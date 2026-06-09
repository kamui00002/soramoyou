// ⭐️ SkyCollageCompositor.swift
// 配置写真（v1）— 4枚の空写真を「合成せず並べた」1枚に焼き込む
//
//  Created on 2026-06-10.
//
//  機能 v1「配置写真」: 朝/昼/夜/雨 など複数の空を 2×2 グリッド or 縦4分割で並べ、
//  任意の一言ラベルを添えて1枚の投稿画像にする。広角合成(v2/OpenCV)とは別物で、
//  ここでは「繋がず並べる」ため必ず成功する（特徴マッチ不要）。
//
//  設計の要点（ImageCompositor の方針を踏襲）:
//  - **写真は最後まで CIImage のまま**扱い、UIGraphics/ImageRenderer でラスタライズしない
//    （Display P3 + .RGBAh の広色域/HDR を壊さないため）。各パネルは CILanczosScaleTransform で
//    縮小し center-crop して配置、4枚を CISourceOverCompositing で重ねる。
//  - 背景・パネル境界線・ラベル文字だけ sRGB の透過オーバーレイにラスタライズして下に敷く
//    （装飾は sRGB で十分。写真領域はその上に重なる）。
//  - 最終 createCGImage は **CIContextPool**（Metal + Display P3 outputColorSpace + .RGBAh）に委譲。
//  - ImageCompositor は一切変更しない（検証済みの P3 死守コードへの回帰を避ける）。
//    そのため flip/rasterizeOverlay/composite/systemFont 相当の小ヘルパは本ファイルに複製する
//    （**この重複は意図的。後で「共通化」と称して触らないこと**）。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import SwiftUI

/// 複数の空写真を並べて1枚に焼き込む配置合成器（v1 配置写真）
enum SkyCollageCompositor {

    // MARK: - 入力

    struct Input {
        /// 並べる写真（向き適用済み・原点問わず）。grid2x2 / vertical4 ともに4枚想定（3枚以下も許容）。
        var photos: [CIImage]
        /// 各パネルの一言ラベル（photos と同 index。nil/空はラベルなし）
        var labels: [String?]
        /// 並べ方
        var layout: CollageLayout
        /// 余白・背景・文字色（v1 たたき台。意匠は後でチューニング可能）
        var gutterRatio: CGFloat
        var background: UIColor
        var labelColor: UIColor
        var fontDesign: Font.Design

        init(photos: [CIImage], labels: [String?] = [], layout: CollageLayout = .grid2x2,
             gutterRatio: CGFloat = 0.018,
             background: UIColor = UIColor(white: 0.98, alpha: 1),
             labelColor: UIColor = UIColor(white: 0.18, alpha: 1),
             fontDesign: Font.Design = .rounded) {
            self.photos = photos
            self.labels = labels
            self.layout = layout
            self.gutterRatio = gutterRatio
            self.background = background
            self.labelColor = labelColor
            self.fontDesign = fontDesign
        }
    }

    /// 出力キャンバスの長辺目安（ImagePickerService の 2048 cap と整合＝二重スケール回避）
    private static let canvasLongSide: CGFloat = 2048

    // MARK: - レイアウト

    /// 1パネル分の配置（すべて TopLeft 座標・px 基準）
    private struct Panel {
        var photoRect: CGRect   // 写真を収める矩形
        var labelRect: CGRect   // ラベル帯（ラベル無し時は .null）
    }

    /// レイアウトとラベル有無からキャンバスサイズと各パネル矩形を決める。
    /// 余白は `gutterRatio`（長辺比）で決まる＝Input.gutterRatio を実際に消費する。
    private static func makeLayout(_ layout: CollageLayout, hasAnyLabel: Bool,
                                   gutterRatio: CGFloat) -> (canvas: CGSize, panels: [Panel]) {
        let s = canvasLongSide
        switch layout {
        case .grid2x2:
            let canvas = CGSize(width: s, height: s)              // 正方
            let g = s * gutterRatio
            let cellW = (s - 3 * g) / 2
            let cellH = (s - 3 * g) / 2
            return (canvas, gridPanels(cols: 2, rows: 2, cellW: cellW, cellH: cellH, gutter: g, hasAnyLabel: hasAnyLabel))
        case .vertical4:
            let width = s * 0.5625                                 // 9:16 縦長
            let height = s
            let g = height * gutterRatio
            let cellW = width - 2 * g
            let cellH = (height - 5 * g) / 4
            return (CGSize(width: width, height: height),
                    gridPanels(cols: 1, rows: 4, cellW: cellW, cellH: cellH, gutter: g, hasAnyLabel: hasAnyLabel))
        }
    }

    /// cols×rows のセルを TopLeft 座標で並べ、各セルを写真矩形＋（必要なら）下部ラベル帯に割る。
    private static func gridPanels(cols: Int, rows: Int, cellW: CGFloat, cellH: CGFloat,
                                   gutter g: CGFloat, hasAnyLabel: Bool) -> [Panel] {
        let band = hasAnyLabel ? cellH * 0.18 : 0
        var panels: [Panel] = []
        for row in 0..<rows {
            for col in 0..<cols {
                let x = g + CGFloat(col) * (cellW + g)
                let y = g + CGFloat(row) * (cellH + g)
                let photoRect = CGRect(x: x, y: y, width: cellW, height: cellH - band)
                let labelRect = band > 0 ? CGRect(x: x, y: y + cellH - band, width: cellW, height: band) : .null
                panels.append(Panel(photoRect: photoRect, labelRect: labelRect))
            }
        }
        return panels
    }

    // MARK: - 合成

    /// 入力を配置合成した CIImage を返す（失敗時 nil）。
    static func compose(_ input: Input) -> CIImage? {
        let photos = Array(input.photos.prefix(4))
        guard !photos.isEmpty else { return nil }

        let labels = (0..<photos.count).map { i -> String? in
            guard i < input.labels.count else { return nil }
            let t = input.labels[i]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        let hasAnyLabel = labels.contains { $0 != nil }

        let (canvas, panels) = makeLayout(input.layout, hasAnyLabel: hasAnyLabel, gutterRatio: input.gutterRatio)
        let canvasRect = CGRect(origin: .zero, size: canvas)

        // 1. 背景＋境界線＋ラベルを 1 枚の sRGB オーバーレイにラスタライズ（写真はこの上に重なる）
        guard let overlay = renderBackgroundLayer(
            canvas: canvasRect, panels: panels, labels: labels,
            background: input.background, labelColor: input.labelColor, fontDesign: input.fontDesign
        ) else { return nil }

        // 2. 各写真を center-crop fill でパネルへ配置し、オーバーレイの上に source-over で重ねる
        var result = overlay
        for (i, panel) in panels.enumerated() where i < photos.count {
            autoreleasepool {
                if let placed = fittedPhoto(photos[i], into: panel.photoRect, canvasHeight: canvas.height) {
                    result = composite(placed, over: result)
                }
            }
        }
        return result.cropped(to: canvasRect)
    }

    /// 4枚の UIImage を配置合成し、向きを正規化した1枚の UIImage を返す（失敗時 nil）。
    /// ImageCompositor.composeToUIImage と同じ seam（cgImage→.oriented→compose→createCGImage(P3)→.up）。
    static func composeToUIImage(photos: [UIImage], labels: [String?], layout: CollageLayout) -> UIImage? {
        let ciPhotos: [CIImage] = photos.compactMap { img in
            guard let cg = img.cgImage else { return nil }
            return CIImage(cgImage: cg).oriented(CGImagePropertyOrientation(img.imageOrientation))
        }
        guard !ciPhotos.isEmpty else { return nil }

        let pool = CIContextPool.shared
        guard let composed = compose(Input(photos: ciPhotos, labels: labels, layout: layout)),
              let outCG = pool.ciContext.createCGImage(
                composed, from: composed.extent, format: .RGBAh, colorSpace: pool.outputColorSpace
              ) else {
            return nil
        }
        return UIImage(cgImage: outCG)
    }

    // MARK: - 背景レイヤ（背景塗り＋境界線＋ラベル）

    private static func renderBackgroundLayer(canvas: CGRect, panels: [Panel], labels: [String?],
                                              background: UIColor, labelColor: UIColor,
                                              fontDesign: Font.Design) -> CIImage? {
        rasterizeOverlay(extent: canvas) { cg, full in
            // 全面を背景色で塗る（ガター＝写真の隙間に見える）
            cg.setFillColor(background.cgColor)
            cg.fill(full)

            for (i, panel) in panels.enumerated() {
                // 写真矩形のうっすらした縁（写真の上には重ならない＝矩形のすぐ外側に薄線）
                let photoCI = flip(panel.photoRect, in: full.height)
                cg.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
                cg.setLineWidth(max(2, full.width * 0.002))
                cg.stroke(photoCI)

                // ラベル帯＋文字（TopLeft 座標のまま描ける＝rasterizeOverlay は UIGraphics 座標系）
                if !panel.labelRect.isNull, i < labels.count, let text = labels[i] {
                    drawLabel(text, in: panel.labelRect, color: labelColor, design: fontDesign, cg: cg)
                }
            }
        }
    }

    /// ラベル帯の中央にラベルを描く（プレート方式＝写真の上には乗せない）。
    private static func drawLabel(_ text: String, in rectTL: CGRect, color: UIColor,
                                  design: Font.Design, cg: CGContext) {
        let inset = rectTL.width * 0.06
        let textRect = rectTL.insetBy(dx: inset, dy: rectTL.height * 0.18)
        guard textRect.width > 0, textRect.height > 0 else { return }

        let fontSize = max(20, min(rectTL.height * 0.5, rectTL.width * 0.09))
        let font = systemFont(ofSize: fontSize, design: design)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let bounding = attributed.boundingRect(
            with: CGSize(width: textRect.width, height: textRect.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        )
        let drawH = min(ceil(bounding.height), textRect.height)
        let drawRect = CGRect(x: textRect.minX, y: rectTL.midY - drawH / 2, width: textRect.width, height: drawH)
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }

    // MARK: - 写真配置（center-crop fill）

    /// 写真を panelRect に center-crop fill して、キャンバス内の所定位置（CI 座標）へ配置する。
    private static func fittedPhoto(_ photo: CIImage, into panelTL: CGRect, canvasHeight: CGFloat) -> CIImage? {
        // 原点 (0,0) に正規化
        let base = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.minX, y: -photo.extent.minY))
        let pw = base.extent.width, ph = base.extent.height
        guard pw > 0, ph > 0, panelTL.width > 0, panelTL.height > 0 else { return nil }

        let target = panelTL.size
        let scale = max(target.width / pw, target.height / ph)   // fill（短辺基準で埋める）

        // Lanczos で高品質縮小（aspectRatio=1 で等方）
        let scaler = CIFilter.lanczosScaleTransform()
        scaler.inputImage = base
        scaler.scale = Float(scale)
        scaler.aspectRatio = 1
        guard let scaled0 = scaler.outputImage else { return nil }
        // 出力原点が動くケースに備えて再正規化
        let scaled = scaled0.transformed(by: CGAffineTransform(translationX: -scaled0.extent.minX, y: -scaled0.extent.minY))
        let sw = scaled.extent.width, sh = scaled.extent.height

        // パネルの CI 矩形（TopLeft→CI 反転）
        let panelCI = flip(panelTL, in: canvasHeight)
        // スケール後の写真をパネル中央に合わせて平行移動
        let tx = panelCI.minX - (sw - panelCI.width) / 2
        let ty = panelCI.minY - (sh - panelCI.height) / 2
        let placed = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
        // パネル矩形でクリップ（ガターへ滲み出さない）
        return placed.cropped(to: panelCI)
    }

    // MARK: - 描画ヘルパ（ImageCompositor からの意図的な複製。共通化で触らないこと）

    /// TopLeft 座標の矩形を、高さ `h` のキャンバスの CI（左下原点）座標へ反転する。
    private static func flip(_ rectTL: CGRect, in h: CGFloat) -> CGRect {
        CGRect(x: rectTL.minX, y: h - rectTL.maxY, width: rectTL.width, height: rectTL.height)
    }

    /// 透過オーバーレイをラスタライズして CIImage 化する（sRGB・装飾用）。
    private static func rasterizeOverlay(extent: CGRect, draw: (CGContext, CGRect) -> Void) -> CIImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: extent.size, format: format)
        let layer = renderer.image { context in
            draw(context.cgContext, CGRect(origin: .zero, size: extent.size))
        }
        guard let cgLayer = layer.cgImage else { return nil }
        return CIImage(cgImage: cgLayer)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// 上レイヤを下レイヤに source-over で重ねる。
    private static func composite(_ top: CIImage, over bottom: CIImage) -> CIImage {
        let filter = CIFilter.sourceOverCompositing()
        filter.inputImage = top
        filter.backgroundImage = bottom
        return filter.outputImage ?? bottom
    }

    /// SwiftUI の Font.Design を UIFont（systemFont + デザイン）に橋渡しする。
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
