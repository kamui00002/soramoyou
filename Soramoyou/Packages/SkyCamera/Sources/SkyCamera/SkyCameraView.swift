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
    private let onCapture: (SkyCameraCapture) -> Void
    /// 閉じる（撮らずに戻る）。
    private let onCancel: () -> Void
    /// 計装イベント。
    private let onEvent: (SkyCameraEvent) -> Void

    /// グリッド表示の保存先キー（本体の名前空間と衝突しないよう注入する）。
    private let gridDefaultsKey: String
    /// 水平線ガイド表示の保存先キー。
    private let horizonDefaultsKey: String
    /// 設定の保存先（テスト時に差し替えられるよう注入可能にしてある）。
    private let defaults: UserDefaults

    // MARK: - State

    @StateObject private var horizonMonitor = HorizonMonitor()
    @StateObject private var model: SkyCameraViewModel

    public init(
        gridDefaultsKey: String = "skyCamera.gridEnabled",
        horizonDefaultsKey: String = "skyCamera.horizonEnabled",
        defaults: UserDefaults = .standard,
        onCapture: @escaping (SkyCameraCapture) -> Void,
        onCancel: @escaping () -> Void,
        onEvent: @escaping (SkyCameraEvent) -> Void
    ) {
        self.gridDefaultsKey = gridDefaultsKey
        self.horizonDefaultsKey = horizonDefaultsKey
        self.defaults = defaults
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.onEvent = onEvent
        // 既定は両方 ON（「グリッド・水平線ガイド付き」が空カメラの売り）。
        // UserDefaults に値が無いときに false にならないよう、object(forKey:) で有無を見てから既定を決める。
        _model = StateObject(wrappedValue: SkyCameraViewModel(
            gridEnabled: defaults.object(forKey: gridDefaultsKey) as? Bool ?? true,
            horizonEnabled: defaults.object(forKey: horizonDefaultsKey) as? Bool ?? true
        ))
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(
                session: model.controller.session,
                onTap: { devicePoint in model.focus(at: devicePoint, locked: false) },
                onLongPress: { devicePoint in model.toggleLock(at: devicePoint) }
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
        .alert("カメラエラー", isPresented: $model.isShowingError) {
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
            .accessibilityLabel("カメラを閉じる")

            Spacer()

            toggleButton(
                systemName: "grid",
                isOn: model.gridEnabled,
                label: "グリッド"
            ) {
                model.gridEnabled.toggle()
                defaults.set(model.gridEnabled, forKey: gridDefaultsKey)
            }

            toggleButton(
                systemName: "level",
                isOn: model.horizonEnabled,
                label: "水平線ガイド"
            ) {
                model.horizonEnabled.toggle()
                defaults.set(model.horizonEnabled, forKey: horizonDefaultsKey)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// ON/OFF を色で示すトグルボタン。
    private func toggleButton(
        systemName: String,
        isOn: Bool,
        label: String,
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
        .accessibilityHint("\(label)の表示を切り替えます")
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
    private func capture() {
        let reading = horizonMonitor.reading
        Task {
            if let capture = await model.capture(reading: reading) {
                onCapture(capture)
            } else if let failure = model.failureReason {
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

    init(gridEnabled: Bool, horizonEnabled: Bool) {
        self.gridEnabled = gridEnabled
        self.horizonEnabled = horizonEnabled
    }

    /// 権限確認 → セッション構成 → 開始。
    /// - Returns: そのときのカメラ権限の状態（計装用）
    func prepare() async -> SkyCameraAuthorization {
        var authorization = SkyCameraAvailability.authorization
        if authorization == .notDetermined {
            authorization = await SkyCameraAvailability.requestAuthorization()
        }
        guard authorization == .authorized else {
            present(error: SkyCameraError.deviceUnavailable)
            return authorization
        }
        do {
            try await controller.configure()
            controller.start()
            usedDeferredStart = await controller.usedDeferredStart()
            isReady = true
        } catch {
            present(error: error)
        }
        return authorization
    }

    /// タップ = その点に AF/AE（ロックは解除）。
    func focus(at devicePoint: CGPoint, locked: Bool) {
        controller.focus(at: devicePoint, locked: locked)
        if isLocked && !locked {
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

    /// 撮影。失敗時は nil を返し `failureReason` に理由を残す。
    func capture(reading: HorizonMath.Reading) async -> SkyCameraCapture? {
        guard !isCapturing, isReady else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        let shutterDate = Date()
        do {
            let result = try await controller.capturePhoto(
                fallbackOrientation: Self.fallbackOrientation(for: reading)
            )
            #if DEBUG
            // 実機で `{Exif}.DateTimeOriginal` が載っているかを確認するための開発用ログ。
            // キー名だけを出すので写真の内容や位置情報は残らない。
            print("📷 SkyCamera metadata keys=\(result.metadata.keys.sorted())")
            if let exif = result.metadata["{Exif}"] as? [String: Any] {
                print("📷 SkyCamera {Exif} keys=\(exif.keys.sorted())")
            }
            #endif
            return SkyCameraCapture(
                photoData: result.data,
                metadata: result.metadata,
                gridEnabled: gridEnabled,
                horizonEnabled: horizonEnabled,
                aeAfLocked: isLocked,
                isLevel: reading.isLevel,
                rollDegrees: reading.isReliable ? reading.rollDegrees : nil,
                usedDeferredStart: usedDeferredStart,
                shutterDate: shutterDate
            )
        } catch {
            present(error: error)
            return nil
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
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failureReason = (error as? SkyCameraError)?.reasonCode ?? "unknown"
        isShowingError = true
        isReady = false
    }
}
