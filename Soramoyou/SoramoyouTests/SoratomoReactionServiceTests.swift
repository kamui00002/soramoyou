//
//  SoratomoReactionServiceTests.swift
//  SoramoyouTests
//
//  そらともの投稿へのリアクションのサービス（SoratomoReactionService）のテスト ⭐️（soratomo-reactions 7.5）
//  - 送る値: Callable の名前・制限時間・付けるとき／外すときの値
//  - 応答の読み方: outcome 4 種類と、kind が名前／null
//  - 失敗の写し方: not_member・sky_not_found・suspended・self_reaction・invalid_reaction・通信
//  - 形の違い: 失敗にせず「変わらなかった」と送った kind を返す
//
//  ⚠️ Functions には接続しない。窓口（SoratomoReactionDataSource）を偽物に差し替える。
//  ⚠️ 期待値は実装から組み立てず、文字列と値を直に書く（同じ式から作った 2 つを比べると、何もしない実装でも緑になる）。
//

import FirebaseFunctions
@testable import Soramoyou
import XCTest

// MARK: - 偽物

/// 窓口の偽物（呼ばれた引数を記録し、決めた結果を返す）
private final class FakeReactionDataSource: SoratomoReactionDataSource, @unchecked Sendable {
    // 返す結果
    var callResult: Result<Any, Error> = .success(["outcome": "added", "kind": "sunset"])

    // 呼ばれた引数
    private(set) var callCalls: [(name: String, payload: [String: Any], timeout: TimeInterval)] = []

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        callCalls.append((name, payload, timeout))
        return try callResult.get()
    }
}

final class SoratomoReactionServiceTests: XCTestCase {
    // MARK: - 部品

    private var dataSource: FakeReactionDataSource!
    private var service: SoratomoReactionService!

    override func setUp() {
        super.setUp()
        resetParts()
    }

    override func tearDown() {
        service = nil
        dataSource = nil
        super.tearDown()
    }

    /// 偽物とサービスを作り直す（1 つのテストで複数の場合を流すときにも使う）
    private func resetParts() {
        dataSource = FakeReactionDataSource()
        service = SoratomoReactionService(dataSource: dataSource)
    }

    /// Callable が返す失敗（サーバーが理由を付けるときは `details` に入れる）
    private func functionsError(_ code: FunctionsErrorCode, reason: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "サーバーの文言（画面に出さない）"]
        if let reason {
            userInfo[FunctionsErrorDetailsKey] = ["reason": reason]
        }
        return NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    /// サービスを呼んで、結果か失敗のどちらかを返す
    private func call(
        groupId: String = "g1",
        skyId: String = "s1",
        kind: SoratomoReactionKind? = .sunset
    ) async -> Result<SoratomoReactionChange, SoratomoError> {
        do {
            return try await .success(service.setReaction(groupId: groupId, skyId: skyId, kind: kind))
        } catch {
            return .failure(error)
        }
    }

    /// 失敗だけを取り出す（成功したら nil）
    private func failure(kind: SoratomoReactionKind? = .sunset) async -> SoratomoError? {
        if case let .failure(error) = await call(kind: kind) {
            return error
        }
        return nil
    }

    // MARK: - 送る値

    /// Callable の名前は soratomoSetReaction、制限時間は 20 秒
    func testSendsCallableNameAndTimeout() async {
        _ = await call()

        XCTAssertEqual(dataSource.callCalls.count, 1)
        XCTAssertEqual(dataSource.callCalls.first?.name, "soratomoSetReaction")
        XCTAssertEqual(dataSource.callCalls.first?.timeout, 20)
    }

    /// 付けるとき: groupId・skyId がそのまま、kind は名前の文字列
    func testSendsKindNameWhenSetting() async {
        _ = await call(groupId: "group-A", skyId: "sky-B", kind: .sunset)

        let payload = dataSource.callCalls.first?.payload
        XCTAssertEqual(payload?["groupId"] as? String, "group-A")
        XCTAssertEqual(payload?["skyId"] as? String, "sky-B")
        XCTAssertEqual(payload?["kind"] as? String, "sunset")
        XCTAssertEqual(payload?.count, 3)
    }

    /// 7 つの名前が、そのままの文字列で送られる（rawValue を直に書く）
    func testSendsEveryKindName() async {
        let cases: [(SoratomoReactionKind, String)] = [
            (.sunset, "sunset"),
            (.cloud, "cloud"),
            (.rainbow, "rainbow"),
            (.sparkles, "sparkles"),
            (.eyes, "eyes"),
            (.redHeart, "red_heart"),
            (.blueHeart, "blue_heart"),
        ]
        for (kind, name) in cases {
            resetParts()

            _ = await call(kind: kind)

            XCTAssertEqual(dataSource.callCalls.first?.payload["kind"] as? String, name, name)
        }
    }

    /// 外すとき: kind の鍵があり（省かない）、値は NSNull（JSON の null）
    func testSendsNullKindWithKeyWhenRemoving() async {
        dataSource.callResult = .success(["outcome": "removed", "kind": NSNull()])

        _ = await call(groupId: "group-A", skyId: "sky-B", kind: nil)

        let payload = dataSource.callCalls.first?.payload
        XCTAssertEqual(payload?.keys.contains("kind"), true, "kind の鍵を省くとサーバーが invalid_input で拒否する")
        XCTAssertTrue(payload?["kind"] is NSNull, "値は文字列でも空文字でもなく NSNull")
        XCTAssertEqual(payload?["groupId"] as? String, "group-A")
        XCTAssertEqual(payload?["skyId"] as? String, "sky-B")
        XCTAssertEqual(payload?.count, 3)
    }

    // MARK: - 応答の読み方

    /// outcome の 4 種類と、kind が名前のとき
    func testReadsOutcomeWithKindName() async throws {
        let cases: [(String, SoratomoReactionOutcome, String, SoratomoReactionKind)] = [
            ("added", .added, "sunset", .sunset),
            ("replaced", .replaced, "red_heart", .redHeart),
            ("unchanged", .unchanged, "eyes", .eyes),
        ]
        for (outcomeName, outcome, kindName, kind) in cases {
            resetParts()
            dataSource.callResult = .success(["outcome": outcomeName, "kind": kindName])

            let result = await call(kind: .cloud)

            // 送った kind(.cloud) ではなく、サーバーが返した kind を採る
            XCTAssertEqual(try result.get(), SoratomoReactionChange(outcome: outcome, kind: kind), outcomeName)
        }
    }

    /// 外したとき: outcome は removed、kind は null → nil
    func testReadsRemovedWithNullKind() async throws {
        dataSource.callResult = .success(["outcome": "removed", "kind": NSNull()])

        let result = await call(kind: nil)

        XCTAssertEqual(try result.get(), SoratomoReactionChange(outcome: .removed, kind: nil))
    }

    /// 変わらなかったとき、kind が null（付いていないのに外した）でも読める
    func testReadsUnchangedWithNullKind() async throws {
        dataSource.callResult = .success(["outcome": "unchanged", "kind": NSNull()])

        let result = await call(kind: .sunset)

        XCTAssertEqual(try result.get(), SoratomoReactionChange(outcome: .unchanged, kind: nil))
    }

    // MARK: - 失敗の写し方

    /// サーバーが理由を付けた失敗
    func testMapsDomainFailures() async {
        let cases: [(NSError, SoratomoError)] = [
            (functionsError(.permissionDenied, reason: "not_member"), .notMember),
            (functionsError(.notFound, reason: "sky_not_found"), .skyGone),
            (functionsError(.permissionDenied, reason: "suspended"), .suspended),
        ]
        for (failureValue, expected) in cases {
            resetParts()
            dataSource.callResult = .failure(failureValue)

            let error = await failure()

            XCTAssertEqual(error, expected, "\(failureValue)")
        }
    }

    /// 自分の投稿への操作・知らない絵文字・入力の不正は、種類を作らず `.unknown`
    func testMapsUnexpectedReasonsToUnknown() async {
        let cases: [NSError] = [
            functionsError(.failedPrecondition, reason: "self_reaction"),
            functionsError(.invalidArgument, reason: "invalid_reaction"),
            functionsError(.invalidArgument, reason: "invalid_input"),
        ]
        for failureValue in cases {
            resetParts()
            dataSource.callResult = .failure(failureValue)

            let error = await failure()

            XCTAssertEqual(error, .unknown, "\(failureValue)")
        }
    }

    /// 通信の失敗と制限時間切れは `.network`
    func testMapsCommunicationFailuresToNetwork() async {
        let cases: [Error] = [
            functionsError(.unavailable),
            functionsError(.deadlineExceeded),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
        ]
        for failureValue in cases {
            resetParts()
            dataSource.callResult = .failure(failureValue)

            let error = await failure()

            XCTAssertEqual(error, .network, "\(failureValue)")
        }
    }

    /// 失敗したときは結果を返さない（成功扱いにしない）
    func testFailureDoesNotReturnChange() async {
        dataSource.callResult = .failure(functionsError(.permissionDenied, reason: "not_member"))

        let result = await call()

        if case .success = result {
            XCTFail("失敗のときに結果が返った")
        }
    }

    // MARK: - 形の違い

    /// 形が違う応答は、投げずに「変わらなかった」と送った kind を返す（サーバーは書いた後に返すため）
    func testMalformedResponseReturnsUnchangedWithSentKind() async throws {
        let cases: [(String, Any)] = [
            ("辞書でない", "added"),
            ("NSNull", NSNull()),
            ("outcome が無い", ["kind": "sunset"]),
            ("outcome が知らない値", ["outcome": "deleted", "kind": "sunset"]),
            ("outcome が文字列でない", ["outcome": 1, "kind": "sunset"]),
            ("kind が知らない名前", ["outcome": "added", "kind": "fire"]),
            ("kind が文字列でも null でもない", ["outcome": "added", "kind": 3]),
            ("kind の鍵が無い", ["outcome": "added"]),
        ]
        for (label, response) in cases {
            resetParts()
            dataSource.callResult = .success(response)

            let result = await call(kind: .rainbow)

            // 送った kind は rainbow。サーバーが何を返していても、これに置き換わる
            XCTAssertEqual(
                try result.get(),
                SoratomoReactionChange(outcome: .unchanged, kind: .rainbow),
                label
            )
        }
    }

    /// 外す操作で形が違う応答は、送った kind（nil）で返す
    func testMalformedResponseWhenRemovingReturnsNilKind() async throws {
        dataSource.callResult = .success(["status": "ok"])

        let result = await call(kind: nil)

        XCTAssertEqual(try result.get(), SoratomoReactionChange(outcome: .unchanged, kind: nil))
    }

    // MARK: - 純関数

    /// 応答の読み方は、形が正しいときだけ値を返し、違えば nil
    func testChangeFromResponse() {
        XCTAssertEqual(
            SoratomoReactionService.change(from: ["outcome": "replaced", "kind": "blue_heart"]),
            SoratomoReactionChange(outcome: .replaced, kind: .blueHeart)
        )
        XCTAssertEqual(
            SoratomoReactionService.change(from: ["outcome": "removed", "kind": NSNull()]),
            SoratomoReactionChange(outcome: .removed, kind: nil)
        )
        XCTAssertNil(SoratomoReactionService.change(from: ["outcome": "added"]))
        XCTAssertNil(SoratomoReactionService.change(from: ["outcome": "nope", "kind": "sunset"]))
        XCTAssertNil(SoratomoReactionService.change(from: "added"))
    }
}
