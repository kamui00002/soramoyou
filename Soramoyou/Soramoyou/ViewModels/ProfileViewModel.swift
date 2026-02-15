//
//  ProfileViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import Combine
import UIKit

@MainActor
class ProfileViewModel: ObservableObject {
    @Published var user: User?
    @Published var userPosts: [Post] = []
    @Published var equippedTools: [EditTool] = []
    @Published var isLoading = false
    @Published var isLoadingPosts = false
    @Published var errorMessage: String?

    // 編集用の一時的な値
    @Published var editingDisplayName: String = ""
    @Published var editingBio: String = ""
    @Published var editingProfileImage: UIImage?
    @Published var shouldDeleteProfileImage: Bool = false // プロフィール画像を削除するかどうか

    // 編集装備システムの管理（全27ツールの並び替え）
    @Published var availableTools: [EditTool] = EditTool.allCases
    @Published var selectedTools: [EditTool] = EditTool.allCases  // 全ツールを常に選択状態
    @Published var toolsOrder: [String] = []

    /// Auth復元後にuserIdを再取得できるようvarに変更
    private var userId: String?
    /// 外部から指定されたuserIdかどうか（自分のプロフィール判定用）
    private let isExternalUserId: Bool
    private let firestoreService: FirestoreServiceProtocol
    private let storageService: StorageServiceProtocol
    /// 認証サービス（Firebase直参照を排除し、テスタビリティを向上）
    private let authService: AuthServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    // 自分のプロフィールかどうか
    var isOwnProfile: Bool {
        guard let userId = userId,
              let currentUserId = authService.currentUser()?.id else {
            return false
        }
        return userId == currentUserId
    }

    init(
        userId: String? = nil,
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        storageService: StorageServiceProtocol = StorageService(),
        authService: AuthServiceProtocol = AuthService()
    ) {
        self.authService = authService
        self.isExternalUserId = (userId != nil)

        // userIdが指定されていない場合は現在のユーザーIDを使用
        if let userId = userId {
            self.userId = userId
        } else {
            self.userId = authService.currentUser()?.id
        }

        self.firestoreService = firestoreService
        self.storageService = storageService

        // デフォルトで全ツールを選択状態にする
        self.selectedTools = EditTool.allCases
        self.toolsOrder = EditTool.allCases.map { $0.rawValue }
    }
    
    /// Auth状態が復元された後にuserIdを再取得してプロフィールをリロード
    /// Firebase Auth復元前にProfileViewが初期化された場合の対策
    func refreshUserIdIfNeeded() async {
        // 外部指定のuserIdがある場合はスキップ
        guard !isExternalUserId else { return }
        
        // userIdがnilの場合、Auth復元後に再取得を試みる
        if userId == nil {
            if let currentUserId = authService.currentUser()?.id {
                userId = currentUserId
                await loadProfile()
                await loadUserPosts()
            }
        }
    }
    
    // MARK: - Load Profile
    
    /// プロフィール情報を読み込む
    func loadProfile() async {
        guard let userId = userId else {
            // 未ログイン時はエラーを表示しない
            return
        }

        isLoading = true
        errorMessage = nil
        // すべてのパス（early return含む）で確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // リトライ可能な操作として実行
            let fetchedUser = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.fetchUser(userId: userId)
            }
            user = fetchedUser

            // 編集用の値を設定
            editingDisplayName = fetchedUser.displayName ?? ""
            editingBio = fetchedUser.bio ?? ""

            // 編集装備を読み込む（自分のプロフィールの場合のみ）
            if isOwnProfile {
                await loadEditTools()
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "ProfileViewModel.loadProfile", userId: userId)

            // notFoundエラーや権限エラーの場合はユーザーにエラーを表示しない
            // （新規ユーザーやドキュメント未作成の正常なケース）
            if let firestoreError = error as? FirestoreServiceError {
                switch firestoreError {
                case .notFound:
                    // ドキュメントが存在しない場合はデフォルト状態で表示
                    setDefaultEditTools()
                    return
                case .fetchFailed(let underlyingError):
                    // 権限エラーの場合もエラーを表示しない
                    if let nsError = underlyingError as NSError?,
                       nsError.domain == "FIRFirestoreErrorDomain",
                       nsError.code == 7 { // PERMISSION_DENIED
                        setDefaultEditTools()
                        return
                    }
                default:
                    break
                }
            }

            // その他のエラーの場合のみユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }
    
    /// 編集装備を読み込む（内部用）
    /// 全27ツールの順序のみを管理
    private func loadEditTools() async {
        guard userId != nil,
              let user = user else {
            return
        }

        // customEditToolsOrderから順序を復元
        if let toolsOrderFromUser = user.customEditToolsOrder,
           !toolsOrderFromUser.isEmpty {
            // 順序に従ってEditToolを取得
            var orderedTools: [EditTool] = []
            for toolId in toolsOrderFromUser {
                if let tool = EditTool(rawValue: toolId) {
                    orderedTools.append(tool)
                }
            }

            // 順序に含まれていないツールも追加（後ろに追加）
            for tool in EditTool.allCases {
                if !orderedTools.contains(tool) {
                    orderedTools.append(tool)
                }
            }

            equippedTools = orderedTools
            selectedTools = orderedTools
            self.toolsOrder = orderedTools.map { $0.rawValue }
        } else {
            // デフォルトは全ツールをそのままの順序で
            setDefaultEditTools()
        }
    }

    /// 編集装備設定のみを読み込む（EditToolsSettingsView用）
    /// エラーが発生してもアラートを表示せず、デフォルトのツールを使用する
    func loadEditToolsSettings() async {
        guard let userId = userId else {
            // 未ログイン時はデフォルトのツールを使用
            setDefaultEditTools()
            return
        }

        isLoading = true
        // すべてのパスで確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // ユーザードキュメントの取得を試みる
            let fetchedUser = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.fetchUser(userId: userId)
            }
            user = fetchedUser

            // 編集装備を読み込む
            await loadEditTools()
        } catch {
            // エラーが発生した場合はデフォルトのツールを使用
            // エラーメッセージは表示しない（EditToolsSettingsViewでは不要）
            ErrorHandler.logError(error, context: "ProfileViewModel.loadEditToolsSettings", userId: userId)
            setDefaultEditTools()
        }
    }

    /// デフォルトの編集装備を設定（全27ツール）
    private func setDefaultEditTools() {
        let allTools = EditTool.allCases
        equippedTools = allTools
        selectedTools = allTools
        toolsOrder = allTools.map { $0.rawValue }
    }
    
    // MARK: - Load Posts
    
    /// ユーザーの投稿一覧を読み込む
    func loadUserPosts() async {
        guard let userId = userId else {
            return
        }

        isLoadingPosts = true
        // エラーメッセージはリセットしない（loadProfileで設定されている可能性があるため）
        // すべてのパス（early return含む）で確実にローディング状態を解除する
        defer { isLoadingPosts = false }

        do {
            // リトライ可能な操作として実行
            let posts = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.fetchUserPosts(
                    userId: userId,
                    limit: 50,
                    lastDocument: nil
                )
            }

            // 他ユーザーのプロフィールの場合は公開投稿のみフィルタリング
            if !isOwnProfile {
                userPosts = posts.filter { $0.visibility == .public }
            } else {
                userPosts = posts
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "ProfileViewModel.loadUserPosts", userId: userId)

            // 権限エラーの場合はエラーを表示しない（新規ユーザーやドキュメント未作成の正常なケース）
            if let firestoreError = error as? FirestoreServiceError {
                switch firestoreError {
                case .notFound:
                    // 投稿がない場合は正常
                    return
                case .fetchFailed(let underlyingError):
                    // 権限エラーの場合もエラーを表示しない
                    if let nsError = underlyingError as NSError?,
                       nsError.domain == "FIRFirestoreErrorDomain",
                       nsError.code == 7 { // PERMISSION_DENIED
                        return
                    }
                default:
                    break
                }
            }

            // その他のエラーの場合のみユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }
    
    // MARK: - Update Profile
    
    /// プロフィール情報を更新
    func updateProfile() async {
        guard let userId = userId,
              var updatedUser = user else {
            errorMessage = "ユーザー情報が取得できません"
            return
        }

        isLoading = true
        errorMessage = nil
        // すべてのパスで確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // プロフィール画像の処理
            var photoURL = updatedUser.photoURL
            
            if shouldDeleteProfileImage {
                // 既存の画像を削除（リトライ可能）
                if photoURL != nil {
                    // Storageから画像を削除（storage.rules のパス形式: users/{userId}/profile/{imageId}）
                    let path = "users/\(userId)/profile/profile.jpg"
                    try? await RetryableOperation.executeIfRetryable { [self] in
                        try await self.storageService.deleteImage(path: path)
                    }
                }
                photoURL = nil
            } else if let profileImage = editingProfileImage {
                // 新しい画像をアップロード（リトライ可能）
                // storage.rules のパス形式: users/{userId}/profile/{imageId}
                let imagePath = "users/\(userId)/profile/profile.jpg"
                let uploadedURL = try await RetryableOperation.executeIfRetryable { [self] in
                    try await self.storageService.uploadImage(profileImage, path: imagePath)
                }
                photoURL = uploadedURL.absoluteString
            }
            
            // ユーザー情報を更新
            updatedUser.displayName = editingDisplayName.isEmpty ? nil : editingDisplayName
            updatedUser.bio = editingBio.isEmpty ? nil : editingBio
            updatedUser.photoURL = photoURL
            updatedUser.updatedAt = Date()
            
            // Firestoreに更新（リトライ可能）
            let savedUser = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.updateUser(updatedUser)
            }
            user = savedUser
            
            // 編集用の値をリセット
            editingProfileImage = nil
            shouldDeleteProfileImage = false
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "ProfileViewModel.updateProfile", userId: userId)
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }

    // MARK: - Edit Tools Management
    
    /// 編集装備の順序を更新（Firestoreに保存）
    func updateEditTools() async {
        guard let userId = userId else {
            errorMessage = "ユーザーIDが取得できません"
            return
        }

        isLoading = true
        errorMessage = nil
        // すべてのパスで確実にローディング状態を解除する
        defer { isLoading = false }

        do {
            // 選択されたツールの順序を取得
            let toolsOrder = selectedTools.map { $0.rawValue }
            
            // リトライ可能な操作として実行
            try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.updateEditTools(
                    userId: userId,
                    tools: self.selectedTools,
                    order: toolsOrder
                )
            }
            
            // ローカルの状態を更新
            equippedTools = selectedTools
            self.toolsOrder = toolsOrder
            
            // ユーザー情報を再読み込み
            await loadProfile()
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "ProfileViewModel.updateEditTools", userId: userId)
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }

    /// 編集装備の順序を変更（ドラッグ&ドロップ）
    func moveEditTool(from source: IndexSet, to destination: Int) {
        selectedTools.move(fromOffsets: source, toOffset: destination)
    }
    
    /// 編集装備の選択をリセット（現在保存されている順序に戻す）
    func resetEditTools() {
        selectedTools = equippedTools
    }
    
    // MARK: - Validation
    
    /// 編集装備の選択が有効かどうか（常にtrue - 全ツール表示のため）
    var isValidEditToolsSelection: Bool {
        true
    }
    
    /// プロフィール編集が有効かどうか
    var isValidProfileEdit: Bool {
        // 表示名と自己紹介の長さチェック（任意）
        let displayNameValid = editingDisplayName.count <= 50
        let bioValid = editingBio.count <= 200
        
        return displayNameValid && bioValid
    }
}
