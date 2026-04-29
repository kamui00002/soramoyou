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

    // MARK: - 編集状態（内部は EditRecipe で管理）

    /// 編集レシピ（不変データ構造）
    /// 【改善】mutable な EditSettings から immutable な EditRecipe に移行。
    /// Undo/Redo・状態管理が値コピーで安全に行える。
    @Published var editRecipe: EditRecipe = EditRecipe()

    /// 後方互換 computed property
    ///
    /// View 側のコード（`viewModel.editSettings`）を変更せずに EditRecipe へ移行できる。
    /// get: EditRecipe を EditSettings に変換して返す
    /// set: EditSettings を EditRecipe に変換して保存
    ///
    /// 注意: `EditSettings` には `toneCurvePoints` / `targetDynamicRange` が含まれないため、
    /// set の時点で既存の値を保全してから再構築する（スライダー操作でトーンカーブが
    /// 失われる不具合を防止）。
    var editSettings: EditSettings {
        get { editRecipe.toEditSettings() }
        set {
            let existingPoints = editRecipe.toneCurvePoints
            let existingDynamicRange = editRecipe.targetDynamicRange
            let existingCropRect = editRecipe.cropRectNorm
            var newRecipe = EditRecipe(from: newValue)
            newRecipe.toneCurvePoints = existingPoints
            newRecipe.targetDynamicRange = existingDynamicRange
            newRecipe.cropRectNorm = existingCropRect
            editRecipe = newRecipe
        }
    }

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

    /// 高速プレビュー用（中解像度）
    @Published var fastPreviewImage: UIImage?
    /// リアルタイム編集中フラグ
    @Published var isEditingRealtime: Bool = false

    // MARK: - Undo/Redo ☁️

    /// 画像ごとの履歴マネージャー（historyManagers[i] が originalImages[i] に対応）
    ///
    /// 各画像で独立した Undo/Redo 履歴を持たせるため配列で管理する。
    /// `class EditHistoryManager` は参照型なので、`historyManager` computed
    /// property 経由でも push/undo/redo は配列要素に反映される。
    @Published private var historyManagers: [EditHistoryManager] = []

    /// 画像が空の状態（init 直後など）でアクセスされたときのフォールバック
    private let fallbackHistoryManager = EditHistoryManager()

    /// 現在の画像インデックスに対応する履歴マネージャー
    private var historyManager: EditHistoryManager {
        historyManagers.indices.contains(currentImageIndex)
            ? historyManagers[currentImageIndex]
            : fallbackHistoryManager
    }

    /// Undo 可能かどうか（historyManager から直接参照）
    var canUndo: Bool { historyManager.canUndo }
    /// Redo 可能かどうか（historyManager から直接参照）
    var canRedo: Bool { historyManager.canRedo }

    /// スライダーのドラッグ開始時のスナップショット（ドラッグ終了時に履歴へ積む）
    private var preDragSnapshot: EditorSnapshot?

    // MARK: - 画像ごとの編集状態スロット ☁️

    /// 各画像ごとに保存する編集状態（imageStates[i] が originalImages[i] に対応）
    ///
    /// 画像切替時に **現在の状態を保存 → 切替先の状態を復元** することで、
    /// 1枚目に施した編集が2,3枚目に伝染しないようにする。
    private var imageStates: [EditorSnapshot] = []

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

        // 画像ごとの編集状態スロットと履歴を初期化（画像枚数と1:1で対応）
        let defaultSnapshot = EditorSnapshot(
            recipe:              EditRecipe(),
            rotationDegrees:     0,
            isFlippedHorizontal: false,
            isFlippedVertical:   false,
            cropAspectRatio:     .free
        )
        self.imageStates = Array(repeating: defaultSnapshot, count: images.count)
        self.historyManagers = images.map { _ in EditHistoryManager() }

        // 初期プレビューを生成（メモリリーク防止のため weak self を使用）
        if !images.isEmpty {
            Task { [weak self] in
                guard let self = self else { return }
                await self.loadEquippedTools()
                await self.generatePreview()
            }
        }
    }

    deinit {
        // 全Taskをキャンセルしてリソースを解放
        previewTask?.cancel()
        fastPreviewTask?.cancel()
        throttledPreviewTask?.cancel()
    }

    // MARK: - Image Management
    
    // MARK: - スナップショット ヘルパー

    /// 現在の編集状態を EditorSnapshot として取得
    private var currentSnapshot: EditorSnapshot {
        EditorSnapshot(
            recipe:              editRecipe,
            rotationDegrees:     rotationDegrees,
            isFlippedHorizontal: isFlippedHorizontal,
            isFlippedVertical:   isFlippedVertical,
            cropAspectRatio:     cropAspectRatio
        )
    }

    /// EditorSnapshot を現在の状態に復元する
    private func applySnapshot(_ snap: EditorSnapshot) {
        editRecipe          = snap.recipe
        rotationDegrees     = snap.rotationDegrees
        isFlippedHorizontal = snap.isFlippedHorizontal
        isFlippedVertical   = snap.isFlippedVertical
        cropAspectRatio     = snap.cropAspectRatio
        invalidateLowResCache()
    }

    // MARK: - 履歴状態更新ヘルパー

    /// historyManager の変更を通知する（@Published で自動通知されるが、
    /// 内部 mutating 操作後に objectWillChange を手動発火する必要がある）
    private func notifyHistoryChange() {
        // historyManager は @Published なので、再代入で objectWillChange が発火する
        // ただし push/undo/redo は内部 mutation なので明示的に通知
        objectWillChange.send()
    }

    // MARK: - Undo/Redo 操作

    /// 直前の編集状態に戻す（recipe + 回転/反転/クロップを含む完全復元）
    func undo() {
        guard let previous = historyManager.undo(current: currentSnapshot) else { return }
        applySnapshot(previous)
        notifyHistoryChange()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// Undo した変更を再適用する
    func redo() {
        guard let next = historyManager.redo(current: currentSnapshot) else { return }
        applySnapshot(next)
        notifyHistoryChange()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    // MARK: - Image Management

    /// 画像を設定
    func setImages(_ images: [UIImage]) {
        originalImages = images
        currentImageIndex = 0

        // 現在の編集状態をリセット（1枚目用のクリーンな状態）
        editRecipe          = EditRecipe()
        rotationDegrees     = 0
        isFlippedHorizontal = false
        isFlippedVertical   = false
        cropAspectRatio     = .free

        // 画像ごとのスロットを再構築（既存スロットは破棄）
        let defaultSnapshot = EditorSnapshot(
            recipe:              EditRecipe(),
            rotationDegrees:     0,
            isFlippedHorizontal: false,
            isFlippedVertical:   false,
            cropAspectRatio:     .free
        )
        imageStates     = Array(repeating: defaultSnapshot, count: images.count)
        historyManagers = images.map { _ in EditHistoryManager() }

        notifyHistoryChange()
        invalidateLowResCache()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    // MARK: - 画像ごとの状態の保存・復元

    /// 現在の編集状態を imageStates[currentImageIndex] に保存する
    private func saveCurrentImageState() {
        guard imageStates.indices.contains(currentImageIndex) else { return }
        imageStates[currentImageIndex] = currentSnapshot
    }

    /// 指定インデックスの保存済みスナップショットを画面に復元する
    private func restoreImageState(at index: Int) {
        guard imageStates.indices.contains(index) else { return }
        // 履歴通知のためコピーを取り、UI 状態をスナップショットへ揃える
        let snap = imageStates[index]
        editRecipe          = snap.recipe
        rotationDegrees     = snap.rotationDegrees
        isFlippedHorizontal = snap.isFlippedHorizontal
        isFlippedVertical   = snap.isFlippedVertical
        cropAspectRatio     = snap.cropAspectRatio
        // 画像が変われば履歴マネージャーも切り替わるため、UI に通知
        notifyHistoryChange()
    }
    
    /// 現在の画像を取得
    var currentImage: UIImage? {
        guard currentImageIndex < originalImages.count else { return nil }
        return originalImages[currentImageIndex]
    }

    /// 切り取り UI 用: 回転・反転適用済みの表示画像。
    ///
    /// 🔧 2026-04-24 修正 (ultrareview bug_003):
    /// generateFinalImage() は applyTransform(回転・反転) → applyCrop の順で適用するため、
    /// 切り取り UI が未変換画像を表示していると crop UI の矩形と最終出力の切り出し領域が
    /// 座標系レベルで一致しない (90°回転後に crop すると意図と全く違う領域が切り出される)。
    /// UI 表示側も applyTransform 適用後の画像を使うことで、UI と出力の一致を保証する。
    var currentImageForCrop: UIImage? {
        guard let image = currentImage else { return nil }
        return applyTransform(to: image)
    }
    
    /// 次の画像に切り替え
    func nextImage() {
        guard currentImageIndex < originalImages.count - 1 else { return }
        // 切替前に現在の編集状態を保存し、切替後にその画像の状態を復元することで
        // 各画像が独立した編集パラメータを保持するようにする
        saveCurrentImageState()
        currentImageIndex += 1
        restoreImageState(at: currentImageIndex)
        invalidateLowResCache()
        // ⭐️ 古いプレビューを即時クリア（async の generatePreview 完了まで前画像が残るのを防ぐ）
        clearPreviewForImageSwitch()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 前の画像に切り替え
    func previousImage() {
        guard currentImageIndex > 0 else { return }
        saveCurrentImageState()
        currentImageIndex -= 1
        restoreImageState(at: currentImageIndex)
        invalidateLowResCache()
        // ⭐️ 古いプレビューを即時クリア
        clearPreviewForImageSwitch()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 画像切替時に古いプレビューを即時クリアして、`currentImage`（元画像）が
    /// 表示されるようにする。`generatePreview()` の async 完了まで前の画像の
    /// フィルタ適用後プレビューが残り続けるのを防止する。
    private func clearPreviewForImageSwitch() {
        previewImage = nil
        fastPreviewImage = nil
        isEditingRealtime = false
        // 進行中の preview Task はキャンセル（古い画像向けの結果が遅延適用されるのを防ぐ）
        previewTask?.cancel()
        fastPreviewTask?.cancel()
        throttledPreviewTask?.cancel()
    }
    
    // MARK: - Filter Management
    
    /// フィルターを適用
    func applyFilter(_ filter: FilterType) {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editSettings.appliedFilter = filter
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// フィルターを解除
    func removeFilter() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editSettings.appliedFilter = nil
        Task { [weak self] in
            await self?.generatePreview()
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
        // 非リアルタイム変更前の状態を Undo スタックに積む
        historyManager.push(currentSnapshot)
        notifyHistoryChange()

        // 値はツールごとの有効範囲に制限（例: .noiseReduction は 0...1 の片側）
        let range = tool.sliderRange
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        editSettings.setValue(clampedValue, for: tool)

        // プレビューを生成（デバウンス処理）
        debouncePreview()
    }

    /// 編集ツールの値をリアルタイムで設定（スロットリング付き・高速プレビュー）
    /// スライダー操作中に呼び出され、中解像度でプレビューを即座に更新
    /// キャッシュ有効時は同期処理でTask overhead を排除し、即座にレンダリング
    /// 最小間隔33ms（約30fps）でスロットリングし、間隔内の最後の値を遅延実行
    func setToolValueRealtime(_ value: Float, for tool: EditTool) {
        // ドラッグ開始時点の状態をキャプチャ（Undo 用）
        if preDragSnapshot == nil {
            preDragSnapshot = currentSnapshot
        }

        // 値はツールごとの有効範囲に制限（例: .noiseReduction は 0...1 の片側）
        let range = tool.sliderRange
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        editSettings.setValue(clampedValue, for: tool)
        isEditingRealtime = true

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFastPreviewTime

        if elapsed >= fastPreviewMinInterval {
            // 十分な時間が経過 → 即座にプレビュー生成
            throttledPreviewTask?.cancel()
            lastFastPreviewTime = now
            renderFastPreviewOrAsync()
        } else {
            // 間隔内 → 遅延実行（最後の値だけ処理）
            throttledPreviewTask?.cancel()
            throttledPreviewTask = Task { [weak self] in
                let waitNano = UInt64((fastPreviewMinInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNano)
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                self.lastFastPreviewTime = CFAbsoluteTimeGetCurrent()
                self.renderFastPreviewOrAsync()
            }
        }
    }

    /// キャッシュが有効なら同期レンダリング、無効なら非同期でキャッシュ再構築後レンダリング
    private func renderFastPreviewOrAsync() {
        let transformKey = makeTransformKey()
        if let lowResCIImage = cachedLowResCIImage,
           cachedImageIndex == currentImageIndex,
           cachedTransformKey == transformKey {
            // キャッシュ有効 → 同期レンダリング（Task overhead なし）
            fastPreviewImage = imageService.generatePreviewFromCIImage(lowResCIImage, recipe: editRecipe)
        } else {
            // キャッシュ無効 → 非同期でキャッシュ再構築してからレンダリング
            fastPreviewTask?.cancel()
            fastPreviewTask = Task { [weak self] in
                await self?.generatePreviewFast()
            }
        }
    }

    /// ドラッグ開始時のスナップショットをキャプチャする（トーンカーブ等の外部 Binding 用）
    /// スライダー系は setToolValueRealtime 内で自動キャプチャされるが、
    /// カスタム Binding で直接 editRecipe を変更する場合はこのメソッドを先に呼ぶ
    func capturePreDragSnapshot() {
        if preDragSnapshot == nil {
            preDragSnapshot = currentSnapshot
        }
    }

    /// トーンカーブ等、スライダー以外の外部 Binding からリアルタイムプレビューを走らせる。
    ///
    /// 内部では `setToolValueRealtime` と同じスロットリング（約 30fps）＋
    /// 低解像度キャッシュ再利用のパスを通るため、ドラッグ中も同期的に画像が更新される。
    /// 呼び出し側は `editRecipe` を先に更新してから本メソッドを呼ぶこと。
    func triggerRealtimePreview() {
        isEditingRealtime = true

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastFastPreviewTime

        if elapsed >= fastPreviewMinInterval {
            throttledPreviewTask?.cancel()
            lastFastPreviewTime = now
            renderFastPreviewOrAsync()
        } else {
            throttledPreviewTask?.cancel()
            throttledPreviewTask = Task { [weak self] in
                guard let self = self else { return }
                let waitNano = UInt64((self.fastPreviewMinInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNano)
                guard !Task.isCancelled else { return }
                self.lastFastPreviewTime = CFAbsoluteTimeGetCurrent()
                self.renderFastPreviewOrAsync()
            }
        }
    }

    /// スライダー操作完了時に呼び出し、高品質プレビューを生成
    func finalizeToolValue(for tool: EditTool) {
        isEditingRealtime = false

        // ドラッグ開始時の状態を履歴に積む
        if let preDrag = preDragSnapshot {
            historyManager.push(preDrag)
            notifyHistoryChange()
            preDragSnapshot = nil
        }

        // 高速プレビューを通常プレビューに昇格（同解像度なので品質ジャンプなし）
        if let fastPreview = fastPreviewImage {
            previewImage = fastPreview
        }
        fastPreviewImage = nil

        // バックグラウンドでフル解像度プレビューを再生成
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 編集ツールの値をリセット
    func resetToolValue(for tool: EditTool) {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editSettings.setValue(nil, for: tool)
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// すべての編集をリセット
    func resetAllEdits() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editRecipe = EditRecipe()   // 編集レシピをリセット
        rotationDegrees = 0
        isFlippedHorizontal = false
        isFlippedVertical = false
        cropAspectRatio = .free
        invalidateLowResCache()
        // ⭐️ Issue #1: 画像切替後にリセットが消えないよう imageStates も同期
        saveCurrentImageState()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    // MARK: - 切り取り・回転操作

    /// 回転角度を設定（リアルタイム・スロットリング付き）
    func setRotationRealtime(_ degrees: Double) {
        // ドラッグ開始時点の状態をキャプチャ（Undo 用）
        if preDragSnapshot == nil {
            preDragSnapshot = currentSnapshot
        }

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
            fastPreviewTask = Task { [weak self] in
                await self?.generatePreviewFast()
            }
        } else {
            throttledPreviewTask?.cancel()
            throttledPreviewTask = Task { [weak self] in
                let waitNano = UInt64((fastPreviewMinInterval - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNano)
                guard !Task.isCancelled else { return }
                guard let self = self else { return }
                self.lastFastPreviewTime = CFAbsoluteTimeGetCurrent()
                self.fastPreviewTask?.cancel()
                self.fastPreviewTask = Task { [weak self] in
                    await self?.generatePreviewFast()
                }
            }
        }
    }

    /// 回転操作完了
    func finalizeRotation() {
        isEditingRealtime = false

        // ドラッグ開始時の状態を履歴に積む
        if let preDrag = preDragSnapshot {
            historyManager.push(preDrag)
            notifyHistoryChange()
            preDragSnapshot = nil
        }

        // 高速プレビューを通常プレビューに昇格
        if let fastPreview = fastPreviewImage {
            previewImage = fastPreview
        }
        fastPreviewImage = nil

        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 左右反転を切り替え
    func toggleFlipHorizontal() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        isFlippedHorizontal.toggle()
        invalidateLowResCache()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 上下反転を切り替え
    func toggleFlipVertical() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        isFlippedVertical.toggle()
        invalidateLowResCache()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 左に90度回転
    func rotateLeft() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        rotationDegrees -= 90
        if rotationDegrees < -180 {
            rotationDegrees += 360
        }
        invalidateLowResCache()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 右に90度回転
    func rotateRight() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        rotationDegrees += 90
        if rotationDegrees > 180 {
            rotationDegrees -= 360
        }
        invalidateLowResCache()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// アスペクト比を設定
    /// アスペクト比変更時はクロップ矩形も自動で中央配置・比率一致に整える
    func setCropAspectRatio(_ ratio: CropAspectRatio) {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        cropAspectRatio = ratio

        // `.free` 以外が選ばれたらクロップ矩形を中央配置で比率合わせ
        if let aspect = ratio.ratio {
            editRecipe.cropRectNorm = centeredCropRect(aspect: aspect)
        } else {
            // `.free`: 現在の矩形は維持（なければフル）
            if editRecipe.cropRectNorm == nil {
                editRecipe.cropRectNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }

        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 指定アスペクト比（幅/高さ）で画像中央に内接するクロップ矩形（正規化）を計算
    private func centeredCropRect(aspect: CGFloat) -> CGRect {
        guard let image = currentImage else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        // 表示用の画像サイズ（回転/反転は UI 上の見た目。クロップは
        // applyTransform 後の画像に対して適用されるため size をそのまま使う）
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let imageAspect = w / h
        let cropW: CGFloat
        let cropH: CGFloat
        if imageAspect > aspect {
            // 画像のほうが横長 → 高さいっぱい、幅を絞る
            cropH = 1.0
            cropW = aspect / imageAspect
        } else {
            cropW = 1.0
            cropH = imageAspect / aspect
        }
        let x = (1.0 - cropW) / 2.0
        let y = (1.0 - cropH) / 2.0
        return CGRect(x: x, y: y, width: cropW, height: cropH)
    }

    /// クロップ矩形を直接更新（インタラクティブ UI 用）
    /// `finalize` を true にすると Undo 履歴にも積む
    func updateCropRect(_ rect: CGRect, finalize: Bool) {
        if finalize {
            if preDragSnapshot == nil {
                preDragSnapshot = currentSnapshot
            }
            historyManager.push(preDragSnapshot ?? currentSnapshot)
            notifyHistoryChange()
            preDragSnapshot = nil
        } else if preDragSnapshot == nil {
            preDragSnapshot = currentSnapshot
        }

        editRecipe.cropRectNorm = rect

        if finalize {
            Task { [weak self] in
                await self?.generatePreview()
            }
        }
    }

    /// 切り取りタブ遷移時のクロップ UI 可視化。
    ///
    /// `editRecipe.cropRectNorm` が未設定、またはフル画面 (1.0x1.0) のままだと
    /// CropOverlayView の矩形・4隅のハンドルが画像の端と重なって視認できず、
    /// ユーザーに「トリミング機能がある」ことが伝わらない。
    /// 既定値として上下左右に約 8% のインセットを持つ矩形をセットし、
    /// マスク外側の暗転でトリミング UI が明確に見えるようにする。
    ///
    /// すでに何らかの矩形が設定されている場合は尊重（上書きしない）。
    func ensureVisibleCropRect() {
        let current = editRecipe.cropRectNorm
        let isFullFrame = current == nil
            || (current?.origin == .zero
                && current?.size == CGSize(width: 1, height: 1))
        guard isFullFrame else { return }

        let inset: CGFloat = 0.08
        let rect = CGRect(
            x: inset,
            y: inset,
            width: 1.0 - inset * 2,
            height: 1.0 - inset * 2
        )
        // 履歴は積まない（自動セットのため）
        editRecipe.cropRectNorm = rect
    }

    /// クロップをリセット（矩形だけクリア）
    func resetCropRect() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editRecipe.cropRectNorm = nil
        cropAspectRatio = .free
        // ⭐️ Issue #1: 画像切替後にリセットが消えないよう imageStates も同期
        saveCurrentImageState()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 切り取り・回転のリセット
    func resetCropSettings() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        rotationDegrees = 0
        isFlippedHorizontal = false
        isFlippedVertical = false
        cropAspectRatio = .free
        editRecipe.cropRectNorm = nil
        invalidateLowResCache()
        // ⭐️ Issue #1: 画像切替後にリセットが消えないよう imageStates も同期
        saveCurrentImageState()
        Task { [weak self] in
            await self?.generatePreview()
        }
    }
    
    // MARK: - Preview Generation

    /// プレビューを生成（デバウンス処理付き）
    private func debouncePreview() {
        // 前のタスクをキャンセル
        previewTask?.cancel()

        // 新しいタスクを作成（メモリリーク防止のため weak self を使用）
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms待機

            guard !Task.isCancelled else { return }
            await self?.generatePreview()
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

            // EditRecipe を直接渡す（toneCurvePoints などを保全するため）
            let preview = try await imageService.generatePreview(processedImage, recipe: editRecipe)

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

    /// 高速プレビューを生成（中解像度・750x750）☁️
    /// スライダー操作中のリアルタイム表示用
    /// キャッシュ済みの中解像度CIImageを使い、同期的にフィルターチェーンを適用
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
        let preview = imageService.generatePreviewFromCIImage(lowResCIImage, recipe: editRecipe)

        // リクエストIDが変わっていたら結果を破棄
        guard requestId == currentFastPreviewRequestId else { return }

        fastPreviewImage = preview
    }

    /// 変換状態のキーを生成（キャッシュ無効化判定用）
    private func makeTransformKey() -> String {
        "\(rotationDegrees)_\(isFlippedHorizontal)_\(isFlippedVertical)"
    }

    /// 中解像度CIImageキャッシュを再構築（同期版：互換性のため残す）
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

        // CIImage上で750x750にリサイズ（UIImage変換なし）
        let lowRes = imageService.resizeCIImage(ciImage, maxSize: CGSize(width: 750, height: 750))

        cachedLowResCIImage = lowRes
        cachedImageIndex = currentImageIndex
        cachedTransformKey = makeTransformKey()
    }

    /// 中解像度CIImageキャッシュを再構築（非同期版：バックグラウンド処理）☁️
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

            // CIImage上で750x750にリサイズ
            return imageServiceRef.resizeCIImage(ciImage, maxSize: CGSize(width: 750, height: 750))
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

        // UIGraphicsImageRendererで正規化（スレッドセーフかつモダンなAPI）
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// 中解像度キャッシュを無効化
    private func invalidateLowResCache() {
        cachedLowResCIImage = nil
    }

    /// 回転・反転を画像に適用（現在の UI 状態を使用）
    private func applyTransform(to image: UIImage) -> UIImage {
        applyTransform(
            to: image,
            rotation: rotationDegrees,
            flipH: isFlippedHorizontal,
            flipV: isFlippedVertical
        )
    }

    /// 回転・反転を画像に適用（パラメータ明示版）
    ///
    /// 画像ごとに独立したパラメータで変換を適用する `generateFinalImages()` から
    /// 利用するため、`self.*` を経由しない引数版を用意している。
    private func applyTransform(
        to image: UIImage,
        rotation: Double,
        flipH: Bool,
        flipV: Bool
    ) -> UIImage {
        // 回転も反転もない場合はそのまま返す
        guard rotation != 0 || flipH || flipV else {
            return image
        }

        let size = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { rendererContext in
            let context = rendererContext.cgContext

            // コンテキストの中心に移動
            context.translateBy(x: size.width / 2, y: size.height / 2)

            // 反転を適用
            var scaleX: CGFloat = 1.0
            var scaleY: CGFloat = 1.0
            if flipH {
                scaleX = -1.0
            }
            if flipV {
                scaleY = -1.0
            }
            context.scaleBy(x: scaleX, y: scaleY)

            // 回転を適用
            let radians = rotation * .pi / 180.0
            context.rotate(by: CGFloat(radians))

            // 画像を描画
            image.draw(in: CGRect(
                x: -size.width / 2,
                y: -size.height / 2,
                width: size.width,
                height: size.height
            ))
        }
    }
    
    // MARK: - Final Image Generation

    /// 最終的な編集済み画像を生成（全画像）
    /// EditRecipe を直接適用することで toneCurvePoints などを保全する
    ///
    /// 画像ごとに独立した編集パラメータを反映するため、現在編集中の画像の状態を
    /// `imageStates` に保存してから、各 index のスナップショットを使ってループで
    /// 適用する。
    func generateFinalImages() async throws -> [UIImage] {
        // 現在画像の編集状態を imageStates へ保存（最新化）
        saveCurrentImageState()

        var editedImages: [UIImage] = []

        for (index, image) in originalImages.enumerated() {
            let snapshot: EditorSnapshot = imageStates.indices.contains(index)
                ? imageStates[index]
                : EditorSnapshot(
                    recipe:              EditRecipe(),
                    rotationDegrees:     0,
                    isFlippedHorizontal: false,
                    isFlippedVertical:   false,
                    cropAspectRatio:     .free
                )

            let transformedImage = applyTransform(
                to: image,
                rotation: snapshot.rotationDegrees,
                flipH:    snapshot.isFlippedHorizontal,
                flipV:    snapshot.isFlippedVertical
            )
            let editedImage = try await imageService.applyEditRecipe(
                snapshot.recipe,
                to: transformedImage
            )
            editedImages.append(editedImage)
        }

        return editedImages
    }

    /// 全画像分の最終的な編集レシピ（画像ごとの独立した EditRecipe）を取得する。
    /// 投稿時に Firestore へ画像ごとの編集情報を保存する用途で利用する。
    func currentEditRecipes() -> [EditRecipe] {
        // 現在画像の編集状態を最新化した上で配列を返す
        saveCurrentImageState()
        return imageStates.map { $0.recipe }
    }

    /// 現在の画像の最終的な編集済み画像を生成
    /// EditRecipe を直接適用することで toneCurvePoints などを保全する
    func generateFinalImage() async throws -> UIImage {
        guard let image = currentImage else {
            throw EditViewModelError.noImage
        }

        let transformedImage = applyTransform(to: image)
        return try await imageService.applyEditRecipe(editRecipe, to: transformedImage)
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
