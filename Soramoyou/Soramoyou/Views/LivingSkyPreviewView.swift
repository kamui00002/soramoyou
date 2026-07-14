// ⭐️ LivingSkyPreviewView.swift
// Living Sky（空のループアニメーション）のプロトタイプ用プレビュー画面（段階2）
//
//  LivingSkyPreviewView.swift
//  Soramoyou
//
// 設計書: docs/living-sky-design.md §4（プレビュー・カクつかない）§6（パラメータ）
//
// ⚠️ これは「段階2: シェーダ＋Engine＋簡易プレビューのプロトタイプ」用の最小限 UI。
//    本番 UI（フィルター/編集ツールと並ぶ導線・デザイン調整）は後段階で作り込む前提。

import SwiftUI
import MetalKit
import CoreImage

// MARK: - LivingSkySheet（プロトタイプ用シート画面）

/// Living Sky のプレビュー＋4スライダー＋閉じるボタンだけの簡素なシート。
/// `EditView` から `#if DEBUG` ゲートで提示される（本プロンプト仕様のエントリポイント参照）。
struct LivingSkySheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = LivingSkyController()

    /// 元にする写真（編集済みプレビュー、無ければ元画像）
    let sourceImage: UIImage

    // MARK: - 段階4: mp4 書き出し用の State

    /// 書き出し中フラグ（true の間はボタンを無効化し ProgressView を表示する）
    @State private var isExporting = false
    /// 書き出し進捗 0...1（`LivingSkyVideoExporter.renderVideo` の progress コールバックから更新）
    @State private var exportProgress: Double = 0
    /// 書き出し結果メッセージ（成功/失敗どちらもこのアラートで表示する）
    @State private var exportResultMessage: String?
    /// 書き出し結果アラートの表示フラグ
    @State private var showExportResultAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                previewArea
                Divider().background(Color.white.opacity(0.2))
                controlsArea
            }
            .background(Color.black)
            .navigationTitle("Living Sky（プロトタイプ）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear {
            controller.start(with: sourceImage)
        }
        .alert(exportResultMessage ?? "", isPresented: $showExportResultAlert) {
            Button("OK") {}
        }
    }

    // MARK: - 段階4: mp4 書き出し

    /// 「動画を保存」ボタンのアクション。
    ///
    /// プレビュー用の `controller.engine`（`.preview` 品質・長辺1080）とは別に、
    /// 書き出し専用の新しい `LivingSkyEngine` インスタンスを作り `.export` 品質（長辺1920）で
    /// `prepare` する（プレビューengineとは別物。パラメータは現在の controller.parameters をコピー）。
    private func startExport() {
        guard !isExporting else { return }
        isExporting = true
        exportProgress = 0

        Task {
            defer { isExporting = false }
            do {
                let exportEngine = LivingSkyEngine()
                exportEngine.parameters = controller.parameters
                try await exportEngine.prepare(image: sourceImage, quality: .export)

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mp4")

                let exporter = LivingSkyVideoExporter()
                try await exporter.renderVideo(to: tempURL, engine: exportEngine) { value in
                    Task { @MainActor in
                        exportProgress = value
                    }
                }
                try await exporter.saveToPhotos(fileURL: tempURL)

#if DEBUG
                // 私（レビュアー）の E2E 検証用に一時ファイルのパスをログ出力する。
                // `LivingSkyVideoExporter.saveToPhotos` は DEBUG ビルドでは保存成功後も
                // 一時ファイルを削除しない設計のため、このパスから実ファイルを確認できる。
                print("LivingSkyExport: \(tempURL.path)")
#endif

                exportResultMessage = "写真に保存したわ"
                showExportResultAlert = true
            } catch {
                exportResultMessage = error.localizedDescription
                showExportResultAlert = true
            }
        }
    }

    // MARK: - プレビュー領域

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            Color.black

            switch controller.state {
            case .idle, .preparing:
                ProgressView("空を解析中…")
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .foregroundColor(.white)

            case .unavailable(let message), .failed(let message):
                unavailableMessage(message)

            case .ready:
                readyPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Engine 準備完了後のプレビュー本体（MTKView + 低信頼度バッジ）
    @ViewBuilder
    private var readyPreview: some View {
        LivingSkyMetalView(engine: controller.engine)
            .aspectRatio(controller.previewAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        // 設計書§7: ヒューリスティックマスクの誤判定リスク（地上がゆらぐ）への対策として、
        // confidence が低い（=白黒つけにくい判定が多い写真）ときは警告バッジを出す。
        // プレビュー自体は止めない（「メッセージ表示」の範囲に留める）。
        if controller.engine.maskConfidence < LivingSkyEngine.lowConfidenceThreshold {
            VStack {
                Spacer()
                Text("⚠️ 空の判定精度が低い写真です。動きが不自然に見える場合があります")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                    .padding(.bottom, 16)
            }
        }
    }

    private func unavailableMessage(_ message: String) -> some View {
        Text(message)
            .font(.body)
            .foregroundColor(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    // MARK: - コントロール領域（4スライダー）

    private var controlsArea: some View {
        VStack(spacing: 16) {
            sliderRow(
                title: "風向き",
                valueText: "\(Int(controller.parameters.windAngleDegrees))°",
                value: Binding(
                    get: { controller.parameters.windAngleDegrees },
                    set: { controller.parameters.windAngleDegrees = $0 }
                ),
                range: 0...359
            )
            sliderRow(
                title: "速さ",
                valueText: String(format: "%.2f", controller.parameters.speed),
                value: Binding(
                    get: { controller.parameters.speed },
                    set: { controller.parameters.speed = $0 }
                ),
                range: 0.1...1.0
            )
            sliderRow(
                title: "光のゆらぎ",
                valueText: String(format: "%.2f", controller.parameters.shimmerAmount),
                value: Binding(
                    get: { controller.parameters.shimmerAmount },
                    set: { controller.parameters.shimmerAmount = $0 }
                ),
                range: 0...0.10
            )
            sliderRow(
                title: "ループ長",
                valueText: String(format: "%.1fs", controller.parameters.loopDuration),
                value: Binding(
                    get: { controller.parameters.loopDuration },
                    set: { controller.parameters.loopDuration = $0 }
                ),
                range: 6...10
            )

            exportButton
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color.black)
    }

    /// 段階4: mp4 書き出しボタン（スライダーの下に配置）。
    /// 書き出し中は ProgressView（%表示）に切り替え、ボタンを無効化する。プレビューは動かしたままでよい。
    @ViewBuilder
    private var exportButton: some View {
        Button(action: { startExport() }) {
            if isExporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("書き出し中… \(Int(exportProgress * 100))%")
                        .monospacedDigit()
                }
            } else {
                Text("動画を保存（8秒ループ）")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundColor(.white)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color.white.opacity(0.15)))
        .disabled(isExporting || controller.state != .ready)
        .padding(.top, 4)
    }

    /// スライダー1行分（タイトル・現在値・スライダー本体）
    private func sliderRow(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
                Text(valueText)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(.white)
        }
    }
}

// MARK: - LivingSkyController（Engine のライフサイクル管理）

/// `LivingSkyEngine` の準備状態・パラメータ変更を SwiftUI から扱うためのコントローラ。
///
/// `LivingSkyEngine` 自体は ObservableObject ではない（画像処理エンジンに SwiftUI 依存を
/// 持ち込みたくないため）ので、この薄いラッパーが `@Published` 状態を仲介する。
@MainActor
final class LivingSkyController: ObservableObject {

    /// 準備状態
    enum State: Equatable {
        case idle
        case preparing
        case ready
        /// Metal カーネル自体が使用不可（機種非対応・metallib ロード失敗）
        case unavailable(String)
        /// `prepare` 実行時にエラーが発生した
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// ユーザー可変パラメータ。変更すると即座に `engine.parameters` へ反映される
    /// （マスク再生成は発生しない。設計書§4「パラメータ変更は uniform 変更のみ」）。
    @Published var parameters = LivingSkyParameters() {
        didSet { engine.parameters = parameters }
    }

    /// 1枚の写真につき1インスタンス生成する Engine
    let engine = LivingSkyEngine()

    /// プレビューのアスペクト比（幅/高さ）。`prepare` 完了まで正方形扱いの 1 を返す。
    var previewAspectRatio: CGFloat {
        guard let extent = engine.preparedPhoto?.extent, extent.height > 0 else { return 1 }
        return extent.width / extent.height
    }

    /// 準備を開始する。Metal 非対応なら即座に `.unavailable` へ遷移し `prepare` は呼ばない
    /// （設計書§1「Metal 必須: kernel ロード失敗時はフォールバックせず機能を非表示」）。
    func start(with image: UIImage) {
        guard state == .idle else { return }

        guard engine.isAvailable else {
            state = .unavailable("この端末では Living Sky を利用できません（Metal 非対応）")
            return
        }

        state = .preparing
        Task {
            do {
                try await engine.prepare(image: image)
                state = .ready
            } catch {
                state = .failed("空の解析に失敗しました: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - LivingSkyMetalView（MTKView ラッパー）

/// `LivingSkyEngine.makeFrame` を毎フレーム直接 GPU テクスチャへ描画する MTKView ラッパー。
///
/// 設計書§4「プレビュー（カクつかない）」の核: 毎フレームの CGImage/UIImage 変換をせず、
/// `CIContextPool.shared.ciContext` から `CIRenderDestination` 経由で drawable のテクスチャへ
/// 直接描画する。
struct LivingSkyMetalView: UIViewRepresentable {
    let engine: LivingSkyEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = CIContextPool.shared.mtlDevice
        view.delegate = context.coordinator
        // CIContext が drawable のテクスチャへ直接書き込むため、Metal 標準の
        // フレームバッファ経由の描画（framebufferOnly=true の最適化）を無効化する必要がある。
        view.framebufferOnly = false
        // preferredFramesPerSecond に沿って継続的に draw(in:) を呼ばせる
        // （setNeedsDisplay 方式だとパラメータ変更時にしか再描画されずアニメーションが動かない）。
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // engine インスタンスはシート表示中固定のため、ここで差し替える更新は無い。
        // パラメータ変更は `LivingSkyController` → `engine.parameters` を直接更新する経路
        // （uniform 変更のみ）で反映されるため、View 側の再構築は不要。
    }

    // MARK: - Coordinator（MTKViewDelegate）

    final class Coordinator: NSObject, MTKViewDelegate {
        private let engine: LivingSkyEngine
        private let commandQueue: MTLCommandQueue?
        private let ciContext = CIContextPool.shared.ciContext
        /// プレビュー開始時刻。経過秒を `LivingSkyEngine.makeFrame(elapsed:)` に渡す。
        private let startDate = Date()

        init(engine: LivingSkyEngine) {
            self.engine = engine
            self.commandQueue = CIContextPool.shared.mtlDevice?.makeCommandQueue()
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // アスペクト比は SwiftUI 側の `.aspectRatio` で管理しているため、ここでは何もしない。
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandQueue = commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            let elapsed = Date().timeIntervalSince(startDate)
            guard let frame = engine.makeFrame(elapsed: elapsed) else {
                return
            }

            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            // アスペクト比を保った中央配置（アスペクト比が僅かにずれるケースの保険として、
            // SwiftUI 側の `.aspectRatio` と二重にレターボックス計算する）。
            let extent = frame.extent
            guard extent.width > 0, extent.height > 0 else { return }
            let scale = min(drawableSize.width / extent.width, drawableSize.height / extent.height)
            let offsetX = (drawableSize.width - extent.width * scale) / 2 - extent.minX * scale
            let offsetY = (drawableSize.height - extent.height * scale) / 2 - extent.minY * scale
            let transform = CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
            let placed = frame.transformed(by: transform)

            // drawable 全面を黒で塗ってからフレームを合成する（アスペクト比が drawable と
            // 一致しない場合のレターボックス部分を黒く保つため）。
            let background = CIImage(color: .black)
                .cropped(to: CGRect(origin: .zero, size: drawableSize))
            let composed = placed.composited(over: background)
                .cropped(to: CGRect(origin: .zero, size: drawableSize))

            let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
            destination.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)

            do {
                _ = try ciContext.startTask(toRender: composed, to: destination)
            } catch {
                // 描画失敗時は今フレームをスキップして次フレームへ続行する（クラッシュさせない）。
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
