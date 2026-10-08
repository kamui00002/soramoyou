//
//  SoratomoSkyServiceTests.swift
//  SoramoyouTests
//
//  そらとも投稿のサービス（SoratomoSkyService）の、Firestore に触らない部分のテスト ⭐️（tasks 11.2・release-gate 9.3）
//
//  確かめるもの: 文書の項目 → SoratomoSky の変換と壊れた 1 件の読み飛ばし、続きの有無の判定、
//  投稿の作成で送る値（functions/soratomoCore.js の validateSkyInput に合わせた形）と、作成の Callable の失敗の写し、
//  投稿 1 件の監視の結果の決め方（存在・不在・権限）。
//  ⚠️ Firestore への実際の読み書き（トランザクションがオフラインで失敗して積まれないこと・
//     監視の isFromCache・count()）は、単体テストでは確かめられない。実機かシミュレータで確かめる。
//  ⚠️ 作成の Callable には接続しない。窓口（SoratomoSkyDataSource）を偽物に差し替える。
//
//  項目名は、本番のコードの定数（SoratomoSkyService.Field）を使わず、文字列で書いている。
//  定数の打ち間違いを、テストで見つけるため（Functions が書く項目名・受け取る項目名と一致させる）。
//

import FirebaseFirestore
import FirebaseFunctions
@testable import Soramoyou
import XCTest

// MARK: - 偽物

/// 作成の Callable の窓口の偽物（呼ばれた引数を記録し、決めた結果を返す）
private final class FakeSkyDataSource: SoratomoSkyDataSource, @unchecked Sendable {
    /// 返す結果（既定はサーバーが新しく作ったときの戻り値）
    var callResult: Result<Any, Error> = .success(["skyId": "sky1", "created": true])

    /// 呼ばれた引数
    private(set) var callCalls: [(name: String, payload: [String: Any], timeout: TimeInterval)] = []

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        callCalls.append((name, payload, timeout))
        return try callResult.get()
    }
}

final class SoratomoSkyServiceTests: XCTestCase {
    // MARK: - テスト用のデータ

    /// 作成日時（Firestore が返す Timestamp）
    private let createdAtTimestamp = Timestamp(seconds: 1_700_000_000, nanoseconds: 0)
    /// 上の Timestamp と同じ時刻
    private let createdAtDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// 正しい形の文書の項目
    private func validData() -> [String: Any] {
        [
            "authorId": "author1",
            "caption": "夕焼け",
            "width": 2048,
            "height": 1536,
            "createdAt": createdAtTimestamp,
        ]
    }

    /// 読み取った文書（パスは投稿 ID から作る）
    private func document(id: String, data: [String: Any]) -> SoratomoSkyService.SourceDocument {
        SoratomoSkyService.SourceDocument(id: id, path: "soratomoGroups/g1/skies/\(id)", data: data)
    }

    // MARK: - 文書 → SoratomoSky

    func testDecodeSkyReadsEveryField() throws {
        let sky = try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: validData())
        XCTAssertEqual(
            sky,
            SoratomoSky(
                id: "sky1", groupId: "g1", authorId: "author1", caption: "夕焼け",
                pixelWidth: 2048, pixelHeight: 1536, createdAt: createdAtDate
            )
        )
    }

    func testDecodeSkyWithoutCaptionGivesNil() throws {
        var data = validData()
        data["caption"] = nil
        let sky = try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: data)
        XCTAssertNil(sky.caption)
    }

    func testDecodeSkyThrowsMissingFieldForEachRequiredField() {
        for key in ["authorId", "width", "height", "createdAt"] {
            var data = validData()
            data[key] = nil
            XCTAssertThrowsError(
                try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: data),
                "\(key) が無い文書は変換できない"
            ) { error in
                XCTAssertEqual(error as? SoratomoSkyService.DecodeError, .missingField(key))
            }
        }
    }

    func testDecodeSkyThrowsInvalidFieldForWrongTypesAndValues() {
        // (壊す項目, 壊した値)
        let cases: [(String, Any)] = [
            ("authorId", ""), // 空の投稿者
            ("authorId", 123), // 文字列でない
            ("width", "2048"), // 数でない
            ("width", 0), // 0 以下（縦横比を計算できない）
            ("height", -1),
            ("createdAt", Date(timeIntervalSince1970: 0)), // Timestamp でない
            ("caption", 5), // あるのに文字列でない
        ]
        for (key, value) in cases {
            var data = validData()
            data[key] = value
            XCTAssertThrowsError(
                try SoratomoSkyService.decodeSky(id: "sky1", groupId: "g1", data: data),
                "\(key)=\(value) は変換できない"
            ) { error in
                XCTAssertEqual(error as? SoratomoSkyService.DecodeError, .invalidField(key))
            }
        }
    }

    // MARK: - 壊れた 1 件の読み飛ばし

    func testDecodeSkiesSkipsOnlyTheBrokenDocumentAndReportsItsPath() {
        var broken = validData()
        broken["width"] = nil
        let documents = [
            document(id: "a", data: validData()),
            document(id: "b", data: broken),
            document(id: "c", data: validData()),
        ]
        var failures: [SoratomoSkyService.DecodeFailure] = []

        let skies = SoratomoSkyService.decodeSkies(documents, groupId: "g1") { failures.append($0) }

        XCTAssertEqual(skies.map(\.id), ["a", "c"], "壊れた b だけが落ち、並び順は元のまま")
        XCTAssertEqual(failures.map(\.path), ["soratomoGroups/g1/skies/b"], "壊れた文書のパスが残る")
        XCTAssertEqual(failures.first?.error, .missingField("width"))
    }

    func testDecodeSkiesReportsNothingWhenEveryDocumentIsValid() {
        var failureCount = 0
        let skies = SoratomoSkyService.decodeSkies(
            [document(id: "a", data: validData())], groupId: "g1"
        ) { _ in failureCount += 1 }
        XCTAssertEqual(skies.count, 1)
        XCTAssertEqual(failureCount, 0)
    }

    // MARK: - 続きの有無

    func testMayHaveMoreIsTrueWhenCountReachesLimit() {
        XCTAssertTrue(SoratomoSkyService.mayHaveMore(documentCount: 20, limit: 20))
        XCTAssertFalse(SoratomoSkyService.mayHaveMore(documentCount: 19, limit: 20))
        XCTAssertFalse(SoratomoSkyService.mayHaveMore(documentCount: 0, limit: 20))
    }

    func testTimelineSnapshotCountsReadDocumentsNotDecodedOnes() {
        // 3 件読んで 1 件が壊れていても、上限（3）に達しているので続きがありうる。
        // 変換後の件数（2）で判定すると「もう無い」になり、無限スクロールが止まってしまう
        var broken = validData()
        broken["height"] = nil
        let documents = [
            document(id: "a", data: validData()),
            document(id: "b", data: broken),
            document(id: "c", data: validData()),
        ]

        let snapshot = SoratomoSkyService.makeTimelineSnapshot(
            documents: documents, groupId: "g1", limit: 3, isFromCache: false
        ) { _ in }

        XCTAssertEqual(snapshot.skies.count, 2)
        XCTAssertTrue(snapshot.mayHaveMore)
    }

    func testTimelineSnapshotIsNotMoreWhenBelowLimit() {
        let snapshot = SoratomoSkyService.makeTimelineSnapshot(
            documents: [document(id: "a", data: validData())], groupId: "g1", limit: 20, isFromCache: false
        ) { _ in }
        XCTAssertFalse(snapshot.mayHaveMore)
    }

    func testTimelineSnapshotPassesIsFromCacheThrough() {
        for isFromCache in [true, false] {
            let snapshot = SoratomoSkyService.makeTimelineSnapshot(
                documents: [], groupId: "g1", limit: 20, isFromCache: isFromCache
            ) { _ in }
            XCTAssertEqual(snapshot.isFromCache, isFromCache)
        }
    }

    // MARK: - 監視の件数の上限と文書 ID

    func testEffectiveLimitIsAtLeastOne() {
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(20), 20)
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(60), 60)
        // Firestore の limit(to:) は 0 以下で例外になる
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(0), 1)
        XCTAssertEqual(SoratomoSkyService.effectiveLimit(-5), 1)
    }

    func testIsUsableDocumentIdRejectsEmptyAndSlash() {
        XCTAssertTrue(SoratomoSkyService.isUsableDocumentId("AbC123xyz"))
        XCTAssertFalse(SoratomoSkyService.isUsableDocumentId(""))
        XCTAssertFalse(SoratomoSkyService.isUsableDocumentId("a/b"))
    }

    // MARK: - 投稿の作成で送る値（release-gate 9.3）

    func testCreatePayloadHasExactlyTheInputKeysWithCaption() {
        let payload = SoratomoSkyService.makeCreatePayload(for: draft(caption: "夕焼け"))
        // functions/soratomoCore.js の validateSkyInput が読む項目だけ。
        // 投稿者（認証の uid）と作成日時（サーバーの時刻）はサーバーが決めるので送らない
        XCTAssertEqual(Set(payload.keys), ["groupId", "skyId", "caption", "width", "height"])
        XCTAssertEqual(payload["caption"] as? String, "夕焼け")
    }

    func testCreatePayloadMapsDraftValuesToInputNames() {
        let payload = SoratomoSkyService.makeCreatePayload(for: draft(caption: nil))
        XCTAssertEqual(payload["groupId"] as? String, "g1")
        XCTAssertEqual(payload["skyId"] as? String, "sky1")
        // アプリの pixelWidth / pixelHeight は、Functions では width / height
        XCTAssertEqual(payload["width"] as? Int, 2048)
        XCTAssertEqual(payload["height"] as? Int, 1536)
    }

    func testCreatePayloadOmitsCaptionWhenNil() {
        let payload = SoratomoSkyService.makeCreatePayload(for: draft(caption: nil))
        // 項目ごと省く（項目があると、validateSkyInput は 1〜100 文字の文字列しか通さない）
        XCTAssertNil(payload["caption"])
        XCTAssertEqual(Set(payload.keys), ["groupId", "skyId", "width", "height"])
    }

    func testCreatePayloadOmitsEmptyCaption() {
        let payload = SoratomoSkyService.makeCreatePayload(for: draft(caption: ""))
        // 空の文字列を送ると invalid_input で拒否される
        XCTAssertNil(payload["caption"])
        XCTAssertEqual(Set(payload.keys), ["groupId", "skyId", "width", "height"])
    }

    // MARK: - 投稿の作成（Callable soratomoCreateSky・release-gate 9.3）

    func testCreateSkyCallsCreateCallableWithPayloadAndTwentySeconds() async throws {
        let (service, dataSource) = makeService()

        try await service.createSky(draft(caption: "夕焼け"))

        XCTAssertEqual(dataSource.callCalls.count, 1)
        let call = try XCTUnwrap(dataSource.callCalls.first)
        XCTAssertEqual(call.name, "soratomoCreateSky")
        XCTAssertEqual(call.timeout, 20)
        XCTAssertEqual(call.payload as NSDictionary, SoratomoSkyService.makeCreatePayload(for: draft(caption: "夕焼け")) as NSDictionary)
    }

    func testCreateSkySucceedsWhenServerCreatedOrAlreadyHadTheSameSky() async throws {
        // 同じ投稿 ID の送り直しは、サーバーが created: false の成功で返す（1 件で済む）
        for created in [true, false] {
            let (service, dataSource) = makeService()
            dataSource.callResult = .success(["skyId": "sky1", "created": created])

            try await service.createSky(draft(caption: nil))

            XCTAssertEqual(dataSource.callCalls.count, 1, "created=\(created) でも送り直さない（送り直しは呼び出し側の責務）")
        }
    }

    func testCreateSkyTreatsUnexpectedSuccessResponseAsSuccess() async throws {
        // サーバーが成功を返したのは、文書を作った（または同じ人の文書があった）後だけ。
        // 戻り値の形が違うだけで失敗にすると、呼び出し側が画像を消し、画像の無い投稿が残ってしまう
        let responses: [Any] = ["unexpected", ["skyId": "other", "created": true], ["skyId": "sky1"]]
        for response in responses {
            let (service, dataSource) = makeService()
            dataSource.callResult = .success(response)

            try await service.createSky(draft(caption: nil))

            XCTAssertEqual(dataSource.callCalls.count, 1)
        }
    }

    func testCreateSkyMapsCallableFailures() async {
        // (Callable の失敗, 写した種類)
        let cases: [(NSError, SoratomoError)] = [
            (functionsError(.invalidArgument, reason: "ng_word"), .ngWord),
            (functionsError(.permissionDenied, reason: "suspended"), .suspended),
            (functionsError(.permissionDenied, reason: "not_member"), .notMember),
            (functionsError(.permissionDenied, reason: "flag_off"), .flagOff),
            // 入力の誤りはアプリの不具合なので、利用者向けの種類を作らない
            (functionsError(.invalidArgument, reason: "invalid_input"), .unknown),
            // 結果が確定しない失敗（サーバーには届いた可能性がある）
            (functionsError(.unavailable), .network),
            (functionsError(.deadlineExceeded), .network),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet), .network),
            (functionsError(.unauthenticated), .permissionDenied),
            (functionsError(.internal), .unknown),
        ]
        for (callableError, expected) in cases {
            let (service, dataSource) = makeService()
            dataSource.callResult = .failure(callableError)
            do {
                try await service.createSky(draft(caption: nil))
                XCTFail("\(callableError) は失敗するはず")
            } catch {
                XCTAssertEqual(error, expected, "\(callableError)")
            }
        }
    }

    func testCreateSkyWithUnusableIdsFailsWithoutCalling() async {
        for (groupId, skyId) in [("", "sky1"), ("g1", "a/b")] {
            let (service, dataSource) = makeService()
            let unusableDraft = SoratomoSkyDraft(
                groupId: groupId, skyId: skyId, authorId: "author1", caption: nil,
                pixelWidth: 2048, pixelHeight: 1536
            )
            do {
                try await service.createSky(unusableDraft)
                XCTFail("失敗するはず")
            } catch {
                XCTAssertEqual(error, .unknown)
            }
            XCTAssertTrue(dataSource.callCalls.isEmpty)
        }
    }

    func testIsCreateResponseChecksSkyIdAndCreated() {
        XCTAssertTrue(SoratomoSkyService.isCreateResponse(["skyId": "sky1", "created": true], skyId: "sky1"))
        XCTAssertTrue(SoratomoSkyService.isCreateResponse(["skyId": "sky1", "created": false], skyId: "sky1"))
        XCTAssertFalse(SoratomoSkyService.isCreateResponse(["skyId": "other", "created": true], skyId: "sky1"))
        XCTAssertFalse(SoratomoSkyService.isCreateResponse(["skyId": "sky1"], skyId: "sky1"))
        XCTAssertFalse(SoratomoSkyService.isCreateResponse(["skyId": "sky1", "created": "true"], skyId: "sky1"))
        XCTAssertFalse(SoratomoSkyService.isCreateResponse("unexpected", skyId: "sky1"))
    }

    // MARK: - 投稿 1 件の監視（release-gate 9.3・要件 1.7）

    func testResolveObservedSkyIsPresentWhenDocumentExists() {
        // キャッシュの結果でも、あるものはある
        for isFromCache in [true, false] {
            let result = SoratomoSkyService.resolveObservedSky(exists: true, isFromCache: isFromCache, error: nil)
            XCTAssertEqual(result, .success(.present), "isFromCache=\(isFromCache)")
        }
    }

    func testResolveObservedSkyIsGoneOnlyWhenServerConfirmsAbsence() {
        let result = SoratomoSkyService.resolveObservedSky(exists: false, isFromCache: false, error: nil)
        XCTAssertEqual(result, .success(.gone))
    }

    func testResolveObservedSkyIgnoresAbsenceOnlyFromCache() {
        // オフラインで開いた・まだ端末に写しが無い投稿は「無い」として届く。これを「もう無い」にしない
        // （監視は続くので、つながればサーバーの結果が届く）
        let result = SoratomoSkyService.resolveObservedSky(exists: false, isFromCache: true, error: nil)
        XCTAssertNil(result)
    }

    func testResolveObservedSkyIsNotMemberWhenPermissionIsLost() {
        // メンバーでなくなると、ルールが読み取りを拒否する
        let result = SoratomoSkyService.resolveObservedSky(
            exists: nil, isFromCache: false, error: firestoreError(.permissionDenied)
        )
        XCTAssertEqual(result, .failure(.notMember))
    }

    func testResolveObservedSkyMapsOtherErrorsAsRead() {
        XCTAssertEqual(
            SoratomoSkyService.resolveObservedSky(exists: nil, isFromCache: false, error: firestoreError(.unavailable)),
            .failure(.network)
        )
        XCTAssertEqual(
            SoratomoSkyService.resolveObservedSky(exists: nil, isFromCache: false, error: firestoreError(.internal)),
            .failure(.unknown)
        )
    }

    func testResolveObservedSkyWithoutSnapshotOrErrorIsUnknown() {
        // 起きない想定。起きても「もう無い」とは決めない
        let result = SoratomoSkyService.resolveObservedSky(exists: nil, isFromCache: false, error: nil)
        XCTAssertEqual(result, .failure(.unknown))
    }

    @MainActor
    func testObserveSkyWithUnusableIdsDeliversNotMember() async {
        // 空文字や「/」でパスを作ると Firestore が異常終了するので、監視を張らずに「メンバーでない」を返す
        let (service, _) = makeService()
        let delivered = expectation(description: "結果が届く")
        var received: [Result<SoratomoSkyPresence, SoratomoError>] = []

        let token = service.observeSky(groupId: "a/b", skyId: "sky1") { result in
            received.append(result)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 5)
        token.cancel()

        XCTAssertEqual(received, [.failure(.notMember)])
    }

    // MARK: - ヘルパー

    private func draft(caption: String?) -> SoratomoSkyDraft {
        SoratomoSkyDraft(
            groupId: "g1", skyId: "sky1", authorId: "author1", caption: caption,
            pixelWidth: 2048, pixelHeight: 1536
        )
    }

    /// 窓口を偽物にしたサービス（Firestore は差し替えない。作るだけでは Firestore に触れない）
    private func makeService() -> (SoratomoSkyService, FakeSkyDataSource) {
        let dataSource = FakeSkyDataSource()
        return (SoratomoSkyService(dataSource: dataSource), dataSource)
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
}
