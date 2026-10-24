//
//  WelcomeView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var showLogin = false
    @State private var showSignUp = false
    @State private var cloudOffset: CGFloat = 0
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0
    @State private var titleOffset: CGFloat = 30
    @State private var buttonsOffset: CGFloat = 50
    @State private var buttonsOpacity: Double = 0
    /// 端末の「視差効果を減らす」。ON のときは雲を流さない（ずっと動くものを止めた絵にする）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // 空のグラデーション背景
            LinearGradient(
                colors: DesignTokens.Colors.daySkyGradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 装飾的な雲
            cloudsLayer
                // 「視差効果を減らす」を途中で切り替えたら雲を作り直し、走っている繰り返しの動きを確実に捨てる
                // （SwiftUI は値を始点へ戻しただけでは repeatForever の動きを捨てないことがあるため）
                .id(reduceMotion)

            // 光の効果
            lightEffects

            // メインコンテンツ
            VStack(spacing: 0) {
                Spacer()

                // ロゴ・タイトルエリア
                VStack(spacing: DesignTokens.Spacing.lg) {
                    // アプリアイコン風の雲（アニメーション付き）
                    ZStack {
                        // グロー効果
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        Color.white.opacity(0.5),
                                        Color.white.opacity(0),
                                    ],
                                    center: .center,
                                    startRadius: 40,
                                    endRadius: 100
                                )
                            )
                            .frame(width: 200, height: 200)
                            .blur(radius: 20)

                        // メインアイコン
                        Image(systemName: "cloud.sun.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.white, .white.opacity(0.9)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: DesignTokens.Colors.skyBlue.opacity(0.5), radius: 20, x: 0, y: 10)
                    }
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                    // タイトル
                    VStack(spacing: DesignTokens.Spacing.sm) {
                        Text("そらもよう")
                            .font(.system(size: DesignTokens.Typography.heroSize, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, .white.opacity(0.9)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(DesignTokens.Shadow.text)

                        Text("空を撮る、空を集める")
                            .font(.system(size: DesignTokens.Typography.bodySize, weight: .medium, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .shadow(DesignTokens.Shadow.text)
                    }
                    .offset(y: titleOffset)
                    .opacity(logoOpacity)
                }
                .padding(.bottom, DesignTokens.Spacing.xxl)

                Spacer()

                // ボタンエリア（グラスモーフィズム強化）
                VStack(spacing: DesignTokens.Spacing.md) {
                    // 新規登録ボタン（プライマリ）
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                        showSignUp = true
                    }) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 18, weight: .semibold))
                            Text("新規登録")
                                .font(.system(size: DesignTokens.Typography.buttonSize, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.md)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                                    .fill(
                                        LinearGradient(
                                            colors: DesignTokens.Colors.accentGradient,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )

                                RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            }
                        )
                        .shadow(DesignTokens.Shadow.button)
                    }
                    .buttonStyle(ScaleButtonStyle())

                    // ログインボタン（セカンダリ）
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        showLogin = true
                    }) {
                        Text("ログイン")
                            .font(.system(size: DesignTokens.Typography.buttonSize, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DesignTokens.Spacing.md)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                                        .fill(DesignTokens.Colors.glassSecondary)

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
                                }
                            )
                    }
                    .buttonStyle(ScaleButtonStyle())

                    // ゲストとして閲覧ボタン
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        authViewModel.enterGuestMode()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "eye")
                                .font(.system(size: 14))
                            Text("ゲストとして閲覧")
                                .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                        }
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .padding(.top, DesignTokens.Spacing.sm)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.bottom, DesignTokens.Spacing.xxl)
                .offset(y: buttonsOffset)
                .opacity(buttonsOpacity)
            }
        }
        .onAppear {
            startAnimations()
        }
        .onChange(of: reduceMotion) { reduce in
            // 画面を出している途中で設定が変わったとき: ON → 雲を初めの位置に戻して止める／OFF → 雲を流し始める
            // （ロゴとボタンの登場の動きは 1 回きりなので、ここでは扱わない）
            if reduce {
                cloudOffset = 0
            } else {
                startCloudAnimation()
            }
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
        }
    }

    // MARK: - Light Effects ☀️

    private var lightEffects: some View {
        GeometryReader { geometry in
            // 上部の光
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: geometry.size.width * 0.3, y: -100)
                .blur(radius: 30)
        }
        .ignoresSafeArea()
    }

    // MARK: - 雲のレイヤー ☀️

    private var cloudsLayer: some View {
        GeometryReader { geometry in
            ZStack {
                // 上部の雲
                CloudShape()
                    .fill(.white.opacity(0.5))
                    .frame(width: 220, height: 90)
                    .offset(x: cloudOffset - 60, y: geometry.size.height * 0.08)
                    .blur(radius: 1)

                CloudShape()
                    .fill(.white.opacity(0.35))
                    .frame(width: 160, height: 65)
                    .offset(x: geometry.size.width - cloudOffset - 100, y: geometry.size.height * 0.14)
                    .blur(radius: 1)

                // 中央の雲
                CloudShape()
                    .fill(.white.opacity(0.4))
                    .frame(width: 190, height: 75)
                    .offset(x: cloudOffset + 30, y: geometry.size.height * 0.32)
                    .blur(radius: 1)

                // 下部の雲
                CloudShape()
                    .fill(.white.opacity(0.25))
                    .frame(width: 240, height: 95)
                    .offset(x: geometry.size.width - cloudOffset - 160, y: geometry.size.height * 0.58)
                    .blur(radius: 2)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - アニメーション ☀️

    private func startAnimations() {
        // 雲のアニメーション（「視差効果を減らす」ON のときは流さない＝cloudOffset 0 の初めの位置で止めた絵）
        if !reduceMotion {
            startCloudAnimation()
        }

        // ロゴの登場アニメーション
        withAnimation(DesignTokens.Animation.smoothSpring.delay(0.2)) {
            logoScale = 1.0
            logoOpacity = 1.0
            titleOffset = 0
        }

        // ボタンの登場アニメーション
        withAnimation(DesignTokens.Animation.smoothSpring.delay(0.5)) {
            buttonsOffset = 0
            buttonsOpacity = 1.0
        }
    }

    /// 雲をゆっくり左右に流し続ける（ずっと動く）
    /// 「視差効果を減らす」ON のときは呼ばない。止めた絵は cloudOffset = 0（画面に出た最初の位置）
    private func startCloudAnimation() {
        withAnimation(
            Animation.easeInOut(duration: DesignTokens.Animation.cloudDuration)
                .repeatForever(autoreverses: true)
        ) {
            cloudOffset = 35
        }
    }
}

// MARK: - Scale Button Style ☀️

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(DesignTokens.Animation.buttonPress, value: configuration.isPressed)
    }
}

struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeView()
            .environmentObject(AuthViewModel())
    }
}
