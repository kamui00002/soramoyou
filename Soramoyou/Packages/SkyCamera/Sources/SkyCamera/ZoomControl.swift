// ⭐️ レンズ切替のズームコントロール（0.5x / 1x / 3x のボタン＋連続スライダー）
import SwiftUI

/// 画面下部に出すズーム操作。iPhone 標準カメラと同じ流儀に揃えてある。
///
/// - **タップ**: その倍率へなめらかに移動する
/// - **横ドラッグ**: 連続ズーム（スライダーとして働く）
///
/// 見た目は既存のグリッド／水平線トグル（黒 35% の円＋選択中は黄色）に合わせている。
/// カメラ画面の中で 1 箇所だけ質感を変えると、そこだけ浮いて見えるため。
struct ZoomControl: View {

    /// 端末のレンズ構成（プリセットと上下限の出どころ）。
    let configuration: LensConfiguration

    /// いま表示している倍率。
    @Binding var displayedZoom: CGFloat

    /// 倍率が変わったときの通知。`animated` はボタン操作なら true。
    let onChange: (_ displayedZoom: CGFloat, _ animated: Bool) -> Void

    /// ドラッグを始めたときの倍率。連続ズームの基準点。
    @State private var dragStartZoom: CGFloat?

    /// ドラッグ量を倍率へ変える感度（px）。
    /// 小さくすると敏感になりすぎて狙った倍率で止められない。実機で詰める値。
    private let dragSensitivity: CGFloat = 140

    private var presets: [CGFloat] { configuration.presetDisplayedZooms }
    private var minDisplayed: CGFloat {
        configuration.displayedZoom(forVideoZoomFactor: configuration.minFactor)
    }
    private var maxDisplayed: CGFloat {
        configuration.displayedZoom(forVideoZoomFactor: configuration.maxFactor)
    }

    /// いま使われているレンズに当たるプリセット（＝現在値以下で最大のもの）。
    private var activePreset: CGFloat {
        presets.last { $0 <= displayedZoom + 0.0001 } ?? presets.first ?? 1
    }

    var body: some View {
        // レンズが 1 つしか無い端末では押す意味が無いので出さない。
        if presets.count > 1 {
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    chip(for: preset)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.35)))
            // ⚠️ minimumDistance を置くのが肝。0 にするとドラッグ判定がボタンのタップを
            //    飲み込んでしまい、プリセットが押せなくなる。
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let start = dragStartZoom ?? displayedZoom
                        if dragStartZoom == nil { dragStartZoom = start }
                        // 倍率は「何倍か」なので、足し算ではなく掛け算で動かす。
                        // 足し算だと 0.5x 付近が飛びすぎ、望遠側が動かなくなる。
                        let scaled = start * CGFloat(exp(Double(value.translation.width) / Double(dragSensitivity)))
                        apply(min(maxDisplayed, max(minDisplayed, scaled)), animated: false)
                    }
                    .onEnded { _ in dragStartZoom = nil }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("ズーム")
            .accessibilityValue(LensConfiguration.label(forDisplayedZoom: displayedZoom))
        }
    }

    /// プリセット 1 つぶんのボタン。
    private func chip(for preset: CGFloat) -> some View {
        let isActive = abs(preset - activePreset) < 0.0001
        // 選択中のレンズでは、プリセットちょうどでなければ実際の倍率を出す
        //（1.7x にいるのに「1x」と出ていると、何倍なのか分からなくなる）。
        let isExactlyPreset = abs(displayedZoom - preset) < 0.05
        let text = isActive && !isExactlyPreset
            ? LensConfiguration.label(forDisplayedZoom: displayedZoom)
            : LensConfiguration.label(forDisplayedZoom: preset)

        return Button {
            apply(preset, animated: true)
        } label: {
            Text(text)
                .font(.system(size: isActive ? 13 : 12, weight: isActive ? .bold : .semibold))
                .foregroundColor(isActive ? .black : .white)
                .frame(minWidth: 34)
                .frame(height: 34)
                .background(
                    Circle()
                        .fill(isActive ? Color.yellow : Color.white.opacity(0.12))
                        .frame(width: 34, height: 34)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(LensConfiguration.label(forDisplayedZoom: preset)) にする")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// 倍率を確定して呼び出し側へ渡す。
    private func apply(_ zoom: CGFloat, animated: Bool) {
        displayedZoom = zoom
        onChange(zoom, animated)
    }
}
