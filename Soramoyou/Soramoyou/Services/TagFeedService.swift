//
//  TagFeedService.swift
//  Soramoyou
//
//  ハッシュタグ単位の投稿取得サービス ⭐️
//
//  既存の `FirestoreService.searchByHashtag` は limit を持たず全件取得するため、
//  タグ詳細画面のような「無限スクロールする一覧」には流用できない。
//  ここでページング対応版を別途用意する。
//
//  ⚠️ タグは正規化しない（小文字化・トリムをしない）。
//     `PostViewModel.extractHashtags` が保存した生の単語をそのまま使う。
//     Firestore の `arrayContains` は完全一致のため、正規化すると既存投稿に当たらない。
//

import FirebaseFirestore
import Foundation

// MARK: - Protocol

/// タグフィード取得のインターフェース（テスト時にモックを注入可能）
protocol TagFeedServiceProtocol {
    /// 指定ハッシュタグの公開投稿を新着順にページング取得する
    /// - Parameters:
    ///   - hashtag: "#" を含まない生のタグ文字列
    ///   - limit: 1ページあたりの件数
    ///   - lastDocument: 前ページの最後のドキュメント（nil なら先頭ページ）
    /// - Returns: 投稿と、次ページ取得に使う最後のドキュメント
    func fetchPostsByHashtag(
        _ hashtag: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?)

    /// 自分の投稿からよく使っているハッシュタグを推定する
    /// - Parameters:
    ///   - userId: 対象ユーザーID
    ///   - topN: 返す件数の上限
    /// - Returns: 使用頻度の高い順のタグ配列
    func fetchInferredTags(userId: String, topN: Int) async throws -> [String]
}

// MARK: - 頻度集計（純関数）

/// ハッシュタグの使用頻度を集計する純関数群 ⭐️
///
/// Firestore に一切触らないため単体テストが可能（`TagFeedServiceTests`）。
/// フォロー中タグが 0 件のときの補完候補を出す用途で使う。
enum HashtagFrequencyRanker {
    /// ハッシュタグ配列の集合から、使用頻度の高い順に上位 `topN` 件を返す。
    ///
    /// - 同一投稿内で同じタグが複数回出ても **1 回として数える**。
    ///   1 つの投稿にキャプションで「#空 #空 #空」と書かれただけで
    ///   そのタグが上位に来てしまうのを防ぐため（＝「何件の投稿で使ったか」を数える）。
    /// - 空文字・空白のみのタグは除外する。
    /// - 並び順は「件数の降順 → タグ名の昇順」。
    ///   ⚠️ Swift の `sorted(by:)` は安定ソートではないため、件数が同じタグの順序が
    ///      実行ごとに変わりうる。タグ名を第2キーにして結果を決定的にする
    ///      （テストが不定期に落ちるのを防ぐ）。
    ///
    /// - Parameters:
    ///   - groups: 投稿ごとのハッシュタグ配列
    ///   - topN: 返す件数の上限（0 以下なら空配列）
    /// - Returns: 使用頻度の高い順のタグ配列
    static func topTags(fromHashtagGroups groups: [[String]], topN: Int) -> [String] {
        guard topN > 0 else { return [] }

        var counts: [String: Int] = [:]
        for group in groups {
            // 同一投稿内の重複を潰してから数える
            for tag in Set(group) {
                // 空文字・空白のみは意味を成さないので数えない（トリムは判定にのみ使い、
                // 集計キーは保存値そのまま＝Firestore の完全一致を壊さない）
                guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                counts[tag, default: 0] += 1
            }
        }

        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value // 件数の多い順
                }
                return lhs.key < rhs.key // 同数はタグ名の昇順（決定的にするため）
            }
            .prefix(topN)
            .map(\.key)
    }

    /// 投稿配列から使用頻度の高いタグを返す（`topTags(fromHashtagGroups:topN:)` の薄いラッパー）
    static func topTags(from posts: [Post], topN: Int) -> [String] {
        topTags(fromHashtagGroups: posts.map { $0.hashtags ?? [] }, topN: topN)
    }
}

// MARK: - Service

/// タグフィード取得サービス
final class TagFeedService: TagFeedServiceProtocol {
    /// 推定タグを集計するときに遡る自分の投稿の件数
    private static let inferredTagsScanLimit = 50

    private let db: Firestore
    /// 自分の投稿取得は既存実装（`fetchUserPosts`）を再利用する。
    /// ハッシュタグ検索だけは limit 付きの新クエリが必要なので `db` を直接使う。
    private let firestoreService: FirestoreServiceProtocol

    init(
        db: Firestore = Firestore.firestore(),
        firestoreService: FirestoreServiceProtocol = FirestoreService()
    ) {
        self.db = db
        self.firestoreService = firestoreService
    }

    private var postsCollection: CollectionReference {
        db.collection("posts")
    }

    // MARK: - Fetch Posts By Hashtag

    /// 指定ハッシュタグの公開投稿を新着順にページング取得する
    ///
    /// クエリ構成: `visibility == "public"` + `hashtags arrayContains tag`
    ///           + `createdAt` 降順 + `limit`
    /// → 既存の複合インデックス `visibility ASC, hashtags CONTAINS, createdAt DESC`
    ///   でそのまま賄えるため `firestore.indexes.json` の変更は不要。
    func fetchPostsByHashtag(
        _ hashtag: String,
        limit: Int,
        lastDocument: DocumentSnapshot?
    ) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) {
        do {
            var query: Query = postsCollection
                .whereField("visibility", isEqualTo: Visibility.public.rawValue)
                .whereField("hashtags", arrayContains: hashtag)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)

            // ページネーション: 前ページの最後のドキュメントの続きから取得
            if let lastDocument {
                query = query.start(afterDocument: lastDocument)
            }

            let snapshot = try await query.getDocuments()

            // ⚠️ compactMap { try? ... } は壊れたドキュメントを無言で落とすため使わない。
            //    1件のデコード失敗でページ全体を捨てると一覧が真っ白になるので、
            //    パスをログに残したうえでその1件だけスキップする（tech-spec.md の方針）。
            // ⚠️ スキップにより posts.count が limit を割ると、基底 PaginatedPostsViewModel
            //    （posts.count < pageSize で hasMorePosts=false）がページングを早期に打ち切る。
            //    壊れたドキュメントは現状想定されないため graceful degradation として許容し、
            //    PR-7 のマージ層（0件ページ禁止）と併せて見直す。
            let posts = snapshot.documents.compactMap { document -> Post? in
                do {
                    return try Post(from: document.data())
                } catch {
                    print("❌ タグフィードの投稿デコード失敗 path=\(document.reference.path) error=\(error.localizedDescription)")
                    return nil
                }
            }

            // 次ページの起点は「デコード成否に関わらず実際に読んだ最後のドキュメント」。
            // posts.last だとスキップした壊れたドキュメントで無限ループになる。
            return (posts: posts, lastDocument: snapshot.documents.last)
        } catch {
            throw FirestoreServiceError.fetchFailed(error)
        }
    }

    // MARK: - Inferred Tags

    /// 自分の直近の投稿から、よく使っているハッシュタグを推定する
    ///
    /// フォロー中タグが 0 件のユーザーに「あなたがよく使うタグ」を出すための補完に使う。
    /// 集計自体は純関数 `HashtagFrequencyRanker` が行う。
    ///
    /// ⚠️ 現時点では未配線（本番の呼び出し元は無く、テストも集計の純関数
    ///    `HashtagFrequencyRanker` だけを検証している）。後続 PR-7（あなた向けフィード）の
    ///    ForYouFeedSourceBuilder が「フォロー中タグ0件のときの補完」に使う前倒し実装。
    func fetchInferredTags(userId: String, topN: Int) async throws -> [String] {
        let posts = try await firestoreService.fetchUserPosts(
            userId: userId,
            limit: Self.inferredTagsScanLimit,
            lastDocument: nil
        )
        return HashtagFrequencyRanker.topTags(from: posts, topN: topN)
    }
}
