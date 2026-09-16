// ⭐️ 空カメラの全画面 UI（撮る → 本体へ返すところまで）
import AVFoundation
import SwiftUI
import UIKit

/// 空カメラの画面。本体（そらもよう）からは `.fullScreenCover` で開く。
///
/// このパッケージは計装基盤に依存しないので、記録したいことは `onEvent` で本体へ渡す。
public struct SkyCameraView: View {

    // MARK: - Callbacks

    /// 撮影完了（撮影データ一式を本体へ渡す）。
    /// ⚠️ `async` なのは意図的。本体側の後処理（写真ライブラリ保存など）が終わるまで
    ///    撮影中フラグを下げないことで、処理中に閉じられて 1 枚失う事故を構造的に防ぐ。
    private let onCapture: (SkyCameraCapture) async -> Void
    /// 閉じる（撮らずに戻る）。
    private let onCancel: () -> Void
    /// 計装イベント。
    private let onEvent: (SkyCameraEvent) -> Void

    /// グリッド表示の保存先キー（本体の名前空間と衝突しないよう注入する）。
    private let gridDefaultsKey: String
    /// 水平線ガイド表示の保存先キー。
    private let horizonDefaultsKey: String
    /// 空優先 AE（白飛び防止）の保存先キー。
    private let skyPriorityDefaultsKey: String
    /// フラッシュ設定の保存先キー。
    private let flashDefaultsKey: String
    /// 記録形式の保存先キー。
    private let formatDefaultsKey: String
    /// 撮影解像度（幅で覚える）の保存先キー。
    private let resolutionDefaultsKey: String
    /// 設定の保存先（テスト時に差し替えられるよう注入可能にしてある）。
    private let defaults: UserDefaults

    // MARK: - State

    /// ピンチを始めたときの倍率（連続ズームの基準点）。
    @State private var pinchStartZoom: CGFloat?

    @StateObject private var horizonMonitor = HorizonMonitor()
    @StateObject private var model: SkyCameraViewModel

    public init(
        gridDefaultsKey: String = "skyCamera.gridEnabled",
        horizonDefaultsKey: String = "skyCamera.horizonEnabled",
        skyPriorityDefaultsKey: String = "skyCamera.skyPriorityEnabled",
        flashDefaultsKey: String = "skyCamera.flashMode",
        formatDefaultsKey: String = "skyCamera.photoFormat",
        resolutionDefaultsKey: String = "skyCamera.photoResolutionWidth",
        defaults: UserDefaults = .standard,
        onCapture: @escaping (SkyCameraCapture) async -> Void,
        onCancel: @escaping () -> Void,
        onEvent: @escaping (SkyCameraEvent) -> Void
    ) {
        self.gridDefaultsKey = gridDefaultsKey
        self.horizonDefaultsKey = horizonDefaultsKey
        self.skyPriorityDefaultsKey = skyPriorityDefaultsKey
        self.flashDefaultsKey = flashDefaultsKey
        self.formatDefaultsKey = formatDefaultsKey
        self.resolutionDefaultsKey = resolutionDefaultsKey
        self.defaults = defaults
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.onEvent = onEvent
        // 既定は両方 ON（「グリッド・水平線ガイド付き」が空カメラの売り）。
        // UserDefaults に値が無いときに false にならないよう、object(forKey:) で有無を見てから既定を決める。
        _model = StateObject(wrappedValue: SkyCameraViewModel(
            gridEnabled: defaults.object(forKey: gridDefaultsKey) as? Bool ?? true,
            horizonEnabled: defaults.object(forKey: horizonDefaultsKey) as? Bool ?? true,
            // 空優先 AE も既定 ON。「そらもようで撮ると空がちゃんと写る」が売りなので、
            // 既定で効いていないと大半のユーザーに価値が届かない。
            skyPriorityEnabled: defaults.object(forKey: skyPriorityDefaultsKey) as? Bool ?? true,
            // 空にフラッシュは届かないので既定はオフ。
            flashMode: (defaults.string(forKey: flashDefaultsKey))
                .flatMap(SkyCameraFlashMode.init(rawValue:)) ?? .off,
            photoFormat: defaults.string(forKey: formatDefaultsKey)
                .flatMap(SkyCameraPhotoFormat.init(rawValue:)) ?? .heic
        ))
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(
                session: model.controller.session,
                onTap: { devicePoint in model.focus(at: devicePoint) },
                onLongPress: { devicePoint in model.toggleLock(at: devicePoint) },
                // 横持ちでプレビュー映像が回らないのを防ぐため、層をコントローラへ結びつける。
                onPreviewReady: { view in model.controller.attachPreview(view) }
            )
            .ignoresSafeArea()
            // 標準カメラと同じピンチズーム。タップ（フォーカス）・長押し（AE/AFロック）とは
            // 種類の違うジェスチャなので、simultaneousGesture で並立させて奪い合わない。
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        guard let configuration = model.lensConfiguration else { return }
                        let start = pinchStartZoom ?? model.displayedZoom
                        if pinchStartZoom == nil { pinchStartZoom = start }
                        let lower = configuration.displayedZoom(forVideoZoomFactor: configuration.minFactor)
                        let upper = configuration.displayedZoom(forVideoZoomFactor: configuration.maxFactor)
                        model.setZoom(min(upper, max(lower, start * scale)), animated: false)
                    }
                    .onEnded { _ in pinchStartZoom = nil }
            )

            if model.gridEnabled {
                GridOverlay()
                    .ignoresSafeArea()
            }

            if model.horizonEnabled {
                HorizonGuideView(reading: horizonMonitor.reading)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                Spacer()
                if model.isLocked {
                    lockBadge
                }
                if let configuration = model.lensConfiguration {
                    ZoomControl(
                        configuration: configuration,
                        displayedZoom: $model.displayedZoom
                    ) { zoom, animated in
                        model.setZoom(zoom, animated: animated)
                    }
                    .padding(.bottom, 10)
                }
                shutterBar
            }
        }
        .statusBarHidden(true)
        .task {
            // 権限は呼び出し側（本体の「撮る」ボタン）で確認済みだが、
            // 未決定のまま開かれた場合にもここで確実に要求してから構成する。
            let savedWidth = defaults.object(forKey: resolutionDefaultsKey) as? Int
            model.preferredResolutionWidth = savedWidth.map(Int32.init)
            let authorization = await model.prepare()
            onEvent(.opened(authorization: authorization))
            if let failure = model.failureReason {
                onEvent(.failed(reason: failure))
            }
            horizonMonitor.start()
        }
        .onDisappear {
            horizonMonitor.stop()
            model.controller.stop()
        }
        .alert(model.isPermissionError ? "カメラを使えません" : "カメラエラー", isPresented: $model.isShowingError) {
            // 権限はアプリ側からは戻せないので、設定アプリへ送る導線を必ず出す
            //（本体の「撮る」ボタン側 `PostView.startCamera` と同じ作法に揃える）。
            if model.isPermissionError {
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    onCancel()
                }
            }
            Button("閉じる", role: .cancel) { onCancel() }
        } message: {
            Text(model.errorMessage ?? "カメラを利用できません。")
        }
    }

    // MARK: - Subviews

    /// 上部バー（閉じる・グリッド・水平線）。
    private var topBar: some View {
        // ⚠️ ボタンが増えたので間隔を詰める。44pt × 6 個 ＋ 間隔 6pt × 5 = 294pt で、
        //    いちばん狭い iPhone SE（375pt − 左右余白 40pt = 335pt）にも収まる。
        HStack(spacing: 6) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            // 撮影処理中に閉じられると、撮れた1枚が渡らないまま画面が消えてしまう。
            .disabled(model.isCapturing)
            .opacity(model.isCapturing ? 0.4 : 1)
            .accessibilityLabel("カメラを閉じる")

            Spacer()

            toggleButton(
                systemName: "grid",
                isOn: model.gridEnabled,
                label: "グリッド",
                hint: "グリッドの表示を切り替えます"
            ) {
                model.gridEnabled.toggle()
                defaults.set(model.gridEnabled, forKey: gridDefaultsKey)
            }

            toggleButton(
                systemName: "level",
                isOn: model.horizonEnabled,
                label: "水平線ガイド",
                hint: "水平線ガイドの表示を切り替えます"
            ) {
                model.horizonEnabled.toggle()
                defaults.set(model.horizonEnabled, forKey: horizonDefaultsKey)
            }

            toggleButton(
                systemName: "cloud.sun",
                isOn: model.skyPriorityEnabled,
                label: "空優先（白飛び防止）",
                hint: "空が白く飛ばないよう、撮影時の明るさを自動で下げます"
            ) {
                model.setSkyPriorityEnabled(!model.skyPriorityEnabled)
                defaults.set(model.skyPriorityEnabled, forKey: skyPriorityDefaultsKey)
            }

            // フラッシュを積んでいない端末ではボタン自体を出さない（押せても何も起きないため）。
            if model.isFlashAvailable {
                toggleButton(
                    systemName: model.flashMode.systemImageName,
                    isOn: model.flashMode != .off,
                    label: model.flashMode.label,
                    hint: "フラッシュを オフ→自動→オン の順に切り替えます"
                ) {
                    model.setFlashMode(model.flashMode.next)
                    defaults.set(model.flashMode.rawValue, forKey: flashDefaultsKey)
                }
            }

            formatButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// 記録形式と解像度のバッジ（iPhone 標準カメラの「HEIF 24」に相当）。
    /// アイコンでは伝わらない情報なので文字で出し、タップでメニューを開く。
    private var formatButton: some View {
        Menu {
            Section("記録形式") {
                ForEach(model.availableFormats, id: \.self) { format in
                    Button {
                        model.setPhotoFormat(format)
                        defaults.set(format.rawValue, forKey: formatDefaultsKey)
                    } label: {
                        Label(format.menuTitle,
                              systemImage: model.photoFormat == format ? "checkmark" : "")
                    }
                }
            }
            // 1 つしか無いときも節ごと出す。空欄だと「選べないのか壊れているのか」が
            // ユーザーにも開発者にも分からなくなる（実際それで原因の切り分けに手間取った）。
            if !model.photoResolutions.isEmpty {
                Section("解像度") {
                    ForEach(model.photoResolutions, id: \.self) { resolution in
                        Button {
                            model.setPhotoResolution(resolution)
                            defaults.set(Int(resolution.width), forKey: resolutionDefaultsKey)
                        } label: {
                            Label(resolution.label,
                                  systemImage: model.selectedResolution == resolution ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: {
            Text(formatBadgeText)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 64, height: 44)
                .background(Capsule().fill(.black.opacity(0.35)))
        }
        .accessibilityLabel("記録形式と解像度")
        .accessibilityValue(formatBadgeText)
        .accessibilityHint("写真の保存形式と解像度を選びます")
    }

    /// バッジの文字（例: "HEIC 12"）。解像度が 1 つしか無い端末では形式だけ出す。
    private var formatBadgeText: String {
        guard let megapixels = model.selectedResolution?.megapixels else {
            return model.photoFormat.label
        }
        return "\(model.photoFormat.label) \(megapixels)"
    }

    /// ON/OFF を色で示すトグルボタン。
    /// - Parameter hint: VoiceOver で読み上げる説明。グリッド等は「表示の切り替え」だが
    ///   空優先 AE は表示ではなく撮影時の露出制御なので、機能ごとに言い分ける必要がある。
    private func toggleButton(
        systemName: String,
        isOn: Bool,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundColor(isOn ? .yellow : .white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.black.opacity(0.35)))
        }
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "オン" : "オフ")
        .accessibilityHint(hint)
    }

    /// AE/AF ロック中であることを示すバッジ（標準カメラと同じ表現）。
    private var lockBadge: some View {
        Text("AE/AF ロック")
            .font(.caption.weight(.bold))
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.yellow))
            .padding(.bottom, 12)
            .accessibilityLabel("AE AF ロック中")
    }

    /// 下部のシャッターバー。
    private var shutterBar: some View {
        HStack {
            Spacer()
            Button {
                capture()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 4)
                        .frame(width: 74, height: 74)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 62, height: 62)
                }
            }
            .disabled(model.isCapturing || !model.isReady)
            .opacity(model.isReady ? 1 : 0.4)
            .accessibilityLabel("撮影")
            Spacer()
        }
        .padding(.bottom, 32)
    }

    // MARK: - Actions

    /// シャッター。撮影結果に「そのときの UI 状態」を添えて本体へ渡す。
    /// 受け渡し（`onCapture`）まで含めて ViewModel に任せることで、
    /// 後処理の途中で閉じられて撮れた 1 枚が消える経路を無くしている。
    private func capture() {
        let reading = horizonMonitor.reading
        Task {
            if let failure = await model.capture(reading: reading, handOff: onCapture) {
                onEvent(.failed(reason: failure))
            }
        }
    }
}

// MARK: - ViewModel

/// 画面状態とセッション制御の橋渡し。View を薄く保つために状態をここへ集約する。
@MainActor
final class SkyCameraViewModel: ObservableObject {

    /// セッション制御（プレビューへ渡すため公開）。
    let controller = CameraSessionController()

    @Published var gridEnabled: Bool
    @Published var horizonEnabled: Bool
    /// 空優先 AE（白飛び防止）が ON か。切り替えは `setSkyPriorityEnabled(_:)` を通す。
    @Published private(set) var skyPriorityEnabled: Bool

    /// 端末のレンズ構成。構成前と単眼端末では nil（＝ズーム UI を出さない）。
    @Published private(set) var lensConfiguration: LensConfiguration?

    /// いま表示している倍率。既定は標準カメラと同じ 1x。
    @Published var displayedZoom: CGFloat = 1

    /// フラッシュの動作。
    @Published private(set) var flashMode: SkyCameraFlashMode

    /// 記録形式。
    @Published private(set) var photoFormat: SkyCameraPhotoFormat

    /// この端末で選べる記録形式。RAW 非対応の端末では RAW を外す。
    @Published private(set) var availableFormats: [SkyCameraPhotoFormat] = [.heic, .jpeg]

    /// この端末でフラッシュを使えるか（使えないならボタンを出さない）。
    @Published private(set) var isFlashAvailable = false

    /// 選べる撮影解像度（小さい順）。
    @Published private(set) var photoResolutions: [SkyCameraPhotoResolution] = []

    /// いま選んでいる撮影解像度。
    @Published private(set) var selectedResolution: SkyCameraPhotoResolution?
    /// AE/AF ロック中か。
    @Published private(set) var isLocked = false
    /// 撮影処理中か（シャッターの二度押し防止）。
    @Published private(set) var isCapturing = false
    /// セッション構成が完了して撮れる状態か。
    @Published private(set) var isReady = false
    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?

    /// Deferred Start が有効だったか（計装用）。
    private var usedDeferredStart = false

    /// 直近の失敗理由（計装用の短いコード）。
    private(set) var failureReason: String?

    /// 直近の失敗が権限によるものか（「設定を開く」導線を出すかの判断に使う）。
    @Published private(set) var isPermissionError = false

    init(gridEnabled: Bool, horizonEnabled: Bool, skyPriorityEnabled: Bool,
         flashMode: SkyCameraFlashMode, photoFormat: SkyCameraPhotoFormat) {
        self.gridEnabled = gridEnabled
        self.horizonEnabled = horizonEnabled
        self.skyPriorityEnabled = skyPriorityEnabled
        self.flashMode = flashMode
        self.photoFormat = photoFormat
    }

    /// フラッシュの動作を変える。
    func setFlashMode(_ mode: SkyCameraFlashMode) {
        flashMode = mode
        controller.setFlashMode(mode)
    }

    /// 記録形式を切り替える。
    func setPhotoFormat(_ format: SkyCameraPhotoFormat) {
        photoFormat = format
        controller.setPhotoFormat(format)
    }

    /// 撮影解像度を選ぶ。
    func setPhotoResolution(_ resolution: SkyCameraPhotoResolution) {
        selectedResolution = resolution
        controller.setPhotoResolution(resolution)
    }

    /// 端末が返した一覧から、保存してある選択（無ければ最小）を復元する。
    func loadPhotoResolutions(preferredWidth: Int32?) async {
        let resolutions = await controller.photoResolutions()
        photoResolutions = resolutions
        // ⚠️ 既定を最小のままにしてある。ここを勝手に最大へ上げると、
        //    1 枚あたりのファイルが数倍になって写真ライブラリを静かに圧迫する。
        //    「今まで最小で撮っていた」という事実はユーザーへ伝えたうえで選ばせる。
        let restored = preferredWidth.flatMap { width in resolutions.first { $0.width == width } }
        guard let resolution = restored ?? resolutions.first else { return }
        selectedResolution = resolution
        controller.setPhotoResolution(resolution)
    }

    /// 空優先 AE を切り替える。表示状態とセッション側の設定を必ず同時に動かす。
    func setSkyPriorityEnabled(_ enabled: Bool) {
        skyPriorityEnabled = enabled
        controller.setSkyPriorityExposureEnabled(enabled)
    }

    /// 復元したい解像度の幅（View から渡す。UserDefaults はパッケージ側で持たない）。
    var preferredResolutionWidth: Int32?

    /// 権限確認 → セッション構成 → 開始。
    /// - Returns: そのときのカメラ権限の状態（計装用）
    func prepare() async -> SkyCameraAuthorization {
        var authorization = SkyCameraAvailability.authorization
        if authorization == .notDetermined {
            authorization = await SkyCameraAvailability.requestAuthorization()
        }
        guard authorization == .authorized else {
            // 「カメラが無い端末」と「ユーザーが拒否した」は原因も打ち手も違う。
            // 同じ理由コードに潰すと、計装でも画面でも区別が付かなくなる。
            present(error: SkyCameraError.permissionDenied)
            return authorization
        }
        do {
            try await controller.configure()
            // ⚠️ 構成の**後**に伝える。configure 前に呼んでも測光器がまだ存在しない。
            controller.setSkyPriorityExposureEnabled(skyPriorityEnabled)
            lensConfiguration = await controller.lensConfiguration()
            // 保存してある設定をセッションへ反映する（構成の後でないと出力が無い）。
            controller.setFlashMode(flashMode)
            controller.setPhotoFormat(photoFormat)
            isFlashAvailable = await controller.isFlashAvailable()
            // RAW を積んでいない端末ではメニューに出さない（選んでも撮れないため）。
            if await controller.isRAWAvailable() {
                availableFormats = [.heic, .jpeg, .raw]
            } else if photoFormat == .raw {
                // 以前 RAW を選んだ端末から機種変更した場合の保険。
                setPhotoFormat(.heic)
            }
            await loadPhotoResolutions(preferredWidth: preferredResolutionWidth)
            controller.start()
            usedDeferredStart = await controller.usedDeferredStart()
            isReady = true
        } catch {
            present(error: error)
        }
        return authorization
    }

    /// ズーム倍率を変える。表示とセッション側を必ず同時に動かす。
    func setZoom(_ zoom: CGFloat, animated: Bool) {
        displayedZoom = zoom
        controller.setZoom(displayedZoom: zoom, animated: animated)
    }

    /// タップ = その点に AF/AE を合わせる（ロック中なら解除する）。
    func focus(at devicePoint: CGPoint) {
        controller.focus(at: devicePoint, locked: false)
        if isLocked {
            isLocked = false
        }
    }

    /// 長押し = AE/AF ロック。ロック中に長押しすると解除する（標準カメラと同じ操作）。
    func toggleLock(at devicePoint: CGPoint) {
        if isLocked {
            controller.unlockFocusAndExposure()
            isLocked = false
        } else {
            controller.focus(at: devicePoint, locked: true)
            isLocked = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// 撮影して、その場で本体へ受け渡すところまでを 1 本にする。
    ///
    /// ⚠️ `handOff` が終わるまで `isCapturing` を下げない。
    ///    ここを分けて先に下げると、本体側の後処理（写真ライブラリ保存。初回は権限プロンプトが出る）
    ///    の最中に閉じるボタンが有効になり、撮れた 1 枚が誰にも渡らないまま消える。
    /// - Parameters:
    ///   - reading: シャッターを切った瞬間の傾き
    ///   - handOff: 撮影結果の受け取り手（本体側の後処理）
    /// - Returns: 失敗した場合の理由コード。成功なら nil
    func capture(
        reading: HorizonMath.Reading,
        handOff: (SkyCameraCapture) async -> Void
    ) async -> String? {
        guard !isCapturing, isReady else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        // ⚠️ 撮影処理中もトグルは操作できるので、ここで固定する。
        //    撮影後に読むと「撮った写真とは違う瞬間の設定」を記録してしまう。
        let skyPriorityAtShutter = skyPriorityEnabled
        let zoomAtShutter = displayedZoom
        let shutterDate = Date()
        do {
            let result = try await controller.capturePhoto(
                fallbackOrientation: Self.fallbackOrientation(for: reading)
            )
            let status = await controller.skyPriorityStatus()
            await handOff(SkyCameraCapture(
                photoData: result.data,
                rawPhotoData: result.rawData,
                metadata: result.metadata,
                gridEnabled: gridEnabled,
                horizonEnabled: horizonEnabled,
                aeAfLocked: isLocked,
                isLevel: reading.isLevel,
                rollDegrees: reading.isReliable ? reading.rollDegrees : nil,
                usedDeferredStart: usedDeferredStart,
                skyPriorityEnabled: skyPriorityAtShutter,
                // ⭐️ 実測値（撮れた 1 枚の EXIF）を正とする。要求値ではないので、
                //    撮影処理中の測光や AE ロックによるズレの影響を受けない。
                //    EXIF に無い端末のための保険としてのみ現在値へ落とす。
                exposureBiasEV: SkyPriorityExposure.exposureBias(fromMetadata: result.metadata)
                    ?? status.bias,
                zoomDisplayed: Double(zoomAtShutter),
                photoMegapixels: selectedResolution?.megapixels ?? 0,
                availableMegapixels: photoResolutions.map { String($0.megapixels) }
                    .joined(separator: ","),
                photoFormat: photoFormat,
                skyPriorityMeasured: status.hasMeasured,
                skyClippedFraction: status.clippedFraction,
                skyPeakLuma: Int(status.peakLuma),
                skyMaxClippedFraction: status.maxClippedFraction,
                skyMaxPeakLuma: Int(status.maxPeakLuma),
                shutterDate: shutterDate
            ))
            return nil
        } catch {
            present(error: error)
            return failureReason
        }
    }

    /// iOS 16 用の撮影向き（重力から求めた端末の向き）。
    /// ⚠️ 端末の向きと映像の向きはランドスケープで**左右が入れ替わる**（AVFoundation の仕様）。
    ///    例: 端末が landscapeLeft のとき、映像は landscapeRight で立つ。
    private static func fallbackOrientation(for reading: HorizonMath.Reading) -> AVCaptureVideoOrientation {
        switch reading.orientation {
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft:      return .landscapeRight
        case .landscapeRight:     return .landscapeLeft
        }
    }

    /// エラーを画面と計装の両方へ流す。
    private func present(error: Error) {
        let skyError = error as? SkyCameraError
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failureReason = skyError?.reasonCode ?? "unknown"
        isPermissionError = skyError?.isPermissionDenied ?? false
        isShowingError = true
        // ⚠️ 一時的な失敗では撮影可否を落とさない。
        //    中断中にシャッターを押した 1 回で `isReady` を false にすると、
        //    中断が明けてセッションが戻っても撮れないまま（開き直すしかなくなる）。
        if skyError?.isTransient != true {
            isReady = false
        }
    }
}
