//
//  SoratomoNotificationPrimerTests.swift
//  SoramoyouTests
//
//  そらともの通知の事前説明（SoratomoNotificationPrimer）の判定と、選んだ操作の処理のテスト ⭐️（tasks 12.2）
//
//  端末の許可状態・UserDefaults・許可の要求・計測は、すべて差し替えたもので確かめる。
//  本物の許可ダイアログと通知センターには触れない。
//  （既定の許可の要求が `PushNotificationManager` を通ることは、OS の許可ダイアログが要るので、
//   単体テストでは確かめない。実機で確かめる）
//

@testable import Soramoyou
import UserNotifications
import XCTest

@MainActor
final class SoratomoNotificationPrimerTests: XCTestCase {
    // MARK: - 差し替えるもの

    /// 差し替えた窓口の記録（許可状態・許可の要求・計測）
    @MainActor
    private final class Probe {
        /// 端末の通知許可の状態（`decide()` が呼ばれるたびに、この時点の値を読む）
        var status: UNAuthorizationStatus = .notDetermined
        /// 許可の要求が返す結果
        var requestResult = true
        /// 許可の要求が呼ばれた回数
        private(set) var requestCount = 0
        /// 記録された計測イベント
        private(set) var events: [SoratomoEvent] = []
        /// true にすると、次の許可の要求を `release(granted:)` まで止める（ダイアログの待ち中の操作を試すため）
        var holdNextRequest = false
        private var held: CheckedContinuation<Bool, Never>?
        var isHolding: Bool {
            held != nil
        }

        func request() async -> Bool {
            requestCount += 1
            if holdNextRequest {
                holdNextRequest = false
                return await withCheckedContinuation { held = $0 }
            }
            return requestResult
        }

        func release(granted: Bool) {
            held?.resume(returning: granted)
            held = nil
        }

        func record(_ event: SoratomoEvent) {
            events.append(event)
        }
    }

    /// このテスト専用の UserDefaults の名前（アプリ本体の記録と混ざらないようにする）
    private static let suiteName = "SoratomoNotificationPrimerTests"

    private var probe: Probe!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        probe = Probe()
        defaults = UserDefaults(suiteName: Self.suiteName)
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    /// 差し替えた窓口で組み立てた実物
    private func makePrimer() -> SoratomoNotificationPrimer {
        let recorder = probe!
        return SoratomoNotificationPrimer(
            readAuthorizationStatus: { recorder.status },
            defaults: defaults,
            requestAuthorization: { await recorder.request() },
            log: { recorder.record($0) }
        )
    }

    /// 「出した」記録を、テストの前提として先に書く
    private func seed(primerShown: Bool, guideShown: Bool) {
        defaults.set(primerShown, forKey: SoratomoNotificationPrimer.primerShownKey)
        defaults.set(guideShown, forKey: SoratomoNotificationPrimer.settingsGuideShownKey)
    }

    // MARK: - decide: 許可状態と既読の組み合わせ

    /// 許可状態 5 種 × 既読 4 通りの 20 通りの判定（期待値は要件 10.1・10.5 を 1 行ずつ写したもの）
    func testDecideForEveryStatusAndRecordCombination() async {
        typealias D = SoratomoPrimerDecision
        // (許可状態, 事前説明を出した, 設定の案内を出した, 期待する判定)
        let table: [(UNAuthorizationStatus, Bool, Bool, D)] = [
            // 未決定: 事前説明を出していなければ事前説明。案内の記録は関係しない
            (.notDetermined, false, false, .showPrimer),
            (.notDetermined, false, true, .showPrimer),
            (.notDetermined, true, false, D.none),
            (.notDetermined, true, true, D.none),
            // 拒否: 設定の案内を出していなければ案内。事前説明の記録は関係しない
            (.denied, false, false, .showSettingsGuide),
            (.denied, true, false, .showSettingsGuide),
            (.denied, false, true, D.none),
            (.denied, true, true, D.none),
            // 許可済み（仮の許可・一時的な許可を含む）: 記録にかかわらず何も出さない
            (.authorized, false, false, D.none),
            (.authorized, true, false, D.none),
            (.authorized, false, true, D.none),
            (.authorized, true, true, D.none),
            (.provisional, false, false, D.none),
            (.provisional, true, false, D.none),
            (.provisional, false, true, D.none),
            (.provisional, true, true, D.none),
            (.ephemeral, false, false, D.none),
            (.ephemeral, true, false, D.none),
            (.ephemeral, false, true, D.none),
            (.ephemeral, true, true, D.none),
        ]
        XCTAssertEqual(table.count, 20)

        for (status, primerShown, guideShown, expected) in table {
            probe.status = status
            seed(primerShown: primerShown, guideShown: guideShown)
            let decision = await makePrimer().decide()
            XCTAssertEqual(
                decision, expected,
                "status=\(status.rawValue) primerShown=\(primerShown) guideShown=\(guideShown)"
            )
        }
    }

    /// 判定は、呼ぶたびに端末の許可状態を読み直す（前の結果を使い回さない）
    func testDecideReadsTheStatusEveryTime() async {
        let primer = makePrimer()

        probe.status = .notDetermined
        var decision = await primer.decide()
        XCTAssertEqual(decision, .showPrimer)

        probe.status = .denied
        decision = await primer.decide()
        XCTAssertEqual(decision, .showSettingsGuide)

        probe.status = .authorized
        decision = await primer.decide()
        XCTAssertEqual(decision, SoratomoPrimerDecision.none)
    }

    /// 判定しただけでは「出した」ことにならない（出せなかったときに、もう一度判定できる）
    func testDecideDoesNotWriteAnyRecord() async {
        let primer = makePrimer()

        probe.status = .notDetermined
        let first = await primer.decide()
        let second = await primer.decide()
        XCTAssertEqual(first, .showPrimer)
        XCTAssertEqual(second, .showPrimer)

        probe.status = .denied
        let third = await primer.decide()
        let fourth = await primer.decide()
        XCTAssertEqual(third, .showSettingsGuide)
        XCTAssertEqual(fourth, .showSettingsGuide)

        XCTAssertFalse(defaults.bool(forKey: SoratomoNotificationPrimer.primerShownKey))
        XCTAssertFalse(defaults.bool(forKey: SoratomoNotificationPrimer.settingsGuideShownKey))
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertEqual(probe.requestCount, 0)
    }

    // MARK: - handle: 「あとで」

    /// 「あとで」は許可を要求せず、計測を 1 回だけ記録し、事前説明を再び出さない（10.4）
    func testLaterDoesNotRequestAndRecordsOnceAndStopsThePrimer() async {
        probe.status = .notDetermined
        let primer = makePrimer()
        let before = await primer.decide()
        XCTAssertEqual(before, .showPrimer)

        let granted = await primer.handle(choice: .later)

        XCTAssertFalse(granted)
        XCTAssertEqual(probe.requestCount, 0, "「あとで」で OS の許可ダイアログを出してはいけない")
        XCTAssertEqual(probe.events, [.notificationPromptResult(choice: .later, granted: false)])
        XCTAssertTrue(defaults.bool(forKey: SoratomoNotificationPrimer.primerShownKey))

        // 端末の許可は未決定のままでも、もう事前説明は出さない
        let after = await primer.decide()
        XCTAssertEqual(after, SoratomoPrimerDecision.none)
    }

    // MARK: - handle: 「通知を受け取る」

    /// 「通知を受け取る」で許可されたら、許可の要求を 1 回だけ通し、許可の結果を記録して返す（10.3）
    func testAllowRequestsOnceAndRecordsGranted() async {
        probe.status = .notDetermined
        probe.requestResult = true
        let primer = makePrimer()

        let granted = await primer.handle(choice: .allow)

        XCTAssertTrue(granted)
        XCTAssertEqual(probe.requestCount, 1)
        XCTAssertEqual(probe.events, [.notificationPromptResult(choice: .allow, granted: true)])
        XCTAssertTrue(defaults.bool(forKey: SoratomoNotificationPrimer.primerShownKey))
    }

    /// OS の許可ダイアログで拒否されたら granted=false を返して記録し、その後は設定の案内の対象になる
    func testAllowDeniedRecordsNotGrantedThenGuidesToSettings() async {
        probe.status = .notDetermined
        probe.requestResult = false
        let primer = makePrimer()

        let granted = await primer.handle(choice: .allow)

        XCTAssertFalse(granted)
        XCTAssertEqual(probe.requestCount, 1)
        XCTAssertEqual(probe.events, [.notificationPromptResult(choice: .allow, granted: false)])

        // OS の許可が「拒否」に変わった後の次の判定: 事前説明は出さず、まだ出していない設定の案内を出す
        probe.status = .denied
        let decision = await primer.decide()
        XCTAssertEqual(decision, .showSettingsGuide)
    }

    // MARK: - handle: 1 回だけ

    /// 選んだ後の 2 回目は、何も要求せず、計測も増やさない（選んだときに 1 回だけ記録する）
    func testSecondHandleAfterChoiceDoesNothing() async {
        let primer = makePrimer()

        let first = await primer.handle(choice: .later)
        let second = await primer.handle(choice: .allow)
        let third = await primer.handle(choice: .later)

        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertFalse(third)
        XCTAssertEqual(probe.requestCount, 0)
        XCTAssertEqual(probe.events, [.notificationPromptResult(choice: .later, granted: false)])
    }

    /// 許可ダイアログの待ち中の連打は、許可の要求も計測も 2 つ目を作らない
    func testSecondAllowWhileWaitingForTheDialogDoesNothing() async {
        probe.holdNextRequest = true
        let primer = makePrimer()

        let first = Task { await primer.handle(choice: .allow) }
        // 1 回目が許可の要求で止まるまで待つ（上限つき）
        var spins = 0
        while !probe.isHolding, spins < 1000 {
            await Task.yield()
            spins += 1
        }
        guard probe.isHolding else {
            XCTFail("1 回目の許可の要求が始まらなかった")
            return
        }

        let second = await primer.handle(choice: .allow)
        XCTAssertFalse(second)
        XCTAssertEqual(probe.requestCount, 1)
        XCTAssertTrue(probe.events.isEmpty, "許可の結果が出るまで、計測は記録しない")

        probe.release(granted: true)
        let firstResult = await first.value
        XCTAssertTrue(firstResult)
        XCTAssertEqual(probe.requestCount, 1)
        XCTAssertEqual(probe.events, [.notificationPromptResult(choice: .allow, granted: true)])
    }

    /// 許可ダイアログの待ち中でも、選んだ時点で「出した」記録は残っている（待ち中にアプリが終了されても再び出さない）
    func testPrimerIsMarkedShownAsSoonAsAllowIsChosen() async {
        probe.holdNextRequest = true
        let primer = makePrimer()

        let task = Task { await primer.handle(choice: .allow) }
        var spins = 0
        while !probe.isHolding, spins < 1000 {
            await Task.yield()
            spins += 1
        }
        guard probe.isHolding else {
            XCTFail("許可の要求が始まらなかった")
            return
        }

        XCTAssertTrue(defaults.bool(forKey: SoratomoNotificationPrimer.primerShownKey))
        probe.release(granted: false)
        _ = await task.value
    }

    // MARK: - markSettingsGuideShown

    /// 設定の案内を出したと記録すると、拒否のままでも、もう案内しない（10.5）
    func testMarkSettingsGuideShownStopsTheGuide() async {
        probe.status = .denied
        let primer = makePrimer()
        let before = await primer.decide()
        XCTAssertEqual(before, .showSettingsGuide)

        primer.markSettingsGuideShown()
        // 何度呼んでも同じ
        primer.markSettingsGuideShown()

        let after = await primer.decide()
        XCTAssertEqual(after, SoratomoPrimerDecision.none)
        XCTAssertTrue(probe.events.isEmpty, "設定の案内は計測を記録しない")
        XCTAssertEqual(probe.requestCount, 0)
    }

    /// 2 つの記録は独立している（案内を出しても事前説明の記録は変わらず、逆も同じ）
    func testTheTwoRecordsAreIndependent() async {
        let primer = makePrimer()

        primer.markSettingsGuideShown()
        XCTAssertFalse(defaults.bool(forKey: SoratomoNotificationPrimer.primerShownKey))
        probe.status = .notDetermined
        let primerStillShown = await primer.decide()
        XCTAssertEqual(primerStillShown, .showPrimer)

        _ = await primer.handle(choice: .later)
        XCTAssertTrue(defaults.bool(forKey: SoratomoNotificationPrimer.primerShownKey))
        XCTAssertTrue(defaults.bool(forKey: SoratomoNotificationPrimer.settingsGuideShownKey))
    }

    // MARK: - 記録のキー

    /// 記録のキーは design.md のとおり（変えると、既に見た人にもう一度出てしまう）
    func testRecordKeysMatchTheDesign() {
        XCTAssertEqual(SoratomoNotificationPrimer.primerShownKey, "soratomo.notificationPrimerShown")
        XCTAssertEqual(SoratomoNotificationPrimer.settingsGuideShownKey, "soratomo.notificationSettingsGuideShown")
    }

    // MARK: - 文言（要件 10.2・10.17）

    /// 事前説明の文言は要件 10.2 のとおり
    func testPrimerCopyMatchesRequirement() {
        XCTAssertEqual(SoratomoNotificationPrimerCopy.primerMessage, "友達が空を投稿したらお知らせします")
        XCTAssertEqual(SoratomoNotificationPrimerCopy.allowButton, "通知を受け取る")
        XCTAssertEqual(SoratomoNotificationPrimerCopy.laterButton, "あとで")
    }

    /// 設定の案内は、設定アプリで通知を許可する方法（手順）と、設定アプリを開く操作を持つ（10.5）
    func testSettingsGuideHasStepsAndAnOpenAction() {
        XCTAssertFalse(SoratomoNotificationPrimerCopy.guideSteps.isEmpty)
        XCTAssertTrue(SoratomoNotificationPrimerCopy.guideSteps.contains { $0.contains("設定") })
        XCTAssertFalse(SoratomoNotificationPrimerCopy.guideOpenButton.isEmpty)
    }

    /// 画面に出る文言のどれにも、「グループごとに通知をオフにできる」と読める言い方を入れない（10.17）
    func testCopyNeverMentionsPerGroupNotificationOff() {
        // 「グループ」という言葉自体を使わない（この画面は「友達」で説明する）。
        // 「ごとに」「個別」「単位」も、グループ単位の切り替えを匂わせるので使わない
        let forbidden = ["グループ", "ごとに", "個別", "単位"]
        for text in SoratomoNotificationPrimerCopy.allTexts {
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "「\(text)」に「\(word)」が含まれている")
            }
        }
        XCTAssertFalse(SoratomoNotificationPrimerCopy.allTexts.isEmpty)
    }
}
