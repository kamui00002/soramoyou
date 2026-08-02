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

import CoreImage
@testable import Soramoyou
import XCTest

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
        let allValues: [UInt8] = Array(0 ... 255)
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

    // MARK: - trajectoryの向き（設計書§4: 水平ドリフトのみ・yは不変）

    /// trajectory の2点目が「重心から水平方向にのみドリフトし、yは不変」という設計書§4の契約を検証する。
    func test_trajectorySecondPoint_isHorizontalDriftOnly() {
        let centroid = CGPoint(x: 100, y: 50)
        let driftPx = SkyMotionAssetPreparer.driftPixels(imageWidth: 1000, ratio: 0.04)
        let second = CGPoint(x: centroid.x + driftPx, y: centroid.y)
        XCTAssertEqual(second.x, 140)
        XCTAssertEqual(second.y, 50, "trajectoryの2点目でYが変化している（水平ドリフトのみのはず）")
    }

    // MARK: - ドリフト量は画像幅比（2026-07-28 実機FB「横写真だけ雲が動いて見えない」の回帰防止）

    /// ドリフト量が**画像幅に比例**すること。絶対px固定に戻すと、長辺1920縮小によって
    /// 横写真(幅1920)と縦写真(幅1440)で相対移動量が1.33倍ズレ、横写真だけ雲が止まって見える。
    func test_driftPixels_scalesWithImageWidth() {
        let ratio = SkyMotionPreset.driftWidthRatio
        let landscape = SkyMotionAssetPreparer.driftPixels(imageWidth: 1920, ratio: ratio)
        let portrait = SkyMotionAssetPreparer.driftPixels(imageWidth: 1440, ratio: ratio)

        XCTAssertGreaterThan(landscape, portrait, "幅の広い横写真ほどドリフトpxも大きくなるべき")
        // 幅比 1920:1440 = 4:3 がそのままドリフトpx比になる＝「画面に対する割合」が揃っている。
        XCTAssertEqual(landscape / portrait, 1920.0 / 1440.0, accuracy: 0.0001,
                       "ドリフトpxが画像幅に比例していない（絶対px固定に退行した疑い）")
    }

    /// 出力尺の見込み値が「動いて見える上限」を超えないことを検証する。
    ///
    /// ⚠️ 以前ここには「見かけ速度 = 幅比 ÷ 尺 が下限以上」という不変条件を置いていたが、
    ///    **同一写真での対照実験（2026-08-02）でこのモデルは否定された**:
    ///    ドリフトを44px→63pxに増やしても、尺が長い側（setpts2.3）は3.45倍遅いままだった。
    ///    速度を決めているのはサーバーの setpts 係数であり、client のドリフト比率ではない。
    ///    よって速度の回帰ガードは `functions/skyMotionCore.test.js` の
    ///    「スロー係数は全て上限以下」へ移した。ここでは尺の側だけを見る。
    ///
    /// 素材(Kling)は約5.1秒・出力 = setpts×5.1 − 1.0 なので、上限 setpts 1.8 に対応する
    /// 出力尺は約8.2秒。これを超える値が入っていたら setpts 側が上限を破っている疑いがある。
    func test_allPresetDurations_stayWithinPerceivableRange() {
        for preset in SkyMotionPreset.allCases {
            XCTAssertLessThanOrEqual(
                preset.approximateSeconds, 8.2,
                "\(preset.rawValue) の尺 \(preset.approximateSeconds)秒 は setpts 上限1.8を超えている"
                    + "（実測: setpts2.3=尺10.6秒 は実機NG「動いてない」）"
            )
        }
    }

    /// ラベルの「約N秒」表記が `approximateSeconds` と乖離していないことを検証する。
    /// 尺を変えたのに文言を直し忘れる（＝ユーザーに嘘の秒数を見せる）退行を防ぐ。
    func test_presetLabels_matchApproximateSeconds() {
        for preset in SkyMotionPreset.allCases {
            // ラベル例「速い（約5.5秒）」から数値部分を取り出す。
            let digits = preset.label.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .first(where: { !$0.isEmpty })
            let labeled = Double(digits ?? "")
            XCTAssertNotNil(labeled, "\(preset.rawValue) のラベルに秒数が含まれていない: \(preset.label)")
            XCTAssertEqual(
                labeled ?? 0, Double(preset.approximateSeconds), accuracy: 0.6,
                "\(preset.rawValue) のラベル「\(preset.label)」が実際の尺 \(preset.approximateSeconds)秒 と食い違う"
            )
        }
    }

    /// ドリフト比率が「Kling に無視される領域」に落ちていないことを検証する。
    ///
    /// 実測（同一写真・空の累積フロー %幅/秒）: 2.3%→0.120 / 4.0%→0.046 / 6.5%→0.264 と
    /// 6.5%以下は横並びでほぼ静止。10%で 2.1〜3.1 に跳ねる（`SkyMotionPreset` の表）。
    /// 下げる方向の変更は「雲が動かない」実機不具合に直結するのでここで止める。
    func test_driftRatio_isAboveIgnoredThreshold() {
        XCTAssertGreaterThanOrEqual(
            SkyMotionPreset.driftWidthRatio, 0.07,
            "ドリフト比率が Kling に無視される領域（幅6.5%以下）に入っている"
        )
    }

    /// ドリフト比率が実測で地上固定を確認できた上限を超えないことを検証する。
    /// 幅10%までは地上の移動0〜1pxを4本で確認済み。それ以上は未検証なので上げるなら実測すること。
    func test_driftRatio_staysWithinVerifiedCeiling() {
        XCTAssertLessThanOrEqual(
            SkyMotionPreset.driftWidthRatio, 0.10,
            "ドリフト比率が実測で地上固定を確認した範囲（幅10%）を超えている"
        )
    }

    /// 尺の序列（quick < standard < calm）が保たれていること。
    /// 3択の意味そのもの（「速い＝短い / ゆっくり＝長い」）がラベルと矛盾しないための契約。
    /// サーバーの setpts 係数を大きくするほど尺が伸び、同時に遅くなる（両者は分離できない）。
    func test_presetDurationOrdering_matchesLabels() {
        XCTAssertLessThan(SkyMotionPreset.quick.approximateSeconds,
                          SkyMotionPreset.standard.approximateSeconds,
                          "「速い」が「標準」より長い")
        XCTAssertLessThan(SkyMotionPreset.standard.approximateSeconds,
                          SkyMotionPreset.calm.approximateSeconds,
                          "「標準」が「ゆっくり」より長い")
    }

    /// `SkyMotionJob` の `loopDuration` 既定値が、実在するプリセットを指していること。
    /// 未知のキーになるとサーバーの `slowFactorForJob` がフォールバック値に落ち、
    /// ユーザーが選んだ尺と実際の尺が食い違う。
    func test_defaultLoopDuration_mapsToAnExistingPreset() {
        let job = SkyMotionJob(
            id: "test", userId: "u", sourcePath: "s", skyMaskPath: "k",
            groundMaskPath: "g", aspectRatio: "1:1", trajectory: []
        )
        XCTAssertNotNil(
            SkyMotionPreset.allCases.first { $0.loopDurationKey == job.loopDuration },
            "loopDuration の既定値 '\(job.loopDuration)' に対応するプリセットが無い"
        )
    }

    /// アセット準備側の既定ドリフトが、プリセット共通の値と一致していること。
    /// 二重定義になると片方だけ直して「無視される領域」に戻る事故が起きる。
    func test_preparerDefaultDrift_matchesPresetConstant() {
        XCTAssertEqual(SkyMotionAssetPreparer.driftWidthRatioDefault,
                       SkyMotionPreset.driftWidthRatio,
                       "ドリフト比率が2箇所で食い違っている")
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
        for y in 0 ..< size {
            for x in 0 ..< size {
                let i = (y * size + x) * 4
                let c: UInt8 = y < size / 2 ? topValue : bottomValue
                bytes[i] = c
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
        for i in 0 ..< (size * size) {
            gray[i] = rgba[i * 4]
        }
        return (gray, size, size)
    }
}
