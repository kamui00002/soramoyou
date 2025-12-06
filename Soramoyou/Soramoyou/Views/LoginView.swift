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
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                    
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
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
                        Task {
                            isLoading = true
                            errorMessage = ""
                            do {
                                try await authViewModel.signIn(email: email, password: password)
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
                            Text("ログイン")
                        }
                    }
                    .disabled(isLoading || email.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("ログイン")
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

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(AuthViewModel())
    }
}


