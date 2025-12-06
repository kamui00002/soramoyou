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
    @Published var caption: String = ""
    @Published var hashtags: [String] = []
    @Published var location: Location?
    @Published var visibility: Visibility = .public
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0.0
    @Published var errorMessage: String?
    @Published var isPostSaved = false
    
    // 自動抽出された情報
    @Published var extractedInfo: ExtractedImageInfo?
    
    private let imageService: ImageServiceProtocol
    private let storageService: StorageServiceProtocol
    private let firestoreService: FirestoreServiceProtocol
    private let userId: String?
    
    private var uploadedImageURLs: [String] = []
    private var uploadedThumbnailURLs: [String] = []
    
    init(
        userId: String? = nil,
        imageService: ImageServiceProtocol = ImageService(),
        storageService: StorageServiceProtocol = StorageService(),
        firestoreService: FirestoreServiceProtocol = FirestoreService()
    ) {
        self.userId = userId
        self.imageService = imageService
        self.storageService = storageService
        self.firestoreService = firestoreService
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
        
        Task {
            do {
                // EXIF情報の抽出
                let exifData = try await imageService.extractEXIFData(firstImage)
                
                // 時間帯の判定
                let timeOfDay: TimeOfDay?
                if let capturedAt = exifData.capturedAt {
                    timeOfDay = TimeOfDay.from(date: capturedAt)
                } else {
                    timeOfDay = nil
                }
                
                // 色の抽出
                let colors = try await imageService.extractColors(firstImage, maxCount: 5)
                
                // 色温度の計算
                let colorTemperature = try await imageService.calculateColorTemperature(firstImage)
                
                // 空の種類の判定
                let skyType = try await imageService.detectSkyType(firstImage)
                
                extractedInfo = ExtractedImageInfo(
                    capturedAt: exifData.capturedAt,
                    timeOfDay: timeOfDay,
                    skyColors: colors,
                    colorTemperature: colorTemperature,
                    skyType: skyType
                )
            } catch {
                // エラーは無視（自動抽出はオプション）
                print("画像情報の抽出に失敗しました: \(error)")
            }
        }
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
        
        do {
            // 1. 画像をアップロード（リトライ可能）
            let imageURLs = try await RetryableOperation.executeIfRetryable(
                operationName: "PostViewModel.uploadImages"
            ) {
                try await uploadImages()
            }
            
            // 2. Firestoreに投稿データを保存
            let post = try await createPost(imageURLs: imageURLs)
            
            // 3. 投稿を保存（リトライ可能）
            _ = try await RetryableOperation.executeIfRetryable(
                operationName: "PostViewModel.createPost"
            ) {
                try await firestoreService.createPost(post)
            }
            
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
        } finally {
            isUploading = false
        }
    }
    
    /// 画像をアップロード
    private func uploadImages() async throws -> [(url: String, thumbnail: String?)] {
        var imageURLs: [(url: String, thumbnail: String?)] = []
        let totalImages = Double(editedImages.count)
        
        for (index, image) in editedImages.enumerated() {
            // 画像を圧縮・リサイズ
            let resizedImage = try await imageService.resizeImage(
                image,
                maxSize: CGSize(width: 2048, height: 2048)
            )
            
            let compressedData = try await imageService.compressImage(resizedImage, quality: 0.85)
            guard let compressedImage = UIImage(data: compressedData) else {
                throw PostViewModelError.imageCompressionFailed
            }
            
            // 画像をアップロード
            let imagePath = "posts/\(userId!)/\(UUID().uuidString).jpg"
            let imageURL = try await storageService.uploadImage(compressedImage, path: imagePath)
            uploadedImageURLs.append(imagePath)
            
            // サムネイルをアップロード（StorageServiceが自動的にthumbnails/を追加するため、元のパスを渡す）
            let thumbnailBasePath = "\(userId!)/\(UUID().uuidString).jpg"
            let thumbnailURL = try await storageService.uploadThumbnail(compressedImage, path: thumbnailBasePath)
            uploadedThumbnailURLs.append("thumbnails/\(thumbnailBasePath)")
            
            imageURLs.append((url: imageURL.absoluteString, thumbnail: thumbnailURL.absoluteString))
            
            // 進捗を更新
            uploadProgress = Double(index + 1) / totalImages * 0.9 // 90%まで（残り10%はFirestore保存）
        }
        
        return imageURLs
    }
    
    /// 投稿データを作成
    private func createPost(imageURLs: [(url: String, thumbnail: String?)]) throws -> Post {
        guard let userId = userId else {
            throw PostViewModelError.userNotAuthenticated
        }
        
        // ImageInfo配列を作成
        let imageInfos = imageURLs.enumerated().map { index, urls in
            ImageInfo(
                url: urls.url,
                thumbnail: urls.thumbnail,
                width: Int(editedImages[index].size.width),
                height: Int(editedImages[index].size.height),
                order: index
            )
        }
        
        // 投稿データを作成
        let post = Post(
            id: UUID().uuidString,
            userId: userId,
            images: imageInfos,
            caption: caption.isEmpty ? nil : caption,
            hashtags: hashtags.isEmpty ? nil : hashtags,
            location: location,
            skyColors: extractedInfo?.skyColors,
            capturedAt: extractedInfo?.capturedAt,
            timeOfDay: extractedInfo?.timeOfDay,
            skyType: extractedInfo?.skyType,
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
        
        uploadedImageURLs = []
        uploadedThumbnailURLs = []
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
        caption = ""
        hashtags = []
        location = nil
        visibility = .public
        extractedInfo = nil
        isPostSaved = false
        errorMessage = nil
        uploadedImageURLs = []
        uploadedThumbnailURLs = []
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

