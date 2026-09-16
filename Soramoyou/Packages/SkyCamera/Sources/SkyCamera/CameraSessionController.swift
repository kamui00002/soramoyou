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

    /// セッションを動かしておきたいか（＝カメラ画面が開いている）。
    /// ⚠️ 「動かしたいか」と「なぜ今止まっているか」は必ず別の変数で持つ。
    ///    1 つのフラグに混ぜると、中断中にバックグラウンドへ行ったときに
    ///    片方の書き手がもう片方の意図を上書きしてしまい、前面へ戻っても再開できなくなる。
    private var isRunningDesired = false

    /// システム都合で中断中か（着信・他アプリのカメラ利用・Control Center など）。
    private var isInterrupted = false

    /// アプリがバックグラウンドにいるか。
    private var isInBackground = false

    /// AE/AF を明示的にロック中か（長押し）。被写体変化で自動へ戻してよいかの判断に使う。
    private var isFocusLocked = false

    /// 空優先 AE（白飛び防止）の測光器。プレビュー映像から白飛び率を実測する。
    private var exposureMeter: SkyExposureMeter?

    /// 空優先 AE をユーザーが ON にしているか（sessionQueue 上でのみ読み書きする）。
    private var isSkyPriorityDesired = false

    /// いま端末へかけている露出補正値（EV）。sessionQueue 上でのみ読み書きする。
    private var appliedExposureBias: Float = 0

    /// 空優先 AE の判定パラメータ。
    private let exposureTuning = SkyPriorityExposure.Tuning.default

    /// プレビュー View（回転の追従に使う）。sessionQueue 上でのみ読み書きする。
    /// ⚠️ **weak で持つ**。View は `onTap` クロージャ経由で ViewModel → 本コントローラを
    ///    強参照しているので、こちらが強参照すると循環参照になる。
    private weak var previewView: CameraPreviewUIView?

    /// プレビュー回転角の監視（iOS 17+）。sessionQueue 上で読み書きする（deinit を除く）。
    private var rotationObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    public override init() {
        super.init()
        registerNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // KVO は invalidate() がどのスレッドからでも安全なので deinit で解除してよい。
        rotationObservation?.invalidate()
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

        // 空優先 AE の測光用出力。プレビューと同じ映像を低頻度で読んで白飛び率を測る。
        // ⚠️ `prepare()` は **addOutput の後**に呼ぶこと。
        //    `availableVideoPixelFormatTypes` はセッションに繋がって初めて埋まるため、
        //    先に呼ぶと一覧が空になり、輝度の Range 判定を取り違える。
        // ⚠️ Deferred Start には**あえて乗せない**。測光を後回しにすると
        //    「開いた直後の 1 枚」が白飛びから守られないため。
        let meter = SkyExposureMeter(clipThreshold: exposureTuning.clipThreshold) { [weak self] fraction in
            guard let self else { return }
            self.sessionQueue.async { self.applyMeasuredClippingOnSessionQueue(fraction) }
        }
        if session.canAddOutput(meter.output) {
            session.addOutput(meter.output)
            meter.prepare()
            meter.setEnabled(isSkyPriorityDesired)
            exposureMeter = meter
        }

        videoDevice = device

        // タップ AF/AE は「1 回合わせたら止まる」一発モード（.autoFocus / .autoExpose）なので、
        // 被写体が変わったタイミングで自動追従へ戻してやる必要がある。
        // ⚠️ これを購読しないと `isSubjectAreaChangeMonitoringEnabled` が名前倒れになり、
        //    通常タップが実質 AE/AF ロックとして振る舞う（長押しロックと区別が付かなくなる）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSubjectAreaDidChange),
            name: .AVCaptureDeviceSubjectAreaDidChange,
            object: device
        )

        // プレビュー層は View 生成時に別経路で届くので、届いていればそれ込みで作る。
        // 撮影向きだけなら層は不要だが、プレビューの回転には層が要る。
        rebuildRotationCoordinatorOnSessionQueue()
        isConfigured = true
    }

    // MARK: - プレビュー層の結びつけ

    /// プレビュー View を受け取り、端末の回転にプレビュー映像を追従させる。
    ///
    /// ⚠️ **これを呼ばないと横持ちでプレビューだけ回らない**。
    ///    `AVCaptureVideoPreviewLayer` は端末回転に自動追従しないため、
    ///    コネクションの回転角を明示的に更新してやる必要がある
    ///    （静止画側は撮影直前に `applyRotation` で立てているので影響を受けない）。
    /// - Parameter view: プレビューを表示している View（メインスレッドから渡すこと）
    public func attachPreview(_ view: CameraPreviewUIView) {
        sessionQueue.async {
            self.previewView = view
            self.rebuildRotationCoordinatorOnSessionQueue()
        }
    }

    /// 回転コーディネータを（プレビュー層が分かっていればそれ込みで）作り直す。
    ///
    /// iOS 17+ は `RotationCoordinator` を KVO で監視してプレビューへ流す。
    /// iOS 16 は `CameraPreviewUIView.layoutSubviews` 側が向きを更新するのでここでは何もしない。
    private func rebuildRotationCoordinatorOnSessionQueue() {
        guard #available(iOS 17.0, *), let device = videoDevice else { return }

        let view = previewView
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: view?.previewLayer)
        rotationCoordinatorStorage = coordinator

        // ⚠️ 回転角は端末を回すたびに変わる。一度読むだけでは追従しないので必ず KVO で監視する。
        rotationObservation?.invalidate()
        guard let view else {
            rotationObservation = nil
            return
        }
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak view] _, change in
            guard let angle = change.newValue else { return }
            // プレビューは UI 層なのでメインスレッドで触る。
            // View はクロージャが直接掴む（sessionQueue 専用プロパティを他スレッドから読まないため）。
            // 角度は View に預けるだけにして、実際の適用（コネクションの有無）は View に任せる
            //（構成前でコネクションが未生成でも、次の layoutSubviews で必ず適用される）。
            DispatchQueue.main.async {
                view?.desiredRotationAngle = angle
            }
        }
    }

    // MARK: - Running

    /// セッションを開始する（すでに動いていれば何もしない）。
    public func start() {
        sessionQueue.async {
            self.isRunningDesired = true
            self.startIfPossibleOnSessionQueue()
        }
    }

    /// セッションを停止する。
    public func stop() {
        sessionQueue.async {
            self.isRunningDesired = false
            // 露出補正は端末（AVCaptureDevice）側に残る設定なので、画面を閉じるときは素へ戻す。
            // 戻さないと「OFF にしたのに暗いまま」「次に開いたら暗い」が起きる。
            if self.appliedExposureBias != 0, let device = self.videoDevice {
                self.setExposureBiasOnSessionQueue(0, device: device)
            }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// 「動かしたい」かつ「止める理由が無い」ときだけ開始する。
    /// 中断中・バックグラウンド中は OS 側が開始を拒むので、条件が揃うまで待つ。
    private func startIfPossibleOnSessionQueue() {
        guard isRunningDesired, !isInterrupted, !isInBackground else { return }
        guard isConfigured, !session.isRunning else { return }
        session.startRunning()
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
                // 停止中のセッションへ撮影を投げるとコールバックが 1 本も返らず、
                // continuation が resume されないまま画面がロックされる。手前で必ず弾く。
                guard self.session.isRunning else {
                    continuation.resume(throwing: SkyCameraError.sessionNotRunning)
                    return
                }

                // 撮影直前にコネクションの向きを決める（画面の向きロック中でも正しく立てるため）。
                if let connection = self.photoOutput.connection(with: .video) {
                    self.applyRotation(to: connection, fallbackOrientation: fallbackOrientation)
                }

                let settings = self.makePhotoSettings()
                let delegate = PhotoCaptureDelegate(
                    completion: { result in
                        continuation.resume(with: result)
                    },
                    // ⚠️ 解放は「必ず最後に来る」`didFinishCaptureFor` からだけ行う。
                    //    先に解放するとバックストップが呼ばれる前にデリゲートが消える
                    //    （`AVCapturePhotoOutput` はデリゲートを保持しないため）。
                    onFinished: { [weak self] in
                        guard let self else { return }
                        // 完了通知は任意のキューで来るため、辞書操作は sessionQueue に寄せる。
                        self.sessionQueue.async {
                            self.captureDelegates[settings.uniqueID] = nil
                        }
                    }
                )
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
            self.isFocusLocked = locked
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

    // MARK: - 空優先 AE（白飛び防止）

    /// 空優先 AE の ON/OFF を切り替える。
    ///
    /// OFF にしたときは必ず補正を 0 EV へ戻す。戻さないと直前の補正が端末に残り、
    /// 「OFF にしたのに暗いまま」という説明のつかない状態になる。
    public func setSkyPriorityExposureEnabled(_ enabled: Bool) {
        sessionQueue.async {
            self.isSkyPriorityDesired = enabled
            self.exposureMeter?.setEnabled(enabled)
            guard !enabled, self.appliedExposureBias != 0, let device = self.videoDevice else { return }
            self.setExposureBiasOnSessionQueue(0, device: device)
        }
    }

    /// いまかかっている露出補正値（EV）。計装用。
    public func currentExposureBias() async -> Float {
        await withCheckedContinuation { (continuation: CheckedContinuation<Float, Never>) in
            sessionQueue.async { continuation.resume(returning: self.appliedExposureBias) }
        }
    }

    /// 測光結果（白飛び率）を受けて露出補正を更新する（sessionQueue 上で呼ぶこと）。
    private func applyMeasuredClippingOnSessionQueue(_ clippedFraction: Double) {
        // ユーザーが長押しで AE をロックしているあいだは意図を尊重して触らない。
        guard isSkyPriorityDesired, !isFocusLocked, let device = videoDevice else { return }
        // ⚠️ `lower...upper` は lower > upper だと実行時トラップする。端末の値を信用せず確かめる。
        let lower = device.minExposureTargetBias
        let upper = device.maxExposureTargetBias
        guard lower <= upper else { return }

        let next = SkyPriorityExposure.decideBias(
            clippedFraction: clippedFraction,
            currentBias: appliedExposureBias,
            tuning: exposureTuning,
            deviceLimits: lower...upper
        )
        guard next != appliedExposureBias else { return }
        setExposureBiasOnSessionQueue(next, device: device)
    }

    /// 露出補正値を端末へ書き込む（sessionQueue 上で呼ぶこと）。
    private func setExposureBiasOnSessionQueue(_ bias: Float, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(bias, completionHandler: nil)
            // 端末への書き込みが成功したときだけ記録する（失敗時に嘘の現在値を持たないため）。
            appliedExposureBias = bias
        } catch {
            // 別アプリがカメラ設定を掴んでいる等。次の測光でやり直せるので握りつぶす。
        }
    }

    /// AE/AF のロックを解除して自動追従へ戻す。
    public func unlockFocusAndExposure() {
        sessionQueue.async {
            self.isFocusLocked = false
            self.returnToContinuousOnSessionQueue(resetPointToCenter: false)
        }
    }

    /// 被写体が変わったら自動追従へ戻す（標準カメラと同じ挙動）。
    /// 長押しで明示的にロック中のときは、ユーザーの意図を尊重して触らない。
    @objc private func handleSubjectAreaDidChange() {
        sessionQueue.async {
            guard !self.isFocusLocked else { return }
            // 被写体が変わった＝それまでの注視点はもう意味が無いので中央基準へ戻す。
            self.returnToContinuousOnSessionQueue(resetPointToCenter: true)
        }
    }

    /// 連続 AF/AE へ戻す共通処理（sessionQueue 上で呼ぶこと）。
    /// - Parameter resetPointToCenter: 注視点を画面中央へ戻すか
    private func returnToContinuousOnSessionQueue(resetPointToCenter: Bool) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if resetPointToCenter {
                let center = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = center
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = center
                }
            }
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
        sessionQueue.async {
            self.isInterrupted = true
        }
    }

    @objc private func handleSessionInterruptionEnded() {
        sessionQueue.async {
            self.isInterrupted = false
            // バックグラウンド中に中断が明けた場合はここでは開始しない
            //（前面へ戻ったときに `handleWillEnterForeground` が改めて判定する）。
            self.startIfPossibleOnSessionQueue()
        }
    }

    @objc private func handleDidEnterBackground() {
        sessionQueue.async {
            self.isInBackground = true
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    @objc private func handleWillEnterForeground() {
        sessionQueue.async {
            self.isInBackground = false
            self.startIfPossibleOnSessionQueue()
        }
    }
}

// MARK: - PhotoCaptureDelegate

/// 1 回の撮影に 1 個だけ使う使い捨てデリゲート。
/// `AVCapturePhotoOutput` はデリゲートを弱参照で持たないため、呼び出し側で寿命を管理する。
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let completion: (Result<(data: Data, metadata: [String: Any]), Error>) -> Void

    /// 1 回の撮影が完全に終わったときに呼ぶ後始末（デリゲートの解放）。
    private let onFinished: () -> Void

    /// 二重呼び出し防止（エラーと完了が両方来るケースがある）。
    /// ⚠️ `withCheckedThrowingContinuation` は二重 resume でクラッシュするので、
    ///    このフラグは「安全のための飾り」ではなく**落ちないための必須条件**。
    private var hasCompleted = false

    init(
        completion: @escaping (Result<(data: Data, metadata: [String: Any]), Error>) -> Void,
        onFinished: @escaping () -> Void
    ) {
        self.completion = completion
        self.onFinished = onFinished
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

    /// 1 回の撮影で **必ず最後に** 呼ばれるコールバック。
    ///
    /// `didFinishProcessingPhoto` は撮影が途中で打ち切られると届かないことがある。
    /// そのとき continuation が resume されないと、呼び出し側の `isCapturing` が
    /// 下りずカメラ画面から出られなくなる（強制終了以外に脱出手段が無くなる）。
    /// ここを唯一の「必ず通る出口」にして、取りこぼしを構造的に塞ぐ。
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if !hasCompleted {
            hasCompleted = true
            let reason = error?.localizedDescription ?? "撮影が完了しませんでした"
            completion(.failure(SkyCameraError.captureFailed(reason)))
        }
        onFinished()
    }
}
