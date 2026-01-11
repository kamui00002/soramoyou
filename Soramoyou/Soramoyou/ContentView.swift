//
//  ContentView.swift
//  Soramoyou
//
//  Created by 吉留徹 on 2025/12/07.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authViewModel: AuthViewModel

    var body: some View {
        Group {
            if authViewModel.isAuthenticated {
                // ログイン済み: メイン画面を表示
                MainTabView()
            } else {
                // 未ログイン: ウェルカム画面を表示
                WelcomeView()
            }
        }
        .onAppear {
            // 認証状態を確認
            authViewModel.checkAuthState()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthViewModel())
}
