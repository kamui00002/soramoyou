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

    // MARK: プッシュ通知の配信プレフ（Firestore users/{uid} に保存。端末の通知許可とは別物）
    /// 自分の投稿への いいね/コメント を知らせる
    @Published var notifyReactions = true
    /// フォロー中の人が新規投稿したら知らせる
    @Published var notifyNewPostsFromFollowing = true
    /// 誰かが新規投稿したら知らせる（全員）
    @Published var notifyNewPostsFromEveryone = false
    /// プッシュ通知まわりの案内（許可されていない／保存失敗）。誘導アラートに使う。
    @Published var pushNotificationMessage: String?
    /// 通知プレフのトグル切替（直近 Task）。連打時に最後の操作を最終状態にするための直列化に使う（golden-hour と同様）。
    private var notificationToggleTask: Task<Void, Never>?

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

    // MARK: - プッシュ通知の配信プレフ

    /// プッシュ通知のどれを送るか（端末の許可とは別の「配信内容」プレフ）。
    enum PushPreference {
        case reactions              // 自分の投稿への いいね/コメント
        case newPostsFromFollowing  // フォロー中の人の新規投稿
        case newPostsFromEveryone   // 誰かの新規投稿（全員）
    }

    /// 設定画面を開いたときに、現在の配信プレフを Firestore から読み込む。
    func loadNotificationPreferences() async {
        guard let userId = authService.currentUser()?.id else { return }
        do {
            let user = try await firestoreService.fetchUser(userId: userId)
            notifyReactions = user.notifyReactions
            notifyNewPostsFromFollowing = user.notifyNewPostsFromFollowing
            notifyNewPostsFromEveryone = user.notifyNewPostsFromEveryone
        } catch {
            // 取得失敗時は既定値のまま表示する（保存時に再取得する）。
            ErrorHandler.logError(error, context: "SettingsViewModel.loadNotificationPreferences", userId: userId)
        }
    }

    /// 配信プレフのトグル切り替え（FIFO 直列化）。
    /// トグルの Binding は切替ごとに独立 Task を起動し、保存は await を跨ぐため、未管理だと
    /// 「ON 直後に OFF→遅れて ON 側が復帰して上書き」で操作と逆の最終状態になり得る。
    /// 直前の切替の完了を待ってから実行し、最後の操作を必ず最終状態にする（golden-hour と同様）。
    func setNotificationPreference(_ pref: PushPreference, enabled: Bool) async {
        let previous = notificationToggleTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSetNotificationPreference(pref, enabled: enabled)
        }
        notificationToggleTask = task
        await task.value
    }

    /// トグル切り替えの本体。Firestore へターゲット保存し、ON 時は「良い瞬間」として通知許可を要求する。
    private func performSetNotificationPreference(_ pref: PushPreference, enabled: Bool) async {
        apply(pref, enabled)  // 楽観的に UI 更新

        guard let userId = authService.currentUser()?.id else {
            apply(pref, !enabled)  // 未ログインなら戻す
            return
        }

        do {
            // 通知プレフ3つ（＋updatedAt）だけをターゲット更新。User 全体を書かないので
            // 設定画面を開いている間に増えたフォロー数等を古い値で巻き戻さない。
            try await firestoreService.updateNotificationPreferences(
                userId: userId,
                notifyReactions: notifyReactions,
                notifyNewPostsFromFollowing: notifyNewPostsFromFollowing,
                notifyNewPostsFromEveryone: notifyNewPostsFromEveryone
            )
            LoggingService.shared.logEvent("push_pref_changed", parameters: [
                "pref": prefKey(pref),
                "enabled": enabled
            ])
        } catch {
            apply(pref, !enabled)  // 保存失敗なら戻す
            pushNotificationMessage = "通知設定を保存できませんでした。通信環境をご確認ください。"
            ErrorHandler.logError(error, context: "SettingsViewModel.setNotificationPreference", userId: userId)
            return
        }

        // ON にしたら「良い瞬間」として通知許可を要求＋APNs 登録（拒否なら設定アプリへ誘導）。
        if enabled {
            let granted = await PushNotificationManager.shared.requestAuthorizationAndRegister()
            LoggingService.shared.logEvent("push_permission_result", parameters: ["granted": granted])
            if !granted {
                pushNotificationMessage = "通知がオフになっています。設定アプリで「そらもよう」の通知を許可すると、お知らせが届きます。"
            }
        }
    }

    /// @Published のプレフ値を更新する（楽観的 UI / 巻き戻し用）。
    private func apply(_ pref: PushPreference, _ value: Bool) {
        switch pref {
        case .reactions: notifyReactions = value
        case .newPostsFromFollowing: notifyNewPostsFromFollowing = value
        case .newPostsFromEveryone: notifyNewPostsFromEveryone = value
        }
    }

    /// 計装用のプレフ識別子（イベントパラメータ）。
    private func prefKey(_ pref: PushPreference) -> String {
        switch pref {
        case .reactions: return "reactions"
        case .newPostsFromFollowing: return "following"
        case .newPostsFromEveryone: return "everyone"
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
