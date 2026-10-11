//
//  SoratomoLeaveService.swift
//  Soramoyou
//
//  そらとものグループを 1 つだけ抜けるサービス ⭐️☁️
//  （leave-group 7.1・design.md の「SoratomoLeaveService」・要件 4.3・4.4・4.5）
//
//  - Callable `soratomoLeaveGroup` を、完了（`{ done: true }`）が返るまで呼ぶ（最大 8 回・1 回 75 秒）。
//    サーバーは 1 回あたり 45 秒の予算で片づけ、終わらなければ `done: false` を返す（続きは次の呼び出しで片づける）
//  - 失敗したら呼び直さずに投げる。画面は、失敗の後に `membershipOnServer` でメンバーのままかを確かめてから決める
//  - 型は退会のサービス（SoratomoAccountDeletionService）にそろえた（Callable の窓口を差し替えてテストする）
//
//  ⚠️ サーバーはメンバーでない人にも完了と同じ応答を返す（`not_member` を返さない・要件 3.14）。
//  ⚠️ 失敗の記録（SoratomoError.record）の文脈は固定の文字列だけ。グループ ID も入れない（要件 11.1）。
//

import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation

// MARK: - サービス

/// 記録（非致命エラー）に残す、抜けるの失敗（ID も中身も持たない）
private enum SoratomoLeaveFailure: LocalizedError {
    /// 戻り値が、決めた形（`{ done: Bool, groupDeleted: Bool }`）でなかった
    case malformedResponse
    /// 最大回数まで呼んでも、完了が返らなかった
    case incomplete
    /// 繰り返しの途中で、サインインしているアカウントが替わった（またはサインアウトした）
    case accountChanged

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "soratomo: 抜けるの戻り値の形が違う"
        case .incomplete:
            "soratomo: 抜けるの片づけが最大回数で終わらなかった"
        case .accountChanged:
            "soratomo: 抜けるの途中でアカウントが替わったので止めた"
        }
    }
}

/// そらとものグループを 1 つだけ抜けるサービス（`SoratomoLeaveServiceProtocol` の本物の実装）
final class SoratomoLeaveService: SoratomoLeaveServiceProtocol {
    /// 抜けるの Callable の名前（functions/soratomo.js の `exports` と同じ）
    static let callableName = "soratomoLeaveGroup"
    /// 1 回の制限時間（秒）。サーバーの予算 45 秒＋余裕（退会と同じ）
    static let callTimeout: TimeInterval = 75
    /// 呼ぶ回数の上限（退会と同じ）
    static let maxCalls = 8

    /// Functions と Firestore の窓口
    private let dataSource: any SoratomoLeaveDataSource

    /// - Parameter dataSource: 窓口。既定は本物（呼ばれたときに初めて Firebase を使う）
    init(dataSource: any SoratomoLeaveDataSource = SoratomoLeaveFirebaseDataSource()) {
        self.dataSource = dataSource
    }

    // MARK: - SoratomoLeaveServiceProtocol

    /// 片づけが終わるまで、抜けるの Callable を呼ぶ
    ///
    /// - 完了が返ったら、すぐに戻る（それ以上は呼ばない）
    /// - 失敗したら、呼び直さずに投げる（通信・制限時間切れは `.network`、それ以外は `.unknown`）
    /// - `maxCalls` 回呼んでも完了しなければ `.incomplete`
    /// - 戻り値の `groupDeleted` は、どれか 1 回で真なら真にする
    ///   （再試行の間にほかの人が抜けてグループが消えると、後の回で真に変わる・design.md の API Contract）
    func leave(groupId: String) async throws(SoratomoLeaveError) -> SoratomoLeaveResult {
        // 文書の ID として使えない値（空・「/」を含む）は送らない。自動 ID の形か（英数字 1〜64 文字）は
        // サーバーが確かめて invalid_input で断る（アプリは自動 ID しか持たない）
        guard SoratomoGroupService.isUsableDocumentId(groupId) else {
            throw SoratomoLeaveError.unknown
        }
        var groupDeleted = false
        // 最初に、いまの利用者を覚える。回ごとに同じかを確かめ、替わっていたら次を送らない（/review-full D1）。
        // Callable は回ごとにその時点の利用者のトークンで送られる。途中でサインアウトして、同じグループに入っている
        // 別のアカウントで入り直すと、確認なしにその人が抜けてしまう（投稿も消えて戻せない）。
        // 最初からサインインしていない（nil のまま）ときは、今までどおり呼んでサーバーに断らせる
        let startUid = dataSource.currentUid()
        for _ in 0 ..< Self.maxCalls {
            guard dataSource.currentUid() == startUid else {
                SoratomoError.record(SoratomoLeaveFailure.accountChanged, context: "soratomo.leaveGroup.accountChanged")
                throw SoratomoLeaveError.unknown
            }
            let response: Any
            do {
                response = try await dataSource.callCallable(
                    Self.callableName,
                    payload: ["groupId": groupId],
                    timeout: Self.callTimeout
                )
            } catch {
                throw Self.mapCallError(error)
            }
            guard let decoded = Self.decodeResponse(response) else {
                SoratomoError.record(SoratomoLeaveFailure.malformedResponse, context: "soratomo.leaveGroup.response")
                throw SoratomoLeaveError.unknown
            }
            groupDeleted = groupDeleted || decoded.groupDeleted
            if decoded.done {
                return SoratomoLeaveResult(groupDeleted: groupDeleted)
            }
        }
        SoratomoError.record(SoratomoLeaveFailure.incomplete, context: "soratomo.leaveGroup.incomplete")
        throw SoratomoLeaveError.incomplete
    }

    /// 自分のメンバーの文書を、キャッシュを使わずに読み、メンバーのままかを返す
    ///
    /// | 結果 | 返す値 |
    /// |---|---|
    /// | 読めて文書がある | `.member` |
    /// | 読めて文書が無い（サーバーで不在を確かめた） | `.notMember` |
    /// | 権限の拒否（メンバーでなければルールが読みを拒否する） | `.notMember` |
    /// | 通信の失敗・それ以外 | `.unknown` |
    ///
    /// - Note: 「読めて文書が無い」は design.md に無い枝。ルールは読みを同じ文書の存在で許すので本番では起きないが、
    ///   サーバーで不在を確かめた結果なので、グループの監視（`SoratomoGroupService.resolveObservedGroup`）の前例に合わせて `.notMember` にした。
    /// - Important: メンバーでない人の読みが `permissionDenied` で届くか（`notFound` でないか）は、
    ///   本番につないだ開発版で確かめる（要確認 Q2・tasks 12.2）。違えば、ここの写しを直す。
    func membershipOnServer(groupId: String, uid: String) async -> SoratomoMembershipCheck {
        // 空や「/」を含む値で文書を引くと Firestore が異常終了する（確かめられなかったものとして扱う）
        guard SoratomoGroupService.isUsableDocumentId(groupId), SoratomoGroupService.isUsableDocumentId(uid) else {
            return .unknown
        }
        do {
            return try await dataSource.memberDocumentExistsOnServer(groupId: groupId, uid: uid) ? .member : .notMember
        } catch {
            return Self.mapMembershipError(error)
        }
    }

    // MARK: - 純関数

    /// Callable の失敗を写す。通信・制限時間切れは `.network`、それ以外は記録に残して `.unknown`
    static func mapCallError(_ error: Error) -> SoratomoLeaveError {
        if SoratomoGroupService.mapCallableError(error) == .network {
            return .network
        }
        SoratomoError.record(error, context: "soratomo.leaveGroup")
        return .unknown
    }

    /// メンバーの文書の読みの失敗を写す。権限の拒否だけが `.notMember`。想定外（通信以外）は記録に残す
    static func mapMembershipError(_ error: Error) -> SoratomoMembershipCheck {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain, nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
            return .notMember
        }
        if SoratomoError.fromFirestore(error, access: .read) != .network {
            SoratomoError.record(error, context: "soratomo.leaveGroup.membership")
        }
        return .unknown
    }

    /// 戻り値の `done` と `groupDeleted`。どちらかが無い・真偽値でなければ nil
    static func decodeResponse(_ response: Any) -> (done: Bool, groupDeleted: Bool)? {
        guard let object = response as? [String: Any],
              let done = object["done"] as? Bool,
              let groupDeleted = object["groupDeleted"] as? Bool
        else {
            return nil
        }
        return (done, groupDeleted)
    }
}

// MARK: - 本物の窓口

/// 抜けるの Callable（asia-northeast1）と、メンバーの文書の本物の窓口
///
/// 状態を持たない（呼ばれるたびに `Functions`・`Firestore` を引く）。アプリの外（単体テスト）で
/// `SoratomoLeaveService()` を作っても、呼ばない限り Firebase に触れない。
struct SoratomoLeaveFirebaseDataSource: SoratomoLeaveDataSource {
    private var db: Firestore {
        Firestore.firestore()
    }

    private var functions: Functions {
        Functions.functions(region: SoratomoGroupService.region)
    }

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        let callable = functions.httpsCallable(name)
        callable.timeoutInterval = timeout
        let result = try await callable.call(payload)
        return result.data
    }

    func memberDocumentExistsOnServer(groupId: String, uid: String) async throws -> Bool {
        // キャッシュを使わない（抜けた直後の端末のキャッシュには、自分のメンバーの文書が残っている）
        let snapshot = try await db.collection(SoratomoFirestorePath.groups)
            .document(groupId)
            .collection(SoratomoFirestorePath.members)
            .document(uid)
            .getDocument(source: .server)
        return snapshot.exists
    }

    func currentUid() -> String? {
        Auth.auth().currentUser?.uid
    }
}
