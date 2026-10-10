//
//  SoratomoModerationService.swift
//  Soramoyou
//
//  そらともの通報とブロックのサービス ⭐️☁️
//  （release-gate 9.2・design.md の「通報とブロック（SoratomoModerationService）」・要件 5.4・5.6・5.9・9.3・9.8・9.9・9.10）
//
//  - 通報: Callable `soratomoReportSky`（制限時間 20 秒）。同じ投稿をもう一度通報しても、サーバーは成功で返す（要件 6.7）
//  - ブロック: `users/{uid}.blockedUserIds` へ arrayUnion を、書き込みだけのトランザクションで書く。
//    保存できたときだけ、既存のブロックの通知（`.userBlocked`）を送る（ホーム・タグ・ギャラリー・あなた向けと、そらともが隠す）
//
//  ⚠️ 既存のルートの通報とブロック（FirestoreService）は変えない（要件 13.4）。
//     既存の `blockUser` は `updateData` で書くので、圏外でも失敗せず、つながったときに後から書かれる。
//     ここでは「失敗を出し、隠さない」（要件 9.9）ために、端末内に積まれないトランザクションで書く。
//  ⚠️ 通報されたこと・ブロックされたことを、相手やほかのメンバーに知らせる処理は作らない（要件 5.9・9.10）。
//  ⚠️ 計測（SoratomoAnalytics.log）はここでは呼ばない。画面の ViewModel（tasks 10.x）の責務。
//  ⚠️ 失敗の記録（SoratomoError.record）に入れてよいのは ID だけ（要件 14.1）。
//

import FirebaseFirestore
import FirebaseFunctions
import Foundation

// MARK: - Functions と Firestore の窓口（テストで差し替える）

/// 通報の Callable と、ブロックの一覧（`users/{uid}.blockedUserIds`）の窓口
///
/// `SoratomoModerationService` は、この窓口が投げたエラーを `SoratomoError` に写すことと、
/// 通知を送るかどうかを決めることを受け持つ。窓口は `SoratomoError` へ写さず、元のエラーのまま投げる
/// （形は `SoratomoProfileDataSource` と同じ）。
protocol SoratomoModerationDataSource: Sendable {
    /// Callable を呼んで、戻り値（デコード済みの JSON）を返す
    /// - Parameters:
    ///   - name: Callable の名前
    ///   - payload: 送る値
    ///   - timeout: 制限時間（秒）
    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any

    /// ブロックの一覧に足す（書き込みだけのトランザクション。圏外では失敗し、端末内に積まれない）
    /// - Parameters:
    ///   - authorId: ブロックする投稿者の uid
    ///   - uid: 自分の uid
    func addBlockedUserId(_ authorId: String, uid: String) async throws

    /// ブロックの一覧を読む
    /// - Returns: 一覧。文書が無い・項目が無いときは空
    func fetchBlockedUserIds(uid: String) async throws -> [String]
}

// MARK: - サービス

/// 記録（非致命エラー）に残す、通報の失敗（ID も中身も持たない）
private enum SoratomoModerationFailure: LocalizedError {
    /// 通報の Callable の戻り値が、決めた形（`{ accepted: true }`）でなかった
    case malformedReportResponse

    var errorDescription: String? {
        switch self {
        case .malformedReportResponse:
            "soratomo: 通報の戻り値の形が違う"
        }
    }
}

/// 通報とブロックのサービス（`SoratomoModerationServiceProtocol` の本物の実装）
final class SoratomoModerationService: SoratomoModerationServiceProtocol {
    /// 通報の Callable の名前（functions/soratomo.js の `exports` と同じ）
    static let reportCallableName = "soratomoReportSky"

    /// Functions と Firestore の窓口
    private let dataSource: any SoratomoModerationDataSource
    /// ブロックの通知（`.userBlocked`）を送る通知センター（テストで差し替える）
    private let notificationCenter: NotificationCenter

    /// - Parameters:
    ///   - dataSource: Functions と Firestore の窓口。既定は本物（呼ばれたときに初めて Firebase を使う）
    ///   - notificationCenter: `.userBlocked` を送る通知センター。既定は `.default`
    init(
        dataSource: any SoratomoModerationDataSource = SoratomoModerationFirebaseDataSource(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.dataSource = dataSource
        self.notificationCenter = notificationCenter
    }

    // MARK: - SoratomoModerationServiceProtocol

    /// 投稿を通報する（Callable `soratomoReportSky`・20 秒）
    ///
    /// 失敗は `SoratomoGroupService.mapCallableError` で写す（通信・制限時間切れは `.network`、
    /// 投稿が無いは `.skyGone`、自分の投稿・理由の誤りなどは `.unknown`）。
    /// 想定外の失敗（`.unknown`・`.permissionDenied`）だけを記録する（SoratomoGroupService の `call` と同じ決まり）。
    func report(groupId: String, skyId: String, reason: ReportReason) async throws(SoratomoError) {
        let response: Any
        do {
            response = try await dataSource.callCallable(
                Self.reportCallableName,
                payload: ["groupId": groupId, "skyId": skyId, "reason": reason.rawValue],
                timeout: SoratomoGroupService.callTimeout
            )
        } catch {
            let mapped = SoratomoGroupService.mapCallableError(error)
            switch mapped {
            case .unknown, .permissionDenied:
                SoratomoError.record(error, context: "soratomo.reportSky")
            default:
                break
            }
            throw mapped
        }
        guard Self.isAcceptedReportResponse(response) else {
            SoratomoError.record(SoratomoModerationFailure.malformedReportResponse, context: "soratomo.reportSky.response")
            throw SoratomoError.unknown
        }
    }

    /// 投稿者をブロックする（`users/{uid}.blockedUserIds` に足す）
    ///
    /// 保存できたときだけ `.userBlocked` を送る。失敗したら送らない
    /// （一覧から消したのに、実際はブロックされていない、を防ぐ・要件 9.9）。
    /// 失敗は `SoratomoError.fromFirestore(_:access: .write)` で写す（圏外は `.network`）。
    func block(uid: String, authorId: String) async throws(SoratomoError) {
        // 空文字や「/」を含む uid で文書のパスを作ると、Firestore が異常終了する。呼ぶ前に弾く
        guard SoratomoGroupService.isUsableDocumentId(uid),
              SoratomoGroupService.isUsableDocumentId(authorId)
        else {
            throw SoratomoError.unknown
        }
        do {
            try await dataSource.addBlockedUserId(authorId, uid: uid)
        } catch {
            throw Self.mapWriteError(error, context: "soratomo.blockUser")
        }
        postUserBlocked(authorId)
    }

    /// ブロックの一覧（`users/{uid}.blockedUserIds`）を読む
    ///
    /// 呼び出し側（隠す集合の読み込み）は、失敗の種類を区別しない（読めなければ今の一覧のまま）。
    /// 通信の失敗は `.network`、それ以外は記録に残して `.unknown` にする
    /// （`.read` の写しの「メンバーでない」は、グループを読めないときの意味なので使わない）。
    func fetchBlockedUserIds(uid: String) async throws(SoratomoError) -> Set<String> {
        guard SoratomoGroupService.isUsableDocumentId(uid) else {
            throw SoratomoError.unknown
        }
        do {
            return try await Set(dataSource.fetchBlockedUserIds(uid: uid))
        } catch {
            if SoratomoError.fromFirestore(error, access: .read) == .network {
                throw SoratomoError.network
            }
            SoratomoError.record(error, context: "soratomo.fetchBlockedUserIds")
            throw SoratomoError.unknown
        }
    }

    // MARK: - Private

    /// ブロックが保存されたことを、既存の一覧（ホーム・タグ・ギャラリー・あなた向け）とそらともに伝える
    private func postUserBlocked(_ authorId: String) {
        notificationCenter.post(
            name: .userBlocked,
            object: nil,
            userInfo: [Notification.blockedUserIdKey: authorId]
        )
    }

    /// 書き込みの失敗を写す。想定外（`.unknown`・`.permissionDenied`）だけ記録に残す
    private static func mapWriteError(_ error: Error, context: StaticString) -> SoratomoError {
        let mapped = SoratomoError.fromFirestore(error, access: .write)
        switch mapped {
        case .unknown, .permissionDenied:
            SoratomoError.record(error, context: context)
        default:
            break
        }
        return mapped
    }

    // MARK: - 純関数

    /// 通報の Callable の戻り値が `{ accepted: true }` か
    static func isAcceptedReportResponse(_ response: Any) -> Bool {
        guard let object = response as? [String: Any],
              let accepted = object["accepted"] as? Bool
        else {
            return false
        }
        return accepted
    }
}

// MARK: - 本物の窓口

/// 通報の Callable（asia-northeast1）と、ブロックの一覧（`users/{uid}`）の本物の窓口
///
/// 状態を持たない（呼ばれるたびに `Functions`・`Firestore` を引く）。アプリの外（単体テスト）で
/// `SoratomoModerationService()` を作っても、呼ばない限り Firebase に触れない。
struct SoratomoModerationFirebaseDataSource: SoratomoModerationDataSource {
    /// 既存の利用者のコレクション名（FirestoreService の `usersCollection` と同じ。
    /// ⚠️ `SoratomoFirestorePath.users` は別物（`soratomoUsers`）なので使わない）
    private static let usersCollection = "users"
    /// ブロックの一覧の項目（FirestoreService の `blockUser`・`fetchBlockedUserIds` と同じ）
    private static let blockedUserIdsField = "blockedUserIds"

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

    func addBlockedUserId(_ authorId: String, uid: String) async throws {
        let reference = db.collection(Self.usersCollection).document(uid)
        let fields: [String: Any] = [Self.blockedUserIdsField: FieldValue.arrayUnion([authorId])]
        // 読み取りの無いトランザクションで更新だけを行う（SoratomoSkyService の作成・削除と同じ形）。
        // 書き込み用のバッチや `updateData` と違い、端末内に積まれない。圏外では失敗する。
        // 文書が無ければ Firestore の notFound で失敗する（書き込みの notFound は `.unknown` に写る）
        _ = try await db.runTransaction { transaction, _ -> Any? in
            transaction.updateData(fields, forDocument: reference)
            return nil
        }
    }

    func fetchBlockedUserIds(uid: String) async throws -> [String] {
        // 既存の FirestoreService.fetchBlockedUserIds と同じ読み方（圏外ならキャッシュから読む）
        let snapshot = try await db.collection(Self.usersCollection).document(uid).getDocument()
        return snapshot.data()?[Self.blockedUserIdsField] as? [String] ?? []
    }
}
