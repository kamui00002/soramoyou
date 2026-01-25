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

    init(
        authService: AuthServiceProtocol = AuthService(),
        firestoreService: FirestoreServiceProtocol = FirestoreService()
    ) {
        self.authService = authService
        self.firestoreService = firestoreService

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
            // 1. Firebase Authenticationで新規登録
            let user = try await authService.signUp(email: email, password: password)

            // 2. Firestoreにユーザードキュメントを作成
            let newUser = User(
                id: user.id,
                email: user.email,
                displayName: user.displayName ?? email.split(separator: "@").first.map(String.init),
                photoURL: user.photoURL,
                bio: nil,
                customEditTools: nil,
                customEditToolsOrder: nil,
                followersCount: 0,
                followingCount: 0,
                postsCount: 0,
                createdAt: Date(),
                updatedAt: Date()
            )

            // Firestoreに保存
            let createdUser = try await firestoreService.updateUser(newUser)

            // 3. 状態を更新
            currentUser = createdUser
            isAuthenticated = true

            // ユーザーIDをLoggingServiceに設定
            LoggingService.shared.setUserID(createdUser.id)

            print("✅ 新規登録成功: ユーザーID=\(createdUser.id), メール=\(email)")
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
            // 1. Firebase Authenticationで匿名ログイン
            let user = try await authService.signInAnonymously()

            // 2. Firestoreにユーザードキュメントが存在するか確認
            do {
                // 既存のユーザードキュメントを取得
                let existingUser = try await firestoreService.fetchUser(userId: user.id)
                currentUser = existingUser
                print("✅ 匿名ログイン成功: 既存ユーザー (ID=\(user.id))")
            } catch FirestoreServiceError.notFound {
                // ユーザードキュメントが存在しない場合は新規作成
                let newUser = User(
                    id: user.id,
                    email: nil,
                    displayName: "ゲストユーザー",
                    photoURL: nil,
                    bio: nil,
                    customEditTools: nil,
                    customEditToolsOrder: nil,
                    followersCount: 0,
                    followingCount: 0,
                    postsCount: 0,
                    createdAt: Date(),
                    updatedAt: Date()
                )

                // Firestoreに保存
                let createdUser = try await firestoreService.updateUser(newUser)
                currentUser = createdUser
                print("✅ 匿名ログイン成功: 新規ユーザードキュメント作成 (ID=\(user.id))")
            }

            // 3. 状態を更新
            isAuthenticated = true
            LoggingService.shared.setUserID(user.id)
        } catch {
            ErrorHandler.logError(error, context: "AuthViewModel.signInAnonymously")
            errorMessage = error.userFriendlyMessage
            throw error
        }
    }

    /// ゲストモードで閲覧（Firebase認証なし）
    func enterGuestMode() async {
        errorMessage = nil

        // 既存の認証セッションがある場合はサインアウト
        if isAuthenticated {
            do {
                try await authService.signOut()
            } catch {
                ErrorHandler.logError(error, context: "AuthViewModel.enterGuestMode")
                // サインアウトエラーは無視してゲストモードに移行
            }
        }

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
            isGuest = false  // ゲストモードもリセット

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

            // 認証状態が変化したらゲストモードを解除
            if user != nil {
                isGuest = false
            }

            // ユーザーIDをLoggingServiceに設定/クリア
            if let user = user {
                LoggingService.shared.setUserID(user.id)
            } else {
                LoggingService.shared.setUserID(nil)
            }
        }
    }
}
