//
//  EditViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import UIKit
import Combine

@MainActor
class EditViewModel: ObservableObject {
    @Published var originalImages: [UIImage] = []
    @Published var currentImageIndex: Int = 0
    @Published var previewImage: UIImage?
    @Published var editSettings: EditSettings = EditSettings()
    @Published var equippedTools: [EditTool] = []
    @Published var equippedToolsOrder: [String] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let imageService: ImageServiceProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let userId: String?
    private var previewTask: Task<Void, Never>?
    
    init(
        images: [UIImage] = [],
        userId: String? = nil,
        imageService: ImageServiceProtocol = ImageService(),
        firestoreService: FirestoreServiceProtocol = FirestoreService()
    ) {
        self.originalImages = images
        self.userId = userId
        self.imageService = imageService
        self.firestoreService = firestoreService
        
        // 初期プレビューを生成
        if !images.isEmpty {
            Task {
                await loadEquippedTools()
                await generatePreview()
            }
        }
    }
    
    // MARK: - Image Management
    
    /// 画像を設定
    func setImages(_ images: [UIImage]) {
        originalImages = images
        currentImageIndex = 0
        editSettings = EditSettings()
        Task {
            await generatePreview()
        }
    }
    
    /// 現在の画像を取得
    var currentImage: UIImage? {
        guard currentImageIndex < originalImages.count else { return nil }
        return originalImages[currentImageIndex]
    }
    
    /// 次の画像に切り替え
    func nextImage() {
        guard currentImageIndex < originalImages.count - 1 else { return }
        currentImageIndex += 1
        Task {
            await generatePreview()
        }
    }
    
    /// 前の画像に切り替え
    func previousImage() {
        guard currentImageIndex > 0 else { return }
        currentImageIndex -= 1
        Task {
            await generatePreview()
        }
    }
    
    // MARK: - Filter Management
    
    /// フィルターを適用
    func applyFilter(_ filter: FilterType) {
        editSettings.appliedFilter = filter
        Task {
            await generatePreview()
        }
    }
    
    /// フィルターを解除
    func removeFilter() {
        editSettings.appliedFilter = nil
        Task {
            await generatePreview()
        }
    }
    
    // MARK: - Edit Tool Management
    
    /// 装備ツールを読み込む
    func loadEquippedTools() async {
        guard let userId = userId else {
            // 未ログイン時は基本ツールのみ
            equippedTools = [.brightness, .contrast, .saturation, .exposure, .highlight, .shadow, .warmth, .sharpness, .vignette]
            equippedToolsOrder = equippedTools.map { $0.rawValue }
            return
        }
        
        do {
            // リトライ可能な操作として実行
            let user = try await RetryableOperation.executeIfRetryable {
                try await firestoreService.fetchUser(userId: userId)
            }
            
            // 装備ツールを取得
            if let customTools = user.customEditTools,
               !customTools.isEmpty {
                equippedTools = customTools.compactMap { EditTool(rawValue: $0) }
            } else {
                // デフォルトツール
                equippedTools = [.brightness, .contrast, .saturation, .exposure, .highlight, .shadow, .warmth, .sharpness, .vignette]
            }
            
            // ツールの順序を取得
            if let order = user.customEditToolsOrder,
               !order.isEmpty {
                equippedToolsOrder = order
                // 順序に従ってツールを並び替え
                equippedTools.sort { tool1, tool2 in
                    let index1 = order.firstIndex(of: tool1.rawValue) ?? Int.max
                    let index2 = order.firstIndex(of: tool2.rawValue) ?? Int.max
                    return index1 < index2
                }
            } else {
                equippedToolsOrder = equippedTools.map { $0.rawValue }
            }
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "EditViewModel.loadEquippedTools", userId: userId)
            // エラー時はデフォルトツールを使用
            equippedTools = [.brightness, .contrast, .saturation, .exposure, .highlight, .shadow, .warmth, .sharpness, .vignette]
            equippedToolsOrder = equippedTools.map { $0.rawValue }
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
    }
    
    /// 編集ツールの値を設定
    func setToolValue(_ value: Float, for tool: EditTool) {
        // 値の範囲を-1.0から1.0に制限
        let clampedValue = max(-1.0, min(1.0, value))
        editSettings.setValue(clampedValue, for: tool)
        
        // プレビューを生成（デバウンス処理）
        debouncePreview()
    }
    
    /// 編集ツールの値をリセット
    func resetToolValue(for tool: EditTool) {
        editSettings.setValue(nil, for: tool)
        Task {
            await generatePreview()
        }
    }
    
    /// すべての編集をリセット
    func resetAllEdits() {
        editSettings = EditSettings()
        Task {
            await generatePreview()
        }
    }
    
    // MARK: - Preview Generation
    
    /// プレビューを生成（デバウンス処理付き）
    private func debouncePreview() {
        // 前のタスクをキャンセル
        previewTask?.cancel()
        
        // 新しいタスクを作成
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms待機（ユーザー体験と処理負荷のバランス）

            guard !Task.isCancelled else { return }
            await generatePreview()
        }
    }
    
    /// プレビューを生成
    func generatePreview() async {
        guard let image = currentImage else {
            previewImage = nil
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let preview = try await imageService.generatePreview(image, edits: editSettings)
            previewImage = preview
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "EditViewModel.generatePreview")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }
        
        isLoading = false
    }
    
    // MARK: - Final Image Generation
    
    /// 最終的な編集済み画像を生成（全画像）
    func generateFinalImages() async throws -> [UIImage] {
        var editedImages: [UIImage] = []
        
        for image in originalImages {
            let editedImage = try await imageService.applyEditSettings(editSettings, to: image)
            editedImages.append(editedImage)
        }
        
        return editedImages
    }
    
    /// 現在の画像の最終的な編集済み画像を生成
    func generateFinalImage() async throws -> UIImage {
        guard let image = currentImage else {
            throw EditViewModelError.noImage
        }
        
        return try await imageService.applyEditSettings(editSettings, to: image)
    }
}

// MARK: - EditViewModelError

enum EditViewModelError: LocalizedError {
    case noImage
    case previewGenerationFailed
    case toolNotEquipped
    
    var errorDescription: String? {
        switch self {
        case .noImage:
            return "画像が設定されていません"
        case .previewGenerationFailed:
            return "プレビューの生成に失敗しました"
        case .toolNotEquipped:
            return "このツールは装備されていません"
        }
    }
}

