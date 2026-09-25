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

    /// 背面カメラ。構成後に確定する（sessionQueue 上でのみ触る）。
    /// ⭐️ 可能なら**仮想デバイス**（3眼などをまとめた 1 つのデバイス）を掴む。
    ///    レンズごとに別デバイスへ差し替えると、そのたびにセッションの再構成が要り、
    ///    露出・回転・水平線ガイドの結びつけも作り直しになる。
    ///    仮想デバイスならズーム倍率を変えるだけで OS がレンズを切り替えてくれるので、
    ///    こちらは**デバイスを一度も持ち替えない**（＝既存の配線に一切触らない）。
    private var videoDevice: AVCaptureDevice?

    /// 掴んだデバイスのレンズ構成（倍率の換算に使う）。sessionQueue 上でのみ触る。
    private var lensConfigurationStorage: LensConfiguration?

    /// いまセッションへ挿している入力（デバイスを付け替えるときに外すため保持する）。
    private var videoInput: AVCaptureDeviceInput?

    /// いま掴んでいるカメラの種別。
    /// ⚠️ 「単眼かどうか」の真偽値では足りない。48MP はどのレンズでも撮れるので、
    ///    **どの物理レンズを掴んでいるか**まで持たないと付け替えの要否を判断できない。
    private var currentLensRequirement: SkyCameraLensRequirement = .virtual

    /// 付け替え先の種別（レンズ構成の作り方が違うので分けて渡す）。
    private enum AttachTarget {
        /// 複数レンズをまとめた仮想デバイス。倍率の基準は端末が報告する切替点から作る。
        case virtual(hasUltraWide: Bool)
        /// 物理レンズ 1 本。倍率の基準は「素の画角」から作る（端末は切替点を報告しない）。
        case physical(nativeDisplayedZoom: CGFloat)
    }

    /// 超広角・望遠を含む**仮想デバイス**のレンズ構成。
    /// ⚠️ 物理レンズを掴んでいる間も**保持し続ける**。UI のズームボタンはこちらを基準に
    ///    組み立てるので、48MP のあいだ 0.5x / 3x が消えてはいけない。
    ///    「構成時に一度だけ取る」にすると、保存済みの 48MP を復元した直後に
    ///    物理レンズの構成で上書きされるかどうかが**呼び出し順に依存**してしまう。
    ///    仮想デバイスを掴んだときにだけ更新することで順序に依存しなくなる。
    private var virtualLensConfigurationStorage: LensConfiguration?

    /// いま合わせている表示倍率（sessionQueue 上でのみ触る）。
    private var currentDisplayedZoom: CGFloat = 1

    /// レンズ状態が変わったときの通知先（メインスレッドで呼ぶ）。
    private var lensStateHandler: (@Sendable (SkyCameraLensState) -> Void)?

    /// 直近に通知したレンズ状態（同じ内容を何度も流さないため）。
    private var lastPublishedLensState: SkyCameraLensState?

    /// 最後に受け取ったズーム要求の連番。
    /// ⚠️ 付け替えには時間がかかるので、その間に次のズーム要求が来ると、
    ///    **完了通知が古い倍率を持って後から届く**（指を離した後に表示だけ巻き戻る）。
    ///    どの要求に対する結果かを番号で示し、受け手が古い通知を捨てられるようにする。
    private var latestZoomRequestID: UInt64 = 0

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

    /// ロックの世代番号（sessionQueue 上でのみ読み書きする）。
    /// ⚠️ ロック指定の `focus(at:locked:)` は 0.5 秒後に `.locked` を書く予約を入れるが、
    ///    予約した時点では「その 0.5 秒の間に解除・掛け直し・レンズ付け替えが起きるか」は分からない。
    ///    ロックの状態が変わるたびに世代を進め、発火時に「予約した世代のままか」を確かめて
    ///    古い予約を捨てる。これが無いと、ロック直後にタップで解除しても 0.5 秒後に固定され直す。
    private var lockGeneration: UInt64 = 0

    /// このロック中に、ユーザーが明るさ（露出補正）を手動で動かしたか（sessionQueue 上でのみ読み書きする）。
    /// 解除時に補正を 0 へ戻すかどうかの判断に使う（`ManualExposure.shouldResetOnUnlock`）。
    private var hasManualExposureAdjustment = false

    /// 手動の露出補正のうち「まだ端末へ書いていない最新値」。
    /// ⚠️ ドラッグ中は 60Hz で届くので、1 件ずつ sessionQueue へ積むと書き込みが追いつかず、
    ///    指を止めた後もしばらく古い値を順に書き続ける。最新値だけを預かり、
    ///    書き込みの予約は常に 1 本だけにする（溜まった古い値は上書きで捨てる）。
    ///    呼び手（メイン）と書き手（sessionQueue）がまたがるので、ここだけはロックで守る。
    private var pendingManualExposureBias: Float?
    private let pendingManualExposureLock = NSLock()

    /// 空優先 AE（白飛び防止）の測光器。プレビュー映像から白飛び率を実測する。
    private var exposureMeter: SkyExposureMeter?

    /// 空優先 AE をユーザーが ON にしているか（sessionQueue 上でのみ読み書きする）。
    private var isSkyPriorityDesired = false

    /// いま端末へかけている露出補正値（EV）。sessionQueue 上でのみ読み書きする。
    private var appliedExposureBias: Float = 0

    /// 直近に測れた白飛び率と最大輝度（較正用の計装）。
    /// ⚠️ 「効かなかった」ときに、閾値が高すぎるのか本当に飛んでいないのかを
    ///    区別するために要る。これが無いと数値を当てずっぽうで動かすことになる。
    private var lastClippedFraction: Double = 0
    private var lastPeakLuma: UInt8 = 0

    /// この画面を開いてからの最大値（較正用）。
    /// ⚠️ 「直近」だけでは足りない。空優先 AE は飛びを見つけると露出を下げて飛びを消すので、
    ///    撮影時点の値は**補正後の落ち着いた姿**しか映さない。
    ///    補正する前にどこまで明るかったかは、最大値を覚えていないと永久に分からない。
    private var maxClippedFraction: Double = 0
    private var maxPeakLuma: UInt8 = 0

    /// 測光が一度でも成立したか（計装用）。
    /// ⚠️ これが無いと「ON だが一度も測れていない（壊れている）」と
    ///    「ON だが下げる必要が無かった（正常）」が本番データで区別できない。
    ///    測光出力を挿せなかった端末・想定外のバッファ形式など、
    ///    恒久的に機能しない経路はすべてここが false のままになる。
    private var hasMeasuredClipping = false

    /// フラッシュの動作（sessionQueue 上でのみ読み書きする）。
    private var flashMode: AVCaptureDevice.FlashMode = .off

    /// 選べる撮影解像度（sessionQueue 上でのみ読み書きする）。
    private var availableResolutions: [SkyCameraPhotoResolution] = []

    /// いま選んでいる撮影解像度。nil なら端末既定（＝最小）。
    private var preferredResolution: SkyCameraPhotoResolution?

    /// いま実際に撮れる解像度。レンズの都合で希望より下がることがある
    /// （48MP のまま超広角へ移ると 12MP になる）。
    /// ⚠️ 撮影設定には**必ずこちらを使う**。希望値をそのまま渡すと、出せないデバイスに
    ///    出せない寸法を要求することになる。
    private var effectiveResolutionStorage: SkyCameraPhotoResolution?

    /// このデバイスの**全フォーマットを通じた**最大解像度（MP。診断用）。
    /// ⚠️ いま使っているフォーマットが出せる最大とは別物。
    ///    「48MP がこのデバイスに存在しないのか、いまのフォーマットが対応していないだけか」を
    ///    区別するために要る。仮想デバイス（3眼）では 48MP が出ないことがあり、
    ///    その場合はレンズ切替と 48MP のどちらを取るかという設計判断になる。
    private var deviceMaxMegapixels = 0

    /// **背面の物理レンズごと**の最大解像度（例: `"ultra:12,wide:48,tele:12"`。診断用）。
    /// ⚠️ 「48MP を超広角・望遠でも撮れるのか」は**測らないと分からない**。
    ///    カタログ上のセンサー画素数と、AVFoundation が写真として出せる寸法は別物なので、
    ///    仕様表を根拠に実装を始めない。ここが 48 でなければ、その大工事に意味は無い。
    private var lensMaxMegapixels = ""

    /// 記録形式（sessionQueue 上でのみ読み書きする）。
    private var photoFormat: SkyCameraPhotoFormat = .heic

    /// 直近の測光で届いたバッファが Full Range だったか（計装用）。まだ測れていなければ nil。
    /// ⚠️ `lastPeakLuma` / `maxPeakLuma` は届いたバッファの流儀のままの生値
    ///    （Video Range なら最大 235）。どちらの物差しかを残さないと集計で混ざる。
    private var lastLumaFullRange: Bool?

    /// 直近の測光がどの範囲を測ったか（空の側だけ／画面全体。計装用）。
    private var lastMeterRegion: SkyPriorityExposure.MeterRegion?

    /// 空優先 AE の判定パラメータ。
    private let exposureTuning = SkyPriorityExposure.Tuning.default

    /// 露出補正を書き込んでから、反映完了の通知が来るまでに見込む最大待ち時間（秒）。
    /// 通知が来なかった場合の保険でもあるので、実測の収束時間より長めに取る。
    private static let exposureSettleTimeout: CFTimeInterval = 0.6

    /// 反映完了の通知が来てから、AE が物理的に落ち着くまで追加で待つ時間（秒）。
    private static let exposureSettleMargin: CFTimeInterval = 0.3

    /// プレビュー View（回転の追従に使う）。sessionQueue 上でのみ読み書きする。
    /// ⚠️ **weak で持つ**。View は `onTap` クロージャ経由で ViewModel → 本コントローラを
    ///    強参照しているので、こちらが強参照すると循環参照になる。
    private weak var previewView: CameraPreviewUIView?

    /// プレビュー回転角の監視（iOS 17+）。sessionQueue 上で読み書きする（deinit を除く）。
    private var rotationObservation: NSKeyValueObservation?

    /// 撮影用の回転角の監視（空優先 AE の測光が「どちらが空か」を知るため）。
    /// プレビュー用とは別に持つ。プレビュー層が無くても測光は動くので、こちらは常に張る。
    private var captureRotationObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    public override init() {
        super.init()
        registerNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // KVO は invalidate() がどのスレッドからでも安全なので deinit で解除してよい。
        rotationObservation?.invalidate()
        captureRotationObservation?.invalidate()
    }

    // MARK: - Configuration

    /// セッションを構成する（背面広角 + 静止画出力）。既に構成済みなら何もしない。
    /// - Throws: 背面カメラが無い／入出力を追加できない場合
    public func configure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureOnSessionQueue()
                    // ⚠️ 解像度は**構成が確定してから**読む。
                    //    `sessionPreset = .photo` は commitConfiguration で初めて効くので、
                    //    構成の内側で activeFormat を見ると**前の形式**の値を拾ってしまう
                    //    （選べる解像度が 1 つしか無いように見える）。
                    //    `availableVideoPixelFormatTypes` で踏んだのと同じ型の罠。
                    self.finalizePhotoDimensionsOnSessionQueue()
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

        guard let selected = Self.selectBackCamera() else {
            throw SkyCameraError.deviceUnavailable
        }
        let device = selected.device

        session.beginConfiguration()
        // beginConfiguration と commitConfiguration は必ず対で呼ぶ（途中 throw でも取りこぼさない）。
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw SkyCameraError.configurationFailed
        }
        session.addInput(input)
        videoInput = input

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
        let meter = SkyExposureMeter(
            clipThreshold: exposureTuning.clipThreshold,
            skyRegionFraction: exposureTuning.skyRegionFraction
        ) { [weak self] reading in
            guard let self else { return }
            self.sessionQueue.async {
                // 適用の可否に関わらず「測れた」ことは記録する（壊れていない証拠になる）。
                self.hasMeasuredClipping = true
                // 測り方（空の側／画面全体・Full／Video Range）が変わったら、
                // これまでの最大値は別の物差しの数字なので混ぜずに積み直す。
                if SkyPriorityExposure.measurementBasisChanged(
                    previousRegion: self.lastMeterRegion,
                    previousFullRange: self.lastLumaFullRange,
                    region: reading.region,
                    isFullRange: reading.isFullRange
                ) {
                    self.maxClippedFraction = 0
                    self.maxPeakLuma = 0
                }
                self.lastClippedFraction = reading.clippedFraction
                self.lastPeakLuma = reading.peakLuma
                self.maxClippedFraction = max(self.maxClippedFraction, reading.clippedFraction)
                self.maxPeakLuma = max(self.maxPeakLuma, reading.peakLuma)
                self.lastLumaFullRange = reading.isFullRange
                self.lastMeterRegion = reading.region
                self.applyMeasuredClippingOnSessionQueue(reading.clippedFraction)
            }
        }
        if session.canAddOutput(meter.output) {
            session.addOutput(meter.output)
            meter.prepare()
            meter.setEnabled(isSkyPriorityDesired)
            exposureMeter = meter
        }

        attachDeviceOnSessionQueue(device,
                                   target: .virtual(hasUltraWide: selected.hasUltraWide),
                                   targetDisplayedZoom: 1)
        isConfigured = true
    }

    /// 選べる撮影解像度を確定し、出力側の上限を上げる（sessionQueue 上・構成の**後**で呼ぶこと）。
    private func finalizePhotoDimensionsOnSessionQueue() {
        guard let device = videoDevice else { return }
        // 24MP は遅延配信が要るので一覧から外す（理由は SkyCameraPhotoResolution のコメント）。
        let supported = device.activeFormat.supportedMaxPhotoDimensions
            .map { SkyCameraPhotoResolution(width: $0.width, height: $0.height) }
            .filter { !$0.requiresDeferredDelivery }
            .sorted { $0.megapixels < $1.megapixels }
        // 物理レンズを 1 本だけ掴めば仮想デバイスより大きく撮れるので、その最大を 1 件だけ足す。
        // ⚠️ **どのレンズでも撮れる**（実機で超広角・標準・望遠とも 48MP と実測）。
        //    「広角だけ」ではないので、3 本の中の最大を採る。
        // ⚠️ 一覧は**初回に一度だけ**作り、切り替えのたびに作り直さない。
        //    作り直すと 48MP を選んだ瞬間に 12MP へ戻る道が消える。
        var resolutions = supported
        if let physicalBest = Self.largestPhysicalLensPhotoResolution(),
           physicalBest.megapixels > (supported.last?.megapixels ?? 0) {
            resolutions.append(SkyCameraPhotoResolution(
                width: physicalBest.width, height: physicalBest.height, requiresPhysicalLens: true))
        }
        availableResolutions = resolutions
        // 診断用：デバイスが持つ全フォーマットの中での最大。
        // ⚠️ メソッドチェーンで書くと型チェックが通らない（式が複雑すぎる）。素直に回す。
        let maxMegapixels = Self.maximumMegapixels(for: device)
        deviceMaxMegapixels = maxMegapixels
        lensMaxMegapixels = Self.lensMaxMegapixelsSummary()

        // ⚠️ 出力側の上限は**ここで一度だけ**いちばん大きい値へ上げておく。
        //    撮影のたびに動かすと「重いパイプライン再構成」が走る（SDK ヘッダーの警告）。
        //    以後は撮影設定側（settings.maxPhotoDimensions）で軽く選ぶ。
        //    startRunning の前に済ませる必要があるが、configure() は start() より先なので満たしている。
        if let largest = supported.last {
            photoOutput.maxPhotoDimensions = CMVideoDimensions(
                width: largest.width, height: largest.height)
        }

        // ProRAW は「使う」と宣言して初めて availableRawPhotoPixelFormatTypes に現れる。
        // 対応端末なら常に有効化しておく（実際に RAW で撮るかは撮影設定側で決める）。
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
    }

    /// デバイスを掴んだ後の共通処理。
    ///
    /// ⭐️ 初回構成と、解像度都合の**付け替え**の両方がここを通る。
    ///    道を 2 本にすると必ず片方だけ直し忘れるので、1 本に集約してある。
    private func attachDeviceOnSessionQueue(_ device: AVCaptureDevice,
                                            target: AttachTarget,
                                            targetDisplayedZoom: CGFloat) {
        // 前のデバイス向けの購読を必ず外す（残すと古いデバイスの通知で誤動作する）。
        NotificationCenter.default.removeObserver(
            self, name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)

        videoDevice = device
        let lensConfiguration: LensConfiguration
        switch target {
        case .virtual(let hasUltraWide):
            lensConfiguration = Self.makeLensConfiguration(device: device, hasUltraWide: hasUltraWide)
            // ⚠️ 仮想デバイスのときだけ覚える。物理レンズの構成で上書きすると
            //    UI のズームボタンから 0.5x / 3x が消える。
            virtualLensConfigurationStorage = lensConfiguration
        case .physical(let nativeDisplayedZoom):
            // ⚠️ 物理レンズ単体は切替点を報告しないので、基準倍率を自分で与える。
            //    与えないと超広角の等倍が「1x」と表示され、画角と食い違う。
            lensConfiguration = LensConfiguration(
                nativeDisplayedZoom: nativeDisplayedZoom,
                minFactor: device.minAvailableVideoZoomFactor,
                deviceMaxFactor: device.maxAvailableVideoZoomFactor)
        }
        lensConfigurationStorage = lensConfiguration
        // 露出補正はデバイスごとの設定なので、付け替えたら追跡値を捨てる
        //（別のデバイスにかけた値を「いまかかっている」と思い込まないため）。
        appliedExposureBias = 0
        // ⚠️ AE/AF ロックも**同じ理由で捨てる**。新しいデバイスは自動追従の状態で始まるので、
        //    フラグだけ残すと (a) 画面のロック表示が実体と食い違い、
        //    (b) 空優先 AE が「ロック中だから触らない」と誤認して測光を止め続ける。
        //    露出補正だけリセットして、こちらを忘れていた。
        isFocusLocked = false
        // 手動の明るさ調整も同じ理由で捨てる。新しいデバイスには手動値を書いていないので、
        // 0 へ戻す書き込みは要らない（フラグだけ落とす）。0.5 秒後のロック予約も古い世代にする。
        hasManualExposureAdjustment = false
        lockGeneration &+= 1

        // ⚠️ 仮想デバイスは videoZoomFactor = 1.0 で始まるが、それは**いちばん広いレンズ**。
        //    3 眼端末だと超広角なので、何もしないとカメラが 0.5x で開いてしまう。
        //    そのため必ず倍率を明示して合わせる。
        // ⚠️ ここで**無条件に 1x へ戻してはいけない**。付け替えは「0.5x を押した」ことが
        //    きっかけで起きるので、1x へ戻すとユーザーの操作をそのまま捨てることになり、
        //    「押しても何も起きない」として現れる。狙いの倍率を受け取って復元する。
        applyZoomOnSessionQueue(displayedZoom: targetDisplayedZoom,
                                configuration: lensConfiguration,
                                device: device,
                                animated: false)
        currentDisplayedZoom = targetDisplayedZoom

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
    }

    // MARK: - レンズ選択

    /// 背面カメラを、広い画角を優先して選ぶ。
    ///
    /// 仮想デバイス（複数レンズを 1 つにまとめたもの）を上から順に試し、
    /// どれも無ければ従来どおり単眼の広角カメラへ落ちる。
    /// - Returns: 掴んだデバイスと、いちばん広いレンズが超広角かどうか
    private static func selectBackCamera() -> (device: AVCaptureDevice, hasUltraWide: Bool)? {
        // 「超広角を含むか」は倍率表示の基準（1x をどこに置くか）を決めるので、
        // 端末の型から確定させる。ここを推測にすると 0.5x の表示がずれる。
        let candidates: [(AVCaptureDevice.DeviceType, Bool)] = [
            (.builtInTripleCamera, true),    // 超広角＋標準＋望遠
            (.builtInDualWideCamera, true),  // 超広角＋標準
            (.builtInDualCamera, false),     // 標準＋望遠
            (.builtInWideAngleCamera, false) // 単眼
        ]
        for (type, hasUltraWide) in candidates {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return (device, hasUltraWide)
            }
        }
        return nil
    }

    /// 端末が報告する値からレンズ構成を組み立てる。
    private static func makeLensConfiguration(device: AVCaptureDevice,
                                              hasUltraWide: Bool) -> LensConfiguration {
        LensConfiguration(
            hasUltraWide: hasUltraWide,
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) },
            minFactor: device.minAvailableVideoZoomFactor,
            deviceMaxFactor: device.maxAvailableVideoZoomFactor
        )
    }

    // MARK: - ズーム

    /// 掴んだ端末のレンズ構成（UI がボタンとスライダーを組み立てるのに使う）。
    /// 構成前・デバイスが無い場合は nil。
    public func lensConfiguration() async -> LensConfiguration? {
        await withCheckedContinuation { (continuation: CheckedContinuation<LensConfiguration?, Never>) in
            sessionQueue.async { continuation.resume(returning: self.lensConfigurationStorage) }
        }
    }

    /// 表示倍率（0.5x / 1x / 3x …）を指定してズームする。
    /// - Parameters:
    ///   - displayedZoom: 画面に出している倍率
    ///   - animated: true ならなめらかに寄る（ボタンで飛ばすとき用）。
    ///     スライダーのように連続して呼ぶ場合は false にする
    ///     （毎回アニメーションを開始し直すとかえってカクつくため）。
    public func setZoom(displayedZoom: CGFloat, animated: Bool, requestID: UInt64) {
        sessionQueue.async {
            self.latestZoomRequestID = requestID
            // ⚠️ 判断は「これから合わせたい倍率」で行う。付け替え**後**の実測値で判断すると、
            //    付け替え → 倍率が変わる → また付け替え、と往復しかねない。
            let required = self.requiredLensOnSessionQueue(displayedZoom: displayedZoom,
                                                           resolution: self.preferredResolution)
            if required != self.currentLensRequirement, let preferred = self.preferredResolution {
                self.switchDeviceOnSessionQueue(to: required,
                                                targetResolution: preferred,
                                                targetDisplayedZoom: displayedZoom)
                return
            }
            guard let device = self.videoDevice,
                  let configuration = self.lensConfigurationStorage else { return }
            self.applyZoomOnSessionQueue(displayedZoom: displayedZoom,
                                         configuration: configuration,
                                         device: device,
                                         animated: animated)
            self.currentDisplayedZoom = displayedZoom
        }
    }

    /// 掴んでいるデバイスへ倍率を実際に当てる（sessionQueue 上で呼ぶこと）。
    private func applyZoomOnSessionQueue(displayedZoom: CGFloat,
                                         configuration: LensConfiguration,
                                         device: AVCaptureDevice,
                                         animated: Bool) {
        let factor = configuration.videoZoomFactor(forDisplayedZoom: displayedZoom)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if animated {
                // rate は「1 秒あたり何段変わるか」。4 は標準カメラに近い体感。
                device.ramp(toVideoZoomFactor: factor, withRate: 4)
            } else {
                // ドラッグ中に ramp を重ねると前の動きと喧嘩するので、必ず止めてから直接入れる。
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = factor
            }
        } catch {
            // ズームできなくても撮影自体は続けられるので握りつぶす。
        }
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

        // 空優先 AE の測光へ「撮影を正立させる角度」を流す。
        // ⚠️ プレビュー層の有無に関係なく張る（下の guard より前に置く）。
        //    測光用のバッファはセンサー本来の向きのまま届くので、この角度が無いと
        //    どちらが空か分からず、画面全体を測ることになる。
        captureRotationObservation?.invalidate()
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            // 測光器は sessionQueue 上でのみ触る（他のプロパティと同じ規則）。
            self?.sessionQueue.async {
                self?.exposureMeter?.setCaptureRotation(Double(angle))
            }
        }

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
            self.exposureMeter?.setEnabled(self.isSkyPriorityDesired)
            self.startIfPossibleOnSessionQueue()
        }
    }

    /// セッションを停止する。
    public func stop() {
        sessionQueue.async {
            self.isRunningDesired = false
            // ⚠️ 復帰処理より**先に**測光を止める。止めないと、停止直前に測られた結果が
            //    この後ろのキューに残っていて、0 EV へ戻した直後に負の補正を再適用しうる。
            //    シリアルキューは順序を守るだけで、古い依頼を捨ててはくれない。
            self.exposureMeter?.setEnabled(false)
            // 露出補正は端末（AVCaptureDevice）側に残る設定なので、画面を閉じるときは素へ戻す。
            // 戻さないと「OFF にしたのに暗いまま」「次に開いたら暗い」が起きる。
            self.resetExposureBiasOnSessionQueue()
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
    ) async throws -> (data: Data, rawData: Data?, metadata: [String: Any]) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data, rawData: Data?, metadata: [String: Any]), Error>) in
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

    /// 撮影設定。既定は HEIC（容量が小さく EXIF もそのまま載る）。
    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings = makeBaseSettings()
        // ⚠️ `.quality` にするとナイトモード・Deep Fusion が自動で効くようになるが、
        //    そのぶんシャッターが待たされる。空の連続撮影を優先して `.balanced` のままにしてある
        //    （段階 A での意図的な選択。変えるならシャッター体感の再確認とセットで）。
        settings.photoQualityPrioritization = .balanced
        // 指定しないと端末が出せる**最小**で撮られる（SDK ヘッダー明記）。
        // ⚠️ 希望値ではなく**実際に撮れる解像度**を渡す。仮想デバイスへ戻っているのに
        //    48MP の寸法を要求すると、そのデバイスが出せない寸法になる。
        if let resolution = effectiveResolutionStorage {
            settings.maxPhotoDimensions = CMVideoDimensions(
                width: resolution.width, height: resolution.height)
        }
        // 端末・状態によって使えるフラッシュは変わるので、必ず現時点の可否を見てから入れる。
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        return settings
    }

    /// 記録形式に応じた撮影設定の土台を作る。
    private func makeBaseSettings() -> AVCapturePhotoSettings {
        let hevcAvailable = photoOutput.availablePhotoCodecTypes.contains(.hevc)
        let processedFormat: [String: Any]? = hevcAvailable
            ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil

        if photoFormat == .raw, let rawType = preferredRawPixelFormatType() {
            // ⚠️ RAW 単独にはしない。DNG は編集パイプラインで開けないので、
            //    必ず現像済みの 1 枚を同時に受け取って、そちらを編集へ渡す。
            return AVCapturePhotoSettings(
                rawPixelFormatType: rawType,
                processedFormat: processedFormat ?? [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        if photoFormat == .heic, let processedFormat {
            return AVCapturePhotoSettings(format: processedFormat)
        }
        // JPEG、または HEVC が使えない端末。
        return AVCapturePhotoSettings()
    }

    /// 使う RAW の画素形式。Apple ProRAW を優先する（素の Bayer RAW より扱いやすい）。
    private func preferredRawPixelFormatType() -> OSType? {
        let available = photoOutput.availableRawPhotoPixelFormatTypes
        // ⚠️ **Apple ProRAW だけを使う。Bayer RAW へは落とさない。**
        //    SDK ヘッダー（AVCapturePhotoOutput.h）の Bayer RAW rules:
        //      - photoQualityPrioritization を .speed にしなければならない
        //      - 撮影時の videoZoomFactor が 1.0 でなければならない
        //    破ると NSInvalidArgumentException で**落ちる**。レンズ切替とズームが主役の
        //    このカメラでその制約は飲めないので、対応端末を絞る方を選ぶ。
        //    ここが nil を返せば `isRAWAvailable()` も false になり、
        //    メニューから RAW が消える（選べないものを見せない）。
        return available.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
    }

    // MARK: - 撮影の設定

    /// フラッシュの動作を変える。
    public func setFlashMode(_ mode: SkyCameraFlashMode) {
        sessionQueue.async { self.flashMode = mode.avFlashMode }
    }

    /// 記録形式を切り替える。
    public func setPhotoFormat(_ format: SkyCameraPhotoFormat) {
        sessionQueue.async { self.photoFormat = format }
    }

    /// この端末で RAW（Apple ProRAW）を使えるか。使えないならメニューに出さない。
    public func isRAWAvailable() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async {
                continuation.resume(returning: self.preferredRawPixelFormatType() != nil)
            }
        }
    }

    /// 指定デバイスが出せる最大の解像度（遅延配信が要るものは除く）。
    private static func largestPhotoResolution(
        for device: AVCaptureDevice?
    ) -> SkyCameraPhotoResolution? {
        guard let device else { return nil }
        var best: SkyCameraPhotoResolution?
        for format in device.formats {
            for dimensions in format.supportedMaxPhotoDimensions {
                let candidate = SkyCameraPhotoResolution(
                    width: dimensions.width, height: dimensions.height)
                guard !candidate.requiresDeferredDelivery else { continue }
                if candidate.megapixels > (best?.megapixels ?? 0) { best = candidate }
            }
        }
        return best
    }

    /// その解像度で撮れるフォーマットのうち、プレビューが軽いものを選ぶ。
    /// ⚠️ 48MP は `.photo` プリセットが選ぶフォーマットでは出ない。
    ///    プリセットを `.inputPriority` にして、ここで選んだフォーマットを自分で当てる。
    private static func format(
        for device: AVCaptureDevice, supporting resolution: SkyCameraPhotoResolution
    ) -> AVCaptureDevice.Format? {
        var best: AVCaptureDevice.Format?
        var bestArea = Int.max
        for format in device.formats {
            let matches = format.supportedMaxPhotoDimensions.contains {
                $0.width == resolution.width && $0.height == resolution.height
            }
            guard matches else { continue }
            let videoDimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let area = Int(videoDimensions.width) * Int(videoDimensions.height)
            // プレビュー用の映像が小さいものを優先する（大きいほど発熱と電力を食う）。
            if area < bestArea {
                bestArea = area
                best = format
            }
        }
        return best
    }

    /// 指定デバイスが全フォーマットを通じて出せる最大解像度（MP）。
    /// ⚠️ メソッドチェーンで書くと型チェックが通らない（式が複雑すぎる）。素直に回す。
    private static func maximumMegapixels(for device: AVCaptureDevice?) -> Int {
        guard let device else { return 0 }
        var maxMegapixels = 0
        for format in device.formats {
            for dimensions in format.supportedMaxPhotoDimensions {
                let resolution = SkyCameraPhotoResolution(
                    width: dimensions.width, height: dimensions.height)
                maxMegapixels = max(maxMegapixels, resolution.megapixels)
            }
        }
        return maxMegapixels
    }

    /// 背面の物理レンズごとの最大解像度を 1 行にまとめる（副作用なし・読むだけ）。
    ///
    /// ⭐️ 掴まずに `formats` を読むだけなので、セッションには一切影響しない。
    ///    「超広角でも 48MP を出せるのか」を、実装に着手する**前に**数字で確かめるための値。
    private static func lensMaxMegapixelsSummary() -> String {
        let lenses: [(String, AVCaptureDevice.DeviceType)] = [
            ("ultra", .builtInUltraWideCamera),
            ("wide", .builtInWideAngleCamera),
            ("tele", .builtInTelephotoCamera)
        ]
        var parts: [String] = []
        for (name, type) in lenses {
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else {
                // 持っていないレンズは「0」ではなく欠席として残す（0 は「測って 0 だった」と紛らわしい）。
                parts.append("\(name):-")
                continue
            }
            parts.append("\(name):\(Self.maximumMegapixels(for: device))")
        }
        return parts.joined(separator: ",")
    }

    /// 診断用の解像度まわりの実測値。
    /// - Returns: `current` = いま掴んでいるデバイスの最大、
    ///   `lenses` = 物理レンズごとの最大（例 `"ultra:12,wide:48,tele:12"`）
    public func maximumMegapixelsDiagnostics() async -> (current: Int, lenses: String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(current: Int, lenses: String), Never>) in
            sessionQueue.async {
                continuation.resume(returning: (self.deviceMaxMegapixels, self.lensMaxMegapixels))
            }
        }
    }

    /// 選べる撮影解像度の一覧（小さい順）。
    public func photoResolutions() async -> [SkyCameraPhotoResolution] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[SkyCameraPhotoResolution], Never>) in
            sessionQueue.async { continuation.resume(returning: self.availableResolutions) }
        }
    }

    /// 撮影解像度を選ぶ。必要ならデバイスごと付け替える。
    public func setPhotoResolution(_ resolution: SkyCameraPhotoResolution?) {
        sessionQueue.async {
            self.preferredResolution = resolution
            guard let resolution else { return }
            // 解像度を変えても倍率は保つ。レンズはどの倍率でも選べるので寄せる必要が無い。
            let targetZoom = self.currentDisplayedZoom
            let required = self.requiredLensOnSessionQueue(displayedZoom: targetZoom,
                                                           resolution: resolution)
            self.switchDeviceOnSessionQueue(to: required,
                                            targetResolution: resolution,
                                            targetDisplayedZoom: targetZoom)
        }
    }

    /// デバイスを付け替える（sessionQueue 上で呼ぶこと）。
    ///
    /// ⚠️ 48MP は物理レンズを 1 本だけ掴んだときにしか出せず、3眼をまとめた仮想デバイスからは
    ///    見えない（実機で triple=24MP / 物理3本はいずれも 48MP と実測）。
    ///    よって解像度とデバイスは切り離せない。
    ///    ただし**ユーザーにはレンズを常に選ばせる**ので、超広角・望遠へ移るときは
    ///    こちらが自動で仮想デバイスへ戻し、そのぶん解像度を落とす。
    private func switchDeviceOnSessionQueue(to requirement: SkyCameraLensRequirement,
                                            targetResolution: SkyCameraPhotoResolution,
                                            targetDisplayedZoom: CGFloat) {
        guard requirement != currentLensRequirement else {
            // 付け替えは要らないが、倍率の指定は効かせる。
            if let device = videoDevice, let configuration = lensConfigurationStorage {
                applyZoomOnSessionQueue(displayedZoom: targetDisplayedZoom,
                                        configuration: configuration,
                                        device: device,
                                        animated: true)
            }
            finishDeviceSwitchOnSessionQueue(targetDisplayedZoom: targetDisplayedZoom)
            return
        }

        // 掴む先を決める。狙った物理レンズが取れない端末では仮想デバイスへ落とす。
        var resolved: SkyCameraLensRequirement = .virtual
        var targetDevice: AVCaptureDevice?
        var attachTarget: AttachTarget?
        if case .physical(let lens) = requirement,
           let native = virtualLensConfigurationStorage?.nativeDisplayedZoom(for: lens),
           let physical = AVCaptureDevice.default(Self.deviceType(for: lens),
                                                  for: .video, position: .back) {
            resolved = requirement
            targetDevice = physical
            attachTarget = .physical(nativeDisplayedZoom: native)
        } else if let selected = Self.selectBackCamera() {
            targetDevice = selected.device
            attachTarget = .virtual(hasUltraWide: selected.hasUltraWide)
        }

        guard let targetDevice, let attachTarget, let previousInput = videoInput else {
            // 掴めるデバイスが無い。付け替えは諦めるが、倍率の要求は捨てない。
            abandonDeviceSwitchOnSessionQueue(targetDisplayedZoom: targetDisplayedZoom)
            return
        }
        // 落とした先がいまと同じなら付け替えない（無駄な作り直しを避ける）。
        guard resolved != currentLensRequirement else {
            abandonDeviceSwitchOnSessionQueue(targetDisplayedZoom: targetDisplayedZoom)
            return
        }

        session.beginConfiguration()
        session.removeInput(previousInput)
        guard let input = try? AVCaptureDeviceInput(device: targetDevice),
              session.canAddInput(input) else {
            // ⚠️ 入れ替えに失敗したら必ず元へ戻す。入力が無いセッションはプレビューが
            //    真っ暗になり、ユーザーには「壊れた」としか見えない。
            if session.canAddInput(previousInput) { session.addInput(previousInput) }
            session.commitConfiguration()
            abandonDeviceSwitchOnSessionQueue(targetDisplayedZoom: targetDisplayedZoom)
            return
        }
        session.addInput(input)
        videoInput = input

        var isPhysical = false
        if case .physical = attachTarget { isPhysical = true }
        if isPhysical, let format = Self.format(for: targetDevice, supporting: targetResolution) {
            // プリセットを外してフォーマットを自分で当てる（48MP を出す唯一の方法）。
            session.sessionPreset = .inputPriority
            do {
                try targetDevice.lockForConfiguration()
                defer { targetDevice.unlockForConfiguration() }
                targetDevice.activeFormat = format
            } catch {
                // 当てられなければプリセット任せのまま進む（解像度は上がらないが撮れる）。
            }
        } else {
            session.sessionPreset = .photo
        }
        session.commitConfiguration()

        currentLensRequirement = resolved
        attachDeviceOnSessionQueue(targetDevice,
                                   target: attachTarget,
                                   targetDisplayedZoom: targetDisplayedZoom)
        finishDeviceSwitchOnSessionQueue(targetDisplayedZoom: targetDisplayedZoom)
    }

    /// いまの倍率と希望解像度から、掴むべきカメラを決める（sessionQueue 上で呼ぶこと）。
    private func requiredLensOnSessionQueue(displayedZoom: CGFloat,
                                            resolution: SkyCameraPhotoResolution?)
        -> SkyCameraLensRequirement {
        let virtual = virtualLensConfigurationStorage
        return SkyCameraLensSwitching.requiredDevice(
            displayedZoom: displayedZoom,
            preferredRequiresPhysicalLens: resolution?.requiresPhysicalLens ?? false,
            ultraWideNativeZoom: virtual?.nativeDisplayedZoom(for: .ultraWide),
            teleNativeZoom: virtual?.nativeDisplayedZoom(for: .telephoto),
            current: currentLensRequirement)
    }

    /// 物理レンズと AVFoundation のデバイス種別の対応。
    private static func deviceType(for lens: SkyCameraPhysicalLens) -> AVCaptureDevice.DeviceType {
        switch lens {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }

    /// 背面の物理レンズ 3 本の中で、いちばん大きく撮れる解像度（掴まず読むだけ）。
    private static func largestPhysicalLensPhotoResolution() -> SkyCameraPhotoResolution? {
        var best: SkyCameraPhotoResolution?
        for lens in SkyCameraPhysicalLens.allCases {
            let device = AVCaptureDevice.default(Self.deviceType(for: lens),
                                                 for: .video, position: .back)
            guard let candidate = Self.largestPhotoResolution(for: device) else { continue }
            if candidate.megapixels > (best?.megapixels ?? 0) { best = candidate }
        }
        return best
    }

    /// 付け替えを**諦めた**ときの後始末（sessionQueue 上で呼ぶこと）。
    ///
    /// ⚠️ ここで古い倍率のまま帰ってはいけない。UI は押された時点で新しい倍率を
    ///    表示しているので、**表示と実体がずれたまま固定される**
    ///    （「押しても何も起きない」に見える）。付け替えができなくても、
    ///    要求された倍率はいま掴んでいるデバイスへ当てられるだけ当てる。
    ///    当てた結果（端末の上下限で丸められることがある）を実体として通知する。
    private func abandonDeviceSwitchOnSessionQueue(targetDisplayedZoom: CGFloat) {
        guard let device = videoDevice, let configuration = lensConfigurationStorage else {
            finishDeviceSwitchOnSessionQueue(targetDisplayedZoom: currentDisplayedZoom)
            return
        }
        applyZoomOnSessionQueue(displayedZoom: targetDisplayedZoom,
                                configuration: configuration,
                                device: device,
                                animated: true)
        // 端末が受け付けた実際の倍率を求め直す（要求値ではなく実体を UI へ返すため）。
        let applied = configuration.displayedZoom(
            forVideoZoomFactor: configuration.videoZoomFactor(forDisplayedZoom: targetDisplayedZoom))
        finishDeviceSwitchOnSessionQueue(targetDisplayedZoom: applied)
    }

    /// 付け替えの後始末。実際に撮れる解像度を確定し、出力側の上限を合わせ、UI へ知らせる。
    private func finishDeviceSwitchOnSessionQueue(targetDisplayedZoom: CGFloat) {
        let effective = resolveEffectiveResolutionOnSessionQueue()
        effectiveResolutionStorage = effective
        // 出力側の上限は「いま撮れる寸法」に合わせる。上げっぱなしにすると、
        // 仮想デバイスへ戻したあとも 48MP の寸法が残ってしまう。
        if let effective {
            photoOutput.maxPhotoDimensions = CMVideoDimensions(
                width: effective.width, height: effective.height)
        }
        currentDisplayedZoom = targetDisplayedZoom
        publishLensStateOnSessionQueue()
    }

    /// いま実際に撮れる解像度を求める（sessionQueue 上で呼ぶこと）。
    ///
    /// ⭐️ **要求値から推測せず、当たっているフォーマットから読み返す。**
    ///    「48MP を頼んだのだから 48MP のはず」と決め打ちすると、フォーマットを当て損ねた
    ///    ときや、そのレンズが 48MP を持たないときに**バッジが嘘をつく**。
    ///    読み返しにしておけば、表示は常に実体と一致する。
    private func resolveEffectiveResolutionOnSessionQueue() -> SkyCameraPhotoResolution? {
        guard let preferred = preferredResolution, let device = videoDevice else { return nil }
        let supported = device.activeFormat.supportedMaxPhotoDimensions
            .map { SkyCameraPhotoResolution(width: $0.width, height: $0.height) }
            .filter { !$0.requiresDeferredDelivery }
        guard !supported.isEmpty else { return nil }
        // 希望を超えない中で最大。無ければ（希望より全部大きい）いちばん小さいものへ。
        let withinPreferred = supported.filter { $0.megapixels <= preferred.megapixels }
        return withinPreferred.max { $0.megapixels < $1.megapixels }
            ?? supported.min { $0.megapixels < $1.megapixels }
    }

    /// レンズ状態が変わったときだけ UI へ知らせる（sessionQueue 上で呼ぶこと）。
    ///
    /// ⚠️ ズームのたびに流してはいけない。ドラッグ中は毎秒数十回呼ばれるので、
    ///    そのまま `@Published` へ流すと画面全体が作り直されてタップを取りこぼす。
    ///    変化したときだけ流す。
    private func publishLensStateOnSessionQueue() {
        let state = SkyCameraLensState(displayedZoom: currentDisplayedZoom,
                                       effectiveResolution: effectiveResolutionStorage,
                                       lens: currentLensRequirement,
                                       isFocusLocked: isFocusLocked,
                                       zoomRequestID: latestZoomRequestID)
        guard state != lastPublishedLensState else { return }
        lastPublishedLensState = state
        guard let handler = lensStateHandler else { return }
        DispatchQueue.main.async { handler(state) }
    }

    /// レンズ状態の通知先を登録する（構成の前でも後でもよい）。
    public func setLensStateHandler(_ handler: @escaping @Sendable (SkyCameraLensState) -> Void) {
        sessionQueue.async { self.lensStateHandler = handler }
    }

    /// 超広角・望遠を含む仮想デバイスのレンズ構成。
    /// UI のズームボタンは**常にこちら**を基準に組み立てる（48MP 中も消さないため）。
    public func virtualLensConfiguration() async -> LensConfiguration? {
        await withCheckedContinuation { (continuation: CheckedContinuation<LensConfiguration?, Never>) in
            sessionQueue.async { continuation.resume(returning: self.virtualLensConfigurationStorage) }
        }
    }

    /// いま実際に撮れる解像度（バッジ表示と計装に使う）。
    public func effectiveResolution() async -> SkyCameraPhotoResolution? {
        await withCheckedContinuation { (continuation: CheckedContinuation<SkyCameraPhotoResolution?, Never>) in
            sessionQueue.async { continuation.resume(returning: self.effectiveResolutionStorage) }
        }
    }

    /// この端末でフラッシュを使えるか（UI の出し分けに使う）。
    public func isFlashAvailable() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async {
                // supportedFlashModes は .off だけの端末でも1件返るので、
                // 「off 以外があるか」で判断する。
                let modes = self.photoOutput.supportedFlashModes
                continuation.resume(returning: modes.contains(.on) || modes.contains(.auto))
            }
        }
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
            // 前のロックで明るさを手動で動かしていたら、ここで 0 へ戻す。
            // ⚠️ タップでの解除は `unlockFocusAndExposure` を通らずここへ来るので、ここにも要る。
            //    書き込みは lockForConfiguration の内側で呼ぶと入れ子になるので、その前に済ませる。
            self.endManualExposureOnSessionQueue(device: device)
            self.isFocusLocked = locked
            // 合わせ直した時点で、前のロックの 0.5 秒後の予約は無効にする（`lockGeneration` 参照）。
            self.lockGeneration &+= 1
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
            // 停止中に ON にされても測り始めない（start() で復帰させる）。
            self.exposureMeter?.setEnabled(enabled && self.isRunningDesired)
            guard !enabled else { return }
            // ⭐️ ロック中に手動で明るさを調整している間は、補正値の持ち主は手動側。
            //    ここで 0 に戻すと、太陽マークの表示と実際の明るさがずれるうえ、ユーザーが決めた明るさを勝手に消してしまう。
            //    手動の補正はロック解除（endManualExposureOnSessionQueue）で 0 に戻るので、ここでは触らない。
            guard !(self.isFocusLocked && self.hasManualExposureAdjustment) else { return }
            self.resetExposureBiasOnSessionQueue()
        }
    }

    /// 真上（または真下）を向いているかを空優先 AE の測光へ伝える。
    /// 真上を向くと画面ほぼ全部が空になるので、測光は画面全体へ切り替わる。
    public func setMeteringLooksStraightUp(_ looksUp: Bool) {
        sessionQueue.async {
            self.exposureMeter?.setLooksStraightUp(looksUp)
        }
    }

    /// 空優先 AE の現況（計装用）。
    /// - Returns: `bias` = いまかかっている露出補正値（EV。EXIF が取れないときの保険）、
    ///   `hasMeasured` = 測光が一度でも成立したか、
    ///   `clippedFraction` / `peakLuma` = 直近の測定値（閾値較正のため）
    public func skyPriorityStatus() async -> SkyPriorityStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<SkyPriorityStatus, Never>) in
            sessionQueue.async {
                continuation.resume(returning: SkyPriorityStatus(
                    bias: self.appliedExposureBias,
                    hasMeasured: self.hasMeasuredClipping,
                    clippedFraction: self.lastClippedFraction,
                    peakLuma: self.lastPeakLuma,
                    maxClippedFraction: self.maxClippedFraction,
                    maxPeakLuma: self.maxPeakLuma,
                    lumaFullRange: self.lastLumaFullRange,
                    meterRegion: self.lastMeterRegion,
                    // 手動で動かしていなければ nil（「動かして 0 に戻した」と区別するため）。
                    manualBias: self.hasManualExposureAdjustment ? self.appliedExposureBias : nil
                ))
            }
        }
    }

    /// 露出補正を 0 EV（素の状態）へ戻す（sessionQueue 上で呼ぶこと）。
    /// OFF と停止の 2 経路から呼ばれるので、条件判定ごと 1 箇所にまとめてある。
    private func resetExposureBiasOnSessionQueue() {
        guard appliedExposureBias != 0, let device = videoDevice else { return }
        setExposureBiasOnSessionQueue(0, device: device)
    }

    /// 測光結果（白飛び率）を受けて露出補正を更新する（sessionQueue 上で呼ぶこと）。
    private func applyMeasuredClippingOnSessionQueue(_ clippedFraction: Double) {
        // ⚠️ `isRunningDesired` を必ず見る。測光結果は測られてから適用されるまでに
        //    キューを 1 回またぐので、その間に停止・OFF が挟まりうる。
        //    「測った時点で有効だった」ではなく「いま適用してよいか」で判断する。
        // ユーザーが長押しで AE をロックしているあいだは意図を尊重して触らない。
        guard isRunningDesired, isSkyPriorityDesired, !isFocusLocked,
              let device = videoDevice else { return }
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
    ///
    /// ⚠️ 書き込んだ値がセンサーに効くまでには時間がかかる（実機で数百ミリ秒）。
    ///    その間のフレームは**まだ前の明るさ**なので、測り続けると「効いていない」と誤解して
    ///    さらに下げ、下限まで振り切れる。だから書き込みとセットで測光を止める。
    private func setExposureBiasOnSessionQueue(_ bias: Float, device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(bias) { [weak self] _ in
                // 反映が完了した時点から、AE が物理的に落ち着くまでさらに少し待つ。
                self?.exposureMeter?.suppressMeasurements(for: Self.exposureSettleMargin)
            }
            // 反映完了の通知が来るまでの間も測らない。通知が来ない端末への保険も兼ねる。
            exposureMeter?.suppressMeasurements(for: Self.exposureSettleTimeout)
            // 端末への書き込みが成功したときだけ記録する（失敗時に嘘の現在値を持たないため）。
            appliedExposureBias = bias
        } catch {
            // ⚠️ 到達しない想定（このアプリの lockForConfiguration は sessionQueue 上で
            //    直列化されており、他アプリとの競合は中断通知として現れるため）。
            //    握りつぶすのは、露出補正が書けなくても撮影自体は続けられるから。
        }
    }

    /// AE/AF のロックを解除して自動追従へ戻す。
    public func unlockFocusAndExposure() {
        sessionQueue.async {
            self.isFocusLocked = false
            // ロック直後（0.5 秒以内）の解除でも、固定の予約が後から刺さらないようにする。
            self.lockGeneration &+= 1
            // そのロック中に明るさを手動で動かしていたら 0 へ戻す（動かしていなければ何もしない）。
            if let device = self.videoDevice {
                self.endManualExposureOnSessionQueue(device: device)
            }
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
        // 予約した時点の世代を覚えておく（理由は `lockGeneration` のコメント）。
        let generation = lockGeneration
        sessionQueue.asyncAfter(deadline: .now() + 0.5) {
            // ⚠️ 0.5 秒の間に解除・掛け直し・レンズ付け替えがあれば、この予約はもう古い。
            //    確かめずに書くと、解除したのに固定される（取り消せないロック）。
            guard generation == self.lockGeneration, self.isFocusLocked else { return }
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

    // MARK: - 手動の明るさ調整（長押しロック中の ☀︎ ドラッグ）

    /// ロック中に動かせる明るさの「いまの値」と「動かせる範囲」を返す。
    ///
    /// ⭐️ ロックした直後に 1 回呼べば、それがそのままドラッグの開始値になる。
    ///    ロック中は空優先 AE が補正を書かない（`applyMeasuredClippingOnSessionQueue` の guard）
    ///    ので、ロック後に値を動かすのは手動だけ。ロック前に空優先 AE が掛けていた値
    ///    （例 -1.0）から始まるので、触った瞬間に明るさが跳ばない。
    /// ⚠️ 値は `appliedExposureBias`（このクラスが書いた記録）を返す。
    ///    `resetExposureBiasOnSessionQueue` などの判断もこの記録を正としているので、
    ///    端末の値を別に読むと記録とずれて「戻したつもりで戻っていない」が起きうる。
    /// - Returns: `bias` = いまかかっている補正値（EV）、
    ///   `range` = 動かせる範囲（端末と ±2 EV の狭い方）。デバイスが無い・範囲が壊れているなら nil
    public func manualExposureContext() async -> (bias: Float, range: ClosedRange<Float>?) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(bias: Float, range: ClosedRange<Float>?), Never>) in
            sessionQueue.async {
                let range = self.videoDevice.flatMap { device in
                    ManualExposure.range(deviceMin: device.minExposureTargetBias,
                                         deviceMax: device.maxExposureTargetBias)
                }
                continuation.resume(returning: (bias: self.appliedExposureBias, range: range))
            }
        }
    }

    /// ロック中の明るさ（露出補正）を手動で設定する。ドラッグ中に 60Hz で呼んでよい。
    ///
    /// ⚠️ 空優先 AE の補正に**足し合わせない**。ロック中は手動が補正値を丸ごと持つ
    ///    （呼び手は `manualExposureContext()` の値を開始値にして、絶対値で渡す）。
    /// ロックしていないときは何もしない（解除と入れ違いに届いた古い値を書かないため）。
    /// - Parameter bias: 設定したい補正値（EV）。範囲外なら範囲に収めてから書く
    public func setManualExposureBias(_ bias: Float) {
        pendingManualExposureLock.lock()
        let needsSchedule = pendingManualExposureBias == nil
        pendingManualExposureBias = bias
        pendingManualExposureLock.unlock()
        // 書き込みの予約がまだ残っていれば、その予約が最新値を拾うので積み増さない。
        guard needsSchedule else { return }
        sessionQueue.async { self.applyPendingManualExposureBiasOnSessionQueue() }
    }

    /// 預かっている最新の手動補正値を端末へ書く（sessionQueue 上で呼ぶこと）。
    private func applyPendingManualExposureBiasOnSessionQueue() {
        pendingManualExposureLock.lock()
        let pending = pendingManualExposureBias
        pendingManualExposureBias = nil
        pendingManualExposureLock.unlock()

        guard let pending, isFocusLocked, let device = videoDevice,
              let range = ManualExposure.range(deviceMin: device.minExposureTargetBias,
                                               deviceMax: device.maxExposureTargetBias) else { return }
        let bias = ManualExposure.clamp(pending, to: range)
        guard bias != appliedExposureBias else { return }
        // 記録と測光の一時停止は空優先 AE と同じ書き込み口を通す（道を 2 本にしない）。
        // ロック中は空優先 AE が止まっているので、測光の一時停止は無害。
        // ⚠️ `exposureMode == .locked` のままでも補正値は実際の露出に効く
        //    （AVCaptureDevice.h の setExposureTargetBias の説明）。モードは変えない。
        setExposureBiasOnSessionQueue(bias, device: device)
        // 書き込みに成功した（＝記録が更新された）ときだけ手動扱いにする。
        if appliedExposureBias == bias {
            hasManualExposureAdjustment = true
        }
    }

    /// ロックの終わりに、手動で動かした明るさを片付ける
    /// （sessionQueue 上、かつ lockForConfiguration の**外**で呼ぶこと）。
    ///
    /// ⭐️ **そのロック中に手動で動かしたときだけ** 0 へ戻す（理由は `ManualExposure.shouldResetOnUnlock`）。
    ///    0 へ戻した後は、空優先 AE が有効なら次の測光から通常どおり決め直す。
    private func endManualExposureOnSessionQueue(device: AVCaptureDevice) {
        defer { hasManualExposureAdjustment = false }
        guard ManualExposure.shouldResetOnUnlock(hasManualAdjustment: hasManualExposureAdjustment) else {
            return
        }
        setExposureBiasOnSessionQueue(0, device: device)
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

    private let completion: (Result<(data: Data, rawData: Data?, metadata: [String: Any]), Error>) -> Void

    /// 届いた DNG（RAW 撮影時のみ）。
    private var rawData: Data?

    /// 届いた現像済み画像と、その EXIF。
    /// ⚠️ RAW と現像済みの**到着順は保証されていない**ので、どちらも預かっておいて
    ///    「もうコールバックは来ない」と SDK が明言する時点でまとめて確定する。
    private var processedData: Data?
    private var processedMetadata: [String: Any] = [:]

    /// 1 回の撮影が完全に終わったときに呼ぶ後始末（デリゲートの解放）。
    private let onFinished: () -> Void

    /// 二重呼び出し防止（エラーと完了が両方来るケースがある）。
    /// ⚠️ `withCheckedThrowingContinuation` は二重 resume でクラッシュするので、
    ///    このフラグは「安全のための飾り」ではなく**落ちないための必須条件**。
    private var hasCompleted = false

    init(
        completion: @escaping (Result<(data: Data, rawData: Data?, metadata: [String: Any]), Error>) -> Void,
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

        if let error {
            hasCompleted = true
            completion(.failure(SkyCameraError.captureFailed(error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            // ⚠️ ここで失敗にしない。RAW 撮影では 2 枚届くので、片方が取れなくても
            //    もう片方で成立する可能性がある。取りこぼしは didFinishCaptureFor が拾う。
            return
        }
        // ⚠️ **ここでは確定しない。**
        //    以前は現像済みが届いた時点で確定していたが、RAW と現像済みの到着順は
        //    保証されていない。現像済みが先に来ると `rawData` が nil のまま成功が確定し、
        //    後から届く DNG が二重呼び出し防止に弾かれて**静かに消える**
        //    （RAW を選んだのに HEIC だけが保存される）。
        //    SDK は「もうコールバックは来ない」と明言する didFinishCaptureFor を
        //    用意しているので、両方そろうのをそこまで待つ。
        if photo.isRawPhoto {
            rawData = data
        } else {
            processedData = data
            processedMetadata = photo.metadata
        }
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
            if let data = processedData {
                // 現像済みが取れていれば成功。DNG は取れていれば一緒に返す。
                completion(.success((data: data, rawData: rawData, metadata: processedMetadata)))
            } else {
                let reason = error?.localizedDescription ?? "撮影が完了しませんでした"
                completion(.failure(SkyCameraError.captureFailed(reason)))
            }
        }
        onFinished()
    }
}
