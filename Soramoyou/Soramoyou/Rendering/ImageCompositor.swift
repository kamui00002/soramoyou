// ⭐️ ImageCompositor.swift
// 写真 ＋ 気分フレーム（余白＋下プレート）＋ フレーム用コメント → 1 枚に合成
//
//  ImageCompositor.swift
//  Soramoyou
//
//  Created on 2026-06-08. Rewritten 2026-06-09（写真の上に縁を重ねる方式 →
//  写真の周囲に余白＋下プレートを足す「額縁/銘板」方式へ。コメントは写真ではなくプレートに焼く）。
//
//  機能1（気分フレーム＋フレーム用コメント）の合成基盤。
//
//  設計の要点:
//  - **写真は縮小・トリミングしない**。写真ピクセルはそのまま、その周囲にフレーム余白と
//    下の「プレート（コメント帯）」を足した、写真より大きいキャンバスを生成する。
//    （長辺が 2048 を超える分は呼び出し側の既存アップロード経路が一括縮小する＝1 回の再サンプル。）
//  - キャプションは写真の上ではなく **プレート（写真の外側の余白）** に描く。
//  - 既存の編集パイプラインは Display P3 + HDR を死守している
//    （`CIContextPool.outputColorSpace` / `writeJPEGRepresentation`）。本合成も
//    フレーム背景・文字は sRGB でラスタライズし `CISourceOverCompositing` で重ね、
//    写真は CIImage 空間のまま、最終 `createCGImage` は `.RGBAh` + outputColorSpace に委ねる。
//    そのため写真本体を `ImageRenderer` / `UIGraphicsImageRenderer` でラスタライズしない。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import SwiftUI
import ImageIO

/// 写真へ気分フレーム（余白＋下プレート）／フレーム用コメントを焼き込む合成器
enum ImageCompositor {

    // MARK: - 入力

    /// 合成入力
    struct Input {
        /// 編集確定済みの写真（フル解像度 CIImage・原点は問わない）
        var base: CIImage
        /// フレーム用コメント（任意・未入力可。未入力ならプレートを作らず余白のみ）
        var caption: String?
        /// 色・世界観を決める気分（nil の場合はフレームなし＝写真そのまま）
        var mood: Mood?
        /// 枠の形（色は mood、形は style）。余白量・プレート・文字色に影響する。
        var style: FrameStyle

        init(base: CIImage, caption: String? = nil, mood: Mood? = nil, style: FrameStyle = .classic) {
            self.base = base
            self.caption = caption
            self.mood = mood
            self.style = style
        }
    }

    // MARK: - レイアウト

    /// フレーム合成のレイアウト（すべて TopLeft 座標・px 基準で計算し、CI 描画時に上下反転）。
    private struct Layout {
        /// 出力キャンバス全体（写真＋余白＋プレート）
        var canvas: CGSize
        /// 写真の配置（TopLeft 座標）
        var photoRect: CGRect
        /// コメントを描くプレート領域（TopLeft 座標・コメント無し時は .null）
        var plateRect: CGRect
        /// プレート上のコメント文字色（背景に対しコントラストを確保した色）
        var captionColor: UIColor
    }

    /// style と写真サイズ・コメント有無からレイアウトを決める。
    ///
    /// - classic / matte: 上下左右に余白、写真の下にプレート（コメント時）。
    /// - bottomBand: 余白なし（写真は全幅）＋下に色プレート（バンド）。
    private static func layout(style: FrameStyle, photo: CGSize, hasCaption: Bool, mood: Mood) -> Layout {
        let pw = photo.width
        let ph = photo.height

        let side: CGFloat       // 左右・上の余白
        let plate: CGFloat      // 下プレート高（コメント領域）
        let bottom: CGFloat     // プレート下の余白
        let captionColor: UIColor

        switch style {
        case .classic:
            side = max(20, pw * 0.05)
            plate = hasCaption ? max(64, pw * 0.15) : 0
            bottom = side
            // グラデ枠（mood 主色）に対し、輝度で白/濃色を切替えてコントラスト確保
            captionColor = readableTextColor(on: UIColor(mood.style.palette.first ?? .white))
        case .matte:
            side = max(24, pw * 0.06)
            plate = hasCaption ? max(72, pw * 0.17) : 0
            bottom = side
            // ギャラリー銘板：白マットに濃い文字
            captionColor = UIColor(white: 0.12, alpha: 1)
        case .bottomBand:
            side = 0
            plate = hasCaption ? max(80, pw * 0.18) : pw * 0.07   // 帯はこのスタイルの個性なのでコメント無しでも薄く残す
            bottom = 0
            captionColor = .white                                  // 濃色帯に白文字
        }

        let top = (style == .bottomBand) ? 0 : side
        let cw = pw + side * 2
        let ch = top + ph + plate + bottom
        let photoRect = CGRect(x: side, y: top, width: pw, height: ph)
        let plateRect = plate > 0 ? CGRect(x: side, y: top + ph, width: pw, height: plate) : .null

        return Layout(canvas: CGSize(width: cw, height: ch),
                      photoRect: photoRect, plateRect: plateRect, captionColor: captionColor)
    }

    // MARK: - 合成

    /// base に気分フレーム（余白＋下プレート）とコメントを焼き込んだ CIImage を返す。
    ///
    /// - mood が nil の場合はフレームを作らず base をそのまま返す（passthrough）。
    /// - 出力 extent は **base より大きい**（写真＋余白＋プレート）。
    static func compose(_ input: Input) -> CIImage {
        guard let mood = input.mood else { return input.base }

        // base を原点 (0,0) に正規化（.oriented 後に origin がずれるケースに備える）
        let photo = input.base.transformed(
            by: CGAffineTransform(translationX: -input.base.extent.minX, y: -input.base.extent.minY)
        )
        let pw = photo.extent.width
        let ph = photo.extent.height
        guard pw > 0, ph > 0 else { return input.base }

        let trimmed = input.caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCaption = !(trimmed?.isEmpty ?? true)
        let lay = layout(style: input.style, photo: CGSize(width: pw, height: ph), hasCaption: hasCaption, mood: mood)
        let canvasRect = CGRect(origin: .zero, size: lay.canvas)

        // 1. フレーム背景（余白＋プレート塗り＋写真縁の線＋プレート上のコメント）を 1 枚にラスタライズ（sRGB）
        let frameLayer = renderFrameLayer(
            layout: lay, style: input.style, mood: mood,
            caption: hasCaption ? trimmed : nil, canvas: canvasRect
        )

        // 2. 写真をキャンバス内の所定位置へ平行移動（TopLeft→CI 反転）
        //    CI 原点は左下。写真上端を上から top に置くため CI 原点 y = ch - top - ph。
        let photoCIOriginY = lay.canvas.height - lay.photoRect.minY - ph
        let placedPhoto = photo.transformed(
            by: CGAffineTransform(translationX: lay.photoRect.minX, y: photoCIOriginY)
        )

        // 3. 写真（不透明）をフレーム背景の上に重ねる＝余白とプレートのみフレームが見える
        var result = placedPhoto
        if let frame = frameLayer {
            result = composite(placedPhoto, over: frame)
        }
        return result.cropped(to: canvasRect)
    }

    /// 1 枚の写真へ mood フレーム＋コメントを焼き込み、向きを正規化した UIImage を返す。
    ///
    /// 流れ: cgImage → `.oriented`(向き適用) → compose(余白＋プレート生成) → `createCGImage`(Display P3) → UIImage(.up)。
    /// - 失敗時（cgImage 取得不可 / レンダ失敗）は入力画像をそのまま返す。
    /// - `caption` は **フレーム用コメント**（通常の投稿キャプションとは別物）。
    static func composeToUIImage(base image: UIImage, mood: Mood?, caption: String?, style: FrameStyle = .classic) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let pool = CIContextPool.shared
        let oriented = CIImage(cgImage: cgImage)
            .oriented(CGImagePropertyOrientation(image.imageOrientation))
        let composed = compose(Input(base: oriented, caption: caption, mood: mood, style: style))
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

    // MARK: - フレームレイヤ（背景＋プレート＋縁＋コメント）

    /// フレーム関連の描画（余白塗り・プレート・写真縁の線・プレート上のコメント）を
    /// 1 枚の透過レイヤにまとめてラスタライズし CIImage 化する。
    ///
    /// 写真領域は「穴」（透明）にしておき、compose 側で不透明な写真を上に重ねる。
    /// プレートとコメントは写真の外側なので、写真を重ねても隠れない。
    private static func renderFrameLayer(layout lay: Layout, style: FrameStyle, mood: Mood,
                                         caption: String?, canvas: CGRect) -> CIImage? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let palette = mood.style.palette.map { UIColor($0).cgColor }
        let primary = UIColor(mood.style.palette.first ?? .white)

        return rasterizeOverlay(extent: canvas) { cg, full in
            // --- 背景（余白＋プレートの塗り）---
            switch style {
            case .classic:
                // キャンバス全体を mood グラデで塗る（写真は後で上に重なる＝余白とプレートだけ見える）
                fillGradient(cg, rect: full, colors: palette.isEmpty ? [primary.cgColor] : palette)
            case .matte:
                cg.setFillColor(UIColor(white: 0.98, alpha: 1).cgColor)
                cg.fill(full)
            case .bottomBand:
                // 写真領域＋上余白は透明のまま。下プレートのみ濃色帯。
                if !lay.plateRect.isNull {
                    let band = flip(lay.plateRect, in: full.height)   // TopLeft→CI
                    cg.saveGState()
                    cg.clip(to: band)
                    let top = primary.withAlphaComponent(0).cgColor
                    let bottom = blend(primary.cgColor, with: .black, t: 0.55, alpha: 0.9)
                    if let space = CGColorSpace(name: CGColorSpace.sRGB),
                       let grad = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
                        cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: band.maxY), end: CGPoint(x: 0, y: band.minY), options: [])
                    }
                    cg.restoreGState()
                    // 帯上辺に mood 色の細いライン
                    let line = max(4, full.width * 0.008)
                    cg.setFillColor(primary.cgColor)
                    cg.fill(CGRect(x: band.minX, y: band.maxY - line, width: band.width, height: line))
                }
            }

            // --- 写真の縁線（CI 座標で写真矩形の外周）---
            let photoCI = flip(lay.photoRect, in: full.height)
            switch style {
            case .classic:
                let hairline = max(3, full.width * 0.005)
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
                cg.setLineWidth(hairline)
                cg.stroke(photoCI.insetBy(dx: -hairline / 2, dy: -hairline / 2))
            case .matte:
                let accent = max(3, full.width * 0.006)
                cg.setStrokeColor(primary.withAlphaComponent(0.95).cgColor)
                cg.setLineWidth(accent)
                cg.stroke(photoCI.insetBy(dx: -accent / 2, dy: -accent / 2))
            case .bottomBand:
                break
            }

            // --- コメント（プレート内に描画）---
            if let caption, !lay.plateRect.isNull {
                drawCaption(caption, in: lay.plateRect, canvasHeight: full.height,
                            color: lay.captionColor, design: mood.style.fontDesign, cg: cg)
            }
        }
    }

    /// プレート矩形（TopLeft 座標）の中にコメントを中央寄せで描く。
    ///
    /// CGContext は rasterizeOverlay 内で TopLeft 座標系（UIGraphics）になっているため、
    /// plateRect（TopLeft）をそのまま使える。
    private static func drawCaption(_ text: String, in plateRectTL: CGRect, canvasHeight: CGFloat,
                                    color: UIColor, design: Font.Design, cg: CGContext) {
        let inset = plateRectTL.width * 0.06
        let textRect = plateRectTL.insetBy(dx: inset, dy: plateRectTL.height * 0.16)
        guard textRect.width > 0, textRect.height > 0 else { return }

        let fontSize = max(16, min(plateRectTL.height * 0.34, plateRectTL.width * 0.05))
        let font = systemFont(ofSize: fontSize, design: design)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail   // プレート内に収める（はみ出し防止）

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = fontSize * 0.12
        shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.03)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .shadow: shadow
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)

        // 高さは最大 2 行相当に制限し、プレート内で縦中央へ
        let maxH = min(textRect.height, fontSize * 2.6)
        let bounding = attributed.boundingRect(
            with: CGSize(width: textRect.width, height: maxH),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        let drawH = min(ceil(bounding.height), maxH)
        let drawRect = CGRect(x: textRect.minX,
                              y: plateRectTL.midY - drawH / 2,
                              width: textRect.width, height: drawH)
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    // MARK: - 描画ヘルパ

    /// TopLeft 座標の矩形を、高さ `h` のキャンバスの CI（左下原点）座標へ反転する。
    private static func flip(_ rectTL: CGRect, in h: CGFloat) -> CGRect {
        CGRect(x: rectTL.minX, y: h - rectTL.maxY, width: rectTL.width, height: rectTL.height)
    }

    /// 縦方向の線形グラデーションで rect を塗る（sRGB）。
    private static func fillGradient(_ cg: CGContext, rect: CGRect, colors: [CGColor]) {
        cg.saveGState()
        cg.clip(to: rect)
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) {
            cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        } else {
            cg.setFillColor(colors.first ?? UIColor.white.cgColor)
            cg.fill(rect)
        }
        cg.restoreGState()
    }

    /// 背景色の相対輝度から、可読な文字色（白 or 濃色）を選ぶ（コントラスト確保）。
    private static func readableTextColor(on background: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        background.getRed(&r, green: &g, blue: &b, alpha: &a)
        // sRGB 相対輝度（簡易）
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6 ? UIColor(white: 0.12, alpha: 1) : .white
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
