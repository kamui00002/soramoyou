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
    /// 設定の保存先（テスト時に差し替えられるよう注入可能にしてある）。
    private let defaults: UserDefaults

    // MARK: - State

    @StateObject private var horizonMonitor = HorizonMonitor()
    @StateObject private var model: SkyCameraViewModel

    public init(
        gridDefaultsKey: String = "skyCamera.gridEnabled",
        horizonDefaultsKey: String = "skyCamera.horizonEnabled",
        skyPriorityDefaultsKey: String = "skyCamera.skyPriorityEnabled",
        defaults: UserDefaults = .standard,
        onCapture: @escaping (SkyCameraCapture) async -> Void,
        onCancel: @escaping () -> Void,
        onEvent: @escaping (SkyCameraEvent) -> Void
    ) {
        self.gridDefaultsKey = gridDefaultsKey
        self.horizonDefaultsKey = horizonDefaultsKey
        self.skyPriorityDefaultsKey = skyPriorityDefaultsKey
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
            skyPriorityEnabled: defaults.object(forKey: skyPriorityDefaultsKey) as? Bool ?? true
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
                shutterBar
            }
        }
        .statusBarHidden(true)
        .task {
            // 権限は呼び出し側（本体の「撮る」ボタン）で確認済みだが、
            // 未決定のまま開かれた場合にもここで確実に要求してから構成する。
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
        HStack(spacing: 20) {
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
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
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

    init(gridEnabled: Bool, horizonEnabled: Bool, skyPriorityEnabled: Bool) {
        self.gridEnabled = gridEnabled
        self.horizonEnabled = horizonEnabled
        self.skyPriorityEnabled = skyPriorityEnabled
    }

    /// 空優先 AE を切り替える。表示状態とセッション側の設定を必ず同時に動かす。
    func setSkyPriorityEnabled(_ enabled: Bool) {
        skyPriorityEnabled = enabled
        controller.setSkyPriorityExposureEnabled(enabled)
    }

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
            controller.start()
            usedDeferredStart = await controller.usedDeferredStart()
            isReady = true
        } catch {
            present(error: error)
        }
        return authorization
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
        let shutterDate = Date()
        do {
            let result = try await controller.capturePhoto(
                fallbackOrientation: Self.fallbackOrientation(for: reading)
            )
            let status = await controller.skyPriorityStatus()
            await handOff(SkyCameraCapture(
                photoData: result.data,
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
                skyPriorityMeasured: status.hasMeasured,
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
