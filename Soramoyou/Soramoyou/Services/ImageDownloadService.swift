//
//  ImageDownloadService.swift
//  Soramoyou
//
//  画像ダウンロード・写真ライブラリ保存サービス

import UIKit
import Photos
import Kingfisher

// MARK: - エラー定義

enum ImageDownloadError: LocalizedError {
    case invalidURL
    case unsafeURL
    case downloadFailed
    case noImages
    case photoLibraryDenied
    case saveFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "画像のURLが無効です"
        case .unsafeURL:
            return "許可されていないURLスキームです"
        case .downloadFailed:
            return "画像のダウンロードに失敗しました"
        case .noImages:
            return "保存する画像がありません"
        case .photoLibraryDenied:
            return "写真ライブラリへのアクセスが許可されていません。設定アプリから許可してください。"
        case .saveFailed(let error):
            return "画像の保存に失敗しました: \(error.localizedDescription)"
        }
    }
}

// MARK: - プロトコル

protocol ImageDownloadServiceProtocol: Sendable {
    func downloadImage(from urlString: String) async throws -> UIImage
    func downloadImages(from urlStrings: [String]) async throws -> [UIImage]
    func downloadAndSaveImages(from urlStrings: [String]) async throws -> Int
    func saveToPhotoLibrary(_ image: UIImage) async throws
    func saveToPhotoLibrary(_ images: [UIImage]) async throws
    func checkPhotoLibraryPermission() async -> Bool
}

// MARK: - 実装

final class ImageDownloadService: ImageDownloadServiceProtocol, @unchecked Sendable {

    static let shared = ImageDownloadService()

    private init() {}

    private static let allowedSchemes: Set<String> = ["https", "http"]

    /// Kingfisher キャッシュから画像を取得（キャッシュミス時はダウンロード）
    func downloadImage(from urlString: String) async throws -> UIImage {
        guard let url = URL(string: urlString) else {
            throw ImageDownloadError.invalidURL
        }

        // セキュリティ: https/http のみ許可（file:// や data: を防止）
        guard let scheme = url.scheme?.lowercased(),
              Self.allowedSchemes.contains(scheme) else {
            throw ImageDownloadError.unsafeURL
        }

        // Kingfisher キャッシュを優先的に使用
        return try await withCheckedThrowingContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: url) { result in
                switch result {
                case .success(let imageResult):
                    continuation.resume(returning: imageResult.image)
                case .failure:
                    continuation.resume(throwing: ImageDownloadError.downloadFailed)
                }
            }
        }
    }

    /// 複数画像を逐次ダウンロードしてそれぞれ保存（メモリ対策: 1枚ずつ保存して解放）
    func downloadAndSaveImages(from urlStrings: [String]) async throws -> Int {
        guard !urlStrings.isEmpty else {
            throw ImageDownloadError.noImages
        }
        guard await checkPhotoLibraryPermission() else {
            throw ImageDownloadError.photoLibraryDenied
        }

        var savedCount = 0
        for urlString in urlStrings {
            let image = try await downloadImage(from: urlString)
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                savedCount += 1
            } catch {
                throw ImageDownloadError.saveFailed(error)
            }
        }
        return savedCount
    }

    /// 複数画像を逐次ダウンロード（メモリ対策）
    func downloadImages(from urlStrings: [String]) async throws -> [UIImage] {
        guard !urlStrings.isEmpty else {
            throw ImageDownloadError.noImages
        }
        var images: [UIImage] = []
        for urlString in urlStrings {
            let image = try await downloadImage(from: urlString)
            images.append(image)
        }
        return images
    }

    /// 写真ライブラリに1枚保存
    func saveToPhotoLibrary(_ image: UIImage) async throws {
        guard await checkPhotoLibraryPermission() else {
            throw ImageDownloadError.photoLibraryDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        } catch {
            throw ImageDownloadError.saveFailed(error)
        }
    }

    /// 写真ライブラリに複数枚保存
    func saveToPhotoLibrary(_ images: [UIImage]) async throws {
        guard !images.isEmpty else {
            throw ImageDownloadError.noImages
        }
        guard await checkPhotoLibraryPermission() else {
            throw ImageDownloadError.photoLibraryDenied
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                for image in images {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            }
        } catch {
            throw ImageDownloadError.saveFailed(error)
        }
    }

    /// 写真ライブラリへの書き込み権限をチェック（.addOnly で十分）
    func checkPhotoLibraryPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return newStatus == .authorized || newStatus == .limited
        default:
            return false
        }
    }
}
