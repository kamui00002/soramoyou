//
//  SkyBackgroundView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

// MARK: - Sky Background View

struct SkyBackgroundView<Content: View>: View {
    let content: Content
    let showClouds: Bool

    @State private var cloudOffset: CGFloat = 0

    init(showClouds: Bool = true, @ViewBuilder content: () -> Content) {
        self.showClouds = showClouds
        self.content = content()
    }

    var body: some View {
        ZStack {
            // 空のグラデーション背景
            LinearGradient(
                colors: [
                    Color(red: 0.68, green: 0.85, blue: 0.90),  // 淡い空色
                    Color(red: 0.53, green: 0.81, blue: 0.98),  // 空色
                    Color(red: 0.39, green: 0.58, blue: 0.93)   // 深い空色
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 装飾的な雲（オプション）
            if showClouds {
                cloudsLayer
            }

            // コンテンツ
            content
        }
        .onAppear {
            if showClouds {
                startCloudAnimation()
            }
        }
    }

    // MARK: - 雲のレイヤー

    private var cloudsLayer: some View {
        GeometryReader { geometry in
            ZStack {
                // 上部の雲
                CloudShape()
                    .fill(.white.opacity(0.5))
                    .frame(width: 180, height: 70)
                    .offset(x: cloudOffset - 40, y: geometry.size.height * 0.08)

                CloudShape()
                    .fill(.white.opacity(0.35))
                    .frame(width: 140, height: 55)
                    .offset(x: geometry.size.width - cloudOffset - 80, y: geometry.size.height * 0.12)

                // 中央の雲
                CloudShape()
                    .fill(.white.opacity(0.4))
                    .frame(width: 160, height: 65)
                    .offset(x: cloudOffset + 10, y: geometry.size.height * 0.32)

                // 下部の雲
                CloudShape()
                    .fill(.white.opacity(0.25))
                    .frame(width: 200, height: 80)
                    .offset(x: geometry.size.width - cloudOffset - 130, y: geometry.size.height * 0.55)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - アニメーション

    private func startCloudAnimation() {
        withAnimation(
            Animation.easeInOut(duration: 8)
                .repeatForever(autoreverses: true)
        ) {
            cloudOffset = 25
        }
    }
}

// MARK: - Sky Background Modifier

struct SkyBackgroundModifier: ViewModifier {
    let showClouds: Bool

    func body(content: Content) -> some View {
        SkyBackgroundView(showClouds: showClouds) {
            content
        }
    }
}

extension View {
    func skyBackground(showClouds: Bool = true) -> some View {
        modifier(SkyBackgroundModifier(showClouds: showClouds))
    }
}

// MARK: - Glass Card Style

struct GlassCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.white.opacity(0.2))
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.white.opacity(0.4), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCardStyle())
    }
}

// MARK: - Glass Button Style

struct GlassButtonStyle: ButtonStyle {
    let isPrimary: Bool

    init(isPrimary: Bool = true) {
        self.isPrimary = isPrimary
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(isPrimary ? 0.25 : 0.15))
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(.white.opacity(isPrimary ? 0.5 : 0.3), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Cloud Shape

struct CloudShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let width = rect.width
        let height = rect.height

        // 雲の形を描画
        path.move(to: CGPoint(x: width * 0.2, y: height * 0.7))

        // 左側の丸み
        path.addQuadCurve(
            to: CGPoint(x: width * 0.1, y: height * 0.5),
            control: CGPoint(x: width * 0.05, y: height * 0.7)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.25, y: height * 0.3),
            control: CGPoint(x: width * 0.05, y: height * 0.3)
        )

        // 上部の丸み
        path.addQuadCurve(
            to: CGPoint(x: width * 0.5, y: height * 0.15),
            control: CGPoint(x: width * 0.35, y: height * 0.1)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.75, y: height * 0.3),
            control: CGPoint(x: width * 0.65, y: height * 0.1)
        )

        // 右側の丸み
        path.addQuadCurve(
            to: CGPoint(x: width * 0.9, y: height * 0.5),
            control: CGPoint(x: width * 0.95, y: height * 0.3)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.8, y: height * 0.7),
            control: CGPoint(x: width * 0.95, y: height * 0.7)
        )

        // 底部
        path.addLine(to: CGPoint(x: width * 0.2, y: height * 0.7))

        path.closeSubpath()

        return path
    }
}

// MARK: - Preview

struct SkyBackgroundView_Previews: PreviewProvider {
    static var previews: some View {
        SkyBackgroundView {
            VStack {
                Text("そらもよう")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Spacer()

                Button("ボタン") {}
                    .buttonStyle(GlassButtonStyle())
                    .padding()
            }
            .padding()
        }
    }
}
