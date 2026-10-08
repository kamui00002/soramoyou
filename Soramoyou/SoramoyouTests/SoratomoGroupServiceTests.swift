//
//  SoratomoGroupServiceTests.swift
//  SoramoyouTests
//
//  そらとものグループのサービス（SoratomoGroupService）のテスト ⭐️（tasks 11.1）
//  - Callable のエラーの写し（flag_off・invalid_name・invalid_format・not_found・group_full・user_limit・not_owner・通信）
//    と、release-gate 8 で足した理由（ng_word・suspended・consent_required・outdated_guideline・sky_not_found・not_member）
//  - グループ一覧の並び順（最新の活動時刻の新しい順・最大 10 件）
//  - Callable の戻り値・グループ・メンバーの文書の読み取り
//  - グループの監視の 1 回分の結果の決め方（権限の拒否・不在・キャッシュだけの結果）
//
//  ⚠️ Firestore と Functions には接続しない。サービスの `static` の純関数だけを確かめる。
//     Callable の本物の呼び出し（制限時間 20 秒・リージョン）は、エミュレーターか本番での確認が要る。
//

import FirebaseFirestore
import FirebaseFunctions
@testable import Soramoyou
import XCTest

final class SoratomoGroupServiceTests: XCTestCase {
    // MARK: - 部品

    /// 基準にする日時（秒まで。Timestamp との往復で値が変わらないように、端数を持たせない）
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// 正しい形の招待コード（字種の 8 文字）
    private func makeCode(_ text: String = "ABCDEFGH") throws -> SoratomoInviteCode {
        try XCTUnwrap(SoratomoInviteCode.parse(userInput: text))
    }

    /// `soratomoJoinGroup` の戻り値（値の型が混ざるので、型を明示して作る）
    private func joinResponse(groupId: String, alreadyMember: Bool) -> [String: Any] {
        ["groupId": groupId, "alreadyMember": alreadyMember]
    }

    /// Callable が返す失敗（サーバーが理由を付けるときは `details["reason"]` に入れる）
    private func functionsError(_ code: FunctionsErrorCode, reason: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "サーバーの文言（画面に出さない）"]
        if let reason {
            userInfo[FunctionsErrorDetailsKey] = ["reason": reason]
        }
        return NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    /// Callable が返す、理由のほかに詳細も持つ失敗（release-gate の consent_required・outdated_guideline の `currentVersion`）
    private func functionsError(_ code: FunctionsErrorCode, details: [String: Any]) -> NSError {
        NSError(
            domain: FunctionsErrorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "サーバーの文言（画面に出さない）", FunctionsErrorDetailsKey: details]
        )
    }

    /// Firestore が返す失敗
    private func firestoreError(_ code: FirestoreErrorCode.Code) -> NSError {
        NSError(domain: FirestoreErrorDomain, code: code.rawValue, userInfo: nil)
    }

    /// 並び替えのテスト用のグループ（活動時刻だけを変える）
    private func makeGroup(
        id: String,
        lastActivityOffset: TimeInterval,
        createdOffset: TimeInterval = 0
    ) throws -> SoratomoGroup {
        try SoratomoGroup(
            id: id,
            name: "グループ",
            ownerId: "owner",
            inviteCode: makeCode(),
            memberCount: 1,
            createdAt: baseDate.addingTimeInterval(createdOffset),
            lastActivityAt: baseDate.addingTimeInterval(lastActivityOffset)
        )
    }

    /// 正しい形のグループの文書
    private func validGroupData() -> [String: Any] {
        [
            "name": "夕焼け部",
            "ownerId": "owner-1",
            "inviteCode": "ABCDEFGH",
            "memberCount": 3,
            "createdAt": Timestamp(date: baseDate),
            "lastActivityAt": Timestamp(date: baseDate.addingTimeInterval(600)),
        ]
    }

    // MARK: - 定数

    func testConstants() {
        // Functions の REGION（functions/soratomo.js）と、Callable の制限時間（20 秒）が、変わっていないこと
        XCTAssertEqual(SoratomoGroupService.region, "asia-northeast1")
        XCTAssertEqual(SoratomoGroupService.callTimeout, 20)
    }

    // MARK: - Callable のエラーの写し: 理由（details["reason"]）

    func testMapCallableError_flagOff() {
        let error = functionsError(.permissionDenied, reason: "flag_off")
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .flagOff)
    }

    func testMapCallableError_invalidName() {
        let error = functionsError(.invalidArgument, reason: "invalid_name")
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .invalidName)
    }

    func testMapCallableError_invalidFormat() {
        let error = functionsError(.invalidArgument, reason: "invalid_format")
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .invalidFormat)
    }

    func testMapCallableError_notFound() {
        let error = functionsError(.notFound, reason: "not_found")
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .notFound)
    }

    func testMapCallableError_groupFull() {
        // group_full と user_limit は同じ code（resourceExhausted）。理由だけが違う
        let error = functionsError(.resourceExhausted, reason: "group_full")
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .groupFull)
    }

    func testMapCallableError_userLimit() {
        let error = functionsError(.resourceExhausted, reason: "user_limit")
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .userLimit)
    }

    func testMapCallableError_notOwner() {
        // not_owner と flag_off は同じ code（permissionDenied）。理由だけが違う
        let error = functionsError(.permissionDenied, reason: "not_owner")
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .notOwner)
    }

    // MARK: - Callable のエラーの写し: 通信

    func testMapCallableError_unavailableIsNetwork() {
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.unavailable)), .network)
    }

    func testMapCallableError_deadlineExceededIsNetwork() {
        // 制限時間（20 秒）切れは、SDK が deadlineExceeded にして返す
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.deadlineExceeded)), .network)
    }

    func testMapCallableError_urlErrorIsNetwork() {
        // 電波が無いとき、SDK は Functions のエラーにせず、NSURLError のまま返す
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(SoratomoGroupService.mapCallableError(offline), .network)
        XCTAssertEqual(SoratomoGroupService.mapCallableError(lost), .network)
    }

    // MARK: - Callable のエラーの写し: 理由が無い・読めない場合

    func testMapCallableError_unauthenticatedIsPermissionDenied() {
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.unauthenticated)), .permissionDenied)
    }

    func testMapCallableError_permissionDeniedWithoutReasonStaysPermissionDenied() {
        // 理由の無い permissionDenied は flag_off ではない（呼び出し権限の設定などの想定外）
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.permissionDenied)), .permissionDenied)
    }

    func testMapCallableError_codeWithoutReasonNeverBecomesDomainError() {
        // 関数が未デプロイのときは notFound（理由なし）が返る。「招待コードが見つかりません」にしない
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.notFound)), .unknown)
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.invalidArgument)), .unknown)
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.resourceExhausted)), .unknown)
        XCTAssertEqual(SoratomoGroupService.mapCallableError(functionsError(.internal)), .unknown)
    }

    func testMapCallableError_unknownReasonFallsBackToCode() {
        // 知らない理由は無視して、code から決める
        XCTAssertEqual(
            SoratomoGroupService.mapCallableError(functionsError(.permissionDenied, reason: "something_new")),
            .permissionDenied
        )
        XCTAssertEqual(
            SoratomoGroupService.mapCallableError(functionsError(.internal, reason: "something_new")),
            .unknown
        )
    }

    func testMapCallableError_detailsOfWrongShapeAreIgnored() {
        // details が辞書でない（文字列）場合は、理由として読まない
        let error = NSError(
            domain: FunctionsErrorDomain,
            code: FunctionsErrorCode.permissionDenied.rawValue,
            userInfo: [FunctionsErrorDetailsKey: "flag_off"]
        )
        XCTAssertEqual(SoratomoGroupService.mapCallableError(error), .permissionDenied)
    }

    func testMapCallableError_nonFunctionsErrorsGoToFirestoreMapping() {
        // Functions 以外のエラーは SoratomoError.fromFirestore（書き込み側）と同じ写し
        XCTAssertEqual(SoratomoGroupService.mapCallableError(SoratomoError.invalidName), .invalidName)
        XCTAssertEqual(
            SoratomoGroupService.mapCallableError(firestoreError(.permissionDenied)),
            .permissionDenied
        )
        XCTAssertEqual(
            SoratomoGroupService.mapCallableError(NSError(domain: "other", code: 1)),
            .unknown
        )
    }

    // MARK: - Callable のエラーの写し（release-gate 8・design.md の「エラーと計測」の表）

    func testMapCallableError_releaseGateReasons() {
        let app = SoratomoGuideline.currentVersion
        // code は functions/soratomo.js の REASON_TO_CODE のとおり。種類を決めるのは details の reason
        let table: [(code: FunctionsErrorCode, details: [String: Any], expected: SoratomoError)] = [
            (.invalidArgument, ["reason": "ng_word"], .ngWord),
            (.permissionDenied, ["reason": "suspended"], .suspended),
            (.notFound, ["reason": "sky_not_found"], .skyGone),
            // 理由が無ければ code の permission-denied から .permissionDenied になるので、理由で .notMember にする
            (.permissionDenied, ["reason": "not_member"], .notMember),
            // 同意が必要: サーバーの版がアプリと同じ（か小さい・無い・形が違う）なら全文を出す。大きければアプリが古い
            (.failedPrecondition, ["reason": "consent_required", "currentVersion": app], .consentRequired),
            (.failedPrecondition, ["reason": "consent_required", "currentVersion": app - 1], .consentRequired),
            (.failedPrecondition, ["reason": "consent_required"], .consentRequired),
            (.failedPrecondition, ["reason": "consent_required", "currentVersion": "\(app + 1)"], .consentRequired),
            (.failedPrecondition, ["reason": "consent_required", "currentVersion": app + 1], .outdatedApp),
            // 本物の details は JSON から読んだ NSNumber で届く
            (.failedPrecondition, ["reason": "consent_required", "currentVersion": NSNumber(value: app + 1)], .outdatedApp),
            // 同意の版が古い: サーバーの版がアプリより大きいときだけアプリが古い。それ以外は不明
            (.failedPrecondition, ["reason": "outdated_guideline", "currentVersion": app + 1], .outdatedApp),
            (.failedPrecondition, ["reason": "outdated_guideline", "currentVersion": NSNumber(value: app + 1)], .outdatedApp),
            (.failedPrecondition, ["reason": "outdated_guideline", "currentVersion": app], .unknown),
            (.failedPrecondition, ["reason": "outdated_guideline", "currentVersion": app - 1], .unknown),
            (.failedPrecondition, ["reason": "outdated_guideline"], .unknown),
            // 種類を作らない理由（code から .unknown にし、既存の「うまくいきませんでした…」を出す）
            (.invalidArgument, ["reason": "invalid_input"], .unknown),
            (.invalidArgument, ["reason": "invalid_reason"], .unknown),
            (.failedPrecondition, ["reason": "self_report"], .unknown),
        ]
        for row in table {
            XCTAssertEqual(
                SoratomoGroupService.mapCallableError(functionsError(row.code, details: row.details)),
                row.expected,
                "\(row.details)"
            )
        }
    }

    // MARK: - Callable の戻り値

    func testDecodeCreateResponse_readsAllFields() throws {
        let response: [String: Any] = [
            "groupId": "g1",
            "name": "夕焼け部",
            "inviteCode": "ABCDEFGH",
            "memberCount": 1,
        ]
        let summary = try XCTUnwrap(SoratomoGroupService.decodeCreateResponse(response))
        XCTAssertEqual(summary.groupId, "g1")
        XCTAssertEqual(summary.name, "夕焼け部")
        XCTAssertEqual(summary.inviteCode, try makeCode("ABCDEFGH"))
        XCTAssertEqual(summary.memberCount, 1)
    }

    func testDecodeCreateResponse_rejectsMalformed() {
        let valid: [String: Any] = ["groupId": "g1", "name": "夕焼け部", "inviteCode": "ABCDEFGH", "memberCount": 1]
        XCTAssertNotNil(SoratomoGroupService.decodeCreateResponse(valid))

        // 項目が欠ける
        for key in ["groupId", "name", "inviteCode", "memberCount"] {
            var broken = valid
            broken[key] = nil
            XCTAssertNil(SoratomoGroupService.decodeCreateResponse(broken), "\(key) が無いのに読めてしまった")
        }
        // 形が違う（招待コードが字種の 8 文字でない・数が文字列・空のグループ ID・辞書でない）
        var badCode = valid
        badCode["inviteCode"] = "ABC"
        XCTAssertNil(SoratomoGroupService.decodeCreateResponse(badCode))
        var badCount = valid
        badCount["memberCount"] = "1"
        XCTAssertNil(SoratomoGroupService.decodeCreateResponse(badCount))
        var emptyId = valid
        emptyId["groupId"] = ""
        XCTAssertNil(SoratomoGroupService.decodeCreateResponse(emptyId))
        XCTAssertNil(SoratomoGroupService.decodeCreateResponse("not an object"))
    }

    func testDecodeJoinResponse_readsAlreadyMember() throws {
        let joined = try XCTUnwrap(SoratomoGroupService.decodeJoinResponse(joinResponse(groupId: "g1", alreadyMember: false)))
        XCTAssertEqual(joined, SoratomoJoinResult(groupId: "g1", alreadyMember: false))

        // すでにメンバーでも、エラーではなく成功の結果（要件 4.8）
        let already = try XCTUnwrap(SoratomoGroupService.decodeJoinResponse(joinResponse(groupId: "g1", alreadyMember: true)))
        XCTAssertEqual(already, SoratomoJoinResult(groupId: "g1", alreadyMember: true))
    }

    func testDecodeJoinResponse_rejectsMalformed() {
        // 項目が欠ける
        XCTAssertNil(SoratomoGroupService.decodeJoinResponse(["groupId": "g1"] as [String: Any]))
        XCTAssertNil(SoratomoGroupService.decodeJoinResponse(["alreadyMember": true] as [String: Any]))
        // 形が違う（空のグループ ID・真偽値が文字列・辞書でない）
        XCTAssertNil(SoratomoGroupService.decodeJoinResponse(joinResponse(groupId: "", alreadyMember: true)))
        XCTAssertNil(SoratomoGroupService.decodeJoinResponse(["groupId": "g1", "alreadyMember": "yes"] as [String: Any]))
        XCTAssertNil(SoratomoGroupService.decodeJoinResponse([Any]()))
    }

    func testDecodeRegenerateResponse() throws {
        let code = try XCTUnwrap(SoratomoGroupService.decodeRegenerateResponse(["inviteCode": "ABCDEFGH"]))
        XCTAssertEqual(code, try makeCode("ABCDEFGH"))

        XCTAssertNil(SoratomoGroupService.decodeRegenerateResponse([String: Any]()))
        XCTAssertNil(SoratomoGroupService.decodeRegenerateResponse(["inviteCode": "ABC"]))
        XCTAssertNil(SoratomoGroupService.decodeRegenerateResponse(["inviteCode": 12_345_678]))
    }

    // MARK: - 文書の読み取り

    func testIsUsableDocumentId() {
        XCTAssertTrue(SoratomoGroupService.isUsableDocumentId("abc123"))
        // Firestore が異常終了する文字列は弾く
        XCTAssertFalse(SoratomoGroupService.isUsableDocumentId(""))
        XCTAssertFalse(SoratomoGroupService.isUsableDocumentId("a/b"))
    }

    func testDecodeGroup_readsAllFields() throws {
        let group = try XCTUnwrap(SoratomoGroupService.decodeGroup(id: "g1", data: validGroupData()))
        XCTAssertEqual(group.id, "g1")
        XCTAssertEqual(group.name, "夕焼け部")
        XCTAssertEqual(group.ownerId, "owner-1")
        XCTAssertEqual(group.inviteCode, try makeCode("ABCDEFGH"))
        XCTAssertEqual(group.memberCount, 3)
        XCTAssertEqual(group.createdAt, baseDate)
        XCTAssertEqual(group.lastActivityAt, baseDate.addingTimeInterval(600))
    }

    func testDecodeGroup_rejectsMissingOrMalformedFields() {
        // 項目が 1 つでも欠けたら読まない（壊れた文書は一覧から 1 件だけ飛ばす）
        for key in ["name", "ownerId", "inviteCode", "memberCount", "createdAt", "lastActivityAt"] {
            var broken = validGroupData()
            broken[key] = nil
            XCTAssertNil(SoratomoGroupService.decodeGroup(id: "g1", data: broken), "\(key) が無いのに読めてしまった")
        }
        var badCode = validGroupData()
        badCode["inviteCode"] = "ABC"
        XCTAssertNil(SoratomoGroupService.decodeGroup(id: "g1", data: badCode))
        var badTime = validGroupData()
        badTime["lastActivityAt"] = "2026-10-04"
        XCTAssertNil(SoratomoGroupService.decodeGroup(id: "g1", data: badTime))
        var badCount = validGroupData()
        badCount["memberCount"] = "3"
        XCTAssertNil(SoratomoGroupService.decodeGroup(id: "g1", data: badCount))
    }

    func testDecodeMember_readsOwnerAndMember() throws {
        let joinedAt = Timestamp(date: baseDate)
        let owner = try XCTUnwrap(SoratomoGroupService.decodeMember(id: "u1", data: ["role": "owner", "joinedAt": joinedAt]))
        XCTAssertEqual(owner, SoratomoMember(id: "u1", role: .owner, joinedAt: baseDate))

        let member = try XCTUnwrap(SoratomoGroupService.decodeMember(id: "u2", data: ["role": "member", "joinedAt": joinedAt]))
        XCTAssertEqual(member, SoratomoMember(id: "u2", role: .member, joinedAt: baseDate))
    }

    func testDecodeMember_rejectsMalformed() {
        let joinedAt = Timestamp(date: baseDate)
        XCTAssertNil(SoratomoGroupService.decodeMember(id: "u1", data: ["role": "admin", "joinedAt": joinedAt]))
        XCTAssertNil(SoratomoGroupService.decodeMember(id: "u1", data: ["joinedAt": joinedAt]))
        XCTAssertNil(SoratomoGroupService.decodeMember(id: "u1", data: ["role": "owner"]))
        XCTAssertNil(SoratomoGroupService.decodeMember(id: "u1", data: ["role": "owner", "joinedAt": "昨日"]))
    }

    // MARK: - グループの監視の 1 回分

    func testResolveObservedGroup_documentIsSuccess() throws {
        let result = SoratomoGroupService.resolveObservedGroup(
            id: "g1", data: validGroupData(), isFromCache: false, error: nil
        )
        XCTAssertEqual(try result.get().name, "夕焼け部")
        XCTAssertEqual(try result.get().id, "g1")
    }

    func testResolveObservedGroup_cachedDocumentIsStillSuccess() throws {
        // 端末のキャッシュにある文書は、通信できなくても表示する
        let result = SoratomoGroupService.resolveObservedGroup(
            id: "g1", data: validGroupData(), isFromCache: true, error: nil
        )
        XCTAssertEqual(try result.get().id, "g1")
    }

    func testResolveObservedGroup_permissionDeniedAndNotFoundAreNotMember() {
        for code in [FirestoreErrorCode.Code.permissionDenied, .notFound] {
            let result = SoratomoGroupService.resolveObservedGroup(
                id: "g1", data: nil, isFromCache: false, error: firestoreError(code)
            )
            XCTAssertEqual(result, .failure(.notMember))
        }
    }

    func testResolveObservedGroup_unavailableIsNetwork() {
        let result = SoratomoGroupService.resolveObservedGroup(
            id: "g1", data: nil, isFromCache: false, error: firestoreError(.unavailable)
        )
        XCTAssertEqual(result, .failure(.network))
    }

    func testResolveObservedGroup_missingDocumentConfirmedByServerIsNotMember() {
        let result = SoratomoGroupService.resolveObservedGroup(
            id: "g1", data: nil, isFromCache: false, error: nil
        )
        XCTAssertEqual(result, .failure(.notMember))
    }

    func testResolveObservedGroup_missingDocumentInCacheOnlyIsNetwork() {
        // オフラインで、まだ端末に写しが無いだけ。「メンバーでない」にしない
        let result = SoratomoGroupService.resolveObservedGroup(
            id: "g1", data: nil, isFromCache: true, error: nil
        )
        XCTAssertEqual(result, .failure(.network))
    }

    func testResolveObservedGroup_malformedDocumentIsUnknown() {
        var broken = validGroupData()
        broken["name"] = nil
        let result = SoratomoGroupService.resolveObservedGroup(
            id: "g1", data: broken, isFromCache: false, error: nil
        )
        XCTAssertEqual(result, .failure(.unknown))
    }

    // MARK: - グループ一覧の並び順

    func testSortedForList_newestActivityFirst() throws {
        let groups = try [
            makeGroup(id: "old", lastActivityOffset: 100),
            makeGroup(id: "newest", lastActivityOffset: 300),
            makeGroup(id: "middle", lastActivityOffset: 200),
        ]
        let sorted = SoratomoGroupService.sortedForList(groups)
        XCTAssertEqual(sorted.map(\.id), ["newest", "middle", "old"])
    }

    func testSortedForList_returnsAtMost10() throws {
        // 11 件を、順不同で渡す。活動時刻は g0（最も古い）〜 g10（最も新しい）
        let order = [5, 0, 9, 2, 10, 7, 1, 8, 3, 6, 4]
        let groups = try order.map { index in
            try makeGroup(id: "g\(index)", lastActivityOffset: TimeInterval(index) * 60)
        }
        let sorted = SoratomoGroupService.sortedForList(groups)

        XCTAssertEqual(sorted.count, 10)
        // 新しい順の上位 10 件。いちばん古い g0 だけが落ちる
        XCTAssertEqual(sorted.map(\.id), ["g10", "g9", "g8", "g7", "g6", "g5", "g4", "g3", "g2", "g1"])
    }

    func testSortedForList_keepsAllWhenAtMost10() throws {
        let groups = try (0 ..< 10).map { index in
            try makeGroup(id: "g\(index)", lastActivityOffset: TimeInterval(index))
        }
        XCTAssertEqual(SoratomoGroupService.sortedForList(groups).count, 10)
        XCTAssertEqual(SoratomoGroupService.sortedForList([]).count, 0)
    }

    func testSortedForList_tieBreaksByCreatedAtThenId() throws {
        // 活動時刻が同じなら、作成日時の新しい順。それも同じなら ID 順（並びが揺れない）
        let groups = try [
            makeGroup(id: "b", lastActivityOffset: 100, createdOffset: 0),
            makeGroup(id: "a", lastActivityOffset: 100, createdOffset: 0),
            makeGroup(id: "c", lastActivityOffset: 100, createdOffset: 50),
        ]
        XCTAssertEqual(SoratomoGroupService.sortedForList(groups).map(\.id), ["c", "a", "b"])
        XCTAssertEqual(SoratomoGroupService.sortedForList(groups.reversed()).map(\.id), ["c", "a", "b"])
    }

    // MARK: - メンバー一覧の並び順

    func testSortedForMembers_oldestJoinFirst() {
        let members = [
            SoratomoMember(id: "u3", role: .member, joinedAt: baseDate.addingTimeInterval(200)),
            SoratomoMember(id: "u1", role: .owner, joinedAt: baseDate),
            SoratomoMember(id: "u2", role: .member, joinedAt: baseDate.addingTimeInterval(100)),
        ]
        let sorted = SoratomoGroupService.sortedForMembers(members)
        XCTAssertEqual(sorted.map(\.id), ["u1", "u2", "u3"])
        // オーナーの区別は並べ替えで失われない
        XCTAssertEqual(sorted.first?.role, .owner)
    }
}
