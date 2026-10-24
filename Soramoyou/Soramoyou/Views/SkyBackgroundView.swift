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
    /// 端末の「視差効果を減らす」。ON のときは雲を流さない（初めの位置で止めた絵にする）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(showClouds: Bool = true, @ViewBuilder content: () -> Content) {
        self.showClouds = showClouds
        self.content = content()
    }

    var body: some View {
        ZStack {
            // 空のグラデーション背景 ☁️
            LinearGradient(
                colors: DesignTokens.Colors.daySkyGradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 装飾的な雲（オプション）
            if showClouds {
                cloudsLayer
                    // 「視差効果を減らす」を途中で切り替えたら雲を作り直し、走っている繰り返しの動きを確実に捨てる
                    // （SwiftUI は値を始点へ戻しただけでは repeatForever の動きを捨てないことがあるため）
                    // ⚠️ 作り直すのは雲だけ。content に付けると中の画面の状態まで消える
                    .id(reduceMotion)
            }

            // コンテンツ
            content
        }
        .onAppear {
            // 「視差効果を減らす」ON のときは雲を流さない（cloudOffset = 0 ＝ 画面に出た最初の位置で止めた絵）
            if showClouds, !reduceMotion {
                startCloudAnimation()
            }
        }
        .onChange(of: reduceMotion) { reduce in
            // 画面を出している途中で設定が変わったとき: ON → 初めの位置に戻して止める／OFF → 流し始める
            if reduce {
                cloudOffset = 0
            } else if showClouds {
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

// MARK: - Glass Card Style ☁️

struct GlassCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(DesignTokens.Colors.glassSecondary)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                            .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
                    )
            )
            .shadow(DesignTokens.Shadow.medium)
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCardStyle())
    }
}

// MARK: - Glass Post Card Style（投稿カード用グラスモーフィズム）☀️

struct GlassPostCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.5),
                                        Color.white.opacity(0.2),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(DesignTokens.Shadow.card)
    }
}

extension View {
    /// 投稿カード用のグラスモーフィズムスタイルを適用
    func glassPostCard() -> some View {
        modifier(GlassPostCardStyle())
    }
}

// MARK: - Glass Button Style ☁️

struct GlassButtonStyle: ButtonStyle {
    let isPrimary: Bool
    let hasGlow: Bool

    init(isPrimary: Bool = true, hasGlow: Bool = false) {
        self.isPrimary = isPrimary
        self.hasGlow = hasGlow
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DesignTokens.Typography.buttonSize, weight: .semibold, design: .rounded))
            .foregroundColor(DesignTokens.Colors.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignTokens.Spacing.md)
            .background(
                ZStack {
                    // ベース背景
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                        .fill(isPrimary ? DesignTokens.Colors.glassPrimary : DesignTokens.Colors.glassSecondary)

                    // グラデーションボーダー
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Colors.glassBorderAccentStart,
                                    DesignTokens.Colors.glassBorderAccentEnd,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    // 押下時のオーバーレイ
                    if configuration.isPressed {
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                            .fill(DesignTokens.Colors.interactiveHighlight)
                    }
                }
            )
            // グロー効果（オプション）
            .shadow(hasGlow ? DesignTokens.Shadow.glow : DesignTokens.Shadow.button)
            // マイクロインタラクション強化
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(DesignTokens.Animation.buttonPress, value: configuration.isPressed)
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

// MARK: - Modern Glass Input Field ☀️

struct GlassInputField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var isSecure: Bool = false
    var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var showPassword = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // アイコン
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isFocused ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
                    .frame(width: 24)
                    .animation(DesignTokens.Animation.fastEase, value: isFocused)
            }

            // 入力フィールド
            Group {
                if isSecure, !showPassword {
                    SecureField(placeholder, text: $text)
                        .onSubmit { onSubmit?() }
                } else {
                    TextField(placeholder, text: $text)
                        .onSubmit { onSubmit?() }
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: DesignTokens.Typography.bodySize, weight: .regular))
            .foregroundColor(DesignTokens.Colors.textPrimary)
            .focused($isFocused)

            // パスワード表示切替
            if isSecure {
                Button(action: { showPassword.toggle() }) {
                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 16))
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                }
            }

            // クリアボタン
            if !text.isEmpty, !isSecure {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.md - 2)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                    .fill(DesignTokens.Colors.glassSecondary)

                RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                    .stroke(
                        LinearGradient(
                            colors: isFocused
                                ? [DesignTokens.Colors.glassBorderAccentStart, DesignTokens.Colors.selectionAccent.opacity(0.5)]
                                : [DesignTokens.Colors.glassBorderSecondary, DesignTokens.Colors.glassBorderSecondary.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
        )
        .scaleEffect(isFocused ? 1.01 : 1.0)
        .animation(DesignTokens.Animation.quickSpring, value: isFocused)
    }
}

// MARK: - Modern Chip Button ☀️

struct ModernChip: View {
    let title: String
    let isSelected: Bool
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
            }
            .foregroundColor(isSelected ? DesignTokens.Colors.textPrimary : DesignTokens.Colors.textSecondary)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(
                ZStack {
                    Capsule()
                        .fill(isSelected ? DesignTokens.Colors.selectionAccent.opacity(0.3) : DesignTokens.Colors.glassTertiary)

                    Capsule()
                        .stroke(
                            isSelected
                                ? DesignTokens.Colors.selectionAccent.opacity(0.6)
                                : DesignTokens.Colors.glassBorderSecondary,
                            lineWidth: 1
                        )
                }
            )
            .shadow(isSelected ? DesignTokens.Shadow.soft : DesignTokens.Shadow.inner)
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(DesignTokens.Animation.quickSpring, value: isSelected)
    }
}

// MARK: - Floating Action Button ☀️

struct FloatingActionButton: View {
    let icon: String
    var size: CGFloat = 56
    var gradient: [Color] = DesignTokens.Colors.accentGradient
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // グロー効果
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [gradient[0].opacity(0.4), Color.clear],
                            center: .center,
                            startRadius: size * 0.3,
                            endRadius: size * 0.8
                        )
                    )
                    .frame(width: size * 1.4, height: size * 1.4)
                    .blur(radius: 15)

                // ベースサークル
                Circle()
                    .fill(
                        LinearGradient(
                            colors: gradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(DesignTokens.Shadow.floating)

                // アイコン
                Image(systemName: icon)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.9 : 1.0)
        .animation(DesignTokens.Animation.bouncySpring, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Animated Card Container ☀️

struct AnimatedCard<Content: View>: View {
    let content: Content
    var delay: Double = 0
    @State private var isVisible = false
    @State private var isHovered = false

    init(delay: Double = 0, @ViewBuilder content: () -> Content) {
        self.delay = delay
        self.content = content()
    }

    var body: some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    DesignTokens.Colors.glassBorderAccentStart,
                                    DesignTokens.Colors.glassBorderAccentEnd,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
            .shadow(DesignTokens.Shadow.card)
            // 登場アニメーション
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 20)
            // ホバー効果
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(isHovered ? DesignTokens.Shadow.strong : DesignTokens.Shadow.card)
            .onAppear {
                withAnimation(DesignTokens.Animation.smoothSpring.delay(delay)) {
                    isVisible = true
                }
            }
            .onHover { hovering in
                withAnimation(DesignTokens.Animation.cardHover) {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - Shimmer Loading Effect ☀️

struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0
    /// 端末の「視差効果を減らす」。ON のときは光の帯を出さない（ずっと流れる帯をやめ、下地だけの止めた絵にする）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.3),
                            Color.white.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.6)
                    .offset(x: -geometry.size.width * 0.3 + phase * geometry.size.width * 1.6)
                    .mask(content)
                }
                // 「視差効果を減らす」ON のときは帯を見せない。phase 0 の帯は左端に半分だけ光る中途半端な絵になるため、
                // 帯そのものを消して下地（骨組みの形）だけにする
                .opacity(reduceMotion ? 0 : 1)
                // 途中で切り替えたら帯だけを作り直し、走っている繰り返しの動きを確実に捨てる（content は作り直さない）
                .id(reduceMotion)
            )
            .onAppear {
                // 「視差効果を減らす」ON のときは帯を流さない
                if !reduceMotion {
                    startSweep()
                }
            }
            .onChange(of: reduceMotion) { reduce in
                // 画面を出している途中で設定が変わったとき: ON → 帯を初めの位置に戻す（帯は上の opacity で見えない）
                // ／OFF → 流し始める
                if reduce {
                    phase = 0
                } else {
                    startSweep()
                }
            }
    }

    /// 光の帯を左から右へ流し続ける（ずっと動く）
    /// 「視差効果を減らす」ON のときは呼ばない
    private func startSweep() {
        withAnimation(
            Animation.linear(duration: 1.5)
                .repeatForever(autoreverses: false)
        ) {
            phase = 1
        }
    }
}

extension View {
    /// シマーローディング効果を適用
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - Pulse Animation Modifier ☀️

struct PulseEffect: ViewModifier {
    @State private var isPulsing = false
    /// 端末の「視差効果を減らす」。ON のときは脈打たせない（不透明・等倍で止めた絵にする）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? 1.05 : 1.0)
            .opacity(isPulsing ? 0.8 : 1.0)
            .onAppear {
                // 「視差効果を減らす」ON のときは脈打たせない（isPulsing = false のまま＝不透明・等倍）
                // ⚠️ 画面を出している途中で設定が変わっても追わない。走っている繰り返しの動きを確実に止めるには
                //    中身（content）ごと作り直すしかなく、中身の状態（@State など）まで消えてしまうため
                guard !reduceMotion else { return }
                withAnimation(
                    Animation.easeInOut(duration: DesignTokens.Animation.pulseDuration)
                        .repeatForever(autoreverses: true)
                ) {
                    isPulsing = true
                }
            }
    }
}

extension View {
    /// パルスアニメーション効果を適用
    func pulse() -> some View {
        modifier(PulseEffect())
    }
}

// MARK: - Skeleton Loading View ☀️

struct SkeletonView: View {
    var width: CGFloat?
    var height: CGFloat = 20
    var cornerRadius: CGFloat = DesignTokens.Radius.sm

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(DesignTokens.Colors.glassTertiary)
            .frame(width: width, height: height)
            .shimmer()
    }
}

// MARK: - Icon Badge ☀️

struct IconBadge: View {
    let icon: String
    var count: Int?
    var color: Color = DesignTokens.Colors.selectionAccent
    var size: CGFloat = 44

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // アイコン背景
            Circle()
                .fill(DesignTokens.Colors.glassTertiary)
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
                )

            // アイコン
            Image(systemName: icon)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundColor(DesignTokens.Colors.textPrimary)

            // バッジ（カウントがある場合）
            if let count, count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(color)
                    )
                    .offset(x: 4, y: -4)
            }
        }
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
