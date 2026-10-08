//
//  SoratomoGuidelineService.swift
//  Soramoyou
//
//  そらともガイドラインへの同意のサービス ⭐️☁️
//  （release-gate 9.5・design.md の「同意」の節・要件 10.2・10.6・10.7）
//
//  - 同意の状態: `soratomoUsers/{uid}` の `guidelineVersion`（同意した版）と `groupCount`（所属数）を読む。
//    文書が無ければ「未同意・所属 0」。本人だけが読める（ルールは既存のまま）
//  - 同意の記録: Callable `soratomoAgreeGuideline`（制限時間 20 秒）に `{ version }` を送る。
//    サーバーの版と違えば `outdated_guideline` で拒否される（`mapCallableError` がアプリの版と比べて写す）
//
//  ⚠️ 計測（SoratomoAnalytics.log）はここでは呼ばない。画面と ViewModel の責務。
//  ⚠️ 失敗の記録（SoratomoError.record）に入れてよいのは ID だけ（要件 14.1）。
//

import FirebaseFirestore
import FirebaseFunctions
import Foundation

// MARK: - Functions と Firestore の窓口（テストで差し替える）

/// 同意の Callable と、同意の状態（`soratomoUsers/{uid}`）の窓口
///
/// 窓口は元のエラーのまま投げる（形は `SoratomoModerationDataSource` と同じ）。
protocol SoratomoGuidelineDataSource: Sendable {
    /// Callable を呼んで、戻り値（デコード済みの JSON）を返す
    /// - Parameters:
    ///   - name: Callable の名前
    ///   - payload: 送る値
    ///   - timeout: 制限時間（秒）
    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any

    /// `soratomoUsers/{uid}` の中身を読む
    /// - Returns: 文書の項目。文書が無ければ nil
    func fetchUserIndex(uid: String) async throws -> [String: Any]?
}

// MARK: - サービス

/// 記録（非致命エラー）に残す、同意の失敗（ID も中身も持たない）
private enum SoratomoGuidelineFailure: LocalizedError {
    /// 同意の Callable の戻り値が、決めた形（`{ version: number }`）でなかった
    case malformedAgreeResponse

    var errorDescription: String? {
        switch self {
        case .malformedAgreeResponse:
            "soratomo: 同意の戻り値の形が違う"
        }
    }
}

/// 同意のサービス（`SoratomoGuidelineServiceProtocol` の本物の実装）
final class SoratomoGuidelineService: SoratomoGuidelineServiceProtocol {
    /// 同意の Callable の名前（functions/soratomo.js の `exports` と同じ）
    static let agreeCallableName = "soratomoAgreeGuideline"

    /// `soratomoUsers/{uid}` の項目
    enum Field {
        /// 同意した版
        static let guidelineVersion = "guidelineVersion"
        /// 所属しているグループの数
        static let groupCount = "groupCount"
    }

    /// Functions と Firestore の窓口
    private let dataSource: any SoratomoGuidelineDataSource

    /// - Parameter dataSource: Functions と Firestore の窓口。既定は本物（呼ばれたときに初めて Firebase を使う）
    init(dataSource: any SoratomoGuidelineDataSource = SoratomoGuidelineFirebaseDataSource()) {
        self.dataSource = dataSource
    }

    // MARK: - SoratomoGuidelineServiceProtocol

    /// 同意の状態を読む
    ///
    /// 呼び出し側（入口の判定）は、失敗の種類を区別しない（読めなければ全文を出さない）。
    /// 通信の失敗は `.network`、それ以外は記録に残して `.unknown` にする（`fetchBlockedUserIds` と同じ決まり）。
    func fetchConsentStatus(uid: String) async throws(SoratomoError) -> SoratomoConsentStatus {
        guard SoratomoGroupService.isUsableDocumentId(uid) else {
            throw SoratomoError.unknown
        }
        let fields: [String: Any]?
        do {
            fields = try await dataSource.fetchUserIndex(uid: uid)
        } catch {
            if SoratomoError.fromFirestore(error, access: .read) == .network {
                throw SoratomoError.network
            }
            SoratomoError.record(error, context: "soratomo.fetchConsentStatus")
            throw SoratomoError.unknown
        }
        return Self.consentStatus(from: fields)
    }

    /// 同意を記録する（Callable `soratomoAgreeGuideline`・20 秒）
    ///
    /// 失敗は `SoratomoGroupService.mapCallableError` で写す。想定外（`.unknown`・`.permissionDenied`）だけ記録する。
    func agree(version: Int) async throws(SoratomoError) {
        let response: Any
        do {
            response = try await dataSource.callCallable(
                Self.agreeCallableName,
                payload: ["version": version],
                timeout: SoratomoGroupService.callTimeout
            )
        } catch {
            let mapped = SoratomoGroupService.mapCallableError(error)
            switch mapped {
            case .unknown, .permissionDenied:
                SoratomoError.record(error, context: "soratomo.agreeGuideline")
            default:
                break
            }
            throw mapped
        }
        guard Self.isAgreeResponse(response) else {
            SoratomoError.record(SoratomoGuidelineFailure.malformedAgreeResponse, context: "soratomo.agreeGuideline.response")
            throw SoratomoError.unknown
        }
    }

    // MARK: - 純関数

    /// `soratomoUsers/{uid}` の項目から同意の状態を作る
    ///
    /// 文書が無い・項目が無い・型が違うときは「未同意」「所属 0」として読む（サーバーの `countOf` と同じ扱い）。
    static func consentStatus(from fields: [String: Any]?) -> SoratomoConsentStatus {
        let agreedVersion = (fields?[Field.guidelineVersion] as? NSNumber)?.intValue
        let groupCount = (fields?[Field.groupCount] as? NSNumber)?.intValue ?? 0
        return SoratomoConsentStatus(agreedVersion: agreedVersion, groupCount: max(groupCount, 0))
    }

    /// 同意の Callable の戻り値が `{ version: number }` か
    static func isAgreeResponse(_ response: Any) -> Bool {
        guard let object = response as? [String: Any] else {
            return false
        }
        return object["version"] is NSNumber
    }
}

// MARK: - 本物の窓口

/// 同意の Callable（asia-northeast1）と、`soratomoUsers/{uid}` の本物の窓口
///
/// 状態を持たない（呼ばれるたびに `Functions`・`Firestore` を引く）。アプリの外（単体テスト）で
/// `SoratomoGuidelineService()` を作っても、呼ばない限り Firebase に触れない。
struct SoratomoGuidelineFirebaseDataSource: SoratomoGuidelineDataSource {
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

    func fetchUserIndex(uid: String) async throws -> [String: Any]? {
        // 圏外ならキャッシュから読む（入口の判定は、読めなければ出さないので、古い値でも害が小さい）
        let snapshot = try await db.collection(SoratomoFirestorePath.users).document(uid).getDocument()
        return snapshot.data()
    }
}
