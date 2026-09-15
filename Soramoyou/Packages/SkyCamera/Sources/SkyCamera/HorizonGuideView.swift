// ⭐️ 水平線ガイド（傾きに追従する線・水平で色が変わる）
import SwiftUI
import UIKit

/// 傾きに追従して回転する水平線ガイド。
/// 水平（±1°）に入った瞬間だけ軽いハプティクスを 1 回返す（鳴り続けないよう状態の変化で判定）。
public struct HorizonGuideView: View {

    /// 現在の傾き読み取り結果。
    private let reading: HorizonMath.Reading

    /// 直前に「水平だった」か。ハプティクスを入った瞬間だけに絞るための記憶。
    @State private var wasLevel = false

    public init(reading: HorizonMath.Reading) {
        self.reading = reading
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let lineWidth = width * 0.6

            ZStack {
                // 基準線（常に画面の水平）。ここに撮影中の線が重なると「水平」。
                Rectangle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: lineWidth, height: 1)

                // 端末の傾きに追従する線。
                Rectangle()
                    .fill(reading.isLevel ? Color.green : Color.white.opacity(0.9))
                    .frame(width: lineWidth, height: reading.isLevel ? 2 : 1)
                    .rotationEffect(.degrees(reading.rollDegrees))
                    .animation(.linear(duration: 0.05), value: reading.rollDegrees)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            // 真上（空）を向いていて傾きが求まらないときは、嘘の線を出さずに隠す。
            .opacity(reading.isReliable ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: reading.isLevel) { isLevel in
            guard reading.isReliable else { return }
            if isLevel && !wasLevel {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            wasLevel = isLevel
        }
    }
}
