// ⭐️ 空カメラの公開データ型（撮影結果・計装イベント・利用可否）
import AVFoundation
import Foundation
import ImageIO

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
    /// RAW 撮影時は**現像済みの方**が入る（編集パイプラインは DNG を扱えないため）。
    public let photoData: Data

    /// RAW 撮影時の DNG データ。RAW を選んでいないときは nil。
    /// 写真ライブラリにはこちらを残す（標準カメラと同じ扱い）。
    public let rawPhotoData: Data?

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

    /// 撮影時に空優先 AE（白飛び防止）が ON だったか（計装用）
    public let skyPriorityEnabled: Bool

    /// 撮影時に実際にかかっていた露出補正値（EV。計装用）。
    /// 0 なら「ON だが下げる必要が無かった」＝機能が効いていないのではなく出番が無かった、と読む。
    public let exposureBiasEV: Float

    /// 直近に測れた白飛び率（0〜1。較正用）。
    public let skyClippedFraction: Double

    /// 直近に測れたフレームの最大輝度（0〜255。較正用）。
    /// ⭐️ 閾値（既定 250）に届く高さがそもそも来ているかを見るための値。
    ///    これが常に 240 前後なら、飛んでいないのではなく**閾値が高すぎる**。
    public let skyPeakLuma: Int

    /// 画面を開いてからの白飛び率の最大値（較正用）。
    public let skyMaxClippedFraction: Double

    /// 画面を開いてからの最大輝度（較正用）。
    /// ⭐️ 補正**前**にどこまで明るかったかを残す。撮影時点の値は露出を下げたあとの姿なので、
    ///    これが無いと「効いたから静かなのか、最初から静かなのか」を後から区別できない。
    public let skyMaxPeakLuma: Int

    /// デバイスが全フォーマットを通じて出せる最大解像度（MP。診断用）。
    /// ⭐️ `availableMegapixels` が小さいとき、デバイスの限界なのか
    ///    いま使っているフォーマット（＝仮想デバイスの都合）の限界なのかを切り分ける。
    public let deviceMaxMegapixels: Int

    /// 単眼の広角デバイスが出せる最大解像度（MP。診断用）。
    /// ⭐️ 「レンズ切替を捨てて単眼へ移れば 48MP が取れるのか」を、
    ///    大工事の前に数字で確かめるための値。
    public let wideCameraMaxMegapixels: Int

    /// 撮影時の記録形式（計装用）。
    public let photoFormat: SkyCameraPhotoFormat

    /// 撮影時の解像度（百万画素。計装用）。
    /// ⭐️ 「指定を忘れて最小で撮っていた」が本番で直ったかを確かめるための値。
    public let photoMegapixels: Int

    /// その端末で選べた解像度の一覧（MP をカンマ区切り。例: "12,49"。計装用）。
    /// ⭐️ 「選択肢が出ない」ときに、端末が本当に 1 つしか返していないのか
    ///    読み取り位置を間違えているのかを、本番データで切り分けるため。
    public let availableMegapixels: String

    /// 撮影時のズーム倍率（表示倍率。計装用）。
    /// ⭐️ 「空を撮るとき人はどのレンズを選ぶか」を測る。超広角がよく使われるなら、
    ///    OpenCV の広角合成（IPA +1.7MB）を将来外せるかの判断材料になる。
    public let zoomDisplayed: Double

    /// 測光が一度でも成立したか（計装用）。
    /// `skyPriorityEnabled` が true なのにこれが false なら、出番が無かったのではなく
    /// **機能が動いていない**（測光出力を挿せなかった等）。この 2 つを混ぜてはいけない。
    public let skyPriorityMeasured: Bool

    /// シャッターを切った時刻。EXIF に撮影日時が無い場合の代替として本体が使う。
    public let shutterDate: Date

    public init(
        photoData: Data,
        rawPhotoData: Data?,
        metadata: [String: Any],
        gridEnabled: Bool,
        horizonEnabled: Bool,
        aeAfLocked: Bool,
        isLevel: Bool,
        rollDegrees: Double?,
        usedDeferredStart: Bool,
        skyPriorityEnabled: Bool,
        exposureBiasEV: Float,
        zoomDisplayed: Double,
        photoMegapixels: Int,
        availableMegapixels: String,
        photoFormat: SkyCameraPhotoFormat,
        deviceMaxMegapixels: Int,
        wideCameraMaxMegapixels: Int,
        skyPriorityMeasured: Bool,
        skyClippedFraction: Double,
        skyPeakLuma: Int,
        skyMaxClippedFraction: Double,
        skyMaxPeakLuma: Int,
        shutterDate: Date
    ) {
        self.photoData = photoData
        self.rawPhotoData = rawPhotoData
        self.metadata = metadata
        self.gridEnabled = gridEnabled
        self.horizonEnabled = horizonEnabled
        self.aeAfLocked = aeAfLocked
        self.isLevel = isLevel
        self.rollDegrees = rollDegrees
        self.usedDeferredStart = usedDeferredStart
        self.skyPriorityEnabled = skyPriorityEnabled
        self.exposureBiasEV = exposureBiasEV
        self.zoomDisplayed = zoomDisplayed
        self.photoMegapixels = photoMegapixels
        self.availableMegapixels = availableMegapixels
        self.photoFormat = photoFormat
        self.deviceMaxMegapixels = deviceMaxMegapixels
        self.wideCameraMaxMegapixels = wideCameraMaxMegapixels
        self.skyPriorityMeasured = skyPriorityMeasured
        self.skyClippedFraction = skyClippedFraction
        self.skyPeakLuma = skyPeakLuma
        self.skyMaxClippedFraction = skyMaxClippedFraction
        self.skyMaxPeakLuma = skyMaxPeakLuma
        self.shutterDate = shutterDate
    }
}

/// 空優先 AE の現況スナップショット（計装・較正用）。
public struct SkyPriorityStatus: Sendable {
    /// いまかかっている露出補正値（EV）。
    public let bias: Float
    /// 測光が一度でも成立したか。
    public let hasMeasured: Bool
    /// 直近に測れた白飛び率（0〜1）。
    public let clippedFraction: Double
    /// 直近に測れたフレームの最大輝度（0〜255）。
    public let peakLuma: UInt8
    /// 画面を開いてからの白飛び率の最大値（0〜1）。
    public let maxClippedFraction: Double
    /// 画面を開いてからの最大輝度（0〜255）。
    public let maxPeakLuma: UInt8
}

/// 記録形式。
public enum SkyCameraPhotoFormat: String, CaseIterable, Sendable {
    /// 既定。容量が小さく EXIF もそのまま載る。
    case heic
    /// 他アプリへ渡すときの逃げ道。
    case jpeg
    /// Apple ProRAW（Linear DNG）。編集の余地が大きいかわりに容量も大きい。
    /// ⚠️ 1 回の撮影で **DNG と現像済み画像の 2 枚**が届く。
    ///    DNG は写真ライブラリへ、現像済みの方を編集画面へ渡す。
    case raw

    /// バッジに出す短い文字。
    public var label: String {
        switch self {
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        case .raw: return "RAW"
        }
    }

    /// メニューに出す説明つきの文字。
    public var menuTitle: String {
        switch self {
        case .heic: return "HEIC（容量が小さい）"
        case .jpeg: return "JPEG（他アプリで開きやすい）"
        case .raw: return "RAW（編集の余地が大きい・容量が大きい）"
        }
    }
}

/// 撮影解像度。
///
/// ⚠️ **既定のままだと端末が出せる最小値で撮ってしまう**。
///    `AVCapturePhotoSettings.maxPhotoDimensions` の既定は
///    「supportedMaxPhotoDimensions の最小」と SDK ヘッダーに明記されている。
///    4800 万画素センサーを積んだ端末でも、指定しなければ最小のまま。
public struct SkyCameraPhotoResolution: Equatable, Hashable, Sendable {

    public let width: Int32
    public let height: Int32

    /// この解像度を出すのに**単眼の広角デバイス**が要るか。
    /// ⚠️ true のとき、3眼をまとめた仮想デバイスから離れることになるので
    ///    **超広角（0.5x）などのレンズ切替が使えなくなる**。
    ///    黙って機能が消えるのが一番よくないので、UI で必ず明示する。
    public let requiresSingleLens: Bool

    public init(width: Int32, height: Int32, requiresSingleLens: Bool = false) {
        self.width = width
        self.height = height
        self.requiresSingleLens = requiresSingleLens
    }

    /// 百万画素（MP）。
    ///
    /// ⚠️ **四捨五入ではなく切り捨て**にすること。センサーの実画素数は
    ///    宣伝上の値より必ず少し多いので、四捨五入すると1つ大きい数字になる。
    ///      4032×3024 = 12.19MP → 12MP（Apple 表記）
    ///      5712×4284 = 24.47MP → 24MP
    ///      8064×6048 = 48.77MP → 48MP（四捨五入すると 49 になってしまう）
    public var megapixels: Int {
        Int(Double(width) * Double(height) / 1_000_000)
    }

    /// ボタンに出す文字（例: "12MP"）。
    public var label: String { "\(megapixels)MP" }

    /// メニューに出す文字。レンズ切替を失うものにはその旨を添える。
    public var menuTitle: String {
        requiresSingleLens ? "\(label)（メインカメラのみ）" : label
    }

    /// 撮れた 1 枚の EXIF から**実際に届いた寸法**を読む。
    ///
    /// ⭐️ 要求値（設定で選んだ解像度）と実測値は別物。ズームやレンズの都合で
    ///    要求どおり届かないことがあるので、計装には必ずこちらを使う。
    ///    露出補正で EXIF を正としているのと同じ考え方。
    public static func delivered(fromMetadata metadata: [String: Any]) -> SkyCameraPhotoResolution? {
        guard let width = metadata[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = metadata[kCGImagePropertyPixelHeight as String] as? NSNumber else {
            return nil
        }
        return SkyCameraPhotoResolution(width: width.int32Value, height: height.int32Value)
    }

    /// ⚠️ 24MP (5712×4284) は**遅延写真配信（deferred photo delivery）を有効にしたときだけ**
    ///    24MP として提供される、と SDK ヘッダーに明記されている。
    ///    遅延配信では撮影直後に届くのが本体ではなく代理（proxy）になり、
    ///    「撮る → データを受け取る → その場で編集へ」という今の流れと噛み合わない。
    ///    指定しても 24MP にならないので、選べる一覧から外す。
    public var requiresDeferredDelivery: Bool {
        width == 5712 && height == 4284
    }
}

/// フラッシュの動作。
public enum SkyCameraFlashMode: String, CaseIterable, Sendable {
    /// 光らせない（空の撮影では基本これ。空にフラッシュは届かない）。
    case off
    /// 暗ければ自動で光る。
    case auto
    /// 必ず光る。
    case on

    var avFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    /// 上部バーに出すアイコン（SF Symbols）。
    public var systemImageName: String {
        switch self {
        case .off: return "bolt.slash"
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        }
    }

    /// 読み上げ・表示用の名前。
    public var label: String {
        switch self {
        case .off: return "フラッシュ オフ"
        case .auto: return "フラッシュ 自動"
        case .on: return "フラッシュ オン"
        }
    }

    /// 押すたびに off → auto → on → off と巡回する。
    public var next: SkyCameraFlashMode {
        switch self {
        case .off: return .auto
        case .auto: return .on
        case .on: return .off
        }
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
    /// カメラ権限が拒否・制限されている（アプリからは戻せないので設定アプリへ案内する）
    case permissionDenied
    /// セッションの構成に失敗した
    case configurationFailed
    /// セッションが動いていない状態で撮影しようとした
    case sessionNotRunning
    /// 撮影に失敗した（下位のエラーを添える）
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "カメラを利用できません。"
        case .permissionDenied:
            return "設定アプリの「そらもよう」からカメラへのアクセスを許可してください。"
        case .configurationFailed:
            return "カメラの準備に失敗しました。"
        case .sessionNotRunning:
            return "カメラを準備しています。少し待ってからもう一度お試しください。"
        case .captureFailed(let reason):
            return "撮影に失敗しました（\(reason)）。"
        }
    }

    /// 計装に載せる短い理由（PII なし）
    public var reasonCode: String {
        switch self {
        case .deviceUnavailable:   return "device_unavailable"
        case .permissionDenied:    return "permission_denied"
        case .configurationFailed: return "configuration_failed"
        case .sessionNotRunning:   return "session_not_running"
        case .captureFailed:       return "capture_failed"
        }
    }

    /// 権限が原因か（画面側で「設定を開く」導線を出すかの判断に使う）。
    public var isPermissionDenied: Bool {
        if case .permissionDenied = self { return true }
        return false
    }

    /// 一時的な失敗か（＝画面を開き直さなくても、次の操作でやり直せる）。
    /// 中断（着信・他アプリのカメラ利用）が明ければセッションは自動で戻るため、
    /// ここで撮影不可にしてしまうと復帰してもシャッターが返ってこない。
    public var isTransient: Bool {
        if case .sessionNotRunning = self { return true }
        return false
    }
}


/// レンズまわりのいまの状態。付け替えで変わったときだけ UI へ流す。
///
/// ⭐️ **なぜ 3 つをまとめて 1 つの型にするか**: 倍率・実際の解像度・どのデバイスか、は
///    必ず同時に変わる。別々に流すと「バッジは 48 のままなのに実体は 12MP」という
///    中途半端な瞬間が生まれ、ユーザーには嘘の表示に見える。
public struct SkyCameraLensState: Equatable, Sendable {

    /// いま合わせている表示倍率。
    public let displayedZoom: CGFloat

    /// いま実際に撮れる解像度（希望より下がっていることがある）。
    public let effectiveResolution: SkyCameraPhotoResolution?

    /// 単眼の広角デバイスを掴んでいるか（＝48MP が活きている状態か）。
    public let isUsingSingleWideDevice: Bool

    public init(displayedZoom: CGFloat,
                effectiveResolution: SkyCameraPhotoResolution?,
                isUsingSingleWideDevice: Bool) {
        self.displayedZoom = displayedZoom
        self.effectiveResolution = effectiveResolution
        self.isUsingSingleWideDevice = isUsingSingleWideDevice
    }
}
