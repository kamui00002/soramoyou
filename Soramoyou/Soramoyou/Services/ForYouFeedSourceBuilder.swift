//
//  ForYouFeedSourceBuilder.swift
//  Soramoyou
//
//  「あなた向け」フィードのストリーム構成を組み立てるサービス ⭐️
//
//  MergedFeedPaginator（Firestore 非依存）へ注入する本番用の fetch クロージャを作る層。
//  ストリームは3系統:
//    A1: フォロー中ユーザーの公開投稿      … visibility == 'public'    + userId in [≤30]
//    A2: フォロー中ユーザーのフォロワー限定 … visibility == 'followers' + userId in [≤8] ⚠️
//    B : フォロータグの公開投稿            … visibility == 'public'    + hashtags array-contains-any [≤30]
//
//  ⚠️ A1 と A2 を `visibility in ['public','followers']` の1本にまとめてはいけない。
//     rules の followers 枝は userId 1件ごとに exists() を消費するため、まとめると
//     論理和が 2N に膨らみ exists() 上限（1リクエスト10回）で縛られ、
//     安全なはずの公開投稿まで巻き添えでクエリ全体が denied になる（R1 プローブの知見）。
//
//  ⚠️ B は public 限定。フォロワー限定投稿がタグ経由で未フォローの他人に見えるのは事故。
//

import FirebaseFirestore
import Foundation

// MARK: - Result

/// ストリーム構成の結果（計装用のメタ情報付き）
struct ForYouFeedSources {
    /// MergedFeedPaginator へ渡すストリーム群
    let streams: [FeedStreamSource]
    /// 計装用: フォロー中ユーザー数
    let followeeCount: Int
    /// 計装用: 使用したタグ数
    let tagCount: Int
    /// 計装用: タグの出所（"followed"=明示フォロー / "inferred"=自分の投稿から推定 / "none"=タグなし）
    let tagSource: String
}

// MARK: - Protocol

/// ストリーム構成のインターフェース（テスト時にモックを注入可能）
protocol ForYouFeedSourceBuilderProtocol {
    /// userId の「あなた向け」フィードを構成するストリーム群を組み立てる
    func buildSources(for userId: String) async throws -> ForYouFeedSources
}

// MARK: - Implementation

final class ForYouFeedSourceBuilder: ForYouFeedSourceBuilderProtocol {
    /// フォロー中 uid の取得上限（計画で確定した値）
    private static let maxFollowees = 100
    /// フォロー一覧の1ページ取得件数
    private static let followingPageSize = 50
    /// A1（公開投稿）のチャンクサイズ。Firestore の `in` 上限は 30。
    private static let publicChunkSize = 30
    /// A2（フォロワー限定投稿）のチャンクサイズ ⭐️ R2 対応。
    /// rules の followers 枝は `userId in [...]` の要素1件ごとに exists() を1回消費し、
    /// exists()/get() は「1リクエスト10回まで」（Firebase 公式）。
    /// R2 実測（2026-08-20・本番 rules・フォロー中12人）: チャンク 8 も 12 も denied に
    /// ならず成功＝公式記載より実際は緩い（in 分解後の枝ごとに予算が効いている可能性）。
    /// ただし文書化された上限は 10 のままなので、余裕を持たせた 8 を出荷値とする
    /// （上限ちょうどで設計しない・計画の確定方針）。
    private static let followersChunkSize = 8
    /// フォロータグが0件のときに自分の投稿から補完する推定タグの件数
    private static let inferredTagsTopN = 10
    /// B ストリームのタグ上限（`array-contains-any` の上限 30）
    private static let maxTags = 30

    private let db: Firestore
    private let followRepository: FollowRepositoryProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let tagFeedService: TagFeedServiceProtocol

    init(
        db: Firestore = Firestore.firestore(),
        followRepository: FollowRepositoryProtocol = FollowRepository(),
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        tagFeedService: TagFeedServiceProtocol = TagFeedService()
    ) {
        self.db = db
        self.followRepository = followRepository
        self.firestoreService = firestoreService
        self.tagFeedService = tagFeedService
    }

    private var postsCollection: CollectionReference {
        db.collection("posts")
    }

    // MARK: - Build

    func buildSources(for userId: String) async throws -> ForYouFeedSources {
        // 1. フォロー中の uid（最大100件）。ここの失敗はフィードの核なので呼び出し側へ投げる。
        let followeeIds = try await fetchFolloweeIds(of: userId)

        // 2. タグ: 明示フォロー（users.followedTags）を優先し、0件なら自分の投稿から推定で補完。
        //    タグは「あると嬉しい」層なので、取得失敗でフィード全体は落とさない（ログのみ）。
        let (tags, tagSource) = await resolveTags(for: userId)

        // 3. ストリームを組み立てる
        var streams: [FeedStreamSource] = []

        // A1: フォロー中の公開投稿（in 上限 30 でチャンク分割）
        for (index, chunk) in chunked(followeeIds, size: Self.publicChunkSize).enumerated() {
            streams.append(makePostsStream(id: "A1-\(index)") { [postsCollection] in
                postsCollection
                    .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                    .whereField("userId", in: chunk)
                    .order(by: "createdAt", descending: true)
            })
        }

        // A2: フォロー中のフォロワー限定投稿（R1 プローブ成功により有効化）。
        // ⚠️ 対象はフォロー中ユーザーのみ。未フォロー相手に 'followers' を含む
        //    クエリを投げると rules を満たせずクエリ全体が denied になる。
        // ⚠️ 既知の許容制限（レビュー D7）: チャンクは構築時点のフォロー集合を固定する。
        //    フィード表示中にフォロー解除すると、そのチャンクの以後の補充は rules を
        //    満たせず失敗し（ログ・計装には残る）、同チャンクの他ユーザー分も次の
        //    リフレッシュ（Paginator 再構築）まで欠落する。リフレッシュで自癒するため
        //    許容。フォロー変更イベントとの連動再構築は将来課題。
        for (index, chunk) in chunked(followeeIds, size: Self.followersChunkSize).enumerated() {
            streams.append(makePostsStream(id: "A2-\(index)") { [postsCollection] in
                postsCollection
                    .whereField("visibility", isEqualTo: Visibility.followers.rawValue)
                    .whereField("userId", in: chunk)
                    .order(by: "createdAt", descending: true)
            })
        }

        // B: タグの公開投稿（array-contains-any 上限 30・既存インデックス
        //    `visibility + hashtags CONTAINS + createdAt` で賄えるため追加インデックス不要）
        if !tags.isEmpty {
            let cappedTags = Array(tags.prefix(Self.maxTags))
            streams.append(makePostsStream(id: "B") { [postsCollection] in
                postsCollection
                    .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                    .whereField("hashtags", arrayContainsAny: cappedTags)
                    .order(by: "createdAt", descending: true)
            })
        }

        return ForYouFeedSources(
            streams: streams,
            followeeCount: followeeIds.count,
            tagCount: min(tags.count, Self.maxTags),
            tagSource: tagSource
        )
    }

    // MARK: - Private

    /// フォロー中の uid を最大 maxFollowees 件までページングで取得する
    private func fetchFolloweeIds(of userId: String) async throws -> [String] {
        var ids: [String] = []
        var cursor: DocumentSnapshot?

        while ids.count < Self.maxFollowees {
            let pageLimit = min(Self.followingPageSize, Self.maxFollowees - ids.count)
            let result = try await followRepository.fetchFollowing(
                of: userId,
                limit: pageLimit,
                lastDocument: cursor
            )
            ids.append(contentsOf: result.follows.map(\.followeeId))
            cursor = result.lastDocument
            // 取得件数がページサイズ未満なら残りは無い（デコードスキップで僅かに
            // 少なく見える可能性はあるが、既存の一覧と同じ振る舞いとして許容）
            if result.follows.count < pageLimit || cursor == nil {
                break
            }
        }
        return ids
    }

    /// タグ集合とその出所を解決する。
    /// 明示フォロー（users.followedTags）＞ 0件なら自分の投稿タグ頻度上位で補完（確定仕様6）。
    private func resolveTags(for userId: String) async -> (tags: [String], source: String) {
        do {
            let user = try await firestoreService.fetchUser(userId: userId)
            let followedTags = user.followedTags ?? []
            if !followedTags.isEmpty {
                return (followedTags, "followed")
            }
            let inferred = try await tagFeedService.fetchInferredTags(
                userId: userId,
                topN: Self.inferredTagsTopN
            )
            return (inferred, inferred.isEmpty ? "none" : "inferred")
        } catch {
            // タグが取れなくてもフォロー中ストリームだけでフィードは成立させる
            ErrorHandler.logError(error, context: "ForYouFeedSourceBuilder.resolveTags")
            return ([], "none")
        }
    }

    /// カーソルを内包した投稿ストリームを作る。
    /// カーソル（DocumentSnapshot）をこの箱に閉じ込めることで、
    /// MergedFeedPaginator 側は Firestore の型を一切知らずに済む。
    private func makePostsStream(
        id: String,
        buildQuery: @escaping () -> Query
    ) -> FeedStreamSource {
        let cursor = CursorBox()
        return FeedStreamSource(id: id) { limit in
            var query = buildQuery().limit(to: limit)
            if let last = cursor.lastDocument {
                query = query.start(afterDocument: last)
            }

            let snapshot = try await query.getDocuments()

            // 次ページの起点は「デコード成否に関わらず実際に読んだ最後のドキュメント」。
            // posts.last 基準にするとスキップした壊れたドキュメントで無限ループになる。
            if let last = snapshot.documents.last {
                cursor.lastDocument = last
            }

            // ⚠️ 壊れたドキュメント1件でストリーム全体を落とさない。
            //    パスをログに残して1件だけスキップする（tech-spec.md の方針）。
            let posts = snapshot.documents.compactMap { document -> Post? in
                do {
                    return try Post(from: document.data())
                } catch {
                    print("❌ あなた向けフィードの投稿デコード失敗 path=\(document.reference.path) error=\(error.localizedDescription)")
                    return nil
                }
            }

            // 枯渇判定はデコード成功件数ではなく「生の取得ドキュメント数」で行う
            return FeedStreamPage(
                posts: posts,
                isExhausted: snapshot.documents.count < limit
            )
        }
    }

    /// 配列を size 件ずつに分割する（Firestore の in / array-contains-any 上限対応）
    private func chunked(_ array: [String], size: Int) -> [[String]] {
        guard size > 0, !array.isEmpty else { return [] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0 ..< min($0 + size, array.count)])
        }
    }
}

/// ストリームごとのページネーションカーソルを保持する箱。
/// fetch クロージャに閉じ込めて使う（Paginator を Firestore 非依存に保つため）。
private final class CursorBox {
    var lastDocument: DocumentSnapshot?
}
