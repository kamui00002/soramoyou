//
//  ContentView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
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
                            if !hasRequestedATT && AdService.isAdsEnabled {
                                hasRequestedATT = true
                                await AdService.shared.initialize()
                            }
                        }
                    }
            } else if authViewModel.isAuthenticated {
                // 認証済み: メインタブビューを表示
                MainTabView()
            } else if authViewModel.isGuest {
                // ゲストモード: 閲覧専用タブビューを表示（投稿・プロフィール機能は制限）
                GuestTabView()
            } else {
                // 未認証: ウェルカム画面を表示
                WelcomeView()
            }
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
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AuthViewModel())
    }
}


