// ⭐️☁️ 空カメラの撮影結果を、写真ライブラリ保存・投稿パイプライン・計装へつなぐサービス
import Foundation
import Photos
import SkyCamera
import UIKit

/// `SkyCameraView` が返す `SkyCameraCapture` を本体の都合に合わせて変換する係。
///
/// 責務は 3 つだけに絞ってある:
/// 1. 撮影した**元データ**（EXIF 付き）を写真ライブラリへ保存する
/// 2. 投稿パイプラインへ渡す `UIImage` と `ExternalEditInfo` を作る
/// 3. 計装イベントを `LoggingService` ファサードへ流す
enum CameraCaptureService {

    // MARK: - 写真ライブラリ保存

    /// 撮影データを写真ライブラリへ追加する。
    ///
    /// 権限は「追加のみ（`.addOnly`）」で要求する（読み取り権限は不要なので求めない）。
    /// ⚠️ **拒否・失敗しても投稿は止めない**。戻り値 false を計装に載せるだけにする。
    /// - Parameter photoData: `AVCapturePhoto.fileDataRepresentation()` の元データ
    /// - Returns: 保存できたら true
    static func saveToPhotoLibrary(photoData: Data) async -> Bool {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            return false
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // 元データをそのまま資産にするので、再エンコードは挟まない（EXIF が落ちない）。
                request.addResource(with: .photo, data: photoData, options: options)
            }
            return true
        } catch {
            print("❌ 写真ライブラリへの保存に失敗: \(error.localizedDescription)")
            return false
        }
    }

    /// 「追加のみ」権限を要求する（未決定のときだけシステムのプロンプトが出る）。
    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - 投稿パイプラインへの変換

    /// 撮影データから、投稿パイプラインへ渡せる `UIImage` を作る。
    ///
    /// ⚠️ **向きを `.up` に焼き込む**のが肝。`AVCaptureDevice.RotationCoordinator` を使うと
    ///    `UIImage(data:)` は `.right` 等の `imageOrientation` 付きで届くが、
    ///    既存の `ImageService.resizeImage` は向きを焼き込まず、空マスクは `.up` 前提で動く
    ///    （過去に `.right` の縦撮りで事故が起きている）。ここで正規化して以降の前提を揃える。
    /// - Parameter photoData: 撮影の元データ
    /// - Returns: 向きを焼き込んだ画像。デコードできない場合は nil
    static func makeImage(from photoData: Data) -> UIImage? {
        guard let image = UIImage(data: photoData) else { return nil }
        return bakeOrientation(image)
    }

    /// `imageOrientation` をピクセルに焼き込んで `.up` の画像にする。
    /// 既に `.up` の場合はそのまま返す（無駄な再描画をしない）。
    static func bakeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        // scale は元画像に合わせる（ここで解像度を変えない。リサイズは既存パイプラインの仕事）。
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            // draw(in:) は imageOrientation を反映して描くので、描いた結果は常に .up になる。
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// 撮影結果から `ExternalEditInfo` を作る。
    ///
    /// `creationDate` にはシャッター時刻を入れる。`exifCapturedAt` は `capture.metadata`
    /// （`AVCapturePhoto.metadata`。`CGImageSourceCopyPropertiesAtIndex` と同じ辞書構造で
    /// `{Exif}` サブ辞書を含む）から、写真ピッカー経路と同じ `ImageService.parseEXIFData`
    /// で解釈する。EXIF が無ければ nil のままで、`ExternalEditInfo.resolvedCapturedAt` が
    /// `creationDate`（シャッター時刻）に補完する。
    static func makeExternalEditInfo(from capture: SkyCameraCapture) -> ExternalEditInfo {
        ExternalEditInfo(
            hasAdjustments: false,
            creationDate: capture.shutterDate,
            exifCapturedAt: ImageService.parseEXIFData(from: capture.metadata).capturedAt
        )
    }

    // MARK: - 計装

    /// `SkyCameraEvent`（パッケージ側のイベント）を計装のイベント名・属性へ写像する。
    /// 純関数にしてあるのでテストから直接確認できる。
    static func analyticsPayload(for event: SkyCameraEvent) -> (name: String, parameters: [String: Any]) {
        switch event {
        case .opened(let authorization):
            return ("camera_opened", ["authorization": authorization.rawValue])
        case .failed(let reason):
            return ("camera_error", ["reason": reason])
        }
    }

    /// 撮影 1 回分の計装属性（PII なし・Bool と数値のみ）。
    static func captureParameters(capture: SkyCameraCapture, savedToLibrary: Bool) -> [String: Any] {
        [
            "grid_enabled": capture.gridEnabled,
            "horizon_enabled": capture.horizonEnabled,
            "ae_af_locked": capture.aeAfLocked,
            "is_level": capture.isLevel,
            // 傾きは整数の度数まで丸める（小数は分析の役に立たず値の種類だけ増える）。
            "roll_deg": Int((capture.rollDegrees ?? 0).rounded()),
            "saved_to_library": savedToLibrary,
            "deferred_start": capture.usedDeferredStart,
            // 空優先 AE（白飛び防止）が ON だったか。
            "sky_priority_enabled": capture.skyPriorityEnabled,
            // ⭐️ 実際に露出を下げたか。ON でもこれが false なら「出番が無かった」だけで、
            //    機能が壊れているのとは意味が違う。両方を残さないと切り分けられない。
            "sky_priority_engaged": capture.exposureBiasEV < 0,
            // ⭐️ 測光が一度でも成立したか。ON かつ false なら「出番が無かった」ではなく
            //    **動いていない**。この属性が無いと、恒久的な故障が
            //    「たまたま下げる必要が無かった撮影」に紛れて永遠に気づけない。
            // ⭐️ どのレンズで空を撮ったか。0.1 刻みへ丸める。
            "zoom": Double((capture.zoomDisplayed * 10).rounded()) / 10,
            // ⭐️ 撮影解像度。指定を忘れると端末の最小で撮られるので、本番で効いているか見る。
            "photo_mp": capture.photoMegapixels,
            "sky_priority_measured": capture.skyPriorityMeasured,
            // ⭐️ 閾値較正のための実測値。効かなかったときに
            //    「閾値が高すぎる」のか「本当に飛んでいない」のかを区別する。
            //    率は 0.1% 刻みへ丸める（生値だと値の種類だけ増えて集計できない）。
            "sky_clipped_pct": Double((capture.skyClippedFraction * 1000).rounded()) / 10,
            "sky_peak_luma": capture.skyPeakLuma,
            // ⭐️ 補正**前**の最大値。空優先AEは飛びを見つけると消しにかかるので、
            //    撮影時点の値だけでは「効いた結果の静けさ」と「元々静か」を区別できない。
            "sky_max_clipped_pct": Double((capture.skyMaxClippedFraction * 1000).rounded()) / 10,
            "sky_max_peak_luma": capture.skyMaxPeakLuma,
            // 補正量は 0.1 EV 刻みに丸める（小数をそのまま送ると値の種類だけ増えて集計できない）。
            "exposure_bias_ev": Double((capture.exposureBiasEV * 10).rounded()) / 10,
        ]
    }

    /// パッケージから届いたイベントをそのまま計装へ流す。
    static func log(event: SkyCameraEvent) {
        let payload = analyticsPayload(for: event)
        LoggingService.shared.logEvent(payload.name, parameters: payload.parameters)
    }

    // MARK: - まとめ役

    /// 撮影 → 写真ライブラリ保存 → 計装 → 投稿パイプライン用の素材づくり、を 1 本にしたもの。
    /// - Returns: 投稿パイプラインへ渡す画像と外部編集情報。画像を作れなかった場合は nil
    static func process(capture: SkyCameraCapture) async -> (image: UIImage, info: ExternalEditInfo)? {
        let savedToLibrary = await saveToPhotoLibrary(photoData: capture.photoData)
        LoggingService.shared.logEvent(
            "camera_capture",
            parameters: captureParameters(capture: capture, savedToLibrary: savedToLibrary)
        )
        guard let image = makeImage(from: capture.photoData) else {
            LoggingService.shared.logEvent("camera_error", parameters: ["reason": "decode_failed"])
            return nil
        }
        return (image: image, info: makeExternalEditInfo(from: capture))
    }
}
