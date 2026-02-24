//
//  OnboardingView.swift ☀️
//  Soramoyou
//
//  初回起動時に表示されるオンボーディング画面
//  アプリの主要機能を紹介し、ユーザーに使い方を説明する
//

import SwiftUI

/// オンボーディング画面
/// 初回起動時にアプリの機能を紹介する
struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0

    /// オンボーディングページの内容
    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "camera.fill",
            title: "空を撮る",
            description: "お気に入りの空の写真を選んで\n美しく編集しましょう",
            gradientColors: [
                Color(red: 0.53, green: 0.81, blue: 0.98),
                Color(red: 0.39, green: 0.58, blue: 0.93)
            ]
        ),
        OnboardingPage(
            icon: "slider.horizontal.3",
            title: "自由に編集",
            description: "10種類のフィルターと27種類の\n編集ツールで思い通りに",
            gradientColors: [
                Color(red: 0.98, green: 0.76, blue: 0.53),
                Color(red: 0.93, green: 0.52, blue: 0.39)
            ]
        ),
        OnboardingPage(
            icon: "square.and.arrow.up",
            title: "みんなと共有",
            description: "あなたの空の写真を投稿して\n世界中の空を楽しもう",
            gradientColors: [
                Color(red: 0.76, green: 0.53, blue: 0.98),
                Color(red: 0.58, green: 0.39, blue: 0.93)
            ]
        ),
        OnboardingPage(
            icon: "sparkles",
            title: "さあ、始めよう",
            description: "そらもようで\n素敵な空の写真ライフを",
            gradientColors: [
                Color(red: 0.68, green: 0.85, blue: 0.90),
                Color(red: 0.53, green: 0.81, blue: 0.98)
            ]
        )
    ]

    var body: some View {
        ZStack {
            // 背景グラデーション
            LinearGradient(
                colors: pages[currentPage].gradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.5), value: currentPage)

            // 装飾的な雲
            cloudsDecoration

            VStack(spacing: 0) {
                // ページコンテンツ
                TabView(selection: $currentPage) {
                    ForEach(0..<pages.count, id: \.self) { index in
                        pageView(for: pages[index])
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                // ページインジケーターとボタン
                bottomControls
            }
        }
    }

    // MARK: - Page View ☀️

    /// 各ページのコンテンツ
    private func pageView(for page: OnboardingPage) -> some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            Spacer()

            // アイコン
            ZStack {
                // グロー効果
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0)
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)
                    .blur(radius: 20)

                // アイコン
                Image(systemName: page.icon)
                    .font(.system(size: 80))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, .white.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            }

            // タイトル
            Text(page.title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(DesignTokens.Shadow.text)

            // 説明文
            Text(page.description)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .shadow(DesignTokens.Shadow.text)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
    }

    // MARK: - Bottom Controls ☀️

    /// ページインジケーターとボタン
    private var bottomControls: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            // ページインジケーター
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(currentPage == index ? Color.white : Color.white.opacity(0.4))
                        .frame(width: currentPage == index ? 10 : 8, height: currentPage == index ? 10 : 8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                }
            }

            // ボタン
            if currentPage == pages.count - 1 {
                // 最後のページ: 始めるボタン
                Button(action: {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    withAnimation {
                        hasCompletedOnboarding = true
                    }
                }) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text("始める")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundColor(pages[currentPage].gradientColors[0])
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignTokens.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                            .fill(Color.white)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
            } else {
                // 次へボタン
                HStack {
                    // スキップボタン
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation {
                            hasCompletedOnboarding = true
                        }
                    }) {
                        Text("スキップ")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.8))
                    }

                    Spacer()

                    // 次へボタン
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        withAnimation {
                            currentPage += 1
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text("次へ")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                        )
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
            }
        }
        .padding(.bottom, DesignTokens.Spacing.xxl)
    }

    // MARK: - Clouds Decoration ☀️

    /// 装飾的な雲
    private var cloudsDecoration: some View {
        GeometryReader { geometry in
            ZStack {
                // 上部の雲
                CloudShape()
                    .fill(.white.opacity(0.3))
                    .frame(width: 200, height: 80)
                    .offset(x: -50, y: geometry.size.height * 0.1)
                    .blur(radius: 2)

                CloudShape()
                    .fill(.white.opacity(0.2))
                    .frame(width: 150, height: 60)
                    .offset(x: geometry.size.width - 100, y: geometry.size.height * 0.15)
                    .blur(radius: 2)

                // 下部の雲
                CloudShape()
                    .fill(.white.opacity(0.15))
                    .frame(width: 180, height: 70)
                    .offset(x: 30, y: geometry.size.height * 0.6)
                    .blur(radius: 3)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Onboarding Page Model ☀️

/// オンボーディングページのデータモデル
struct OnboardingPage {
    let icon: String
    let title: String
    let description: String
    let gradientColors: [Color]
}

// MARK: - Preview ☀️

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(hasCompletedOnboarding: .constant(false))
    }
}
