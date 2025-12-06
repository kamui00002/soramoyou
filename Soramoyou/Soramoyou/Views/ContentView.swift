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
                            // 認証状態の確認を待つ（AuthViewModelが初期化時に自動的に確認する）
                            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒待機
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
        .alert("エラー", isPresented: .constant(authViewModel.errorMessage != nil)) {
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


