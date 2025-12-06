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
        NavigationView {
            Form {
                Section {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                    
                    SecureField("パスワード", text: $password)
                        .textContentType(.newPassword)
                    
                    SecureField("パスワード確認", text: $confirmPassword)
                        .textContentType(.newPassword)
                }
                
                if !errorMessage.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .foregroundColor(.red)
                        }
                    }
                }
                
                if let authError = authViewModel.errorMessage, !authError.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(authError)
                                .foregroundColor(.red)
                        }
                    }
                }
                
                Section {
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
                        if isLoading {
                            ProgressView()
                        } else {
                            Text("新規登録")
                        }
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty || confirmPassword.isEmpty)
                }
            }
            .navigationTitle("新規登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }
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


