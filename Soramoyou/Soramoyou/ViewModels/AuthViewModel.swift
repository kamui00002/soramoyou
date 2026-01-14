//
//  AuthViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import Combine
import FirebaseAuth

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = false
    @Published var currentUser: User?
    @Published var errorMessage: String?
    @Published var isGuest = false

    private let authService: AuthServiceProtocol
    private var authStateTask: Task<Void, Never>?
    
    init(authService: AuthServiceProtocol = AuthService()) {
        self.authService = authService

        // 初期認証状態の確認（自動ログイン）
        checkAuthState()

        // 認証状態の監視（メモリリーク防止のため weak self を使用）
        authStateTask = Task { [weak self] in
            guard let self = self else { return }
            await self.observeAuthState()
        }
    }

    deinit {
        // Taskをキャンセルしてリソースを解放
        authStateTask?.cancel()
    }
    
    func signIn(email: String, password: String) async throws {
        errorMessage = nil

        do {
            let user = try await authService.signIn(email: email, password: password)
            currentUser = user
            isAuthenticated = true

            // ユーザーIDをLoggingServiceに設定
            LoggingService.shared.setUserID(user.id)
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "AuthViewModel.signIn")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
            throw error
        }
    }
    
    func signUp(email: String, password: String) async throws {
        errorMessage = nil

        do {
            let user = try await authService.signUp(email: email, password: password)
            currentUser = user
            isAuthenticated = true

            // ユーザーIDをLoggingServiceに設定
            LoggingService.shared.setUserID(user.id)
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "AuthViewModel.signUp")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
            throw error
        }
    }

    func signInAnonymously() async throws {
        errorMessage = nil

        do {
            let user = try await authService.signInAnonymously()
            currentUser = user
            isAuthenticated = true

            LoggingService.shared.setUserID(user.id)
        } catch {
            ErrorHandler.logError(error, context: "AuthViewModel.signInAnonymously")
            errorMessage = error.userFriendlyMessage
            throw error
        }
    }

    /// ゲストモードで閲覧（Firebase認証なし）
    func enterGuestMode() {
        errorMessage = nil
        currentUser = nil
        isAuthenticated = false
        isGuest = true
        LoggingService.shared.setUserID(nil)
    }

    func signOut() async throws {
        errorMessage = nil

        do {
            try await authService.signOut()
            currentUser = nil
            isAuthenticated = false

            // ユーザーIDをLoggingServiceからクリア
            LoggingService.shared.setUserID(nil)
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "AuthViewModel.signOut")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
            throw error
        }
    }
    
    /// 初期化時に現在の認証状態を確認（自動ログイン）
    func checkAuthState() {
        if let user = authService.currentUser() {
            currentUser = user
            isAuthenticated = true

            // ユーザーIDをLoggingServiceに設定
            LoggingService.shared.setUserID(user.id)
        } else {
            currentUser = nil
            isAuthenticated = false

            // ユーザーIDをLoggingServiceからクリア
            LoggingService.shared.setUserID(nil)
        }
    }
    
    private func observeAuthState() async {
        for await user in authService.observeAuthState() {
            currentUser = user
            isAuthenticated = user != nil

            // ユーザーIDをLoggingServiceに設定/クリア
            if let user = user {
                LoggingService.shared.setUserID(user.id)
            } else {
                LoggingService.shared.setUserID(nil)
            }
        }
    }
}
