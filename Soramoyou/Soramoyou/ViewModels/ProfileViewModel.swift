//
//  ProfileViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import Combine
import UIKit
import FirebaseAuth

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
    
    // 編集装備システムの管理
    @Published var availableTools: [EditTool] = EditTool.allCases
    @Published var selectedTools: [EditTool] = []
    @Published var toolsOrder: [String] = []
    
    private let userId: String?
    private let firestoreService: FirestoreServiceProtocol
    private let storageService: StorageServiceProtocol

    // 自分のプロフィールかどうか
    var isOwnProfile: Bool {
        guard let userId = userId,
              let currentUserId = Auth.auth().currentUser?.uid else {
            return false
        }
        return userId == currentUserId
    }
    
    // 編集装備の制約（5-8個）
    let minEditTools = 5
    let maxEditTools = 8
    
    init(
        userId: String? = nil,
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        storageService: StorageServiceProtocol = StorageService()
    ) {
        // userIdが指定されていない場合は現在のユーザーIDを使用
        if let userId = userId {
            self.userId = userId
        } else {
            self.userId = Auth.auth().currentUser?.uid
        }
        
        self.firestoreService = firestoreService
        self.storageService = storageService
    }
    
    // MARK: - Load Profile
    
    /// プロフィール情報を読み込む
    func loadProfile() async {
        guard let userId = userId else {
            errorMessage = "ユーザーIDが取得できません"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // リトライ可能な操作として実行
            let fetchedUser = try await RetryableOperation.executeIfRetryable {
                try await firestoreService.fetchUser(userId: userId)
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
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
        
        isLoading = false
    }
    
    /// 編集装備を読み込む
    private func loadEditTools() async {
        guard let userId = userId,
              let user = user else {
            return
        }
        
        // customEditToolsとcustomEditToolsOrderから編集装備を復元
        if let customTools = user.customEditTools,
           let toolsOrder = user.customEditToolsOrder {
            // 順序に従ってEditToolを取得
            var tools: [EditTool] = []
            for toolId in toolsOrder {
                if let tool = EditTool(rawValue: toolId) {
                    tools.append(tool)
                }
            }
            
            // 順序に含まれていないツールも追加（後ろに追加）
            for tool in EditTool.allCases {
                if !tools.contains(tool) && customTools.contains(tool.rawValue) {
                    tools.append(tool)
                }
            }
            
            equippedTools = tools
            selectedTools = tools
            self.toolsOrder = toolsOrder
        } else {
            // デフォルトの編集装備（最初の5個）
            let defaultTools = Array(EditTool.allCases.prefix(minEditTools))
            equippedTools = defaultTools
            selectedTools = defaultTools
            self.toolsOrder = defaultTools.map { $0.rawValue }
        }
    }
    
    // MARK: - Load Posts
    
    /// ユーザーの投稿一覧を読み込む
    func loadUserPosts() async {
        guard let userId = userId else {
            return
        }
        
        isLoadingPosts = true
        errorMessage = nil
        
        do {
            // リトライ可能な操作として実行
            let posts = try await RetryableOperation.executeIfRetryable {
                try await firestoreService.fetchUserPosts(
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
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
        
        isLoadingPosts = false
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
        
        do {
            // プロフィール画像の処理
            var photoURL = updatedUser.photoURL
            
            if shouldDeleteProfileImage {
                // 既存の画像を削除（リトライ可能）
                if let existingPhotoURL = photoURL,
                   let url = URL(string: existingPhotoURL) {
                    // Storageから画像を削除
                    let path = "users/\(userId)/profile.jpg"
                    try? await RetryableOperation.executeIfRetryable {
                        try await storageService.deleteImage(path: path)
                    }
                }
                photoURL = nil
            } else if let profileImage = editingProfileImage {
                // 新しい画像をアップロード（リトライ可能）
                let imagePath = "users/\(userId)/profile.jpg"
                let uploadedURL = try await RetryableOperation.executeIfRetryable {
                    try await storageService.uploadImage(profileImage, path: imagePath)
                }
                photoURL = uploadedURL.absoluteString
            }
            
            // ユーザー情報を更新
            updatedUser.displayName = editingDisplayName.isEmpty ? nil : editingDisplayName
            updatedUser.bio = editingBio.isEmpty ? nil : editingBio
            updatedUser.photoURL = photoURL
            updatedUser.updatedAt = Date()
            
            // Firestoreに更新（リトライ可能）
            let savedUser = try await RetryableOperation.executeIfRetryable {
                try await firestoreService.updateUser(updatedUser)
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
        
        isLoading = false
    }
    
    // MARK: - Edit Tools Management
    
    /// 編集装備を更新
    func updateEditTools() async {
        guard let userId = userId else {
            errorMessage = "ユーザーIDが取得できません"
            return
        }
        
        // バリデーション: 5-8個の制約
        guard selectedTools.count >= minEditTools && selectedTools.count <= maxEditTools else {
            errorMessage = "編集装備は\(minEditTools)個から\(maxEditTools)個まで選択できます"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            // 選択されたツールのIDと順序を取得
            let toolsOrder = selectedTools.map { $0.rawValue }
            
            // リトライ可能な操作として実行
            try await RetryableOperation.executeIfRetryable {
                try await firestoreService.updateEditTools(
                    userId: userId,
                    tools: selectedTools,
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
        
        isLoading = false
    }
    
    /// 編集装備を追加
    func addEditTool(_ tool: EditTool) {
        guard !selectedTools.contains(tool),
              selectedTools.count < maxEditTools else {
            return
        }
        selectedTools.append(tool)
    }
    
    /// 編集装備を削除
    func removeEditTool(_ tool: EditTool) {
        guard selectedTools.count > minEditTools else {
            return
        }
        selectedTools.removeAll { $0 == tool }
    }
    
    /// 編集装備の順序を変更
    func moveEditTool(from source: IndexSet, to destination: Int) {
        selectedTools.move(fromOffsets: source, toOffset: destination)
    }
    
    /// 編集装備の選択をリセット
    func resetEditTools() {
        selectedTools = equippedTools
    }
    
    // MARK: - Validation
    
    /// 編集装備の選択が有効かどうか
    var isValidEditToolsSelection: Bool {
        selectedTools.count >= minEditTools && selectedTools.count <= maxEditTools
    }
    
    /// プロフィール編集が有効かどうか
    var isValidProfileEdit: Bool {
        // 表示名と自己紹介の長さチェック（任意）
        let displayNameValid = editingDisplayName.count <= 50
        let bioValid = editingBio.count <= 200
        
        return displayNameValid && bioValid
    }
}

