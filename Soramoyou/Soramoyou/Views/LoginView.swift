//
//  LoginView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct LoginView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var showContent = false
    @FocusState private var focusedField: Field?

    enum Field {
        case email, password
    }

    var body: some View {
        SkyBackgroundView(showClouds: true) {
            VStack(spacing: 0) {
                // ヘッダー
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(DesignTokens.Colors.glassTertiary)
                            )
                    }
                    .padding()
                }

                Spacer()

                // タイトル
                VStack(spacing: DesignTokens.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        DesignTokens.Colors.selectionAccent.opacity(0.3),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 20,
                                    endRadius: 60
                                )
                            )
                            .frame(width: 120, height: 120)
                            .blur(radius: 15)

                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, .white.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(DesignTokens.Shadow.medium)
                    }

                    Text("おかえりなさい")
                        .font(.system(size: DesignTokens.Typography.titleSize, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(DesignTokens.Shadow.text)
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
                .padding(.bottom, DesignTokens.Spacing.xl)

                // フォーム
                VStack(spacing: DesignTokens.Spacing.md) {
                    // メールアドレス入力
                    GlassInputField(
                        placeholder: "メールアドレス",
                        text: $email,
                        icon: "envelope",
                        onSubmit: { focusedField = .password }
                    )
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .focused($focusedField, equals: .email)

                    // パスワード入力
                    GlassInputField(
                        placeholder: "パスワード",
                        text: $password,
                        icon: "lock",
                        isSecure: true,
                        onSubmit: { attemptLogin() }
                    )
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)

                    // エラーメッセージ
                    if !errorMessage.isEmpty || (authViewModel.errorMessage != nil && !authViewModel.errorMessage!.isEmpty) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(DesignTokens.Colors.warning)
                            Text(errorMessage.isEmpty ? (authViewModel.errorMessage ?? "") : errorMessage)
                                .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium))
                        }
                        .foregroundColor(DesignTokens.Colors.textDark)
                        .padding(DesignTokens.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.md)
                                .fill(Color.white.opacity(0.95))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }

                    // ログインボタン
                    Button(action: attemptLogin) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.system(size: 18))
                                Text("ログイン")
                                    .font(.system(size: DesignTokens.Typography.buttonSize, weight: .semibold, design: .rounded))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.md)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                                    .fill(
                                        LinearGradient(
                                            colors: DesignTokens.Colors.accentGradient,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )

                                RoundedRectangle(cornerRadius: DesignTokens.Radius.button)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            }
                        )
                        .shadow(isFormValid ? DesignTokens.Shadow.glow : DesignTokens.Shadow.button)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .disabled(isLoading || !isFormValid)
                    .opacity(isFormValid ? 1.0 : 0.6)
                    .padding(.top, DesignTokens.Spacing.sm)

                    // パスワードを忘れた場合
                    Button(action: {
                        // TODO: パスワードリセット機能
                    }) {
                        Text("パスワードをお忘れですか？")
                            .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    .padding(.top, DesignTokens.Spacing.sm)
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 30)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            withAnimation(DesignTokens.Animation.smoothSpring.delay(0.1)) {
                showContent = true
            }
        }
    }

    // MARK: - Computed Properties

    private var isFormValid: Bool {
        !email.isEmpty && !password.isEmpty
    }

    // MARK: - Methods

    private func attemptLogin() {
        guard isFormValid else { return }
        focusedField = nil

        Task {
            isLoading = true
            errorMessage = ""

            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()

            do {
                try await authViewModel.signIn(email: email, password: password)
                let successFeedback = UINotificationFeedbackGenerator()
                successFeedback.notificationOccurred(.success)
                dismiss()
            } catch {
                let errorFeedback = UINotificationFeedbackGenerator()
                errorFeedback.notificationOccurred(.error)
                withAnimation(DesignTokens.Animation.quickSpring) {
                    errorMessage = error.localizedDescription
                }
            }
            isLoading = false
        }
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AuthViewModel())
    }
}
