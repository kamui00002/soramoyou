//
//  DailyPickViewModelTests.swift
//  SoramoyouTests
//
//  ホーム「すべて」の「今日のおすすめのそらもよう」カードの状態（DailyPickViewModel）のテスト ⭐️
//
//  見ること: 今日の文書 → 無ければ前日の文書 → ログイン中だけブロック一覧 → 候補を先頭から 1 件ずつ、の順番と、
//  「次へ」「止める」の分け方、ゲストは読まないもの、`.userBlocked` を受けたときの差し替え、計装の 1 回と中身。
//  ⚠️ 「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。
//
//  固定の時刻: 2026-10-26T01:00:00Z（JST 10:00）→ 今日の鍵 "2026-10-26"・前日の鍵 "2026-10-25"
//  （鍵の作り方は DailyPickKey。ここでは期待する鍵を直に書く）
//
//  陽性対照（2026-10-26 予定・メインが流して記録する）:
//  ① DailyPickViewModel.outcome(for:) が DailyPickResolver.classify(post:blockedUserIds:) に渡す Set を
//     常に空（blockedUserIds: []）にする
//     → 赤になるはずのテスト:
//        testSkipsFirstCandidateByBlockedAuthor
//        testUserBlockedNotificationMovesToNextCandidate
//        testUserBlockedNotificationWithNoMoreCandidatesHidesCard
//  ② resolveLoad で今日の文書の読み取りが throw したとき、return .failed をやめて前日の文書へ回す
//     （catch で todayPick = nil にする）
//     → 赤になるはずのテスト:
//        testTodayDocumentReadFailureDoesNotFallBack
//  結果（2026-10-26・iPhone 18 Pro シミュレーター）: ① と ② を同じ組み直しで入れて、予言の 4 本だけが赤（20 本中 4 本）。
//  ほかの 16 本は緑。同じ組み直しで DailyPickKey.switchHourJST も 0 にしたが、このクラスの固定の時刻（JST 10:00）では
//  鍵が変わらない。壊す前（同じ中身）は 20 本すべて緑
//
//  陽性対照 ③（2026-10-27・投稿者の写真を足したとき）:
//  DailyPickViewModel.fetchAuthor の photoURL を `profile.photoURL.map { _ in "wrong" }` にする
//  （写真があれば別の値、空白だけでも nil にしない）
//     → 赤になるはずのテスト:
//        testShowsFirstCandidateOfToday
//        testUserBlockedNotificationMovesToNextCandidate
//        testBlankNameStillKeepsPhoto
//        testBlankPhotoURLBecomesNil
//  結果（2026-10-27・iPhone 18 Pro シミュレーター）: 予言の 4 本だけが赤（22 本中 4 本）。ほかの 18 本は緑。
//  Edit で戻して指紋（shasum）が壊す前と一致することを確かめ、戻した中身で 22 本すべて緑
//
//  陽性対照 ④（2026-10-28・レビュー D1＝ブロックを受けたら次の候補を探す前に下げる）:
//  DailyPickViewModel.handleUserBlocked の、進行中かどうかを見る前の hide() を消す
//     → 赤になるはずのテスト:
//        testCardIsHiddenWhileWaitingForNextCandidateAfterBlock
//  （ほかは緑のまま: 次の候補が無い・一時失敗のときは、探し終わった後の hide() が下げる）
//  結果（2026-10-28・iPhone 18 Pro シミュレーター）: 予言の 1 本だけが赤（23 本中 1 本）。ほかの 22 本は緑。
//  Edit で戻して指紋（shasum）が壊す前と一致することを確かめ、戻した中身で 23 本すべて緑
//
//  陽性対照 ⑤（2026-10-28・レビュー D7＝item を残した一時失敗では unavailable を送らない）:
//  DailyPickViewModel.load の .failed の `if item == nil {` を `do {` にする（いつでも送る＝直す前と同じ）
//     → 赤になるはずのテスト:
//        testLoadFailureThatKeepsItemDoesNotSendUnavailable
//  （ほかは緑のまま: ほかの load_failed のテストは、どれも item が nil のまま失敗する）
//  結果（2026-10-28・iPhone 18 Pro シミュレーター）: 予言の 1 本だけが赤（24 本中 1 本）。ほかの 23 本は緑。
//  Edit で戻して指紋（shasum）が壊す前と一致することを確かめ、戻した中身で 24 本すべて緑
//

@testable import Soramoyou
import XCTest

@MainActor
final class DailyPickViewModelTests: XCTestCase {
    /// 2026-10-26T01:00:00Z（JST 10:00）
    private static let fixedNow = Date(timeIntervalSince1970: 1_792_976_400)

    /// shown・tapped に許すパラメータのキー（uid・名前・キャプションが無いことの確認に使う）
    private static let itemParameterKeys: Set<String> = [
        "date_key", "candidate_index", "is_fallback_day", "is_guest", "is_own_post",
    ]

    // MARK: - 1. 今日の 1 件目が出る

    func testShowsFirstCandidateOfToday() async throws {
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1", "p2"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo"), "p2": makePost("p2", owner: "sora")]
        fixture.firestore.displayNames = ["kumo": "くも"]
        fixture.firestore.photoURLs = ["kumo": "https://example.com/kumo.jpg"]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p1")
        XCTAssertEqual(item.dateKey, "2026-10-26")
        XCTAssertEqual(item.candidateIndex, 0)
        XCTAssertFalse(item.isFallbackDay)
        XCTAssertEqual(item.authorName, "くも", "ログイン中は投稿者の名前が入る")
        XCTAssertEqual(item.authorPhotoURL, "https://example.com/kumo.jpg", "ログイン中は投稿者の写真も入る")
        XCTAssertEqual(fixture.firestore.requestedProfileIds, ["kumo"], "名前と写真は同じ 1 件の読み取りで取る")
        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26"], "今日の文書があれば前日は読まない")
        XCTAssertEqual(fixture.firestore.requestedPostIds, ["p1"], "1 件目で決まれば 2 件目は読まない")

        let shown = fixture.logger.parameters(of: "daily_pick_shown")
        XCTAssertEqual(shown.count, 1)
        let parameters = try XCTUnwrap(shown.first)
        XCTAssertEqual(parameters["date_key"] as? String, "2026-10-26")
        XCTAssertEqual(parameters["candidate_index"] as? Int, 0)
        XCTAssertEqual(parameters["is_fallback_day"] as? Bool, false)
        XCTAssertEqual(parameters["is_guest"] as? Bool, false)
        XCTAssertEqual(parameters["is_own_post"] as? Bool, false)
    }

    // MARK: - 2. 今日が無く前日が出る

    func testFallsBackToYesterdayWhenTodayHasNoDocument() async throws {
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-25": DailyPick(dateKey: "2026-10-25", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p1")
        XCTAssertEqual(item.dateKey, "2026-10-25", "出している文書（前日）の鍵")
        XCTAssertEqual(item.candidateIndex, 0)
        XCTAssertTrue(item.isFallbackDay)
        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26", "2026-10-25"])

        let parameters = try XCTUnwrap(fixture.logger.parameters(of: "daily_pick_shown").first)
        XCTAssertEqual(parameters["date_key"] as? String, "2026-10-25")
        XCTAssertEqual(parameters["is_fallback_day"] as? Bool, true)
    }

    // MARK: - 3. 1 件目が出せなければ 2 件目

    func testSkipsDeletedFirstCandidate() async throws {
        // 1 件目は posts に無い＝ notFound（削除済み）
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["gone", "p2"])]
        fixture.firestore.posts = ["p2": makePost("p2", owner: "sora")]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p2")
        XCTAssertEqual(item.candidateIndex, 1)
        XCTAssertEqual(fixture.firestore.requestedPostIds, ["gone", "p2"])
    }

    func testSkipsFollowersOnlyFirstCandidate() async throws {
        // フォロー中なら followers の投稿も読めてしまうが、カードには公開の投稿しか出さない
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1", "p2"])]
        fixture.firestore.posts = [
            "p1": makePost("p1", owner: "kumo", visibility: .followers),
            "p2": makePost("p2", owner: "sora"),
        ]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p2")
        XCTAssertEqual(item.candidateIndex, 1)
    }

    func testSkipsPrivateFirstCandidate() async throws {
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1", "p2"])]
        fixture.firestore.posts = [
            "p1": makePost("p1", owner: "kumo", visibility: .private),
            "p2": makePost("p2", owner: "sora"),
        ]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p2")
        XCTAssertEqual(item.candidateIndex, 1)
    }

    func testSkipsFirstCandidateByBlockedAuthor() async throws {
        // 陽性対照 ① で赤になるはず（ブロック済みの Set を空にすると 1 件目の p1 が出る）
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1", "p2"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "troll"), "p2": makePost("p2", owner: "sora")]
        fixture.firestore.blockedUserIdsByViewer = ["viewer": ["troll"]]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p2", "見ている人がブロックしている投稿者の投稿は出さない")
        XCTAssertEqual(item.candidateIndex, 1)
        XCTAssertEqual(fixture.firestore.blockedListRequestCount, 1)
    }

    // MARK: - 4. 1 件目が一時失敗なら出さない

    func testStopsWithoutShowingWhenFirstCandidateFailsTransiently() async throws {
        // 代役に回すと「全員に同じ 1 枚」が崩れるので、そこで止める
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1", "p2"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo"), "p2": makePost("p2", owner: "sora")]
        fixture.firestore.transientFailurePostIds = ["p1"]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        XCTAssertNil(viewModel.item)
        XCTAssertEqual(fixture.firestore.requestedPostIds, ["p1"], "2 件目の fetchPost は呼ばない")
        XCTAssertTrue(fixture.logger.parameters(of: "daily_pick_shown").isEmpty)
        let unavailable = fixture.logger.parameters(of: "daily_pick_unavailable")
        XCTAssertEqual(unavailable.count, 1)
        let parameters = try XCTUnwrap(unavailable.first)
        XCTAssertEqual(parameters["reason"] as? String, "load_failed")
        XCTAssertEqual(parameters["date_key"] as? String, "2026-10-26")
        XCTAssertEqual(parameters["is_guest"] as? Bool, false)
    }

    // MARK: - 5. 両日とも無ければ出さない

    func testShowsNothingWhenNeitherDayHasDocument() async throws {
        let fixture = makeFixture()
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        XCTAssertNil(viewModel.item)
        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26", "2026-10-25"])
        XCTAssertEqual(fixture.firestore.blockedListRequestCount, 0, "文書が無ければブロック一覧も読まない")
        XCTAssertTrue(fixture.firestore.requestedPostIds.isEmpty)

        let unavailable = fixture.logger.parameters(of: "daily_pick_unavailable")
        XCTAssertEqual(unavailable.count, 1)
        let parameters = try XCTUnwrap(unavailable.first)
        XCTAssertEqual(parameters["reason"] as? String, "no_document")
        XCTAssertEqual(parameters["date_key"] as? String, "2026-10-26", "unavailable の date_key は今日の鍵")
        XCTAssertEqual(Set(parameters.keys), ["reason", "date_key", "is_guest"])
    }

    // MARK: - 6. ゲストはブロック一覧と名前を取りに行かない

    func testGuestDoesNotReadBlockListOrAuthorName() async throws {
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        fixture.firestore.displayNames = ["kumo": "くも"]
        fixture.firestore.photoURLs = ["kumo": "https://example.com/kumo.jpg"]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: nil)

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p1")
        XCTAssertNil(item.authorName, "ゲストは publicProfiles を読めないので名前は出さない")
        XCTAssertNil(item.authorPhotoURL, "ゲストは写真も出さない（カードは人の形の印）")
        XCTAssertEqual(fixture.firestore.blockedListRequestCount, 0)
        XCTAssertTrue(fixture.firestore.requestedProfileIds.isEmpty)

        let parameters = try XCTUnwrap(fixture.logger.parameters(of: "daily_pick_shown").first)
        XCTAssertEqual(parameters["is_guest"] as? Bool, true)
        XCTAssertEqual(parameters["is_own_post"] as? Bool, false)
    }

    // MARK: - 7. .userBlocked で次へ

    func testUserBlockedNotificationMovesToNextCandidate() async throws {
        // 陽性対照 ① で赤になるはず（Set を空にすると、表示中の投稿が「まだ出せる」に見えて差し替わらない）
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1", "p2"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo"), "p2": makePost("p2", owner: "sora")]
        fixture.firestore.displayNames = ["kumo": "くも", "sora": "そら"]
        fixture.firestore.photoURLs = ["kumo": "https://example.com/kumo.jpg", "sora": "https://example.com/sora.jpg"]
        let viewModel = makeViewModel(fixture)
        await viewModel.load(viewerId: "viewer")
        XCTAssertEqual(viewModel.item?.post.id, "p1", "前提: ブロック前は 1 件目が出ている")

        postUserBlocked("kumo", on: fixture.center)
        await waitUntil { viewModel.item?.post.id == "p2" }

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.post.id, "p2")
        XCTAssertEqual(item.candidateIndex, 1)
        XCTAssertEqual(item.dateKey, "2026-10-26")
        XCTAssertEqual(item.authorName, "そら", "差し替えた投稿にも名前を付ける")
        XCTAssertEqual(item.authorPhotoURL, "https://example.com/sora.jpg", "写真も差し替えた投稿の人のものにする")
        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26"], "文書は読み直さない")
        XCTAssertEqual(fixture.logger.parameters(of: "daily_pick_shown").count, 1, "同じ date_key なので shown は 1 回のまま")
    }

    func testUserBlockedNotificationWithNoMoreCandidatesHidesCard() async throws {
        // 陽性対照 ① で赤になるはず（Set を空にすると、表示中の投稿が下がらない）
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        let viewModel = makeViewModel(fixture)
        await viewModel.load(viewerId: "viewer")
        XCTAssertEqual(viewModel.item?.post.id, "p1", "前提: ブロック前は 1 件目が出ている")

        postUserBlocked("kumo", on: fixture.center)
        await waitUntil { viewModel.item == nil }

        XCTAssertNil(viewModel.item, "次の候補が無ければカードを下げる")
        let unavailable = fixture.logger.parameters(of: "daily_pick_unavailable")
        XCTAssertEqual(unavailable.count, 1)
        XCTAssertEqual(unavailable.first?["reason"] as? String, "all_skipped")
        XCTAssertEqual(unavailable.first?["date_key"] as? String, "2026-10-26")
    }

    func testCardIsHiddenWhileWaitingForNextCandidateAfterBlock() async throws {
        // 陽性対照 ④ で赤になるはず（先に下げないと、次の候補を待っている間ブロックした人の p1 が出たまま押せる）
        let fixture = makeFixture()
        let firestore = fixture.firestore
        addTeardownBlock { firestore.releaseAll() }
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1", "p2"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo"), "p2": makePost("p2", owner: "sora")]
        let viewModel = makeViewModel(fixture)
        await viewModel.load(viewerId: "viewer")
        XCTAssertEqual(viewModel.item?.post.id, "p1", "前提: ブロック前は 1 件目が出ている")

        fixture.firestore.holdPostFetch("p2")
        postUserBlocked("kumo", on: fixture.center)
        await waitUntil { firestore.isHoldingPostFetch("p2") }
        XCTAssertTrue(firestore.isHoldingPostFetch("p2"), "前提: 次の候補（p2）の取得で止まっている")

        XCTAssertNil(viewModel.item, "次の候補を待っている間も、ブロックした人の投稿は出さない")

        firestore.releasePostFetch("p2")
        await waitUntil { viewModel.item?.post.id == "p2" }
        XCTAssertEqual(viewModel.item?.post.id, "p2", "次の候補が取れたら出す")
        XCTAssertEqual(viewModel.item?.candidateIndex, 1)
    }

    // MARK: - 8. 同じ鍵では取り直さない・force は取り直す

    func testSameKeyIsNotRefetched() async {
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")
        await viewModel.load(viewerId: "viewer")

        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26"], "2 回目の load では文書を読まない")
        XCTAssertEqual(fixture.firestore.requestedPostIds, ["p1"])
        XCTAssertEqual(fixture.firestore.blockedListRequestCount, 1)
        XCTAssertEqual(viewModel.item?.post.id, "p1")
    }

    func testNoDocumentIsNotRefetchedWithSameKey() async {
        // 「出すものが無いと確定」も取り直さない
        let fixture = makeFixture()
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")
        await viewModel.load(viewerId: "viewer")

        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26", "2026-10-25"])
    }

    func testForceRefetches() async {
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")
        await viewModel.load(viewerId: "viewer", force: true)

        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26", "2026-10-26"])
        XCTAssertEqual(fixture.firestore.requestedPostIds, ["p1", "p1"])
        XCTAssertEqual(fixture.logger.parameters(of: "daily_pick_shown").count, 1, "取り直しても shown は 1 回")
    }

    // MARK: - 9. shown は同じ date_key で 1 回だけ

    func testShownIsSentOncePerDateKeyAcrossViewModels() async {
        // タブの切り替えでホーム（＝VM）が作り直されても、同じ記録係なら重ねて送らない
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]

        let first = makeViewModel(fixture)
        await first.load(viewerId: "viewer")
        let second = makeViewModel(fixture)
        await second.load(viewerId: "viewer")

        XCTAssertEqual(second.item?.post.id, "p1", "作り直した VM でもカードは出る")
        XCTAssertEqual(fixture.service.requestedKeys.count, 2, "前提: 2 つの VM がそれぞれ読み込んだ")
        XCTAssertEqual(fixture.logger.parameters(of: "daily_pick_shown").count, 1)
    }

    // MARK: - 10. 今日の文書の読み取りが一時失敗なら前日に回らない

    func testTodayDocumentReadFailureDoesNotFallBack() async throws {
        // 陽性対照 ② で赤になるはず（前日へ回ると前日の p1 が出る）
        let fixture = makeFixture()
        fixture.service.errorsByKey = ["2026-10-26": URLError(.notConnectedToInternet)]
        fixture.service.picksByKey = ["2026-10-25": DailyPick(dateKey: "2026-10-25", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        XCTAssertNil(viewModel.item)
        XCTAssertEqual(fixture.service.requestedKeys, ["2026-10-26"], "前日の鍵では読まない")
        XCTAssertTrue(fixture.firestore.requestedPostIds.isEmpty)
        let unavailable = fixture.logger.parameters(of: "daily_pick_unavailable")
        XCTAssertEqual(unavailable.count, 1)
        let parameters = try XCTUnwrap(unavailable.first)
        XCTAssertEqual(parameters["reason"] as? String, "load_failed")
    }

    // MARK: - そのほかの決まり

    func testShownAndTappedParametersHaveOnlyTheAllowedKeys() async throws {
        // uid・名前・キャプションを送らない（キーの集合を直に書いて比べる）
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "viewer", caption: "朝焼け")]
        fixture.firestore.displayNames = ["viewer": "わたし"]
        let viewModel = makeViewModel(fixture)
        await viewModel.load(viewerId: "viewer")

        viewModel.recordTapped()
        viewModel.recordTapped()

        let shown = try XCTUnwrap(fixture.logger.parameters(of: "daily_pick_shown").first)
        XCTAssertEqual(Set(shown.keys), Self.itemParameterKeys)
        let tapped = fixture.logger.parameters(of: "daily_pick_tapped")
        XCTAssertEqual(tapped.count, 2, "tapped はタップのたびに送る")
        let firstTapped = try XCTUnwrap(tapped.first)
        XCTAssertEqual(Set(firstTapped.keys), Self.itemParameterKeys)
        XCTAssertEqual(firstTapped["is_own_post"] as? Bool, true, "自分の投稿が選ばれた日")
    }

    func testTappedWithoutItemSendsNothing() async {
        let fixture = makeFixture()
        let viewModel = makeViewModel(fixture)
        await viewModel.load(viewerId: "viewer")

        viewModel.recordTapped()

        XCTAssertTrue(fixture.logger.parameters(of: "daily_pick_tapped").isEmpty)
    }

    func testLoadFailureKeepsShownItemAndRetriesNextTime() async {
        // 引っ張って更新の一時失敗でカードを消さない。失敗の後は次の呼び出しで取り直す
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        let viewModel = makeViewModel(fixture)
        await viewModel.load(viewerId: "viewer")

        fixture.firestore.transientFailurePostIds = ["p1"]
        await viewModel.load(viewerId: "viewer", force: true)
        XCTAssertEqual(viewModel.item?.post.id, "p1", "一時失敗では出している item を消さない")

        fixture.firestore.transientFailurePostIds = []
        await viewModel.load(viewerId: "viewer")
        XCTAssertEqual(fixture.service.requestedKeys.count, 3, "load_failed の後は force でなくても取り直す")
        XCTAssertEqual(viewModel.item?.post.id, "p1")
    }

    func testLoadFailureThatKeepsItemDoesNotSendUnavailable() async {
        // 陽性対照 ⑤ で赤になるはず（item を残したまま unavailable "load_failed" を送ってしまう）
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        let viewModel = makeViewModel(fixture)
        await viewModel.load(viewerId: "viewer")
        XCTAssertEqual(viewModel.item?.post.id, "p1", "前提: 1 件目が出ている")

        fixture.firestore.transientFailurePostIds = ["p1"]
        await viewModel.load(viewerId: "viewer", force: true)

        XCTAssertEqual(viewModel.item?.post.id, "p1", "前提: 一時失敗では出している item を残す")
        XCTAssertTrue(
            fixture.logger.parameters(of: "daily_pick_unavailable").isEmpty,
            "カードが出ているので「出せなかった」は送らない"
        )
    }

    func testBlockListFailureStopsWithoutShowing() async throws {
        // ブロック一覧が読めないまま出すと、ブロック中の人の投稿を出してしまうかもしれない
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        fixture.firestore.blockListError = URLError(.notConnectedToInternet)
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        XCTAssertNil(viewModel.item)
        XCTAssertTrue(fixture.firestore.requestedPostIds.isEmpty, "候補を取りに行かない")
        let parameters = try XCTUnwrap(fixture.logger.parameters(of: "daily_pick_unavailable").first)
        XCTAssertEqual(parameters["reason"] as? String, "load_failed")
    }

    func testBlankNameStillKeepsPhoto() async throws {
        // 名前と写真は別々に nil になる（名前が空白だけでも写真は出す）
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        fixture.firestore.displayNames = ["kumo": "  \n"]
        fixture.firestore.photoURLs = ["kumo": "https://example.com/kumo.jpg"]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertNil(item.authorName, "空白だけの名前は nil（カードは「ユーザー」）")
        XCTAssertEqual(item.authorPhotoURL, "https://example.com/kumo.jpg")
    }

    func testBlankPhotoURLBecomesNil() async throws {
        // 写真の URL が空白だけなら nil（カードは人の形の印）。名前はそのまま出す
        let fixture = makeFixture()
        fixture.service.picksByKey = ["2026-10-26": DailyPick(dateKey: "2026-10-26", postIds: ["p1"])]
        fixture.firestore.posts = ["p1": makePost("p1", owner: "kumo")]
        fixture.firestore.displayNames = ["kumo": "くも"]
        fixture.firestore.photoURLs = ["kumo": " "]
        let viewModel = makeViewModel(fixture)

        await viewModel.load(viewerId: "viewer")

        let item = try XCTUnwrap(viewModel.item)
        XCTAssertEqual(item.authorName, "くも")
        XCTAssertNil(item.authorPhotoURL)
    }

    // MARK: - Helpers

    /// 1 ケースぶんの偽物一式（記録係と通知センターもケースごとに新しく作る）
    private struct Fixture {
        let service: DailyPickServiceStub
        let firestore: DailyPickFirestoreServiceStub
        let logger: DailyPickEventLoggerStub
        let sessionLog: DailyPickSessionLog
        let center: NotificationCenter
    }

    private func makeFixture() -> Fixture {
        Fixture(
            service: DailyPickServiceStub(),
            firestore: DailyPickFirestoreServiceStub(),
            logger: DailyPickEventLoggerStub(),
            sessionLog: DailyPickSessionLog(),
            center: NotificationCenter()
        )
    }

    /// 偽物一式で VM を作る（now は固定の時刻）
    private func makeViewModel(_ fixture: Fixture) -> DailyPickViewModel {
        let fixedNow = Self.fixedNow
        return DailyPickViewModel(
            dailyPickService: fixture.service,
            firestoreService: fixture.firestore,
            logger: fixture.logger,
            sessionLog: fixture.sessionLog,
            notificationCenter: fixture.center,
            now: { fixedNow }
        )
    }

    /// テスト用の投稿（画像 1 枚つき）
    private func makePost(
        _ id: String,
        owner: String,
        visibility: Visibility = .public,
        caption: String? = nil
    ) -> Post {
        Post(
            id: id,
            userId: owner,
            images: [ImageInfo(url: "https://example.com/sky.jpg", width: 1024, height: 768, order: 0)],
            caption: caption,
            visibility: visibility
        )
    }

    /// 投稿詳細でブロックしたときと同じ通知を、そのケースの通知センターに送る
    private func postUserBlocked(_ userId: String, on center: NotificationCenter) {
        center.post(name: .userBlocked, object: nil, userInfo: [Notification.blockedUserIdKey: userId])
    }

    /// 条件が満たされるまで、10 ミリ秒ずつ最大 2 秒待つ
    ///
    /// `.userBlocked` は通知センターの main キューで受けたあと MainActor の Task で処理し、その中でさらに
    /// 次の候補の fetchPost・名前の取得の await を挟む（偽物の async 関数は MainActor の外で動く）。
    /// 何回 MainActor に順番を譲れば終わるかが決まらないので、`Task.yield()` を決まった回数だけ回す待ち方より、
    /// 短い sleep を挟む期限つきの待ちの方が不安定になりにくい（SoratomoHiddenContentTests と同じ形）。
    /// 期限内に満たされなければそのまま戻り、続くアサートで落ちる（待ち続けない）。
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

// MARK: - 偽物

/// DailyPickServiceProtocol の偽物（鍵ごとの結果と、呼ばれた鍵の記録）
///
/// VM からは 1 本ずつ順番に呼ばれる（並列には呼ばれない）ので、記録にロックは付けない。
private final class DailyPickServiceStub: DailyPickServiceProtocol {
    /// 鍵ごとの文書（無い鍵は nil＝文書なし）
    var picksByKey: [String: DailyPick] = [:]
    /// 鍵ごとに投げるエラー（一時的な失敗）
    var errorsByKey: [String: Error] = [:]
    /// 呼ばれた鍵（呼ばれた順）
    private(set) var requestedKeys: [String] = []

    func fetchDailyPick(dateKey: String) async throws -> DailyPick? {
        requestedKeys.append(dateKey)
        if let error = errorsByKey[dateKey] { throw error }
        return picksByKey[dateKey]
    }
}

/// FirestoreServiceProtocol の偽物（fetchPost・fetchBlockedUserIds・fetchPublicProfile だけ）
///
/// 使わない関数は FirestoreServiceProtocol+TestDefaults.swift が埋める。
/// `holdPostFetch(_:)` で fetchPost を途中で止められる（次の候補を待っている間の状態を作るため）。
/// 止めている間に VM の別の読み込みが同じ偽物を呼ぶことがあるので、呼ばれた記録と止める仕組みはロックの中でだけ触る
/// （SoratomoProfileStoreTests の偽物と同じ形）。返す中身（posts など）は、テストが偽物の呼び出しを走らせていない間
/// （止めている間を含む）にだけ書き換える。止めた呼び出しは再開した後に中身を読む。
private final class DailyPickFirestoreServiceStub: FirestoreServiceProtocol, @unchecked Sendable {
    /// 投稿 ID ごとの投稿（無い ID は notFound＝削除済み）
    var posts: [String: Post] = [:]
    /// 一時的な失敗（ネットワーク断）を返す投稿 ID
    var transientFailurePostIds: Set<String> = []
    /// 見ている人 → ブロックしている人
    var blockedUserIdsByViewer: [String: [String]] = [:]
    /// ブロック一覧の読み取りで投げるエラー
    var blockListError: Error?
    /// 投稿者 → 表示名
    var displayNames: [String: String] = [:]
    /// 投稿者 → プロフィール写真の URL
    var photoURLs: [String: String] = [:]

    private let lock = NSLock()
    private var postIdsCalled: [String] = []
    private var blockedListCalls = 0
    private var profileIdsCalled: [String] = []
    /// 次の fetchPost 1 回を止める投稿 ID
    private var postIdsToHold: Set<String> = []
    /// 止まっている fetchPost（投稿 ID → 再開の口）
    private var postWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    /// releaseAll() の後か（後から止まりに来た呼び出しも、すぐ再開する）
    private var isReleasedAll = false

    /// fetchPost で呼ばれた投稿 ID（呼ばれた順）
    var requestedPostIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return postIdsCalled
    }

    /// fetchBlockedUserIds が呼ばれた回数
    var blockedListRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return blockedListCalls
    }

    /// fetchPublicProfile で呼ばれた投稿者（呼ばれた順）
    var requestedProfileIds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return profileIdsCalled
    }

    /// その投稿 ID の次の fetchPost 1 回を、`releasePostFetch(_:)` まで止める
    func holdPostFetch(_ postId: String) {
        lock.lock()
        postIdsToHold.insert(postId)
        lock.unlock()
    }

    /// その投稿 ID の fetchPost が止まっているか
    func isHoldingPostFetch(_ postId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return postWaiters[postId] != nil
    }

    /// 止めていた fetchPost を再開する
    func releasePostFetch(_ postId: String) {
        lock.lock()
        let waiter = postWaiters.removeValue(forKey: postId)
        lock.unlock()
        waiter?.resume()
    }

    /// 止めているものを全部再開し、以降は止めない（テストの後片付け。止まったまま終わると continuation が漏れるため）
    func releaseAll() {
        lock.lock()
        isReleasedAll = true
        postIdsToHold = []
        let pending = Array(postWaiters.values)
        postWaiters = [:]
        lock.unlock()
        for waiter in pending {
            waiter.resume()
        }
    }

    func fetchPost(postId: String) async throws -> Post {
        if recordPostFetchAndShouldHold(postId) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                parkPostFetch(postId, continuation)
            }
        }
        if transientFailurePostIds.contains(postId) {
            throw FirestoreServiceError.fetchFailed(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
            )
        }
        guard let post = posts[postId] else { throw FirestoreServiceError.notFound }
        return post
    }

    func fetchBlockedUserIds(userId: String) async throws -> [String] {
        recordBlockedListFetch()
        if let blockListError { throw blockListError }
        return blockedUserIdsByViewer[userId] ?? []
    }

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        recordProfileFetch(userId)
        return PublicProfile(id: userId, displayName: displayNames[userId], photoURL: photoURLs[userId])
    }

    // ロックは同期のメソッドの中でだけ使う（async の関数の中で NSLock を触ると警告になるため）

    /// 呼ばれた投稿 ID を記録し、止める投稿 ID なら true（止めるのは 1 回だけ）
    private func recordPostFetchAndShouldHold(_ postId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        postIdsCalled.append(postId)
        guard !isReleasedAll else { return false }
        return postIdsToHold.remove(postId) != nil
    }

    /// 止まりに来た fetchPost の再開の口を預かる（releaseAll() の後なら、すぐ再開する）
    private func parkPostFetch(_ postId: String, _ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isReleasedAll {
            lock.unlock()
            continuation.resume()
        } else {
            postWaiters[postId] = continuation
            lock.unlock()
        }
    }

    private func recordBlockedListFetch() {
        lock.lock()
        blockedListCalls += 1
        lock.unlock()
    }

    private func recordProfileFetch(_ userId: String) {
        lock.lock()
        profileIdsCalled.append(userId)
        lock.unlock()
    }
}

/// DailyPickEventLogging の偽物（送ったイベントの名前とパラメータを記録する）
private final class DailyPickEventLoggerStub: DailyPickEventLogging {
    /// 送ったイベント 1 件
    struct Event {
        let name: String
        let parameters: [String: Any]
    }

    /// 送ったイベント（送った順）
    private(set) var events: [Event] = []

    func logEvent(_ name: String, parameters: [String: Any]?) {
        events.append(Event(name: name, parameters: parameters ?? [:]))
    }

    /// その名前のイベントのパラメータ（送った順）
    func parameters(of name: String) -> [[String: Any]] {
        events.filter { $0.name == name }.map(\.parameters)
    }
}
