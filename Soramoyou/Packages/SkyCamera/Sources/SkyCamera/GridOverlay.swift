// ⭐️ 三分割グリッドの純粋幾何（描画と計算を分けてテスト可能にする）
import Foundation
import SwiftUI

/// 三分割グリッドの線の位置を求める純関数群。
public enum GridGeometry {

    /// 三分割の縦線の x 座標（左から 1/3, 2/3）。
    public static func verticalLineXs(width: CGFloat) -> [CGFloat] {
        [width / 3, width * 2 / 3]
    }

    /// 三分割の横線の y 座標（上から 1/3, 2/3）。
    public static func horizontalLineYs(height: CGFloat) -> [CGFloat] {
        [height / 3, height * 2 / 3]
    }
}

/// 三分割グリッドの描画。線は薄く（空の色を邪魔しない）。
public struct GridOverlay: View {

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Path { path in
                for x in GridGeometry.verticalLineXs(width: size.width) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in GridGeometry.horizontalLineYs(height: size.height) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
        // グリッドは装飾であり、タップは下のプレビュー（AF/AE）に通す。
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
