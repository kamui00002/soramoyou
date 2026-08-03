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

/// ループ動画のプリセット（単一3択・2026-07-26確定 / 2026-08-02に「動かない」を根治）。
///
/// ⚠️ **雲が動くかどうかは①falのプロンプト ②ドリフト比率 の2つで決まる。setpts は尺と減速。**
///    「大きい積雲が動かない」という実機FBの原因調査（2026-08-02）で分かったこと:
///      - 空マスクは正常だった（カバー率92.8%・積雲は白＝動かす側）。マスクのバグではない。
///      - 旧プロンプトが "slowly" / "gentle" / "calm river" と**3回「ゆっくり」と指示**していて、
///        ドリフト比率をいくら上げても打ち消されていた（`skyMotionCore.FAL_PROMPT` の注記参照）。
///      - ドリフト比率には**閾値**があり、幅6.5%以下は Kling にほぼ無視される。
///    実測（同一写真・空の累積フロー ＝ 隣接フレーム間の水平ずれをサブピクセル積算した値）:
///      | 条件                          | %幅/秒 |
///      | 旧prompt・比率2.3%（実機）    | 0.120  ← ユーザー「動かない」
///      | 旧prompt・比率4.0%            | 0.046  ← 増やしても効かない
///      | 旧prompt・比率6.5%            | 0.264  ← まだ効かない
///      | 旧prompt・比率10%（2回）      | 1.572 / 0.379 ← 効くが当たり外れ4.1倍
///      | **新prompt・比率10%（2回）**  | **3.087 / 2.126** ← 外れの方でも十分動く
///    地上は全4本で移動 0〜1px（static_mask は効いている）。
///
/// ⚠️ ドリフト量は **画像幅に対する比率** で持つ（絶対pxではない）。
///    写真は長辺1920に縮小されるため、同じ絶対pxでも横写真(幅1920)は縦写真(幅1440)より
///    相対移動量が1.33倍小さくなり、向きによって速さが変わってしまう。
enum SkyMotionPreset: String, CaseIterable, Identifiable {
    /// 速い・約5.6秒（setpts1.3）
    case quick
    /// 標準・約6.7秒（setpts1.5）
    case standard
    /// ゆっくり・約7.7秒（setpts1.7）
    case calm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quick: "速い（約5.5秒）"
        case .standard: "標準（約6.5秒）"
        case .calm: "ゆっくり（約7.5秒）"
        }
    }

    /// 雲の水平移動量（**画像幅に対する比率**）。fal へ渡す trajectory の長さになる。
    /// `SkyMotionAssetPreparer` が縮小後の実幅に掛けて trajectory のpx量にする。
    ///
    /// ⚠️ **プリセットによらず同じ値**にしている。理由は2つ:
    ///    1. 6.5%以下は Kling にほぼ無視される（enum 冒頭の実測表）。プリセットごとに
    ///       0.023〜0.033 と刻んでいた旧実装は、**3つとも無視される領域**に居た。
    ///    2. 同条件でも生成ごとに1.45倍ばらつくため、プリセット間で1割刻みにしても
    ///       ノイズに埋もれる（＝意味のない精度）。速さ・尺の差は setpts 側で付ける。
    ///
    /// 下限: 0.07 未満は無視される領域。上限: 0.10 で地上固定を4本とも実測確認済み
    /// （それ以上は未検証）。
    static let driftWidthRatio: CGFloat = 0.10

    /// サーバーの setpts 係数（`skyMotionCore.LOOP_DURATION_FACTORS`）から決まる出力尺の
    /// 見込み値(秒)。`label` の文言と整合していることをテストで確認するための定数。
    ///
    /// 算出根拠: 素材(Kling)は約5.1秒 → `setpts × 5.1 − 1.0`(クロスフェード1秒ぶん短くなる)。
    /// quick の 5.64 は実測値で、他はそこから逆算した見込み。
    var approximateSeconds: CGFloat {
        switch self {
        case .quick: 5.64 // setpts 1.3（実測）
        case .standard: 6.67 // setpts 1.5
        case .calm: 7.69 // setpts 1.7
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
