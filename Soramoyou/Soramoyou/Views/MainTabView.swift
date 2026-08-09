//
//  MainTabView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import UIKit

struct MainTabView: View {
    @State private var selectedTab: Tab = .home
    @Namespace private var tabAnimation

    // What's New（新機能紹介）の表示制御
    @AppStorage(WhatsNewContent.onboardingCompletedKey) private var hasCompletedOnboarding = false
    @AppStorage(WhatsNewContent.lastSeenKey) private var lastSeenWhatsNewVersion = ""
    @State private var showWhatsNew = false

    enum Tab: Int, CaseIterable {
        case home = 0
        case gallery = 1
        case post = 2
        case search = 3
        case profile = 4

        var title: String {
            switch self {
            case .home: return "ホーム"
            case .post: return "投稿"
            case .gallery: return "ギャラリー"
            case .search: return "検索"
            case .profile: return "プロフィール"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house"
            case .post: return "plus"
            case .gallery: return "photo.on.rectangle.angled"
            case .search: return "magnifyingglass"
            case .profile: return "person"
            }
        }

        var selectedIcon: String {
            switch self {
            case .home: return "house.fill"
            case .post: return "plus"
            case .gallery: return "photo.on.rectangle.angled.fill"
            case .search: return "magnifyingglass"
            case .profile: return "person.fill"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // メインコンテンツ
            Group {
                switch selectedTab {
                case .home:
                    HomeView()
                case .gallery:
                    GalleryView()
                case .post:
                    PostView()
                case .search:
                    SearchView()
                case .profile:
                    ProfileView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // カスタムフローティングタブバー
            floatingTabBar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .task {
            // 画面計測: 起動直後に表示されているタブを1回だけ記録する（切替は下の onChange が拾う）。
            // ⭐️ `selectedTab` を単一の真実源にすることで、各画面側の `.onAppear`
            //    （SwiftUI の仕様で複数回発火しうる）に依存せず「切替1回＝イベント1回」を保証できる。
            //    このタブバーは TabView ではなく `switch selectedTab` で View を出し分けており、
            //    切替のたびに各画面が作り直される＝onAppear 方式だと重複計上の温床になる。
            LoggingService.shared.logScreen(selectedTab.title)
            await maybeShowWhatsNew()
        }
        .onChange(of: selectedTab) { newTab in
            // タブ切替。画面名は Tab.title の日本語をそのまま使う（PostHog 上の表示名）。
            LoggingService.shared.logScreen(newTab.title)
        }
        // iPad では .sheet が中央フォームカードになり全画面グラデが崩れるため、
        // 全プラットフォームで全画面になる .fullScreenCover を使う（オンボ用途にも適切）。
        .fullScreenCover(isPresented: $showWhatsNew, onDismiss: handleWhatsNewDismiss) {
            WhatsNewView(onClose: { showWhatsNew = false })
        }
    }

    // MARK: - What's New（新機能紹介）

    /// アップデートした既存ユーザーにのみ、新機能紹介を1回だけ表示する。
    /// ATT/AdMob 等のシステムダイアログと衝突しないよう少し待ってから出す。
    private func maybeShowWhatsNew() async {
        guard WhatsNewGate.shouldPresent(
            currentID: WhatsNewContent.currentID,
            lastSeenID: lastSeenWhatsNewVersion,
            hasCompletedOnboarding: hasCompletedOnboarding
        ) else { return }

        // 起動直後は ATT/AdMob ダイアログが先に出るため、その猶予を与える
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 猶予中に既読化された場合は出さない
        guard lastSeenWhatsNewVersion != WhatsNewContent.currentID else { return }

        showWhatsNew = true
        LoggingService.shared.logEvent(
            "whats_new_shown",
            parameters: ["version": WhatsNewContent.currentID]
        )
    }

    /// シートが閉じられたら（×・スワイプ・「さっそく使う」いずれでも）既読化する。
    /// 既読化を1箇所に集約し、どの閉じ方でも「1回だけ」を保証する。
    private func handleWhatsNewDismiss() {
        lastSeenWhatsNewVersion = WhatsNewContent.currentID
        LoggingService.shared.logEvent(
            "whats_new_dismissed",
            parameters: ["version": WhatsNewContent.currentID]
        )
    }

    // MARK: - Floating Tab Bar ☀️

    private var floatingTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                if tab == .post {
                    // 中央の投稿ボタン（特別デザイン）
                    postButton
                } else {
                    // 通常のタブボタン
                    tabButton(for: tab)
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(
            ZStack {
                // ブラー背景
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xxl)
                    .fill(.ultraThinMaterial)

                // グラデーションボーダー
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xxl)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.4),
                                Color.white.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .shadow(DesignTokens.Shadow.floating)
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    // MARK: - Tab Button

    private func tabButton(for tab: Tab) -> some View {
        Button(action: {
            withAnimation(DesignTokens.Animation.smoothSpring) {
                selectedTab = tab
            }
            // ハプティックフィードバック
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
        }) {
            VStack(spacing: 4) {
                ZStack {
                    // 選択時の背景
                    if selectedTab == tab {
                        Circle()
                            .fill(DesignTokens.Colors.selectionAccent.opacity(0.15))
                            .frame(width: 44, height: 44)
                            .matchedGeometryEffect(id: "tabBackground", in: tabAnimation)
                    }

                    Image(systemName: selectedTab == tab ? tab.selectedIcon : tab.icon)
                        .font(.system(size: 20, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(
                            selectedTab == tab
                                ? DesignTokens.Colors.selectionAccent
                                : DesignTokens.Colors.textTertiary
                        )
                        .frame(width: 44, height: 44)
                }

                Text(tab.title)
                    .font(.system(size: DesignTokens.Typography.tabLabelSize, weight: .medium, design: .rounded))
                    .foregroundColor(
                        selectedTab == tab
                            ? DesignTokens.Colors.selectionAccent
                            : DesignTokens.Colors.textTertiary
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Post Button (Center)

    private var postButton: some View {
        Button(action: {
            withAnimation(DesignTokens.Animation.bouncySpring) {
                selectedTab = .post
            }
            // ハプティックフィードバック
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        }) {
            ZStack {
                // グロー効果
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                DesignTokens.Colors.accentGradient[0].opacity(0.4),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 15,
                            endRadius: 35
                        )
                    )
                    .frame(width: 70, height: 70)
                    .blur(radius: 10)

                // メインボタン
                Circle()
                    .fill(
                        LinearGradient(
                            colors: DesignTokens.Colors.accentGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(DesignTokens.Shadow.button)

                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
            }
            .scaleEffect(selectedTab == .post ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .offset(y: -10)
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(AuthViewModel())
    }
}


