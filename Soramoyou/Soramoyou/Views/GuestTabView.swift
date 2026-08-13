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

    /// ゲストタブの画面名（PostHog 上の表示名）☁️
    ///
    /// ⭐️ ログイン後の「ホーム」「検索」とは**あえて別名**にしている。
    ///    同名にするとログイン済みユーザーの画面数にゲストの閲覧が混ざり、
    ///    「ログイン済みだけの数」を後から取り出せなくなる（情報が失われる）。
    ///    別名にしておけば、合算も分離もダッシュボード側で選べる。
    private func screenName(for tab: Int) -> String {
        switch tab {
        case 0: return "ゲスト: ホーム"
        case 1: return "ゲスト: 検索"
        case 2: return "ゲスト: ログイン促進"
        default: return "ゲスト: 不明"
        }
    }

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
        .task {
            // 画面計測: 起動直後に表示されているタブを1回だけ記録する（切替は下の onChange が拾う）。
            // ⭐️ MainTabView と同じく `selectedTab` を単一の真実源にする。各画面側の `.onAppear`
            //    （SwiftUI の仕様で複数回発火しうる）に置く方式より重複計上に強い。
            //    GuestTabView と MainTabView は ContentView の排他分岐なので二重計上はしない。
            LoggingService.shared.logScreen(screenName(for: selectedTab))
        }
        .onChange(of: selectedTab) { newTab in
            // タブ切替。1引数クロージャ形式は本コードベース既存の書き方に合わせている
            // （deployment target は iOS 16.0 のため 2引数形式は使えない）。
            LoggingService.shared.logScreen(screenName(for: newTab))
        }
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
        .navigationViewStyle(.stack)
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
