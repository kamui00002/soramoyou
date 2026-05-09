// ⭐️ Style2DPadView.swift
// 2D スタイルパッド（iPhone 写真スタイル風 UI）— v2 (プリセットサムネイルカルーセル付き)
//
// X 軸: カラー (-1...1) — 寒色 ↔ 暖色
// Y 軸: トーン (-1...1) — 下=フラット ↔ 上=コントラスト強化
//
// 1 つの白丸ハンドルをドラッグするだけで「トーン」と「カラー」を同時に調整できる。
// v2 では左右にプリセットサムネイル列を追加し、タップで瞬時にスタイルへスナップできる。
// 既存の 27 ツール（個別スライダー）とは独立した複合ツールで、
// パイプライン末尾で適用される。
//
//  そらもよう - 空を撮る、空を集める

import SwiftUI
import UIKit

// MARK: - StylePreset

/// 2D スタイルパッドのプリセット位置
///
/// iPhone 写真スタイルの「リッチコントラスト / ウォーム / クール」等に相当する
/// 固定座標を持ったプリセット集合。カルーセルでサムネイル表示し、タップで
/// パッドの白丸を当該位置にスナップする。
///
/// 中央の「標準」(0, 0) は明示的なプリセットとして含めず、パッド本体がその役割を担う。
private enum StylePreset: String, CaseIterable, Identifiable {
    case dramaCool = "ドラマ寒"
    case cool      = "クール"
    case fade      = "フェード"
    case warm      = "ウォーム"
    case rich      = "リッチ"
    case dramaWarm = "ドラマ暖"

    var id: String { rawValue }

    /// トーン軸 (Y) の正規化値 (-1.0...1.0)
    var toneNorm: Float {
        switch self {
        case .dramaCool: return -0.6
        case .cool:      return -0.3
        case .fade:      return -0.5
        case .warm:      return  0.2
        case .rich:      return  0.6
        case .dramaWarm: return  0.7
        }
    }

    /// カラー軸 (X) の正規化値 (-1.0...1.0)
    var colorNorm: Float {
        switch self {
        case .dramaCool: return -0.7
        case .cool:      return -0.5
        case .fade:      return -0.1
        case .warm:      return  0.5
        case .rich:      return  0.2
        case .dramaWarm: return  0.7
        }
    }

    /// パッドの左側に並べるプリセット (X<=0 寄り)
    static let leftPresets: [StylePreset] = [.dramaCool, .cool, .fade]
    /// パッドの右側に並べるプリセット (X>=0 寄り)
    static let rightPresets: [StylePreset] = [.warm, .rich, .dramaWarm]
}

// MARK: - Style2DPadView

/// 2D スタイルパッド本体 (v2)
///
/// 構成:
/// 1. ヘッダー: 「トーン XX カラー XX ↺」の数値表示 + リセットボタン
/// 2. 現在のプリセット名ラベル (近接判定で「標準」「リッチ」等を表示)
/// 3. 横スクロールカルーセル: 左 3 サムネイル + 中央パッド + 右 3 サムネイル
struct Style2DPadView: View {

    // MARK: - 依存

    @ObservedObject var viewModel: EditViewModel

    /// プリセットサムネイルを生成するための ImageService
    /// EditViewModel 内の imageService は private のため、ここでは独自インスタンスを保持
    private let imageService: ImageServiceProtocol = ImageService()

    // MARK: - レイアウト定数

    /// パッドの一辺サイズ（pt）
    private let padSize: CGFloat = 200
    /// ハンドル（白丸）の直径（pt）
    private let thumbSize: CGFloat = 18
    /// ドット格子の縦横の数（奇数推奨で中心が点になる）
    private let dotCount: Int = 13
    /// プリセットサムネイル一辺サイズ（pt）
    private let presetThumbDisplaySize: CGFloat = 64
    /// プリセットサムネイル生成時のピクセルサイズ（高 DPI 用）
    private let presetThumbGenerateSize = CGSize(width: 200, height: 200)
    /// プリセットが「現在選択中」とみなす近接閾値
    private let presetMatchThreshold: Float = 0.05

    // MARK: - 状態

    /// 生成済みプリセットサムネイルのキャッシュ
    /// キー: StylePreset.id (rawValue)、値: 適用後のサムネイル画像
    @State private var presetThumbnails: [String: UIImage] = [:]
    /// サムネイル生成中フラグ (UI 表示用)
    @State private var isGeneratingThumbnails: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 14) {
            headerBar
                .padding(.top, 8)

            currentPresetLabel

            carouselView

            Spacer(minLength: 0)
        }
        // 画像インデックス変化時に自動的に再生成（古いタスクは自動キャンセル）
        .task(id: viewModel.currentImageIndex) {
            await regeneratePresetThumbnails()
        }
    }

    // MARK: - ヘッダー

    /// 「トーン XX | カラー XX | ↺」のヘッダーバー
    ///
    /// 既存の improvedSliderView (EditView.swift) のヘッダー意匠に揃え、
    /// 半透明カプセル背景 + モノスペース数値で読みやすさを確保する。
    private var headerBar: some View {
        HStack(spacing: 16) {
            // トーン値
            valueChip(label: "トーン", value: currentToneInt)

            // カラー値
            valueChip(label: "カラー", value: currentColorInt)

            // リセットボタン（↺）
            Button(action: handleResetTapped) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.callout.weight(.semibold))
                    .foregroundColor(isAtZero ? .white.opacity(0.3) : .white)
                    .frame(width: 28, height: 28)
            }
            .disabled(isAtZero)
            .accessibilityLabel("スタイルをリセット")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(Color.white.opacity(0.08))
        )
    }

    /// 「ラベル 値」のチップ部品
    private func valueChip(label: String, value: Int) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
            Text(formatValue(value))
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.white)
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    // MARK: - 現在のプリセット名ラベル

    /// 現在の (toneNorm, colorNorm) に最も近いプリセット名を表示
    ///
    /// - 0,0 付近 → 「標準」
    /// - プリセットに近接 → そのプリセット名
    /// - どこにも近くない → 「カスタム」
    private var currentPresetLabel: some View {
        Text(currentPresetName)
            .font(.subheadline.weight(.medium))
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.white.opacity(0.05))
            )
            .accessibilityLabel("現在のスタイル: \(currentPresetName)")
    }

    private var currentPresetName: String {
        if isAtZero { return "標準" }
        if let preset = matchedPreset { return preset.rawValue }
        return "カスタム"
    }

    /// 現在の (tone, color) と近接するプリセットを返す（閾値内のもののみ）
    private var matchedPreset: StylePreset? {
        StylePreset.allCases.first { isOnPreset($0) }
    }

    private func isOnPreset(_ preset: StylePreset) -> Bool {
        abs(currentTone - preset.toneNorm) < presetMatchThreshold &&
        abs(currentColor - preset.colorNorm) < presetMatchThreshold
    }

    // MARK: - カルーセル (左サムネイル + パッド + 右サムネイル)

    /// 横スクロールカルーセル
    ///
    /// 初期表示時はパッドが中央に来るよう ScrollViewReader でスクロール位置を調整。
    /// プリセットサムネイルをタップすると updateStyle2DRealtime + finalizeStyle2D で
    /// パッドの白丸が当該座標へスナップ移動する。
    private var carouselView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // 左サムネイル群 (X<=0 寄りのプリセット)
                    ForEach(StylePreset.leftPresets) { preset in
                        presetThumbnailButton(preset)
                    }

                    // 区切り線
                    verticalSeparator

                    // 中央: 既存の 2D パッド
                    padView
                        .id("pad")

                    // 区切り線
                    verticalSeparator

                    // 右サムネイル群 (X>=0 寄りのプリセット)
                    ForEach(StylePreset.rightPresets) { preset in
                        presetThumbnailButton(preset)
                    }
                }
                .padding(.horizontal, 24)
            }
            .onAppear {
                // 表示時にパッドが画面中央に来るようスクロール
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("pad", anchor: .center)
                    }
                }
            }
        }
    }

    /// 縦の区切り線（パッドとサムネイル群の間に置く視覚的区切り）
    private var verticalSeparator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 1, height: 60)
            .padding(.horizontal, 4)
    }

    /// プリセットサムネイルボタン
    private func presetThumbnailButton(_ preset: StylePreset) -> some View {
        Button(action: { handlePresetTapped(preset) }) {
            presetThumbnailContent(preset)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.rawValue) スタイル")
    }

    /// プリセットサムネイル本体（画像 + ハイライト枠）
    @ViewBuilder
    private func presetThumbnailContent(_ preset: StylePreset) -> some View {
        let isSelected = isOnPreset(preset)

        ZStack {
            // 角丸の背景（画像未生成時のプレースホルダ兼用）
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.08))
                .frame(width: presetThumbDisplaySize, height: presetThumbDisplaySize)

            // 生成済みサムネイル画像
            if let image = presetThumbnails[preset.id] {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: presetThumbDisplaySize, height: presetThumbDisplaySize)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if isGeneratingThumbnails {
                // 生成中の表示
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.white.opacity(0.5))
            }

            // 選択中ハイライト枠
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Color.white : Color.white.opacity(0.15),
                    lineWidth: isSelected ? 2 : 0.5
                )
                .frame(width: presetThumbDisplaySize, height: presetThumbDisplaySize)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    // MARK: - 2D パッド

    /// パッド本体（背景 + ドット格子 + 白丸ハンドル + ドラッグ）
    private var padView: some View {
        ZStack {
            // 1. 角丸の半透明背景
            RoundedRectangle(cornerRadius: 28)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )

            // 2. ドット格子（Canvas で軽量描画）
            Canvas { context, size in
                drawDotGrid(context: context, size: size)
            }
            .padding(12)
            .allowsHitTesting(false)

            // 3. 白丸ハンドル
            Circle()
                .fill(Color.white)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
                .offset(thumbOffset)
                .animation(
                    viewModel.isEditingRealtime ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.85),
                    value: thumbOffset
                )
                .allowsHitTesting(false)
        }
        .frame(width: padSize, height: padSize)
        .contentShape(RoundedRectangle(cornerRadius: 28))
        .gesture(dragGesture)
    }

    /// ドット格子を Canvas で描画
    ///
    /// - 中心ドット（ハンドルの初期位置と重なる）は描画しない（視認性のため）
    /// - 中心十字ライン上の点を少し大きめにし、座標感覚を与える
    private func drawDotGrid(context: GraphicsContext, size: CGSize) {
        let spacing = size.width / CGFloat(dotCount + 1)
        let centerIndex = (dotCount + 1) / 2

        for row in 1...dotCount {
            for col in 1...dotCount {
                // 中心はハンドルが立つので省略
                if row == centerIndex && col == centerIndex { continue }

                let x = CGFloat(col) * spacing
                let y = CGFloat(row) * spacing

                let onCenterAxis = (row == centerIndex || col == centerIndex)
                let radius: CGFloat = onCenterAxis ? 1.4 : 1.0
                let opacity: Double = onCenterAxis ? 0.55 : 0.35

                let rect = CGRect(
                    x: x - radius,
                    y: y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
            }
        }
    }

    // MARK: - ドラッグ

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let (toneNorm, colorNorm) = normalizeLocation(value.location)
                viewModel.updateStyle2DRealtime(toneNorm: toneNorm, colorNorm: colorNorm)
            }
            .onEnded { _ in
                viewModel.finalizeStyle2D()
                // ドラッグ完了時の触覚フィードバック（軽め）
                let haptic = UIImpactFeedbackGenerator(style: .soft)
                haptic.impactOccurred(intensity: 0.6)
            }
    }

    /// パッド内座標 → (toneNorm: Y, colorNorm: X) に変換
    ///
    /// - パッド内のドラッグ可能領域は `padSize - thumbSize` 四方
    /// - Y 軸は画面座標（下方向 +）を反転して上方向を正値にする
    private func normalizeLocation(_ location: CGPoint) -> (toneNorm: Float, colorNorm: Float) {
        let halfSize = padSize / 2
        let usableHalf = halfSize - thumbSize / 2 - 4 // 端 4pt の余白

        let dx = location.x - halfSize
        let dy = location.y - halfSize

        let colorNorm = Float(max(-1.0, min(1.0, dx / usableHalf)))
        // Y 反転: 画面座標は下方向が正、トーン軸は上方向を正値にしたい
        let toneNorm  = Float(max(-1.0, min(1.0, -dy / usableHalf)))

        return (toneNorm, colorNorm)
    }

    // MARK: - 状態（read-only computed）

    private var currentTone: Float {
        Float(viewModel.editRecipe.style2DToneNorm ?? 0)
    }

    private var currentColor: Float {
        Float(viewModel.editRecipe.style2DColorNorm ?? 0)
    }

    /// ヘッダー表示用の整数値（-99...+99）
    private var currentToneInt: Int {
        Int(round(currentTone * 99))
    }

    private var currentColorInt: Int {
        Int(round(currentColor * 99))
    }

    /// (0, 0) のときリセットボタンを無効化する
    private var isAtZero: Bool {
        abs(currentTone) < 0.001 && abs(currentColor) < 0.001
    }

    /// 現在値からハンドルの表示オフセットを算出
    private var thumbOffset: CGSize {
        let halfSize = padSize / 2
        let usableHalf = halfSize - thumbSize / 2 - 4
        return CGSize(
            width: CGFloat(currentColor) * usableHalf,
            height: -CGFloat(currentTone) * usableHalf  // Y 反転
        )
    }

    // MARK: - 値フォーマット

    /// ヘッダー数値の表示形式
    /// - 0 のとき: "00"
    /// - 正値: "+12"
    /// - 負値: "-34"
    private func formatValue(_ v: Int) -> String {
        if v == 0 { return "00" }
        return v > 0 ? "+\(v)" : "\(v)"
    }

    // MARK: - アクション

    private func handleResetTapped() {
        guard !isAtZero else { return }
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        viewModel.resetStyle2D()
    }

    /// プリセットサムネイルがタップされたときの処理
    /// - 触覚フィードバック (light)
    /// - パッドの白丸を当該座標へアニメーション付きで移動
    /// - finalizeStyle2D で Undo 履歴に積む
    private func handlePresetTapped(_ preset: StylePreset) {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()

        // updateStyle2DRealtime を呼ぶことで preDragSnapshot もキャプチャされる
        viewModel.updateStyle2DRealtime(
            toneNorm: preset.toneNorm,
            colorNorm: preset.colorNorm
        )
        // ドラッグ相当の完了処理（履歴へ積む + フル解像度プレビュー）
        viewModel.finalizeStyle2D()
    }

    // MARK: - サムネイル生成

    /// 全プリセット分のサムネイルを非同期で生成
    ///
    /// 1. 元画像を低解像度 (200×200) にリサイズ（共通化）
    /// 2. 各プリセットの (tone, color) のみ設定した EditRecipe を作る
    /// 3. applyEditRecipe で各サムネイルを生成
    /// 4. キャッシュに保存して View に反映
    ///
    /// `.task(id: currentImageIndex)` から呼ばれるため、画像切替時は古いタスクが
    /// 自動キャンセルされる。
    @MainActor
    private func regeneratePresetThumbnails() async {
        // 既存キャッシュをクリア（画像が変わった可能性があるため）
        presetThumbnails = [:]
        isGeneratingThumbnails = true
        defer { isGeneratingThumbnails = false }

        // 元画像を取得
        guard viewModel.originalImages.indices.contains(viewModel.currentImageIndex) else {
            return
        }
        let baseImage = viewModel.originalImages[viewModel.currentImageIndex]

        // 共通の低解像度リサイズ画像を 1 度だけ生成（後続のフィルタ適用を高速化）
        let smallImage: UIImage
        do {
            smallImage = try await imageService.resizeImage(
                baseImage,
                maxSize: presetThumbGenerateSize
            )
        } catch {
            // リサイズ失敗時は元画像をそのまま使う（高画質だが遅くなる）
            smallImage = baseImage
        }

        // 各プリセットを順次適用
        for preset in StylePreset.allCases {
            // タスクキャンセル確認（画像切替で別タスクが走っていたら中断）
            if Task.isCancelled { return }

            var recipe = EditRecipe()
            recipe.style2DToneNorm  = Double(preset.toneNorm)
            recipe.style2DColorNorm = Double(preset.colorNorm)

            do {
                let thumb = try await imageService.applyEditRecipe(recipe, to: smallImage)
                if Task.isCancelled { return }
                presetThumbnails[preset.id] = thumb
            } catch {
                // 個別プリセットの失敗は無視（プレースホルダ表示で継続）
                continue
            }
        }
    }
}

// MARK: - Preview

#Preview {
    // モックの EditViewModel を使ったプレビュー
    let vm = EditViewModel()
    return ZStack {
        Color.black.ignoresSafeArea()
        Style2DPadView(viewModel: vm)
    }
}
