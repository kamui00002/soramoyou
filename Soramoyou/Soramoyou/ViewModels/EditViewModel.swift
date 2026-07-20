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

    /// 「あなたの定番」（柱1 v1）を適用できるか。コーパスに十分な学習データがある時だけ true。
    /// エディタ起動時（loadEquippedTools）に算出し、true のときだけボタンを表示する。
    @Published private(set) var hasPersonalDefault = false

    /// 後方互換 computed property
    ///
    /// View 側のコード（`viewModel.editSettings`）を変更せずに EditRecipe へ移行できる。
    /// get: EditRecipe を EditSettings に変換して返す
    /// set: EditSettings を EditRecipe に変換して保存
    ///
    /// 注意: `EditSettings` には `toneCurvePoints` / `targetDynamicRange` / `cropRectNorm` /
    /// `style2DToneNorm` / `style2DColorNorm` が含まれないため、set の時点で既存の値を
    /// 保全してから再構築する（スライダー操作でトーンカーブやスタイル調整が
    /// 失われる不具合を防止）。
    var editSettings: EditSettings {
        get { editRecipe.toEditSettings() }
        set {
            let existingPoints = editRecipe.toneCurvePoints
            let existingDynamicRange = editRecipe.targetDynamicRange
            let existingCropRect = editRecipe.cropRectNorm
            // スタイルパッドの値も EditSettings 変換で失われる EditRecipe 専用フィールドのため保全する
            // （スタイル調整後に普通編集ツールを触るとスタイルが基準に戻る不具合を防止）
            let existingStyleTone = editRecipe.style2DToneNorm
            let existingStyleColor = editRecipe.style2DColorNorm
            // 空補正強度も同様に EditSettings に存在しない EditRecipe 専用フィールドのため保全する
            // （空補正適用後に普通編集ツールを触ると補正が消える不具合を防止）
            let existingSkyCorrectionIntensity = editRecipe.skyCorrectionIntensity
            var newRecipe = EditRecipe(from: newValue)
            newRecipe.toneCurvePoints = existingPoints
            newRecipe.targetDynamicRange = existingDynamicRange
            newRecipe.cropRectNorm = existingCropRect
            newRecipe.style2DToneNorm = existingStyleTone
            newRecipe.style2DColorNorm = existingStyleColor
            newRecipe.skyCorrectionIntensity = existingSkyCorrectionIntensity
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
    /// パーソナルAI編集（柱1 v1）の学習コーパス（端末内）。テスト時に差し替え可能。
    private let recipeCorpusStore: RecipeCorpusStore
    /// 空マスク生成プロバイダ（ワンタップ空補正機能）。テスト時に差し替え可能。
    private let skyMaskProvider: SkyMaskProviderProtocol
    private var previewTask: Task<Void, Never>?
    private var fastPreviewTask: Task<Void, Never>?

    // MARK: - 低解像度CIImageキャッシュ（プレビュー高速化）

    /// リサイズ済み低解像度CIImage（キャッシュ）
    private var cachedLowResCIImage: CIImage?
    /// キャッシュ対象の画像インデックス
    private var cachedImageIndex: Int = -1
    /// キャッシュ時の変換状態キー（回転・反転）
    private var cachedTransformKey: String = ""

    // MARK: - 空マスクキャッシュ（ワンタップ空補正） ⭐️

    /// プレビュー用にキャッシュ済みの空マスク（`.preview` 品質）。
    /// `currentImageIndex` と変換状態（回転・反転）ごとに1回だけ生成する。
    private var cachedSkyMask: CIImage?
    /// キャッシュ済みマスクの空カバレッジ 0...1（「空が見つかりませんでした」判定に使う）
    private var cachedSkyMaskCoverage: Double?
    /// キャッシュ済みマスクの信頼度 0...1（同上）
    private var cachedSkyMaskConfidence: Double?
    /// キャッシュ対象の画像インデックス
    private var cachedSkyMaskImageIndex: Int = -1
    /// キャッシュ時の変換状態キー（回転・反転。`makeTransformKey()` を再利用）
    private var cachedSkyMaskTransformKey: String = ""
    /// 空マスク生成中フラグ。「空を整える」ボタンの初回タップ時のみ true になる
    /// （2回目以降はキャッシュ済みマスクを再利用するため一瞬で完了する）。
    @Published private(set) var isGeneratingSkyMask = false

    /// 空補正 Before/After 比較用の「補正前」プレビュー画像（⭐️ レビュー指摘4対応）。
    /// 現在のレシピから `skyCorrectionIntensity` だけ nil にした一時レシピで生成した、
    /// 「空補正以外の全編集は反映した状態」の画像。`prepareSkyCorrectionCompareImage()` が
    /// 長押し開始（トグル ON）のたびに 1 回だけ生成してここに書き込む。
    @Published private(set) var skyCorrectionCompareImage: UIImage?

    /// 空補正を「適用中」とみなす強度のしきい値（`FilterGraphBuilder.neutralValueThreshold` と同じ運用）
    private let skyCorrectionActiveThreshold: Double = 0.001
    /// 「空を整える」ボタンの初回タップで設定する既定強度
    private static let skyCorrectionDefaultIntensity: Double = 0.7
    /// 空検出の最低カバレッジ（これ未満は「空が見つかりませんでした」として適用しない）
    private static let skyCorrectionMinCoverage: Double = 0.05
    /// 空検出の最低信頼度（同上）
    private static let skyCorrectionMinConfidence: Double = 0.3

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
    /// 現在の finalize Task（ドラッグ終了後のフル解像度生成）の ID
    ///
    /// finalize 系（`finalizeToolValue` 等）が起動した generatePreview Task が、
    /// 完了時に `isEditingRealtime` / `fastPreviewImage` をリセットしてよいか判定する。
    /// 次のドラッグが始まると上書きされ、古い Task のクリーンアップはスキップされる。
    private var finalizePendingId: UUID?
    
    init(
        images: [UIImage] = [],
        userId: String? = nil,
        imageService: ImageServiceProtocol = ImageService(),
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        recipeCorpusStore: RecipeCorpusStore = RecipeCorpusStore(),
        skyMaskProvider: SkyMaskProviderProtocol = HeuristicSkyMaskProvider(),
        initialRecipe: EditRecipe? = nil
    ) {
        self.originalImages = images
        self.userId = userId
        self.imageService = imageService
        self.firestoreService = firestoreService
        self.recipeCorpusStore = recipeCorpusStore
        self.skyMaskProvider = skyMaskProvider

        // 画像ごとの編集状態スロットと履歴を初期化（画像枚数と1:1で対応）
        // レシピ共有から起動された場合は seed（initialRecipe）を全画像の初期レシピにする。
        // imageStates は画像切替時に save→restore されるため、editRecipe だけでなく
        // 全スロットに入れないと切替で seed が消えてしまう。
        let defaultSnapshot = EditorSnapshot(
            recipe:              initialRecipe ?? EditRecipe(),
            rotationDegrees:     0,
            isFlippedHorizontal: false,
            isFlippedVertical:   false,
            cropAspectRatio:     .free
        )
        self.imageStates = Array(repeating: defaultSnapshot, count: images.count)
        self.historyManagers = images.map { _ in EditHistoryManager() }

        // seed を現在の編集レシピにも反映（最初の generatePreview() から効かせる）。
        // history には積まない: seed 自体がこの編集セッションのベースラインのため。
        if let initialRecipe = initialRecipe {
            self.editRecipe = initialRecipe
            // レシピ共有の計測（共有レシピ付きでエディタが起動した回数）
            LoggingService.shared.logEvent("recipe_share_applied", parameters: nil)
        }

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

    // MARK: - パーソナルAI編集（柱1 v1）「あなたの定番」

    /// コーパスに十分な学習データがあるかを判定し `hasPersonalDefault` を更新する。
    /// （エディタ起動時に呼ぶ。未ログイン or データ不足なら false。）
    func refreshPersonalDefaultAvailability() {
        guard let userId = userId else {
            hasPersonalDefault = false
            return
        }
        let entries = recipeCorpusStore.entries(userId: userId)
        hasPersonalDefault = PersonalRecipeProfile.representative(for: nil, from: entries) != nil
    }

    /// 「あなたの定番」を現在の画像に適用する。
    /// - 過去の自分の編集（コーパス）から代表レシピを作り、トーン・カラー・フィルターを転写する。
    /// - クロップ・トーンカーブ（写真固有）は現在の値を保持する。
    /// - Undo 可能（適用前のスナップショットを履歴に push する）。
    func applyPersonalDefault() {
        guard let userId = userId else { return }
        let entries = recipeCorpusStore.entries(userId: userId)
        guard var representative = PersonalRecipeProfile.representative(for: nil, from: entries) else {
            return
        }
        // 写真固有の編集（クロップ・トーンカーブ・ダイナミックレンジ）は現在値を保持し、
        // 定番では上書きしない（HDR指定が SDR に戻る不具合の防止を含む）。
        representative.cropRectNorm      = editRecipe.cropRectNorm
        representative.toneCurvePoints   = editRecipe.toneCurvePoints
        representative.targetDynamicRange = editRecipe.targetDynamicRange

        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editRecipe = representative

        // パーソナルAI編集の利用計装（柱1 主要操作）
        LoggingService.shared.logEvent("personal_default_applied", parameters: ["sample_count": entries.count])

        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    // MARK: - ワンタップ空補正 ⭐️

    /// 「空を整える」ボタンの実行本体。
    ///
    /// 初回タップ時（このセッションでこの画像＋変換状態のマスクが未生成のとき）だけ
    /// `isGeneratingSkyMask` を立てて空マスクを生成し、以後はキャッシュを再利用する。
    /// 空が十分に検出できない場合は適用せず `errorMessage` を表示する。
    func applySkyCorrection() async {
        isGeneratingSkyMask = true
        defer { isGeneratingSkyMask = false }

        do {
            try await ensureSkyMaskCached(quality: .preview)
        } catch {
            ErrorHandler.logError(error, context: "EditViewModel.applySkyCorrection")
            errorMessage = error.userFriendlyMessage
            return
        }

        guard let coverage = cachedSkyMaskCoverage,
              let confidence = cachedSkyMaskConfidence,
              coverage >= Self.skyCorrectionMinCoverage,
              confidence >= Self.skyCorrectionMinConfidence else {
            errorMessage = "空が見つかりませんでした。別の写真でお試しください。"
            return
        }

        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editRecipe.skyCorrectionIntensity = Self.skyCorrectionDefaultIntensity

        // ワンタップ空補正の利用計装
        LoggingService.shared.logEvent("sky_correction_applied", parameters: [
            "sky_coverage": coverage,
            "confidence": confidence,
            "intensity": Self.skyCorrectionDefaultIntensity
        ])

        await generatePreview()
    }

    /// 空補正強度スライダーのリアルタイム更新（ドラッグ中）。
    /// トーンカーブ等のカスタム Binding と同じパターン: 呼び出し側が editRecipe を
    /// 直接更新してから `triggerRealtimePreview()` を呼ぶ。
    func updateSkyCorrectionIntensityRealtime(_ value: Double) {
        capturePreDragSnapshot()
        editRecipe.skyCorrectionIntensity = min(1.0, max(0.0, value))
        triggerRealtimePreview()
    }

    /// 空補正強度スライダーのドラッグ終了時（`finalizeRotation()` と同型のパターン）。
    func finalizeSkyCorrectionIntensity() {
        if let preDrag = preDragSnapshot {
            historyManager.push(preDrag)
            notifyHistoryChange()
            preDragSnapshot = nil
        }
        scheduleFullResPreviewAfterDrag()
    }

    /// 空補正を解除し、「空を整える」ボタン表示に戻す。
    func removeSkyCorrection() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editRecipe.skyCorrectionIntensity = nil
        Task { [weak self] in
            await self?.generatePreview()
        }
    }

    /// 空補正が「適用中」とみなせるか（⭐️ レビュー指摘5対応: 単一ソース化）。
    ///
    /// `EditView` 側で `(editRecipe.skyCorrectionIntensity ?? 0) > 0` を複数箇所に重複させると、
    /// `FilterGraphBuilder.neutralValueThreshold`（実際に補正が効き始めるしきい値）と
    /// 食い違うサイレント帯が生まれる。しきい値の定義をここ1箇所に集約し、
    /// `EditView` はこの computed property だけを参照する。
    var isSkyCorrectionActive: Bool {
        (editRecipe.skyCorrectionIntensity ?? 0) > skyCorrectionActiveThreshold
    }

    /// 空補正強度の表示用値（未設定時は 0）。
    /// `EditView` 側で `editRecipe.skyCorrectionIntensity ?? 0` を重複させないための単一ソース。
    var skyCorrectionIntensityValue: Double {
        editRecipe.skyCorrectionIntensity ?? 0
    }

    /// 空補正 Before/After 比較用の「補正前」画像を生成してキャッシュする（⭐️ レビュー指摘4対応）。
    ///
    /// 比較対象を「未編集の元画像」（`currentImage`）ではなく、「現在のレシピから
    /// `skyCorrectionIntensity` だけ nil にした状態」にすることで、他の編集ツール（フィルター・
    /// 露出・クロップ等）の見た目はそのままに、空補正の有無だけを比較できるようにする。
    /// 通常のプレビューと同じ変換・クロップ経路（`normalizedTransformedImage` →
    /// `imageService.generatePreview`）を通す。呼び出し側（`EditView`）は Before/After
    /// 比較の長押し開始（トグル ON）のたびに 1 回だけ呼ぶ想定。
    func prepareSkyCorrectionCompareImage() async {
        guard let image = currentImage else {
            skyCorrectionCompareImage = nil
            return
        }

        var recipeWithoutSkyCorrection = editRecipe
        recipeWithoutSkyCorrection.skyCorrectionIntensity = nil

        let transformed = normalizedTransformedImage(image)
        do {
            skyCorrectionCompareImage = try await imageService.generatePreview(
                transformed,
                recipe: recipeWithoutSkyCorrection,
                skyMask: nil
            )
        } catch {
            ErrorHandler.logError(error, context: "EditViewModel.prepareSkyCorrectionCompareImage")
            // 生成失敗時は nil のままにし、呼び出し側で displayPreviewImage にフォールバックさせる
            skyCorrectionCompareImage = nil
        }
    }

    /// 向き正規化（`.up` 焼き込み）と回転・反転適用をこの順序でまとめて行う共通ヘルパー
    /// （⭐️ レビュー指摘1対応）。
    ///
    /// `applyTransform` 単体は回転 0・反転なしのとき元画像をそのまま返すため、EXIF 向きタグ
    /// 付き（`.right` 等の縦撮り）画像をそのまま下流の CIImage 化に渡すと、`ensureSkyMaskCached`
    /// が生成する空マスク（常にこのヘルパー経由で `.up` 焼き込み済み）と extent の縦横が
    /// 食い違い、マスクが誤った領域に合成されるおそれがある。プレビュー（`generatePreview`）・
    /// 書き出し（`generateFinalImages` / `generateFinalImage`）・マスク生成
    /// （`ensureSkyMaskCached` / `prepareSkyCorrectionCompareImage`）の全経路をこのヘルパーに
    /// 統一することで、常に同一の「向き正規化済み＋変換適用済み」画像を基準にする。
    private func normalizedTransformedImage(_ image: UIImage) -> UIImage {
        applyTransform(to: normalizeImageOrientation(image))
    }

    /// 画像ごとに独立したパラメータ版（`generateFinalImages()` から使用）
    private func normalizedTransformedImage(
        _ image: UIImage,
        rotation: Double,
        flipH: Bool,
        flipV: Bool
    ) -> UIImage {
        applyTransform(to: normalizeImageOrientation(image), rotation: rotation, flipH: flipH, flipV: flipV)
    }

    /// プレビュー用の空マスクを（未生成なら）生成してキャッシュする。
    /// `currentImageIndex` と変換状態（回転・反転）のどちらかが変わっていれば再生成する。
    /// 生成した空マスクの extent は呼び出し時点の「向き正規化＋回転反転適用後」の画像と一致する
    /// （`FilterGraphBuilder` に渡す `source` と同じ基準に揃えるため）。
    private func ensureSkyMaskCached(quality: SkyMaskQuality) async throws {
        let transformKey = makeTransformKey()
        if cachedSkyMask != nil,
           cachedSkyMaskImageIndex == currentImageIndex,
           cachedSkyMaskTransformKey == transformKey {
            return
        }

        // 再生成前に一旦クリアする。生成失敗時に「別の画像／変換状態の古いマスク」を
        // 誤って使い回すと、空でない領域を空として合成してしまう恐れがあるため。
        cachedSkyMask = nil
        cachedSkyMaskCoverage = nil
        cachedSkyMaskConfidence = nil

        guard let image = currentImage else { return }
        // ⭐️ レビュー指摘2対応: await（`skyMaskProvider.makeSkyMask`）前に対象インデックスを
        // キャプチャする。キャプチャせず `currentImageIndex` を await 後に読み直すと、await 中
        // （マスク生成中）にユーザーが nextImage()/previousImage() で画像を切り替えた場合、
        // 「古い画像用に生成したマスク」が「切替後の新しい画像のキャッシュ」として誤って
        // 紐付いてしまう（`rebuildLowResCacheAsync` の `currentIndex` キャプチャと同じ前例に揃える）。
        let targetIndex = currentImageIndex
        let transformed = normalizedTransformedImage(image)
        guard let ciImage = CIImage(image: transformed) else {
            throw ImageServiceError.invalidImage
        }
        let mask = try await skyMaskProvider.makeSkyMask(for: ciImage, quality: quality)
        // ⭐️ 青染み軽減（空色適応ゲート）: マスクが壁など非空領域を誤って含んでいても、
        // 実際に空らしい色の画素にしか補正が効かないようにする。マスク生成と同じタイミングで
        // 一度だけ計算してキャッシュに焼き込む（詳細は SkyColorGate.swift 参照）。
        let refined = await refinedSkyMask(rawMask: mask.mask, sourceImage: ciImage)
        cachedSkyMask = refined
        cachedSkyMaskCoverage = mask.skyCoverage
        cachedSkyMaskConfidence = mask.confidence
        cachedSkyMaskImageIndex = targetIndex
        cachedSkyMaskTransformKey = transformKey
    }

    /// 空マスクに色ゲート（青染み軽減）を適用する共通ヘルパー。
    /// プレビュー（`ensureSkyMaskCached`）・書き出し（`makeExportSkyMask`）の両方から呼ぶ。
    /// パレット抽出（CPU 画素読み出し）は重い処理のため `Task.detached` でオフロードする
    /// （`HeuristicSkyMaskProvider.makeSkyMask` 自身が内部でオフロードしているのと同じ理由）。
    /// パレットが抽出できない（サンプル不足）場合は `rawMask` をそのまま返す（旧挙動＝ゲート無効）。
    private func refinedSkyMask(rawMask: CIImage, sourceImage: CIImage) async -> CIImage {
        let ciContext = CIContextPool.shared.ciContext
        let gateData = await Task.detached(priority: .userInitiated) {
            SkyColorGate.buildGateData(image: sourceImage, mask: rawMask, ciContext: ciContext)
        }.value
        guard let gateData else { return rawMask }
        return SkyColorGate.applyGate(to: rawMask, sampling: sourceImage, gateData: gateData)
    }

    /// 書き出し用マスク生成の結果（⭐️ レビュー指摘6対応）。
    ///
    /// 呼び出し側が「補正が設定されていない／しきい値未満（そもそも不要）」と
    /// 「補正ありのはずがマスク生成に失敗した」を区別できるようにする。前者は補正なしで
    /// 書き出しを継続してよいが、後者は画像に補正が反映されないため、レシピ側の
    /// `skyCorrectionIntensity` もフォールバックで nil にしないと「画像は補正なし・
    /// レシピは0.7」という永続的な不一致が Firestore に残ってしまう。
    private enum ExportSkyMaskResult {
        /// 補正が設定されていない、またはしきい値未満（マスク生成不要）
        case notApplicable
        /// マスク生成に成功
        case success(CIImage)
        /// マスク生成を試みたが失敗した
        case failed
    }

    /// 書き出し用の空マスクを生成する（`.export` 品質・毎回新規生成）。
    /// プレビュー用キャッシュとは独立させる（複数画像書き出し時に画像ごとに異なる
    /// マスクが必要なため、キャッシュを使い回すと別画像のマスクを誤用しかねない）。
    private func makeExportSkyMask(for image: UIImage, recipe: EditRecipe) async -> ExportSkyMaskResult {
        guard let intensity = recipe.skyCorrectionIntensity,
              intensity > skyCorrectionActiveThreshold else {
            return .notApplicable
        }
        guard let ciImage = CIImage(image: image) else { return .failed }
        do {
            let mask = try await skyMaskProvider.makeSkyMask(for: ciImage, quality: .export)
            // ⭐️ 青染み軽減（空色適応ゲート）: プレビュー経路（ensureSkyMaskCached）と同じ
            // ゲートを書き出し経路にも適用し、書き出し結果にも壁等の誤染色が残らないようにする。
            let refined = await refinedSkyMask(rawMask: mask.mask, sourceImage: ciImage)
            return .success(refined)
        } catch {
            ErrorHandler.logError(error, context: "EditViewModel.makeExportSkyMask")
            return .failed
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

        // 「あなたの定番」ボタンの可用性を更新（コーパスに十分な学習データがあるか）
        refreshPersonalDefaultAvailability()

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
            // skyMask: 同期経路のため新規生成はせず、キャッシュ済みマスクのみを渡す
            // （未生成なら nil＝空補正なしとして描画される。次の generatePreview() で追いつく）。
            fastPreviewImage = imageService.generatePreviewFromCIImage(lowResCIImage, recipe: editRecipe, skyMask: cachedSkyMask)
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
        // ドラッグ開始時の状態を履歴に積む
        if let preDrag = preDragSnapshot {
            historyManager.push(preDrag)
            notifyHistoryChange()
            preDragSnapshot = nil
        }
        scheduleFullResPreviewAfterDrag()
    }

    /// ドラッグ終了後のフル解像度プレビュー生成を予約する共通ヘルパー
    ///
    /// 旧実装は `previewImage = fastPreviewImage` の "昇格" を行っていたが、
    /// `fastPreviewImage` は 750×750 の低解像度キャッシュ由来のため、
    /// `generatePreview()` が次のドラッグで破棄／requestId ミスマッチで早期 return
    /// すると `previewImage` が 750px のまま固定され「編集すると画像が粗くなる」
    /// 現象を起こしていた（2026-05-17 4並列調査で発覚）。
    ///
    /// 本ヘルパーは：
    /// - `previewImage` への 750px 昇格を行わない（粗さの根源を断つ）
    /// - `isEditingRealtime` / `fastPreviewImage` を即座にリセットせず、
    ///   自分が起動した `generatePreview()` 完了まで維持し、`displayPreviewImage`
    ///   が引き続き `fastPreviewImage` を返すようにする
    /// - 完了時に `finalizePendingId` をチェックし、自分がまだ最新の finalize
    ///   Task か（次のドラッグが始まっていないか）確認してからリセットする
    private func scheduleFullResPreviewAfterDrag() {
        let myId = UUID()
        finalizePendingId = myId
        Task { [weak self] in
            guard let self = self else { return }
            await self.generatePreview()
            // 自分が最新の finalize Task でなければ何もしない（新しい Task に委ねる）
            guard self.finalizePendingId == myId else { return }
            self.finalizePendingId = nil
            self.isEditingRealtime = false
            self.fastPreviewImage = nil
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
        // ドラッグ開始時の状態を履歴に積む
        if let preDrag = preDragSnapshot {
            historyManager.push(preDrag)
            notifyHistoryChange()
            preDragSnapshot = nil
        }
        scheduleFullResPreviewAfterDrag()
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

    // MARK: - 2D スタイルパッド操作 ⭐️

    /// 2D スタイルパッドのドラッグ中: editRecipe を直接更新 + リアルタイムプレビュー
    ///
    /// パッドの座標 (toneNorm: Y, colorNorm: X) を [-1.0, 1.0] にクランプして
    /// EditRecipe に書き込み、30 fps スロットルでプレビューを更新する。
    /// ドラッグ開始時のスナップショットは初回のみキャプチャされ、Undo 履歴に積む準備をする。
    ///
    /// - Parameters:
    ///   - toneNorm: トーン軸（Y）の正規化値、正値=コントラスト強化、負値=フラット化
    ///   - colorNorm: カラー軸（X）の正規化値、正値=暖色寄り、負値=寒色寄り
    func updateStyle2DRealtime(toneNorm: Float, colorNorm: Float) {
        // ドラッグ開始時点の状態をキャプチャ（Undo 用）
        if preDragSnapshot == nil {
            preDragSnapshot = currentSnapshot
        }

        // [-1, 1] の範囲にクランプして EditRecipe に書き込む
        let clampedTone  = Double(min(1.0, max(-1.0, toneNorm)))
        let clampedColor = Double(min(1.0, max(-1.0, colorNorm)))
        editRecipe.style2DToneNorm  = clampedTone
        editRecipe.style2DColorNorm = clampedColor

        // 既存の triggerRealtimePreview() に乗せる
        // （30 fps スロットル + 低解像度キャッシュ再利用 + isEditingRealtime セット）
        triggerRealtimePreview()
    }

    /// 2D スタイルパッドのドラッグ完了: Undo 履歴に積み + フル解像度プレビュー再生成
    func finalizeStyle2D() {
        // ドラッグ開始時の状態を履歴に積む
        if let preDrag = preDragSnapshot {
            historyManager.push(preDrag)
            notifyHistoryChange()
            preDragSnapshot = nil
        }
        scheduleFullResPreviewAfterDrag()
    }

    /// 2D スタイルパッドの値を (0, 0) にリセット
    ///
    /// ヘッダーのリセットボタン (↺) から呼ぶ。Undo に積んでから即座に反映する。
    /// nil をセットすることで FilterGraphBuilder のスキップ判定が走り、
    /// パッド適用処理自体をパイプラインから外せる。
    func resetStyle2D() {
        historyManager.push(currentSnapshot)
        notifyHistoryChange()
        editRecipe.style2DToneNorm  = nil
        editRecipe.style2DColorNorm = nil
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
            // ⭐️ レビュー指摘1対応: 向き正規化（.up 焼き込み）→ 回転・反転適用の順で処理する。
            // 旧実装は applyTransform のみで、回転 0・反転なしのときは EXIF 向きタグ付き
            // （.right 等の縦撮り）画像がそのまま下流の PreviewRenderer.renderPreview
            // （CIImage(cgImage:) で raw 生成＝向きを無視）に渡っていたため、常に .up 焼き込み
            // 済みの空マスク（ensureSkyMaskCached）と extent の縦横が食い違い、空補正が
            // 誤った領域に合成される恐れがあった。normalizedTransformedImage で経路を揃える。
            let processedImage = await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return image }
                return await MainActor.run {
                    self.normalizedTransformedImage(image)
                }
            }.value

            // リクエストIDが変わっていたら結果を破棄
            guard requestId == currentPreviewRequestId else { return }

            // 空補正が設定されているのにマスク未生成（レシピ共有・Undo/Redo等での復元）なら
            // ここで生成しておく。ベストエフォート: 失敗しても補正なしでプレビューを継続する。
            if let intensity = editRecipe.skyCorrectionIntensity,
               intensity > skyCorrectionActiveThreshold {
                try? await ensureSkyMaskCached(quality: .preview)
                guard requestId == currentPreviewRequestId else { return }
            }

            // EditRecipe を直接渡す（toneCurvePoints などを保全するため）
            let preview = try await imageService.generatePreview(processedImage, recipe: editRecipe, skyMask: cachedSkyMask)

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
        // skyMask: 同期経路のため新規生成はせず、キャッシュ済みマスクのみを渡す
        let preview = imageService.generatePreviewFromCIImage(lowResCIImage, recipe: editRecipe, skyMask: cachedSkyMask)

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

        // 回転後の外接矩形サイズを算出。
        // 旧実装はキャンバスを常に元画像と同じ size で描画していたため、90°/270° の
        // 縦横入れ替わりが必要な場合に画像の長辺がはみ出し、中央が正方形にクロップ
        // されていた（例: 3024×4032 → 90°回転 → 3024×3024 にクロップ）。
        // 任意角度にも対応するため絶対 sin/cos で外接矩形を求める。
        let radians = rotation * .pi / 180.0
        let absSin = abs(sin(radians))
        let absCos = abs(cos(radians))
        let canvasSize = CGSize(
            width:  size.width * absCos + size.height * absSin,
            height: size.width * absSin + size.height * absCos
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)

        return renderer.image { rendererContext in
            let context = rendererContext.cgContext

            // キャンバスの中心（回転後の外接矩形の中央）に移動
            context.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)

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
            context.rotate(by: CGFloat(radians))

            // 元画像サイズで中心から描画（キャンバスが外接矩形なので 90°/270° でも切れない）
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
            var snapshot: EditorSnapshot = imageStates.indices.contains(index)
                ? imageStates[index]
                : EditorSnapshot(
                    recipe:              EditRecipe(),
                    rotationDegrees:     0,
                    isFlippedHorizontal: false,
                    isFlippedVertical:   false,
                    cropAspectRatio:     .free
                )

            // ⭐️ レビュー指摘1対応: 向き正規化（.up 焼き込み）→ 回転・反転適用の順で処理する
            // （normalizedTransformedImage、詳細は同メソッドのコメント参照）。
            let transformedImage = normalizedTransformedImage(
                image,
                rotation: snapshot.rotationDegrees,
                flipH:    snapshot.isFlippedHorizontal,
                flipV:    snapshot.isFlippedVertical
            )
            // 空補正の書き出し用マスクは画像ごとに独立して .export 品質で新規生成する
            // （プレビュー用キャッシュは currentImageIndex 1枚分しか保持しないため使い回せない）。
            let exportSkyMask: CIImage?
            switch await makeExportSkyMask(for: transformedImage, recipe: snapshot.recipe) {
            case .notApplicable:
                exportSkyMask = nil
            case .success(let mask):
                exportSkyMask = mask
            case .failed:
                // ⭐️ レビュー指摘6対応: マスク生成に失敗すると画像には補正が反映されない。
                // レシピの skyCorrectionIntensity をそのまま残すと「画像は補正なし・レシピは
                // 0.7」という永続的な不一致が Firestore に保存されてしまうため、この画像の
                // スナップショットだけ intensity を nil にフォールバックしてから書き出す。
                exportSkyMask = nil
                var fallbackRecipe = snapshot.recipe
                fallbackRecipe.skyCorrectionIntensity = nil
                snapshot = EditorSnapshot(
                    recipe:              fallbackRecipe,
                    rotationDegrees:     snapshot.rotationDegrees,
                    isFlippedHorizontal: snapshot.isFlippedHorizontal,
                    isFlippedVertical:   snapshot.isFlippedVertical,
                    cropAspectRatio:     snapshot.cropAspectRatio
                )
                if imageStates.indices.contains(index) {
                    imageStates[index] = snapshot
                }
                // 現在表示中の画像で失敗した場合は、投稿ペイロードに使われるライブの
                // editRecipe（PostInfoPayload.editRecipe 経由でレシピ共有・学習コーパスに
                // 渡る）も同期し、同じ不一致が別経路で再発しないようにする。
                if index == currentImageIndex {
                    editRecipe.skyCorrectionIntensity = nil
                }
            }
            let editedImage = try await imageService.applyEditRecipe(
                snapshot.recipe,
                to: transformedImage,
                skyMask: exportSkyMask
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

        // ⭐️ レビュー指摘1対応: 向き正規化 → 回転・反転適用の順で処理する（詳細は
        // normalizedTransformedImage のコメント参照）。
        let transformedImage = normalizedTransformedImage(image)

        var recipe = editRecipe
        let exportSkyMask: CIImage?
        switch await makeExportSkyMask(for: transformedImage, recipe: recipe) {
        case .notApplicable:
            exportSkyMask = nil
        case .success(let mask):
            exportSkyMask = mask
        case .failed:
            // ⭐️ レビュー指摘6対応: 画像には補正が反映されないため、レシピ側の
            // skyCorrectionIntensity もフォールバックし、「画像は補正なし・レシピは0.7」の
            // 永続不一致を防ぐ。ライブの editRecipe も同期する。
            exportSkyMask = nil
            recipe.skyCorrectionIntensity = nil
            editRecipe.skyCorrectionIntensity = nil
        }
        return try await imageService.applyEditRecipe(recipe, to: transformedImage, skyMask: exportSkyMask)
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
