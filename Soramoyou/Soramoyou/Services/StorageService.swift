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
            
            // アップロード
            let uploadTask = storageRef.putData(imageData, metadata: metadata)
            
            // 進捗を監視
            setupProgressObserver(for: uploadTask, path: path)
            
            // アップロード完了を待機
            _ = try await uploadTask
            
            // ダウンロードURLを取得
            let downloadURL = try await storageRef.downloadURL()
            
            // 進捗監視をクリーンアップ
            cleanupProgressObserver(for: path)
            
            return downloadURL
        } catch let error as StorageServiceError {
            cleanupProgressObserver(for: path)
            throw error
        } catch {
            cleanupProgressObserver(for: path)
            throw StorageServiceError.uploadFailed(error)
        }
    }
    
    // MARK: - Upload Thumbnail
    
    func uploadThumbnail(_ image: UIImage, path: String) async throws -> URL {
        do {
            // サムネイルサイズにリサイズ（最大512x512）
            let thumbnailSize = CGSize(width: 512, height: 512)
            let thumbnailImage = try await resizeImageForThumbnail(image, targetSize: thumbnailSize)
            
            // サムネイルをJPEG形式で圧縮（品質80%）
            guard let thumbnailData = thumbnailImage.jpegData(compressionQuality: 0.80) else {
                throw StorageServiceError.compressionFailed
            }
            
            // Storage参照を取得（サムネイル用のパス）
            let thumbnailPath = "thumbnails/\(path)"
            let storageRef = storage.reference().child(thumbnailPath)
            
            // メタデータを設定
            let metadata = StorageMetadata()
            metadata.contentType = "image/jpeg"
            
            // アップロード
            let uploadTask = storageRef.putData(thumbnailData, metadata: metadata)
            
            // 進捗を監視
            setupProgressObserver(for: uploadTask, path: thumbnailPath)
            
            // アップロード完了を待機
            _ = try await uploadTask
            
            // ダウンロードURLを取得
            let downloadURL = try await storageRef.downloadURL()
            
            // 進捗監視をクリーンアップ
            cleanupProgressObserver(for: thumbnailPath)
            
            return downloadURL
        } catch let error as StorageServiceError {
            cleanupProgressObserver(for: path)
            throw error
        } catch {
            cleanupProgressObserver(for: path)
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
                
                let renderer = UIGraphicsImageRenderer(size: newSize)
                let resizedImage = renderer.image { _ in
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                }
                
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

