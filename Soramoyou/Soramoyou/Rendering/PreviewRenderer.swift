// ⭐️ PreviewRenderer.swift
// プレビュー・書き出しレンダラー（CGImageSource ダウンサンプリング対応）
//
//  PreviewRenderer.swift
//  Soramoyou
//
// 🔧 Phase 0 修正 (2026-04-22):
//   - previewMaxPixel 1000 → 2400（電線ぶれ解消）
//   - applyRecipe を Preview(.RGBA8) / Export(CIImage) に分離
//   - renderExport の戻り値を CGImage → CIImage に変更
//     （呼び出し側で HEIF 書き出し時に CIImage のまま使用することで二重ラスタライズ回避）
//   - PNG 等の旧 CGImage 互換用に renderExportCGImage を追加（.RGBAh 高ビット深度）
//   - テスト可視化のため定数 / 内部ヘルパを internal に公開
//

import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

/// プレビューと書き出し処理を担うレンダラー
///
/// 設計原則:
/// - プレビュー: CGImageSource でダウンサンプリング → CIImage グラフ適用（高速、.RGBA8 / 8bpc）
/// - 書き出し: フル解像度で CIImage グラフ適用（高品質、CIImage のまま返却）
/// - EXIF 回転は CGImageSourceCreateThumbnailAtIndex で自動処理
final class PreviewRenderer {

    // MARK: - 定数

    /// プレビュー最大ピクセルサイズ
    ///
    /// iPhone Pro Max (1290pt × 3x = 3870px) に対して旧値 1000px は不足しており
    /// 電線などの細線でアップスケール劣化が目立つ。Retina + ピンチズーム余裕で 2400px に拡大。
    ///
    /// Phase0RegressionTests から参照するため internal 公開。
    static let previewMaxPixel: Int = 2400

    // MARK: - プレビューレンダリング（URL ベース）

    /// URL から画像をダウンサンプリングしてプレビューを生成する
    ///
    /// - Parameters:
    ///   - url: 元画像の URL
    ///   - recipe: 編集レシピ
    ///   - maxPixel: 最大ピクセルサイズ（デフォルト: `previewMaxPixel`）
    /// - Returns: プレビュー用 CGImage（8bpc / RGBA8）
    static func renderPreview(
        from url: URL,
        recipe: EditRecipe,
        maxPixel: Int = previewMaxPixel
    ) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PreviewRendererError.sourceCreationFailed
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize:          maxPixel,
            kCGImageSourceCreateThumbnailWithTransform:   true
        ]

        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PreviewRendererError.thumbnailCreationFailed
        }

        let graph = applyRecipeForPreview(recipe, to: CIImage(cgImage: thumb))
        let pool = CIContextPool.shared
        guard let cgImage = pool.ciContext.createCGImage(
            graph,
            from: graph.extent,
            format: .RGBA8,
            colorSpace: pool.outputColorSpace
        ) else {
            throw PreviewRendererError.renderingFailed
        }
        return cgImage
    }

    /// UIImage からプレビューを生成する（キャッシュ済み画像対応）
    static func renderPreview(from image: UIImage, recipe: EditRecipe) throws -> UIImage {
        guard let cgImage = image.cgImage else {
            throw PreviewRendererError.invalidImage
        }

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

        let graph = applyRecipeForPreview(recipe, to: scaled)

        // プレビュー表示用は .RGBA8 で十分（メモリ節約・描画速度優先）
        guard let outputCGImage = pool.ciContext.createCGImage(
            graph,
            from: graph.extent,
            format: .RGBA8,
            colorSpace: pool.outputColorSpace
        ) else {
            throw PreviewRendererError.renderingFailed
        }

        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - 書き出しレンダリング（フル解像度）

    /// URL からフル解像度で書き出しレンダリングを行う（CIImage 返却版）
    ///
    /// 🔧 Phase 0 修正: 戻り値を CGImage → CIImage に変更。
    /// HEIF/JPEG 書き出し時に中間 CGImage を介さず、CIImage のまま
    /// `writeHEIFRepresentation` / `writeJPEGRepresentation` に渡すことで
    /// 二重ラスタライズ（8bit 化 → 再エンコード）による画質低下を回避する。
    ///
    /// - Parameters:
    ///   - url: 元画像の URL
    ///   - recipe: 編集レシピ
    /// - Returns: 書き出し用 CIImage（遅延評価グラフ、実レンダは writeXxxRepresentation で実行される）
    static func renderExport(from url: URL, recipe: EditRecipe) throws -> CIImage {
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

        return applyRecipeForExport(recipe, to: input)
    }

    /// 書き出し用 CGImage 版（レガシー呼び出し互換、PNG 用途など）
    ///
    /// PNG 等で CGImage が必要な場合のみ使用。HEIF/JPEG は `renderExport(from:recipe:)` → CIImage 版を推奨。
    static func renderExportCGImage(from url: URL, recipe: EditRecipe) throws -> CGImage {
        let ciImage = try renderExport(from: url, recipe: recipe)
        let pool = CIContextPool.shared
        guard let cgImage = pool.ciContext.createCGImage(
            ciImage,
            from: ciImage.extent,
            format: .RGBAh,
            colorSpace: pool.outputColorSpace
        ) else {
            throw PreviewRendererError.renderingFailed
        }
        return cgImage
    }

    // MARK: - 共通処理

    /// プレビュー表示用のレシピ適用（CIImage グラフを返す）
    ///
    /// 呼び出し側で `.RGBA8` / `.RGBA16` 等を選んで `createCGImage` する。
    /// Phase0RegressionTests から参照するため internal 公開。
    static func applyRecipeForPreview(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        FilterGraphBuilder.buildGraph(recipe: recipe, source: image)
    }

    /// 書き出し用のレシピ適用（CIImage のまま返す → 二重ラスタライズ回避）
    ///
    /// Phase0RegressionTests から参照するため internal 公開。
    static func applyRecipeForExport(_ recipe: EditRecipe, to image: CIImage) -> CIImage {
        FilterGraphBuilder.buildGraph(recipe: recipe, source: image)
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
