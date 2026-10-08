//
//  SoratomoModerationServiceTests.swift
//  SoramoyouTests
//
//  そらともの通報とブロックのサービス（SoratomoModerationService）のテスト ⭐️（release-gate 9.2）
//  - 通報: 送る Callable の名前・値・制限時間、成功、通信の失敗、投稿がもう無い、その他の失敗、戻り値の形
//  - ブロック: 窓口に渡す値、保存できたら `.userBlocked` を 1 回送ること、失敗したら送らないこと
//  - ブロックの一覧の読み取り
//
//  ⚠️ Functions と Firestore には接続しない。窓口（SoratomoModerationDataSource）を偽物に差し替える。
//     本物のトランザクションが圏外で失敗すること（端末内に積まれないこと）は、実機での確認が要る（tasks 16.2）。
//

import FirebaseFirestore
import FirebaseFunctions
@testable import Soramoyou
import XCTest

// MARK: - 偽物

/// 窓口の偽物（呼ばれた引数を記録し、決めた結果を返す）
private final class FakeModerationDataSource: SoratomoModerationDataSource, @unchecked Sendable {
    // 返す結果
    var callResult: Result<Any, Error> = .success(["accepted": true])
    var addBlockedUserIdError: Error?
    var fetchBlockedUserIdsResult: Result<[String], Error> = .success([])

    // 呼ばれた引数
    private(set) var callCalls: [(name: String, payload: [String: Any], timeout: TimeInterval)] = []
    private(set) var addBlockedUserIdCalls: [(authorId: String, uid: String)] = []
    private(set) var fetchBlockedUserIdsCalls: [String] = []

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        callCalls.append((name, payload, timeout))
        return try callResult.get()
    }

    func addBlockedUserId(_ authorId: String, uid: String) async throws {
        addBlockedUserIdCalls.append((authorId, uid))
        if let addBlockedUserIdError {
            throw addBlockedUserIdError
        }
    }

    func fetchBlockedUserIds(uid: String) async throws -> [String] {
        fetchBlockedUserIdsCalls.append(uid)
        return try fetchBlockedUserIdsResult.get()
    }
}

/// 通知センターに届いた `.userBlocked` を記録する
///
/// `queue: nil` で購読するので、送った側の流れの中で同期的に記録される（待たずに件数を数えられる）。
private final class UserBlockedRecorder {
    /// 届いた通知の userInfo の uid（無ければ nil）
    private(set) var blockedIds: [String?] = []
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter) {
        self.center = center
        observer = center.addObserver(forName: .userBlocked, object: nil, queue: nil) { [weak self] notification in
            self?.blockedIds.append(notification.userInfo?[Notification.blockedUserIdKey] as? String)
        }
    }

    deinit {
        if let observer {
            center.removeObserver(observer)
        }
    }
}

final class SoratomoModerationServiceTests: XCTestCase {
    // MARK: - 部品

    private var dataSource: FakeModerationDataSource!
    private var center: NotificationCenter!
    private var recorder: UserBlockedRecorder!
    private var service: SoratomoModerationService!

    override func setUp() {
        super.setUp()
        dataSource = FakeModerationDataSource()
        center = NotificationCenter()
        recorder = UserBlockedRecorder(center: center)
        service = SoratomoModerationService(dataSource: dataSource, notificationCenter: center)
    }

    override func tearDown() {
        service = nil
        recorder = nil
        center = nil
        dataSource = nil
        super.tearDown()
    }

    /// Callable が返す失敗（サーバーが理由を付けるときは `details["reason"]` に入れる）
    private func functionsError(_ code: FunctionsErrorCode, reason: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "サーバーの文言（画面に出さない）"]
        if let reason {
            userInfo[FunctionsErrorDetailsKey] = ["reason": reason]
        }
        return NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    /// Firestore が返す失敗
    private func firestoreError(_ code: FirestoreErrorCode.Code) -> NSError {
        NSError(domain: FirestoreErrorDomain, code: code.rawValue)
    }

    /// 機内モード・圏外の通信エラー
    private var offlineError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    }

    /// 投げられたエラーを `SoratomoError` として取り出す（`SoratomoError` 以外なら nil）
    private func soratomoError(_ error: Error) -> SoratomoError? {
        error as? SoratomoError
    }

    // MARK: - 通報

    /// 通報は `soratomoReportSky` を、groupId・skyId・理由の rawValue で、制限時間 20 秒で呼ぶ
    func testReportSendsCallableNamePayloadAndTimeout() async throws {
        try await service.report(groupId: "group1", skyId: "sky1", reason: .spam)

        XCTAssertEqual(dataSource.callCalls.count, 1)
        let call = try XCTUnwrap(dataSource.callCalls.first)
        XCTAssertEqual(call.name, "soratomoReportSky")
        XCTAssertEqual(call.timeout, 20)
        XCTAssertEqual(call.payload.count, 3)
        XCTAssertEqual(call.payload["groupId"] as? String, "group1")
        XCTAssertEqual(call.payload["skyId"] as? String, "sky1")
        XCTAssertEqual(call.payload["reason"] as? String, "spam")
        // 通報では、ブロックの通知を送らない
        XCTAssertEqual(recorder.blockedIds, [])
    }

    /// 通信の失敗・制限時間切れは `.network`
    func testReportMapsNetworkFailuresToNetwork() async {
        let cases: [Error] = [functionsError(.unavailable), functionsError(.deadlineExceeded), offlineError]
        for underlying in cases {
            dataSource.callResult = .failure(underlying)
            do {
                try await service.report(groupId: "group1", skyId: "sky1", reason: .other)
                XCTFail("通信の失敗で成功してはいけない: \(underlying)")
            } catch {
                XCTAssertEqual(soratomoError(error), .network, "\(underlying)")
            }
        }
    }

    /// 投稿がもう無い（`sky_not_found`）は `.skyGone`
    func testReportMapsSkyNotFoundToSkyGone() async {
        dataSource.callResult = .failure(functionsError(.notFound, reason: "sky_not_found"))
        do {
            try await service.report(groupId: "group1", skyId: "sky1", reason: .inappropriate)
            XCTFail("投稿が無いのに成功してはいけない")
        } catch {
            XCTAssertEqual(soratomoError(error), .skyGone)
        }
    }

    /// 自分の投稿・理由の誤り・理由の無いサーバーの失敗は `.unknown`。メンバーでないは `.notMember`
    func testReportMapsOtherFailures() async {
        let cases: [(underlying: Error, expected: SoratomoError)] = [
            (functionsError(.failedPrecondition, reason: "self_report"), .unknown),
            (functionsError(.invalidArgument, reason: "invalid_reason"), .unknown),
            (functionsError(.internal), .unknown),
            (functionsError(.permissionDenied, reason: "not_member"), .notMember),
        ]
        for (underlying, expected) in cases {
            dataSource.callResult = .failure(underlying)
            do {
                try await service.report(groupId: "group1", skyId: "sky1", reason: .harassment)
                XCTFail("失敗で成功してはいけない: \(underlying)")
            } catch {
                XCTAssertEqual(soratomoError(error), expected, "\(underlying)")
            }
        }
    }

    /// 戻り値が `{ accepted: true }` でなければ `.unknown`
    func testReportRejectsMalformedResponse() async {
        let responses: [Any] = [["accepted": false], [String: Any](), "accepted", NSNull()]
        for response in responses {
            dataSource.callResult = .success(response)
            do {
                try await service.report(groupId: "group1", skyId: "sky1", reason: .copyright)
                XCTFail("形の違う戻り値で成功してはいけない: \(response)")
            } catch {
                XCTAssertEqual(soratomoError(error), .unknown, "\(response)")
            }
        }
    }

    // MARK: - ブロック

    /// 保存できたら、窓口に (投稿者, 自分) を渡し、`.userBlocked` を投稿者の uid で 1 回送る
    func testBlockWritesAndPostsUserBlockedOnce() async throws {
        try await service.block(uid: "me", authorId: "author1")

        XCTAssertEqual(dataSource.addBlockedUserIdCalls.count, 1)
        XCTAssertEqual(dataSource.addBlockedUserIdCalls.first?.authorId, "author1")
        XCTAssertEqual(dataSource.addBlockedUserIdCalls.first?.uid, "me")
        XCTAssertEqual(recorder.blockedIds, ["author1"])
    }

    /// 保存に失敗したら `.userBlocked` を送らない（一覧から消したのに、実際はブロックされていない、を防ぐ・要件 9.9）
    func testBlockFailureDoesNotPostUserBlocked() async {
        let cases: [(underlying: Error, expected: SoratomoError)] = [
            (firestoreError(.unavailable), .network),
            (offlineError, .network),
            (firestoreError(.permissionDenied), .permissionDenied),
            (firestoreError(.notFound), .unknown),
        ]
        for (underlying, expected) in cases {
            dataSource.addBlockedUserIdError = underlying
            do {
                try await service.block(uid: "me", authorId: "author1")
                XCTFail("保存の失敗で成功してはいけない: \(underlying)")
            } catch {
                XCTAssertEqual(soratomoError(error), expected, "\(underlying)")
            }
        }
        XCTAssertEqual(dataSource.addBlockedUserIdCalls.count, cases.count)
        XCTAssertEqual(recorder.blockedIds, [], "失敗したのにブロックの通知が送られた")
    }

    /// 文書 ID に使えない uid（空・「/」を含む）では、窓口を呼ばずに `.unknown`（Firestore の異常終了を避ける）
    func testBlockRejectsUnusableIdsWithoutWriting() async {
        for (uid, authorId) in [("", "author1"), ("a/b", "author1"), ("me", "")] {
            do {
                try await service.block(uid: uid, authorId: authorId)
                XCTFail("使えない ID で成功してはいけない: uid=\(uid) authorId=\(authorId)")
            } catch {
                XCTAssertEqual(soratomoError(error), .unknown)
            }
        }
        XCTAssertEqual(dataSource.addBlockedUserIdCalls.count, 0)
        XCTAssertEqual(recorder.blockedIds, [])
    }

    // MARK: - ブロックの一覧の読み取り

    /// 読めたら集合にして返す（重複は 1 つ）
    func testFetchBlockedUserIdsReturnsSet() async throws {
        dataSource.fetchBlockedUserIdsResult = .success(["a", "b", "a"])

        let ids = try await service.fetchBlockedUserIds(uid: "me")

        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(dataSource.fetchBlockedUserIdsCalls, ["me"])
    }

    /// 通信の失敗は `.network`、それ以外（権限の拒否を含む）は `.unknown`
    func testFetchBlockedUserIdsMapsFailures() async {
        let cases: [(underlying: Error, expected: SoratomoError)] = [
            (firestoreError(.unavailable), .network),
            (offlineError, .network),
            (firestoreError(.permissionDenied), .unknown),
            (NSError(domain: "other", code: 1), .unknown),
        ]
        for (underlying, expected) in cases {
            dataSource.fetchBlockedUserIdsResult = .failure(underlying)
            do {
                _ = try await service.fetchBlockedUserIds(uid: "me")
                XCTFail("読み取りの失敗で成功してはいけない: \(underlying)")
            } catch {
                XCTAssertEqual(soratomoError(error), expected, "\(underlying)")
            }
        }
    }

    /// 文書 ID に使えない uid では、窓口を呼ばずに `.unknown`
    func testFetchBlockedUserIdsRejectsUnusableUid() async {
        do {
            _ = try await service.fetchBlockedUserIds(uid: "")
            XCTFail("空の uid で成功してはいけない")
        } catch {
            XCTAssertEqual(soratomoError(error), .unknown)
        }
        XCTAssertEqual(dataSource.fetchBlockedUserIdsCalls, [])
    }
}
