// ⭐️ 空カメラのセッション制御（AVCaptureSession を専用シリアルキューに閉じ込める）
import AVFoundation
import Foundation
import UIKit

/// `AVCaptureSession` の構成・開始・停止・撮影を一手に引き受けるクラス。
///
/// **並行性の約束**: セッションと出力に触る可変状態はすべて `sessionQueue`（専用シリアルキュー）
/// の上でだけ読み書きする。`session` だけは `AVCaptureVideoPreviewLayer` に渡すためにメインから
/// 読むが、`AVCaptureSession` 自身がスレッドセーフに設計されている（Apple のサンプルも同じ扱い）。
/// この 2 点により実質的にデータ競合が起きないため `@unchecked Sendable` を付けている。
public final class CameraSessionController: NSObject, @unchecked Sendable {

    // MARK: - Properties

    /// プレビュー層へ渡すセッション本体。
    public let session = AVCaptureSession()

    /// セッション操作専用のシリアルキュー（メインスレッドを止めないため）。
    private let sessionQueue = DispatchQueue(label: "com.soramoyou.skycamera.session")

    /// 静止画出力。
    private let photoOutput = AVCapturePhotoOutput()

    /// 背面広角カメラ。構成後に確定する（sessionQueue 上でのみ触る）。
    private var videoDevice: AVCaptureDevice?

    /// iOS 17+ の回転コーディネータ。iOS 16 では nil のまま（型を隠すため Any で保持）。
    private var rotationCoordinatorStorage: Any?

    /// Deferred Start（iOS 26+）を実際に有効化できたか（計装用）。
    private var didEnableDeferredStart = false

    /// 撮影中のデリゲート。撮影が終わるまで ARC に回収されないよう保持する（sessionQueue 上でのみ触る）。
    private var captureDelegates: [Int64: PhotoCaptureDelegate] = [:]

    /// 一度でも構成に成功したか（二重構成の防止）。
    private var isConfigured = false

    /// アプリがバックグラウンドへ行く直前に走っていたか（復帰時に再開すべきかの判断に使う）。
    private var wasRunningBeforeInterruption = false

    // MARK: - Lifecycle

    public override init() {
        super.init()
        registerNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    /// セッションを構成する（背面広角 + 静止画出力）。既に構成済みなら何もしない。
    /// - Throws: 背面カメラが無い／入出力を追加できない場合
    public func configure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureOnSessionQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// sessionQueue 上で実行される構成本体。
    private func configureOnSessionQueue() throws {
        guard !isConfigured else { return }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw SkyCameraError.deviceUnavailable
        }

        session.beginConfiguration()
        // beginConfiguration と commitConfiguration は必ず対で呼ぶ（途中 throw でも取りこぼさない）。
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw SkyCameraError.configurationFailed
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            throw SkyCameraError.configurationFailed
        }
        session.addOutput(photoOutput)

        // シャッターラグと画質のバランス（.quality だと空の連続撮影で待たされる）。
        photoOutput.maxPhotoQualityPrioritization = .balanced

        // Deferred Start（iOS 26+）: セッション開始直後はプレビューを優先し、
        // 静止画出力の起動を後回しにして「開いてすぐ見える」体感を上げる。
        if #available(iOS 26, *) {
            session.automaticallyRunsDeferredStart = true
            // ⚠️ 非対応の出力に `isDeferredStartEnabled = true` を設定すると
            //    NSInvalidArgumentException で即クラッシュする。必ず対応可否を見てから設定する。
            if photoOutput.isDeferredStartSupported {
                photoOutput.isDeferredStartEnabled = true
                didEnableDeferredStart = true
            }
        }

        videoDevice = device
        if #available(iOS 17.0, *) {
            // プレビュー層は後から生成されるため、ここでは preview なしで作る
            //（撮影向きの算出には preview は不要）。
            rotationCoordinatorStorage = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        }
        isConfigured = true
    }

    // MARK: - Running

    /// セッションを開始する（すでに動いていれば何もしない）。
    public func start() {
        sessionQueue.async {
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// セッションを停止する。
    public func stop() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// Deferred Start を実際に有効化できたか（計装用）。
    public func usedDeferredStart() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { continuation.resume(returning: self.didEnableDeferredStart) }
        }
    }

    // MARK: - Capture

    /// 1 枚撮影する。
    /// - Parameter fallbackOrientation: iOS 16 で使う撮影向き（重力から求めたもの）。
    ///   iOS 17+ では `RotationCoordinator` の値を優先するため無視される。
    /// - Returns: 撮影データとメタデータ
    public func capturePhoto(
        fallbackOrientation: AVCaptureVideoOrientation
    ) async throws -> (data: Data, metadata: [String: Any]) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, metadata: [String: Any]), Error>) in
            sessionQueue.async {
                guard self.isConfigured else {
                    continuation.resume(throwing: SkyCameraError.configurationFailed)
                    return
                }

                // 撮影直前にコネクションの向きを決める（画面の向きロック中でも正しく立てるため）。
                if let connection = self.photoOutput.connection(with: .video) {
                    self.applyRotation(to: connection, fallbackOrientation: fallbackOrientation)
                }

                let settings = self.makePhotoSettings()
                let delegate = PhotoCaptureDelegate { [weak self] result in
                    guard let self else { return }
                    // 完了通知は任意のキューで来るため、辞書操作は sessionQueue に寄せる。
                    self.sessionQueue.async {
                        self.captureDelegates[settings.uniqueID] = nil
                    }
                    continuation.resume(with: result)
                }
                self.captureDelegates[settings.uniqueID] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// 撮影設定。HEIC が使えるなら HEIC（容量が小さく EXIF もそのまま載る）。
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .balanced
        return settings
    }

    /// 撮影コネクションに向きを与える。iOS 17+ は水平基準の回転角、iOS 16 は重力由来の向き。
    private func applyRotation(to connection: AVCaptureConnection, fallbackOrientation: AVCaptureVideoOrientation) {
        if #available(iOS 17.0, *),
           let coordinator = rotationCoordinatorStorage as? AVCaptureDevice.RotationCoordinator {
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                return
            }
        }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = fallbackOrientation
        }
    }

    // MARK: - Focus / Exposure

    /// フォーカス・露出の対象点を設定する。
    /// - Parameters:
    ///   - devicePoint: `captureDevicePointConverted(fromLayerPoint:)` で変換済みの点
    ///   - locked: true なら AE/AF をロック、false なら 1 回だけ合わせて自動に戻す
    public func focus(at devicePoint: CGPoint, locked: Bool) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                // ロック指定でもまずは 1 回合わせる（合焦後に .locked へ落とす）。
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }

                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.autoExpose) {
                    device.exposureMode = .autoExpose
                }

                // ロック時は「その点で合わせたあと固定」。合焦の完了を待ってから固定へ移す。
                if locked {
                    self.lockAfterConverging(device: device)
                } else {
                    // 被写体が変わったら自動で追従させる（標準カメラと同じ挙動）。
                    device.isSubjectAreaChangeMonitoringEnabled = true
                }
            } catch {
                // 設定できない端末・状態でも撮影自体は続けられるので、ここでは無視する。
            }
        }
    }

    /// AE/AF のロックを解除して自動追従へ戻す。
    public func unlockFocusAndExposure() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
            } catch {
                // 解除できなくても致命的ではない（次回のタップでやり直せる）。
            }
        }
    }

    /// 合焦・測光が落ち着いた頃合いで `.locked` に落とす。
    /// KVO を張るほどの価値は無いので、実用的な待ち時間（0.5 秒）で十分とする。
    private func lockAfterConverging(device: AVCaptureDevice) {
        sessionQueue.asyncAfter(deadline: .now() + 0.5) {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusModeSupported(.locked) {
                    device.focusMode = .locked
                }
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                device.isSubjectAreaChangeMonitoringEnabled = false
            } catch {
                // ロックできない状態（別アプリがカメラを掴んだ等）は諦めて自動のままにする。
            }
        }
    }

    // MARK: - Interruption / Background

    /// 中断（着信・他アプリのカメラ利用）とバックグラウンド遷移を監視する。
    private func registerNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleSessionInterrupted),
            name: .AVCaptureSessionWasInterrupted,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleSessionInterruptionEnded),
            name: .AVCaptureSessionInterruptionEnded,
            object: session
        )
        center.addObserver(
            self,
            selector: #selector(handleDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleSessionInterrupted() {
        sessionQueue.async { self.wasRunningBeforeInterruption = true }
    }

    @objc private func handleSessionInterruptionEnded() {
        sessionQueue.async {
            guard self.wasRunningBeforeInterruption else { return }
            self.wasRunningBeforeInterruption = false
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    @objc private func handleDidEnterBackground() {
        sessionQueue.async {
            self.wasRunningBeforeInterruption = self.session.isRunning
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    @objc private func handleWillEnterForeground() {
        sessionQueue.async {
            guard self.wasRunningBeforeInterruption else { return }
            self.wasRunningBeforeInterruption = false
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }
}

// MARK: - PhotoCaptureDelegate

/// 1 回の撮影に 1 個だけ使う使い捨てデリゲート。
/// `AVCapturePhotoOutput` はデリゲートを弱参照で持たないため、呼び出し側で寿命を管理する。
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let completion: (Result<(data: Data, metadata: [String: Any]), Error>) -> Void

    /// 二重呼び出し防止（エラーと完了が両方来るケースがある）。
    private var hasCompleted = false

    init(completion: @escaping (Result<(data: Data, metadata: [String: Any]), Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard !hasCompleted else { return }
        hasCompleted = true

        if let error {
            completion(.failure(SkyCameraError.captureFailed(error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(SkyCameraError.captureFailed("データを取り出せませんでした")))
            return
        }
        completion(.success((data: data, metadata: photo.metadata)))
    }
}
