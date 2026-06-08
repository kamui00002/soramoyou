// ⭐️ ImageCompositor.swift
// 写真 ＋ 気分フレーム（透過PNG）＋ 気持ちコメント → 1 枚に合成
//
//  ImageCompositor.swift
//  Soramoyou
//
//  Created on 2026-06-08.
//
//  機能1（気分フレーム＋気持ちコメント）の共通基盤(STEP 1)。
//
//  設計の要点:
//  - 既存の編集パイプラインは Display P3 + HDR を死守している
//    （`CIContextPool.outputColorSpace` / `writeJPEGRepresentation` を `UIImage.jpegData` より優先）。
//    本合成も色管理経路から外れないよう、**Core Image 空間で重ねた CIImage を返す**だけにし、
//    最終エンコード（createCGImage / writeJPEGRepresentation）は呼び出し側の既存経路に委ねる。
//    そのため `ImageRenderer` / `UIGraphicsImageRenderer` で写真本体をラスタライズしない。
//  - キャプションは透明背景にラスタライズして CIImage 化し、`CISourceOverCompositing` で重ねる
//    （文字レイヤは単色＋アルファなので色空間の影響は実用上小さい）。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import SwiftUI

/// 写真へ気分フレーム／キャプションを焼き込む合成器
///
/// 出力先は「投稿フローでの焼き込み」。編集確定済みの写真 CIImage を base に取り、
/// フレーム・テキストを重ねた CIImage を返す。エンコードは既存の Storage / Photo 経路が行う。
enum ImageCompositor {

    // MARK: - 入力

    /// 合成入力
    struct Input {
        /// 編集確定済みの写真（フル解像度 CIImage）
        var base: CIImage
        /// 気分フレームの透過PNG（任意）。base の領域いっぱいにスケールして重ねる。
        var frameOverlay: CIImage?
        /// 気持ちコメント（任意・未入力可）
        var caption: String?
        /// 文字スタイル決定用の気分（nil の場合は穏やかフォールバック）
        var mood: Mood?

        init(base: CIImage, frameOverlay: CIImage? = nil, caption: String? = nil, mood: Mood? = nil) {
            self.base = base
            self.frameOverlay = frameOverlay
            self.caption = caption
            self.mood = mood
        }
    }

    // MARK: - 合成

    /// base の上に frame と caption を焼き込んだ CIImage を返す。
    ///
    /// レイヤ順: 写真 → フレーム → キャプション（上が後）。
    /// - Returns: base.extent にクロップした合成済み CIImage。
    static func compose(_ input: Input) -> CIImage {
        let canvas = input.base.extent
        var result = input.base

        // 1. 気分フレーム（あれば）
        if let overlay = input.frameOverlay {
            let fitted = scaleToFill(overlay, target: canvas)
            result = composite(fitted, over: result)
        }

        // 2. 気持ちコメント（未入力ならスキップ＝フレームのみで成立）
        if let caption = input.caption,
           !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mood = input.mood ?? .calm
            if let textLayer = renderCaption(caption, mood: mood, in: canvas) {
                result = composite(textLayer, over: result)
            }
        }

        return result.cropped(to: canvas)
    }

    // MARK: - キャプションのラスタライズ

    /// キャプションを透明背景にラスタライズして CIImage 化する。
    ///
    /// - Parameters:
    ///   - text: 表示文字列
    ///   - mood: 文字色・フォントデザイン・配置を決める気分
    ///   - extent: 合成先キャンバス（base の extent）
    /// - Returns: extent と同じ大きさ・原点のテキストレイヤ CIImage。失敗時 nil。
    static func renderCaption(_ text: String, mood: Mood, in extent: CGRect) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else { return nil }

        let style = mood.style
        let width = extent.width
        let height = extent.height

        // フォントサイズは画像幅に比例（小さすぎを下限で防止）
        let fontSize = max(18, width * 0.045)
        let font = systemFont(ofSize: fontSize, design: style.fontDesign)
        let textColor = UIColor(style.captionColor)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        // 可読性確保のためのソフトシャドウ（空背景でも文字が沈まないように）
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = fontSize * 0.15
        shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.04)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
            .shadow: shadow
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)

        // テキスト描画領域（左右に余白）
        let horizontalInset = width * 0.08
        let textWidth = width - horizontalInset * 2
        let bounding = attributed.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textHeight = ceil(bounding.height)

        // 縦位置（UIKit 座標系: 上が 0）
        let verticalInset = height * 0.06
        let originY: CGFloat
        switch style.captionPlacement {
        case .top:    originY = verticalInset
        case .center: originY = (height - textHeight) / 2
        case .bottom: originY = height - textHeight - verticalInset
        }
        let drawRect = CGRect(x: horizontalInset, y: originY, width: textWidth, height: textHeight)

        // 透明背景にラスタライズ（scale=1: CIImage はピクセル基準）
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let layer = renderer.image { _ in
            attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }

        guard let cgLayer = layer.cgImage else { return nil }
        // base.extent の原点が (0,0) でないケースに備えて平行移動して位置を合わせる。
        return CIImage(cgImage: cgLayer)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    // MARK: - フレームのコード生成

    /// mood の世界観でフレーム（透過PNG相当）を CIImage として生成する。
    ///
    /// 素材ファイルを使わず Core Graphics で「縁だけ色帯＋角に装飾」を描く。中心は完全透過で
    /// 写真を主役のまま見せる。透過レイヤは sRGB でラスタライズし（MoodStyle.palette は
    /// `Color(red:green:blue:)`=sRGBガモット内なのでロスレス）、`CISourceOverCompositing` で
    /// base に重ねても base の Display P3 ガモットを一切クランプしない。
    ///
    /// extent.size ちょうどで生成することで、compose 内の `scaleToFill` が恒等変換になり歪まない。
    /// - Returns: extent と同じ大きさ・原点のフレームレイヤ CIImage。失敗時 nil。
    static func renderFrame(mood: Mood, in extent: CGRect) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else { return nil }

        let style = mood.style
        let width = extent.width
        let height = extent.height

        // palette を sRGB CGColor へ（先頭=主色）
        let cgColors = style.palette.map { UIColor($0).cgColor }
        let primary = cgColors.first ?? UIColor.white.cgColor

        // 枠太さ・角丸は画像幅比（v1 たたき台。感性チューニングは後で MoodStyle へ逃がす）
        let border = max(8, width * 0.045)
        let corner = width * 0.03

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)

        let layer = renderer.image { context in
            let cg = context.cgContext
            let full = CGRect(x: 0, y: 0, width: width, height: height)

            // (A) 縁グラデーション: 外周角丸をクリップ→内側角丸をくり抜いて「枠リング」だけ塗る。
            //     中心は完全透過のまま＝写真が見える（くり抜き忘れが最大の失敗モード）。
            let outer = UIBezierPath(roundedRect: full, cornerRadius: corner)
            let inner = UIBezierPath(
                roundedRect: full.insetBy(dx: border, dy: border),
                cornerRadius: max(0, corner - border * 0.5)
            )
            cg.saveGState()
            outer.append(inner)
            cg.addPath(outer.cgPath)
            cg.clip(using: .evenOdd)
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let gradient = CGGradient(colorsSpace: space, colors: cgColors as CFArray, locations: nil) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: height),
                    options: []
                )
            } else {
                cg.setFillColor(primary)
                cg.fill(full)
            }
            cg.restoreGState()

            // (B) 角の装飾: mood の SF Symbol を主色で薄く左上に1つだけ（過剰装飾を避ける）。
            let glyphSize = width * 0.09
            let config = UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .light)
            if let symbol = UIImage(systemName: mood.iconName, withConfiguration: config)?
                .withTintColor(UIColor(cgColor: primary), renderingMode: .alwaysOriginal) {
                let pad = border * 0.7
                symbol.draw(
                    in: CGRect(x: pad, y: pad, width: glyphSize, height: glyphSize),
                    blendMode: .normal,
                    alpha: 0.55
                )
            }
        }

        guard let cgLayer = layer.cgImage else { return nil }
        return CIImage(cgImage: cgLayer)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    // MARK: - 内部ヘルパ

    /// 上レイヤを下レイヤに source-over で重ねる
    private static func composite(_ top: CIImage, over bottom: CIImage) -> CIImage {
        let filter = CIFilter.sourceOverCompositing()
        filter.inputImage = top
        filter.backgroundImage = bottom
        return filter.outputImage ?? bottom
    }

    /// オーバーレイを target いっぱいに拡大・原点合わせする（フレームは全面想定のため塗り）
    private static func scaleToFill(_ image: CIImage, target: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scaleX = target.width / extent.width
        let scaleY = target.height / extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return scaled.transformed(by: CGAffineTransform(
            translationX: target.minX - scaled.extent.minX,
            y: target.minY - scaled.extent.minY
        ))
    }

    /// SwiftUI の Font.Design を UIFont（systemFont + デザイン）に橋渡しする
    private static func systemFont(ofSize size: CGFloat, design: Font.Design) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        let systemDesign: UIFontDescriptor.SystemDesign
        switch design {
        case .serif:      systemDesign = .serif
        case .rounded:    systemDesign = .rounded
        case .monospaced: systemDesign = .monospaced
        default:          systemDesign = .default
        }
        if let descriptor = base.fontDescriptor.withDesign(systemDesign) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}
