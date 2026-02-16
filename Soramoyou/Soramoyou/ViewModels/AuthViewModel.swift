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
    private let firestoreService: FirestoreServiceProtocol
    private var authStateTask: Task<Void, Never>?

    init(authService: AuthServiceProtocol = AuthService(),
         firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.authService = authService
        self.firestoreService = firestoreService

        #if DEBUG
        // UIテストモードの場合は認証状態をリセット
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING") &&
           ProcessInfo.processInfo.arguments.contains("RESET_AUTH_STATE") {
            // 認証状態を同期的にリセット
            currentUser = nil
            isAuthenticated = false

            // 認証状態の監視（signOutを先に実行してから監視開始）
            authStateTask = Task { [weak self] in
                // 先にサインアウトを完了させる
                try? await authService.signOut()
                guard let self = self else { return }
                // その後、認証状態の監視を開始
                await self.observeAuthState()
            }
        } else {
            // 初期認証状態の確認（自動ログイン）
            checkAuthState()

            // 認証状態の監視（メモリリーク防止のため weak self を使用）
            authStateTask = Task { [weak self] in
                guard let self = self else { return }
                await self.observeAuthState()
            }
        }
        #else
        // 初期認証状態の確認（自動ログイン）
        checkAuthState()

        // 認証状態の監視（メモリリーク防止のため weak self を使用）
        authStateTask = Task { [weak self] in
            guard let self = self else { return }
            await self.observeAuthState()
        }
        #endif
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
            // 1. Firebase Authでユーザーを作成
            let user = try await authService.signUp(email: email, password: password)

            // 2. Firestoreにユーザー情報を保存
            let _ = try await firestoreService.updateUser(user)

            // 3. 公開プロフィールを作成（機密情報を含まない）
            try await firestoreService.createPublicProfile(from: user)

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
            // 1. Firebase Authで匿名ユーザーを作成
            let user = try await authService.signInAnonymously()

            // 2. Firestoreにユーザー情報を保存（emailはnil）
            let _ = try await firestoreService.updateUser(user)

            // 3. 公開プロフィールを作成
            try await firestoreService.createPublicProfile(from: user)

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
