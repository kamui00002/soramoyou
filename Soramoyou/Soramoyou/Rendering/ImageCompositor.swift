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
import ImageIO

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
        /// 枠の形（色は mood、形は style）。キャプションの色/配置にも影響する。
        var style: FrameStyle

        init(base: CIImage, frameOverlay: CIImage? = nil, caption: String? = nil, mood: Mood? = nil, style: FrameStyle = .classic) {
            self.base = base
            self.frameOverlay = frameOverlay
            self.caption = caption
            self.mood = mood
            self.style = style
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
            if let textLayer = renderCaption(caption, mood: mood, style: input.style, in: canvas) {
                result = composite(textLayer, over: result)
            }
        }

        return result.cropped(to: canvas)
    }

    /// 1 枚の写真へ mood フレーム＋キャプションを焼き込み、向きを正規化した UIImage を返す。
    ///
    /// 投稿前焼き込みから 1 枚ずつ呼ぶ testable seam。一連の流れ:
    /// cgImage → `.oriented`(向き適用) → renderFrame → compose → `createCGImage`(Display P3) → UIImage(.up)。
    /// - cgImage は `UIImage.imageOrientation` を持たないため、合成前に CIImage 空間で向きを適用する。
    /// - 色空間は `CIContextPool.outputColorSpace`(Display P3) を明示し広色域/HDR を維持
    ///   （`UIImage(ciImage:)` / UIGraphicsImageRenderer 経由は広色域を落とすため使わない）。
    /// - 失敗時（cgImage 取得不可 / レンダ失敗）は入力画像をそのまま返す。
    static func composeToUIImage(base image: UIImage, mood: Mood?, caption: String?, style: FrameStyle = .classic) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let pool = CIContextPool.shared
        let oriented = CIImage(cgImage: cgImage)
            .oriented(CGImagePropertyOrientation(image.imageOrientation))
        let frameOverlay = mood.flatMap { renderFrame(mood: $0, style: style, in: oriented.extent) }
        let composed = compose(
            Input(base: oriented, frameOverlay: frameOverlay, caption: caption, mood: mood, style: style)
        )
        guard let outputCGImage = pool.ciContext.createCGImage(
            composed,
            from: composed.extent,
            format: .RGBAh,
            colorSpace: pool.outputColorSpace
        ) else {
            return image
        }
        // orientation 適用済みなので .up（既存 uploadImages→encodeJPEG の正規化と整合）。
        return UIImage(cgImage: outputCGImage)
    }

    // MARK: - キャプションのラスタライズ

    /// キャプションを透明背景にラスタライズして CIImage 化する。
    ///
    /// - Parameters:
    ///   - text: 表示文字列
    ///   - mood: 文字色・フォントデザイン・配置を決める気分
    ///   - extent: 合成先キャンバス（base の extent）
    /// - Returns: extent と同じ大きさ・原点のテキストレイヤ CIImage。失敗時 nil。
    static func renderCaption(_ text: String, mood: Mood, style: FrameStyle = .classic, in extent: CGRect) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else { return nil }

        let moodStyle = mood.style
        let width = extent.width
        let height = extent.height

        // フォントサイズは画像幅に比例（小さすぎを下限で防止）
        let fontSize = max(18, width * 0.045)
        let font = systemFont(ofSize: fontSize, design: moodStyle.fontDesign)
        // バンドは下の暗い帯に乗るため白文字。それ以外は mood の文字色。
        let textColor = (style == .bottomBand) ? UIColor.white : UIColor(moodStyle.captionColor)

        let isBand = (style == .bottomBand)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        // バンドは下帯内に収めるため末尾省略（長文・横長画像でのはみ出し防止）。それ以外は折り返し。
        paragraph.lineBreakMode = isBand ? .byTruncatingTail : .byWordWrapping

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

        // テキスト描画領域（左右に余白）。バンドは下帯(height*0.22)内に高さを制限してはみ出しを防ぐ。
        let horizontalInset = width * 0.08
        let textWidth = width - horizontalInset * 2
        let bandHeight = height * 0.22
        let maxTextHeight = isBand ? bandHeight * 0.72 : CGFloat.greatestFiniteMagnitude
        let bounding = attributed.boundingRect(
            with: CGSize(width: textWidth, height: maxTextHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let textHeight = min(ceil(bounding.height), maxTextHeight)

        // 縦位置（UIKit 座標系: 上が 0）。バンドは下帯の中央へ、それ以外は mood の配置。
        let verticalInset = height * 0.06
        let originY: CGFloat
        if isBand {
            // 下帯（上端 = height - bandHeight）の中で縦中央に収める
            originY = (height - bandHeight) + (bandHeight - textHeight) / 2
        } else {
            switch moodStyle.captionPlacement {
            case .top:    originY = verticalInset
            case .center: originY = (height - textHeight) / 2
            case .bottom: originY = height - textHeight - verticalInset
            }
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

    /// mood の色 × style の形でフレーム（透過PNG相当）を CIImage として生成する。
    ///
    /// 素材ファイルを使わず Core Graphics で描く。中心は透過で写真を主役のまま見せる。
    /// 透過レイヤは sRGB でラスタライズし（MoodStyle.palette は sRGB ガモット内）、
    /// `CISourceOverCompositing` で base に重ねても base の Display P3 ガモットをクランプしない。
    /// extent.size ちょうどで生成し、compose 内の `scaleToFill` が恒等変換になるようにする。
    /// - Returns: extent と同じ大きさ・原点のフレームレイヤ CIImage。失敗時 nil。
    static func renderFrame(mood: Mood, style: FrameStyle = .classic, in extent: CGRect) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else { return nil }
        switch style {
        case .classic:    return renderClassicFrame(mood: mood, in: extent)
        case .matte:      return renderMatteFrame(mood: mood, in: extent)
        case .bottomBand: return renderBottomBandFrame(mood: mood, in: extent)
        }
    }

    /// クラシック：mood 配色のグラデ枠＋白い額装線＋角アイコン（一目で分かる太さ）。
    private static func renderClassicFrame(mood: Mood, in extent: CGRect) -> CIImage? {
        let width = extent.width
        let height = extent.height
        let cgColors = mood.style.palette.map { UIColor($0).withAlphaComponent(1).cgColor }
        let primary = cgColors.first ?? UIColor.white.cgColor
        let border = max(24, width * 0.075)
        let corner = width * 0.035

        return rasterizeOverlay(extent: extent) { cg, full in
            let innerRect = full.insetBy(dx: border, dy: border)
            let innerCorner = max(0, corner - border * 0.5)

            // 縁グラデーション（外周をクリップ→内側をくり抜いて枠リングだけ塗る。中心は透過）
            let outer = UIBezierPath(roundedRect: full, cornerRadius: corner)
            let inner = UIBezierPath(roundedRect: innerRect, cornerRadius: innerCorner)
            cg.saveGState()
            outer.append(inner)
            cg.addPath(outer.cgPath)
            cg.clip(using: .evenOdd)
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let gradient = CGGradient(colorsSpace: space, colors: cgColors as CFArray, locations: nil) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
            } else {
                cg.setFillColor(primary)
                cg.fill(full)
            }
            cg.restoreGState()

            // 写真と枠の境目に白の額装線（空に馴染んで消えるのを防ぐ）
            let hairline = max(3, width * 0.005)
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(hairline)
            cg.addPath(UIBezierPath(roundedRect: innerRect, cornerRadius: innerCorner).cgPath)
            cg.strokePath()

            // 角アイコン（mood の SF Symbol を主色で左上に1つ）
            let glyphSize = width * 0.10
            let config = UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .semibold)
            if let symbol = UIImage(systemName: mood.iconName, withConfiguration: config)?
                .withTintColor(UIColor(cgColor: primary), renderingMode: .alwaysOriginal) {
                let pad = border * 0.6
                symbol.draw(in: CGRect(x: pad, y: pad, width: glyphSize, height: glyphSize), blendMode: .normal, alpha: 0.85)
            }
        }
    }

    /// マット：ギャラリー風の白い厚マット＋写真の縁に mood 色の細いアクセント線。
    private static func renderMatteFrame(mood: Mood, in extent: CGRect) -> CIImage? {
        let width = extent.width
        let primary = UIColor(mood.style.palette.first ?? .white)
        let border = max(28, width * 0.085)
        let corner = width * 0.015

        return rasterizeOverlay(extent: extent) { cg, full in
            let innerRect = full.insetBy(dx: border, dy: border)
            // 不透明な白マットをリング状に（中心は透過）
            let outer = UIBezierPath(roundedRect: full, cornerRadius: corner)
            let inner = UIBezierPath(roundedRect: innerRect, cornerRadius: max(0, corner))
            cg.saveGState()
            outer.append(inner)
            cg.addPath(outer.cgPath)
            cg.clip(using: .evenOdd)
            cg.setFillColor(UIColor(white: 0.98, alpha: 1).cgColor)
            cg.fill(full)
            cg.restoreGState()

            // 写真の縁に mood 色の細いアクセント線
            let accent = max(3, width * 0.006)
            cg.setStrokeColor(primary.withAlphaComponent(0.95).cgColor)
            cg.setLineWidth(accent)
            cg.addPath(UIBezierPath(roundedRect: innerRect, cornerRadius: max(0, corner)).cgPath)
            cg.strokePath()
        }
    }

    /// バンド：写真は広く見せ、下に mood 色を暗く落とした帯（キャプション主役のミニマル）。
    private static func renderBottomBandFrame(mood: Mood, in extent: CGRect) -> CIImage? {
        let width = extent.width
        let height = extent.height
        let primary = UIColor(mood.style.palette.first ?? .white).cgColor
        let bandHeight = height * 0.22

        return rasterizeOverlay(extent: extent) { cg, _ in
            // 下帯：透明 → mood 主色を暗く落とした濃色（文字の土台）
            let bandTopY = height - bandHeight
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: bandTopY, width: width, height: bandHeight))
            let top = UIColor(cgColor: primary).withAlphaComponent(0).cgColor
            let bottom = blend(primary, with: .black, t: 0.55, alpha: 0.88)
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bandTopY), end: CGPoint(x: 0, y: height), options: [])
            }
            cg.restoreGState()

            // 上辺に mood 色の細いライン（ミニマルでも mood が分かるアクセント）
            let line = max(4, width * 0.008)
            cg.setFillColor(primary)
            cg.fill(CGRect(x: 0, y: 0, width: width, height: line))
        }
    }

    /// 透過オーバーレイをラスタライズして CIImage 化する（extent 原点に合わせる）。
    private static func rasterizeOverlay(extent: CGRect, draw: (CGContext, CGRect) -> Void) -> CIImage? {
        let width = extent.width
        let height = extent.height
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let layer = renderer.image { context in
            draw(context.cgContext, CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cgLayer = layer.cgImage else { return nil }
        return CIImage(cgImage: cgLayer)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// 2 色を t(0...1) で線形補間し、指定アルファの CGColor を返す（帯の濃色作りに使用）。
    private static func blend(_ color: CGColor, with other: UIColor, t: CGFloat, alpha: CGFloat) -> CGColor {
        let c = UIColor(cgColor: color)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        c.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: alpha
        ).cgColor
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
