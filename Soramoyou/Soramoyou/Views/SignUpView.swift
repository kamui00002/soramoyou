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

    var body: some View {
        SkyBackgroundView(showClouds: true) {
            VStack(spacing: 0) {
                // ヘッダー
                HStack {
                    Spacer()
                    Button("キャンセル") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding()
                }

                Spacer()

                // タイトル
                VStack(spacing: 12) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 60))
                        .foregroundColor(.white.opacity(0.9))

                    Text("新規登録")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.bottom, 32)

                // フォーム
                ScrollView {
                    VStack(spacing: 16) {
                        // メールアドレス入力
                        VStack(alignment: .leading, spacing: 8) {
                            Text("メールアドレス")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))

                            TextField("example@email.com", text: $email)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.white.opacity(0.2))
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(.white.opacity(0.3), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.white)
                        }

                        // パスワード入力
                        VStack(alignment: .leading, spacing: 8) {
                            Text("パスワード")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))

                            SecureField("6文字以上", text: $password)
                                .textContentType(.newPassword)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.white.opacity(0.2))
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(.white.opacity(0.3), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.white)
                        }

                        // パスワード確認入力
                        VStack(alignment: .leading, spacing: 8) {
                            Text("パスワード確認")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))

                            SecureField("もう一度入力", text: $confirmPassword)
                                .textContentType(.newPassword)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.white.opacity(0.2))
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(.white.opacity(0.3), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.white)
                        }

                        // エラーメッセージ
                        if !errorMessage.isEmpty {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(errorMessage)
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.white.opacity(0.9))
                            )
                        }

                        if let authError = authViewModel.errorMessage, !authError.isEmpty {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text(authError)
                            }
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(.white.opacity(0.9))
                            )
                        }

                        // 新規登録ボタン
                        Button(action: {
                            guard password == confirmPassword else {
                                errorMessage = "パスワードが一致しません"
                                return
                            }

                            Task {
                                isLoading = true
                                errorMessage = ""
                                do {
                                    try await authViewModel.signUp(email: email, password: password)
                                    dismiss()
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                                isLoading = false
                            }
                        }) {
                            HStack {
                                if isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Text("新規登録")
                                }
                            }
                        }
                        .buttonStyle(GlassButtonStyle(isPrimary: true))
                        .disabled(isLoading || email.isEmpty || password.isEmpty || confirmPassword.isEmpty)
                        .opacity(email.isEmpty || password.isEmpty || confirmPassword.isEmpty ? 0.6 : 1.0)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 32)
                }

                Spacer()
            }
        }
    }
}

struct SignUpView_Previews: PreviewProvider {
    static var previews: some View {
        SignUpView()
            .environmentObject(AuthViewModel())
    }
}
