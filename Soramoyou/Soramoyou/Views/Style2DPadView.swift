// ⭐️ Style2DPadView.swift
// 2D スタイルパッド（iPhone 写真スタイル風 UI）
//
// X 軸: カラー (-1...1) — 寒色 ↔ 暖色
// Y 軸: トーン (-1...1) — 下=フラット ↔ 上=コントラスト強化
//
// 1 つの白丸ハンドルをドラッグするだけで「トーン」と「カラー」を同時に調整できる。
// 既存の 27 ツール（個別スライダー）とは独立した複合ツールで、
// パイプライン末尾で適用される。
//
//  そらもよう - 空を撮る、空を集める

import SwiftUI
import UIKit

/// 2D スタイルパッド本体
///
/// 構成:
/// 1. ヘッダー: 「トーン XX カラー XX ↺」の数値表示 + リセットボタン
/// 2. パッド: ドット格子背景 + 白丸ハンドル（ドラッグで両軸同時操作）
struct Style2DPadView: View {

    // MARK: - 依存

    @ObservedObject var viewModel: EditViewModel

    // MARK: - レイアウト定数

    /// パッドの一辺サイズ（pt）
    private let padSize: CGFloat = 200
    /// ハンドル（白丸）の直径（pt）
    private let thumbSize: CGFloat = 18
    /// ドット格子の縦横の数（奇数推奨で中心が点になる）
    private let dotCount: Int = 13

    // MARK: - Body

    var body: some View {
        VStack(spacing: 16) {
            headerBar
                .padding(.top, 8)

            padView

            Spacer(minLength: 0)
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
