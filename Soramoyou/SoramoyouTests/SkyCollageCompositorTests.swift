//
//  SkyCollageCompositorTests.swift
//  SoramoyouTests
//
//  ⭐️ 配置写真（v1）合成器のテスト。
//  4つの単色写真を並べ、各パネル中心の実ピクセルをサンプルして
//  「どの写真がどのパネルに来たか＝パネル順序と TopLeft→CI flip の正しさ」を担保する
//  （4枚配置は単一フレームより flip 誤りが起きやすい最大リスク）。
//

import XCTest
import CoreImage
import UIKit
@testable import Soramoyou

final class SkyCollageCompositorTests: XCTestCase {

    // MARK: - Helpers

    /// 単色 UIImage を生成（sRGB / .up）
    private func solidImage(r: UInt8, g: UInt8, b: UInt8, size: Int = 240) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
        }
        let ci = CIImage(
            bitmapData: Data(bytes), bytesPerRow: size * 4,
            size: CGSize(width: size, height: size), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        let cg = CIContext().createCGImage(ci, from: ci.extent)!
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    /// UIImage の相対座標(fx, fy ∈ 0...1)の RGB を返す。
    private func rgb(_ image: UIImage, fx: CGFloat, fy: CGFloat) -> (r: Int, g: Int, b: Int) {
        guard let cg = image.cgImage else { return (0, 0, 0) }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let x = min(max(Int(CGFloat(w) * fx), 0), w - 1)
        let y = min(max(Int(CGFloat(h) * fy), 0), h - 1)
        let i = (y * w + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    // MARK: - パネル順序 & flip（grid2x2）

    func testGrid2x2PlacesPhotosInReadingOrder() throws {
        // 赤=左上 / 緑=右上 / 青=左下 / 黄=右下 になるべき（左→右・上→下＝読み順）。
        let red = solidImage(r: 230, g: 20, b: 20)
        let green = solidImage(r: 20, g: 220, b: 20)
        let blue = solidImage(r: 20, g: 20, b: 230)
        let yellow = solidImage(r: 230, g: 220, b: 20)

        let out = try XCTUnwrap(SkyCollageCompositor.composeToUIImage(
            photos: [red, green, blue, yellow], labels: [], layout: .grid2x2))

        // 各パネル中心（ガターを避けた内側）をサンプル
        let tl = rgb(out, fx: 0.25, fy: 0.25)   // 左上
        let tr = rgb(out, fx: 0.74, fy: 0.25)   // 右上
        let bl = rgb(out, fx: 0.25, fy: 0.74)   // 左下
        let br = rgb(out, fx: 0.74, fy: 0.74)   // 右下

        XCTAssertTrue(tl.r > 150 && tl.g < 90 && tl.b < 90, "左上は赤のはず: \(tl)")
        XCTAssertTrue(tr.g > 150 && tr.r < 90 && tr.b < 90, "右上は緑のはず: \(tr)")
        XCTAssertTrue(bl.b > 150 && bl.r < 90 && bl.g < 90, "左下は青のはず: \(bl)")
        XCTAssertTrue(br.r > 150 && br.g > 150 && br.b < 90, "右下は黄のはず: \(br)")
    }

    func testVertical4StacksTopToBottom() throws {
        // 縦4分割: 赤→緑→青→黄 が上から順に並ぶ。
        let red = solidImage(r: 230, g: 20, b: 20)
        let green = solidImage(r: 20, g: 220, b: 20)
        let blue = solidImage(r: 20, g: 20, b: 230)
        let yellow = solidImage(r: 230, g: 220, b: 20)

        let out = try XCTUnwrap(SkyCollageCompositor.composeToUIImage(
            photos: [red, green, blue, yellow], labels: [], layout: .vertical4))

        // 縦長キャンバス。中央列(fx=0.5)で各行の中心をサンプル。
        let row0 = rgb(out, fx: 0.5, fy: 0.13)
        let row1 = rgb(out, fx: 0.5, fy: 0.38)
        let row2 = rgb(out, fx: 0.5, fy: 0.62)
        let row3 = rgb(out, fx: 0.5, fy: 0.87)

        XCTAssertTrue(row0.r > 150 && row0.b < 90, "1行目は赤のはず: \(row0)")
        XCTAssertTrue(row1.g > 150 && row1.r < 90, "2行目は緑のはず: \(row1)")
        XCTAssertTrue(row2.b > 150 && row2.r < 90, "3行目は青のはず: \(row2)")
        XCTAssertTrue(row3.r > 150 && row3.g > 150 && row3.b < 90, "4行目は黄のはず: \(row3)")
    }

    func testVerticalAndGridProduceDifferentCanvasAspect() throws {
        // grid2x2 はほぼ正方、vertical4 は縦長。アスペクトで構造差を担保。
        let imgs = (0..<4).map { _ in solidImage(r: 100, g: 100, b: 100) }
        let grid = try XCTUnwrap(SkyCollageCompositor.composeToUIImage(photos: imgs, labels: [], layout: .grid2x2))
        let vert = try XCTUnwrap(SkyCollageCompositor.composeToUIImage(photos: imgs, labels: [], layout: .vertical4))

        XCTAssertEqual(grid.size.width / grid.size.height, 1.0, accuracy: 0.05, "grid2x2 はほぼ正方")
        XCTAssertLessThan(vert.size.width, vert.size.height, "vertical4 は縦長")
    }

    func testLabelsAddBottomBandWithoutCoveringPhoto() throws {
        // ラベルありでも各パネルの写真中心の色は保たれる（ラベルは下帯＝写真の上に乗らない）。
        let red = solidImage(r: 230, g: 20, b: 20)
        let imgs = [red, red, red, red]
        let out = try XCTUnwrap(SkyCollageCompositor.composeToUIImage(
            photos: imgs, labels: ["朝", "昼", "夜", "雨"], layout: .grid2x2))
        // 左上パネルの写真中心（ラベル帯はセル下部なので中心より少し上をサンプル）
        let tl = rgb(out, fx: 0.25, fy: 0.20)
        XCTAssertTrue(tl.r > 150 && tl.g < 90, "ラベルありでも写真中心は赤のまま: \(tl)")
    }

    func testFewerThanFourPhotosDoesNotCrash() throws {
        // 2枚でも合成は成立する（端ケース）。空パネルは背景色。
        let imgs = [solidImage(r: 200, g: 50, b: 50), solidImage(r: 50, g: 200, b: 50)]
        let out = SkyCollageCompositor.composeToUIImage(photos: imgs, labels: [], layout: .grid2x2)
        XCTAssertNotNil(out, "2枚でも nil を返さない")
    }
}
