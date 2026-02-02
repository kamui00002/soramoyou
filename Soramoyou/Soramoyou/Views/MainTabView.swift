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


