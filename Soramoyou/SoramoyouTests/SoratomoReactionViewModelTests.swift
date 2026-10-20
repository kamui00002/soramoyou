//
//  SoratomoReactionViewModelTests.swift
//  SoramoyouTests
//
//  そらとものリアクションの ViewModel のテスト ⭐️
//  （soratomo-reactions tasks 7.6・design.md の SoratomoReactionViewModel・Error Categories）
//
//  - 操作を出してよいか（ログイン中で、自分の投稿でない・1.6）と、出せないときの choose は何もしないこと
//  - オフラインでは送らず、通信の文言と `offline` を記録すること（10.1・10.2）
//  - 送っている間は重ねない（1.10）・楽観的な表示（1.9）・同じ絵文字で外す／違う絵文字で付ける（1.3〜1.5）
//  - 成功の記録（added / replaced / removed）と、unchanged は記録しないこと（D3）
//  - 失敗したらすぐ戻す（10.3）・失敗の文言と理由（10.4・10.5）・投稿がもう無いときの知らせ（8.8）
//  - 確定した上書きを 10 秒後に手放し、新しい上書きは消さないこと（2.6）
//  - ブロックの変化で描き直しを知らせること（5.2）・押した人の一覧を開いた記録・計測に ID が入らないこと（15.3）
//
//  ⚠️ 期待する文言・値・件数は 7.6 の契約から直に書く。ViewModel の実装から組み立てない
//     （同じ値から作った 2 つを比べると、何もしない実装でも緑になるため）。
//  ⚠️ 時間では待たない（Task.sleep を使わない）。10 秒の手放しは SleepGate で、送っている間はサービスの門で止める。
//     状態が変わるのを待つときは、上限つきの Task.yield() の繰り返しにする（タイムラインのテストと同じ形）。
//

import Combine
@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoReactionViewModelTests: XCTestCase {
    // MARK: - 目立つ ID

    /// テストで使う ID（計測に混ざっていないかを文字列で探せるよう、ほかと重ならない値にする）
    private enum ID {
        /// 自分の uid
        static let me = "uid-me-7f3a"
        /// 相手（投稿者）の uid
        static let other = "uid-other-k2p9"
        /// 同じグループの友達の uid（数を見るために、サーバーのリアクションに入れる）
        static let friend = "uid-friend-m4t6"
        /// グループ ID
        static let group = "group-9x2c"
        /// 投稿 ID
        static let sky = "sky-q8w1"
    }

    /// 数の 1 行（期待値を短く書くため）
    private typealias Count = SoratomoReactionSummary.Count

    // MARK: - 代役

    /// ViewModel から呼ばれたクロージャの記録
    private final class Recorder {
        var events: [SoratomoEvent] = []
        var skyGone: [SoratomoSky] = []
        var isOnline = true
        var uid: String?
    }

    /// Task の中から立てて、テストが読む印（受け付けてしまう実装でも、テストを止めずに赤にするため）
    private final class Flag {
        var isSet = false
    }

    /// 確定した上書きを手放す待ち（sleep）を止めておく門
    ///
    /// - 呼ばれた順に 0, 1, 2 … の番号を付け、長さを `requested` に残す（待つ前に残すので、止まっている間も読める）
    /// - `open(at:)` で開けた番号だけを通す。待つ前に開けた番号も通す（開けた番号の集合を持つ）
    /// - `openAll()` はこれからの呼び出しも含めて全部通す（後片づけで、止まったままのタスクを残さないため）
    private actor SleepGate {
        /// 呼ばれた長さ（ナノ秒・呼ばれた順）
        private(set) var requested: [UInt64] = []
        /// 開けた番号
        private var openedIndexes: Set<Int> = []
        /// 全部を開けたか
        private var isAllOpen = false
        /// 待っている呼び出し（番号 → 続き）
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]

        func sleep(_ nanoseconds: UInt64) async {
            let index = requested.count
            requested.append(nanoseconds)
            if isAllOpen || openedIndexes.contains(index) { return }
            await withCheckedContinuation { waiting[index] = $0 }
        }

        func open(at index: Int) {
            openedIndexes.insert(index)
            waiting.removeValue(forKey: index)?.resume()
        }

        func openAll() {
            isAllOpen = true
            let continuations = Array(waiting.values)
            waiting = [:]
            continuations.forEach { $0.resume() }
        }
    }

    /// サービスを処理中で止めておく門（開けるまで待たせる。タイムラインのテストの Gate と同じ考え方）
    ///
    /// 続きは配列で持つ。2 回目の呼び出しが来ても 1 回目の続きを上書きして失わない
    /// （送っている間の 2 回目を受け付けてしまう実装でも、open で両方が戻り、テストが止まらずに赤になる）。
    private actor ServiceGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            isOpen = true
            let waiting = continuations
            continuations = []
            waiting.forEach { $0.resume() }
        }
    }

    /// テスト用の部品
    private struct Fixture {
        let viewModel: SoratomoReactionViewModel
        let service: MockSoratomoReactionService
        let blockedAuthors: SoratomoBlockedAuthors
        let sleepGate: SleepGate
        let recorder: Recorder
    }

    // MARK: - 部品を作る

    /// ViewModel をモックとクロージャだけで作る
    ///
    /// sleep は SleepGate に差し替え、`confirmedLifetimeNanoseconds` は既定のまま（10 秒を固定するため）。
    /// - Parameter uid: 自分の uid（ログアウト中は nil）。ViewModel を作る前に入れる
    private func makeFixture(uid: String? = ID.me) -> Fixture {
        let service = MockSoratomoReactionService()
        // ブロックの一覧は本物を、テスト専用の通知センターで作る（ほかのテストと混ざらないため）
        let blockedAuthors = SoratomoBlockedAuthors(notificationCenter: NotificationCenter())
        let sleepGate = SleepGate()
        let recorder = Recorder()
        recorder.uid = uid
        // 成功のたびに手放しのタスクが門で止まったまま残るので、テストの後で全部通して終わらせる
        addTeardownBlock {
            await sleepGate.openAll()
        }
        let viewModel = SoratomoReactionViewModel(
            groupId: ID.group,
            reactionService: service,
            blockedAuthors: blockedAuthors,
            currentUid: { recorder.uid },
            isOnline: { recorder.isOnline },
            onSkyGone: { recorder.skyGone.append($0) },
            sleep: { await sleepGate.sleep($0) },
            logEvent: { recorder.events.append($0) }
        )
        return Fixture(
            viewModel: viewModel,
            service: service,
            blockedAuthors: blockedAuthors,
            sleepGate: sleepGate,
            recorder: recorder
        )
    }

    /// テスト用の投稿（既定は相手の投稿）
    private func makeSky(authorId: String = ID.other) -> SoratomoSky {
        SoratomoSky(
            id: ID.sky,
            groupId: ID.group,
            authorId: authorId,
            caption: nil,
            pixelWidth: 100,
            pixelHeight: 100,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    /// サーバーのリアクション（uid → 絵文字。時刻は持たない）
    private func reactions(_ kinds: [String: SoratomoReactionKind]) -> SoratomoReactions {
        SoratomoReactions(byUser: kinds.mapValues { SoratomoReaction(kind: $0, reactedAt: nil) })
    }

    /// サービスが成功（結果と、書いた後の自分の絵文字）を返すようにする
    private func respond(_ fixture: Fixture, _ outcome: SoratomoReactionOutcome, kind: SoratomoReactionKind?) {
        fixture.service.setReactionResult = .success(SoratomoReactionChange(outcome: outcome, kind: kind))
    }

    // MARK: - 操作を出してよいか（1.6）

    /// 相手の投稿にだけ操作を出す。自分の投稿・ログアウト中（nil）・空文字の uid では出さない
    func testCanReactOnlyToOthersSkiesWhileSignedIn() {
        // ログイン中で相手の投稿 → 真
        XCTAssertTrue(makeFixture().viewModel.canReact(to: makeSky()))
        // 自分の投稿 → 偽
        XCTAssertFalse(makeFixture().viewModel.canReact(to: makeSky(authorId: ID.me)))
        // ログアウト中（nil）→ 偽
        XCTAssertFalse(makeFixture(uid: nil).viewModel.canReact(to: makeSky()))
        // 空文字の uid もログアウト中として扱う → 偽
        XCTAssertFalse(makeFixture(uid: "").viewModel.canReact(to: makeSky()))
    }

    /// 操作を出せないときの choose は、サービスを呼ばず・記録せず・知らせず・上書きも入れない
    func testChooseDoesNothingWhenCannotReact() async {
        let cases: [(uid: String?, authorId: String, label: String)] = [
            (ID.me, ID.me, "自分の投稿"),
            (nil, ID.other, "ログアウト中"),
            ("", ID.other, "空文字の uid"),
        ]
        for (uid, authorId, label) in cases {
            let fixture = makeFixture(uid: uid)
            // 送ってしまったら上書きと記録が入るよう、成功を返しておく
            respond(fixture, .added, kind: .sunset)
            await fixture.viewModel.choose(.sunset, for: makeSky(authorId: authorId), server: .empty, source: .timeline)

            XCTAssertTrue(fixture.service.setReactionCalls.isEmpty, label)
            XCTAssertTrue(fixture.recorder.events.isEmpty, label)
            XCTAssertNil(fixture.viewModel.notice, label)
            XCTAssertTrue(fixture.viewModel.overlays.isEmpty, label)
        }

        // 対照: 操作を出せるとき（ログイン中で相手の投稿）は送る（何もしない実装で、上が緑に化けていないことを確かめる）
        let control = makeFixture()
        respond(control, .added, kind: .sunset)
        await control.viewModel.choose(.sunset, for: makeSky(), server: .empty, source: .timeline)
        XCTAssertEqual(control.service.setReactionCalls.count, 1)
    }

    // MARK: - オフライン（10.1・10.2）

    /// オフラインで付けようとしたら送らず、通信の文言を出し、offline の失敗（add）を記録し、上書きを入れない
    func testOfflineAddDoesNotSendAndLogsOffline() async {
        let fixture = makeFixture()
        fixture.recorder.isOnline = false
        // 送ってしまったら上書きが入るよう、成功を返しておく
        respond(fixture, .added, kind: .sunset)
        let sky = makeSky()

        await fixture.viewModel.choose(.sunset, for: sky, server: .empty, source: .timeline)

        XCTAssertTrue(fixture.service.setReactionCalls.isEmpty)
        XCTAssertEqual(fixture.viewModel.notice, .failed(.network))
        XCTAssertEqual(fixture.recorder.events, [.reactionFailed(action: .add, reason: .offline)])
        let expected: [String: SoratomoAnalyticsValue] = ["action": .value("add"), "reason": .value("offline")]
        XCTAssertEqual(fixture.recorder.events.first?.parameters, expected)
        XCTAssertNil(fixture.viewModel.overlays[ID.sky])
        XCTAssertTrue(fixture.viewModel.overlays.isEmpty)
        XCTAssertFalse(fixture.viewModel.isSending(sky))
    }

    /// オフラインで外そうとしたら（サーバーに自分の夕焼けがあって夕焼けを選ぶ）、失敗の action は remove
    func testOfflineRemoveLogsRemoveAction() async {
        let fixture = makeFixture()
        fixture.recorder.isOnline = false
        respond(fixture, .removed, kind: nil)

        await fixture.viewModel.choose(.sunset, for: makeSky(), server: reactions([ID.me: .sunset]), source: .detail)

        XCTAssertTrue(fixture.service.setReactionCalls.isEmpty)
        XCTAssertEqual(fixture.viewModel.notice, .failed(.network))
        XCTAssertEqual(fixture.recorder.events, [.reactionFailed(action: .remove, reason: .offline)])
        let expected: [String: SoratomoAnalyticsValue] = ["action": .value("remove"), "reason": .value("offline")]
        XCTAssertEqual(fixture.recorder.events.first?.parameters, expected)
        XCTAssertTrue(fixture.viewModel.overlays.isEmpty)
    }

    // MARK: - 送っている間は重ねない（1.10）

    /// 1 回目を送っている間の 2 回目（別の絵文字）と 3 回目（同じ絵文字）は受け付けず、サービスの呼び出しは 1 回のまま
    func testChooseWhileSendingIsIgnored() async {
        let fixture = makeFixture()
        let sky = makeSky()
        let gate = ServiceGate()
        respond(fixture, .added, kind: .sunset)
        fixture.service.onSetReaction = { await gate.wait() }

        let viewModel = fixture.viewModel
        let first = Task { await viewModel.choose(.sunset, for: sky, server: .empty, source: .timeline) }
        // 1 回目が送信中になるまで待つ
        for _ in 0 ..< 1000 where !viewModel.isSending(sky) {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isSending(sky))

        // 送っている間に 2 回目・3 回目を選ぶ。受け付けてしまう実装ではサービスの門で止まるので、
        // Task で流して「戻ったか」を印で見る（テストを止めずに赤にする）
        let returned = Flag()
        let ignored = Task {
            await viewModel.choose(.rainbow, for: sky, server: .empty, source: .timeline)
            await viewModel.choose(.sunset, for: sky, server: .empty, source: .detail)
            returned.isSet = true
        }
        for _ in 0 ..< 1000 where !returned.isSet {
            await Task.yield()
        }
        // 門を開ける前に戻った＝サービスへ行かなかった
        XCTAssertTrue(returned.isSet)
        XCTAssertTrue(viewModel.isSending(sky))
        XCTAssertEqual(viewModel.overlays[ID.sky]?.value, .set(.sunset))

        await gate.open()
        await first.value
        await ignored.value

        // サービスの呼び出しの記録は、モックが別のスレッドで足すので、1 回目を await した後に見る
        XCTAssertFalse(viewModel.isSending(sky))
        XCTAssertEqual(fixture.service.setReactionCalls.count, 1)
        XCTAssertEqual(fixture.service.setReactionCalls.first?.kind, .sunset)
        XCTAssertEqual(fixture.recorder.events, [.reactionAdded(kind: .sunset, source: .timeline, replaced: false)])
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - 同じ絵文字で外す・違う絵文字で付ける（1.3〜1.5）

    /// サーバーに自分の夕焼けがあるとき、夕焼けを選ぶと kind: nil（外す）を、ViewModel のグループ ID と投稿の ID で送る
    func testChoosingMyCurrentKindSendsNilToRemove() async {
        let fixture = makeFixture()
        respond(fixture, .removed, kind: nil)

        await fixture.viewModel.choose(.sunset, for: makeSky(), server: reactions([ID.me: .sunset]), source: .timeline)

        XCTAssertEqual(fixture.service.setReactionCalls.count, 1)
        XCTAssertEqual(fixture.service.setReactionCalls.first?.groupId, "group-9x2c")
        XCTAssertEqual(fixture.service.setReactionCalls.first?.skyId, "sky-q8w1")
        XCTAssertNil(fixture.service.setReactionCalls.first?.kind)
    }

    /// サーバーに自分の夕焼けがあるとき、虹を選ぶと kind: .rainbow（選び直す）を送る
    func testChoosingAnotherKindSendsThatKind() async {
        let fixture = makeFixture()
        respond(fixture, .replaced, kind: .rainbow)

        await fixture.viewModel.choose(.rainbow, for: makeSky(), server: reactions([ID.me: .sunset]), source: .timeline)

        XCTAssertEqual(fixture.service.setReactionCalls.count, 1)
        XCTAssertEqual(fixture.service.setReactionCalls.first?.groupId, "group-9x2c")
        XCTAssertEqual(fixture.service.setReactionCalls.first?.skyId, "sky-q8w1")
        XCTAssertEqual(fixture.service.setReactionCalls.first?.kind, .rainbow)
    }

    /// サーバーは空でも、確定した上書きが夕焼けなら、夕焼けを選ぶと kind: nil（上書きを反映して外すと決める）
    func testConfirmedOverlayDecidesRemoval() async {
        let fixture = makeFixture()
        let sky = makeSky()
        // 1 回目: 夕焼けを付けて確定させる（監視はまだ届いていない＝サーバーは空のまま）
        respond(fixture, .added, kind: .sunset)
        await fixture.viewModel.choose(.sunset, for: sky, server: .empty, source: .timeline)
        XCTAssertEqual(fixture.viewModel.overlays[ID.sky]?.value, .set(.sunset))
        XCTAssertEqual(fixture.viewModel.overlays[ID.sky]?.phase, .confirmed)

        // 2 回目: もう一度夕焼け → 外す
        respond(fixture, .removed, kind: nil)
        await fixture.viewModel.choose(.sunset, for: sky, server: .empty, source: .timeline)

        XCTAssertEqual(fixture.service.setReactionCalls.map(\.kind), [.sunset, nil])
    }

    // MARK: - 送っている間の表示（楽観的な表示・1.9）

    /// 送っている間は選んだ絵文字が数と自分の絵文字に入り、成功の後は応答の kind で確定する
    func testSendingOverlayShowsChosenKindThenConfirmsWithResponseKind() async {
        let fixture = makeFixture()
        let sky = makeSky()
        let server = reactions([ID.friend: .sunset])
        let gate = ServiceGate()
        // 応答は、送った夕焼けと違う虹を返す（確定の値は応答に従うことを見るため）
        respond(fixture, .added, kind: .rainbow)
        fixture.service.onSetReaction = { await gate.wait() }

        let viewModel = fixture.viewModel
        let sending = Task { await viewModel.choose(.sunset, for: sky, server: server, source: .timeline) }
        for _ in 0 ..< 1000 where !viewModel.isSending(sky) {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isSending(sky))

        // 送っている間: 自分の夕焼けが数に入っている（友達 1 + 自分 1）
        let during = viewModel.summary(for: sky, server: server)
        XCTAssertEqual(during.myKind, .sunset)
        XCTAssertEqual(during.counts, [Count(kind: .sunset, count: 2)])
        XCTAssertEqual(during.total, 2)
        XCTAssertEqual(viewModel.overlays[ID.sky]?.value, .set(.sunset))
        XCTAssertEqual(viewModel.overlays[ID.sky]?.phase, .sending)

        await gate.open()
        await sending.value

        // 成功の後: 応答の虹で確定する
        XCTAssertFalse(viewModel.isSending(sky))
        XCTAssertEqual(viewModel.overlays[ID.sky]?.phase, .confirmed)
        XCTAssertEqual(viewModel.overlays[ID.sky]?.value, .set(.rainbow))
        let after = viewModel.summary(for: sky, server: server)
        XCTAssertEqual(after.myKind, .rainbow)
        XCTAssertEqual(after.counts, [Count(kind: .sunset, count: 1), Count(kind: .rainbow, count: 1)])
        XCTAssertEqual(after.total, 2)
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - 成功の記録

    /// added → reaction_added（replaced: false）。kind は名前の sunset
    func testAddedOutcomeLogsReactionAddedNotReplaced() async {
        let fixture = makeFixture()
        respond(fixture, .added, kind: .sunset)

        await fixture.viewModel.choose(.sunset, for: makeSky(), server: .empty, source: .timeline)

        XCTAssertEqual(fixture.recorder.events, [.reactionAdded(kind: .sunset, source: .timeline, replaced: false)])
        let expected: [String: SoratomoAnalyticsValue] = [
            "kind": .value("sunset"), "source": .value("timeline"), "replaced": .bool(false),
        ]
        XCTAssertEqual(fixture.recorder.events.first?.parameters, expected)
    }

    /// replaced → reaction_added（replaced: true）
    func testReplacedOutcomeLogsReactionAddedReplaced() async {
        let fixture = makeFixture()
        respond(fixture, .replaced, kind: .sunset)

        await fixture.viewModel.choose(.sunset, for: makeSky(), server: reactions([ID.me: .rainbow]), source: .timeline)

        XCTAssertEqual(fixture.service.setReactionCalls.first?.kind, .sunset)
        XCTAssertEqual(fixture.recorder.events, [.reactionAdded(kind: .sunset, source: .timeline, replaced: true)])
    }

    /// removed → reaction_removed（source は操作した画面の detail）
    func testRemovedOutcomeLogsReactionRemoved() async {
        let fixture = makeFixture()
        respond(fixture, .removed, kind: nil)

        await fixture.viewModel.choose(.sunset, for: makeSky(), server: reactions([ID.me: .sunset]), source: .detail)

        XCTAssertEqual(fixture.recorder.events, [.reactionRemoved(source: .detail)])
        let expected: [String: SoratomoAnalyticsValue] = ["source": .value("detail")]
        XCTAssertEqual(fixture.recorder.events.first?.parameters, expected)
    }

    /// D3: unchanged は何も記録しない
    ///
    /// 空回りで緑に化けないよう、実際に 1 回送ったこと・成功として上書きを確定にしたこと・知らせが無いことも同じテストで見る。
    func testUnchangedOutcomeLogsNothing() async {
        let fixture = makeFixture()
        respond(fixture, .unchanged, kind: .sunset)

        await fixture.viewModel.choose(.sunset, for: makeSky(), server: .empty, source: .timeline)

        XCTAssertTrue(fixture.recorder.events.isEmpty)
        XCTAssertEqual(fixture.service.setReactionCalls.count, 1)
        XCTAssertEqual(fixture.viewModel.overlays[ID.sky]?.phase, .confirmed)
        XCTAssertEqual(fixture.viewModel.overlays[ID.sky]?.value, .set(.sunset))
        XCTAssertNil(fixture.viewModel.notice)
    }

    // MARK: - 失敗で上書きを戻す（10.3）

    /// 付けるのに失敗したら、上書きをすぐ消し、数と自分の絵文字はサーバーの値（友達の夕焼け 1 件だけ）に戻る
    func testFailureRestoresServerStateRightAway() async {
        let fixture = makeFixture()
        let sky = makeSky()
        let server = reactions([ID.friend: .sunset])
        fixture.service.setReactionResult = .failure(.network)

        await fixture.viewModel.choose(.sunset, for: sky, server: server, source: .timeline)

        XCTAssertEqual(fixture.service.setReactionCalls.count, 1)
        XCTAssertNil(fixture.viewModel.overlays[ID.sky])
        XCTAssertFalse(fixture.viewModel.isSending(sky))
        let summary = fixture.viewModel.summary(for: sky, server: server)
        XCTAssertNil(summary.myKind)
        XCTAssertEqual(summary.counts, [Count(kind: .sunset, count: 1)])
        XCTAssertEqual(summary.total, 1)
    }

    /// 外すのに失敗したら、自分の夕焼けが戻る（自分 1 + 友達 1 の 2 件のまま）
    func testRemovalFailureRestoresMyReaction() async {
        let fixture = makeFixture()
        let sky = makeSky()
        let server = reactions([ID.me: .sunset, ID.friend: .sunset])
        fixture.service.setReactionResult = .failure(.unknown)

        await fixture.viewModel.choose(.sunset, for: sky, server: server, source: .timeline)

        XCTAssertEqual(fixture.service.setReactionCalls.count, 1)
        XCTAssertNil(fixture.service.setReactionCalls.first?.kind)
        XCTAssertNil(fixture.viewModel.overlays[ID.sky])
        let summary = fixture.viewModel.summary(for: sky, server: server)
        XCTAssertEqual(summary.myKind, .sunset)
        XCTAssertEqual(summary.counts, [Count(kind: .sunset, count: 2)])
        XCTAssertEqual(summary.total, 2)
    }

    // MARK: - 失敗の文言と理由（10.4・10.5）

    /// 失敗を 1 回起こした後の部品を返す（サーバーには自分の夕焼けがある）
    /// - Parameters:
    ///   - error: サービスが投げる失敗
    ///   - removing: 真なら夕焼けを選ぶ＝外す。偽なら虹を選ぶ＝選び直す
    private func fixtureAfterFailure(_ error: SoratomoError, removing: Bool) async -> Fixture {
        let fixture = makeFixture()
        fixture.service.setReactionResult = .failure(error)
        await fixture.viewModel.choose(
            removing ? .sunset : .rainbow,
            for: makeSky(),
            server: reactions([ID.me: .sunset]),
            source: .timeline
        )
        return fixture
    }

    /// 選び直しの失敗（action: add）と外すの失敗（action: remove）の両方で、知らせ・文言・計測の理由を確かめる
    /// - Parameters:
    ///   - error: サービスが投げる失敗
    ///   - message: 画面に出す固定の文言（契約の文をそのまま書く）
    ///   - reason: 計測の `reason` の値（契約の文字列をそのまま書く）
    private func assertFailure(
        _ error: SoratomoError,
        showsMessage message: String,
        logsReason reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for (removing, action) in [(false, "add"), (true, "remove")] {
            let fixture = await fixtureAfterFailure(error, removing: removing)
            XCTAssertEqual(fixture.service.setReactionCalls.count, 1, action, file: file, line: line)
            XCTAssertEqual(fixture.viewModel.notice, .failed(error), action, file: file, line: line)
            XCTAssertEqual(fixture.viewModel.notice?.userMessage, message, action, file: file, line: line)
            XCTAssertEqual(fixture.recorder.events.map(\.name), ["soratomo_reaction_failed"], action, file: file, line: line)
            let expected: [String: SoratomoAnalyticsValue] = ["action": .value(action), "reason": .value(reason)]
            XCTAssertEqual(fixture.recorder.events.first?.parameters, expected, action, file: file, line: line)
        }
    }

    /// 通信の失敗: 通信の文言・reason は network
    func testNetworkFailureShowsNetworkMessageAndLogsNetwork() async {
        await assertFailure(
            .network,
            showsMessage: "通信できませんでした。インターネットにつながる場所でもう一度お試しください",
            logsReason: "network"
        )
    }

    /// 投稿がもう無い: 「この投稿はもうありません」・reason は not_found
    func testSkyGoneFailureShowsSkyGoneMessageAndLogsNotFound() async {
        await assertFailure(.skyGone, showsMessage: "この投稿はもうありません", logsReason: "not_found")
    }

    /// メンバーでない: リアクション独自の文言（`SoratomoError.notMember.userMessage` とは違う）・reason は not_member
    func testNotMemberFailureShowsReactionMessageAndLogsNotMember() async {
        await assertFailure(
            .notMember,
            showsMessage: "このグループのメンバーではないため、リアクションできませんでした",
            logsReason: "not_member"
        )
    }

    /// 利用停止: 停止とお問い合わせの文言（10.5）・reason は suspended
    func testSuspendedFailureShowsSuspendedMessageAndLogsSuspended() async {
        await assertFailure(
            .suspended,
            showsMessage: "そらともの利用が停止されています。設定の『お問い合わせ』からご連絡ください",
            logsReason: "suspended"
        )
    }

    /// 想定外の失敗: 「リアクションできませんでした…」・reason は unknown
    ///
    /// 記録（`SoratomoError.record`）はサービスの 1 か所で、ViewModel は呼ばない（利用者の決定 2026-10-21）。
    /// 差し替え口が無いのでテストでは見ない。
    func testUnknownFailureShowsGenericMessageAndLogsUnknown() async {
        await assertFailure(
            .unknown,
            showsMessage: "リアクションできませんでした。時間をおいてもう一度お試しください",
            logsReason: "unknown"
        )
    }

    /// ルールに拒否された: 表に無い種類なので「リアクションできませんでした…」・reason は unknown
    func testPermissionDeniedFailureShowsGenericMessageAndLogsUnknown() async {
        await assertFailure(
            .permissionDenied,
            showsMessage: "リアクションできませんでした。時間をおいてもう一度お試しください",
            logsReason: "unknown"
        )
    }

    /// 通信・投稿がもう無い・メンバーでない・利用停止の 4 つ以外は、どの種類も「リアクションできませんでした…」
    /// （内部のエラーコードやほかの操作の文言を出さない・10.4）
    func testNoticeMessageForOtherErrorsIsGenericReactionMessage() {
        let special: [SoratomoError] = [.network, .skyGone, .notMember, .suspended]
        let others = SoratomoError.allCases.filter { !special.contains($0) }
        XCTAssertFalse(others.isEmpty)
        for error in others {
            XCTAssertEqual(
                SoratomoReactionNotice.failed(error).userMessage,
                "リアクションできませんでした。時間をおいてもう一度お試しください",
                "\(error)"
            )
        }
    }

    // MARK: - 投稿がもう無い（8.8）

    /// skyGone の失敗で、その投稿を 1 回だけ onSkyGone に渡す
    func testSkyGoneFailureCallsOnSkyGoneOnceWithThatSky() async {
        let fixture = makeFixture()
        let sky = makeSky()
        fixture.service.setReactionResult = .failure(.skyGone)

        await fixture.viewModel.choose(.sunset, for: sky, server: .empty, source: .detail)

        XCTAssertEqual(fixture.recorder.skyGone, [sky])
        XCTAssertEqual(fixture.recorder.skyGone.map(\.id), ["sky-q8w1"])
    }

    /// skyGone 以外の失敗では onSkyGone を呼ばない
    func testOtherFailuresDoNotCallOnSkyGone() async {
        let errors: [SoratomoError] = [.network, .notMember, .suspended, .unknown, .permissionDenied]
        for error in errors {
            let fixture = makeFixture()
            fixture.service.setReactionResult = .failure(error)

            await fixture.viewModel.choose(.sunset, for: makeSky(), server: .empty, source: .timeline)

            // 失敗の道を通ったことを先に確かめる（空回りで緑にしない）
            XCTAssertEqual(fixture.viewModel.notice, .failed(error), "\(error)")
            XCTAssertTrue(fixture.recorder.skyGone.isEmpty, "\(error)")
        }
    }

    // MARK: - 上書きの手放し（2.6）

    /// 確定した上書きは成功の直後は残り、10 秒（10_000_000_000 ナノ秒）の待ちが終わったら消える
    func testConfirmedOverlayIsReleasedAfterTenSeconds() async throws {
        let fixture = makeFixture()
        respond(fixture, .added, kind: .sunset)

        await fixture.viewModel.choose(.sunset, for: makeSky(), server: .empty, source: .timeline)

        // 成功の直後は確定の上書きが残っている
        XCTAssertEqual(fixture.viewModel.overlays[ID.sky]?.value, .set(.sunset))
        XCTAssertEqual(fixture.viewModel.overlays[ID.sky]?.phase, .confirmed)
        let expiry = try XCTUnwrap(fixture.viewModel.expiryTasks[ID.sky])

        await fixture.sleepGate.open(at: 0)
        await expiry.value

        XCTAssertNil(fixture.viewModel.overlays[ID.sky])
        XCTAssertNil(fixture.viewModel.expiryTasks[ID.sky])
        // タスクは非同期に始まるので、待ちの長さはタスクを await した後に見る
        let requested = await fixture.sleepGate.requested
        XCTAssertEqual(requested, [10_000_000_000])
    }

    /// 古い手放し（1 本目）の待ちが終わっても、札が違うので新しい上書き（虹）は消さない。2 本目が終わったら消える
    func testOlderExpiryDoesNotRemoveNewerOverlay() async throws {
        let fixture = makeFixture()
        let sky = makeSky()
        let viewModel = fixture.viewModel

        // 1 本目: 夕焼けで成功
        respond(fixture, .added, kind: .sunset)
        await viewModel.choose(.sunset, for: sky, server: .empty, source: .timeline)
        let first = try XCTUnwrap(viewModel.expiryTasks[ID.sky])
        // 1 本目の手放しが門に着くまで待つ（門の番号 0 を 1 本目に固定し、取り違えで止まらないようにする）
        var arrived = await fixture.sleepGate.requested.count
        for _ in 0 ..< 1000 where arrived < 1 {
            await Task.yield()
            arrived = await fixture.sleepGate.requested.count
        }
        XCTAssertEqual(arrived, 1)

        // 2 本目: 虹に選び直して成功
        respond(fixture, .replaced, kind: .rainbow)
        await viewModel.choose(.rainbow, for: sky, server: .empty, source: .timeline)
        // 2 本の控えは、どちらも await する前に取る
        let second = try XCTUnwrap(viewModel.expiryTasks[ID.sky])
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(fixture.service.setReactionCalls.map(\.kind), [.sunset, .rainbow])

        // 1 本目の待ちが終わっても、新しい上書き（虹の確定）と 2 本目の控えは残る
        await fixture.sleepGate.open(at: 0)
        await first.value
        XCTAssertEqual(viewModel.overlays[ID.sky]?.value, .set(.rainbow))
        XCTAssertEqual(viewModel.overlays[ID.sky]?.phase, .confirmed)
        XCTAssertEqual(viewModel.expiryTasks[ID.sky], second)

        // 2 本目の待ちが終わったら消える
        await fixture.sleepGate.open(at: 1)
        await second.value
        XCTAssertNil(viewModel.overlays[ID.sky])
        XCTAssertNil(viewModel.expiryTasks[ID.sky])
        let requested = await fixture.sleepGate.requested
        XCTAssertEqual(requested, [10_000_000_000, 10_000_000_000])
    }

    // MARK: - ブロックの変化（5.2）

    /// ブロックが足されたら objectWillChange が届き、その後の summary から相手の分が消える
    func testBlockingSendsObjectWillChangeAndHidesTheirReaction() {
        let fixture = makeFixture()
        let sky = makeSky()
        let server = reactions([ID.friend: .rainbow, ID.me: .sunset])

        // ブロックの前は 2 人分（絵文字の並び順: 夕焼け → 虹）
        let before = fixture.viewModel.summary(for: sky, server: server)
        XCTAssertEqual(before.counts, [Count(kind: .sunset, count: 1), Count(kind: .rainbow, count: 1)])
        XCTAssertEqual(before.total, 2)

        var willChangeCount = 0
        let subscription = fixture.viewModel.objectWillChange.sink { _ in
            willChangeCount += 1
        }
        XCTAssertEqual(willChangeCount, 0)

        fixture.blockedAuthors.add(ID.friend)

        XCTAssertGreaterThanOrEqual(willChangeCount, 1)
        let after = fixture.viewModel.summary(for: sky, server: server)
        XCTAssertEqual(after.counts, [Count(kind: .sunset, count: 1)])
        XCTAssertEqual(after.total, 1)
        XCTAssertEqual(after.myKind, .sunset)
        XCTAssertEqual(after.reactors.map(\.id), ["uid-me-7f3a"])
        // 購読はテストの最後まで持つ
        subscription.cancel()
    }

    // MARK: - 押した人の一覧を開いた

    /// didOpenReactors(count: 3) → soratomo_reactions_viewed（reaction_count: 3）
    func testDidOpenReactorsLogsReactionCount() {
        let fixture = makeFixture()

        fixture.viewModel.didOpenReactors(count: 3)

        XCTAssertEqual(fixture.recorder.events, [.reactionsViewed(reactionCount: 3)])
        let expected: [String: SoratomoAnalyticsValue] = ["reaction_count": .int(3)]
        XCTAssertEqual(fixture.recorder.events.first?.parameters, expected)
    }

    // MARK: - 計測の値に名前や ID が入らない（15.3）

    /// 付ける・選び直す・外す・失敗・オフライン・一覧を通した全イベントの値の文字列に、uid・グループ ID・投稿 ID が無い
    func testAnalyticsValuesCarryNoIdsAndKindIsName() async {
        let fixture = makeFixture()
        let sky = makeSky()
        let viewModel = fixture.viewModel

        // 付ける（夕焼け）
        respond(fixture, .added, kind: .sunset)
        await viewModel.choose(.sunset, for: sky, server: .empty, source: .timeline)
        // 選び直す（虹）
        respond(fixture, .replaced, kind: .rainbow)
        await viewModel.choose(.rainbow, for: sky, server: .empty, source: .timeline)
        // 外す（確定した虹をもう一度選ぶ）
        respond(fixture, .removed, kind: nil)
        await viewModel.choose(.rainbow, for: sky, server: .empty, source: .detail)
        // 失敗（くもを付けようとして、メンバーでない）
        fixture.service.setReactionResult = .failure(.notMember)
        await viewModel.choose(.cloud, for: sky, server: .empty, source: .timeline)
        // オフライン（見たよを付けようとする）
        fixture.recorder.isOnline = false
        await viewModel.choose(.eyes, for: sky, server: .empty, source: .timeline)
        // 押した人の一覧を開く
        viewModel.didOpenReactors(count: 2)

        // 6 個すべてを通ったことを先に確かめる（空回りで緑にしない）
        XCTAssertEqual(fixture.recorder.events, [
            .reactionAdded(kind: .sunset, source: .timeline, replaced: false),
            .reactionAdded(kind: .rainbow, source: .timeline, replaced: true),
            .reactionRemoved(source: .detail),
            .reactionFailed(action: .add, reason: .notMember),
            .reactionFailed(action: .add, reason: .offline),
            .reactionsViewed(reactionCount: 2),
        ])
        // kind は絵文字でなく名前
        let kinds = fixture.recorder.events.compactMap { $0.parameters["kind"] }
        XCTAssertEqual(kinds, [.value("sunset"), .value("rainbow")])

        let texts = fixture.recorder.events.flatMap(\.parameters.values).compactMap { value -> String? in
            if case let .value(text) = value { return text }
            return nil
        }
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            for id in ["uid-me-7f3a", "uid-other-k2p9", "group-9x2c", "sky-q8w1"] {
                XCTAssertFalse(text.contains(id), "計測の値「\(text)」に \(id) が入っている")
            }
        }
    }
}
