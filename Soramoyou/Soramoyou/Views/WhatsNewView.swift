//
//  WhatsNewView.swift ☀️
//  Soramoyou
//
//  アップデートで増えた新機能を、既存ユーザーに「1回だけ」紹介するシート。
//  OnboardingView と統一感のある空デザイン（グラデーション＋雲）を踏襲する。
//  既読化は呼び出し側の `.sheet(onDismiss:)` に集約しているため、
//  本ビューは「閉じる意思」を `onClose` で伝えるだけに徹する。
//

import SwiftUI

/// 新機能紹介シート（What's New）
struct WhatsNewView: View {
    /// 閉じる操作。呼び出し側で sheet を閉じ、onDismiss 側で既読化される。
    let onClose: () -> Void

    @State private var currentPage = 0

    private let pages = WhatsNewContent.pages

    /// iPad などの広い画面でコンテンツが間延びしないよう最大幅を制限する
    private let maxContentWidth: CGFloat = 500

    var body: some View {
        ZStack {
            // 背景グラデーション（現在ページの配色）
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
                header

                // ページコンテンツ
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        pageView(for: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                bottomControls
            }
        }
    }

    // MARK: - Header ☀️

    /// 上部: 見出し＋閉じるボタン
    private var header: some View {
        HStack {
            Text("アップデートで新機能が増えました")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .shadow(DesignTokens.Shadow.text)

            Spacer()

            Button(action: {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                onClose()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.2)))
            }
            .accessibilityLabel("閉じる")
        }
        .padding(.horizontal, DesignTokens.Spacing.screenMargin)
        .padding(.top, DesignTokens.Spacing.md)
    }

    // MARK: - Page View ☀️

    /// 各ページのコンテンツ（アイコン＋新機能バッジ＋タイトル＋説明）
    private func pageView(for page: WhatsNewPage) -> some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Spacer()

            // アイコン（グロー付き）
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.4), Color.white.opacity(0)],
                            center: .center,
                            startRadius: 30,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)
                    .blur(radius: 20)

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

            // 新機能バッジ
            Text(page.badge)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(page.gradientColors[0])
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

            // タイトル
            Text(page.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .shadow(DesignTokens.Shadow.text)

            // 説明文
            Text(page.description)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .shadow(DesignTokens.Shadow.text)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .frame(maxWidth: maxContentWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Controls ☀️

    /// ページインジケーターと主ボタン（次へ / さっそく使う）
    private var bottomControls: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            // ページインジケーター
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(currentPage == index ? Color.white : Color.white.opacity(0.4))
                        .frame(
                            width: currentPage == index ? 10 : 8,
                            height: currentPage == index ? 10 : 8
                        )
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentPage)
                }
            }

            // 主ボタン
            Button(action: primaryAction) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(isLastPage ? "さっそく使う" : "次へ")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Image(systemName: isLastPage ? "arrow.right" : "chevron.right")
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
        }
        .frame(maxWidth: maxContentWidth)
        .frame(maxWidth: .infinity)
        .padding(.bottom, DesignTokens.Spacing.xxl)
    }

    // MARK: - Helpers

    /// 最終ページかどうか
    private var isLastPage: Bool {
        currentPage == pages.count - 1
    }

    /// 主ボタンの動作: 最終ページなら閉じる、それ以外は次ページへ
    private func primaryAction() {
        let impact = UIImpactFeedbackGenerator(style: isLastPage ? .medium : .light)
        impact.impactOccurred()
        if isLastPage {
            onClose()
        } else {
            withAnimation {
                currentPage += 1
            }
        }
    }

    // MARK: - Clouds Decoration ☀️

    /// 装飾的な雲（OnboardingView と共通の CloudShape を流用）
    private var cloudsDecoration: some View {
        GeometryReader { geometry in
            ZStack {
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

// MARK: - Preview ☀️

struct WhatsNewView_Previews: PreviewProvider {
    static var previews: some View {
        WhatsNewView(onClose: {})
    }
}
