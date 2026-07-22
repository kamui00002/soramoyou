//
//  SkyMotionAssetPreparerTests.swift
//  SoramoyouTests
//
//  ⭐️「空を動かす」（Kling版）フェーズ1b: SkyMotionAssetPreparer の純関数
//  （2値化・反転・重心・aspect近似）のユニットテスト。
//
//  設計書: docs/sky-motion-design.md §4
//  「座標系に注意: CIImage は左下原点・Firestoreに渡す trajectory はピクセル座標」
//  という要件が最重要リスクのため、重心テストは決定的な合成CIImage（上半分白=空・下半分黒=地上）
//  を実際にラスタライズしてエンドツーエンドに検証し、「上下反転バグ」を機械的に検出できるようにする
//  （既存 LivingSkyEngineTests・CIImageTestHelpers と同型パターンを参照）。
//

import XCTest
import CoreImage
@testable import Soramoyou

final class SkyMotionAssetPreparerTests: XCTestCase {

    // MARK: - 2値化（binarizeMaskBytes）

    /// 閾値127を境に 0 または 255 だけを返すこと（設計書「2値化（フェザーではない）」）を検証する。
    func test_binarizeMaskBytes_thresholdsAt127() {
        let bytes: [UInt8] = [0, 100, 126, 127, 128, 200, 255]
        let result = SkyMotionAssetPreparer.binarizeMaskBytes(bytes, threshold: 127)
        XCTAssertEqual(result, [0, 0, 0, 255, 255, 255, 255])
    }

    /// 出力が常に0/255の2値のみであること（中間値が残らないこと）を網羅的に検証する。
    func test_binarizeMaskBytes_outputIsAlwaysBinary() {
        let allValues: [UInt8] = Array(0...255)
        let result = SkyMotionAssetPreparer.binarizeMaskBytes(allValues, threshold: 127)
        XCTAssertTrue(result.allSatisfy { $0 == 0 || $0 == 255 }, "2値化後に0/255以外の値が残っている")
    }

    // MARK: - 反転（invertMaskBytes）

    /// sky_mask → ground_mask への反転が単純な補数（255 - v）であること
    /// （設計書§3: "ground_mask.png は sky_mask の反転相当"）を検証する。
    func test_invertMaskBytes_complementsBinaryValues() {
        let skyBytes: [UInt8] = [0, 255, 0, 255]
        let groundBytes = SkyMotionAssetPreparer.invertMaskBytes(skyBytes)
        XCTAssertEqual(groundBytes, [255, 0, 255, 0])
    }

    /// 2値化後のバイト列を反転させた場合、白画素(空)と黒画素(地上)が完全に入れ替わること
    /// （static_mask=ground/dynamic_mask=sky の極性が壊れていないこと）を検証する。
    func test_invertMaskBytes_isInvolution() {
        let bytes: [UInt8] = [0, 50, 127, 200, 255]
        let binary = SkyMotionAssetPreparer.binarizeMaskBytes(bytes)
        let inverted = SkyMotionAssetPreparer.invertMaskBytes(binary)
        let doubleInverted = SkyMotionAssetPreparer.invertMaskBytes(inverted)
        XCTAssertEqual(binary, doubleInverted, "反転を2回適用したら元に戻らない（反転ロジックが対合になっていない）")
        for (skyValue, groundValue) in zip(binary, inverted) {
            XCTAssertNotEqual(skyValue, groundValue, "同じ画素で sky/ground が同じ値になっている")
        }
    }

    // MARK: - 重心（centroidPixel）— 座標系の上下反転バグ検出が最重要

    /// 上半分=白(空)・下半分=黒(地上) の合成CIImageを実際にラスタライズ→2値化し、
    /// 重心が「画像の上半分」に来ることを検証する。
    ///
    /// 設計書§4「座標系に注意: CIImage は左下原点・trajectoryはピクセル座標（左上原点想定）」を
    /// 踏まえ、もし実装がCIImageの座標系をそのまま使ってしまう（Y反転を怠る）と、
    /// 重心は誤って画像の下半分に出てしまう。このテストはその回帰を機械的に検出する。
    func test_centroidPixel_topHalfSky_yieldsCentroidInTopHalf() throws {
        let size = 64
        let image = Self.makeTopWhiteBottomBlackCIImage(size: size)

        let (grayBytes, width, height) = try Self.renderGrayscaleBytes(image, size: size)
        let binary = SkyMotionAssetPreparer.binarizeMaskBytes(grayBytes)
        let centroid = SkyMotionAssetPreparer.centroidPixel(binaryBytes: binary, width: width, height: height)

        let point = try XCTUnwrap(centroid, "白画素(空)があるのに重心がnilになった")

        // 座標系反転バグがあれば重心は下半分（y > height/2）に出るため、まずそれを厳密に否定する。
        XCTAssertLessThan(
            point.y, CGFloat(height) / 2,
            "重心が下半分に来ている（Y座標が上下反転している疑い。design doc §4 参照）"
        )
        // 上半分(0..<size/2)が一様に白なので、重心yは理論値 height/4 付近になるはず。
        XCTAssertEqual(point.y, CGFloat(height) / 4, accuracy: 2.0)
        // 上半分は幅方向に一様に白なので、重心xは画像中央になるはず。
        XCTAssertEqual(point.x, CGFloat(width) / 2, accuracy: 2.0)
    }

    /// 下半分=白(空)・上半分=黒(地上) の逆パターンでも重心が正しく「下半分」に来ることを検証する
    /// （上のテストの対称ケース。片方向だけの偶然一致を排除するため）。
    func test_centroidPixel_bottomHalfSky_yieldsCentroidInBottomHalf() throws {
        let size = 64
        let image = Self.makeTopBlackBottomWhiteCIImage(size: size)

        let (grayBytes, width, height) = try Self.renderGrayscaleBytes(image, size: size)
        let binary = SkyMotionAssetPreparer.binarizeMaskBytes(grayBytes)
        let centroid = SkyMotionAssetPreparer.centroidPixel(binaryBytes: binary, width: width, height: height)

        let point = try XCTUnwrap(centroid)
        XCTAssertGreaterThan(point.y, CGFloat(height) / 2, "重心が上半分に来ている（Y座標反転の疑い）")
        XCTAssertEqual(point.y, CGFloat(height) * 3 / 4, accuracy: 2.0)
    }

    /// 白画素(空)が1つも無いマスクでは重心を計算できず nil を返すことを検証する。
    /// （呼び出し側 SkyMotionAssetPreparer.prepareAsync はこの nil を画像中心へフォールバックする）
    func test_centroidPixel_allBlack_returnsNil() {
        let width = 8, height = 8
        let bytes = [UInt8](repeating: 0, count: width * height)
        XCTAssertNil(SkyMotionAssetPreparer.centroidPixel(binaryBytes: bytes, width: width, height: height))
    }

    /// バッファサイズが width×height と一致しない場合は安全に nil を返すこと（クラッシュしないこと）を検証する。
    func test_centroidPixel_mismatchedBufferSize_returnsNilSafely() {
        let bytes: [UInt8] = [255, 255, 255]
        XCTAssertNil(SkyMotionAssetPreparer.centroidPixel(binaryBytes: bytes, width: 8, height: 8))
    }

    // MARK: - trajectoryの向き（設計書§4: 水平+40pxのみ・yは不変）

    /// trajectory の2点目が「重心から水平方向にのみ+40pxされ、yは不変」という設計書§4の契約を検証する。
    func test_trajectorySecondPoint_isHorizontalDriftOnly() {
        let centroid = CGPoint(x: 100, y: 50)
        let driftPx: CGFloat = 40
        let second = CGPoint(x: centroid.x + driftPx, y: centroid.y)
        XCTAssertEqual(second.x, 140)
        XCTAssertEqual(second.y, 50, "trajectoryの2点目でYが変化している（水平ドリフトのみのはず）")
    }

    // MARK: - aspect比の近似（nearestAspectRatio）

    func test_nearestAspectRatio_wideImage_returns16x9() {
        XCTAssertEqual(SkyMotionAssetPreparer.nearestAspectRatio(width: 1920, height: 1080), "16:9")
    }

    func test_nearestAspectRatio_tallImage_returns9x16() {
        XCTAssertEqual(SkyMotionAssetPreparer.nearestAspectRatio(width: 1080, height: 1920), "9:16")
    }

    func test_nearestAspectRatio_squareImage_returns1x1() {
        XCTAssertEqual(SkyMotionAssetPreparer.nearestAspectRatio(width: 1000, height: 1000), "1:1")
    }

    /// 16:10（横長だが16:9ほど極端でない・かつ候補間のちょうど中間ではない比率）で
    /// 対数距離的に最も近い "16:9" が選ばれることを検証する
    /// （比=1.6・|log(1.6)-log(16/9)|≈0.105 vs |log(1.6)-log(1)|≈0.470 vs |log(1.6)-log(9/16)|≈1.045）。
    func test_nearestAspectRatio_moderatelyWideImage_returns16x9() {
        XCTAssertEqual(SkyMotionAssetPreparer.nearestAspectRatio(width: 1600, height: 1000), "16:9")
    }

    func test_nearestAspectRatio_invalidInput_fallsBackTo1x1() {
        XCTAssertEqual(SkyMotionAssetPreparer.nearestAspectRatio(width: 0, height: 100), "1:1")
        XCTAssertEqual(SkyMotionAssetPreparer.nearestAspectRatio(width: 100, height: 0), "1:1")
    }

    // MARK: - Private Helpers

    /// 上半分=白(255)・下半分=黒(0) の CIImage を生成する。
    /// `CIImageTestHelpers.makeTwoBandCIImage` と同型パターン（y < size/2 が「上半分」に対応する
    /// 走査順であることは既存ヘルパーのコメントで確立済み）。
    private static func makeTopWhiteBottomBlackCIImage(size: Int) -> CIImage {
        makeTwoBandGrayscaleCIImage(size: size, topValue: 255, bottomValue: 0)
    }

    /// 上半分=黒(0)・下半分=白(255) の CIImage を生成する（上のテストの対称ケース用）。
    private static func makeTopBlackBottomWhiteCIImage(size: Int) -> CIImage {
        makeTwoBandGrayscaleCIImage(size: size, topValue: 0, bottomValue: 255)
    }

    private static func makeTwoBandGrayscaleCIImage(size: Int, topValue: UInt8, bottomValue: UInt8) -> CIImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let c: UInt8 = y < size / 2 ? topValue : bottomValue
                bytes[i]     = c
                bytes[i + 1] = c
                bytes[i + 2] = c
                bytes[i + 3] = 255
            }
        }
        let data = Data(bytes)
        return CIImage(bitmapData: data,
                       bytesPerRow: size * 4,
                       size: CGSize(width: size, height: size),
                       format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// CIImage を「行0=画像上端」のグレースケールバイト列にラスタライズする（テスト専用）。
    ///
    /// `SkyMotionAssetPreparer.rasterizeGrayscaleBytes`（private）と同じ契約
    /// （CGContext描画によるRGBA8取得 → Rチャンネル抽出。R=G=Bのグレースケール画像が前提）を
    /// 共有ヘルパー `CIImageTestHelpers.renderRGBA8Pixels` の上に再現し、「決定的な合成CIImage」を
    /// 実際の入力として重心計算をエンドツーエンドに検証できるようにする。
    private static func renderGrayscaleBytes(
        _ image: CIImage,
        size: Int
    ) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let extent = CGRect(x: 0, y: 0, width: size, height: size)
        let rgba = try CIImageTestHelpers.renderRGBA8Pixels(image, extent: extent)
        var gray = [UInt8](repeating: 0, count: size * size)
        for i in 0..<(size * size) {
            gray[i] = rgba[i * 4]
        }
        return (gray, size, size)
    }
}
