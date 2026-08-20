//
//  MergedFeedPaginatorTests.swift
//  SoramoyouTests
//
//  MergedFeedPaginator（あなた向けフィードの k-way マージ）の単体テスト ⭐️
//
//  Paginator は Firestore 非依存（fetch クロージャ注入）なので、
//  ここでは「配列を切り出すだけ」のストリームを注入して純粋にマージ規約を検証する。
//
//  計画の必須7ケース:
//  ① 単純インターリーブ ② ページ境界をまたぐ順序 ③ 重複が1回だけ
//  ④ 片方枯渇でも hasMore 継続 ⑤ 1ストリーム throw で残りが継続
//  ⑥ ブロックのみのページで0件を返さず読み進める ⑦ createdAt 同値は documentID 昇順
//

@testable import Soramoyou
import XCTest

@MainActor
final class MergedFeedPaginatorTests: XCTestCase {
    // MARK: - Helpers

    /// テスト用の最小 Post を作る（createdAt はエポック秒で指定）
    private func makePost(_ id: String, user: String = "u1", t: TimeInterval) -> Post {
        Post(id: id, userId: user, images: [], createdAt: Date(timeIntervalSince1970: t))
    }

    /// 配列を limit 件ずつ切り出すだけのテスト用ストリーム。
    /// 本番（ForYouFeedSourceBuilder）と同じく、カーソル（オフセット）はクロージャ側が保持する。
    private func makeArrayStream(id: String, posts: [Post]) -> FeedStreamSource {
        var offset = 0
        return FeedStreamSource(id: id) { limit in
            let page = Array(posts.dropFirst(offset).prefix(limit))
            offset += page.count
            return FeedStreamPage(posts: page, isExhausted: page.count < limit)
        }
    }

    /// テスト用のエラー
    private struct StreamError: Error {}

    // MARK: - ① 単純インターリーブ

    /// 2ストリームの投稿が createdAt 降順で正しく交互にマージされる
    func test単純インターリーブ() async throws {
        let streamA = makeArrayStream(id: "A", posts: [
            makePost("a1", t: 100), makePost("a2", t: 80), makePost("a3", t: 60),
        ])
        let streamB = makeArrayStream(id: "B", posts: [
            makePost("b1", t: 90), makePost("b2", t: 70), makePost("b3", t: 50),
        ])
        let paginator = MergedFeedPaginator(sources: [streamA, streamB], fetchPageSize: 10)

        let page = try await paginator.nextPage(limit: 6)

        XCTAssertEqual(page.map(\.id), ["a1", "b1", "a2", "b2", "a3", "b3"])
        XCTAssertFalse(paginator.hasMore)
    }

    // MARK: - ② ページ境界をまたぐ順序

    /// A の1ページ目末尾より古い投稿が B の1ページ目途中に入っても、
    /// 全件読み切ったときにタイムスタンプが単調減少していること。
    /// （このバグは通常操作では絶対に発現しないため、fetchPageSize=3 で作為的に再現する）
    func testページ境界をまたいでも順序が保たれる() async throws {
        // A のページ1 = [100, 90, 20]（末尾 20）、ページ2 = [10]
        // B のページ1 = [95, 30, 25] → 30 と 25 は「A のページ1末尾(20)より新しい」
        let streamA = makeArrayStream(id: "A", posts: [
            makePost("a1", t: 100), makePost("a2", t: 90),
            makePost("a3", t: 20), makePost("a4", t: 10),
        ])
        let streamB = makeArrayStream(id: "B", posts: [
            makePost("b1", t: 95), makePost("b2", t: 30), makePost("b3", t: 25),
        ])
        let paginator = MergedFeedPaginator(sources: [streamA, streamB], fetchPageSize: 3)

        // 全件を小さいページで読み切る
        var all: [Post] = []
        while paginator.hasMore {
            all += try await paginator.nextPage(limit: 3)
        }

        XCTAssertEqual(all.map(\.id), ["a1", "b1", "a2", "b2", "b3", "a3", "a4"])
        // タイムスタンプの単調減少を1件ずつ確認
        for pair in zip(all, all.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                pair.0.createdAt, pair.1.createdAt,
                "順序逆転: \(pair.0.id) → \(pair.1.id)"
            )
        }
    }

    // MARK: - ③ 重複が1回だけ

    /// 同じ投稿が複数ストリームに現れても（例: フォロー中の人のタグ投稿は A1 と B の両方に出る）
    /// フィードには1回しか出ない
    func test重複投稿は1回だけemitされる() async throws {
        let duplicated = makePost("dup", t: 90)
        let streamA = makeArrayStream(id: "A", posts: [makePost("a1", t: 100), duplicated])
        let streamB = makeArrayStream(id: "B", posts: [duplicated, makePost("b1", t: 50)])
        let paginator = MergedFeedPaginator(sources: [streamA, streamB], fetchPageSize: 10)

        let page = try await paginator.nextPage(limit: 10)

        XCTAssertEqual(page.map(\.id), ["a1", "dup", "b1"])
    }

    // MARK: - ④ 片方枯渇でも hasMore 継続

    /// 片方のストリームが枯渇しても、もう片方が残っていれば hasMore は true のまま
    func test片方枯渇でもhasMoreが継続する() async throws {
        let streamA = makeArrayStream(id: "A", posts: [makePost("a1", t: 100)])
        let streamB = makeArrayStream(id: "B", posts: [
            makePost("b1", t: 90), makePost("b2", t: 80), makePost("b3", t: 70),
            makePost("b4", t: 60), makePost("b5", t: 50),
        ])
        let paginator = MergedFeedPaginator(sources: [streamA, streamB], fetchPageSize: 2)

        let page1 = try await paginator.nextPage(limit: 3)
        XCTAssertEqual(page1.map(\.id), ["a1", "b1", "b2"])
        // A は枯渇したが B が残っているので継続
        XCTAssertTrue(paginator.hasMore)

        let page2 = try await paginator.nextPage(limit: 3)
        XCTAssertEqual(page2.map(\.id), ["b3", "b4", "b5"])
        XCTAssertFalse(paginator.hasMore)
    }

    // MARK: - ⑤ 1ストリーム throw で残りが継続

    /// 1ストリームの取得失敗で全体を落とさない（失敗ストリームはスキップ）
    func test1ストリームの失敗で全体が落ちない() async throws {
        let failing = FeedStreamSource(id: "failing") { _ in
            throw StreamError()
        }
        let streamB = makeArrayStream(id: "B", posts: [
            makePost("b1", t: 90), makePost("b2", t: 80),
        ])
        let paginator = MergedFeedPaginator(sources: [failing, streamB], fetchPageSize: 10)

        let page = try await paginator.nextPage(limit: 10)

        XCTAssertEqual(page.map(\.id), ["b1", "b2"])
        // 失敗ストリームは残量に数えない
        XCTAssertFalse(paginator.hasMore)
    }

    /// 全ストリームが失敗して1件も返せない場合はエラーを投げる（無言の空フィード禁止）
    func test全ストリーム失敗はエラーを投げる() async {
        let failing1 = FeedStreamSource(id: "f1") { _ in throw StreamError() }
        let failing2 = FeedStreamSource(id: "f2") { _ in throw StreamError() }
        let paginator = MergedFeedPaginator(sources: [failing1, failing2], fetchPageSize: 10)

        do {
            _ = try await paginator.nextPage(limit: 10)
            XCTFail("エラーが投げられるべき")
        } catch {
            XCTAssertTrue(error is StreamError)
        }
        XCTAssertFalse(paginator.hasMore)
    }

    // MARK: - ⑥ ブロックのみのページで0件を返さない

    /// ブロック済みユーザーの投稿だけでページが埋まっても、0件を返さず読み進める。
    /// （HomeView のページング発火は「最後の投稿の .onAppear」なので、
    ///  hasMore=true のまま0件を返すとフィードが恒久停止するため）
    func testブロックのみのページで0件を返さず読み進める() async throws {
        // ページ1（fetchPageSize=3）は全部ブロック済みユーザーの投稿、ページ2に表示可能な投稿
        let streamA = makeArrayStream(id: "A", posts: [
            makePost("x1", user: "blocked", t: 100),
            makePost("x2", user: "blocked", t: 90),
            makePost("x3", user: "blocked", t: 80),
            makePost("a1", user: "visible", t: 70),
        ])
        let paginator = MergedFeedPaginator(
            sources: [streamA],
            fetchPageSize: 3,
            isBlocked: { $0 == "blocked" }
        )

        let page = try await paginator.nextPage(limit: 1)

        XCTAssertEqual(page.map(\.id), ["a1"], "ブロックをスキップして次ページまで読み進めるべき")
    }

    // MARK: - ⑦ createdAt 同値は documentID 昇順

    /// createdAt が同時刻の投稿は documentID の昇順で安定して並ぶ（実行ごとに順序が変わらない）
    func testcreatedAt同値はdocumentID昇順() async throws {
        let streamA = makeArrayStream(id: "A", posts: [makePost("zzz", t: 100)])
        let streamB = makeArrayStream(id: "B", posts: [makePost("aaa", t: 100)])
        let streamC = makeArrayStream(id: "C", posts: [makePost("mmm", t: 100)])
        let paginator = MergedFeedPaginator(
            sources: [streamA, streamB, streamC],
            fetchPageSize: 10
        )

        let page = try await paginator.nextPage(limit: 10)

        XCTAssertEqual(page.map(\.id), ["aaa", "mmm", "zzz"])
    }

    // MARK: - 追加の境界ケース

    /// ソースが1本も無い（フォロー0・タグ0）場合は最初から hasMore=false で空を返す
    func testソース0本は最初から枯渇扱い() async throws {
        let paginator = MergedFeedPaginator(sources: [], fetchPageSize: 10)

        XCTAssertFalse(paginator.hasMore)
        let page = try await paginator.nextPage(limit: 10)
        XCTAssertTrue(page.isEmpty)
    }

    /// 「投稿0件だが枯渇していない」ページ（＝全件デコード失敗の頁に相当）が挟まっても、
    /// カーソルが進んでいれば次の取得で継続する
    func testデコード全失敗ページが挟まっても継続する() async throws {
        var callCount = 0
        let stream = FeedStreamSource(id: "A") { _ in
            callCount += 1
            if callCount == 1 {
                // 1ページ目: 生ドキュメントはあったが全件デコード失敗（posts 空・枯渇ではない）
                return FeedStreamPage(posts: [], isExhausted: false)
            }
            // 2ページ目: 正常な投稿
            return FeedStreamPage(posts: [self.makePost("a1", t: 100)], isExhausted: true)
        }
        let paginator = MergedFeedPaginator(sources: [stream], fetchPageSize: 3)

        let page = try await paginator.nextPage(limit: 3)

        XCTAssertEqual(page.map(\.id), ["a1"])
        XCTAssertEqual(callCount, 2, "空ページの後に続きを取り直すべき")
        XCTAssertFalse(paginator.hasMore)
    }

    /// 空・非枯渇ページ（全件デコード失敗相当）を返したストリームが残っている間は、
    /// 他ストリームを先行 emit しない（先行すると次の補充で時系列が逆転する。レビュー D3）
    func test空ページの後に他ストリームを先行emitしない() async throws {
        var callCountA = 0
        let streamA = FeedStreamSource(id: "A") { _ in
            callCountA += 1
            if callCountA == 1 {
                // 1ページ目: 全件デコード失敗（空・非枯渇）
                return FeedStreamPage(posts: [], isExhausted: false)
            }
            // 2ページ目: B の投稿より新しい投稿が現れる
            return FeedStreamPage(posts: [self.makePost("a1", t: 100)], isExhausted: true)
        }
        let streamB = makeArrayStream(id: "B", posts: [makePost("b1", t: 50)])
        let paginator = MergedFeedPaginator(sources: [streamA, streamB], fetchPageSize: 3)

        let page = try await paginator.nextPage(limit: 3)

        // b1(t=50) を先に emit すると a1(t=100) が後から出て時系列逆転になる
        XCTAssertEqual(page.map(\.id), ["a1", "b1"], "A の補充を待ってからマージすべき")
    }

    /// 「空・非枯渇ページ」を返し続ける契約違反ソースが注入されても、
    /// nextPage は無限ループせず、上限到達でそのストリームを切り離して続行する（レビュー D3）
    func test補充が進まないストリームは上限で切り離される() async throws {
        var stuckCallCount = 0
        let stuckStream = FeedStreamSource(id: "stuck") { _ in
            stuckCallCount += 1
            return FeedStreamPage(posts: [], isExhausted: false) // 永遠に空・非枯渇
        }
        let streamB = makeArrayStream(id: "B", posts: [makePost("b1", t: 50)])
        let paginator = MergedFeedPaginator(sources: [stuckStream, streamB], fetchPageSize: 3)

        let page = try await paginator.nextPage(limit: 1)

        XCTAssertEqual(page.map(\.id), ["b1"], "切り離し後は残りのストリームでマージを続行する")
        XCTAssertFalse(paginator.hasMore, "切り離したストリームは残量に数えない")
        XCTAssertLessThanOrEqual(stuckCallCount, 60, "補充試行は上限で打ち止めになる（無限ループしない）")
    }

    /// 部分的に表示できていたフィードは、以後のページでストリーム失敗が混ざっても
    /// エラーを投げない（表示継続を優先。失敗はログ済み）
    func test部分成功後の失敗はエラーにしない() async throws {
        var callCount = 0
        let flaky = FeedStreamSource(id: "flaky") { _ in
            callCount += 1
            if callCount == 1 {
                return FeedStreamPage(
                    posts: [self.makePost("f1", t: 100), self.makePost("f2", t: 90)],
                    isExhausted: false
                )
            }
            throw StreamError()
        }
        let paginator = MergedFeedPaginator(sources: [flaky], fetchPageSize: 2)

        let page1 = try await paginator.nextPage(limit: 2)
        XCTAssertEqual(page1.map(\.id), ["f1", "f2"])
        XCTAssertTrue(paginator.hasMore)

        // 2ページ目でストリームが失敗 → エラーではなく空ページ＋hasMore=false
        let page2 = try await paginator.nextPage(limit: 2)
        XCTAssertTrue(page2.isEmpty)
        XCTAssertFalse(paginator.hasMore)
    }
}
