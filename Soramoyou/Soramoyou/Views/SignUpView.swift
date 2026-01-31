//
//  SignUpView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct SignUpView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage = ""
    @State private var isLoading = false
    @State private var showContent = false
    @FocusState private var focusedField: Field?

    enum Field {
        case email, password, confirmPassword
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

                // タイトル
                VStack(spacing: DesignTokens.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        DesignTokens.Colors.success.opacity(0.3),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 20,
                                    endRadius: 60
                                )
                            )
                            .frame(width: 120, height: 120)
                            .blur(radius: 15)

                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 65))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, .white.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(DesignTokens.Shadow.medium)
                    }

                    Text("はじめまして")
                        .font(.system(size: DesignTokens.Typography.titleSize, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(DesignTokens.Shadow.text)

                    Text("空の写真を共有しましょう")
                        .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)
                .padding(.bottom, DesignTokens.Spacing.lg)

                // フォーム
                ScrollView(showsIndicators: false) {
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
                            placeholder: "パスワード（6文字以上）",
                            text: $password,
                            icon: "lock",
                            isSecure: true,
                            onSubmit: { focusedField = .confirmPassword }
                        )
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .password)

                        // パスワード強度インジケーター
                        if !password.isEmpty {
                            PasswordStrengthIndicator(password: password)
                        }

                        // パスワード確認入力
                        GlassInputField(
                            placeholder: "パスワード確認",
                            text: $confirmPassword,
                            icon: "lock.rotation",
                            isSecure: true,
                            onSubmit: { attemptSignUp() }
                        )
                        .textContentType(.newPassword)
                        .focused($focusedField, equals: .confirmPassword)

                        // パスワード一致チェック
                        if !confirmPassword.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                                Text(passwordsMatch ? "パスワードが一致しています" : "パスワードが一致しません")
                                    .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: .medium))
                            }
                            .foregroundColor(passwordsMatch ? DesignTokens.Colors.success : DesignTokens.Colors.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DesignTokens.Spacing.xs)
                        }

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

                        // 新規登録ボタン
                        Button(action: attemptSignUp) {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 18))
                                    Text("アカウントを作成")
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
                                                colors: [
                                                    DesignTokens.Colors.success,
                                                    DesignTokens.Colors.auroraGreen
                                                ],
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

                        // 利用規約
                        Text("登録することで、利用規約とプライバシーポリシーに同意したことになります。")
                            .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: .regular))
                            .foregroundColor(DesignTokens.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.top, DesignTokens.Spacing.sm)

                        Spacer()
                            .frame(height: 50)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 30)
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
        !email.isEmpty && password.count >= 6 && passwordsMatch
    }

    private var passwordsMatch: Bool {
        !confirmPassword.isEmpty && password == confirmPassword
    }

    // MARK: - Methods

    private func attemptSignUp() {
        guard isFormValid else {
            if password != confirmPassword {
                withAnimation(DesignTokens.Animation.quickSpring) {
                    errorMessage = "パスワードが一致しません"
                }
            }
            return
        }

        focusedField = nil

        Task {
            isLoading = true
            errorMessage = ""

            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()

            do {
                try await authViewModel.signUp(email: email, password: password)
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

// MARK: - Password Strength Indicator ☀️

struct PasswordStrengthIndicator: View {
    let password: String

    private var strength: PasswordStrength {
        if password.count < 6 { return .weak }
        if password.count < 8 { return .medium }
        if password.count >= 8 && hasNumbers && hasUppercase { return .strong }
        return .medium
    }

    private var hasNumbers: Bool {
        password.range(of: "[0-9]", options: .regularExpression) != nil
    }

    private var hasUppercase: Bool {
        password.range(of: "[A-Z]", options: .regularExpression) != nil
    }

    enum PasswordStrength {
        case weak, medium, strong

        var color: Color {
            switch self {
            case .weak: return Color(red: 0.9, green: 0.4, blue: 0.4)
            case .medium: return DesignTokens.Colors.warning
            case .strong: return DesignTokens.Colors.success
            }
        }

        var label: String {
            switch self {
            case .weak: return "弱い"
            case .medium: return "普通"
            case .strong: return "強い"
            }
        }

        var progress: CGFloat {
            switch self {
            case .weak: return 0.33
            case .medium: return 0.66
            case .strong: return 1.0
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // プログレスバー
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(strength.color)
                        .frame(width: geometry.size.width * strength.progress, height: 4)
                        .animation(DesignTokens.Animation.quickSpring, value: strength.progress)
                }
            }
            .frame(height: 4)

            // ラベル
            Text("パスワード強度: \(strength.label)")
                .font(.system(size: DesignTokens.Typography.smallCaptionSize, weight: .medium))
                .foregroundColor(strength.color)
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
    }
}

struct SignUpView_Previews: PreviewProvider {
    static var previews: some View {
        SignUpView()
            .environmentObject(AuthViewModel())
    }
}
