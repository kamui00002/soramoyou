//
//  SoratomoServiceContractsTests.swift
//  SoramoyouTests
//
//  そらとものサービスの契約のテスト ⭐️（S6 の Wave 0）
//  - 監視の札（SoratomoListenerToken）の止め方
//  - Firestore のエラーの写し（SoratomoError.fromFirestore）
//  - protocol の `async throws(SoratomoError)` が、この toolchain で SoratomoError のまま受け取れること
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoServiceContractsTests: XCTestCase {
    // MARK: - 監視の札

    func testTokenCancelRunsOnlyOnce() {
        var cancelCount = 0
        let token = SoratomoListenerToken { cancelCount += 1 }
        XCTAssertFalse(token.isCancelled)

        token.cancel()
        token.cancel()

        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(token.isCancelled)
    }

    func testTokenCancelsWhenReleased() {
        // 札を持たずに捨てると、その場で監視が止まる（ViewModel は札をプロパティに持つこと）
        var cancelCount = 0
        do {
            let token = SoratomoListenerToken { cancelCount += 1 }
            XCTAssertFalse(token.isCancelled)
        }
        XCTAssertEqual(cancelCount, 1)
    }

    func testReplacingTokenStopsPreviousObservation() {
        // 上限を伸ばして張り直すとき、新しい札で上書きすれば古い監視が止まる（tasks 11.2・13.5）
        let service = MockSoratomoSkyService()
        var token: SoratomoListenerToken? = service.observeTimeline(groupId: "g1", limit: 20) { _ in }
        XCTAssertNotNil(token)
        token = service.observeTimeline(groupId: "g1", limit: 40) { _ in }
        XCTAssertNotNil(token)

        XCTAssertEqual(service.cancelledTimelineIndexes, [0])
        XCTAssertEqual(service.observeTimelineCalls.map(\.limit), [20, 40])
    }

    // MARK: - Firestore のエラーの写し

    private func firestoreError(_ code: FirestoreErrorCode.Code) -> NSError {
        NSError(domain: FirestoreErrorDomain, code: code.rawValue)
    }

    func testFirestoreNetworkErrorsBecomeNetwork() {
        for code in [FirestoreErrorCode.Code.unavailable, .deadlineExceeded] {
            XCTAssertEqual(SoratomoError.fromFirestore(firestoreError(code), access: .read), .network, "\(code)")
            XCTAssertEqual(SoratomoError.fromFirestore(firestoreError(code), access: .write), .network, "\(code)")
        }
    }

    func testFirestorePermissionDeniedDependsOnAccess() {
        // 読めない = メンバーでない。書けない = ルールに拒否された
        let error = firestoreError(.permissionDenied)
        XCTAssertEqual(SoratomoError.fromFirestore(error, access: .read), .notMember)
        XCTAssertEqual(SoratomoError.fromFirestore(error, access: .write), .permissionDenied)
    }

    func testFirestoreNotFoundDependsOnAccess() {
        let error = firestoreError(.notFound)
        XCTAssertEqual(SoratomoError.fromFirestore(error, access: .read), .notMember)
        XCTAssertEqual(SoratomoError.fromFirestore(error, access: .write), .unknown)
    }

    func testFirestoreUnauthenticatedBecomesPermissionDenied() {
        let error = firestoreError(.unauthenticated)
        XCTAssertEqual(SoratomoError.fromFirestore(error, access: .read), .permissionDenied)
        XCTAssertEqual(SoratomoError.fromFirestore(error, access: .write), .permissionDenied)
    }

    func testOtherFirestoreErrorsBecomeUnknown() {
        for code in [FirestoreErrorCode.Code.internal, .aborted, .resourceExhausted, .cancelled] {
            XCTAssertEqual(SoratomoError.fromFirestore(firestoreError(code), access: .write), .unknown, "\(code)")
        }
    }

    func testURLErrorsBecomeNetworkExceptCancel() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(SoratomoError.fromFirestore(offline, access: .read), .network)
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertEqual(SoratomoError.fromFirestore(cancelled, access: .read), .unknown)
    }

    func testSoratomoErrorPassesThroughAndOtherDomainsBecomeUnknown() {
        // サービスの中で先に写したエラーは、そのまま返す
        XCTAssertEqual(SoratomoError.fromFirestore(SoratomoError.dailyLimit, access: .write), .dailyLimit)
        // Firestore の番号と同じでも、ドメインが違えば写さない
        let other = NSError(domain: "OtherDomain", code: FirestoreErrorCode.unavailable.rawValue)
        XCTAssertEqual(SoratomoError.fromFirestore(other, access: .read), .unknown)
    }

    // MARK: - typed throws（protocol 越しに SoratomoError のまま受け取れる）

    func testTypedThrowsReachCallerAsSoratomoError() async {
        // ⚠️ catch の `error` を `as?` で変換せずに `.network` と比べている。
        //    投げる型が any Error に広がっていたら、この比較はコンパイルが通らない。
        let mock = MockSoratomoGroupService()
        mock.createGroupResult = .failure(.network)
        let service: any SoratomoGroupServiceProtocol = mock
        let requestId = UUID()
        do {
            _ = try await service.createGroup(name: "朝の空", requestId: requestId)
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error, .network)
        }
        XCTAssertEqual(mock.createGroupCalls.count, 1)
        XCTAssertEqual(mock.createGroupCalls.first?.requestId, requestId)
    }

    func testVoidTypedThrowsSucceedsAndFails() async throws {
        let mock = MockSoratomoSkyService()
        let service: any SoratomoSkyServiceProtocol = mock
        let draft = SoratomoSkyDraft(
            groupId: "g1", skyId: service.newSkyId(groupId: "g1"), authorId: "u1",
            caption: nil, pixelWidth: 2048, pixelHeight: 1536
        )

        mock.createSkyResult = .success(())
        try await service.createSky(draft)

        mock.createSkyResult = .failure(.permissionDenied)
        do {
            try await service.createSky(draft)
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error, .permissionDenied)
        }
        XCTAssertEqual(mock.createSkyCalls, [draft, draft])
        XCTAssertEqual(draft.skyId, "sky-1")
    }

    func testMainActorCallbackReachesOnlyLiveObservation() {
        // @MainActor のコールバックを protocol 越しに渡し、止めた監視には届かないこと
        let mock = MockSoratomoSkyService()
        var received: [Int] = []
        let first = mock.observeTimeline(groupId: "g1", limit: 20) { result in
            if case let .success(snapshot) = result { received.append(snapshot.skies.count) }
        }
        let snapshot = SoratomoTimelineSnapshot(skies: [], isFromCache: true, mayHaveMore: false)
        mock.emitTimeline(.success(snapshot))
        first.cancel()
        mock.emitTimeline(.success(snapshot))

        XCTAssertEqual(received, [0])
    }

    func testImageStoreMockReportsProgressAndDeleteOutcome() async {
        let mock = MockSoratomoImageStore()
        let store: any SoratomoImageStoreProtocol = mock
        let images = SoratomoEncodedImages(display: Data([1]), thumbnail: Data([2]), pixelWidth: 1, pixelHeight: 1)
        let paths = SoratomoImagePaths(groupId: "g1", authorId: "u1", skyId: "s1")
        mock.progressToReport = [0.5, 1.0]
        mock.uploadResult = .failure(.uploadTimeout)
        let reported = ProgressRecorder()

        do {
            try await store.upload(images, to: paths) { reported.append($0) }
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error, .uploadTimeout)
        }
        mock.deleteOutcome = .partiallyFailed
        let outcome = await store.delete(paths)

        XCTAssertEqual(reported.values, [0.5, 1.0])
        XCTAssertEqual(outcome, .partiallyFailed)
        XCTAssertEqual(mock.deleteCalls, [paths])
    }

    func testProfileServiceMockAcceptsValidatedDisplayName() async throws {
        let mock = MockSoratomoProfileService()
        let service: any SoratomoProfileServiceProtocol = mock
        let name = try XCTUnwrap(try? SoratomoTextRules.validateDisplayName("  そら  ").get())

        mock.saveDisplayNameResult = .failure(.network)
        do {
            try await service.saveDisplayName(uid: "u1", name: name)
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error, .network)
        }
        XCTAssertEqual(mock.saveDisplayNameCalls.first?.name.value, "そら")
    }
}

/// `@Sendable` の進み具合のコールバックから値を集める（テスト用）
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}
