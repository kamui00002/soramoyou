//
//  WelcomeView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var showLogin = false
    @State private var showSignUp = false
    @State private var cloudOffset: CGFloat = 0
    @State private var cloudOpacity: Double = 0.8

    var body: some View {
        ZStack {
            // 空のグラデーション背景
            LinearGradient(
                colors: [
                    Color(red: 0.68, green: 0.85, blue: 0.90),  // 淡い空色
                    Color(red: 0.53, green: 0.81, blue: 0.98),  // 空色
                    Color(red: 0.39, green: 0.58, blue: 0.93)   // 深い空色
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // 装飾的な雲
            cloudsLayer

            // メインコンテンツ
            VStack(spacing: 0) {
                Spacer()

                // ロゴ・タイトルエリア
                VStack(spacing: 16) {
                    // アプリアイコン風の雲
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.3))
                            .frame(width: 120, height: 120)
                            .blur(radius: 10)

                        Image(systemName: "cloud.sun.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.white, .white.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                    }

                    Text("そらもよう")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)

                    Text("空を撮る、空を集める")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                }
                .padding(.bottom, 60)

                Spacer()

                // ボタンエリア（グラスモーフィズム）
                VStack(spacing: 16) {
                    // 新規登録ボタン
                    Button(action: {
                        showSignUp = true
                    }) {
                        Text("新規登録")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.white.opacity(0.25))
                                    .background(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(.white.opacity(0.5), lineWidth: 1)
                                    )
                            )
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                    }

                    // ログインボタン
                    Button(action: {
                        showLogin = true
                    }) {
                        Text("ログイン")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(.white.opacity(0.15))
                                    .background(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(.white.opacity(0.3), lineWidth: 1)
                                    )
                            )
                    }

                    // ゲストとして閲覧ボタン
                    Button(action: {
                        authViewModel.enterGuestMode()
                    }) {
                        Text("ゲストとして閲覧")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 50)
            }
        }
        .onAppear {
            startCloudAnimation()
        }
        .sheet(isPresented: $showLogin) {
            LoginView()
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
        }
    }

    // MARK: - 雲のレイヤー

    private var cloudsLayer: some View {
        GeometryReader { geometry in
            ZStack {
                // 上部の雲
                cloudShape
                    .fill(.white.opacity(0.6))
                    .frame(width: 200, height: 80)
                    .offset(x: cloudOffset - 50, y: geometry.size.height * 0.1)

                cloudShape
                    .fill(.white.opacity(0.4))
                    .frame(width: 150, height: 60)
                    .offset(x: geometry.size.width - cloudOffset - 100, y: geometry.size.height * 0.15)

                // 中央の雲
                cloudShape
                    .fill(.white.opacity(0.5))
                    .frame(width: 180, height: 70)
                    .offset(x: cloudOffset + 20, y: geometry.size.height * 0.35)

                // 下部の雲
                cloudShape
                    .fill(.white.opacity(0.3))
                    .frame(width: 220, height: 90)
                    .offset(x: geometry.size.width - cloudOffset - 150, y: geometry.size.height * 0.6)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 雲の形状

    private var cloudShape: some Shape {
        CloudShape()
    }

    // MARK: - アニメーション

    private func startCloudAnimation() {
        withAnimation(
            Animation.easeInOut(duration: 8)
                .repeatForever(autoreverses: true)
        ) {
            cloudOffset = 30
        }
    }
}

struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        WelcomeView()
            .environmentObject(AuthViewModel())
    }
}
