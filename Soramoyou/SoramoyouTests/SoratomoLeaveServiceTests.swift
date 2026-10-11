//
//  SoratomoLeaveServiceTests.swift
//  SoramoyouTests
//
//  グループを抜けるサービス（SoratomoLeaveService）のテスト ⭐️（leave-group 7.1）
//  - 送る Callable の名前・値・制限時間
//  - 完了が返るまで呼び続けること、完了が返ったらそれ以上呼ばないこと
//  - 8 回で終わらないときの `.incomplete`
//  - 応答の `groupDeleted` は、どれか 1 回で真なら真
//  - 失敗の写し（通信・制限時間切れ → `.network`、それ以外 → `.unknown`）と、失敗したら呼び直さないこと
//  - 戻り値の形が違うとき
//  - メンバーの再確認（文書がある → `.member`、無い・権限の拒否 → `.notMember`、通信の失敗・それ以外 → `.unknown`）
//
//  ⚠️ Functions と Firestore には接続しない。窓口（SoratomoLeaveDataSource）を偽物に差し替える。
//

import FirebaseFirestore
import FirebaseFunctions
@testable import Soramoyou
import XCTest

// MARK: - 偽物

/// 窓口の偽物（呼ばれた引数を記録し、決めた結果を順に返す。使い切ったら最後の結果を返し続ける）
private final class FakeLeaveDataSource: SoratomoLeaveDataSource, @unchecked Sendable {
    // 返す結果（Callable は呼ばれた順）
    var results: [Result<Any, Error>] = [.success(["done": true, "groupDeleted": false])]
    var memberDocumentResult: Result<Bool, Error> = .success(true)
    // 返す uid（読まれた順。使い切ったら最後の値を返し続ける）
    var uids: [String?] = ["uAbCdEfGhIjKlMnOpQrStUvWxYz1"]

    // 呼ばれた引数
    private(set) var calls: [(name: String, payload: [String: Any], timeout: TimeInterval)] = []
    private(set) var memberDocumentCalls: [(groupId: String, uid: String)] = []
    private(set) var uidReads = 0

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        calls.append((name, payload, timeout))
        let index = min(calls.count - 1, results.count - 1)
        return try results[index].get()
    }

    func memberDocumentExistsOnServer(groupId: String, uid: String) async throws -> Bool {
        memberDocumentCalls.append((groupId, uid))
        return try memberDocumentResult.get()
    }

    func currentUid() -> String? {
        uidReads += 1
        return uids[min(uidReads - 1, uids.count - 1)]
    }
}

final class SoratomoLeaveServiceTests: XCTestCase {
    // MARK: - 部品

    /// 自動 ID の形のグループ ID と uid（中身に意味は無い）
    private static let groupId = "gAbCdEfGhIjKlMnOpQr1"
    private static let uid = "uAbCdEfGhIjKlMnOpQrStUvWxYz1"

    private var dataSource: FakeLeaveDataSource!
    private var service: SoratomoLeaveService!

    override func setUp() {
        super.setUp()
        resetParts()
    }

    /// 偽物とサービスを作り直す（1 つのテストで複数の場合を流すときにも使う）
    private func resetParts() {
        dataSource = FakeLeaveDataSource()
        service = SoratomoLeaveService(dataSource: dataSource)
    }

    override func tearDown() {
        service = nil
        dataSource = nil
        super.tearDown()
    }

    /// Callable が返す失敗（理由を付けるときは `details["reason"]` に入れる）
    private func functionsError(_ code: FunctionsErrorCode, reason: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "サーバーの文言（画面に出さない）"]
        if let reason {
            userInfo[FunctionsErrorDetailsKey] = ["reason": reason]
        }
        return NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    /// Firestore が返す失敗
    private func firestoreError(_ code: FirestoreErrorCode.Code) -> NSError {
        NSError(domain: FirestoreErrorDomain, code: code.rawValue, userInfo: nil)
    }

    /// 抜けるの戻り値か、投げた失敗
    private func leaveOutcome(groupId: String = SoratomoLeaveServiceTests.groupId) async
        -> Result<SoratomoLeaveResult, SoratomoLeaveError>
    {
        do {
            return try await .success(service.leave(groupId: groupId))
        } catch {
            return .failure(error)
        }
    }

    /// 応答の形（サーバーの `respond` と同じ 2 項目）
    private func response(done: Bool, groupDeleted: Bool = false) -> Result<Any, Error> {
        .success(["done": done, "groupDeleted": groupDeleted])
    }

    // MARK: - 送るもの

    /// Callable の名前は soratomoLeaveGroup、値は groupId だけ、制限時間は 75 秒（design.md の SoratomoLeaveService）
    func testLeaveSendsCallableNameGroupIdAndTimeout() async {
        let outcome = await leaveOutcome()

        XCTAssertEqual(outcome, .success(SoratomoLeaveResult(groupDeleted: false)))
        XCTAssertEqual(dataSource.calls.count, 1, "1 回目で完了したら、それ以上呼ばない")
        XCTAssertEqual(dataSource.calls.first?.name, "soratomoLeaveGroup")
        XCTAssertEqual(dataSource.calls.first?.payload.count, 1, "uid は送らない（サーバーは認証の uid だけを使う・要件 3.13）")
        XCTAssertEqual(dataSource.calls.first?.payload["groupId"] as? String, Self.groupId)
        XCTAssertEqual(dataSource.calls.first?.timeout, 75)
        XCTAssertEqual(SoratomoLeaveService.maxCalls, 8)
    }

    /// 文書 ID に使えない groupId（空・「/」を含む）は、呼ばずに `.unknown`
    func testLeaveWithUnusableGroupIdDoesNotCall() async {
        for groupId in ["", "a/b"] {
            resetParts()

            let outcome = await leaveOutcome(groupId: groupId)

            XCTAssertEqual(outcome, .failure(.unknown), "\(groupId)")
            XCTAssertTrue(dataSource.calls.isEmpty, "\(groupId)")
        }
    }

    // MARK: - 呼び直し（要件 4.3）

    /// ⭐️ 完了（done: true）が返るまで呼び続ける。返ったら止める
    func testLeaveCallsAgainUntilDone() async {
        dataSource.results = [
            response(done: false),
            response(done: false),
            response(done: false),
            response(done: true),
            response(done: false), // 呼ばれないはず
        ]

        let outcome = await leaveOutcome()

        XCTAssertEqual(outcome, .success(SoratomoLeaveResult(groupDeleted: false)))
        XCTAssertEqual(dataSource.calls.count, 4)
    }

    /// ⭐️ 8 回呼んでも終わらなければ `.incomplete`。9 回目は呼ばない
    func testLeaveGivesUpAfterMaxCallsWithIncomplete() async {
        dataSource.results = [response(done: false)]

        let outcome = await leaveOutcome()

        XCTAssertEqual(outcome, .failure(.incomplete))
        XCTAssertEqual(dataSource.calls.count, 8)
    }

    /// 8 回目で完了すれば成功
    func testLeaveSucceedsWhenDoneOnLastCall() async {
        dataSource.results = Array(repeating: response(done: false), count: 7) + [response(done: true)]

        let outcome = await leaveOutcome()

        XCTAssertEqual(outcome, .success(SoratomoLeaveResult(groupDeleted: false)))
        XCTAssertEqual(dataSource.calls.count, 8)
    }

    // MARK: - groupDeleted

    /// ⭐️ 応答の `groupDeleted` は、どれか 1 回で真なら真（再試行の間にほかの人が抜けて、後の回で真に変わることがある）
    func testLeaveGroupDeletedIsTrueIfAnyCallSaysTrue() async {
        let cases: [(name: String, results: [Result<Any, Error>], expected: Bool)] = [
            ("すべて偽", [response(done: false), response(done: true)], false),
            ("1 回で完了・真", [response(done: true, groupDeleted: true)], true),
            ("途中の回だけ真", [response(done: false), response(done: false, groupDeleted: true), response(done: true)], true),
            ("最後の回だけ真", [response(done: false), response(done: true, groupDeleted: true)], true),
        ]
        for testCase in cases {
            resetParts()
            dataSource.results = testCase.results

            let outcome = await leaveOutcome()

            XCTAssertEqual(outcome, .success(SoratomoLeaveResult(groupDeleted: testCase.expected)), testCase.name)
        }
    }

    // MARK: - 失敗の写し（要件 4.4）

    /// 通信・制限時間切れは `.network`。失敗したら呼び直さない
    func testLeaveMapsNetworkFailuresToNetworkWithoutRetrying() async {
        let cases: [Error] = [
            functionsError(.unavailable),
            functionsError(.deadlineExceeded),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
        ]
        for failure in cases {
            resetParts()
            dataSource.results = [.failure(failure), response(done: true)]

            let outcome = await leaveOutcome()

            XCTAssertEqual(outcome, .failure(.network), "\(failure)")
            XCTAssertEqual(dataSource.calls.count, 1, "失敗したら呼び直さない: \(failure)")
        }
    }

    /// 通信以外の失敗（未ログイン・サーバーの失敗・理由つきの拒否など）は `.unknown`。失敗したら呼び直さない
    func testLeaveMapsOtherFailuresToUnknown() async {
        let cases: [Error] = [
            functionsError(.unauthenticated),
            functionsError(.internal),
            functionsError(.invalidArgument, reason: "invalid_input"),
            functionsError(.failedPrecondition, reason: "not_member"),
            NSError(domain: "other", code: 1),
        ]
        for failure in cases {
            resetParts()
            dataSource.results = [.failure(failure), response(done: true)]

            let outcome = await leaveOutcome()

            XCTAssertEqual(outcome, .failure(.unknown), "\(failure)")
            XCTAssertEqual(dataSource.calls.count, 1, "失敗したら呼び直さない: \(failure)")
        }
    }

    /// ⭐️ 繰り返しの途中でアカウントが替わったら（サインアウトを含む）、次の回を送らずに止める（/review-full D1）
    ///
    /// Callable は回ごとにその時点の利用者のトークンで送られる。止めないと、同じグループに入っている
    /// 別のアカウントが、確認なしに抜けてしまう（投稿も消えて戻せない）。
    func testLeaveStopsWhenAccountChangesBetweenCalls() async {
        let cases: [(label: String, after: String?)] = [("別のアカウント", "uZyXwVuTsRqPoNmLkJiHgFeDcBa9"), ("サインアウト", nil)]
        for (label, after) in cases {
            resetParts()
            dataSource.results = [response(done: false)]
            // 1 回目の前までは同じ利用者、2 回目の前から替わる（読み口は回の前に 1 回ずつ・最初に覚えるので 1 回多い）
            dataSource.uids = [Self.uid, Self.uid, after]

            let outcome = await leaveOutcome()

            XCTAssertEqual(outcome, .failure(.unknown), label)
            XCTAssertEqual(dataSource.calls.count, 1, "\(label): 替わった後に呼んだ")
        }
    }

    /// 途中の回で失敗したら、そこで止めて失敗を投げる
    func testLeaveStopsOnFailureAfterPartialProgress() async {
        dataSource.results = [response(done: false), .failure(functionsError(.unavailable)), response(done: true)]

        let outcome = await leaveOutcome()

        XCTAssertEqual(outcome, .failure(.network))
        XCTAssertEqual(dataSource.calls.count, 2)
    }

    /// 戻り値の形が違えば `.unknown`（呼び直さない）
    func testLeaveRejectsMalformedResponse() async {
        let cases: [Any] = [
            ["done": true], // groupDeleted が無い
            ["groupDeleted": false], // done が無い
            ["done": "true", "groupDeleted": false],
            ["done": true, "groupDeleted": "false"],
            "done",
            NSNull(),
        ]
        for response in cases {
            resetParts()
            dataSource.results = [.success(response)]

            let outcome = await leaveOutcome()

            XCTAssertEqual(outcome, .failure(.unknown), "\(response)")
            XCTAssertEqual(dataSource.calls.count, 1, "\(response)")
        }
    }

    // MARK: - メンバーの再確認（要件 4.4・4.5・要確認 Q2 の前半）

    /// 文書があれば `.member`。読むのは自分のメンバーの文書（グループ ID と uid をそのまま渡す）
    func testMembershipIsMemberWhenDocumentExists() async {
        dataSource.memberDocumentResult = .success(true)

        let check = await service.membershipOnServer(groupId: Self.groupId, uid: Self.uid)

        XCTAssertEqual(check, .member)
        XCTAssertEqual(dataSource.memberDocumentCalls.count, 1)
        XCTAssertEqual(dataSource.memberDocumentCalls.first?.groupId, Self.groupId)
        XCTAssertEqual(dataSource.memberDocumentCalls.first?.uid, Self.uid)
    }

    /// サーバーで文書が無いと確かめられたら `.notMember`（design.md に無い枝・グループの監視の前例に合わせた）
    func testMembershipIsNotMemberWhenDocumentIsAbsentOnServer() async {
        dataSource.memberDocumentResult = .success(false)

        let check = await service.membershipOnServer(groupId: Self.groupId, uid: Self.uid)

        XCTAssertEqual(check, .notMember)
    }

    /// ⭐️ 権限の拒否は `.notMember`（メンバーでなければ、ルールが自分のメンバーの文書の読みを拒否する）
    func testMembershipIsNotMemberWhenPermissionDenied() async {
        dataSource.memberDocumentResult = .failure(firestoreError(.permissionDenied))

        let check = await service.membershipOnServer(groupId: Self.groupId, uid: Self.uid)

        XCTAssertEqual(check, .notMember)
    }

    /// 通信の失敗は `.unknown`（確かめられなかった。メンバーでないとは決めない）
    func testMembershipIsUnknownWhenNetworkFails() async {
        let cases: [Error] = [
            firestoreError(.unavailable),
            firestoreError(.deadlineExceeded),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
        ]
        for failure in cases {
            resetParts()
            dataSource.memberDocumentResult = .failure(failure)

            let check = await service.membershipOnServer(groupId: Self.groupId, uid: Self.uid)

            XCTAssertEqual(check, .unknown, "\(failure)")
        }
    }

    /// それ以外の失敗も `.unknown`。`notFound` は要確認 Q2 を確かめるまで `.unknown` のまま（記録には残る）
    func testMembershipIsUnknownForOtherFailures() async {
        let cases: [Error] = [
            firestoreError(.notFound),
            firestoreError(.internal),
            firestoreError(.unauthenticated),
            NSError(domain: "other", code: 1),
        ]
        for failure in cases {
            resetParts()
            dataSource.memberDocumentResult = .failure(failure)

            let check = await service.membershipOnServer(groupId: Self.groupId, uid: Self.uid)

            XCTAssertEqual(check, .unknown, "\(failure)")
        }
    }

    /// 文書 ID に使えないグループ ID・uid（空・「/」を含む）は、読まずに `.unknown`
    func testMembershipWithUnusableIdsDoesNotRead() async {
        let cases: [(groupId: String, uid: String)] = [
            ("", Self.uid),
            ("a/b", Self.uid),
            (Self.groupId, ""),
            (Self.groupId, "x/y"),
        ]
        for testCase in cases {
            resetParts()

            let check = await service.membershipOnServer(groupId: testCase.groupId, uid: testCase.uid)

            XCTAssertEqual(check, .unknown, "\(testCase)")
            XCTAssertTrue(dataSource.memberDocumentCalls.isEmpty, "\(testCase)")
        }
    }
}
