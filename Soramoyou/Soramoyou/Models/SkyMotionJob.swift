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

/// ループ動画のプリセット（単一3択・2026-07-26確定 / 2026-07-28に速度較正）。
/// 速さと尺が「対角線」でセットになる: 速い=短い / ゆっくり=長い。
/// - `driftWidthRatio`（雲の移動量 → trajectory・fal生成に反映）で「速さ」が決まり、
/// - `loopDurationKey`（→ `livingSkyJobs.loopDuration` → サーバー `slowFactorForJob` の setpts）で「尺」が決まる。
///
/// ⚠️ ドリフト量は **画像幅に対する比率** で持つ（絶対pxではない）。
///    写真は長辺1920に縮小されるため、同じ絶対pxでも横写真(幅1920)は縦写真(幅1440)より
///    相対移動量が1.33倍小さくなり、「横写真だけ動いて見えない」不具合になっていた（2026-07-28実機FB）。
///
/// 較正の根拠（同一写真・同一サーバー経路での実測。動き量=隣接フレーム平均絶対差×fps）:
///   - 旧quick  幅1.77% ÷ 5.64s = 0.314%/秒 → 実測12.4「とても良かった」
///   - 旧calm   幅1.67% ÷10.64s = 0.157%/秒 → 実測 6.4「動いていない」
///   見かけの動きは (幅比 ÷ 出力尺) にほぼ完全比例する（予測と実測の誤差3%）ため、
///   下限6.4を大きく上回り、かつ速さの序列を保つ値として quick 12.4 / standard 11.7 / calm 11.2 を狙う。
enum SkyMotionPreset: String, CaseIterable, Identifiable {
    /// 速い・約5.6秒（実機で「とても良かった」判定の速度を維持 / setpts1.3）
    case quick
    /// 標準・約8秒（setpts1.8）
    case standard
    /// ゆっくり・約10.6秒（setpts2.3）
    case calm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quick: "速い（約5秒）"
        case .standard: "標準（約7.5秒）"
        case .calm: "ゆっくり（約10秒）"
        }
    }

    /// 雲の水平移動量（**画像幅に対する比率**）。速さを決める。
    /// `SkyMotionAssetPreparer` が縮小後の実幅に掛けて trajectory のpx量にする。
    /// 上限の安全域: 幅の4.7%まではゴースト無し・地上固定OKを実証済み（旧 fast_10s 検証）。
    var driftWidthRatio: CGFloat {
        switch self {
        case .quick: 0.018
        case .standard: 0.024
        case .calm: 0.030
        }
    }

    /// `livingSkyJobs.loopDuration` に書く値。サーバー `slowFactorForJob` が setpts 係数へ写像する。
    var loopDurationKey: String {
        switch self {
        case .quick: "short"
        case .standard: "medium"
        case .calm: "long"
        }
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
        x = Int(point.x.rounded())
        y = Int(point.y.rounded())
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
    /// ループ動画の尺（`SkyMotionPreset.loopDurationKey`: "short"/"medium"/"long"）。client が選んで書き、
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
        loopDuration: String = SkyMotionPreset.calm.loopDurationKey
    ) {
        self.id = id
        self.userId = userId
        status = .pending
        self.sourcePath = sourcePath
        self.skyMaskPath = skyMaskPath
        self.groundMaskPath = groundMaskPath
        self.aspectRatio = aspectRatio
        self.trajectory = trajectory
        self.loopDuration = loopDuration
        falRequestId = nil
        videoURL = nil
        pollAttempts = 0
        errorCode = nil
        error = nil
        // サーバー時刻は toFirestoreData() が FieldValue.serverTimestamp() で設定するため、
        // クライアント生成時点ではまだ確定しない（Feedback.swift と同方針）。
        createdAt = nil
        updatedAt = nil
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
            "updatedAt": FieldValue.serverTimestamp(),
        ]
    }

    // MARK: - Firestore Mapping（読み込み用・snapshot listener 経由）

    /// Firestore ドキュメントデータから初期化（Cloud Functions による状態遷移後の読み込み用）。
    /// 必須フィールド（userId/status）が欠落している場合のみ nil を返す。
    /// それ以外の欠落フィールドは安全な既定値にフォールバックする（Draft/Post と同方針）。
    init?(from documentData: [String: Any], id: String) {
        guard let userId = documentData["userId"] as? String,
              let statusRaw = documentData["status"] as? String
        else {
            return nil
        }

        self.id = id
        self.userId = userId
        // 未知の status 文字列（想定外のサーバー側変更）は .pending へフォールバックする
        // （Visibility(rawValue:) ?? .public と同じ「クラッシュより安全側フォールバック」方針）。
        status = SkyMotionJobStatus(rawValue: statusRaw) ?? .pending
        sourcePath = documentData["sourcePath"] as? String ?? ""
        skyMaskPath = documentData["skyMaskPath"] as? String ?? ""
        groundMaskPath = documentData["groundMaskPath"] as? String ?? ""
        aspectRatio = documentData["aspectRatio"] as? String ?? "1:1"
        loopDuration = documentData["loopDuration"] as? String ?? SkyMotionPreset.calm.loopDurationKey

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
            trajectory = decodedPoints
        } else {
            trajectory = []
        }

        falRequestId = documentData["falRequestId"] as? String
        videoURL = documentData["videoURL"] as? String
        pollAttempts = documentData["pollAttempts"] as? Int ?? 0
        errorCode = documentData["errorCode"] as? String
        error = documentData["error"] as? String
        createdAt = (documentData["createdAt"] as? Timestamp)?.dateValue()
        updatedAt = (documentData["updatedAt"] as? Timestamp)?.dateValue()
    }

    /// Firestore DocumentSnapshot から初期化。
    init?(from document: DocumentSnapshot) {
        guard let data = document.data() else { return nil }
        self.init(from: data, id: document.documentID)
    }
}
