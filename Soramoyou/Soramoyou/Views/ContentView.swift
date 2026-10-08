//
//  ContentView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    /// お気に入り（🔖）状態の共有 Manager ⭐️ サインアウト時のローカル破棄を配線するために参照する
    @EnvironmentObject private var favoriteManager: FavoriteManager
    /// いいね状態の共有 Manager ⭐️ 同じくサインアウト時のローカル破棄を配線するために参照する（#147）
    @EnvironmentObject private var likeManager: LikeManager
    /// そらとも（友達グループで空を共有）の機能フラグの判定 ⭐️ tasks 14.1
    /// ログインが確定したら評価し、サインアウトで判定を戻す（SoramoyouApp が注入）
    @EnvironmentObject private var soratomoGate: SoratomoFeatureGate
    /// そらともへの遷移を決めるルーター ⭐️ tasks 14.1（未ログインの間に届いた通知の行き先を破棄するために見る）
    @ObservedObject private var soratomoRouter = SoratomoRouter.shared
    @State private var isLoading = true
    @State private var hasRequestedATT = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                // 初回起動: オンボーディング画面を表示
                OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
            } else if isLoading {
                // 初期読み込み中
                ProgressView("読み込み中...")
                    .onAppear {
                        // 認証状態の確認が完了するまで待機
                        Task {
                            #if DEBUG
                                // UIテストモードの場合はローディング時間を短縮
                                let isUITesting = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
                                let waitTime: UInt64 = isUITesting ? 100_000_000 : 500_000_000 // UIテスト: 0.1秒, 通常: 0.5秒
                            #else
                                let waitTime: UInt64 = 500_000_000 // 通常: 0.5秒
                            #endif
                            try? await Task.sleep(nanoseconds: waitTime)
                            isLoading = false

                            // ビュー表示後にATT/AdMob初期化を実行
                            // ATTダイアログはビューが表示された後でないと表示されない
                            if !hasRequestedATT, AdService.isAdsEnabled {
                                hasRequestedATT = true
                                await AdService.shared.initialize()
                            }
                        }
                    }
            } else if authViewModel.isAuthenticated {
                // 認証済み: メインタブビューを表示
                MainTabView()
                    .task(id: authViewModel.isAuthenticated) {
                        // ⚠️「空を動かす」回数パックの**未完了トランザクション再送はここが砦**。
                        //    購入は済んだがサーバー加算の確認前にアプリが落ちた場合、次に
                        //    ユーザーが取る行動は「アプリを開き直す」であって「空を動かすシートを
                        //    開き直す」ではない。だからシートではなく起動直後に回す。
                        //    ログインし直しで uid が変わった場合も、id: で task が張り直されて
                        //    残高の購読先が正しい uid になる。
                        SkyMotionCreditService.shared.start()
                    }
            } else if authViewModel.isGuest {
                // ゲストモード: 閲覧専用タブビューを表示（投稿・プロフィール機能は制限）
                GuestTabView()
            } else {
                // 未認証: ウェルカム画面を表示
                WelcomeView()
            }
        }
        // ⚠️ サインアウトしたら、この端末に残る「自分だけの🔖」をローカルから消す。
        //    お気に入りは本人だけが見られるプライベート保存なので、共有端末で次の
        //    ユーザーに前のユーザーの🔖が塗られて見えてはいけない。
        //    AuthViewModel.signOut は WidgetCacheManager / SkyMotionCreditService を
        //    同じ理由で消しているが、FavoriteManager は別の @StateObject で
        //    AuthViewModel から手が届かないため、環境が揃うここで配線する。
        .onChange(of: authViewModel.isAuthenticated) { isAuthenticated in
            if !isAuthenticated {
                favoriteManager.clearOnSignOut()
                // いいね（ピンクのハート）も同じ理由で消す（#147）⭐️
                likeManager.clearOnSignOut()
                // おすすめの空（自分の一覧）も同じ理由で消す。アカウント削除でもここを通る ⭐️
                RecommendationManager.shared.clearOnSignOut()
                // そらとも（友達グループで空を共有）も同じ理由で消す ⭐️ tasks 14.1
                // 通知の保留の行き先と画面の経路・フラグの判定・画像のキャッシュ・表示名とアイコンの保持・投稿の覚え
                // ・ブロックの一覧と通報の記録のメモリ（release-gate 9.6。端末の通報の記録は残す）
                SoratomoRouter.shared.clearOnSignOut()
                soratomoGate.reset()
                SoratomoImageCache.clear()
                SoratomoDependencies.live.clearSessionState()
            }
        }
        // そらともの機能フラグを、ログインが確定するたびに評価する ⭐️ tasks 14.1
        // 起動時（ログイン済みで起動）と、ログインし直したとき（id が変わって張り直される）に走る。
        // 起動ごとの最初の評価だけトークンを強制的に更新するのは、判定（SoratomoFeatureGate）の中で済んでいる。
        // 評価が済んで判定が変わると、MainTabView の onChange が通知の保留の行き先を解決する
        .task(id: authViewModel.isAuthenticated) {
            if authViewModel.isAuthenticated {
                await soratomoGate.evaluate()
            }
        }
        // 未ログインの間に届いた、そらともの通知の行き先を破棄する ⭐️ tasks 14.1
        // （読み込みが終わってログイン状態が確定した時と、通知のタップが届いた時）
        .onChange(of: isLoading) { _ in
            resolveSoratomoPendingIfSignedOut()
        }
        .onChange(of: soratomoRouter.pending) { _ in
            resolveSoratomoPendingIfSignedOut()
        }
        .alert("エラー", isPresented: Binding(errorMessage: $authViewModel.errorMessage)) {
            Button("OK") {
                authViewModel.errorMessage = nil
            }
        } message: {
            if let errorMessage = authViewModel.errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - そらとも ⭐️ tasks 14.1

    /// 未ログイン（ゲスト中・ウェルカム画面）で、そらともの通知の保留の行き先があれば破棄させる
    ///
    /// ルーターは未ログインなら破棄して `signed_out` を記録する（そらともの画面は出さない・要件 10.11）。
    /// ログイン済みの間の解決は MainTabView が行う（What's New の表示中かを知っているのはそちら）。
    ///
    /// ⚠️ ログイン状態が確定する前に呼ぶと、ログイン済みの利用者の通知を `signed_out` で捨ててしまう。
    ///    そのため、オンボーディングと起動直後の読み込み（isLoading）が終わるまでは何もしない。
    ///    `AuthViewModel` は init で現在のログイン状態を同期で読むので、読み込みが終われば確定している。
    private func resolveSoratomoPendingIfSignedOut() {
        guard hasCompletedOnboarding, !isLoading, !authViewModel.isAuthenticated else { return }
        soratomoRouter.resolvePending(
            session: .signedOut,
            gate: soratomoGate.state,
            canPresent: false
        )
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthViewModel())
            .environmentObject(FavoriteManager())
            .environmentObject(LikeManager())
            // そらともの判定（Preview では常に未ログイン扱いの窓口）⭐️
            .environmentObject(SoratomoFeatureGate(provider: SoratomoEntryContentPreviewProvider()))
    }
}

/// Preview 用のアカウントの窓口（ログインしていない扱い。FirebaseAuth を呼ばない）⭐️
@MainActor
private struct SoratomoEntryContentPreviewProvider: SoratomoClaimsProviding {
    func currentAccountKind() -> SoratomoAccountKind? { nil }
    func claims(forceRefresh _: Bool) async throws -> [String: Any] { [:] }
}
