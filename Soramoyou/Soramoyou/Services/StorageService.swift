//
//  StorageService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import UIKit
import FirebaseStorage
import Combine

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
            // 画像をJPEG形式で圧縮（品質85%）
            guard let imageData = image.jpegData(compressionQuality: 0.85) else {
                throw StorageServiceError.compressionFailed
            }

            // 画像サイズの検証（最大5MB）
            let maxSize: Int = 5 * 1024 * 1024 // 5MB
            if imageData.count > maxSize {
                throw StorageServiceError.imageTooLarge
            }

            // Storage参照を取得
            let storageRef = storage.reference().child(path)

            // メタデータを設定
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"

            // アップロード（async/await版）
            let uploadMetadata = try await storageRef.putDataAsync(imageData, metadata: metadata)

            // アップロード完了後、メタデータが存在することを確認
            guard uploadMetadata.path != nil else {
                throw StorageServiceError.uploadFailed(NSError(
                    domain: "com.soramoyou.storage",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Upload completed but metadata is invalid"]
                ))
            }

            // ダウンロードURLを取得（リトライ機構付き）
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
                // 少し待機してからダウンロードURLを取得
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: UInt64(attempt * 500_000_000)) // 0.5秒 * attempt
                }

                let downloadURL = try await storageRef.downloadURL()
                return downloadURL
            } catch {
                lastError = error
                print("⚠️ ダウンロードURL取得失敗 (試行\(attempt + 1)/\(maxRetries)): \(error.localizedDescription)")

                // 最後の試行でなければ続ける
                if attempt < maxRetries - 1 {
                    continue
                }
            }
        }

        // すべてのリトライが失敗した場合
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
            // サムネイルサイズにリサイズ（最大512x512）
            let thumbnailSize = CGSize(width: 512, height: 512)
            let thumbnailImage = try await resizeImageForThumbnail(image, targetSize: thumbnailSize)

            // サムネイルをJPEG形式で圧縮（品質80%）
            guard let thumbnailData = thumbnailImage.jpegData(compressionQuality: 0.80) else {
                throw StorageServiceError.compressionFailed
            }

            // Storage参照を取得（サムネイル用のパス）
            let storageRef = storage.reference().child(thumbnailPath)

            // メタデータを設定
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"

            // アップロード（async/await版）
            let uploadMetadata = try await storageRef.putDataAsync(thumbnailData, metadata: metadata)

            // アップロード完了後、メタデータが存在することを確認
            guard uploadMetadata.path != nil else {
                throw StorageServiceError.uploadFailed(NSError(
                    domain: "com.soramoyou.storage",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Thumbnail upload completed but metadata is invalid"]
                ))
            }

            // ダウンロードURLを取得（リトライ機構付き）
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
            // ストリームが終了（キャンセル含む）したときにクリーンアップ
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
        // 進捗を監視
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
        
        // 完了時にストリームを終了
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
        
        // エラー時にストリームを終了
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
    
    private func resizeImageForThumbnail(_ image: UIImage, targetSize: CGSize) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let size = image.size
                let aspectRatio = size.width / size.height
                
                var newSize: CGSize
                if size.width > size.height {
                    // 横長
                    if size.width > targetSize.width {
                        newSize = CGSize(width: targetSize.width, height: targetSize.width / aspectRatio)
                    } else {
                        newSize = size
                    }
                } else {
                    // 縦長または正方形
                    if size.height > targetSize.height {
                        newSize = CGSize(width: targetSize.height * aspectRatio, height: targetSize.height)
                    } else {
                        newSize = size
                    }
                }
                
                // CIContextベースのリサイズ（バックグラウンドスレッドセーフ）
                guard let cgImage = image.cgImage else {
                    continuation.resume(returning: image)
                    return
                }
                let ciImage = CIImage(cgImage: cgImage)
                let scaleX = newSize.width / ciImage.extent.width
                let scaleY = newSize.height / ciImage.extent.height
                let scale = min(scaleX, scaleY)

                let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let context = CIContext(options: [.useSoftwareRenderer: false])
                guard let outputCGImage = context.createCGImage(scaled, from: scaled.extent) else {
                    continuation.resume(returning: image)
                    return
                }

                let resizedImage = UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
                continuation.resume(returning: resizedImage)
            }
        }
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

