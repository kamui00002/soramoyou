//
//  SkyMotionJob.swift
//  Soramoyou
//
//  ⭐️「空を動かす」（Kling版）フェーズ1b: `livingSkyJobs/{jobId}` の Codable モデル。
//
//  設計書: docs/sky-motion-design.md §1（唯一のデータ契約の土台）
//  ⚠️ 命名が近い（`LivingSky*`）既存の Metal ローカル版 Living Sky とは別機能。
//
//  クライアントが書けるのは「画像3枚のアップロード」と「status="pending" の初期ドキュメント作成」のみ。
//  以降の状態遷移（submitted/completed/failed・falRequestId・videoURL 等）は
//  Cloud Functions（Admin SDK）専用（`firestore.rules` の `allow update, delete: if false` 参照）。
//  そのため本モデルは「作成用イニシャライザ」と「読み込み用イニシャライザ（listener 経由）」を
//  明確に分ける（Draft/Post と同じ toFirestoreData()/init(from:) の手動マッピング方式に合わせる。
//  このコードベースは FirebaseFirestoreSwift の Codable 自動変換を使わない慣習のため）。
//

import FirebaseFirestore
import Foundation
import os

/// `livingSkyJobs/{jobId}.status` の値（設計書§1）。
/// client が書けるのは `.pending` のみ。以降は Cloud Functions が
/// `pending → submitting → submitted → completed/failed` の順に遷移させる。
enum SkyMotionJobStatus: String, CaseIterable {
    case pending
    /// fal.ai への submit 処理中（Cloud Functions が pending から遷移させる中間状態）。
    /// UI 側は `.submitted` と同様「生成中」の待機表示として扱う。
    case submitting
    case submitted
    case completed
    case failed
}

/// 雲の動きの速さ（＝画面上の見かけ速度）。独立2軸(2026-07-24)の1軸目。
/// ⭐️ サーバーの setpts ではなく **trajectory（雲の移動量）** で決まる（`SkyMotionAssetPreparer` が
///    `driftPixels` を変えて fal 生成に反映する）。速いほど雲を大きく動かす＝ゴーストのリスクは上がる。
enum SkyMotionSpeed: String, CaseIterable, Identifiable {
    case fast
    case slow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "速い"
        case .slow: return "ゆっくり"
        }
    }
}

/// ループ動画の尺（長さ）。独立2軸の2軸目。`livingSkyJobs.loopDuration` に rawValue を書き、
/// サーバー `slowFactorForJob` が setpts 係数へ写像する（short≒5秒 / long≒10秒）。
enum SkyMotionDuration: String, CaseIterable, Identifiable {
    case short
    case long

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: return "5秒"
        case .long: return "10秒"
        }
    }
}

/// 速さ×尺 → trajectory の水平ドリフト量(px)。画面上の見かけ速度 = drift ÷ 出力尺 なので、
/// 速さを尺に依らず一定に見せるには drift を尺に比例させる（∴ fast×long が最大ドリフト）。
/// 実証済み安全値 40px 近傍に収めつつ fast/slow で約2倍差をつけ知覚差を確保する。
/// ⚠️ fast×long(68px≒1.7倍) はゴーストの最警戒セル＝実機で要確認（アドバイザー指摘の2失敗モード:
///    過剰drift=ゴースト / 過少drift=速い遅いの差が見えない、の両方を実機で判定すること）。
func skyMotionDriftPixels(speed: SkyMotionSpeed, duration: SkyMotionDuration) -> CGFloat {
    switch (speed, duration) {
    case (.fast, .short): return 34
    case (.fast, .long):  return 68
    case (.slow, .short): return 16
    case (.slow, .long):  return 32
    }
}

/// trajectory 配列の1点（ピクセル座標・整数）。
/// 設計書§4: sky_mask の重心 → 水平方向に +40px の2点。原点は画像左上・y下向き。
struct SkyMotionTrajectoryPoint: Equatable {
    let x: Int
    let y: Int

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// `CGPoint`（`SkyMotionAssetPreparer` の出力・サブピクセル精度）から Firestore 用に丸めて生成する。
    init(rounding point: CGPoint) {
        self.x = Int(point.x.rounded())
        self.y = Int(point.y.rounded())
    }

    func toFirestoreData() -> [String: Any] {
        ["x": x, "y": y]
    }

    init?(from documentData: [String: Any]) {
        guard let x = documentData["x"] as? Int, let y = documentData["y"] as? Int else {
            return nil
        }
        self.x = x
        self.y = y
    }
}

/// 「空を動かす」（Kling版）ジョブ1件（`livingSkyJobs/{jobId}`）。
struct SkyMotionJob: Identifiable {
    private static let logger = Logger(
        subsystem: "com.soramoyou.photo-editor",
        category: "SkyMotionJob"
    )

    let id: String
    let userId: String
    let status: SkyMotionJobStatus
    let sourcePath: String
    let skyMaskPath: String
    let groundMaskPath: String
    let aspectRatio: String
    let trajectory: [SkyMotionTrajectoryPoint]
    /// ループ動画の尺（`SkyMotionDuration` の rawValue: "short"/"long"）。client が選んで書き、
    /// サーバー `slowFactorForJob` が setpts 係数へ写像する（速さは trajectory 側で決まるので
    /// この値は尺だけを担う）。旧ジョブ（欠落）はサーバー側で標準(2.0)にフォールバックする。
    let loopDuration: String
    /// fal.ai へのsubmit成功後に Cloud Functions が設定する（client からは常に nil）
    let falRequestId: String?
    /// 完成後の Storage ダウンロードURL。Cloud Functions が設定する（client からは常に nil）
    let videoURL: String?
    /// ポーラーの試行回数。Cloud Functions が管理する
    let pollAttempts: Int
    /// `"quota_exceeded"` | `"submit_failed"` | `"downstream_unavailable"` | `"timeout"` 等
    /// （設計書§1に "等" とある通り、Cloud Functions 側が将来追加しうるためクローズドな enum にはしない）
    let errorCode: String?
    /// エラーの人間可読メッセージ
    let error: String?
    let createdAt: Date?
    let updatedAt: Date?

    // MARK: - Init（作成用）

    /// クライアント側で新規ジョブを作成するときのイニシャライザ。
    ///
    /// `firestore.rules` の create 条件（`status == 'pending'` かつ
    /// `!hasAny(['falRequestId', 'videoURL'])`）を必ず満たす形に固定する。
    /// function 専用フィールド（falRequestId/videoURL/pollAttempts/errorCode/error）は
    /// ここでは意味を持たないため既定値（nil/0）で保持するのみで、`toFirestoreData()` にも含めない。
    init(
        id: String,
        userId: String,
        sourcePath: String,
        skyMaskPath: String,
        groundMaskPath: String,
        aspectRatio: String,
        trajectory: [SkyMotionTrajectoryPoint],
        loopDuration: String = SkyMotionDuration.long.rawValue
    ) {
        self.id = id
        self.userId = userId
        self.status = .pending
        self.sourcePath = sourcePath
        self.skyMaskPath = skyMaskPath
        self.groundMaskPath = groundMaskPath
        self.aspectRatio = aspectRatio
        self.trajectory = trajectory
        self.loopDuration = loopDuration
        self.falRequestId = nil
        self.videoURL = nil
        self.pollAttempts = 0
        self.errorCode = nil
        self.error = nil
        // サーバー時刻は toFirestoreData() が FieldValue.serverTimestamp() で設定するため、
        // クライアント生成時点ではまだ確定しない（Feedback.swift と同方針）。
        self.createdAt = nil
        self.updatedAt = nil
    }

    // MARK: - Firestore Mapping（作成用）

    /// Firestore ドキュメントデータに変換（新規作成用）。
    /// キーは `firestore.rules` の create 条件を必ず満たすこと
    /// （`userId`/`status` は必須。`falRequestId`/`videoURL` は絶対に含めない）。
    func toFirestoreData() -> [String: Any] {
        [
            "id": id,
            "userId": userId,
            "status": status.rawValue,
            "sourcePath": sourcePath,
            "skyMaskPath": skyMaskPath,
            "groundMaskPath": groundMaskPath,
            "aspectRatio": aspectRatio,
            "trajectory": trajectory.map { $0.toFirestoreData() },
            "loopDuration": loopDuration,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    // MARK: - Firestore Mapping（読み込み用・snapshot listener 経由）

    /// Firestore ドキュメントデータから初期化（Cloud Functions による状態遷移後の読み込み用）。
    /// 必須フィールド（userId/status）が欠落している場合のみ nil を返す。
    /// それ以外の欠落フィールドは安全な既定値にフォールバックする（Draft/Post と同方針）。
    init?(from documentData: [String: Any], id: String) {
        guard let userId = documentData["userId"] as? String,
              let statusRaw = documentData["status"] as? String else {
            return nil
        }

        self.id = id
        self.userId = userId
        // 未知の status 文字列（想定外のサーバー側変更）は .pending へフォールバックする
        // （Visibility(rawValue:) ?? .public と同じ「クラッシュより安全側フォールバック」方針）。
        self.status = SkyMotionJobStatus(rawValue: statusRaw) ?? .pending
        self.sourcePath = documentData["sourcePath"] as? String ?? ""
        self.skyMaskPath = documentData["skyMaskPath"] as? String ?? ""
        self.groundMaskPath = documentData["groundMaskPath"] as? String ?? ""
        self.aspectRatio = documentData["aspectRatio"] as? String ?? "1:1"
        self.loopDuration = documentData["loopDuration"] as? String ?? SkyMotionDuration.long.rawValue

        if let trajectoryData = documentData["trajectory"] as? [[String: Any]] {
            let decodedPoints = trajectoryData.compactMap { SkyMotionTrajectoryPoint(from: $0) }
            // tech-spec.md: 壊れたドキュメントの無言スキップ禁止。一部の点だけデコードに
            // 失敗した場合（想定外のサーバー側フォーマット変更等）はログに残し、
            // クラッシュはさせず成功した点だけで継続する。
            if decodedPoints.count != trajectoryData.count {
                Self.logger.error(
                    "空を動かす: trajectory の一部デコードに失敗 jobId=\(id, privacy: .public) expected=\(trajectoryData.count) actual=\(decodedPoints.count)"
                )
            }
            self.trajectory = decodedPoints
        } else {
            self.trajectory = []
        }

        self.falRequestId = documentData["falRequestId"] as? String
        self.videoURL = documentData["videoURL"] as? String
        self.pollAttempts = documentData["pollAttempts"] as? Int ?? 0
        self.errorCode = documentData["errorCode"] as? String
        self.error = documentData["error"] as? String
        self.createdAt = (documentData["createdAt"] as? Timestamp)?.dateValue()
        self.updatedAt = (documentData["updatedAt"] as? Timestamp)?.dateValue()
    }

    /// Firestore DocumentSnapshot から初期化。
    init?(from document: DocumentSnapshot) {
        guard let data = document.data() else { return nil }
        self.init(from: data, id: document.documentID)
    }
}
