//  SkyStitcherTests.swift ⭐️  (SoramoyouTests, ホスト型なので @testable import で到達)
//
//  機能3 STEP0 の go/no-go ハーネス。
//  - OpenCV 未導入(SORAMOYOU_OPENCV 未定義)でも緑になる「.unavailable 契約」を検証。
//  - OpenCV 導入後は同じテストが自動的に「重なり45%の4枚→.ok+横長」本判定へ切り替わる。

import XCTest
import UIKit
@testable import Soramoyou

final class SkyStitcherTests: XCTestCase {

    /// 横長の「空＋特徴(雲/地平線)」ソース。のっぺり青空だけだと特徴ゼロで非決定的になるため模様を入れる。
    private func makeWideSkySource(width: Int = 2000, height: Int = 600) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat.preferred(); fmt.scale = 1; fmt.opaque = true
        let r = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt)
        return r.image { ctx in
            let cg = ctx.cgContext, cs = CGColorSpaceCreateDeviceRGB()
            let grad = CGGradient(colorsSpace: cs, colors: [
                UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).cgColor,
                UIColor(red: 0.95, green: 0.8, blue: 0.6, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: height), options: [])
            var seed: UInt64 = 42
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 33) / Double(1 << 31) }
            UIColor(white: 1, alpha: 0.85).setFill()
            for _ in 0..<40 {
                cg.fillEllipse(in: CGRect(x: rnd() * Double(width), y: rnd() * Double(height) * 0.7,
                                          width: 40 + rnd() * 120, height: 20 + rnd() * 50))
            }
            UIColor(white: 0.15, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: Double(height) * 0.82, width: Double(width), height: Double(height) * 0.18))
        }
    }

    /// ソースを45%重ねつつ4分割クロップ→ガイド撮影の4枚を模す（特徴が必ず一致する）。
    private func makeOverlappingTiles(from src: UIImage, count: Int = 4, overlap: Double = 0.45) -> [UIImage] {
        let W = src.size.width, H = src.size.height, cg = src.cgImage!
        let tileW = W / (Double(count) - (Double(count) - 1) * overlap)
        let step = tileW * (1 - overlap)
        var tiles: [UIImage] = []
        for i in 0..<count {
            let x = step * Double(i)
            if let c = cg.cropping(to: CGRect(x: x, y: 0, width: min(tileW, W - x), height: H)) {
                tiles.append(UIImage(cgImage: c, scale: 1, orientation: .up))
            }
        }
        return tiles
    }

    /// 【go/no-go 本判定】OpenCV 未導入でもこのテストは緑（unavailable契約）。導入で自動的に本判定へ。
    func testStitchAvailabilityContract() {
        let tiles = makeOverlappingTiles(from: makeWideSkySource())
        let result = SkyStitcher.stitch(tiles)
        #if SORAMOYOU_OPENCV
        XCTAssertEqual(result.status, .ok, "重なり45%の4枚が合成不可（go不成立）: \(result.status)")
        let pano = try? XCTUnwrap(result.image); XCTAssertNotNil(pano)
        if let pano {
            let ar = pano.size.width / pano.size.height
            let tileAR = tiles[0].size.width / tiles[0].size.height
            XCTAssertGreaterThan(ar, tileAR * 1.5, "合成結果が広角(横長)になっていない pano=\(ar) tile=\(tileAR)")
            XCTAssertGreaterThan(pano.size.width, tiles.map { $0.size.width }.max()! * 1.2, "1枚分に潰れている")
        }
        #else
        XCTAssertEqual(result.status, .unavailable)   // 未リンク環境: CI を止めない
        XCTAssertNil(result.image)
        #endif
    }

    /// 入力不足は OpenCV 有無に関わらず Swift 層で弾く（常に検証可能）。
    func testTooFewImagesReturnsNeedMore() {
        XCTAssertEqual(SkyStitcher.stitch([makeWideSkySource()]).status, .needMoreImages)
        XCTAssertEqual(SkyStitcher.stitch([]).status, .needMoreImages)
    }

    /// 撮り方→ワープ/クロップの対応（実写4枚の手元比較で確定した設定の固定）。
    /// pan=円筒(1)+内接矩形(1)、grid=球面(0)+許容70%(4)。変更時はここが落ちて気づける。
    func testStitchStyleTuningCodes() {
        XCTAssertEqual(SkyStitchStyle.pan.warperCode, 1)
        XCTAssertEqual(SkyStitchStyle.pan.cropCode, 1)
        XCTAssertEqual(SkyStitchStyle.grid.warperCode, 0)
        XCTAssertEqual(SkyStitchStyle.grid.cropCode, 4)
    }
}
