//
//  SettingsViewModel.swift
//  Soramoyou
//
//  設定画面のViewModel
//  アカウント削除等のビジネスロジックをViewから分離
//

import Foundation

/// 設定画面のViewModel
@MainActor
class SettingsViewModel: ObservableObject {
    /// アカウント削除中フラグ
    @Published var isDeletingAccount = false
    /// アカウント削除エラー
    @Published var deleteAccountError: String?
    /// 再認証が必要かどうか
    @Published var showingReauthentication = false

    private let authService: AuthServiceProtocol
    private let firestoreService: FirestoreServiceProtocol

    init(authService: AuthServiceProtocol = AuthService(),
         firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.authService = authService
        self.firestoreService = firestoreService
    }

    /// アカウント削除を実行
    func performAccountDeletion() async -> Bool {
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        guard let userId = authService.currentUser()?.id else {
            deleteAccountError = "ユーザー情報を取得できません"
            return false
        }

        do {
            // 1. Firestoreのユーザーデータを削除
            try await firestoreService.deleteUserData(userId: userId)

            // 2. Firebase Authのアカウントを削除
            try await authService.deleteAccount()

            return true
        } catch let error as AuthError where error == .requiresRecentLogin {
            // 再認証が必要
            showingReauthentication = true
            return false
        } catch {
            ErrorHandler.logError(error, context: "SettingsViewModel.performAccountDeletion", userId: userId)
            deleteAccountError = "アカウントの削除に失敗しました: \(error.localizedDescription)"
            return false
        }
    }

    /// 再認証後にアカウント削除を実行
    func performReauthAndDelete(email: String, password: String) async -> Bool {
        isDeletingAccount = true
        defer { isDeletingAccount = false }

        guard let userId = authService.currentUser()?.id else {
            deleteAccountError = "ユーザー情報を取得できません"
            return false
        }

        do {
            // 1. 再認証
            try await authService.reauthenticate(email: email, password: password)

            // 2. Firestoreのユーザーデータを削除
            try await firestoreService.deleteUserData(userId: userId)

            // 3. Firebase Authのアカウントを削除
            try await authService.deleteAccount()

            return true
        } catch {
            ErrorHandler.logError(error, context: "SettingsViewModel.performReauthAndDelete", userId: userId)
            deleteAccountError = "アカウントの削除に失敗しました: \(error.localizedDescription)"
            return false
        }
    }
}
