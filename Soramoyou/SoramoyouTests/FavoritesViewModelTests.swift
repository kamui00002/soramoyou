//
//  FavoritesViewModelTests.swift
//  SoramoyouTests
//
//  「私のお気に入りの空」一覧 ViewModel のテスト。⭐️
//  最小 Mock（fetchFavorites / fetchPost のみ上書き）で検証。
//
//  この画面の肝は「1件ずつ fetchPost して、落ちた1件で全体を巻き込まない」こと。
//  そのため失敗の分類（削除済み・非公開化 → 表示しない ／ ネットワーク → エラー表示）を重点的に見る。
//

import XCTest
@testable import Soramoyou
import FirebaseFirestore

@MainActor
final class FavoritesViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeFavorites(_ ids: [String]) -> [Favorite] {
        // createdAt は新しい順（先頭が最新）になるように降順で振る
        ids.enumerated().map { index, id in
            Favorite(postId: id, createdAt: Date(timeIntervalSince1970: Double(1000 - index)))
        }
    }

    private func makePost(_ id: String) -> Post {
        Post(id: id, userId: "u1", images: [])
    }

    /// 非公開化・フォロー解除で読めなくなった状態（permissionDenied）を再現する
    private func permissionDeniedError() -> Error {
        FirestoreServiceError.fetchFailed(
            NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        )
    }

    // MARK: - Tests

    /// 1. favorites の順序が posts に保たれる（fetchPost は並列なので順序保持は VM の責務）
    func testLoadPreservesFavoriteOrder() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"])
        XCTAssertEqual(viewModel.unavailableCount, 0)
        XCTAssertNil(viewModel.lastError)
    }

    /// 2. 削除済み（notFound）の投稿は落ちて unavailableCount に数えられ、他は表示される
    func testDeletedPostIsCountedAsUnavailable() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "gone", "p3"])
        mock.postsById = ["p1": makePost("p1"), "p3": makePost("p3")]
        mock.failingPostIds = ["gone": FirestoreServiceError.notFound]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p3"])
        XCTAssertEqual(viewModel.unavailableCount, 1)
        XCTAssertNil(viewModel.lastError, "1件落ちただけで画面全体をエラーにしない")
    }

    /// 3. 非公開化（permissionDenied）も unavailable 扱い
    func testPermissionDeniedIsCountedAsUnavailable() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "hidden"])
        mock.postsById = ["p1": makePost("p1")]
        mock.failingPostIds = ["hidden": permissionDeniedError()]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"])
        XCTAssertEqual(viewModel.unavailableCount, 1)
        XCTAssertNil(viewModel.lastError)
    }

    /// 4. 全件が一時的な失敗（ネットワーク等）なら「0件」と嘘をつかずエラーにする
    func testAllTransientFailuresSurfaceError() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2"])
        let networkError = FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        mock.failingPostIds = ["p1": networkError, "p2": networkError]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertNotNil(viewModel.lastError, "一時的な失敗を『0件』と表示してはいけない")
    }

    /// 5. pageSize ちょうどなら hasMore が立ち、loadMore で追記され、
    ///    2ページ目が pageSize 未満になったら hasMore が倒れる
    func testPaginationAppendsAndStops() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [p1, p2]（ちょうど）、2ページ目 = [p3]（未満）
        mock.allFavorites = makeFavorites(["p1", "p2", "p3"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"])
        XCTAssertFalse(viewModel.hasMore)

        // カーソルの受け渡しを検証する（「追記された」だけでは、カーソルが
        // 進んでいなくても・巻き戻っていてもテストは緑になってしまう）
        XCTAssertEqual(mock.receivedAfterValues.count, 2)
        XCTAssertNil(mock.receivedAfterValues.first ?? nil, "1ページ目は先頭から取る（カーソルなし）")
        XCTAssertEqual(
            mock.receivedAfterValues.last ?? nil,
            mock.allFavorites[1].createdAt,
            "2ページ目は1ページ目末尾（p2）の createdAt から続ける"
        )
    }

    /// 6. syncFavorited(ids:) で、お気に入りから外れた投稿だけが消える
    func testSyncFavoritedDropsUnfavoritedOnly() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)
        await viewModel.load()

        // p2 を詳細画面で解除したことにする
        viewModel.syncFavorited(ids: ["p1", "p3"])

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p3"])
    }

    /// 7. お気に入りに戻った投稿が、元の位置へ戻る ⭐️
    ///
    /// 起きうる場面は2つとも実在する:
    ///   - 解除の書き込みが失敗して FavoriteManager がローカルをリバートした
    ///   - ユーザーが誤タップに気づいてすぐ押し直した
    /// 削除しかしない実装だと、どちらでも「お気に入りのままなのに一覧から消えた」まま
    /// pull-to-refresh するまで直らない。
    func testSyncFavoritedRestoresPostAtOriginalPosition() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)
        await viewModel.load()

        viewModel.syncFavorited(ids: ["p1", "p3"])
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p3"])

        // 書き込み失敗のリバート（または押し直し）で p2 がお気に入りへ戻る
        viewModel.syncFavorited(ids: ["p1", "p2", "p3"])

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"], "末尾ではなく元の位置へ戻る")
    }

    /// 8. 一時的な失敗に当たったら、そのページを**そこで切り詰める** ⭐️
    ///
    /// 「失敗した1件だけ飛ばして残りを積む」と、カーソルはページ末尾まで進むのに
    /// 失敗した投稿は積まれていない。次ページはその先から始まるので、
    /// **その投稿は二度と取りに行かれず静かに消える**（お気に入りしたのに一覧に無い）。
    ///
    /// レジで30個スキャンして袋に入ったのが25個なら、レシートは25個分で切る。
    /// ＝カーソルは「解決できた最後の1件」までしか進めない。
    func testTransientFailureTruncatesPageAndResumesAfterRecovery() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3", "p4"])
        mock.postsById = [
            "p1": makePost("p1"), "p2": makePost("p2"),
            "p3": makePost("p3"), "p4": makePost("p4")
        ]
        mock.failingPostIds = [
            "p2": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 3)

        await viewModel.load()

        XCTAssertEqual(
            viewModel.posts.map(\.id), ["p1"],
            "p2 で打ち切る。p3 を先に積むと、間の p2 が永久に欠落する"
        )
        XCTAssertTrue(viewModel.hasMore, "切り詰めた＝サーバーにはまだ続きが残っている")
        XCTAssertNotNil(viewModel.loadMoreError, "つまずいたことをフッターに出す（黙って諦めない）")

        // 通信が回復した状態で続きを読む
        mock.failingPostIds = [:]
        await viewModel.loadMore()

        // ⚠️ ここが本命。「カーソルを進めすぎない」ことの結果を**表示される並び**で見る。
        //    進めすぎれば p2 が欠落し、戻しすぎれば p1 が二重に出る。どちらもこの1本で落ちる。
        XCTAssertEqual(
            viewModel.posts.map(\.id), ["p1", "p2", "p3", "p4"],
            "切り詰めた p2 から再開する。欠落も重複もしない"
        )
        XCTAssertNil(viewModel.loadMoreError, "回復したらエラー表示は消える")
    }

    /// 9. 1ページ丸ごと出せなかったら、次のページまで繰る ⭐️
    ///
    /// 一覧が0件だと画面に最後のセルが存在せず、`.onAppear` 起点の loadMore が発火しない。
    /// ViewModel 側で繰らないと、その先に生きている投稿があっても永久に辿り着けない。
    func testAllUnavailablePageAdvancesToNextPage() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [gone1, gone2]（全滅）、2ページ目 = [p3]
        mock.allFavorites = makeFavorites(["gone1", "gone2", "p3"])
        mock.postsById = ["p3": makePost("p3")]
        mock.failingPostIds = [
            "gone1": FirestoreServiceError.notFound,
            "gone2": FirestoreServiceError.notFound
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p3"], "1ページ目が全滅でも2ページ目まで繰る")
        XCTAssertEqual(viewModel.unavailableCount, 2, "繰った先でも、出せなかった件数は数え続ける")
        XCTAssertFalse(viewModel.hasMore, "2ページ目が pageSize 未満なので終端")
    }

    /// 10. 全ページ出せなくても、ページ繰りは予算で止まる ⭐️
    ///
    /// 削除済みの favorites が数百件ある人で無限に回らないための上限。
    /// ただし打ち切ったときに `hasMore` を倒してはいけない
    /// （倒すと「お気に入りは全部消えました」と**嘘の断定**を表示することになる）。
    func testAllUnavailablePagesStopAtPageBudget() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // 予算より多いページを用意し、全ページとも全件が削除済み
        // pageSize(2) × 予算(5) を超える16件。全件が削除済み
        mock.allFavorites = makeFavorites((1...16).map { "g\($0)" })
        for favorite in mock.allFavorites {
            mock.failingPostIds[favorite.postId] = FirestoreServiceError.notFound
        }
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertEqual(mock.receivedAfterValues.count, 5, "無限には繰らない（1リクエストあたり5ページまで）")
        XCTAssertTrue(viewModel.hasMore, "予算切れ。続きが残っているのに『全部消えた』と断定しない")
        XCTAssertTrue(
            viewModel.stalledWithMore,
            "自動のページ送りは末尾セルが変わらないと再発火しない。手動の導線を画面に出す必要がある状態"
        )
    }

    /// 11. 続きの読み込みが一時的に失敗したら、黙って捨てず表に出す ⭐️
    ///
    /// 修正前の `loadMore` は解決結果の一時的な失敗を見ておらず、取れなかった投稿は
    /// **カーソルだけ進んで静かに消えていた**。画面にも何も出ないので気づく手段が無い。
    /// 一覧全体をエラーにはせず（既に出ているものは残す）、フッターで再試行を促す。
    func testLoadMoreSurfacesTransientErrorInsteadOfDroppingIt() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3", "p4"])
        mock.postsById = [
            "p1": makePost("p1"), "p2": makePost("p2"),
            "p3": makePost("p3"), "p4": makePost("p4")
        ]
        mock.failingPostIds = [
            "p4": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertNil(viewModel.loadMoreError, "1ページ目は問題なく解決できている")

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"], "p4 の手前まで積む")
        XCTAssertNotNil(viewModel.loadMoreError, "失敗を黙って捨てない")
        XCTAssertTrue(viewModel.hasMore, "p4 はまだサーバーに残っている")

        // ⚠️ ここからが本命。`loadMore` が **自分で書いた** カーソル（p3 まで）を
        //    次の `loadMore` が正しく使うかを見る。
        //    テスト8が見ているのは「`load` が書いたカーソルを `loadMore` が読む」側だけなので、
        //    ここを見ないと `self.cursor = batch.cursor ?? cursor` を消しても緑のまま通る
        //    （そのときは p2 から取り直すので p3 が二重に出る）。
        mock.failingPostIds = [:]
        await viewModel.loadMore()

        XCTAssertEqual(
            viewModel.posts.map(\.id), ["p1", "p2", "p3", "p4"],
            "切り詰めた p4 から再開する。p3 は重複しない"
        )
        let expectedCursors: [Date?] = [
            nil,
            mock.allFavorites[1].createdAt,  // 2回目 = 1ページ目末尾の p2
            mock.allFavorites[2].createdAt   // 3回目 = loadMore が切り詰めた位置の p3
        ]
        XCTAssertEqual(
            mock.receivedAfterValues, expectedCursors,
            "3回目は p3 から続ける（1ページ目末尾の p2 へ巻き戻らない）"
        )
        XCTAssertNil(viewModel.loadMoreError, "回復したらエラー表示は消える")
    }

    /// 12. ページの **先頭** でつまずいたら、カーソルは1歩も進めない ⭐️
    ///
    /// `consumed == 0`（1件も消費していない）のときは、カーソルを「前のページの末尾」に
    /// 据え置かないといけない。失敗した投稿自身の位置へ動かしてしまうと、
    /// 復旧後の取得がその投稿の **次** から始まる＝ **その投稿が永久に欠落する**。
    /// これは今回直したバグ (a) そのものの再来で、既存テストはどれも consumed >= 1 なので拾えない。
    func testFirstItemFailureKeepsCursorAtPreviousPageEnd() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3", "p4"])
        mock.postsById = [
            "p1": makePost("p1"), "p2": makePost("p2"),
            "p3": makePost("p3"), "p4": makePost("p4")
        ]
        // 2ページ目の **先頭** p3 でつまずかせる（＝ consumed == 0）
        mock.failingPostIds = [
            "p3": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])

        await viewModel.loadMore()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"], "先頭で落ちたので1件も積めない")
        XCTAssertNotNil(viewModel.loadMoreError)
        XCTAssertTrue(viewModel.hasMore, "p3 以降はまだサーバーに残っている")

        // 通信が回復した状態で続きを読む
        mock.failingPostIds = [:]
        await viewModel.loadMore()

        XCTAssertEqual(
            viewModel.posts.map(\.id), ["p1", "p2", "p3", "p4"],
            "p3 から再開する。1件も消費していないのでカーソルは据え置き"
        )
        let expectedCursors: [Date?] = [
            nil,
            mock.allFavorites[1].createdAt,  // 2回目 = p2
            mock.allFavorites[1].createdAt   // ⭐️ 3回目も p2 のまま。進めると p3 が消える
        ]
        XCTAssertEqual(mock.receivedAfterValues, expectedCursors, "失敗した回はカーソルを進めない")
    }

    /// 13. 一覧が **非空** でも、続きが全滅すれば行き詰まる ⭐️
    ///
    /// ⚠️ 「1件も出せていない」だけが行き詰まりではない。1件出たあとで続きが全滅すると、
    ///    末尾セルの id が変わらないので `.onAppear` は再発火せず、
    ///    pull-to-refresh しても `load()` は1件出た1ページ目で止まる（繰らない）。
    ///    `loadMore` 側でも `stalledWithMore` を立てないと、この人はその先へ二度と進めない。
    ///
    /// ⭐️ この状態は `hasMore && posts.isEmpty` では代用できない（`posts` は非空だから）。
    ///    「今回のバッチで1件でも増えたか」という **差分** でしか判別できないことの証拠。
    func testNonEmptyListStallsAtPageBudgetAndRecovers() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // [p1, g0...g10, p2] = 13件。先頭で1件だけ出せて、そのあと11件が削除済み
        mock.allFavorites = makeFavorites(["p1"] + (0...10).map { "g\($0)" } + ["p2"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2")]
        for index in 0...10 {
            mock.failingPostIds["g\(index)"] = FirestoreServiceError.notFound
        }
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"], "1ページ目で1件出たのでそこで止まる")
        XCTAssertFalse(viewModel.stalledWithMore, "この時点では1件増えている＝行き詰まっていない")

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"], "5ページ繰っても1件も増えない")
        XCTAssertTrue(viewModel.hasMore, "予算切れ。『全部消えた』と断定しない")
        XCTAssertTrue(
            viewModel.stalledWithMore,
            "一覧が非空でも手動の導線が要る（末尾セルが変わらず .onAppear は再発火しない）"
        )
        XCTAssertEqual(
            viewModel.unavailableCount, 11,
            "load の1件 + loadMore の10件。ページをまたいでも累計で数える"
        )

        // 手動ボタンから続きを読めば、その先の生きている投稿に辿り着ける
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"], "行き詰まりから抜けられる")
        XCTAssertFalse(viewModel.stalledWithMore, "前に進めたのでフラグは倒れる")
        XCTAssertFalse(viewModel.hasMore, "最後のページは pageSize 未満")
    }

    /// 14. 切り詰めて捨てた後半の「出せない投稿」は数えない ⭐️
    ///
    /// ⚠️ 切り詰めた後半は **まだ消費していない**（次の取得でもう一度読む）。
    ///    ここで先に数えると、再取得したときに二重計上されて脚注の件数が膨らむ。
    ///    逆に、再取得で見つかった分は累計に足さないといけない（`=` で上書きすると消える）。
    ///    どちらへ転んでもユーザーには「非公開・削除された空 N件」の N が狂って見える。
    func testUnavailableCountIsNotDoubleCountedAcrossTruncation() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // 1ページ(4件)の中に「消費済みの gone1」「切り詰めの起点 p2」「未消費の gone2」が同居する
        mock.allFavorites = makeFavorites(["p1", "gone1", "p2", "gone2"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2")]
        mock.failingPostIds = [
            "gone1": FirestoreServiceError.notFound,
            "gone2": FirestoreServiceError.notFound,
            "p2": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 4)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"], "p2 で打ち切る")
        XCTAssertEqual(
            viewModel.unavailableCount, 1,
            "数えるのは消費した範囲（gone1）だけ。切り詰めた後半の gone2 を先に数えない"
        )

        // 通信が回復して、切り詰めた p2 から読み直す
        mock.failingPostIds["p2"] = nil
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])
        XCTAssertEqual(
            viewModel.unavailableCount, 2,
            "再取得で見つかった gone2 を足して累計2。二重に数えて3にもしない"
        )
    }

    /// 15. favorites クエリ **そのもの** が失敗したら、黙らずフッターに出す ⭐️
    ///
    /// ⚠️ 取得は2層。ここで見るのは **下の層**（favorites の1ページ取得・アトミック）の失敗。
    ///    Mock が常に成功する作りだと `load` / `loadMore` の catch 節は一度も実行されないまま
    ///    「テストは全部 green」になる。実運用でいちばん起きるのは通信断で、
    ///    そのとき黙って何も出ないとユーザーには「続きが出てこない」としか見えない。
    func testFavoritesQueryFailureSurfacesInFooterAndResumesFromSameCursor() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])

        // 2回目の favorites クエリだけ通信エラーにする
        mock.fetchFavoritesFailure = (
            call: 2,
            error: FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        )
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"], "既に出ているものは消さない")
        XCTAssertNotNil(viewModel.loadMoreError, "黙って諦めない（フッターに再試行を出す）")
        XCTAssertNil(viewModel.lastError, "一覧全体をエラー画面にはしない")
        XCTAssertTrue(viewModel.hasMore, "再試行できるよう hasMore は倒さない")

        // 通信が回復
        mock.fetchFavoritesFailure = nil
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"])
        XCTAssertNil(viewModel.loadMoreError, "回復したらエラー表示は消える")
        let expectedCursors: [Date?] = [
            nil,
            mock.allFavorites[1].createdAt,  // 2回目 = p2（ここで throw）
            mock.allFavorites[1].createdAt   // ⭐️ 3回目も p2。失敗した回はカーソルを進めない
        ]
        XCTAssertEqual(mock.receivedAfterValues, expectedCursors, "同じカーソルから読み直す")
    }
}

// MARK: - Mock

final class MockFirestoreServiceForFavoritesList: FirestoreServiceProtocol {
    /// お気に入り全件（createdAt の降順）。`fetchFavorites` はここから `after` / `limit` で切り出す ⭐️
    ///
    /// ⚠️ 「呼び出し順に用意したページを返す」形だと、**カーソルを渡していない実装でもテストが緑になる**。
    ///    この画面の肝はまさに「カーソルをどこまで進めるか」なので、Mock 側で `after` を実際に尊重する。
    ///    本番の `fetchFavorites` は `order(by: createdAt, descending: true)` + `start(after:)` ＝
    ///    **同値は含まない**ので、その意味論に合わせている。
    var allFavorites: [Favorite] = []
    /// fetchFavorites に渡された `after`（カーソル）の記録 ⭐️
    ///
    /// ⚠️ カーソルを `DocumentSnapshot` ではなく `createdAt` の `Date` にしたのは
    ///    「protocol にスナップショットを出さない＝テストでモックできる」ようにするため。
    ///    その設計判断を活かすには、実際に渡っている値を検証しないと意味がない。
    private(set) var receivedAfterValues: [Date?] = []
    /// postId -> Post（成功する投稿）
    var postsById: [String: Post] = [:]
    /// postId -> 投げるエラー（失敗する投稿）
    var failingPostIds: [String: Error] = [:]
    /// 指定した回数目の `fetchFavorites` だけ失敗させる（`call` は1始まり）⭐️
    ///
    /// ⚠️ 下の層（favorites の1ページ取得）は **アトミック** で、失敗すればページ丸ごと throw する。
    ///    この経路を再現できる口が無いと、`load` / `loadMore` の catch 節は一度も実行されないまま
    ///    「テストは全部 green」になる（＝落ちない代わりに、何も証明していない）。
    var fetchFavoritesFailure: (call: Int, error: Error)?


    func fetchFavorites(userId _: String, limit: Int, after: Date?) async throws -> [Favorite] {
        receivedAfterValues.append(after)
        // 何回目の呼び出しかは記録した件数で数える（＝失敗した回も1回として数える）
        if let failure = fetchFavoritesFailure, failure.call == receivedAfterValues.count {
            throw failure.error
        }
        // start(after:) 相当。降順なので「カーソルより古いもの」を返し、同値は含まない。
        let remaining = after.map { cursor in
            allFavorites.filter { $0.createdAt < cursor }
        } ?? allFavorites
        return Array(remaining.prefix(limit))
    }

    func fetchPost(postId: String) async throws -> Post {
        if let error = failingPostIds[postId] { throw error }
        guard let post = postsById[postId] else { throw FirestoreServiceError.notFound }
        return post
    }
}
