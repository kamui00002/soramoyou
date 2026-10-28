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

import FirebaseFirestore
@testable import Soramoyou
import XCTest

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
            "p3": makePost("p3"), "p4": makePost("p4"),
        ]
        mock.failingPostIds = [
            "p2": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009)),
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
            "gone2": FirestoreServiceError.notFound,
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
        mock.allFavorites = makeFavorites((1 ... 16).map { "g\($0)" })
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
            "p3": makePost("p3"), "p4": makePost("p4"),
        ]
        mock.failingPostIds = [
            "p4": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009)),
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
            mock.allFavorites[1].createdAt, // 2回目 = 1ページ目末尾の p2
            mock.allFavorites[2].createdAt, // 3回目 = loadMore が切り詰めた位置の p3
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
            "p3": makePost("p3"), "p4": makePost("p4"),
        ]
        // 2ページ目の **先頭** p3 でつまずかせる（＝ consumed == 0）
        mock.failingPostIds = [
            "p3": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009)),
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
            mock.allFavorites[1].createdAt, // 2回目 = p2
            mock.allFavorites[1].createdAt, // ⭐️ 3回目も p2 のまま。進めると p3 が消える
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
        mock.allFavorites = makeFavorites(["p1"] + (0 ... 10).map { "g\($0)" } + ["p2"])
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2")]
        for index in 0 ... 10 {
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
            "p2": FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009)),
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
            mock.allFavorites[1].createdAt, // 2回目 = p2（ここで throw）
            mock.allFavorites[1].createdAt, // ⭐️ 3回目も p2。失敗した回はカーソルを進めない
        ]
        XCTAssertEqual(mock.receivedAfterValues, expectedCursors, "同じカーソルから読み直す")
    }

    // MARK: - 壊れたお気に入りドキュメントを飛ばしたページ ⭐️

    //
    // 本番の `fetchFavorites` は、変換に失敗したドキュメントを 1 件ずつ飛ばす（一覧全体は生かす）。
    // そのため満杯（limit 件）に読んだページでも、返る件数は limit を割る。
    // 「件数 == pageSize ＝ 続きあり」で判定すると、壊れた 1 件だけで続きを見失う。

    /// 16. 1ページ目に壊れたお気に入りがあっても、満杯まで読めていれば続きを読む ⭐️
    func testBrokenFavoriteInFirstPageKeepsHasMore() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(3) で切ると 1ページ目 = [p1, broken, p2]（満杯に読んだが、返るのは2件）、2ページ目 = [p3, p4]
        mock.allFavorites = makeFavorites(["p1", "broken", "p2", "p3", "p4"])
        mock.brokenFavoriteIds = ["broken"]
        mock.postsById = [
            "p1": makePost("p1"), "p2": makePost("p2"),
            "p3": makePost("p3"), "p4": makePost("p4"),
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 3)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])
        XCTAssertTrue(viewModel.hasMore, "満杯に読んだページなので続きがある（返った件数で判定しない）")
        XCTAssertFalse(viewModel.stalledWithMore, "1件以上出せているので行き詰まりではない")
        XCTAssertEqual(viewModel.unavailableCount, 0, "壊れたドキュメントは『非公開・削除』の脚注には数えない")

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3", "p4"], "壊れた1件の先も読める")
        XCTAssertFalse(viewModel.hasMore, "2ページ目は pageSize 未満しか読めなかったので終わり")
    }

    /// 17. 追加ページに壊れたお気に入りがあっても、その先を読む ⭐️
    func testBrokenFavoriteInLoadMorePageKeepsHasMore() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(3) で切ると 1ページ目 = [p1, p2, p3]、2ページ目 = [p4, broken, p5]（返るのは2件）、3ページ目 = [p6]
        mock.allFavorites = makeFavorites(["p1", "p2", "p3", "p4", "broken", "p5", "p6"])
        mock.brokenFavoriteIds = ["broken"]
        for id in ["p1", "p2", "p3", "p4", "p5", "p6"] {
            mock.postsById[id] = makePost(id)
        }
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 3)

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3", "p4", "p5"])
        XCTAssertTrue(viewModel.hasMore, "2ページ目も満杯に読めているので、まだ続きがある")

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3", "p4", "p5", "p6"])
        XCTAssertFalse(viewModel.hasMore)
    }

    /// 18. ページ丸ごと壊れていても、カーソルを進めて次のページを読む ⭐️
    ///
    /// ⚠️ 返る件数が 0 でも、壊れたドキュメントは **読んではいる**。カーソルを「変換できた最後の1件」で
    ///    決めると 1 歩も進まず、同じ壊れたページを予算いっぱい読み直して行き詰まる
    ///    （ボタンで続きを読んでも、また同じページから読み直すだけ）。
    func testAllBrokenPageAdvancesCursorToNextPage() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [p1, p2]、2ページ目 = [broken1, broken2]（返るのは0件）、3ページ目 = [p3]
        mock.allFavorites = makeFavorites(["p1", "p2", "broken1", "broken2", "p3"])
        mock.brokenFavoriteIds = ["broken1", "broken2"]
        mock.postsById = ["p1": makePost("p1"), "p2": makePost("p2"), "p3": makePost("p3")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2", "p3"], "壊れたページを越えて p3 まで辿り着く")
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertFalse(viewModel.stalledWithMore)
        let expectedCursors: [Date?] = [
            nil,
            mock.allFavorites[1].createdAt, // 2回目 = 1ページ目末尾の p2
            mock.allFavorites[3].createdAt, // ⭐️ 3回目 = 壊れた broken2。p2 に据え置くと同じページを読み直す
        ]
        XCTAssertEqual(mock.receivedAfterValues, expectedCursors, "壊れたドキュメントも読んだ位置として進める")
    }

    /// 19. 壊れたページが予算を超えて続いても、予算で止まり、続きから再開できる ⭐️
    ///
    /// 予算（1リクエスト5ページ）と `stalledWithMore` の振る舞いは、削除済みが続くとき（テスト10）と同じ。
    /// そのうえで、次の読み込みが **止まった位置の先から** 始まる（同じページを読み直さない）ことを見る。
    func testAllBrokenPagesStopAtPageBudgetAndResumeFromWhereStopped() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) × 8ページ = 16件、全件が壊れている。9回目の読み込みで0件＝終端
        mock.allFavorites = makeFavorites((1 ... 16).map { "broken\($0)" })
        mock.brokenFavoriteIds = Set(mock.allFavorites.map(\.postId))
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertEqual(mock.receivedAfterValues.count, 5, "無限には繰らない（1リクエストあたり5ページまで）")
        XCTAssertTrue(viewModel.hasMore, "予算切れ。続きが残っているのに『全部消えた』と断定しない")
        XCTAssertTrue(viewModel.stalledWithMore, "手動の導線を画面に出す必要がある状態")
        XCTAssertNil(viewModel.lastError, "壊れたドキュメントは一時的な失敗ではないので、エラー画面にはしない")

        // 手動ボタンから続きを読む
        await viewModel.loadMore()

        XCTAssertTrue(viewModel.posts.isEmpty)
        XCTAssertFalse(viewModel.hasMore, "最後まで読み切った")
        XCTAssertFalse(viewModel.stalledWithMore)
        // 2回目以降のカーソル = 各ページ末尾（broken2, broken4, …, broken16）
        let pageEndCursors: [Date?] = stride(from: 1, to: 16, by: 2).map { mock.allFavorites[$0].createdAt }
        XCTAssertEqual(
            mock.receivedAfterValues, [nil] + pageEndCursors,
            "各ページの末尾から1ページずつ進む（同じページを読み直さない）"
        )
    }

    // MARK: - 他人のお気に入り ⭐️

    //
    // 他人用（init(ownerId:viewerId:)）は、持ち主の favorites を読み、
    // 公開の投稿だけ・閲覧者がブロックしている人の投稿を除いて出す。件数は数えない・見せない。

    /// 他人用のテストで使う投稿（投稿者と公開範囲を選べる）
    private func makeOtherUserPost(_ id: String, author: String, visibility: Visibility) -> Post {
        Post(id: id, userId: author, images: [], visibility: visibility)
    }

    /// 20. 他人用は「公開」かつ「ブロックしていない人」の投稿だけが残る ⭐️
    func testOtherUserShowsOnlyPublicPostsFromUnblockedAuthors() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["pub1", "fol1", "priv1", "denied1", "blockedPub", "pub2"])
        mock.postsById = [
            "pub1": makeOtherUserPost("pub1", author: "a", visibility: .public),
            // 閲覧者が読めても（フォロワー限定・非公開）、他人用では出さない
            "fol1": makeOtherUserPost("fol1", author: "a", visibility: .followers),
            "priv1": makeOtherUserPost("priv1", author: "a", visibility: .private),
            "blockedPub": makeOtherUserPost("blockedPub", author: "blocked", visibility: .public),
            "pub2": makeOtherUserPost("pub2", author: "b", visibility: .public),
        ]
        // 第三者の非公開の投稿は、閲覧者には読めない（permission-denied）
        mock.failingPostIds = ["denied1": permissionDeniedError()]
        mock.blockedUserIds = ["blocked"]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["pub1", "pub2"])
        XCTAssertEqual(mock.receivedFavoritesUserIds, ["owner"], "favorites は持ち主の uid で読む")
        XCTAssertEqual(mock.receivedBlockedUserIdsQueries, ["viewer"], "ブロック一覧は閲覧者の uid で読む")
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isAccessRevoked)
        XCTAssertTrue(viewModel.isViewingOtherUser)
    }

    /// 21. 他人用は件数を数えない・見せない（本人用は今までどおり数える）⭐️
    ///
    /// 件数を出すと、フォロワーに「非公開・フォロワー限定のお気に入りが N 件ある」ことが分かってしまう。
    func testOtherUserNeverCountsOrShowsUnavailableCount() async {
        let otherMock = MockFirestoreServiceForFavoritesList()
        otherMock.allFavorites = makeFavorites(["gone", "denied"])
        otherMock.failingPostIds = [
            "gone": FirestoreServiceError.notFound,
            "denied": permissionDeniedError(),
        ]
        let other = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: otherMock, pageSize: 30)

        await other.load()

        XCTAssertEqual(other.posts.map(\.id), [])
        XCTAssertFalse(other.showsUnavailableCount, "他人用では件数を出してはいけない")
        XCTAssertEqual(other.unavailableCount, 0, "他人用では件数を数えない（View が分岐を漏らしても出ない）")
        XCTAssertFalse(other.hasMore)
        XCTAssertNil(other.lastError)

        // 対照: 本人用で同じ favorites なら、今までどおり 2 件と数えて見せる
        let ownMock = MockFirestoreServiceForFavoritesList()
        ownMock.allFavorites = makeFavorites(["gone", "denied"])
        ownMock.failingPostIds = [
            "gone": FirestoreServiceError.notFound,
            "denied": permissionDeniedError(),
        ]
        let own = FavoritesViewModel(ownUserId: "me", firestoreService: ownMock, pageSize: 30)

        await own.load()

        XCTAssertTrue(own.showsUnavailableCount)
        XCTAssertEqual(own.unavailableCount, 2)
        XCTAssertFalse(own.isViewingOtherUser)
    }

    /// 22. 他人の favorites の list が拒否されたら「見られなくなった」状態（汎用のエラーではない）⭐️
    func testOtherUserListPermissionDeniedShowsAccessRevoked() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1"])
        mock.postsById = ["p1": makeOtherUserPost("p1", author: "a", visibility: .public)]
        mock.fetchFavoritesFailure = (call: 1, error: permissionDeniedError())
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertTrue(viewModel.isAccessRevoked)
        XCTAssertNil(viewModel.lastError, "汎用のエラー画面（再試行）にしない")
        XCTAssertEqual(viewModel.posts.map(\.id), [])
        XCTAssertFalse(viewModel.hasMore)
    }

    /// 23. 続きを読む途中で拒否されたら、出ている一覧を消して「見られなくなった」にする。読み直して戻れる ⭐️
    func testOtherUserLoadMorePermissionDeniedClearsListAndRecoversOnReload() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2", "p3"])
        mock.postsById = [
            "p1": makeOtherUserPost("p1", author: "a", visibility: .public),
            "p2": makeOtherUserPost("p2", author: "a", visibility: .public),
            "p3": makeOtherUserPost("p3", author: "a", visibility: .public),
        ]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 2)

        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])

        // 見ている間に持ち主が OFF にした（2 回目の list が拒否される）
        mock.fetchFavoritesFailure = (call: 2, error: permissionDeniedError())
        await viewModel.loadMore()

        XCTAssertTrue(viewModel.isAccessRevoked)
        XCTAssertEqual(viewModel.posts.map(\.id), [], "持ち主が見せるのをやめたものを出し続けない")
        XCTAssertNil(viewModel.loadMoreError, "フッターの「再試行」にしない")
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.hasMore)

        // 持ち主が ON に戻した（拒否されなくなった）→ 読み直せば戻れる
        mock.fetchFavoritesFailure = nil
        await viewModel.load()

        XCTAssertFalse(viewModel.isAccessRevoked)
        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])
    }

    /// 24. 本人用の list の拒否は、今までどおり汎用のエラー（「見られなくなった」にしない）
    func testOwnListPermissionDeniedStaysGenericError() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1"])
        mock.postsById = ["p1": makePost("p1")]
        mock.fetchFavoritesFailure = (call: 1, error: permissionDeniedError())
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertNotNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isAccessRevoked)
    }

    /// 25. 他人用では、閲覧者の 🔖 の変化で一覧から消さない ⭐️
    ///
    /// FavoriteManager が持つのは閲覧者の 🔖。持ち主のお気に入りの一覧を、それで絞ってはいけない。
    func testOtherUserSyncFavoritedDoesNotRemovePosts() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1", "p2"])
        mock.postsById = [
            "p1": makeOtherUserPost("p1", author: "a", visibility: .public),
            "p2": makeOtherUserPost("p2", author: "a", visibility: .public),
        ]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 30)
        await viewModel.load()

        // 閲覧者はどちらにも 🔖 を付けていない
        viewModel.syncFavorited(ids: [])

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1", "p2"])
    }

    /// 26. 本人用はブロック一覧を読まない（読み取りの回数と振る舞いは今までどおり）
    func testOwnModeReadsOwnFavoritesAndNeverReadsBlockedUsers() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1"])
        mock.postsById = ["p1": makePost("p1")]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["p1"])
        XCTAssertEqual(mock.receivedFavoritesUserIds, ["me"])
        XCTAssertEqual(mock.receivedBlockedUserIdsQueries, [], "本人用ではブロック一覧を読まない")
    }

    /// 27. ブロック一覧が読めなくても、公開の投稿は出す（HomeViewModel.loadBlockedUsers と同じ考え方）
    func testOtherUserBlockedListFailureStillShowsPublicPosts() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["pub1", "fol1"])
        mock.postsById = [
            "pub1": makeOtherUserPost("pub1", author: "a", visibility: .public),
            "fol1": makeOtherUserPost("fol1", author: "a", visibility: .followers),
        ]
        mock.fetchBlockedUserIdsError = FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 30)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["pub1"])
        XCTAssertNil(viewModel.lastError, "ブロック一覧の失敗で一覧そのものをエラーにしない")
    }

    /// 28. 1ページ丸ごと絞り込みで落ちても、次のページまで繰る ⭐️
    ///
    /// 絞り込みは「消費はした（カーソルは進む）が表示しない」。カーソルが進まないと同じページを読み直し続ける。
    func testOtherUserAllFilteredPageAdvancesToNextPage() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [fol1, fol2]（全部フォロワー限定）、2ページ目 = [pub3]
        mock.allFavorites = makeFavorites(["fol1", "fol2", "pub3"])
        mock.postsById = [
            "fol1": makeOtherUserPost("fol1", author: "a", visibility: .followers),
            "fol2": makeOtherUserPost("fol2", author: "a", visibility: .followers),
            "pub3": makeOtherUserPost("pub3", author: "a", visibility: .public),
        ]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["pub3"])
        let expectedCursors: [Date?] = [nil, mock.allFavorites[1].createdAt]
        XCTAssertEqual(mock.receivedAfterValues, expectedCursors, "絞り込みで落ちた fol2 の位置から次のページを読む")
        XCTAssertFalse(viewModel.hasMore)
    }

    /// 29. 他人用の既定のページの大きさは 30（ルールの list の上限 `limit <= 30` と結びついている）⭐️
    func testOtherUserDefaultPageSizeIsThirty() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["p1"])
        mock.postsById = ["p1": makeOtherUserPost("p1", author: "a", visibility: .public)]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock)

        await viewModel.load()

        XCTAssertEqual(mock.receivedLimits, [30])
    }

    // MARK: - 他人用: 見せられる空が 1 件も無いページは自動で読み進める ⭐️ 1.18.0 PR-B

    //
    // 他人用は「公開・ブロック相手でない」投稿しか出さないので、持ち主が見せられないお気に入り
    // （フォロワー限定・非公開・削除済み・ブロック相手の投稿）が続くと、1 ページまるごと 0 件になりうる。
    // そこで「まだ続きがあります」だけを出すと、見せられないお気に入りが**ある**ことがフォロワーに伝わる。
    // 1 回の読み込みの中で、見せられる空が 1 件増えるまで（予算 5 ページまで）次のページを読む。
    // ⚠️ 本人用の「自動で次へ行かない」テストは書かない。本人用も以前から同じ予算で読み進めている
    //    （テスト 9・10・13・19 がその事実を固定している）。

    /// 30. 1 ページ目が全部見せられなくても、1 回の load で 2 ページ目の公開の空まで読む ⭐️ 1.18.0 PR-B
    func testOtherUserAutoAdvancesPastInvisiblePageToPublicPost() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(4) で切ると
        //   1ページ目 = [fol1, priv2, denied3, blocked4]（全部見せられない）
        //   2ページ目 = [pub5, fol6, fol7, fol8]（公開が 1 件・満杯に読めたので続きあり）
        //   3ページ目 = [pub9]（2ページ目で 1 件増えたので読まれないはず）
        mock.allFavorites = makeFavorites(["fol1", "priv2", "denied3", "blocked4", "pub5", "fol6", "fol7", "fol8", "pub9"])
        mock.postsById = [
            "fol1": makeOtherUserPost("fol1", author: "a", visibility: .followers),
            "priv2": makeOtherUserPost("priv2", author: "a", visibility: .private),
            "blocked4": makeOtherUserPost("blocked4", author: "blocked", visibility: .public),
            "pub5": makeOtherUserPost("pub5", author: "a", visibility: .public),
            "fol6": makeOtherUserPost("fol6", author: "a", visibility: .followers),
            "fol7": makeOtherUserPost("fol7", author: "a", visibility: .followers),
            "fol8": makeOtherUserPost("fol8", author: "a", visibility: .followers),
            "pub9": makeOtherUserPost("pub9", author: "a", visibility: .public),
        ]
        // 第三者の非公開の投稿は、閲覧者には読めない（permission-denied）
        mock.failingPostIds = ["denied3": permissionDeniedError()]
        mock.blockedUserIds = ["blocked"]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 4)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["pub5"])
        XCTAssertEqual(mock.receivedAfterValues.count, 2, "favorites の list は 2 回（1 件見せられた 2 ページ目で止まる）")
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertFalse(viewModel.stalledWithMore, "1 件増えたので行き詰まりではない")
        XCTAssertNil(viewModel.lastError)
    }

    /// 31. 全ページ見せられず、続きも無ければ、空の一覧で終わる（「まだ続きがあります」にしない）⭐️ 1.18.0 PR-B
    func testOtherUserAllInvisiblePagesWithoutMoreEndsEmpty() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [fol1, priv2]（満杯）、2ページ目 = [denied3]（pageSize 未満＝終端）
        mock.allFavorites = makeFavorites(["fol1", "priv2", "denied3"])
        mock.postsById = [
            "fol1": makeOtherUserPost("fol1", author: "a", visibility: .followers),
            "priv2": makeOtherUserPost("priv2", author: "a", visibility: .private),
        ]
        mock.failingPostIds = ["denied3": permissionDeniedError()]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), [])
        XCTAssertFalse(viewModel.hasMore, "続きは無い")
        XCTAssertFalse(viewModel.stalledWithMore)
        XCTAssertEqual(mock.receivedAfterValues.count, 2)
        XCTAssertNil(viewModel.lastError)
        XCTAssertFalse(viewModel.isAccessRevoked)
    }

    /// 32. 見せられないページが上限より多く続いても、list はちょうど上限の回数で止まり、続きは残す ⭐️ 1.18.0 PR-B
    func testOtherUserInvisiblePagesStopAtPageBudget() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) × 6ページ = 12件。全部フォロワー限定（予算 5 ページより多い）
        mock.allFavorites = makeFavorites((1 ... 12).map { "fol\($0)" })
        for favorite in mock.allFavorites {
            mock.postsById[favorite.postId] = makeOtherUserPost(favorite.postId, author: "a", visibility: .followers)
        }
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(mock.receivedAfterValues.count, 5, "1 回の読み込みで読むのは 5 ページまで")
        XCTAssertEqual(viewModel.posts.map(\.id), [])
        XCTAssertTrue(viewModel.hasMore, "予算切れ。続きが残っているのに『無い』と断定しない")
        XCTAssertTrue(viewModel.stalledWithMore)
    }

    /// 33. 1 ページ目で 1 件でも見せられたら、そこで止まる（次のページを先に読まない）⭐️ 1.18.0 PR-B
    func testOtherUserStopsAfterFirstPageWithPublicPost() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [pub1, fol2]（公開が 1 件・満杯なので続きあり）、2ページ目 = [pub3]
        mock.allFavorites = makeFavorites(["pub1", "fol2", "pub3"])
        mock.postsById = [
            "pub1": makeOtherUserPost("pub1", author: "a", visibility: .public),
            "fol2": makeOtherUserPost("fol2", author: "a", visibility: .followers),
            "pub3": makeOtherUserPost("pub3", author: "a", visibility: .public),
        ]
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(viewModel.posts.map(\.id), ["pub1"])
        XCTAssertEqual(mock.receivedAfterValues.count, 1)
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertFalse(viewModel.stalledWithMore)
    }

    /// 34. 自動で読み進めた先の list が拒否されたら、1 ページ目で拒否されたときと同じく「見られなくなった」⭐️ 1.18.0 PR-B
    func testOtherUserPermissionDeniedOnAutoAdvancedPageShowsAccessRevoked() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [fol1, fol2]（全部見せられない）→ 2 回目の list が拒否される
        mock.allFavorites = makeFavorites(["fol1", "fol2", "pub3"])
        mock.postsById = [
            "fol1": makeOtherUserPost("fol1", author: "a", visibility: .followers),
            "fol2": makeOtherUserPost("fol2", author: "a", visibility: .followers),
            "pub3": makeOtherUserPost("pub3", author: "a", visibility: .public),
        ]
        mock.fetchFavoritesFailure = (call: 2, error: permissionDeniedError())
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(mock.receivedAfterValues.count, 2)
        XCTAssertTrue(viewModel.isAccessRevoked)
        XCTAssertNil(viewModel.lastError, "汎用のエラー画面（再試行）にしない")
        XCTAssertEqual(viewModel.posts.map(\.id), [])
        XCTAssertFalse(viewModel.hasMore)
    }

    /// 35. 自動で読み進めた先の list が通信で失敗したら、1 ページ目で失敗したときと同じく汎用のエラー ⭐️ 1.18.0 PR-B
    func testOtherUserTransientFailureOnAutoAdvancedPageSurfacesError() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [fol1, fol2]（全部見せられない）→ 2 回目の list が通信エラー
        mock.allFavorites = makeFavorites(["fol1", "fol2", "pub3"])
        mock.postsById = [
            "fol1": makeOtherUserPost("fol1", author: "a", visibility: .followers),
            "fol2": makeOtherUserPost("fol2", author: "a", visibility: .followers),
            "pub3": makeOtherUserPost("pub3", author: "a", visibility: .public),
        ]
        mock.fetchFavoritesFailure = (
            call: 2,
            error: FirestoreServiceError.fetchFailed(NSError(domain: NSURLErrorDomain, code: -1009))
        )
        let viewModel = FavoritesViewModel(ownerId: "owner", viewerId: "viewer", firestoreService: mock, pageSize: 2)

        await viewModel.load()

        XCTAssertEqual(mock.receivedAfterValues.count, 2)
        XCTAssertNotNil(viewModel.lastError, "『0件』と嘘をつかずエラーにする")
        XCTAssertFalse(viewModel.isAccessRevoked, "通信の失敗は「見られなくなった」にしない")
        XCTAssertEqual(viewModel.posts.map(\.id), [])
    }

    // MARK: - 他人用: 投稿詳細でのブロック（.userBlocked 通知）⭐️ 1.18.0 PR-B

    //
    // 他人のお気に入りの一覧から投稿を開いて投稿者をブロックしたら、引っ張って更新を待たずに一覧から消す。
    // 以降に読むページからも除く（ホーム・ギャラリー・タグ・あなた向けと同じ）。

    /// 36. 他人用: X をブロックしたら、表示中の一覧から X の投稿が消え、続きを読んでも X は出ない ⭐️ 1.18.0 PR-B
    func testOtherUserBlockedNotificationRemovesAuthorFromListAndLaterPages() async {
        let mock = MockFirestoreServiceForFavoritesList()
        // pageSize(2) で切ると 1ページ目 = [x1, y1]、2ページ目 = [x2, y2]（2ページ目が終端かは3回目の読み込みで分かる）
        mock.allFavorites = makeFavorites(["x1", "y1", "x2", "y2"])
        mock.postsById = [
            "x1": makeOtherUserPost("x1", author: "X", visibility: .public),
            "y1": makeOtherUserPost("y1", author: "Y", visibility: .public),
            "x2": makeOtherUserPost("x2", author: "X", visibility: .public),
            "y2": makeOtherUserPost("y2", author: "Y", visibility: .public),
        ]
        // 他のテストが `.default` に送る通知と混ざらないよう、このテストだけの通知センターを使う
        let center = NotificationCenter()
        let viewModel = FavoritesViewModel(
            ownerId: "owner",
            viewerId: "viewer",
            firestoreService: mock,
            pageSize: 2,
            notificationCenter: center
        )
        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["x1", "y1"], "前提: ブロック前は X と Y の両方が出ている")

        center.post(name: .userBlocked, object: nil, userInfo: [Notification.blockedUserIdKey: "X"])
        await waitForMainActorTasks { viewModel.posts.map(\.id) == ["y1"] }

        XCTAssertEqual(viewModel.posts.map(\.id), ["y1"], "引っ張って更新を待たずに、表示中の一覧から X を除く")

        await viewModel.loadMore()

        XCTAssertEqual(viewModel.posts.map(\.id), ["y1", "y2"], "続きのページからも X を除く")
        XCTAssertEqual(mock.receivedAfterValues.count, 2)
    }

    /// 37. 本人用: `.userBlocked` を受けても一覧は変わらない（本人用は購読しない＝今までどおり）⭐️ 1.18.0 PR-B
    ///
    /// 本人用は「自分が 🔖 を付けた空のアルバム」。投稿者をブロックしてもお気に入りが消えるわけではない。
    func testOwnUserBlockedNotificationDoesNotChangeList() async {
        let mock = MockFirestoreServiceForFavoritesList()
        mock.allFavorites = makeFavorites(["x1", "y1"])
        mock.postsById = [
            "x1": makeOtherUserPost("x1", author: "X", visibility: .public),
            "y1": makeOtherUserPost("y1", author: "Y", visibility: .public),
        ]
        let viewModel = FavoritesViewModel(ownUserId: "me", firestoreService: mock, pageSize: 30)
        await viewModel.load()
        XCTAssertEqual(viewModel.posts.map(\.id), ["x1", "y1"])

        // 本人用の init は通知センターを受け取らない（購読するなら `.default`）ので、`.default` に送る
        NotificationCenter.default.post(name: .userBlocked, object: nil, userInfo: [Notification.blockedUserIdKey: "X"])
        // 受け取った場合の処理（MainActor 上の Task）が走りきるだけの時間を与える（条件は満たされないので上限まで譲る）
        await waitForMainActorTasks { false }

        XCTAssertEqual(viewModel.posts.map(\.id), ["x1", "y1"], "本人用ではブロックした人の投稿も今までどおり出す")
        XCTAssertEqual(mock.receivedBlockedUserIdsQueries, [], "本人用ではブロック一覧も読まない")
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
    /// 壊れていて変換に失敗するお気に入りの postId ⭐️
    ///
    /// 本番の `fetchFavorites` は、変換に失敗したドキュメントを 1 件ずつ飛ばす。
    /// ただしクエリの `limit` には数えられる（＝読んだ件数には入る）ので、返る件数は limit を割る。
    var brokenFavoriteIds: Set<String> = []
    /// fetchFavorites に渡された `userId`（＝読んだ favorites の持ち主）の記録 ⭐️
    ///
    /// ⚠️ 他人用で「持ち主の uid で読む」ことを直に確かめるため。閲覧者の uid と取り違えても、
    ///    Mock は uid を見ずに同じ `allFavorites` を返すので、記録を見ないと緑のまま通ってしまう。
    private(set) var receivedFavoritesUserIds: [String] = []
    /// fetchFavorites に渡された `limit` の記録（他人用の既定のページの大きさ＝ルールの上限 30 を固定する）
    private(set) var receivedLimits: [Int] = []
    /// 閲覧者のブロック一覧（`fetchBlockedUserIds` が返す）
    var blockedUserIds: [String] = []
    /// `fetchBlockedUserIds` を失敗させるときのエラー
    var fetchBlockedUserIdsError: Error?
    /// fetchBlockedUserIds に渡された `userId`（＝閲覧者）の記録。本人用では 1 回も呼ばれないことも見る
    private(set) var receivedBlockedUserIdsQueries: [String] = []

    func fetchFavorites(userId: String, limit: Int, after: Date?) async throws -> FavoritePage {
        receivedFavoritesUserIds.append(userId)
        receivedLimits.append(limit)
        receivedAfterValues.append(after)
        // 何回目の呼び出しかは記録した件数で数える（＝失敗した回も1回として数える）
        if let failure = fetchFavoritesFailure, failure.call == receivedAfterValues.count {
            throw failure.error
        }
        // start(after:) 相当。降順なので「カーソルより古いもの」を返し、同値は含まない。
        let remaining = after.map { cursor in
            allFavorites.filter { $0.createdAt < cursor }
        } ?? allFavorites
        // limit 件読んでから、壊れたものを飛ばす（本番と同じ順序）
        let read = Array(remaining.prefix(limit))
        // 本番（FavoritePage(favorites:snapshot:limit:)）と同じく、起点と続きの有無は読んだドキュメントで決める
        return FavoritePage(
            favorites: read.filter { !brokenFavoriteIds.contains($0.postId) },
            lastReadCreatedAt: read.last?.createdAt,
            isExhausted: read.count < limit
        )
    }

    func fetchPost(postId: String) async throws -> Post {
        if let error = failingPostIds[postId] { throw error }
        guard let post = postsById[postId] else { throw FirestoreServiceError.notFound }
        return post
    }

    func fetchBlockedUserIds(userId: String) async throws -> [String] {
        receivedBlockedUserIdsQueries.append(userId)
        if let fetchBlockedUserIdsError { throw fetchBlockedUserIdsError }
        return blockedUserIds
    }
}
