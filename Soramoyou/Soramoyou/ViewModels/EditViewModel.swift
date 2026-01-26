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
    @Published var isDragging = false

    private let imageService: ImageServiceProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let userId: String?
    private var previewTask: Task<Void, Never>?
    private var cachedLowResImage: UIImage?
    private var realtimePreviewTask: Task<Void, Never>?
    private var isGeneratingRealtimePreview = false
    private var pendingRealtimeUpdate = false
    
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

    /// メモリリーク防止のためのクリーンアップ
    deinit {
        previewTask?.cancel()
        realtimePreviewTask?.cancel()
    }

    /// 手動でリソースをクリーンアップ
    func cleanup() {
        previewTask?.cancel()
        realtimePreviewTask?.cancel()
        previewTask = nil
        realtimePreviewTask = nil
        cachedLowResImage = nil
        previewImage = nil
        originalImages = []
        isGeneratingRealtimePreview = false
        pendingRealtimeUpdate = false
    }

    // MARK: - Image Management
    
    /// 画像を設定
    func setImages(_ images: [UIImage]) {
        originalImages = images
        currentImageIndex = 0
        editSettings = EditSettings()
        cachedLowResImage = nil
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
        cachedLowResImage = nil
        Task {
            await generatePreview()
        }
    }

    /// 前の画像に切り替え
    func previousImage() {
        guard currentImageIndex > 0 else { return }
        currentImageIndex -= 1
        cachedLowResImage = nil
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
            let user = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.fetchUser(userId: userId)
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
    
    /// 編集ツールの値を設定（リアルタイムプレビュー対応）
    func setToolValue(_ value: Float, for tool: EditTool) {
        // 値の範囲を-1.0から1.0に制限
        let clampedValue = max(-1.0, min(1.0, value))
        editSettings.setValue(clampedValue, for: tool)

        // ドラッグ中は即座にプレビュー生成（低解像度）
        if isDragging {
            generateRealtimePreview()
        } else {
            // ドラッグ終了後は高品質プレビュー
            debouncePreview()
        }
    }

    /// スライダーのドラッグ状態が変更された時に呼ばれる
    func onDraggingChanged(_ isDragging: Bool) {
        self.isDragging = isDragging

        if isDragging {
            // ドラッグ開始時に低解像度画像をキャッシュ
            prepareLowResImage()
        } else {
            // ドラッグ終了時にリアルタイム状態をリセット
            pendingRealtimeUpdate = false
            isGeneratingRealtimePreview = false
            realtimePreviewTask?.cancel()

            // 高品質プレビューを生成
            Task {
                await generatePreview()
            }
        }
    }

    /// 低解像度画像を準備（同期的にリサイズ）
    private func prepareLowResImage() {
        guard let image = currentImage, cachedLowResImage == nil else { return }

        // 同期的にリサイズ（即座にキャッシュを利用可能にする）
        let maxWidth: CGFloat = 400
        let scale = maxWidth / image.size.width
        if scale < 1.0 {
            let newSize = CGSize(
                width: maxWidth,
                height: image.size.height * scale
            )
            let renderer = UIGraphicsImageRenderer(size: newSize)
            cachedLowResImage = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            cachedLowResImage = image
        }
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
        cachedLowResImage = nil
        Task {
            await generatePreview()
        }
    }

    // MARK: - Preview Generation

    /// リアルタイムプレビューを生成（スロットリング方式）
    /// 前のプレビュー生成中は新しい生成をキューイングし、
    /// 完了後に最新の設定で再生成する
    private func generateRealtimePreview() {
        // 既にプレビュー生成中の場合は、完了後に再生成するようフラグを立てる
        if isGeneratingRealtimePreview {
            pendingRealtimeUpdate = true
            return
        }

        isGeneratingRealtimePreview = true
        pendingRealtimeUpdate = false

        realtimePreviewTask = Task {
            // 低解像度画像を使用してプレビュー生成
            let sourceImage = cachedLowResImage ?? currentImage
            guard let image = sourceImage else {
                isGeneratingRealtimePreview = false
                return
            }

            do {
                let currentEdits = editSettings
                let preview = try await imageService.generatePreview(image, edits: currentEdits)
                previewImage = preview
            } catch {
                // リアルタイムプレビュー中のエラーは無視
            }

            isGeneratingRealtimePreview = false

            // 処理中に新しい値が来ていた場合、最新の値で再生成
            if pendingRealtimeUpdate && isDragging {
                generateRealtimePreview()
            }
        }
    }

    /// プレビューを生成（デバウンス処理付き）
    private func debouncePreview() {
        // 前のタスクをキャンセル
        previewTask?.cancel()

        // 新しいタスクを作成
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms待機（短縮）

            guard !Task.isCancelled else { return }
            await generatePreview()
        }
    }

    /// プレビューを生成（高品質）
    func generatePreview() async {
        guard let image = currentImage else {
            previewImage = nil
            return
        }

        // ドラッグ中でない場合のみローディング表示
        if !isDragging {
            isLoading = true
        }
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
