// ⭐️ StorageService.swift
// Firebase Storage への画像アップロード・サムネイル生成
//
//  StorageService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//
// 🔧 Phase 0 修正 (2026-04-22):
//   - uploadImage の JPEG 圧縮品質 0.85 → 0.95（投稿画質向上）
//   - サムネイル用 JPEG 圧縮は 0.80 維持（表示用途のため許容）
//   - resizeImageForThumbnail: CIContext を毎回生成 → CIContextPool.shared を使用
//     （Metal デバイス・コマンドキュー共有でオーバーヘッド削減、最大 5 倍高速化）
//   - print → os.Logger（rules/swift.md 準拠）
//

import Combine
import CoreImage
import FirebaseStorage
import Foundation
import ImageIO
import MobileCoreServices
import os
import UIKit
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.soramoyou.photo-editor", category: "StorageService")

protocol StorageServiceProtocol {
    func uploadImage(_ image: UIImage, path: String) async throws -> URL
    func uploadThumbnail(_ image: UIImage, path: String) async throws -> URL
    func deleteImage(path: String) async throws
    func uploadProgress(path: String) -> AsyncStream<Double>
}

class StorageService: StorageServiceProtocol {
    private let storage: Storage
    private var progressStreams: [String: AsyncStream<Double>.Continuation] = [:]
    private let progressStreamsQueue = DispatchQueue(label: "com.soramoyou.storage.progress")

    init(storage: Storage = Storage.storage()) {
        self.storage = storage
    }

    // MARK: - Upload Image

    func uploadImage(_ image: UIImage, path: String) async throws -> URL {
        do {
            // 🔧 2026-04-24 修正 (コードレビュー M8):
            // 旧 `UIImage.jpegData` は UIKit 内部の sRGB 固定エンコーダで Display P3 等の広色域を
            // ダウンコンバートしてしまう。PhotoKitAdapter.saveEdit は CIContext.writeJPEGRepresentation
            // で書き出すため、同じ画像でも投稿 JPEG (Storage) と写真保存 JPEG で色空間が微妙に違う
            // という不整合があった。`encodeJPEG` ヘルパーで ImageIO ベースの書き出しに揃える。
            let imageData = try encodeJPEG(image: image, quality: 0.95)

            // 画像サイズの検証（最大5MB）
            let maxSize: Int = 5 * 1024 * 1024
            if imageData.count > maxSize {
                throw StorageServiceError.imageTooLarge
            }

            let storageRef = storage.reference().child(path)

            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"

            let uploadMetadata = try await storageRef.putDataAsync(imageData, metadata: metadata)

            guard uploadMetadata.path != nil else {
                throw StorageServiceError.uploadFailed(NSError(
                    domain: "com.soramoyou.storage",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Upload completed but metadata is invalid"]
                ))
            }

            let downloadURL = try await getDownloadURLWithRetry(storageRef: storageRef, maxRetries: 3)
            return downloadURL
        } catch let error as StorageServiceError {
            throw error
        } catch {
            throw StorageServiceError.uploadFailed(error)
        }
    }

    // MARK: - Helper: Download URL with Retry

    /// ダウンロードURLを取得（リトライ機構付き）
    /// - Parameters:
    ///   - storageRef: Storage参照
    ///   - maxRetries: 最大リトライ回数
    /// - Returns: ダウンロードURL
    private func getDownloadURLWithRetry(storageRef: StorageReference, maxRetries: Int) async throws -> URL {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: UInt64(attempt * 500_000_000))
                }

                let downloadURL = try await storageRef.downloadURL()
                return downloadURL
            } catch {
                lastError = error
                // Phase 0 修正: print → os.Logger
                logger.warning("ダウンロードURL取得失敗 (試行 \(attempt + 1)/\(maxRetries)): \(error.localizedDescription, privacy: .public)")

                if attempt < maxRetries - 1 {
                    continue
                }
            }
        }

        throw lastError ?? StorageServiceError.uploadFailed(NSError(
            domain: "com.soramoyou.storage",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to get download URL after \(maxRetries) retries"]
        ))
    }

    // MARK: - Upload Thumbnail

    func uploadThumbnail(_ image: UIImage, path: String) async throws -> URL {
        let thumbnailPath = "thumbnails/\(path)"
        do {
            let thumbnailSize = CGSize(width: 512, height: 512)
            let thumbnailImage = try await resizeImageForThumbnail(image, targetSize: thumbnailSize)

            // 🔧 2026-04-24 修正 (コードレビュー M8): jpegData → ImageIO 経路に統一
            // サムネイル表示用: 0.80 維持（容量優先）
            let thumbnailData = try encodeJPEG(image: thumbnailImage, quality: 0.80)

            let storageRef = storage.reference().child(thumbnailPath)

            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"

            let uploadMetadata = try await storageRef.putDataAsync(thumbnailData, metadata: metadata)

            guard uploadMetadata.path != nil else {
                throw StorageServiceError.uploadFailed(NSError(
                    domain: "com.soramoyou.storage",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Thumbnail upload completed but metadata is invalid"]
                ))
            }

            let downloadURL = try await getDownloadURLWithRetry(storageRef: storageRef, maxRetries: 3)
            return downloadURL
        } catch let error as StorageServiceError {
            throw error
        } catch {
            throw StorageServiceError.uploadFailed(error)
        }
    }

    // MARK: - Delete Image

    func deleteImage(path: String) async throws {
        do {
            let storageRef = storage.reference().child(path)
            try await storageRef.delete()
        } catch {
            throw StorageServiceError.deleteFailed(error)
        }
    }

    // MARK: - Upload Progress

    func uploadProgress(path: String) -> AsyncStream<Double> {
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self = self else { return }
                self.progressStreamsQueue.async {
                    self.progressStreams.removeValue(forKey: path)
                }
            }
            progressStreamsQueue.async {
                self.progressStreams[path] = continuation
            }
        }
    }

    private func setupProgressObserver(for uploadTask: StorageUploadTask, path: String) {
        uploadTask.observe(.progress) { [weak self] snapshot in
            guard let self = self,
                  let progress = snapshot.progress else {
                return
            }

            let fractionCompleted = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)

            self.progressStreamsQueue.async {
                if let continuation = self.progressStreams[path] {
                    continuation.yield(fractionCompleted)
                }
            }
        }

        uploadTask.observe(.success) { [weak self] _ in
            guard let self = self else { return }

            self.progressStreamsQueue.async {
                if let continuation = self.progressStreams[path] {
                    continuation.yield(1.0)
                    continuation.finish()
                    self.progressStreams.removeValue(forKey: path)
                }
            }
        }

        uploadTask.observe(.failure) { [weak self] _ in
            guard let self = self else { return }

            self.progressStreamsQueue.async {
                if let continuation = self.progressStreams[path] {
                    continuation.finish()
                    self.progressStreams.removeValue(forKey: path)
                }
            }
        }
    }

    private func cleanupProgressObserver(for path: String) {
        progressStreamsQueue.async {
            if let continuation = self.progressStreams[path] {
                continuation.finish()
                self.progressStreams.removeValue(forKey: path)
            }
        }
    }

    // MARK: - Helper Methods

    /// 🔧 2026-04-24 修正 (コードレビュー M8):
    /// UIImage.jpegData は UIKit 内部の sRGB 固定エンコーダで広色域を落とす。
    /// PhotoKitAdapter 側は CIContext.writeJPEGRepresentation で Display P3 を保持するため、
    /// 投稿 JPEG と写真保存 JPEG で色空間が違うという不整合があった。
    /// ここでは CIContext.writeJPEGRepresentation を使い、両経路の色空間を揃える。
    /// CIImage 変換に失敗するケース (モデル画像等) のみフォールバックで jpegData を使う。
    private func encodeJPEG(image: UIImage, quality: CGFloat) throws -> Data {
        if let ciImage = CIImage(image: image) ?? image.cgImage.map({ CIImage(cgImage: $0) }) {
            let pool = CIContextPool.shared
            let colorSpace = pool.outputColorSpace
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
            ]
            if let data = pool.ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: colorSpace,
                options: options
            ) {
                return data
            }
        }
        // 予期せぬ失敗時のみフォールバック（実機で起きないはずだが念のため）
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw StorageServiceError.compressionFailed
        }
        logger.warning("CIContext.jpegRepresentation に失敗したため UIImage.jpegData にフォールバック")
        return data
    }

    /// Phase 0 修正: CIContext 毎回生成 → CIContextPool.shared 利用
    /// CIContext は MTLDevice / MTLCommandQueue を内部で確保するため生成コストが高い。
    /// プール共有で Metal コンテキスト初期化を省き、サムネイル生成を最大 5 倍高速化。
    private func resizeImageForThumbnail(_ image: UIImage, targetSize: CGSize) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let size = image.size
                let aspectRatio = size.width / size.height

                var newSize: CGSize
                if size.width > size.height {
                    if size.width > targetSize.width {
                        newSize = CGSize(width: targetSize.width, height: targetSize.width / aspectRatio)
                    } else {
                        newSize = size
                    }
                } else {
                    if size.height > targetSize.height {
                        newSize = CGSize(width: targetSize.height * aspectRatio, height: targetSize.height)
                    } else {
                        newSize = size
                    }
                }

                guard let cgImage = image.cgImage else {
                    continuation.resume(returning: image)
                    return
                }
                let ciImage = CIImage(cgImage: cgImage)
                let scaleX = newSize.width / ciImage.extent.width
                let scaleY = newSize.height / ciImage.extent.height
                let scale = min(scaleX, scaleY)

                let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

                // Phase 0 修正: CIContext 毎回生成 → CIContextPool.shared を使用
                let pool = CIContextPool.shared
                guard let outputCGImage = pool.ciContext.createCGImage(scaled, from: scaled.extent) else {
                    continuation.resume(returning: image)
                    return
                }

                let resizedImage = UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
                continuation.resume(returning: resizedImage)
            }
        }
    }
}

// MARK: - 投稿画像の一括削除ヘルパー

extension StorageServiceProtocol {
    /// 投稿に関連する全画像を並列削除（ベストエフォート）。
    ///
    /// 🔧 2026-04-24 修正 (ultrareview bug_002):
    /// 旧実装は `users/{userId}/posts/{postId}/{filename}` という、アップロード時と
    /// 完全に乖離したパスを組み立てて削除していたため、投稿削除後も画像が Storage に
    /// 残り続けていた (try? await により失敗は握り潰されユーザーには気付かれない)。
    ///
    /// 現行: `ImageInfo.storagePath` / `thumbnailStoragePath` を優先的に使用する。
    /// 旧データ互換のため、storagePath が nil の場合のみ Firebase Storage の
    /// download URL 形式 (`https://.../o/<encoded-path>?...`) から storage path を
    /// 抽出するフォールバック経路を用意する。
    func deletePostImages(_ post: Post) async {
        await withTaskGroup(of: Void.self) { group in
            for image in post.images {
                if let path = Self.resolveStoragePath(for: image) {
                    group.addTask { try? await self.deleteImage(path: path) }
                }
                if let thumbPath = Self.resolveThumbnailStoragePath(for: image) {
                    group.addTask { try? await self.deleteImage(path: thumbPath) }
                }
            }
            if let originals = post.originalImages {
                for image in originals {
                    if let path = Self.resolveStoragePath(for: image) {
                        group.addTask { try? await self.deleteImage(path: path) }
                    }
                }
            }
        }
    }

    /// ImageInfo から本体画像の削除パスを解決する。
    static func resolveStoragePath(for image: ImageInfo) -> String? {
        if let stored = image.storagePath, !stored.isEmpty {
            return stored
        }
        if let url = URL(string: image.url) {
            return storagePathFromDownloadURL(url)
        }
        return nil
    }

    /// ImageInfo からサムネイル画像の削除パスを解決する。
    static func resolveThumbnailStoragePath(for image: ImageInfo) -> String? {
        if let stored = image.thumbnailStoragePath, !stored.isEmpty {
            return stored
        }
        if let thumbnail = image.thumbnail, let url = URL(string: thumbnail) {
            return storagePathFromDownloadURL(url)
        }
        return nil
    }

    /// Firebase Storage download URL から storage パスを抽出する。
    ///
    /// 入力例: `https://firebasestorage.googleapis.com/v0/b/<bucket>/o/posts%2FuserId%2Fpublic%2Fid.jpg?alt=media&token=...`
    /// 出力例: `posts/userId/public/id.jpg`
    static func storagePathFromDownloadURL(_ url: URL) -> String? {
        let components = url.pathComponents
        // Firebase Storage の URL は `/v0/b/<bucket>/o/<encoded-path>` 形式。
        // パスコンポーネントは ["/", "v0", "b", "<bucket>", "o", "<encoded-path>"] となる。
        guard let objectIndex = components.firstIndex(of: "o"),
              objectIndex + 1 < components.count else {
            return nil
        }
        let encoded = components[objectIndex + 1]
        return encoded.removingPercentEncoding
    }
}

// MARK: - StorageServiceError

enum StorageServiceError: LocalizedError {
    case compressionFailed
    case imageTooLarge
    case uploadFailed(Error)
    case deleteFailed(Error)
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .compressionFailed:
            return "画像の圧縮に失敗しました"
        case .imageTooLarge:
            return "画像サイズが大きすぎます（最大5MB）"
        case .uploadFailed(let error):
            return "画像のアップロードに失敗しました: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "画像の削除に失敗しました: \(error.localizedDescription)"
        case .invalidPath:
            return "無効なパスです"
        }
    }
}
