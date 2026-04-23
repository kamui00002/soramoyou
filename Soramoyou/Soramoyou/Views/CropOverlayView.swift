// ⭐️ CropOverlayView.swift
// 切り取り画面用のインタラクティブなクロップ矩形オーバーレイ
//
// 機能:
// - 4 隅のハンドルをドラッグで矩形をリサイズ
// - 矩形内をドラッグで全体を平行移動
// - 外側は半透明の黒マスクで暗く
// - 内部は「三分割グリッド」を表示（写真構図の補助線）
// - `aspectRatio` が指定されていればリサイズ時に比率を維持

import SwiftUI

/// クロップ領域を示すオーバーレイ View
///
/// - `cropRectNorm` は画像全体 (0.0〜1.0) を基準とした正規化矩形
/// - `imageRect` は画像が描画されているスクリーン座標の矩形
/// - ドラッグ終了時に `onEditEnd` を呼んで Undo 履歴や高品質プレビューを確定させる
struct CropOverlayView: View {

    /// 画像が実際に描画されているスクリーン上の矩形
    let imageRect: CGRect

    /// 正規化クロップ矩形（左上原点・0.0〜1.0）
    @Binding var cropRectNorm: CGRect

    /// アスペクト比制約（幅/高さ、nil のとき自由）
    let aspectRatio: CGFloat?

    /// ドラッグ終了コールバック（Undo 履歴 / 高品質プレビュー確定用）
    var onEditEnd: (() -> Void)? = nil

    /// ハンドルの描画サイズ
    private let handleSize: CGFloat = 22
    /// リサイズ中の最小矩形サイズ（画像に対する比率）
    private let minCropFraction: CGFloat = 0.15

    /// ドラッグ中の基準矩形（ジェスチャー開始時の正規化矩形）
    @State private var dragStartRect: CGRect? = nil

    var body: some View {
        // 正規化矩形 → スクリーン矩形
        let screen = CGRect(
            x: imageRect.origin.x + cropRectNorm.origin.x * imageRect.size.width,
            y: imageRect.origin.y + cropRectNorm.origin.y * imageRect.size.height,
            width:  cropRectNorm.size.width  * imageRect.size.width,
            height: cropRectNorm.size.height * imageRect.size.height
        )

        ZStack {
            // 画像の外側を暗く覆う（画像内のクロップ外も暗く）
            darkMask(imageRect: imageRect, cropScreen: screen)

            // クロップ矩形（白枠 + 三分割グリッド）
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: screen.width, height: screen.height)
                .position(x: screen.midX, y: screen.midY)
                .allowsHitTesting(false)

            gridLines(in: screen)

            // 中央の移動ジェスチャーゾーン
            Color.clear
                .frame(width: screen.width, height: screen.height)
                .contentShape(Rectangle())
                .position(x: screen.midX, y: screen.midY)
                .gesture(moveGesture)

            // 4 隅のリサイズハンドル
            ForEach(Corner.allCases, id: \.self) { corner in
                handleView()
                    .position(position(of: corner, in: screen))
                    .gesture(resizeGesture(for: corner))
            }
        }
    }

    // MARK: - Subviews

    /// クロップ外を暗くマスクする
    @ViewBuilder
    private func darkMask(imageRect: CGRect, cropScreen: CGRect) -> some View {
        Path { path in
            path.addRect(imageRect)
            path.addRect(cropScreen)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// 三分割グリッド（構図補助線）
    private func gridLines(in rect: CGRect) -> some View {
        Path { path in
            let w = rect.width / 3
            let h = rect.height / 3
            // 縦線 2 本
            path.move(to: CGPoint(x: rect.minX + w,     y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + w,     y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX + w * 2, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + w * 2, y: rect.maxY))
            // 横線 2 本
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + h))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 2))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 2))
        }
        .stroke(Color.white.opacity(0.4), lineWidth: 0.7)
        .allowsHitTesting(false)
    }

    /// 4 隅のハンドル見た目
    private func handleView() -> some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: handleSize - 8, height: handleSize - 8)
            Circle()
                .stroke(Color.black.opacity(0.4), lineWidth: 1)
                .frame(width: handleSize - 8, height: handleSize - 8)
        }
        .frame(width: handleSize, height: handleSize)
        .contentShape(Circle())
    }

    // MARK: - Gestures

    /// 矩形全体の移動
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRectNorm }
                guard let start = dragStartRect else { return }
                let dx = value.translation.width  / imageRect.size.width
                let dy = value.translation.height / imageRect.size.height
                var newX = start.origin.x + dx
                var newY = start.origin.y + dy
                newX = max(0, min(1 - start.size.width,  newX))
                newY = max(0, min(1 - start.size.height, newY))
                cropRectNorm = CGRect(
                    x: newX, y: newY,
                    width: start.size.width, height: start.size.height
                )
            }
            .onEnded { _ in
                dragStartRect = nil
                onEditEnd?()
            }
    }

    /// 4 隅でのリサイズ
    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartRect == nil { dragStartRect = cropRectNorm }
                guard let start = dragStartRect else { return }
                let dx = value.translation.width  / imageRect.size.width
                let dy = value.translation.height / imageRect.size.height

                var minX = start.origin.x
                var minY = start.origin.y
                var maxX = start.origin.x + start.size.width
                var maxY = start.origin.y + start.size.height

                switch corner {
                case .topLeft:
                    minX += dx
                    minY += dy
                case .topRight:
                    maxX += dx
                    minY += dy
                case .bottomLeft:
                    minX += dx
                    maxY += dy
                case .bottomRight:
                    maxX += dx
                    maxY += dy
                }

                // 最小サイズ保証
                if maxX - minX < minCropFraction {
                    if corner == .topLeft || corner == .bottomLeft {
                        minX = maxX - minCropFraction
                    } else {
                        maxX = minX + minCropFraction
                    }
                }
                if maxY - minY < minCropFraction {
                    if corner == .topLeft || corner == .topRight {
                        minY = maxY - minCropFraction
                    } else {
                        maxY = minY + minCropFraction
                    }
                }

                // 画像範囲内にクランプ
                minX = max(0, min(1, minX))
                minY = max(0, min(1, minY))
                maxX = max(0, min(1, maxX))
                maxY = max(0, min(1, maxY))

                var newRect = CGRect(
                    x: minX, y: minY,
                    width: max(minCropFraction, maxX - minX),
                    height: max(minCropFraction, maxY - minY)
                )

                // アスペクト比制約
                if let aspect = aspectRatio, let adjusted = applyAspect(rect: newRect, corner: corner, aspect: aspect) {
                    newRect = adjusted
                }

                cropRectNorm = newRect
            }
            .onEnded { _ in
                dragStartRect = nil
                onEditEnd?()
            }
    }

    /// アスペクト比を維持するよう矩形を補正
    ///
    /// 画像のピクセル比率を考慮しないと、正規化座標系での「見た目の比率」が
    /// 実際の画像の比率と一致しないため、ここでは `imageRect` のサイズ（実描画サイズ）を基に比率計算する。
    private func applyAspect(rect: CGRect, corner: Corner, aspect: CGFloat) -> CGRect? {
        // imageRect 座標（ピクセル近似）に変換してアスペクト比を判定
        let pixelW = rect.size.width  * imageRect.size.width
        let pixelH = rect.size.height * imageRect.size.height
        let currentAspect = pixelW / max(pixelH, 0.0001)
        guard abs(currentAspect - aspect) > 0.001 else { return rect }

        // 幅を基準に高さを合わせる or その逆
        var w = rect.size.width
        var h = rect.size.height
        // 正規化空間での目標比率
        let normAspect = aspect * (imageRect.size.height / imageRect.size.width)

        if pixelW / pixelH > aspect {
            // 横に伸びすぎ → 幅を詰める
            w = h * normAspect
        } else {
            h = w / normAspect
        }

        var x = rect.origin.x
        var y = rect.origin.y
        switch corner {
        case .topLeft:
            x = rect.maxX - w
            y = rect.maxY - h
        case .topRight:
            y = rect.maxY - h
        case .bottomLeft:
            x = rect.maxX - w
        case .bottomRight:
            break
        }

        // 画像範囲内にクランプ
        if x < 0 { x = 0 }
        if y < 0 { y = 0 }
        if x + w > 1 { w = 1 - x }
        if y + h > 1 { h = 1 - y }
        // w/h 再調整（クランプで比率崩れた場合）
        if pixelW / pixelH > aspect {
            w = h * normAspect
        } else {
            h = w / normAspect
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 4 隅の識別
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// 画面座標系でのハンドル位置
    private func position(of corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}
