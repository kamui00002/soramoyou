// ⭐️ EditViewModel.swift
// 編集画面のビューモデル
// リアルタイムプレビュー機能を追加
//
//  EditViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import UIKit
import SwiftUI
import Combine
import CoreImage

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

    // MARK: - 切り取り・回転関連のプロパティ

    /// 回転角度（度数法）
    @Published var rotationDegrees: Double = 0
    /// 左右反転フラグ
    @Published var isFlippedHorizontal: Bool = false
    /// 上下反転フラグ
    @Published var isFlippedVertical: Bool = false
    /// 切り取りアスペクト比
    @Published var cropAspectRatio: CropAspectRatio = .free

    // MARK: - リアルタイムプレビュー用プロパティ

    /// 高速プレビュー用（低解像度）
    @Published var fastPreviewImage: UIImage?
    /// リアルタイム編集中フラグ
    @Published var isEditingRealtime: Bool = false

    private let imageService: ImageServiceProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let userId: String?
    private var previewTask: Task<Void, Never>?
    private var fastPreviewTask: Task<Void, Never>?

    // MARK: - 低解像度CIImageキャッシュ（プレビュー高速化）

    /// リサイズ済み低解像度CIImage（キャッシュ）
    private var cachedLowResCIImage: CIImage?
    /// キャッシュ対象の画像インデックス
    private var cachedImageIndex: Int = -1
    /// キャッシュ時の変換状態キー（回転・反転）
    private var cachedTransformKey: String = ""

    // MARK: - スロットリング ☁️

    /// 最後の高速プレビューレンダリング時刻
    private var lastFastPreviewTime: CFAbsoluteTime = 0
    /// スロットリング最小間隔（約30fps）
    private let fastPreviewMinInterval: CFAbsoluteTime = 0.033
    /// 遅延実行用タスク
    private var throttledPreviewTask: Task<Void, Never>?

    // MARK: - リクエストID管理（レースコンディション防止）☁️

    /// 現在のプレビューリクエストID
    private var currentPreviewRequestId: UUID = UUID()
    /// 現在の高速プレビューリクエストID
    private var currentFastPreviewRequestId: UUID = UUID()
    
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
        invalidateLowResCache()
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
        invalidateLowResCache()
        Task {
            await generatePreview()
        }
    }

    /// 前の画像に切り替え
    func previousImage() {
        guard currentImageIndex > 0 else { return }
        currentImageIndex -= 1
        invalidateLowResCache()
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
    
    /// 装備ツールを読み込む（全27ツールを順序に従って表示）
    func loadEquippedTools() async {
        guard let userId = userId else {
            // 未ログイン時は全ツールをデフォルト順序で表示
            equippedTools = EditTool.allCases
            equippedToolsOrder = equippedTools.map { $0.rawValue }
            return
        }

        do {
            // リトライ可能な操作として実行
            let user = try await RetryableOperation.executeIfRetryable { [self] in
                try await self.firestoreService.fetchUser(userId: userId)
            }

            // 全27ツールを使用（順序のみカスタマイズ）
            var allTools = EditTool.allCases

            // ツールの順序を取得して並び替え
            if let order = user.customEditToolsOrder,
               !order.isEmpty {
                equippedToolsOrder = order
                // 順序に従ってツールを並び替え
                allTools.sort { tool1, tool2 in
                    let index1 = order.firstIndex(of: tool1.rawValue) ?? Int.max
                    let index2 = order.firstIndex(of: tool2.rawValue) ?? Int.max
                    return index1 < index2
                }
            } else {
                equippedToolsOrder = allTools.map { $0.rawValue }
            }

            equippedTools = allTools
        } catch {
            // notFoundエラーの場合はユーザードキュメントが未作成なので、全ツールをデフォルト順序で表示
            // エラーメッセージは表示しない（正常なケースとして扱う）
            if let firestoreError = error as? FirestoreServiceError,
               case .notFound = firestoreError {
                equippedTools = EditTool.allCases
                equippedToolsOrder = equippedTools.map { $0.rawValue }
                return
            }

            // その他のエラーの場合はログに記録
            ErrorHandler.logError(error, context: "EditViewModel.loadEquippedTools", userId: userId)
            // エラー時は全ツールをデフォルト順序で表示
            equippedTools = EditTool.allCases
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

    /// 編集ツールの値をリアルタイムで設定（スロットリング付き・高速プレビュー）
    /// スライダー操作中に呼び出され、低解像度でプレビューを即座に更新
    /// 最小間隔33ms（約30fps）でスロットリングし、間隔内の最後の値を遅延実行
    func setToolValueRealtime(_ value: Float, for tool: EditTool) {
        // 値の範囲を-1.0から1.0に制限
        let clampedValue = max(-1.0, min(1.0, value))
        editSettings.setValue(clampedValue, for: tool)
        isEditingRealtime = true

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFastPreviewTime

        if elapsed >= fastPreviewMinInterval {
            // 十分な時間が経過 → 即座にプレビュー生成
            throttledPreviewTask?.cancel()
            lastFastPreviewTime = now
            fastPreviewTask?.cancel()
            fastPreviewTask = Task {
                await generatePreviewFast()
            }
        } else {
            // 間隔内 → 遅延実行（最後の値だけ処理）
            throttledPreviewTask?.cancel()
            throttledPreviewTask = Task {
                let waitNano = UInt64((fastPreviewMinInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNano)
                guard !Task.isCancelled else { return }
                lastFastPreviewTime = CFAbsoluteTimeGetCurrent()
                fastPreviewTask?.cancel()
                fastPreviewTask = Task {
                    await generatePreviewFast()
                }
            }
        }
    }

    /// スライダー操作完了時に呼び出し、高品質プレビューを生成
    func finalizeToolValue(for tool: EditTool) {
        isEditingRealtime = false
        fastPreviewImage = nil

        // 高品質プレビューを生成
        Task {
            await generatePreview()
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
        rotationDegrees = 0
        isFlippedHorizontal = false
        isFlippedVertical = false
        cropAspectRatio = .free
        invalidateLowResCache()
        Task {
            await generatePreview()
        }
    }

    // MARK: - 切り取り・回転操作

    /// 回転角度を設定（リアルタイム・スロットリング付き）
    func setRotationRealtime(_ degrees: Double) {
        rotationDegrees = degrees
        isEditingRealtime = true
        // 回転変更時はキャッシュ無効化（変換が変わるため）
        invalidateLowResCache()

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFastPreviewTime

        if elapsed >= fastPreviewMinInterval {
            throttledPreviewTask?.cancel()
            lastFastPreviewTime = now
            fastPreviewTask?.cancel()
            fastPreviewTask = Task {
                await generatePreviewFast()
            }
        } else {
            throttledPreviewTask?.cancel()
            throttledPreviewTask = Task {
                let waitNano = UInt64((fastPreviewMinInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNano)
                guard !Task.isCancelled else { return }
                lastFastPreviewTime = CFAbsoluteTimeGetCurrent()
                fastPreviewTask?.cancel()
                fastPreviewTask = Task {
                    await generatePreviewFast()
                }
            }
        }
    }

    /// 回転操作完了
    func finalizeRotation() {
        isEditingRealtime = false
        fastPreviewImage = nil

        Task {
            await generatePreview()
        }
    }

    /// 左右反転を切り替え
    func toggleFlipHorizontal() {
        isFlippedHorizontal.toggle()
        invalidateLowResCache()
        Task {
            await generatePreview()
        }
    }

    /// 上下反転を切り替え
    func toggleFlipVertical() {
        isFlippedVertical.toggle()
        invalidateLowResCache()
        Task {
            await generatePreview()
        }
    }

    /// 左に90度回転
    func rotateLeft() {
        rotationDegrees -= 90
        if rotationDegrees < -180 {
            rotationDegrees += 360
        }
        invalidateLowResCache()
        Task {
            await generatePreview()
        }
    }

    /// 右に90度回転
    func rotateRight() {
        rotationDegrees += 90
        if rotationDegrees > 180 {
            rotationDegrees -= 360
        }
        invalidateLowResCache()
        Task {
            await generatePreview()
        }
    }

    /// アスペクト比を設定
    func setCropAspectRatio(_ ratio: CropAspectRatio) {
        cropAspectRatio = ratio
    }

    /// 切り取り・回転のリセット
    func resetCropSettings() {
        rotationDegrees = 0
        isFlippedHorizontal = false
        isFlippedVertical = false
        cropAspectRatio = .free
        invalidateLowResCache()
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
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms待機

            guard !Task.isCancelled else { return }
            await generatePreview()
        }
    }

    /// プレビューを生成 ☁️
    /// リクエストIDを使用してレースコンディションを防止
    func generatePreview() async {
        guard let image = currentImage else {
            previewImage = nil
            return
        }

        // 新しいリクエストIDを発行
        let requestId = UUID()
        currentPreviewRequestId = requestId

        isLoading = true
        errorMessage = nil

        do {
            // 画像処理をバックグラウンドで実行
            let processedImage = await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return image }
                // 回転・反転を適用した画像を作成
                return await MainActor.run {
                    self.applyTransform(to: image)
                }
            }.value

            // リクエストIDが変わっていたら結果を破棄
            guard requestId == currentPreviewRequestId else { return }

            let preview = try await imageService.generatePreview(processedImage, edits: editSettings)

            // リクエストIDが変わっていたら結果を破棄
            guard requestId == currentPreviewRequestId else { return }

            previewImage = preview
        } catch {
            // リクエストIDが変わっていたらエラー表示も不要
            guard requestId == currentPreviewRequestId else { return }

            // エラーをログに記録
            ErrorHandler.logError(error, context: "EditViewModel.generatePreview")
            // ユーザーフレンドリーなメッセージを表示
            errorMessage = error.userFriendlyMessage
        }

        isLoading = false
    }

    /// 高速プレビューを生成（低解像度・256x256）☁️
    /// スライダー操作中のリアルタイム表示用
    /// キャッシュ済みの低解像度CIImageを使い、同期的にフィルターチェーンを適用
    /// リクエストIDを使用してレースコンディションを防止
    func generatePreviewFast() async {
        guard currentImage != nil else {
            fastPreviewImage = nil
            return
        }

        // 新しいリクエストIDを発行
        let requestId = UUID()
        currentFastPreviewRequestId = requestId

        // キャッシュが有効かチェックし、無効なら再生成（バックグラウンドで実行）
        let transformKey = makeTransformKey()
        if cachedLowResCIImage == nil
            || cachedImageIndex != currentImageIndex
            || cachedTransformKey != transformKey {
            await rebuildLowResCacheAsync()
        }

        // リクエストIDが変わっていたら結果を破棄
        guard requestId == currentFastPreviewRequestId else { return }

        guard let lowResCIImage = cachedLowResCIImage else {
            fastPreviewImage = nil
            return
        }

        // CIImageベースでプレビュー生成
        let preview = imageService.generatePreviewFromCIImage(lowResCIImage, edits: editSettings)

        // リクエストIDが変わっていたら結果を破棄
        guard requestId == currentFastPreviewRequestId else { return }

        fastPreviewImage = preview
    }

    /// 変換状態のキーを生成（キャッシュ無効化判定用）
    private func makeTransformKey() -> String {
        "\(rotationDegrees)_\(isFlippedHorizontal)_\(isFlippedVertical)"
    }

    /// 低解像度CIImageキャッシュを再構築（同期版：互換性のため残す）
    private func rebuildLowResCache() {
        guard let image = currentImage else {
            cachedLowResCIImage = nil
            return
        }

        // まず画像の向きを正規化（CIImageはorientationフラグを無視するため）
        let normalizedImage = normalizeImageOrientation(image)

        // 回転・反転を適用
        let transformed = applyTransform(to: normalizedImage)

        // UIImage → CIImage に変換
        guard let ciImage = CIImage(image: transformed) else {
            cachedLowResCIImage = nil
            return
        }

        // CIImage上で256x256にリサイズ（UIImage変換なし）
        let lowRes = imageService.resizeCIImage(ciImage, maxSize: CGSize(width: 256, height: 256))

        cachedLowResCIImage = lowRes
        cachedImageIndex = currentImageIndex
        cachedTransformKey = makeTransformKey()
    }

    /// 低解像度CIImageキャッシュを再構築（非同期版：バックグラウンド処理）☁️
    /// 重い画像処理をバックグラウンドスレッドで実行してUIブロックを防止
    private func rebuildLowResCacheAsync() async {
        guard let image = currentImage else {
            cachedLowResCIImage = nil
            return
        }

        let currentIndex = currentImageIndex
        let transformKey = makeTransformKey()
        let imageServiceRef = imageService

        // 重い画像処理をバックグラウンドで実行
        let result = await Task.detached(priority: .userInitiated) { [weak self] () -> CIImage? in
            guard let self = self else { return nil }

            // MainActorでUIImage関連の処理を実行
            let processedImage: UIImage = await MainActor.run {
                // 画像の向きを正規化
                let normalizedImage = self.normalizeImageOrientation(image)
                // 回転・反転を適用
                return self.applyTransform(to: normalizedImage)
            }

            // UIImage → CIImage に変換
            guard let ciImage = CIImage(image: processedImage) else {
                return nil
            }

            // CIImage上で256x256にリサイズ
            return imageServiceRef.resizeCIImage(ciImage, maxSize: CGSize(width: 256, height: 256))
        }.value

        // キャッシュを更新
        cachedLowResCIImage = result
        cachedImageIndex = currentIndex
        cachedTransformKey = transformKey
    }

    /// 画像の向きを正規化（.upに統一）
    /// CIImageはorientationフラグを無視するため、事前に物理的に回転させる必要がある
    private func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        // 既に.upの場合は処理不要
        guard image.imageOrientation != .up else {
            return image
        }

        // 正規化された画像を描画
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return normalizedImage ?? image
    }

    /// 低解像度キャッシュを無効化
    private func invalidateLowResCache() {
        cachedLowResCIImage = nil
    }

    /// 回転・反転を画像に適用
    private func applyTransform(to image: UIImage) -> UIImage {
        // 回転も反転もない場合はそのまま返す
        guard rotationDegrees != 0 || isFlippedHorizontal || isFlippedVertical else {
            return image
        }

        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return image }

        // コンテキストの中心に移動
        context.translateBy(x: size.width / 2, y: size.height / 2)

        // 反転を適用
        var scaleX: CGFloat = 1.0
        var scaleY: CGFloat = 1.0
        if isFlippedHorizontal {
            scaleX = -1.0
        }
        if isFlippedVertical {
            scaleY = -1.0
        }
        context.scaleBy(x: scaleX, y: scaleY)

        // 回転を適用
        let radians = rotationDegrees * .pi / 180.0
        context.rotate(by: CGFloat(radians))

        // 画像を描画
        image.draw(in: CGRect(
            x: -size.width / 2,
            y: -size.height / 2,
            width: size.width,
            height: size.height
        ))

        let transformedImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()

        return transformedImage
    }
    
    // MARK: - Final Image Generation

    /// 最終的な編集済み画像を生成（全画像）
    func generateFinalImages() async throws -> [UIImage] {
        var editedImages: [UIImage] = []

        for image in originalImages {
            // 回転・反転を適用
            let transformedImage = applyTransform(to: image)
            let editedImage = try await imageService.applyEditSettings(editSettings, to: transformedImage)
            editedImages.append(editedImage)
        }

        return editedImages
    }

    /// 現在の画像の最終的な編集済み画像を生成
    func generateFinalImage() async throws -> UIImage {
        guard let image = currentImage else {
            throw EditViewModelError.noImage
        }

        // 回転・反転を適用
        let transformedImage = applyTransform(to: image)
        return try await imageService.applyEditSettings(editSettings, to: transformedImage)
    }

    /// 表示用のプレビュー画像を取得
    /// リアルタイム編集中は高速プレビュー、それ以外は通常プレビューを返す
    var displayPreviewImage: UIImage? {
        if isEditingRealtime, let fastPreview = fastPreviewImage {
            return fastPreview
        }
        return previewImage
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
