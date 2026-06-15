//
//  PostViewModel.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import UIKit
import Combine

@MainActor
class PostViewModel: ObservableObject {
    @Published var selectedImages: [UIImage] = []
    @Published var editedImages: [UIImage] = []
    @Published var editSettings: EditSettings?
    /// 投稿に添付する完全な編集レシピ。
    /// パーソナルAI編集のコーパス記録・Post.attachedRecipe への添付に使う（旧 editSettings は残す）。
    /// ※ v1 は「代表1枚」: 複数画像投稿でも現在の編集レシピ1件のみを扱う（画像ごとのレシピ配列は将来対応）。
    private var editRecipe: EditRecipe?
    /// 各画像の外部編集情報（写真Appバッジ表示用）⭐️ Issue #4
    /// 配列の index は selectedImages と対応する。Photos ライブラリ権限なしや
    /// 解決失敗時は対応する要素が nil。
    @Published var externalEditInfos: [ExternalEditInfo?] = []
    @Published var caption: String = ""
    /// 機能1: 投稿にまとう気分（mood）。nil=未選択。フレーム＋キャプションの世界観を決める。
    @Published var selectedMood: Mood?
    /// 選択中の枠スタイル（mood の色 × この形で焼き込む。mood 未選択時は無視）
    @Published var selectedFrameStyle: FrameStyle = .classic
    /// 機能1: フレーム（額縁）に焼き込む一言。通常の `caption`（ハッシュタグ用）とは完全に別。
    /// フレームには **この値のみ** を焼く（caption は一切フレームに出さない）。mood 選択時のみ意味を持つ。
    @Published var frameCaption: String = ""
    /// 機能1: フレーム文字色（"#RRGGBB"）。nil=おまかせ（style 自動色）。mood 選択時のみ意味を持つ。
    @Published var frameTextColorHex: String?
    /// 機能1: フレーム文字フォント。nil=mood 既定フォント。mood 選択時のみ意味を持つ。
    @Published var frameFontStyle: FrameFontStyle?
    /// 投稿種別。.single=通常 / .collage=配置写真 / .panorama=広角合成。
    /// 入口（PostView のモード選択）で確定し、savePost の畳み込み・保存メタ分岐を駆動する。
    @Published var postKind: PostKind = .single
    /// 配置写真のレイアウト（postKind==.collage のとき有効）。
    @Published var collageLayout: CollageLayout = .grid2x2
    /// 配置写真の各パネルの一言ラベル（朝/昼/夜/雨 など・任意。index は selectedImages と対応）。
    @Published var panelLabels: [String] = ["", "", "", ""]
    @Published var hashtags: [String] = []
    @Published var location: Location?
    @Published var visibility: Visibility = .public
    @Published var saveOriginalImages: Bool = false  // オリジナル画像も保存するかどうか
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var isPostSaved = false

    // 自動抽出された情報
    @Published var extractedInfo: ExtractedImageInfo?

    // AI空タイプ判定結果 ☁️
    @Published var skyTypeClassificationResult: SkyTypeClassificationResult?
    @Published var isClassifyingSkyType = false
    @Published var userSelectedSkyType: SkyType?  // ユーザーが手動選択した場合

    private let imageService: ImageServiceProtocol
    private let skyTypeClassifier: SkyTypeClassifierProtocol
    private let storageService: StorageServiceProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let userId: String?

    /// 再編集対象の投稿コンテキスト（非nil＝既存投稿の上書き更新モード）。
    /// savePost はこの有無で createPost / updatePost を切り替える。
    private var editingContext: PostEditingContext?
    /// 上書き更新する既存投稿 ID（再編集モードのときのみ非nil）。
    var editingPostId: String? { editingContext?.postId }

    private var uploadedImageURLs: [String] = []
    private var uploadedThumbnailURLs: [String] = []
    private var uploadedOriginalImageURLs: [String] = []  // オリジナル画像のパス
    
    init(
        userId: String? = nil,
        imageService: ImageServiceProtocol = ImageService(),
        storageService: StorageServiceProtocol = StorageService(),
        firestoreService: FirestoreServiceProtocol = FirestoreService(),
        skyTypeClassifier: SkyTypeClassifierProtocol = SkyTypeClassifier()
    ) {
        self.userId = userId
        self.imageService = imageService
        self.storageService = storageService
        self.firestoreService = firestoreService
        self.skyTypeClassifier = skyTypeClassifier
    }
    
    // MARK: - Image Management
    
    /// 選択された画像を設定
    func setSelectedImages(_ images: [UIImage]) {
        selectedImages = images
        editedImages = []
        extractImageInfo()
        // 解像度・ファイルサイズを非同期でバリデーション（必要に応じてリサイズ・圧縮）
        Task { @MainActor in
            await validateAndNormalizeSelectedImages()
        }
    }

    /// 選択画像の解像度・ファイルサイズを検証し、必要に応じてリサイズ・圧縮する
    private func validateAndNormalizeSelectedImages() async {
        let maxDimension: CGFloat = 2048
        let maxBytes = 5 * 1024 * 1024
        for index in selectedImages.indices {
            let image = selectedImages[index]
            do {
                var normalized = image
                if image.size.width > maxDimension || image.size.height > maxDimension {
                    normalized = try await imageService.resizeImage(
                        normalized,
                        maxSize: CGSize(width: maxDimension, height: maxDimension)
                    )
                }
                if let data = normalized.jpegData(compressionQuality: 1.0),
                   data.count > maxBytes {
                    let compressed = try await imageService.compressImage(normalized, quality: 0.85)
                    if let compressedImage = UIImage(data: compressed) {
                        normalized = compressedImage
                    }
                }
                selectedImages[index] = normalized
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    /// 編集済み画像を設定
    func setEditedImages(_ images: [UIImage], editSettings: EditSettings, editRecipe: EditRecipe? = nil) {
        editedImages = images
        self.editSettings = editSettings
        self.editRecipe = editRecipe
    }

    /// 各画像の外部編集情報を設定（PHAsset 由来のメタ情報）⭐️ Issue #4
    func setExternalEditInfos(_ infos: [ExternalEditInfo?]) {
        externalEditInfos = infos
    }
    
    // MARK: - Post Info Management

    /// 再編集モードの seed を流し込む（既存投稿の値を投稿情報画面へ復元）。
    /// 以降 savePost は createPost ではなく updatePost（postId 上書き・カウント/作成日時保持）を行う。
    func seedForEditing(_ context: PostEditingContext) {
        editingContext = context
        caption = context.caption ?? ""
        frameCaption = context.frameCaption ?? ""
        frameTextColorHex = context.frameTextColorHex
        frameFontStyle = context.frameFontStyle
        selectedMood = context.mood
        selectedFrameStyle = context.frameStyle
        visibility = context.visibility
        hashtags = context.hashtags
        location = context.location
    }

    /// キャプションを設定
    func setCaption(_ caption: String) {
        self.caption = caption
        extractHashtags(from: caption)
    }

    /// ハッシュタグを抽出
    /// ⚠️ TextEditor の束縛 setter から毎キーストローク呼ぶと、@Published hashtags の更新が
    ///   入力中の再描画レースを起こし「打った文字が表示されない」不具合になる（実機で再現）。
    ///   そのため呼び出しは `$viewModel.caption` 直接束縛＋`.onChange` から行うこと。
    func extractHashtags(from text: String) {
        let hashtagPattern = #"#(\w+)"#
        let regex = try? NSRegularExpression(pattern: hashtagPattern, options: [])
        let nsString = text as NSString
        let results = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        
        hashtags = results?.compactMap { result in
            if result.numberOfRanges > 1 {
                let range = result.range(at: 1)
                return nsString.substring(with: range)
            }
            return nil
        } ?? []
    }
    
    /// 位置情報を設定
    func setLocation(_ location: Location) {
        self.location = location
    }
    
    /// 公開設定を設定
    func setVisibility(_ visibility: Visibility) {
        self.visibility = visibility
    }
    
    // MARK: - Image Info Extraction

    /// 画像情報を抽出
    private func extractImageInfo() {
        guard let firstImage = selectedImages.first else { return }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // EXIF情報の抽出
                let exifData = try await self.imageService.extractEXIFData(firstImage)

                // 時間帯の判定
                let timeOfDay: TimeOfDay?
                if let capturedAt = exifData.capturedAt {
                    timeOfDay = TimeOfDay.from(date: capturedAt)
                } else {
                    timeOfDay = nil
                }

                // 色の抽出
                let colors = try await self.imageService.extractColors(firstImage, maxCount: 5)

                // 色温度の計算
                let colorTemperature = try await self.imageService.calculateColorTemperature(firstImage)

                // AI空タイプ判定（新しい分類器を使用）☁️
                self.isClassifyingSkyType = true
                let classificationResult = try await self.skyTypeClassifier.classify(firstImage, timeOfDay: timeOfDay)
                self.skyTypeClassificationResult = classificationResult
                self.isClassifyingSkyType = false

                self.extractedInfo = ExtractedImageInfo(
                    capturedAt: exifData.capturedAt,
                    timeOfDay: timeOfDay,
                    skyColors: colors,
                    colorTemperature: colorTemperature,
                    skyType: classificationResult.skyType
                )
            } catch {
                self.isClassifyingSkyType = false
                // エラーをログに記録（自動抽出はオプションだが、ログ基盤には記録する）
                ErrorHandler.logError(error, context: "PostViewModel.extractImageInfo")
            }
        }
    }

    // MARK: - Sky Type Management ☁️

    /// ユーザーがAI判定結果を採用
    func acceptAISkyType() {
        guard let result = skyTypeClassificationResult else { return }
        userSelectedSkyType = nil  // AI判定を使用
        updateExtractedInfoSkyType(result.skyType)
    }

    /// ユーザーが手動で空タイプを選択
    func selectSkyType(_ skyType: SkyType) {
        userSelectedSkyType = skyType
        updateExtractedInfoSkyType(skyType)
    }

    /// extractedInfoのskyTypeを更新
    private func updateExtractedInfoSkyType(_ skyType: SkyType) {
        guard let info = extractedInfo else { return }
        extractedInfo = ExtractedImageInfo(
            capturedAt: info.capturedAt,
            timeOfDay: info.timeOfDay,
            skyColors: info.skyColors,
            colorTemperature: info.colorTemperature,
            skyType: skyType
        )
    }

    /// 現在有効な空タイプを取得
    var effectiveSkyType: SkyType? {
        if let userSelected = userSelectedSkyType {
            return userSelected
        }
        return skyTypeClassificationResult?.skyType ?? extractedInfo?.skyType
    }
    
    // MARK: - Post Save
    
    /// 投稿を保存
    func savePost() async throws {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }
        
        guard !editedImages.isEmpty else {
            throw PostViewModelError.noImages
        }
        
        isUploading = true
        uploadProgress = 0.0
        errorMessage = nil
        uploadedImageURLs = []
        uploadedThumbnailURLs = []
        uploadedOriginalImageURLs = []

        defer {
            isUploading = false
        }

        do {
            // 1a. 配置写真(collage)は複数枚を1枚に畳む（v1。広角合成は手前のフローで畳み込み済み）。
            //     畳み込みは非破壊（editedImages は書き換えない）＝リトライ・再投稿での二重合成を防ぐ。
            let folded = foldImagesIfNeeded(editedImages)
            // collage は「1枚に並べて必ず成功」が約束。万一 compose に失敗（folded が1枚にならない）したら、
            // 4枚バラ撒き＋collageメタ不整合の投稿を作らず、明示エラーで中断する（中途半端な保存を防ぐ）。
            if postKind == .collage && folded.count != 1 {
                throw PostViewModelError.collageCompositionFailed
            }

            // 1b. mood フレーム＋一言を焼き込む（mood 選択時のみ）。
            //     配置写真モードとは排他（二重額縁を避けるため collage では mood を焼かない）。
            let imagesToUpload = (postKind == .collage) ? folded : composeMoodFrameIfNeeded(folded)

            // 2. 編集済み画像をアップロード（リトライ可能）
            let imageURLs = try await RetryableOperation.executeIfRetryable(
                operationName: "PostViewModel.uploadImages"
            ) { [self] in
                try await self.uploadImages(imagesToUpload)
            }

            // 2. オリジナル画像をアップロード（ユーザーが選択した場合のみ）。
            //    合成投稿(collage/panorama)は素材N枚を原画像として残さない（images=合成1枚との非対称・
            //    再編集導線が postKind を運べず "panorama"/"collage" が消える破綻を防ぐ）。
            var originalImageURLs: [UploadedOriginalImage]? = nil
            if saveOriginalImages && !selectedImages.isEmpty && !postKind.isComposite {
                originalImageURLs = try await RetryableOperation.executeIfRetryable(
                    operationName: "PostViewModel.uploadOriginalImages"
                ) { [self] in
                    try await self.uploadOriginalImages()
                }
            }

            // 3. Firestoreに投稿データを保存
            let post = try await createPost(imageURLs: imageURLs, originalImageURLs: originalImageURLs)

            // 3. 投稿を保存 or 更新（リトライ可能）。再編集モードは既存 doc を上書き更新する。
            if let editing = editingContext {
                _ = try await RetryableOperation.executeIfRetryable(
                    operationName: "PostViewModel.updatePost"
                ) { [self] in
                    try await self.firestoreService.updatePost(post)
                }
                // 更新成功後、旧 Storage の孤児ファイルをベストエフォート削除（失敗は無視＝投稿更新は成立済み）。
                // 再アップロードで画像 URL は変わるため Kingfisher の URL キャッシュは自然に更新される。
                for path in editing.oldStoragePaths {
                    try? await storageService.deleteImage(path: path)
                }
            } else {
                _ = try await RetryableOperation.executeIfRetryable(
                    operationName: "PostViewModel.createPost"
                ) { [self] in
                    try await self.firestoreService.createPost(post)
                }
            }

            // パーソナルAI編集の学習コーパスへ記録（端末内・投稿成功時のみ・ベストエフォート）。
            // 記録に失敗しても投稿成功は妨げない。skyType は AI判定 or ユーザー選択を使う。
            // ⚠️ 未編集（中立）レシピは学習データを薄めるため記録しない（isNeutral でゲート）。
            // 再編集（上書き更新）ではコーパスへ重複記録しない（新規投稿のみ学習に使う）。
            if editingContext == nil, let recipe = editRecipe, !recipe.isNeutral {
                RecipeCorpusStore().append(
                    RecipeCorpusEntry(
                        recipe: recipe,
                        skyType: effectiveSkyType,
                        capturedAt: extractedInfo?.capturedAt
                    ),
                    userId: userId
                )
            }

            // 機能1: mood 付き投稿を計装（LoggingService ファサード経由・PII なし）
            if let mood = selectedMood {
                LoggingService.shared.logEvent("post_with_mood", parameters: [
                    "mood": mood.rawValue,
                    "frame_style": selectedFrameStyle.rawValue,
                    "has_caption": !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    // フレーム文字のカスタム選択（PII なし・bool/列挙のみ）
                    "has_custom_text_color": frameTextColorHex != nil,
                    "font_style": frameFontStyle?.rawValue ?? "default"
                ])
            }

            // v1: 配置写真投稿を計装（PII なし・列挙/boolのみ）
            if postKind == .collage {
                LoggingService.shared.logEvent("collage_created", parameters: [
                    "layout": collageLayout.rawValue,
                    "panel_count": min(4, selectedImages.count),
                    "has_labels": panelLabels.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                ])
            }

            // 4. 投稿作成を通知（プロフィール画面の自動更新用）☁️
            NotificationCenter.default.post(name: .postCreated, object: nil)

            isPostSaved = true
            uploadProgress = 1.0
        } catch {
            // エラーをログに記録
            ErrorHandler.logError(error, context: "PostViewModel.savePost", userId: userId)
            
            // エラー時はアップロード済み画像を削除（ロールバック）
            await rollbackUploadedImages()
            
            // ユーザーフレンドリーなメッセージを設定
            errorMessage = error.userFriendlyMessage
            throw error
        }
    }
    
    /// 画像をアップロード
    ///
    /// 🔧 2026-04-24 修正 (ultrareview bug_002):
    /// アップロード時の Storage パスを返すようにし、Post.images[].storagePath として
    /// Firestore に永続化する。投稿削除時に URL から不正なパスを組み立てる問題を解消。
    private func uploadImages(_ imagesToUpload: [UIImage]) async throws -> [UploadedImage] {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }

        var uploaded: [UploadedImage] = []
        let totalImages = Double(imagesToUpload.count)

        // visibility に基づいてサブパスを決定（storage.rules に合わせる）
        let visibilityPath: String
        switch visibility {
        case .public:
            visibilityPath = "public"
        case .followers:
            visibilityPath = "followers"
        case .private:
            visibilityPath = "private"
        }

        for (index, image) in imagesToUpload.enumerated() {
            // 画像を圧縮・リサイズ
            let resizedImage = try await imageService.resizeImage(
                image,
                maxSize: CGSize(width: 2048, height: 2048)
            )

            // 注意: StorageService で再圧縮されるため、ここでは圧縮せずに渡す
            // （二重圧縮による画質劣化を防ぐ）

            // 画像をアップロード（storage.rules のパス形式: posts/{userId}/{visibility}/{imageId}）
            let imageId = UUID().uuidString
            let imagePath = "posts/\(userId)/\(visibilityPath)/\(imageId).jpg"
            let imageURL = try await storageService.uploadImage(resizedImage, path: imagePath)
            uploadedImageURLs.append(imagePath)

            // サムネイルをアップロード（storage.rules のパス形式: thumbnails/{userId}/{visibility}/{imageId}）
            let thumbnailBasePath = "\(userId)/\(visibilityPath)/\(imageId)_thumb.jpg"
            let thumbnailFullPath = "thumbnails/\(thumbnailBasePath)"
            let thumbnailURL = try await storageService.uploadThumbnail(resizedImage, path: thumbnailBasePath)
            uploadedThumbnailURLs.append(thumbnailFullPath)

            // サイズはリサイズ後の実サイズを記録する（アップロードされる画像と一致させる）
            uploaded.append(UploadedImage(
                url: imageURL.absoluteString,
                thumbnail: thumbnailURL.absoluteString,
                width: Int(resizedImage.size.width),
                height: Int(resizedImage.size.height),
                storagePath: imagePath,
                thumbnailStoragePath: thumbnailFullPath
            ))

            // 進捗を更新（オリジナル画像保存時は70%まで、保存しない場合は90%まで）
            let progressMax = saveOriginalImages ? 0.7 : 0.9
            uploadProgress = Double(index + 1) / totalImages * progressMax
        }

        return uploaded
    }

    /// オリジナル画像をアップロード
    private func uploadOriginalImages() async throws -> [UploadedOriginalImage] {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }

        // 配列のスナップショットを取得（async待機中の変更を防ぐ）
        let imagesToUpload = selectedImages

        var uploaded: [UploadedOriginalImage] = []
        let totalImages = Double(imagesToUpload.count)

        // visibility に基づいてサブパスを決定
        let visibilityPath: String
        switch visibility {
        case .public:
            visibilityPath = "public"
        case .followers:
            visibilityPath = "followers"
        case .private:
            visibilityPath = "private"
        }

        for (index, image) in imagesToUpload.enumerated() {
            // オリジナル画像を圧縮・リサイズ
            let resizedImage = try await imageService.resizeImage(
                image,
                maxSize: CGSize(width: 2048, height: 2048)
            )

            // オリジナル画像をアップロード（storage.rules のパス形式: originals/{userId}/{visibility}/{imageId}）
            let imageId = UUID().uuidString
            let imagePath = "originals/\(userId)/\(visibilityPath)/\(imageId).jpg"
            let imageURL = try await storageService.uploadImage(resizedImage, path: imagePath)
            uploadedOriginalImageURLs.append(imagePath)

            // サイズはリサイズ後の実サイズを記録する（アップロードされる画像と一致させる）
            uploaded.append(UploadedOriginalImage(
                url: imageURL.absoluteString,
                width: Int(resizedImage.size.width),
                height: Int(resizedImage.size.height),
                storagePath: imagePath
            ))

            // 進捗を更新（70% 〜 90%）
            uploadProgress = 0.7 + (Double(index + 1) / totalImages * 0.2)
        }

        return uploaded
    }

    /// 投稿データを作成
    /// アップロード済み URL から Post を構築する（純粋・副作用なし）。
    /// `internal`（private でない）なのは collage 分岐の検証テストから直接呼ぶため（@testable import）。
    func createPost(
        imageURLs: [UploadedImage],
        originalImageURLs: [UploadedOriginalImage]? = nil
    ) throws -> Post {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }

        // ImageInfo配列を作成（アップロード時に収集したサイズ情報を使用）
        // 外部編集情報は selectedImages と同じ index で externalEditInfos から取得 ⭐️ Issue #4
        // 合成投稿(collage/panorama)は端末内で生成した新規画像で、特定の素材1枚に紐づかない。
        // 素材1枚目の外部編集情報を合成画像へ誤付与しないよう nil 化する
        // （ギャラリーの「写真Appで編集済み」等のバッジ誤表示を防ぐ。collage が抽出メタを付けない方針と同趣旨）。
        let imageInfos = imageURLs.enumerated().map { index, uploaded -> ImageInfo in
            let externalEditInfo: ExternalEditInfo? = postKind.isComposite
                ? nil
                : (externalEditInfos.indices.contains(index) ? externalEditInfos[index] : nil)
            return ImageInfo(
                url: uploaded.url,
                thumbnail: uploaded.thumbnail,
                width: uploaded.width,
                height: uploaded.height,
                order: index,
                storagePath: uploaded.storagePath,
                thumbnailStoragePath: uploaded.thumbnailStoragePath,
                externalEditInfo: externalEditInfo
            )
        }

        // オリジナル画像のImageInfo配列を作成（オプション）
        var originalImageInfos: [ImageInfo]? = nil
        if let originalURLs = originalImageURLs {
            originalImageInfos = originalURLs.enumerated().map { index, uploaded in
                ImageInfo(
                    url: uploaded.url,
                    thumbnail: nil,
                    width: uploaded.width,
                    height: uploaded.height,
                    order: index,
                    storagePath: uploaded.storagePath,
                    thumbnailStoragePath: nil
                )
            }
        }

        // 投稿データを作成（effectiveSkyTypeを使用 ☁️）
        // キャプションは前後の空白・改行を除去して保存する。空白のみのキャプションは
        // 焼き込み側（composeMoodFrameIfNeeded）と判定を揃えて nil 扱いにし、
        // 「保存値あり／焼き込みなし」の不一致を防ぐ。
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // フレーム用コメントは通常 caption と別保存。mood 未選択時はフレーム自体が出ないので nil。
        let trimmedFrameCaption = frameCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        // 再編集モード（既存投稿の上書き）では ID・カウント・作成日時・抽出メタを元投稿から保持する。
        let editing = editingContext
        // 原画像は再編集で変わらない＝元投稿のものをそのまま引き継ぐ（再アップロードしない）。
        // 新規投稿時のみ、ユーザーが保存を選んだ場合に今回アップロードした原画像を使う。
        let finalOriginalImages = editing?.originalImages ?? originalImageInfos

        // 配置写真(collage)は「合成済み1枚」を保存する特別扱い:
        // - 原画像(素材N枚)は残さない（images=1枚との非対称・再編集破綻を防ぐ。広角合成 panorama も同様）
        // - 抽出メタ(時間帯/空種別/色温度/撮影日時/空色)は1値で表せないので付けない（検索の歪み防止）
        let isCollage = (postKind == .collage)
        // 保存するラベル: collage かつ非空ラベルがあるときのみ。
        // 枚数ソースは「素材枚数」selectedImages。imageInfos は collage では畳み込み後=1枚なので
        // それを使うとパネル2〜4のラベルが欠落する（レビュー指摘の data-loss を修正）。
        let savedPanelLabels: [String]? = {
            guard isCollage else { return nil }
            let count = max(1, min(4, selectedImages.count))
            let trimmed = (0..<count).map { i -> String in
                i < panelLabels.count ? panelLabels[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            return trimmed.contains { !$0.isEmpty } ? trimmed : nil
        }()

        let post = Post(
            id: editing?.postId ?? UUID().uuidString,
            userId: userId,
            images: imageInfos,
            // 合成投稿(collage/panorama)は原画像を残さない＝再編集導線を出さない（postKind 消失防止）。
            originalImages: postKind.isComposite ? nil : finalOriginalImages,
            editSettings: editSettings,
            attachedRecipe: editRecipe,
            caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
            mood: selectedMood,
            // frameId = "mood_style"（色=mood × 形=style）。mood 未選択なら nil。
            frameId: selectedMood.map { "\($0.rawValue)_\(selectedFrameStyle.rawValue)" },
            frameCaption: (selectedMood != nil && !trimmedFrameCaption.isEmpty) ? trimmedFrameCaption : nil,
            // 文字色・フォントは mood 選択時のみ保存（おまかせ/既定は nil＝焼き込み側の自動解決へ委ねる）。
            frameTextColorHex: selectedMood != nil ? frameTextColorHex : nil,
            frameFontStyle: selectedMood != nil ? frameFontStyle : nil,
            // 投稿種別: .single は nil 保存（旧投稿とドキュメント形状を一致＝後方互換）。
            postKind: postKind == .single ? nil : postKind,
            collageLayout: isCollage ? collageLayout : nil,
            panelLabels: savedPanelLabels,
            hashtags: hashtags.isEmpty ? nil : hashtags,
            location: location,
            // 再編集時はメタを再導出せず元投稿の値を保持。新規時は抽出値を使用。配置写真は付けない。
            skyColors: isCollage ? nil : (editing?.skyColors ?? extractedInfo?.skyColors),
            capturedAt: isCollage ? nil : (editing?.capturedAt ?? extractedInfo?.capturedAt),
            timeOfDay: isCollage ? nil : (editing?.timeOfDay ?? extractedInfo?.timeOfDay),
            skyType: isCollage ? nil : (editing?.skyType ?? effectiveSkyType),  // 再編集=保持 / 新規=選択 or AI判定
            colorTemperature: isCollage ? nil : (editing?.colorTemperature ?? extractedInfo?.colorTemperature),
            visibility: visibility,
            // カウント・作成日時は再編集で不変（Firestore ルール isValidPostUpdate 要件）。新規は既定(0/now)。
            likesCount: editing?.likesCount ?? 0,
            commentsCount: editing?.commentsCount ?? 0,
            createdAt: editing?.createdAt ?? Date()
        )

        return post
    }

    /// 配置写真(collage)モードのとき、複数の編集済み画像を1枚に畳む（非破壊）。
    ///
    /// - postKind==.collage: SkyCollageCompositor で 2×2 / 縦4 に並べた1枚を返す（P3/HDR維持）。
    ///   合成失敗（compositor が nil）時は安全側で元配列をそのまま返す（投稿は継続）。
    /// - それ以外（single/panorama）: 素通し。広角合成(panorama)は手前のプレビュー画面で
    ///   既に1枚に畳まれた状態で editedImages に入っている前提。
    private func foldImagesIfNeeded(_ images: [UIImage]) -> [UIImage] {
        guard postKind == .collage, images.count >= 2 else { return images }
        let labels = panelLabels.map { $0.isEmpty ? nil : $0 }
        if let collaged = SkyCollageCompositor.composeToUIImage(photos: images, labels: labels, layout: collageLayout) {
            return [collaged]
        }
        return images
    }

    /// mood / キャプションがあれば編集済み画像へフレーム＋キャプションを焼き込む（非破壊）。
    ///
    /// - mood も caption も無ければ入力をそのまま返す（passthrough）。
    /// - Display P3 / HDR を保つため、CIImage 空間で orientation を適用し、合成結果は
    ///   `CIContextPool` の outputColorSpace(Display P3) で UIImage 化する
    ///   （`UIImage(ciImage:)` / UIGraphicsImageRenderer 経由は広色域を落とすため使わない）。
    /// - フル解像度合成のメモリスパイクを避けるため 1 枚ずつ `autoreleasepool` で囲む。
    private func composeMoodFrameIfNeeded(_ images: [UIImage]) -> [UIImage] {
        // フレームに焼くのは frameCaption（専用欄）のみ。通常 caption（ハッシュタグ用）は一切焼かない。
        let trimmedFrameCaption = frameCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let frameText = trimmedFrameCaption.isEmpty ? nil : trimmedFrameCaption

        // 額縁＋下プレートは mood 選択時のみ生成する。mood 未選択なら何も焼かず素通し
        // （写真の上に文字が浮く旧挙動を排除＝完全分離）。
        guard let mood = selectedMood else { return images }

        // 文字色（おまかせ=nil）・フォント（mood 既定=nil）の上書き。解析不可な hex は nil 扱い＝自動色。
        let colorOverride = frameTextColorHex.flatMap { UIColor(hex: $0) }
        let fontOverride = frameFontStyle

        var result: [UIImage] = []
        result.reserveCapacity(images.count)
        for image in images {
            // フル解像度合成のメモリスパイクを避けるため 1 枚ずつ autoreleasepool で囲む。
            // 合成本体（向き正規化・P3 維持）は ImageCompositor.composeToUIImage に集約。
            autoreleasepool {
                result.append(
                    ImageCompositor.composeToUIImage(base: image, mood: mood, caption: frameText,
                                                     style: selectedFrameStyle,
                                                     captionColor: colorOverride, fontStyle: fontOverride)
                )
            }
        }
        return result
    }

    /// アップロード済み画像をロールバック
    private func rollbackUploadedImages() async {
        // アップロード済み画像を削除
        for path in uploadedImageURLs {
            try? await storageService.deleteImage(path: path)
        }

        for path in uploadedThumbnailURLs {
            try? await storageService.deleteImage(path: path)
        }

        // オリジナル画像も削除
        for path in uploadedOriginalImageURLs {
            try? await storageService.deleteImage(path: path)
        }

        uploadedImageURLs = []
        uploadedThumbnailURLs = []
        uploadedOriginalImageURLs = []
    }
    
    // MARK: - Draft Management
    
    /// 下書きを保存
    func saveDraft() async throws {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }
        
        guard !selectedImages.isEmpty else {
            throw PostViewModelError.noImages
        }
        
        // ImageInfo配列を作成（編集済み画像がない場合は元画像を使用）
        let imagesToUse = editedImages.isEmpty ? selectedImages : editedImages
        let imageInfos = imagesToUse.enumerated().map { index, image in
            ImageInfo(
                url: "", // 下書きではURLは空
                width: Int(image.size.width),
                height: Int(image.size.height),
                order: index
            )
        }
        
        // 下書きデータを作成
        let draft = Draft(
            id: UUID().uuidString,
            userId: userId,
            images: imageInfos,
            editedImages: editedImages.isEmpty ? nil : imageInfos,
            editSettings: editSettings,
            caption: caption.isEmpty ? nil : caption,
            hashtags: hashtags.isEmpty ? nil : hashtags,
            location: location,
            visibility: visibility
        )
        
        _ = try await firestoreService.saveDraft(draft)
    }
    
    /// 下書きを読み込み
    func loadDraft(_ draft: Draft) {
        // 下書きデータをViewModelに設定
        // 注意: 下書きには画像データが含まれていないため、画像は別途読み込む必要がある
        caption = draft.caption ?? ""
        hashtags = draft.hashtags ?? []
        location = draft.location
        visibility = draft.visibility
        editSettings = draft.editSettings
    }
    
    // MARK: - Reset
    
    /// すべてのデータをリセット
    func reset() {
        selectedImages = []
        editedImages = []
        editSettings = nil
        externalEditInfos = []  // ⭐️ Issue #4
        caption = ""
        selectedMood = nil
        selectedFrameStyle = .classic
        frameCaption = ""
        frameTextColorHex = nil
        frameFontStyle = nil
        postKind = .single
        collageLayout = .grid2x2
        panelLabels = ["", "", "", ""]
        editingContext = nil
        hashtags = []
        location = nil
        visibility = .public
        saveOriginalImages = false
        extractedInfo = nil
        skyTypeClassificationResult = nil  // ☁️
        isClassifyingSkyType = false  // ☁️
        userSelectedSkyType = nil  // ☁️
        isPostSaved = false
        errorMessage = nil
        uploadedImageURLs = []
        uploadedThumbnailURLs = []
        uploadedOriginalImageURLs = []
    }
}

// MARK: - ExtractedImageInfo

struct ExtractedImageInfo {
    let capturedAt: Date?
    let timeOfDay: TimeOfDay?
    let skyColors: [String]
    let colorTemperature: Int?
    let skyType: SkyType?
}

// MARK: - アップロード結果 Value Object

/// 編集済み本体画像のアップロード結果。
/// Storage パスを保持することで、投稿削除時に URL から不正なパスを組み立てる問題を回避する。
struct UploadedImage {
    let url: String
    let thumbnail: String?
    let width: Int
    let height: Int
    let storagePath: String
    let thumbnailStoragePath: String
}

/// オリジナル画像（編集前）のアップロード結果。サムネイル生成は行わない。
struct UploadedOriginalImage {
    let url: String
    let width: Int
    let height: Int
    let storagePath: String
}

// MARK: - PostViewModelError

enum PostViewModelError: LocalizedError {
    case userNotAuthenticated
    case noImages
    case imageCompressionFailed
    case uploadFailed
    case saveFailed
    case collageCompositionFailed

    var errorDescription: String? {
        switch self {
        case .userNotAuthenticated:
            return "ログインが必要です"
        case .noImages:
            return "画像が選択されていません"
        case .imageCompressionFailed:
            return "画像の圧縮に失敗しました"
        case .uploadFailed:
            return "画像のアップロードに失敗しました"
        case .saveFailed:
            return "投稿の保存に失敗しました"
        case .collageCompositionFailed:
            return "配置写真の作成に失敗しました。写真を選び直してお試しください"
        }
    }
}
