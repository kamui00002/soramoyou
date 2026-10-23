//
//  ImageDownloadService.swift
//  Soramoyou
//
//  画像ダウンロード・写真ライブラリ保存サービス

import Kingfisher
import Photos
import UIKit

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
            "画像のURLが無効です"
        case .unsafeURL:
            "許可されていないURLスキームです"
        case .downloadFailed:
            "画像のダウンロードに失敗しました"
        case .noImages:
            "保存する画像がありません"
        case .photoLibraryDenied:
            "写真ライブラリへのアクセスが許可されていません。設定アプリから許可してください。"
        case let .saveFailed(error):
            "画像の保存に失敗しました: \(error.localizedDescription)"
        }
    }
}

// MARK: - プロトコル

protocol ImageDownloadServiceProtocol: Sendable {
    func downloadImage(from urlString: String) async throws -> UIImage
    func downloadImages(from urlStrings: [String]) async throws -> [UIImage]
    func downloadAndSaveImages(from urlStrings: [String]) async throws -> Int
    // 投稿の画像を読み方（PostImageSource）から取る版（URL 側の C・C-2。公開以外は Storage のパスで読む）
    func downloadImage(from source: PostImageSource) async throws -> UIImage
    func downloadImages(from sources: [PostImageSource]) async throws -> [UIImage]
    func downloadAndSaveImages(from sources: [PostImageSource]) async throws -> Int
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
              Self.allowedSchemes.contains(scheme)
        else {
            throw ImageDownloadError.unsafeURL
        }

        // Kingfisher キャッシュを優先的に使用
        return try await withCheckedThrowingContinuation { continuation in
            KingfisherManager.shared.retrieveImage(with: url) { result in
                switch result {
                case let .success(imageResult):
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

    // MARK: - 投稿の画像（読み方から取る・URL 側の C・C-2）

    /// 投稿の画像を、読み方（`PostImageSource.resolve` の結果）から取得する
    ///
    /// - `.remote(URL)`：上の URL 版をそのまま使う（https/http の検査・標準のキャッシュ・鍵は URL の文字列＝今までと同じ）
    /// - `.storage(パス)`：ダウンロード URL を使わず、Storage のパスで取得する（毎回 Storage のルールを通る）。
    ///   専用のキャッシュ（`PostStorageImageCache`）にあればそれを使い、無ければ Storage から取って入れる
    /// - `.unavailable`：読みに行かず `invalidURL`（URL 版で URL が空のときと同じ「画像のURLが無効です」）
    /// - Parameter source: 画像の読み方
    /// - Returns: 画像
    func downloadImage(from source: PostImageSource) async throws -> UIImage {
        switch source {
        case let .remote(url):
            return try await downloadImage(from: url.absoluteString)
        case let .storage(path):
            let request = Self.storageRequest(for: path)
            do {
                return try await KingfisherManager.shared.retrieveImage(with: request.source, options: request.options).image
            } catch {
                // 権限の拒否（フォローを外された後など）・通信の失敗は、URL 版と同じ「画像のダウンロードに失敗しました」にまとめる
                throw ImageDownloadError.downloadFailed
            }
        case .unavailable:
            throw ImageDownloadError.invalidURL
        }
    }

    /// 複数の投稿の画像を逐次ダウンロードしてそれぞれ保存（URL 版と同じ流れ。読めない 1 枚があればそこで失敗する）
    func downloadAndSaveImages(from sources: [PostImageSource]) async throws -> Int {
        guard !sources.isEmpty else {
            throw ImageDownloadError.noImages
        }
        guard await checkPhotoLibraryPermission() else {
            throw ImageDownloadError.photoLibraryDenied
        }

        var savedCount = 0
        for source in sources {
            let image = try await downloadImage(from: source)
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

    /// 複数の投稿の画像を逐次ダウンロード（URL 版と同じ流れ。読めない 1 枚があればそこで失敗する）
    func downloadImages(from sources: [PostImageSource]) async throws -> [UIImage] {
        guard !sources.isEmpty else {
            throw ImageDownloadError.noImages
        }
        var images: [UIImage] = []
        for source in sources {
            let image = try await downloadImage(from: source)
            images.append(image)
        }
        return images
    }

    /// Storage のパスで読むときに Kingfisher に渡す、読み先と options
    ///
    /// - 読み先：`PostStorageImageProvider`（鍵はパスそのもの＝投稿詳細の `KFImage.post` で入れた分がそのまま使える）
    /// - options：専用のキャッシュ（`PostStorageImageCache.shared`）だけ。付け忘れると標準のキャッシュに入り、
    ///   サインアウトで消えない（取れた画像では見分けがつかないので、テストはこの値で確かめる）。
    ///   加工（processor）は付けない（付けると鍵が「パス@加工の識別子」になり、画面で入れた分と鍵がずれる）
    /// ⚠️ 同じ決まりが `KFImage.post`（PostKFImage.swift）にもある。片方を変えるときは両方を直す。
    /// - Parameter path: `PostImageSource.resolve` が返した `.storage(パス)` のパス
    /// - Returns: 読み先と options
    static func storageRequest(for path: String) -> (source: Source, options: KingfisherOptionsInfo) {
        (.provider(PostStorageImageProvider(storagePath: path)), [.targetCache(PostStorageImageCache.shared)])
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
