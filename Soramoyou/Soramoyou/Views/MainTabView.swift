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

    // そらとも（友達グループで空を共有）⭐️ tasks 14.1
    /// 機能フラグの判定（SoramoyouApp が注入。ログイン時の評価は ContentView）
    @EnvironmentObject private var soratomoGate: SoratomoFeatureGate
    /// そらともへの遷移を決めるルーター（全画面のカバーの表示と、通知の保留の行き先を持つ）
    @ObservedObject private var soratomoRouter = SoratomoRouter.shared

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
            // そらともの根の画面を全画面で出す口 ⭐️ tasks 14.1
            // ⚠️ What's New の fullScreenCover（外側の ZStack に付いている）とは別の階層（タブの中身の Group）に付ける。
            //    同じビューに 2 つ付けると片方しか出ないため。What's New の表示中は canPresent を false にして待つ
            .fullScreenCover(isPresented: $soratomoRouter.isPresented) {
                SoratomoRootView(router: .shared, dependencies: .live)
            }

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
        // そらともの通知の保留の行き先を、表示できる状況になったら開く ⭐️ tasks 14.1
        // （タブの画面の表示時・フラグの判定が決まった時・通知のタップが届いた時。
        //   What's New を閉じた時は handleWhatsNewDismiss から呼ぶ）
        .onAppear {
            resolveSoratomoPending()
        }
        .onChange(of: soratomoGate.state) { _ in
            resolveSoratomoPending()
        }
        .onChange(of: soratomoRouter.pending) { _ in
            resolveSoratomoPending()
        }
    }

    // MARK: - What's New（新機能紹介）

    /// アップデートした既存ユーザーにのみ、新機能紹介を1回だけ表示する。
    /// ATT/AdMob 等のシステムダイアログと衝突しないよう少し待ってから出す。
    /// 猶予の後に What's New を出してよいか ⭐️ tasks 14.1（レビューで足した）
    ///
    /// そらとも（友達グループで空を共有）の全画面が先に出ているときは出さない。出そうとすると、子のカバーの表示中に
    /// 親から 2 枚目を出すことになり、表示に失敗して `showWhatsNew` が true のまま残りうる。残ると、この起動の間は
    /// そらともの通知の保留が解決されなくなる（canPresent がずっと false）。出さなかった場合は既読にならないので、
    /// 次回の起動で出る（design.md の Risks に書いた挙動と同じ）。
    static func canShowWhatsNewAfterDelay(lastSeenID: String, currentID: String, isSoratomoPresented: Bool) -> Bool {
        lastSeenID != currentID && !isSoratomoPresented
    }

    private func maybeShowWhatsNew() async {
        guard WhatsNewGate.shouldPresent(
            currentID: WhatsNewContent.currentID,
            lastSeenID: lastSeenWhatsNewVersion,
            hasCompletedOnboarding: hasCompletedOnboarding
        ) else { return }

        // 起動直後は ATT/AdMob ダイアログが先に出るため、その猶予を与える
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 猶予中に既読化された場合・そらともの全画面が先に出ている場合は出さない
        guard Self.canShowWhatsNewAfterDelay(
            lastSeenID: lastSeenWhatsNewVersion,
            currentID: WhatsNewContent.currentID,
            isSoratomoPresented: soratomoRouter.isPresented
        ) else { return }

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
        // What's New の表示中に待たせていた、そらともの通知の行き先をもう一度試す ⭐️ tasks 14.1
        // （onDismiss は閉じるアニメーションの後に呼ばれるので、ここなら次の全画面を出せる）
        resolveSoratomoPending()
    }

    // MARK: - そらとも ⭐️ tasks 14.1

    /// そらともの通知の保留の行き先を、いまの状況で開くか・破棄するか・待つかをルーターに決めさせる
    ///
    /// この画面はログイン済みのときだけ出る（ContentView の分岐）ので、ログイン状態は `.signedIn` で渡す。
    /// 未ログインの保留の破棄は ContentView が行う。
    /// - フラグの判定前（unknown）: ルーターが保留のまま待つ（判定が決まると onChange でもう一度呼ばれる）
    /// - フラグが無効: ルーターが破棄して `flag_off` を記録する（そらともの画面は出さない）
    /// - フラグが有効: What's New の表示中は `canPresent = false` で待ち、閉じたら開く
    ///
    /// ⚠️ design.md の Risks のとおり、待ち合わせは What's New だけ。タブの中のほかのシートの表示中や、
    ///    What's New の 1.5 秒の待ちの間にそらともが先に出た場合の挙動は、実機で確かめる。
    private func resolveSoratomoPending() {
        soratomoRouter.resolvePending(
            session: .signedIn,
            gate: soratomoGate.state,
            canPresent: !showWhatsNew
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
            // そらともの判定（Preview では常に未ログイン扱いの窓口。入口もカバーも出ない）⭐️
            .environmentObject(SoratomoFeatureGate(provider: SoratomoEntryMainTabPreviewProvider()))
    }
}

/// Preview 用のアカウントの窓口（ログインしていない扱い。FirebaseAuth を呼ばない）⭐️
@MainActor
private struct SoratomoEntryMainTabPreviewProvider: SoratomoClaimsProviding {
    func currentAccountKind() -> SoratomoAccountKind? { nil }
    func claims(forceRefresh _: Bool) async throws -> [String: Any] { [:] }
}


