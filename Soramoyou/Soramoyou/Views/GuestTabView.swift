//
//  GuestTabView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct GuestTabView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // ホーム（空の写真一覧を閲覧可能）
            HomeView()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("ホーム")
                }
                .tag(0)

            // 検索
            SearchView()
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("検索")
                }
                .tag(1)

            // ログイン促進タブ（投稿・プロフィールの代わり）
            GuestPromptView()
                .tabItem {
                    Image(systemName: "person.crop.circle.badge.plus")
                    Text("ログイン")
                }
                .tag(2)
        }
        .tint(Color(red: 0.39, green: 0.58, blue: 0.93))
    }
}

/// ゲストユーザーにログインを促すビュー
struct GuestPromptView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var showLogin = false
    @State private var showSignUp = false

    var body: some View {
        NavigationView {
            ZStack {
                // 背景グラデーション
                LinearGradient(
                    colors: [
                        Color(red: 0.68, green: 0.85, blue: 0.90),
                        Color(red: 0.53, green: 0.81, blue: 0.98),
                        Color(red: 0.39, green: 0.58, blue: 0.93)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 32) {
                    // アイコン
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 120, height: 120)

                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.white)
                    }

                    // テキスト
                    VStack(spacing: 12) {
                        Text("アカウントを作成しよう")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)

                        Text("ログインすると空の写真を投稿したり、\nお気に入りを保存できます")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }

                    // ボタン
                    VStack(spacing: 16) {
                        // 新規登録ボタン
                        Button(action: {
                            showSignUp = true
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "person.badge.plus.fill")
                                Text("新規登録")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(Color(red: 0.39, green: 0.58, blue: 0.93))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                Capsule()
                                    .fill(Color.white)
                            )
                        }

                        // ログインボタン
                        Button(action: {
                            showLogin = true
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text("ログイン")
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                Capsule()
                                    .stroke(Color.white, lineWidth: 2)
                            )
                        }

                        // ゲストモード終了
                        Button(action: {
                            authViewModel.isGuest = false
                        }) {
                            Text("ウェルカム画面に戻る")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
        }
    }
}

struct GuestTabView_Previews: PreviewProvider {
    static var previews: some View {
        GuestTabView()
            .environmentObject(AuthViewModel())
    }
}
