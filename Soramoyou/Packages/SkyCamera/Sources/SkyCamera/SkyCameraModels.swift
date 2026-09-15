// ⭐️ 空カメラの公開データ型（撮影結果・計装イベント・利用可否）
import AVFoundation
import Foundation

// MARK: - 権限状態

/// カメラ権限の状態。計装の属性値としてそのまま使えるよう snake_case の文字列を持つ。
public enum SkyCameraAuthorization: String {
    case authorized
    case denied
    case notDetermined = "not_determined"
    case restricted

    /// `AVAuthorizationStatus` からの変換。将来ケースが増えても `denied` に倒して安全側に寄せる。
    public init(status: AVAuthorizationStatus) {
        switch status {
        case .authorized:    self = .authorized
        case .denied:        self = .denied
        case .notDetermined: self = .notDetermined
        case .restricted:    self = .restricted
        @unknown default:    self = .denied
        }
    }
}

// MARK: - 撮影結果

/// 1 回の撮影で得られたもの一式。
/// `photoData` は EXIF を含む**元データ**（写真ライブラリへはこれをそのまま保存する）。
public struct SkyCameraCapture {

    /// 撮影データ（HEIC もしくは JPEG。`AVCapturePhoto.fileDataRepresentation()`）
    public let photoData: Data

    /// 撮影メタデータ（`AVCapturePhoto.metadata`。`{Exif}` 等を含む）
    public let metadata: [String: Any]

    /// 撮影時にグリッドを表示していたか（計装用）
    public let gridEnabled: Bool

    /// 撮影時に水平線ガイドを表示していたか（計装用）
    public let horizonEnabled: Bool

    /// 撮影時に AE/AF ロック中だったか（計装用）
    public let aeAfLocked: Bool

    /// 撮影時に水平だったか（計装用）
    public let isLevel: Bool

    /// 撮影時の傾き（度）。真上を向いていて計測不能なら nil。
    public let rollDegrees: Double?

    /// Deferred Start（iOS 26+）が有効だったか（計装用・起動体感の分析）
    public let usedDeferredStart: Bool

    /// シャッターを切った時刻。EXIF に撮影日時が無い場合の代替として本体が使う。
    public let shutterDate: Date

    public init(
        photoData: Data,
        metadata: [String: Any],
        gridEnabled: Bool,
        horizonEnabled: Bool,
        aeAfLocked: Bool,
        isLevel: Bool,
        rollDegrees: Double?,
        usedDeferredStart: Bool,
        shutterDate: Date
    ) {
        self.photoData = photoData
        self.metadata = metadata
        self.gridEnabled = gridEnabled
        self.horizonEnabled = horizonEnabled
        self.aeAfLocked = aeAfLocked
        self.isLevel = isLevel
        self.rollDegrees = rollDegrees
        self.usedDeferredStart = usedDeferredStart
        self.shutterDate = shutterDate
    }
}

// MARK: - 計装イベント

/// 画面内で起きたことを本体へ知らせるためのイベント。
/// このパッケージは計装基盤（Firebase / PostHog）に依存しないので、送信は本体側で行う。
public enum SkyCameraEvent {
    /// カメラ画面を開いた（そのときの権限状態つき）。「開いたのに撮らない率」の分母になる。
    case opened(authorization: SkyCameraAuthorization)
    /// セッション構成・撮影に失敗した（クラッシュしない不具合をテレメトリで拾うため）
    case failed(reason: String)
}

// MARK: - 利用可否

/// 空カメラが使える端末かどうかの判定。
public enum SkyCameraAvailability {

    /// 背面カメラの有無。端末構成は実行中に変わらないので一度だけ調べる
    ///（SwiftUI の body から毎回デバイス探索を走らせないため。static let は遅延かつスレッドセーフ）。
    private static let hasBackCamera: Bool =
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil

    /// 背面カメラが存在するか。シミュレータでは false になるので導線ごと隠せる。
    public static var isAvailable: Bool { hasBackCamera }

    /// 現在のカメラ権限の状態（プロンプトは出さない）。
    public static var authorization: SkyCameraAuthorization {
        SkyCameraAuthorization(status: AVCaptureDevice.authorizationStatus(for: .video))
    }

    /// カメラ権限をリクエストする（未決定のときだけシステムのプロンプトが出る）。
    public static func requestAuthorization() async -> SkyCameraAuthorization {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }
}

// MARK: - エラー

/// 空カメラのエラー。文言はそのままユーザーに出せる日本語にしてある。
public enum SkyCameraError: LocalizedError {
    /// 背面カメラが見つからない
    case deviceUnavailable
    /// セッションの構成に失敗した
    case configurationFailed
    /// 撮影に失敗した（下位のエラーを添える）
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "カメラを利用できません。"
        case .configurationFailed:
            return "カメラの準備に失敗しました。"
        case .captureFailed(let reason):
            return "撮影に失敗しました（\(reason)）。"
        }
    }

    /// 計装に載せる短い理由（PII なし）
    public var reasonCode: String {
        switch self {
        case .deviceUnavailable:  return "device_unavailable"
        case .configurationFailed: return "configuration_failed"
        case .captureFailed:      return "capture_failed"
        }
    }
}
