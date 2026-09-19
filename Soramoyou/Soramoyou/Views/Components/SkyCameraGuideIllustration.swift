//
//  SkyCameraGuideIllustration.swift ⭐️
//  Soramoyou
//
//  空カメラの「グリッドと水平線ガイド」を小さなファインダーの絵で見せる図解コンポーネント。
//  新規ユーザー向けオンボーディング（OnboardingView・色背景）で、SF Symbol の代わりに表示する。
//  - 三分割の線の位置は実物のカメラと同じ `GridGeometry` から取る（絵と実物がずれないように）
//  - 水平線は実物の `HorizonGuideView` が「水平になった瞬間」に見せる緑の線を描く
//

import SkyCamera
import SwiftUI

/// 空カメラのガイド図解（三分割グリッド＋水平になった緑の水平線）。
struct SkyCameraGuideIllustration: View {
    /// 線・枠の基準色（色背景のオンボーディングでは白）
    var tint: Color = .white
    /// ファインダーの幅（高さは写真と同じ 4:3 にする）
    var width: CGFloat = 170

    var body: some View {
        let height = width * 3 / 4

        ZStack {
            // ファインダーの枠（写真 1 枚ぶん）
            RoundedRectangle(cornerRadius: 14)
                .fill(tint.opacity(0.14))

            // 三分割グリッド。位置は実物と同じ計算を使う。
            // 実物（GridOverlay）は全画面で 0.5pt だが、この小ささだと背景に溶けて
            // 見えなくなるため、図解では線だけ少し太く・濃くしている。
            Path { path in
                for x in GridGeometry.verticalLineXs(width: width) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
                for y in GridGeometry.horizontalLineYs(height: height) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(tint.opacity(0.45), lineWidth: 1)

            // 水平線ガイド（水平になったときの緑の線）。
            // 長さは実物（HorizonGuideView）と同じく幅の 6 割。
            Capsule()
                .fill(Color.green)
                .frame(width: width * 0.6, height: 2.5)

            // 枠線はグリッドより手前に描いて、角の線の切れ端を隠す
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint.opacity(0.9), lineWidth: 2)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        // 意味はタイトルと説明文が伝えるので、図は読み上げ対象から外す
        .accessibilityHidden(true)
    }
}
