//
//  SoratomoGuidelineServiceTests.swift
//  SoramoyouTests
//
//  そらともガイドラインへの同意のサービス（SoratomoGuidelineService）のテスト ⭐️（release-gate 9.5）
//  - 同意の状態: 文書の項目の読み方（無い・型が違う）、読み取りの失敗の写し
//  - 同意の記録: 送る Callable の名前・値・制限時間、失敗の写し、戻り値の形
//
//  ⚠️ Functions と Firestore には接続しない。窓口（SoratomoGuidelineDataSource）を偽物に差し替える。
//

import FirebaseFirestore
import FirebaseFunctions
@testable import Soramoyou
import XCTest

// MARK: - 偽物

/// 窓口の偽物（呼ばれた引数を記録し、決めた結果を返す）
private final class FakeGuidelineDataSource: SoratomoGuidelineDataSource, @unchecked Sendable {
    // 返す結果
    var callResult: Result<Any, Error> = .success(["version": 1])
    var fetchUserIndexResult: Result<[String: Any]?, Error> = .success(nil)

    // 呼ばれた引数
    private(set) var callCalls: [(name: String, payload: [String: Any], timeout: TimeInterval)] = []
    private(set) var fetchUserIndexCalls: [String] = []

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        callCalls.append((name, payload, timeout))
        return try callResult.get()
    }

    func fetchUserIndex(uid: String) async throws -> [String: Any]? {
        fetchUserIndexCalls.append(uid)
        return try fetchUserIndexResult.get()
    }
}

final class SoratomoGuidelineServiceTests: XCTestCase {
    // MARK: - 部品

    private var dataSource: FakeGuidelineDataSource!
    private var service: SoratomoGuidelineService!

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
        dataSource = FakeGuidelineDataSource()
        service = SoratomoGuidelineService(dataSource: dataSource)
    }

    /// Callable が返す失敗（サーバーが理由を付けるときは `details` に入れる）
    private func functionsError(_ code: FunctionsErrorCode, details: [String: Any]? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "サーバーの文言（画面に出さない）"]
        if let details {
            userInfo[FunctionsErrorDetailsKey] = details
        }
        return NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    private func fetchError(uid: String = "u1") async -> SoratomoError? {
        do {
            _ = try await service.fetchConsentStatus(uid: uid)
            return nil
        } catch {
            return error
        }
    }

    private func agreeError(version: Int = 1) async -> SoratomoError? {
        do {
            try await service.agree(version: version)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 同意の状態

    /// 文書の項目（同意した版・所属数）を読む
    func testFetchConsentStatusReadsVersionAndGroupCount() async throws {
        dataSource.fetchUserIndexResult = .success(["guidelineVersion": 1, "groupCount": 3, "suspendedAt": "x"])

        let status = try await service.fetchConsentStatus(uid: "u1")

        XCTAssertEqual(status, SoratomoConsentStatus(agreedVersion: 1, groupCount: 3))
        XCTAssertEqual(dataSource.fetchUserIndexCalls, ["u1"])
    }

    /// 文書が無い・項目が無い・型が違うときは「未同意・所属 0」
    func testConsentStatusDefaultsWhenMissingOrMalformed() {
        let cases: [(String, [String: Any]?)] = [
            ("文書なし", nil),
            ("項目なし", [:]),
            ("型が違う", ["guidelineVersion": "1", "groupCount": "2"]),
        ]
        for (label, fields) in cases {
            XCTAssertEqual(
                SoratomoGuidelineService.consentStatus(from: fields),
                SoratomoConsentStatus(agreedVersion: nil, groupCount: 0),
                label
            )
        }
    }

    /// 読み取りの失敗: 通信は `.network`、それ以外は `.unknown`
    func testFetchConsentStatusMapsFailures() async {
        let cases: [(Error, SoratomoError)] = [
            (NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.Code.unavailable.rawValue), .network),
            (NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.Code.permissionDenied.rawValue), .unknown),
            (NSError(domain: "other", code: 1), .unknown),
        ]
        for (failure, expected) in cases {
            resetParts()
            dataSource.fetchUserIndexResult = .failure(failure)

            let error = await fetchError()

            XCTAssertEqual(error, expected, "\(failure)")
        }
    }

    /// 文書のパスに使えない uid は、読まずに `.unknown`
    func testFetchConsentStatusRejectsUnusableUid() async {
        let error = await fetchError(uid: "")

        XCTAssertEqual(error, .unknown)
        XCTAssertTrue(dataSource.fetchUserIndexCalls.isEmpty)
    }

    // MARK: - 同意の記録

    /// Callable の名前は soratomoAgreeGuideline、値は { version }、制限時間は 20 秒
    func testAgreeSendsCallableNamePayloadAndTimeout() async {
        let error = await agreeError(version: 1)

        XCTAssertNil(error)
        XCTAssertEqual(dataSource.callCalls.count, 1)
        XCTAssertEqual(dataSource.callCalls.first?.name, "soratomoAgreeGuideline")
        XCTAssertEqual(dataSource.callCalls.first?.payload["version"] as? Int, 1)
        XCTAssertEqual(dataSource.callCalls.first?.payload.count, 1)
        XCTAssertEqual(dataSource.callCalls.first?.timeout, 20)
    }

    /// 失敗の写し（通信・アプリが古い・その他）
    func testAgreeMapsFailures() async {
        let app = SoratomoGuideline.currentVersion
        let cases: [(Error, SoratomoError)] = [
            (functionsError(.unavailable), .network),
            (functionsError(.deadlineExceeded), .network),
            (functionsError(.failedPrecondition, details: ["reason": "outdated_guideline", "currentVersion": app + 1]), .outdatedApp),
            (functionsError(.internal), .unknown),
        ]
        for (failure, expected) in cases {
            resetParts()
            dataSource.callResult = .failure(failure)

            let error = await agreeError()

            XCTAssertEqual(error, expected, "\(failure)")
        }
    }

    /// 戻り値の形が違えば `.unknown`
    func testAgreeRejectsMalformedResponse() async {
        let cases: [Any] = [["version": "1"], ["ok": true], "version", NSNull()]
        for response in cases {
            resetParts()
            dataSource.callResult = .success(response)

            let error = await agreeError()

            XCTAssertEqual(error, .unknown, "\(response)")
        }
    }
}
