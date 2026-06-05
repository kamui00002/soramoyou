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
    /// ゴールデンアワー通知の有効状態（永続化は GoldenHourNotificationManager と同じ UserDefaults キー）
    @Published var isGoldenHourNotificationEnabled =
        UserDefaults.standard.bool(forKey: GoldenHourNotificationManager.DefaultsKey.enabled)
    /// 通知を有効化できなかった時のメッセージ（設定アプリへの誘導アラートに使う）
    @Published var goldenHourPermissionMessage: String?

    private let authService: AuthServiceProtocol
    private let firestoreService: FirestoreServiceProtocol

    /// ゴールデンアワー通知の切替処理（直近の Task）。連打時の直列化に使う。
    private var goldenHourToggleTask: Task<Void, Never>?

    init(authService: AuthServiceProtocol = AuthService(),
         firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.authService = authService
        self.firestoreService = firestoreService
    }

    // MARK: - ゴールデンアワー通知

    /// ゴールデンアワー通知のトグル切り替え（FIFO 直列化）。
    ///
    /// トグルの Binding は切替ごとに独立した Task を起動する。enable() は権限確認 +
    /// 位置取得で長く suspend するため、未管理のまま並行させると「ON 直後に OFF →
    /// 遅れて ON 側が復帰して通知を再登録」という操作と逆の最終状態になり得る。
    /// 直前の切替の完了を待ってから実行することで、最後の操作が必ず最終状態になる。
    func setGoldenHourNotification(enabled: Bool) async {
        let previous = goldenHourToggleTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performGoldenHourToggle(enabled: enabled)
        }
        goldenHourToggleTask = task
        await task.value
    }

    /// トグル切り替えの本体。
    /// ON: 通知権限 → 位置権限+現在地取得 → スケジュール（いずれか失敗時はトグルを戻して誘導メッセージ）
    /// OFF: 登録済み通知をすべて削除
    private func performGoldenHourToggle(enabled: Bool) async {
        guard enabled else {
            await GoldenHourNotificationManager.shared.disable()
            isGoldenHourNotificationEnabled = false
            return
        }

        switch await GoldenHourNotificationManager.shared.enable() {
        case .enabled:
            isGoldenHourNotificationEnabled = true
        case .notificationPermissionDenied:
            isGoldenHourNotificationEnabled = false
            goldenHourPermissionMessage = "通知が許可されていません。設定アプリで「そらもよう」の通知を許可してください。"
        case .locationPermissionDenied:
            isGoldenHourNotificationEnabled = false
            goldenHourPermissionMessage = "日没時刻の計算におおよその位置情報が必要です。設定アプリで位置情報の利用を許可してください。"
        case .locationUnavailable:
            isGoldenHourNotificationEnabled = false
            goldenHourPermissionMessage = "現在地を取得できませんでした。時間をおいて再度お試しください。"
        }
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

            // 1.5 端末内のパーソナルAI編集コーパスを削除（プライバシー: 退会後に学習データを残さない）
            RecipeCorpusStore().clear(userId: userId)

            // 2. Firebase Authのアカウントを削除
            try await authService.deleteAccount()

            return true
        } catch let error as AuthError where error == .requiresRecentLogin {
            // 再認証が必要
            showingReauthentication = true
            return false
        } catch {
            ErrorHandler.logError(error, context: "SettingsViewModel.performAccountDeletion", userId: userId)
            deleteAccountError = "アカウントの削除に失敗しました: \(error.userFriendlyMessage)"
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

            // 2.5 端末内のパーソナルAI編集コーパスを削除（プライバシー: 退会後に学習データを残さない）
            RecipeCorpusStore().clear(userId: userId)

            // 3. Firebase Authのアカウントを削除
            try await authService.deleteAccount()

            return true
        } catch {
            ErrorHandler.logError(error, context: "SettingsViewModel.performReauthAndDelete", userId: userId)
            deleteAccountError = "アカウントの削除に失敗しました: \(error.userFriendlyMessage)"
            return false
        }
    }
}
