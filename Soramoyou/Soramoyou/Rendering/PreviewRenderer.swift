// ⭐️ PreviewRenderer.swift
// プレビュー・書き出しレンダラー（CGImageSource ダウンサンプリング対応）
//
//  PreviewRenderer.swift
//  Soramoyou
//

import CoreImage
import ImageIO
import UIKit

/// プレビューと書き出し処理を担うレンダラー
///
/// 設計原則:
/// - プレビュー: CGImageSource でダウンサンプリング → CIImage グラフ適用（高速）
/// - 書き出し: フル解像度で CIImage グラフ適用（高品質）
/// - EXIF 回転は CGImageSourceCreateThumbnailAtIndex で自動処理（`kCGImageSourceCreateThumbnailWithTransform: true`）
///
/// EditViewModel.normalizeImageOrientation の責務を担うため、
/// 将来的には EditViewModel の正規化処理をこのクラスに集約できる。
final class PreviewRenderer {

    // MARK: - 定数

    /// プレビュー最大ピクセルサイズ
    private static let previewMaxPixel: Int = 1000

    // MARK: - プレビューレンダリング（URL ベース）

    /// URL から画像をダウンサンプリングしてプレビューを生成する
    ///
    /// - Parameters:
    ///   - url: 元画像の URL
    ///   - recipe: 編集レシピ
    ///   - maxPixel: 最大ピクセルサイズ（デフォルト: 1000px）
    /// - Returns: プレビュー用 CGImage
    static func renderPreview(
        from url: URL,
        recipe: EditRecipe,
        maxPixel: Int = previewMaxPixel
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PreviewRendererError.sourceCreationFailed
        }

        let options: [CFString: Any] = [
            // ソース画像からサムネイルを生成
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixel,
            // EXIF の向き情報を適用（手動回転処理不要）
            kCGImageSourceCreateThumbnailWithTransform:   true
        ]

        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreviewRendererError.thumbnailCreationFailed
        }

        return try applyRecipe(recipe, to: CIImage(cgImage: thumb))
    }

    /// UIImage からプレビューを生成する（キャッシュ済み画像対応）
    ///
    /// - Parameters:
    ///   - image: 元画像
    ///   - recipe: 編集レシピ
    /// - Returns: プレビュー用 UIImage
    static func renderPreview(from image: UIImage, recipe: EditRecipe) throws -> UIImage {
        guard let cgImage = image.cgImage else {
            throw PreviewRendererError.invalidImage
        }

        // ダウンサンプリング
        let sourceImage = CIImage(cgImage: cgImage)
        let pool = CIContextPool.shared
        let maxPixel = CGFloat(previewMaxPixel)
        let extent = sourceImage.extent
        let scale = min(maxPixel / extent.width, maxPixel / extent.height, 1.0)

        let scaled: CIImage
        if scale < 1.0 {
            let scaleFilter = CIFilter.lanczosScaleTransform()
            scaleFilter.inputImage  = sourceImage
            scaleFilter.scale       = Float(scale)
            scaleFilter.aspectRatio = 1.0
            scaled = scaleFilter.outputImage ?? sourceImage
        } else {
            scaled = sourceImage
        }

        let outputGraph = FilterGraphBuilder.buildGraph(recipe: recipe, source: scaled)

        guard let outputCGImage = pool.ciContext.createCGImage(outputGraph, from: outputGraph.extent,
                                                               format: .RGBA8,
                                                               colorSpace: pool.outputColorSpace) else {
            throw PreviewRendererError.renderingFailed
        }

        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - 書き出しレンダリング（フル解像度）

    /// URL からフル解像度で書き出しレンダリングを行う
    ///
    /// - Parameters:
    ///   - url: 元画像の URL
    ///   - recipe: 編集レシピ
    /// - Returns: 書き出し用 CGImage
    static func renderExport(from url: URL, recipe: EditRecipe) throws -> CGImage {
        var options: [CIImageOption: Any] = [
            .applyOrientationProperty: true
        ]

        // iOS 18+ では HDR 展開を有効化
        if #available(iOS 18.0, *) {
            options[.expandToHDR] = true
        }

        guard let input = CIImage(contentsOf: url, options: options) else {
            throw PreviewRendererError.sourceCreationFailed
        }

        return try applyRecipe(recipe, to: input)
    }

    // MARK: - 共通処理

    /// CIImage にレシピを適用して CGImage を生成する
    private static func applyRecipe(_ recipe: EditRecipe, to image: CIImage) throws -> CGImage {
        let pool = CIContextPool.shared
        let outputGraph = FilterGraphBuilder.buildGraph(recipe: recipe, source: image)

        guard let cgImage = pool.ciContext.createCGImage(
            outputGraph,
            from: outputGraph.extent,
            format: .RGBA8,
            colorSpace: pool.outputColorSpace
        ) else {
            throw PreviewRendererError.renderingFailed
        }

        return cgImage
    }
}

// MARK: - エラー定義

enum PreviewRendererError: LocalizedError {
    case sourceCreationFailed
    case thumbnailCreationFailed
    case invalidImage
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .sourceCreationFailed:   return "画像ソースの生成に失敗しました"
        case .thumbnailCreationFailed: return "サムネイルの生成に失敗しました"
        case .invalidImage:           return "無効な画像です"
        case .renderingFailed:        return "レンダリングに失敗しました"
        }
    }
}
