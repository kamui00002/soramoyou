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
    
    var body: some View {
        Group {
            if isLoading {
                // 初期読み込み中
                ProgressView("読み込み中...")
                    .onAppear {
                        // 認証状態の確認が完了するまで待機
                        Task {
                            // UIテストモードの場合はローディング時間を短縮
                            let isUITesting = ProcessInfo.processInfo.arguments.contains("UI_TESTING")
                            let waitTime: UInt64 = isUITesting ? 100_000_000 : 500_000_000 // UIテスト: 0.1秒, 通常: 0.5秒
                            try? await Task.sleep(nanoseconds: waitTime)
                            isLoading = false
                        }
                    }
            } else if authViewModel.isAuthenticated {
                // 認証済み: メインタブビューを表示
                MainTabView()
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


