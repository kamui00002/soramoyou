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
import FirebaseStorage
import Foundation
import os
import UIKit

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
            // Phase 0 修正: 0.85 → 0.95（投稿画質向上）
            guard let imageData = image.jpegData(compressionQuality: 0.95) else {
                throw StorageServiceError.compressionFailed
            }

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

            // サムネイル表示用: 0.80 維持（容量優先）
            guard let thumbnailData = thumbnailImage.jpegData(compressionQuality: 0.80) else {
                throw StorageServiceError.compressionFailed
            }

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
    /// 投稿に関連する全画像を並列削除（ベストエフォート・エラーは無視）
    func deletePostImages(_ post: Post) async {
        await withTaskGroup(of: Void.self) { group in
            for image in post.images {
                if let url = URL(string: image.url) {
                    let path = Self.storagePathFromURL(url, postId: post.id, userId: post.userId, isOriginal: false)
                    group.addTask { try? await self.deleteImage(path: path) }
                }
            }
            if let originals = post.originalImages {
                for image in originals {
                    if let url = URL(string: image.url) {
                        let path = Self.storagePathFromURL(url, postId: post.id, userId: post.userId, isOriginal: true)
                        group.addTask { try? await self.deleteImage(path: path) }
                    }
                }
            }
        }
    }

    /// Firebase Storage URL から削除パスを構築する
    static func storagePathFromURL(_ url: URL, postId: String, userId: String, isOriginal: Bool) -> String {
        let fileName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let subfolder = isOriginal ? "originals/" : ""
        return "users/\(userId)/posts/\(postId)/\(subfolder)\(fileName)"
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
