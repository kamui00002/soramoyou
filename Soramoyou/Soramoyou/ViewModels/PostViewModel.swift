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
    /// 各画像の外部編集情報（写真Appバッジ表示用）⭐️ Issue #4
    /// 配列の index は selectedImages と対応する。Photos ライブラリ権限なしや
    /// 解決失敗時は対応する要素が nil。
    @Published var externalEditInfos: [ExternalEditInfo?] = []
    @Published var caption: String = ""
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
    }
    
    /// 編集済み画像を設定
    func setEditedImages(_ images: [UIImage], editSettings: EditSettings) {
        editedImages = images
        self.editSettings = editSettings
    }

    /// 各画像の外部編集情報を設定（PHAsset 由来のメタ情報）⭐️ Issue #4
    func setExternalEditInfos(_ infos: [ExternalEditInfo?]) {
        externalEditInfos = infos
    }
    
    // MARK: - Post Info Management
    
    /// キャプションを設定
    func setCaption(_ caption: String) {
        self.caption = caption
        extractHashtags(from: caption)
    }
    
    /// ハッシュタグを抽出
    private func extractHashtags(from text: String) {
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
            // 1. 編集済み画像をアップロード（リトライ可能）
            let imageURLs = try await RetryableOperation.executeIfRetryable(
                operationName: "PostViewModel.uploadImages"
            ) { [self] in
                try await self.uploadImages()
            }

            // 2. オリジナル画像をアップロード（ユーザーが選択した場合のみ）
            var originalImageURLs: [UploadedOriginalImage]? = nil
            if saveOriginalImages && !selectedImages.isEmpty {
                originalImageURLs = try await RetryableOperation.executeIfRetryable(
                    operationName: "PostViewModel.uploadOriginalImages"
                ) { [self] in
                    try await self.uploadOriginalImages()
                }
            }

            // 3. Firestoreに投稿データを保存
            let post = try await createPost(imageURLs: imageURLs, originalImageURLs: originalImageURLs)
            
            // 3. 投稿を保存（リトライ可能）
            _ = try await RetryableOperation.executeIfRetryable(
                operationName: "PostViewModel.createPost"
            ) { [self] in
                try await self.firestoreService.createPost(post)
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
    private func uploadImages() async throws -> [UploadedImage] {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }

        // 配列のスナップショットを取得（async待機中の変更を防ぐ）
        let imagesToUpload = editedImages

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

            // サイズ情報もスナップショット時点で収集
            uploaded.append(UploadedImage(
                url: imageURL.absoluteString,
                thumbnail: thumbnailURL.absoluteString,
                width: Int(image.size.width),
                height: Int(image.size.height),
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

            // サイズ情報もスナップショット時点で収集
            uploaded.append(UploadedOriginalImage(
                url: imageURL.absoluteString,
                width: Int(image.size.width),
                height: Int(image.size.height),
                storagePath: imagePath
            ))

            // 進捗を更新（70% 〜 90%）
            uploadProgress = 0.7 + (Double(index + 1) / totalImages * 0.2)
        }

        return uploaded
    }

    /// 投稿データを作成
    private func createPost(
        imageURLs: [UploadedImage],
        originalImageURLs: [UploadedOriginalImage]? = nil
    ) throws -> Post {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }

        // ImageInfo配列を作成（アップロード時に収集したサイズ情報を使用）
        // 外部編集情報は selectedImages と同じ index で externalEditInfos から取得 ⭐️ Issue #4
        let imageInfos = imageURLs.enumerated().map { index, uploaded -> ImageInfo in
            let externalEditInfo = externalEditInfos.indices.contains(index)
                ? externalEditInfos[index]
                : nil
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
        let post = Post(
            id: UUID().uuidString,
            userId: userId,
            images: imageInfos,
            originalImages: originalImageInfos,
            editSettings: editSettings,
            caption: caption.isEmpty ? nil : caption,
            hashtags: hashtags.isEmpty ? nil : hashtags,
            location: location,
            skyColors: extractedInfo?.skyColors,
            capturedAt: extractedInfo?.capturedAt,
            timeOfDay: extractedInfo?.timeOfDay,
            skyType: effectiveSkyType,  // ユーザー選択 or AI判定
            colorTemperature: extractedInfo?.colorTemperature,
            visibility: visibility
        )

        return post
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
        }
    }
}
