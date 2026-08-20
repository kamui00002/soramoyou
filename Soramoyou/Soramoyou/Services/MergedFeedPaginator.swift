//
//  MergedFeedPaginator.swift
//  Soramoyou
//
//  「あなた向け」フィードの k-way マージページネーター ⭐️
//
//  複数のソート済みストリーム（フォロー中の公開投稿 / フォロー中のフォロワー限定投稿 /
//  フォロータグの投稿）を createdAt 降順のまま1本のフィードに合成する。
//
//  設計上の絶対条件:
//  - Firestore 非依存（fetch クロージャ注入）にして単体テスト可能にする
//  - 「0件ページ」を hasMore=true のまま返さない。HomeView のページング発火は
//    「最後の投稿の .onAppear」なので、途中で0件を返すとフィードが恒久停止する。
//    1件以上 emit できるまで内部でループし、空を返すのは全ストリーム枯渇時のみ
//  - 1ストリームの失敗で全体を落とさない（失敗ストリームはスキップして継続）
//  - ブロック除外は emit 前に行う（emit 後に filter するとページが縮み、上の保証が壊れる）
//  - 重複除去はページを跨いで行う（フォロー中の人のタグ投稿は A1 と B の両方に現れる）
//

import Foundation

// MARK: - Stream Source

/// マージ対象の1ストリーム分の取得口。
///
/// カーソル（Firestore の DocumentSnapshot 等）は fetchPage クロージャ側が保持する。
/// これにより本ファイルは Firestore に依存せず、テストでは配列を切り出すだけの
/// クロージャを注入できる（ForYouFeedSourceBuilder が本番用クロージャを組み立てる）。
struct FeedStreamSource {
    /// ログ用の識別子（例: "A1-0" / "A2-1" / "B"）
    let id: String
    /// 1ページ取得する。呼び出しのたびに「前回の続き」を返すこと。
    let fetchPage: (_ limit: Int) async throws -> FeedStreamPage
}

/// 1ページ分の取得結果。
struct FeedStreamPage {
    /// デコードに成功した投稿（createdAt 降順で並んでいること）
    let posts: [Post]
    /// これ以上取得できるものが無いか。
    /// ⚠️ デコード成功件数ではなく「生の取得ドキュメント数 < limit」で判定すること。
    ///    デコード失敗のスキップで posts.count が limit を割っただけのページを
    ///    枯渇と誤判定すると、ページングが早期に打ち切られる（PR-6 レビュー指摘と同型の罠）。
    let isExhausted: Bool
}

// MARK: - Paginator

/// k 本のソート済みストリームを createdAt 降順で1本にマージするページネーター。
///
/// 使い方の契約:
/// - リフレッシュ時は本インスタンスを**新規に作り直す**こと（カーソルを巻き戻す口は無い）。
/// - `nextPage` の並行呼び出しはしないこと（ViewModel 側の isLoadingMore /
///   isRefreshing ガードで直列化される前提）。
@MainActor
final class MergedFeedPaginator {
    /// ストリームごとの内部状態
    private final class StreamState {
        let source: FeedStreamSource
        /// 取得済み・未 emit の投稿（createdAt 降順）
        var buffer: [Post] = []
        var isExhausted = false
        var isFailed = false

        init(source: FeedStreamSource) {
            self.source = source
        }

        /// まだ emit しうる投稿を持ちうるか（失敗ストリームは残量に数えない）
        var isActive: Bool { !isFailed && (!buffer.isEmpty || !isExhausted) }
    }

    private let streams: [StreamState]
    /// ストリーム1回あたりの取得件数
    private let fetchPageSize: Int
    /// 重複除去用の emit 済み投稿 ID。ページを跨いで保持する。
    private var emittedIds: Set<String> = []
    /// ブロック判定（emit 前に除外する）
    private let isBlocked: (_ userId: String) -> Bool
    /// 最初に発生したストリーム失敗。全ストリームが沈黙して1件も返せない時に
    /// 呼び出し側へ伝える（「無言で空フィード」にしない。欠陥C の反省）。
    private var firstError: Error?
    /// これまでに1件でも emit したか。「部分的に成功して表示できていたフィード」が
    /// 末尾のページで突然エラーになるのを避けるため、throw は一度も emit して
    /// いない場合（＝画面が空のまま）に限定する。
    private var hasEmittedAny = false

    /// まだ読み込める投稿が残っている可能性があるか
    private(set) var hasMore: Bool = true

    /// - Parameters:
    ///   - sources: マージ対象のストリーム群（空ならフィードは最初から空）
    ///   - fetchPageSize: ストリーム1回あたりの取得件数
    ///   - isBlocked: ブロック済みユーザー判定。true の投稿は emit しない
    init(
        sources: [FeedStreamSource],
        fetchPageSize: Int,
        isBlocked: @escaping (_ userId: String) -> Bool = { _ in false }
    ) {
        streams = sources.map(StreamState.init)
        self.fetchPageSize = max(1, fetchPageSize)
        self.isBlocked = isBlocked
        // ソースが1本も無い（フォロー0・タグ0）なら最初から枯渇扱い
        if sources.isEmpty {
            hasMore = false
        }
    }

    /// 次のページを返す。
    ///
    /// - limit 件そろうか全ストリームが枯渇するまで内部でループする
    ///   （ブロック・重複だけのページを 0 件のまま返さない）。
    /// - 1件も返せず、かつストリーム失敗が原因の場合はエラーを投げる。
    func nextPage(limit: Int) async throws -> [Post] {
        var emitted: [Post] = []

        while emitted.count < limit {
            // 1. アクティブなのにバッファが空のストリームへ1ページ補充する
            await fillEmptyBuffers()

            // 2. バッファに投稿を持つストリームを候補にする
            let candidates = streams.filter { !$0.buffer.isEmpty }
            if candidates.isEmpty {
                // アクティブなストリームが残っていなければ全体が枯渇
                if !streams.contains(where: \.isActive) {
                    break
                }
                // アクティブなのにバッファが空（例: ページ内の全件がデコード失敗）
                // → カーソルは進んでいるので、次の周回で続きを取り直す
                continue
            }

            // 3. 各ストリーム先頭のうち最も新しい投稿を取り出す。
            //    「全アクティブストリームがバッファを持つ」状態で選ぶため、
            //    未取得の投稿がこれより新しいことはない（k-way マージの安全条件:
            //    各ストリームの未取得分は必ずそのストリームのバッファ末尾より古い）。
            guard let best = candidates.min(by: { lhs, rhs in
                orderedBefore(lhs.buffer[0], rhs.buffer[0])
            }) else { break } // candidates は非空なので到達しない（force unwrap 回避）
            let post = best.buffer.removeFirst()

            // 4. 重複除去 → ブロック除外 → emit
            //    （ブロック投稿も emittedIds に入れて、別ストリーム経由の再登場を防ぐ）
            guard !emittedIds.contains(post.id) else { continue }
            emittedIds.insert(post.id)
            guard !isBlocked(post.userId) else { continue }
            emitted.append(post)
        }

        hasMore = streams.contains { $0.isActive }

        if !emitted.isEmpty {
            hasEmittedAny = true
        }
        // フィードが一度も表示できておらず（＝画面が空のまま）、原因にストリーム失敗が
        // 含まれる場合はエラーとして呼び出し側に伝える。部分的にでも表示できていれば
        // フィード継続を優先して投げない（失敗はログ済み）。
        if emitted.isEmpty, !hasEmittedAny, let error = firstError {
            throw error
        }
        return emitted
    }

    // MARK: - Private

    /// フィード内の表示順: createdAt 降順、同時刻は documentID 昇順（決定的な並びにする）
    private func orderedBefore(_ lhs: Post, _ rhs: Post) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id < rhs.id
    }

    /// バッファが空のアクティブストリームへ1ページずつ補充する。
    /// 取得に失敗したストリームは isFailed にして以後スキップする（全体は落とさない）。
    private func fillEmptyBuffers() async {
        for stream in streams where stream.isActive && stream.buffer.isEmpty {
            do {
                let page = try await stream.source.fetchPage(fetchPageSize)
                stream.buffer = page.posts
                if page.isExhausted {
                    stream.isExhausted = true
                }
            } catch {
                stream.isFailed = true
                if firstError == nil {
                    firstError = error
                }
                ErrorHandler.logError(
                    error,
                    context: "MergedFeedPaginator.stream(\(stream.source.id))"
                )
            }
        }
    }
}
