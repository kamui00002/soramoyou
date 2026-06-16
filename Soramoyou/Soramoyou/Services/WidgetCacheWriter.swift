//
//  WidgetCacheWriter.swift
//  Soramoyou
//
//  本体アプリ側で、ウィジェット用のローカル画像キャッシュ（512px JPEG）と
//  インデックス（widget_index.json）を App Group へ書き出す。
//  ウィジェット拡張は *読むだけ*。本体だけがここを通って書く。
//
//  方針:
//    - 画像は長辺 512px に縮小し、Display P3 を保った JPEG で保存
//      （`UIImage.jpegData` ではなく `CIContext.jpegRepresentation`＝色がくすまない）。
//    - インデックスは postId で重複排除し、新しい順に最大 maxEntries 件だけ残す（Decision 2 = 50）。
//      溢れたエントリの画像ファイルは削除して孤児を残さない。
//    - インデックスは原子的に書く（`.atomic`＝temp へ書いてからリネーム）。
//    - コンテナ URL は **注入可能**。entitlement の無いテスト環境でも temp ディレクトリで検証できる。
//
//  ⚠️ このファイルは本体専用（`CIContextPool`=Metal に依存）。ウィジェット拡張には入れない。
//

import CoreImage
import Foundation
import ImageIO
import UIKit

/// ウィジェット用ローカルキャッシュを App Group に書き出す本体側ライター。
final class WidgetCacheWriter {

    enum WidgetCacheError: Error, Equatable {
        /// App Group コンテナが取得できない（entitlement 未付与など）。
        case containerUnavailable
        /// 画像の JPEG エンコードに失敗。
        case imageEncodingFailed
    }

    private let containerURL: URL?
    private let ciContext: CIContext
    private let outputColorSpace: CGColorSpace
    private let fileManager: FileManager
    /// インデックスに残す最大件数（新しい順）。Decision 2。
    let maxEntries: Int
    /// 縮小後の長辺ピクセル数。
    let maxPixelSize: CGFloat
    /// JPEG 圧縮品質（0...1）。
    let jpegQuality: Double

    init(
        containerURL: URL? = AppGroup.containerURL,
        ciContext: CIContext = CIContextPool.shared.ciContext,
        outputColorSpace: CGColorSpace = CIContextPool.shared.outputColorSpace,
        maxEntries: Int = 50,
        maxPixelSize: CGFloat = 512,
        jpegQuality: Double = 0.8,
        fileManager: FileManager = .default
    ) {
        self.containerURL = containerURL
        self.ciContext = ciContext
        self.outputColorSpace = outputColorSpace
        self.maxEntries = maxEntries
        self.maxPixelSize = maxPixelSize
        self.jpegQuality = jpegQuality
        self.fileManager = fileManager
    }

    // MARK: - 公開 API

    /// 1 投稿ぶんを書き出し、インデックスを更新して返す。
    @discardableResult
    func cache(
        image: UIImage,
        postId: String,
        timeOfDay: String?,
        skyColors: [String],
        createdAt: Date
    ) throws -> WidgetIndex {
        let imagesDir = try ensureImagesDirectory()
        let fileName = Self.imageFileName(for: postId)
        let jpeg = try downscaledJPEGData(from: image)
        let fileURL = imagesDir.appendingPathComponent(fileName, isDirectory: false)
        try jpeg.write(to: fileURL, options: .atomic)

        let entry = WidgetIndex.Entry(
            postId: postId,
            imageFileName: fileName,
            timeOfDay: timeOfDay,
            skyColors: skyColors,
            createdAt: createdAt
        )
        return try updateIndex { current in
            // 同じ postId の旧エントリを除き、新エントリを足す（重複排除）。
            var merged = current.filter { $0.postId != postId }
            merged.append(entry)
            return merged
        }
    }

    /// 既存インデックスを読む（無ければ `.empty`）。
    func loadIndex() -> WidgetIndex {
        guard let url = indexFileURL(),
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(WidgetIndex.self, from: data) else {
            return .empty
        }
        return index
    }

    /// 全キャッシュ（画像＋インデックス）を消す（ログアウト・退会時など）。
    func clear() throws {
        guard let container = containerURL else { throw WidgetCacheError.containerUnavailable }
        let imagesDir = container.appendingPathComponent(AppGroup.Path.imagesDirectory, isDirectory: true)
        if fileManager.fileExists(atPath: imagesDir.path) {
            try fileManager.removeItem(at: imagesDir)
        }
        let indexURL = container.appendingPathComponent(AppGroup.Path.indexFile, isDirectory: false)
        if fileManager.fileExists(atPath: indexURL.path) {
            try fileManager.removeItem(at: indexURL)
        }
    }

    // MARK: - インデックス更新（原子的）

    /// 現在のエントリ配列を受け取り新しい配列を返すクロージャで、インデックスを更新する。
    /// - 新しい順にソートし、`maxEntries` 件に切り詰め、溢れた画像ファイルは削除する（孤児防止）。
    @discardableResult
    private func updateIndex(_ transform: ([WidgetIndex.Entry]) -> [WidgetIndex.Entry]) throws -> WidgetIndex {
        guard let indexURL = indexFileURL(),
              let imagesDir = imagesDirectoryURL() else {
            throw WidgetCacheError.containerUnavailable
        }

        let updated = transform(loadIndex().entries)
        // 新しい順にソートし、上限で切り詰める。
        let sorted = updated.sorted { $0.createdAt > $1.createdAt }
        let kept = Array(sorted.prefix(maxEntries))

        // 切り詰めで外れたエントリの画像ファイルを削除（孤児防止）。
        let keptFileNames = Set(kept.map { $0.imageFileName })
        let droppedFileNames = Set(updated.map { $0.imageFileName }).subtracting(keptFileNames)
        for name in droppedFileNames {
            let url = imagesDir.appendingPathComponent(name, isDirectory: false)
            try? fileManager.removeItem(at: url)
        }

        let index = WidgetIndex(
            schemaVersion: WidgetIndex.currentSchemaVersion,
            updatedAt: Date(),
            entries: kept
        )
        let data = try JSONEncoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
        return index
    }

    // MARK: - 画像縮小（長辺 maxPixelSize・P3 JPEG）

    private func downscaledJPEGData(from image: UIImage) throws -> Data {
        guard let cgImage = image.cgImage else {
            throw WidgetCacheError.imageEncodingFailed
        }
        // UIImage の向きを EXIF 向きに反映してから縮小する（横倒れ防止）。
        var ciImage = CIImage(cgImage: cgImage)
            .oriented(Self.cgOrientation(from: image.imageOrientation))

        let longSide = max(ciImage.extent.width, ciImage.extent.height)
        if longSide > maxPixelSize {
            let scale = maxPixelSize / longSide
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality
        ]
        guard let data = ciContext.jpegRepresentation(
            of: ciImage,
            colorSpace: outputColorSpace,
            options: options
        ) else {
            throw WidgetCacheError.imageEncodingFailed
        }
        return data
    }

    // MARK: - パス解決（注入された containerURL 基準）

    private func imagesDirectoryURL() -> URL? {
        containerURL?.appendingPathComponent(AppGroup.Path.imagesDirectory, isDirectory: true)
    }

    private func indexFileURL() -> URL? {
        containerURL?.appendingPathComponent(AppGroup.Path.indexFile, isDirectory: false)
    }

    private func ensureImagesDirectory() throws -> URL {
        guard let dir = imagesDirectoryURL() else { throw WidgetCacheError.containerUnavailable }
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - ヘルパー

    /// postId からキャッシュ画像のファイル名を作る。postId は Firestore のドキュメント ID（英数）でファイル名に安全。
    static func imageFileName(for postId: String) -> String {
        "\(postId).jpg"
    }

    /// `UIImage.Orientation` を `CGImagePropertyOrientation` に変換する。
    static func cgOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
