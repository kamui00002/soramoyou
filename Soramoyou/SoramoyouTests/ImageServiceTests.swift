//
//  ImageServiceTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//
// 🔧 2026-04-24 整理 (コードレビュー H1 対応):
//   - applyEditTool 系テスト 23 件は削除。ツール単位の係数検証は FilterGraphBuilderTests に
//     移管済みで、プレビューとテストが同じ経路を通るようになった。
//   - generatePreviewFromCIImage(_:edits:) / generatePreview(_:edits:) / applyEditSettings
//     系テストも併せて削除（EditRecipe 経路へ一本化）。
//

import XCTest
@testable import Soramoyou
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class ImageServiceTests: XCTestCase {
    var imageService: ImageService!

    override func setUp() {
        super.setUp()
        imageService = ImageService()
    }

    override func tearDown() {
        imageService = nil
        super.tearDown()
    }

    // MARK: - 基本機能

    func testImageServiceInitialization() {
        let service = ImageService()
        XCTAssertNotNil(service)
    }

    func testMetalBackedCIContext() {
        // デフォルトコンストラクタで Metal CIContext が使用される
        let service = ImageService()
        XCTAssertNotNil(service)
    }

    // MARK: - Resize / Compress

    func testResizeImage() async throws {
        let testImage = createTestImage(size: CGSize(width: 4000, height: 3000))
        let maxSize = CGSize(width: 2048, height: 2048)

        let resizedImage = try await imageService.resizeImage(testImage, maxSize: maxSize)

        XCTAssertLessThanOrEqual(resizedImage.size.width, 2048)
        XCTAssertLessThanOrEqual(resizedImage.size.height, 2048)
    }

    func testResizeImageMaxResolution() async throws {
        let testImage = createTestImage(size: CGSize(width: 4000, height: 3000))
        let maxSize = CGSize(width: 2048, height: 2048)

        let resizedImage = try await imageService.resizeImage(testImage, maxSize: maxSize)

        XCTAssertLessThanOrEqual(resizedImage.size.width, 2048)
        XCTAssertLessThanOrEqual(resizedImage.size.height, 2048)

        let originalAspectRatio = testImage.size.width / testImage.size.height
        let resizedAspectRatio = resizedImage.size.width / resizedImage.size.height
        XCTAssertEqual(originalAspectRatio, resizedAspectRatio, accuracy: 0.01)
    }

    func testCompressImage() async throws {
        let testImage = createTestImage(size: CGSize(width: 1000, height: 1000))
        let quality: CGFloat = 0.85

        let compressedData = try await imageService.compressImage(testImage, quality: quality)

        XCTAssertFalse(compressedData.isEmpty)
        XCTAssertTrue(compressedData.starts(with: [0xFF, 0xD8]))
    }

    func testCompressImageMaxSize() async throws {
        let testImage = createTestImage(size: CGSize(width: 4000, height: 4000))
        let quality: CGFloat = 0.85

        let compressedData = try await imageService.compressImage(testImage, quality: quality)

        XCTAssertFalse(compressedData.isEmpty)
        let maxSize: Int = 5 * 1024 * 1024
        XCTAssertLessThanOrEqual(compressedData.count, maxSize)
    }

    // MARK: - Filter

    func testApplyFilter() async throws {
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        let filter = FilterType.vintage

        let filteredImage = try await imageService.applyFilter(filter, to: testImage)

        XCTAssertNotNil(filteredImage)
        XCTAssertEqual(filteredImage.size, testImage.size)
    }

    // MARK: - EditRecipe 経路のプレビュー

    func testGeneratePreviewWithRecipe() async throws {
        let testImage = createTestImage(size: CGSize(width: 2000, height: 2000))
        var recipe = EditRecipe()
        recipe.brightnessCI = 0.1
        recipe.contrastCI = 1.2

        let previewImage = try await imageService.generatePreview(testImage, recipe: recipe)

        XCTAssertNotNil(previewImage)
        // プレビューはサムネイルサイズ（750x750以下）
        XCTAssertLessThanOrEqual(previewImage.size.width, 750)
        XCTAssertLessThanOrEqual(previewImage.size.height, 750)
    }

    func testApplyEditRecipe() async throws {
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        var recipe = EditRecipe()
        recipe.exposureEV = 0.5

        let edited = try await imageService.applyEditRecipe(recipe, to: testImage)

        XCTAssertNotNil(edited)
        XCTAssertEqual(edited.size, testImage.size)
    }

    func testGeneratePreviewFromCIImageWithRecipe() {
        let testImage = createTestImage(size: CGSize(width: 256, height: 256))
        guard let ciImage = CIImage(image: testImage) else {
            XCTFail("CIImage変換に失敗")
            return
        }
        var recipe = EditRecipe()
        recipe.brightnessCI = 0.2

        let preview = imageService.generatePreviewFromCIImage(ciImage, recipe: recipe)

        XCTAssertNotNil(preview)
    }

    // MARK: - CIImage リサイズ

    func testResizeCIImage() {
        let testImage = createTestImage(size: CGSize(width: 2000, height: 1500))
        guard let ciImage = CIImage(image: testImage) else {
            XCTFail("CIImage変換に失敗")
            return
        }
        let maxSize = CGSize(width: 256, height: 256)

        let resized = imageService.resizeCIImage(ciImage, maxSize: maxSize)

        XCTAssertLessThanOrEqual(resized.extent.width, 256)
        XCTAssertLessThanOrEqual(resized.extent.height, 256)
    }

    func testResizeCIImageNoResizeNeeded() {
        let ciImage = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let maxSize = CGSize(width: 256, height: 256)

        let resized = imageService.resizeCIImage(ciImage, maxSize: maxSize)

        XCTAssertEqual(resized.extent.width, ciImage.extent.width, accuracy: 1.0)
        XCTAssertEqual(resized.extent.height, ciImage.extent.height, accuracy: 1.0)
    }

    // MARK: - 画像解析

    func testExtractColors() async throws {
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        let maxCount = 5

        let colors = try await imageService.extractColors(testImage, maxCount: maxCount)

        XCTAssertFalse(colors.isEmpty)
        XCTAssertLessThanOrEqual(colors.count, maxCount)
        for color in colors {
            XCTAssertTrue(color.hasPrefix("#"))
            XCTAssertEqual(color.count, 7)
        }
    }

    func testCalculateColorTemperature() async throws {
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))

        let colorTemperature = try await imageService.calculateColorTemperature(testImage)

        XCTAssertGreaterThanOrEqual(colorTemperature, 2000)
        XCTAssertLessThanOrEqual(colorTemperature, 10000)
    }

    func testDetectSkyType() async throws {
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))

        let skyType = try await imageService.detectSkyType(testImage)

        XCTAssertTrue([SkyType.clear, .cloudy, .sunset, .sunrise, .storm].contains(skyType))
    }

    // MARK: - EXIF（元ファイルから読む）

    /// EXIF 辞書付きの JPEG を一時ファイルとして書き出す（`Phase0RegressionTests` の
    /// CGImageDestination 書き出しと同型）。`exif` が nil なら EXIF 無しで書く。
    /// バンドルに画像フィクスチャが無いため、テストごとに生成し teardown で削除する。
    private func makeJPEGFixture(exif: [CFString: Any]?) throws -> URL {
        let image = createTestImage(size: CGSize(width: 16, height: 16))
        let cgImage = try XCTUnwrap(image.cgImage, "cgImage 取得失敗")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif_fixture_\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let type = UTType.jpeg.identifier as CFString
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil),
            "JPEG CGImageDestination の生成に失敗"
        )
        var properties: [CFString: Any] = [:]
        if let exif {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "JPEG 書き出し失敗")
        return url
    }

    /// 端末ロケールに依らず Gregorian + 現在のタイムゾーンで期待日時を組み立てる
    private func localGregorianDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0))
    }

    /// DateTimeOriginal を持つ JPEG から撮影日時が読める。
    /// 旧 UIImage 版は再エンコードで EXIF が消えるため構造的に不可能だった（本番 12/12 件欠落）。
    func testExtractEXIFDataReadsDateTimeOriginalFromFile() throws {
        let url = try makeJPEGFixture(exif: [kCGImagePropertyExifDateTimeOriginal: "2026:03:15 07:30:00"])

        let exif = try imageService.extractEXIFData(fileURL: url)

        XCTAssertEqual(exif.capturedAt, localGregorianDate(year: 2026, month: 3, day: 15, hour: 7, minute: 30))
    }

    /// EXIF 無し（スクリーンショット相当）は throw せず capturedAt == nil
    func testExtractEXIFDataWithoutEXIFReturnsNilCapturedAt() throws {
        let url = try makeJPEGFixture(exif: nil)

        let exif = try imageService.extractEXIFData(fileURL: url)

        XCTAssertNil(exif.capturedAt)
    }

    /// 画像でないファイルは invalidImage を throw する
    func testExtractEXIFDataThrowsForNonImageFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not_image_\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try "this is not an image".write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try imageService.extractEXIFData(fileURL: url))
    }

    /// OffsetTimeOriginal（"+09:00"）があればそのオフセットで解釈する
    func testParseEXIFDateTimeWithOffset() {
        let date = ImageService.parseEXIFDateTime("2026:03:15 07:30:00", offset: "+09:00")

        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-03-14T22:30:00Z"))
    }

    /// 書式外は nil
    func testParseEXIFDateTimeInvalidFormatReturnsNil() {
        XCTAssertNil(ImageService.parseEXIFDateTime("2026-03-15 07:30:00", offset: nil))
        XCTAssertNil(ImageService.parseEXIFDateTime("", offset: nil))
    }

    /// "JST" のような ISO 形式でないオフセットは無視して TimeZone.current で解釈する
    func testParseEXIFDateTimeIgnoresNonISOOffset() {
        let withJST = ImageService.parseEXIFDateTime("2026:03:15 07:30:00", offset: "JST")

        XCTAssertEqual(withJST, ImageService.parseEXIFDateTime("2026:03:15 07:30:00", offset: nil))
        XCTAssertEqual(withJST, localGregorianDate(year: 2026, month: 3, day: 15, hour: 7, minute: 30))
    }

    // MARK: - EditSettings 値管理テスト（struct 単体テスト）

    /// EditSettings で全ツールの値をセット・取得できる
    func testEditSettingsAllToolsValueRoundTrip() {
        var settings = EditSettings()
        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        for tool in toolsToTest {
            settings.setValue(0.42, for: tool)
            let retrieved = settings.value(for: tool)
            XCTAssertEqual(retrieved, 0.42, "\(tool.displayName)の値ラウンドトリップに失敗")
        }
    }

    /// EditSettings で全ツールの nil リセットが動作する
    func testEditSettingsAllToolsReset() {
        var settings = EditSettings()
        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        for tool in toolsToTest {
            settings.setValue(0.5, for: tool)
        }
        for tool in toolsToTest {
            settings.setValue(nil, for: tool)
            XCTAssertNil(settings.value(for: tool), "\(tool.displayName)のリセットに失敗")
        }
    }

    /// EditSettings Firestore 変換
    func testEditSettingsFirestoreRoundTrip() {
        var settings = EditSettings()
        settings.tone = 0.3
        settings.brilliance = -0.5
        settings.blackPoint = 0.2
        settings.naturalSaturation = 0.8
        settings.tint = -0.1
        settings.colorTemperature = 0.6
        settings.whiteBalance = -0.3
        settings.texture = 0.4
        settings.clarity = 0.7
        settings.dehaze = 0.5
        settings.grain = 0.2
        settings.fade = 0.3
        settings.noiseReduction = 0.6
        settings.curves = -0.4
        settings.hsl = 0.1
        settings.lensCorrection = 0.3
        settings.doubleExposure = 0.5

        let data = settings.toFirestoreData()
        guard let restored = EditSettings(from: data) else {
            XCTFail("Firestoreデータからの復元に失敗")
            return
        }

        XCTAssertEqual(restored.tone ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(restored.brilliance ?? 0, -0.5, accuracy: 0.001)
        XCTAssertEqual(restored.blackPoint ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(restored.naturalSaturation ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(restored.tint ?? 0, -0.1, accuracy: 0.001)
        XCTAssertEqual(restored.colorTemperature ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(restored.whiteBalance ?? 0, -0.3, accuracy: 0.001)
        XCTAssertEqual(restored.texture ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(restored.clarity ?? 0, 0.7, accuracy: 0.001)
        XCTAssertEqual(restored.dehaze ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(restored.grain ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(restored.fade ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(restored.noiseReduction ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(restored.curves ?? 0, -0.4, accuracy: 0.001)
        XCTAssertEqual(restored.hsl ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(restored.lensCorrection ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(restored.doubleExposure ?? 0, 0.5, accuracy: 0.001)
    }

    // MARK: - 空領域からの色抽出（PR-B）

    /// 陽性対照: 上 40% が夕焼け・下 60% が青の画像。
    /// 画像全体で計算すると、面積の大きい青に引っ張られて「夕焼けなのに 6000K 超」になる
    /// （本番で観測された 9396K の再現）。
    func testSunsetOverBlueWholeImageTemperatureIsCool() async throws {
        let image = makeTwoBandUIImage(
            top: UIColor(red: 0.95, green: 0.55, blue: 0.30, alpha: 1),
            bottom: UIColor(red: 0.30, green: 0.45, blue: 0.85, alpha: 1),
            topFraction: 0.4
        )

        let unmasked = try await imageService.calculateColorTemperature(image)
        print("🧪 陽性対照 unmasked=\(unmasked)K")
        XCTAssertGreaterThan(unmasked, 6000, "画像全体の平均は下の青に引っ張られる")
    }

    /// 陽性対照（修正後）: 同じ画像でも、上 40% の空マスクを渡すと夕焼けの色温度（3500K 未満）になる。
    /// マスク無し（nil）は従来どおり画像全体の値（6000K 超）のまま。
    func testSunsetOverBlueSkyMaskedTemperatureIsWarm() async throws {
        let ciImage = try await analysisCIImage(from: makeTwoBandUIImage(
            top: UIColor(red: 0.95, green: 0.55, blue: 0.30, alpha: 1),
            bottom: UIColor(red: 0.30, green: 0.45, blue: 0.85, alpha: 1),
            topFraction: 0.4
        ))
        let mask = makeTopBandMask(extent: ciImage.extent, topFraction: 0.4)

        let masked = try await imageService.calculateColorTemperature(from: ciImage, skyMask: mask)
        let unmasked = try await imageService.calculateColorTemperature(from: ciImage, skyMask: nil)
        print("🧪 陽性対照 masked=\(masked)K unmasked=\(unmasked)K")

        XCTAssertLessThan(masked, 3500, "空（夕焼け）の部分だけから計算すれば暖色の色温度になる")
        XCTAssertGreaterThan(unmasked, 6000, "マスク無しは画像全体の値のまま")
    }

    /// 上=青空・下=茶色の地上。空マスク（上 50%）を渡すと主要色は全部青寄り（b > r）になる。
    /// マスク無しは地上の茶色（r > b）を含む。
    func testExtractColorsWithSkyMaskReturnsOnlySkyColors() async throws {
        let ciImage = try await analysisCIImage(from: makeBlueSkyOverGroundImage())
        let mask = makeTopBandMask(extent: ciImage.extent, topFraction: 0.5)

        let masked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: mask)
        let unmasked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: nil)

        XCTAssertFalse(masked.isEmpty)
        for hex in masked {
            let c = try XCTUnwrap(rgb(fromHex: hex))
            XCTAssertGreaterThan(c.b, c.r, "空マスクありの色 \(hex) は青寄りのはず（地上の色が混ざっていない）")
        }
        XCTAssertTrue(
            try unmasked.contains { try XCTUnwrap(rgb(fromHex: $0)).r > XCTUnwrap(rgb(fromHex: $0)).b },
            "マスク無しは地上の茶色を含む（対照）: \(unmasked)"
        )
    }

    /// 実物の `HeuristicSkyMaskProvider` を通しても、閾値を満たしたうえで空の色だけが取れる。
    func testExtractColorsWithHeuristicSkyMaskReturnsOnlySkyColors() async throws {
        let ciImage = try await analysisCIImage(from: makeBlueSkyOverGroundImage())
        let skyMask = try await HeuristicSkyMaskProvider(ciContext: CIContext()).makeSkyMask(for: ciImage, quality: .preview)

        XCTAssertGreaterThanOrEqual(skyMask.skyCoverage, 0.05, "青空が上半分にあるので被覆率の閾値を満たす")
        XCTAssertGreaterThanOrEqual(skyMask.confidence, 0.3, "2 色がはっきり分かれているので確信度の閾値を満たす")

        let colors = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: skyMask.mask)
        XCTAssertFalse(colors.isEmpty)
        for hex in colors {
            let c = try XCTUnwrap(rgb(fromHex: hex))
            XCTAssertGreaterThan(c.b, c.r, "実物のマスクでも色 \(hex) は青寄りのはず")
        }
    }

    /// 全黒マスク（空が無い）は空のセルが残らないので、マスク無しと同じ配列にフォールバックする。
    func testExtractColorsWithAllBlackMaskFallsBackToWholeImage() async throws {
        let ciImage = try await analysisCIImage(from: makeBlueSkyOverGroundImage())
        let blackMask = CIImage(color: CIColor.black).cropped(to: ciImage.extent)

        let masked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: blackMask)
        let unmasked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: nil)
        XCTAssertEqual(masked, unmasked)

        let maskedTemperature = try await imageService.calculateColorTemperature(from: ciImage, skyMask: blackMask)
        let unmaskedTemperature = try await imageService.calculateColorTemperature(from: ciImage, skyMask: nil)
        XCTAssertEqual(maskedTemperature, unmaskedTemperature)
    }

    /// 単色の青に全白マスク（全部が空）を渡すと、マスク無しと同じ配列になる（加重平均が縁で暗くならない）。
    func testExtractColorsWithAllWhiteMaskOnSolidImageMatchesWholeImage() async throws {
        let ciImage = try await analysisCIImage(from: createTestImage(size: CGSize(width: 256, height: 256)))
        let whiteMask = CIImage(color: CIColor.white).cropped(to: ciImage.extent)

        let masked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: whiteMask)
        let unmasked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: nil)
        XCTAssertEqual(masked, unmasked)
    }

    /// 中間値のマスク（本物の provider と同じく DeviceGray・色管理なし `NSNull` で作る）。
    /// 上 40% の値が 0.15 なので、どのセルもマスク平均が `skyCellMinMaskMean`(0.2) 未満＝空セル 0 で、
    /// マスク無しと同じ配列にフォールバックしなければならない。
    /// ⚠️ 0/1 の二値マスクは sRGB ガンマの不動点なので、マスク値にガンマがかかる不具合を検出できない
    ///    （0.15 がガンマで約 0.42 に化けるとセルが採用され、夕焼けの帯の色だけが返って失敗する）。
    func testExtractColorsWithIntermediateMaskValueBelowCellThresholdFallsBackToWholeImage() async throws {
        let ciImage = try await analysisCIImage(from: makeTwoBandUIImage(
            top: UIColor(red: 0.95, green: 0.55, blue: 0.30, alpha: 1),
            bottom: UIColor(red: 0.30, green: 0.45, blue: 0.85, alpha: 1),
            topFraction: 0.4
        ))
        let mask = try makeRawGrayTopBandMask(extent: ciImage.extent, topFraction: 0.4, value: 38) // 38/255 ≈ 0.15

        let masked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: mask)
        let unmasked = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: nil)
        XCTAssertEqual(masked, unmasked, "マスク値 0.15 のセルは空として採用しない（ガンマで膨らませない）")
    }

    /// `.up` 画像では、CIImage 版（マスク無し）と従来の UIImage 版が同じ値を返す（委譲で出力が変わっていない）。
    func testCIImageAnalysisWithoutMaskMatchesUIImageVersion() async throws {
        let image = makeBlueSkyOverGroundImage()
        let ciImage = try await analysisCIImage(from: image)

        let uiColors = try await imageService.extractColors(image, maxCount: 5)
        let ciColors = try await imageService.extractColors(from: ciImage, maxCount: 5, skyMask: nil)
        XCTAssertEqual(ciColors, uiColors)

        let uiTemperature = try await imageService.calculateColorTemperature(image)
        let ciTemperature = try await imageService.calculateColorTemperature(from: ciImage, skyMask: nil)
        XCTAssertEqual(ciTemperature, uiTemperature)
    }

    // MARK: - Helper

    private func createTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 上下 2 色に塗り分けた UIImage（`.up`・scale 1）を作る（`SkyMaskProviderTests.makeTwoBandImage` と同型）
    private func makeTwoBandUIImage(
        top: UIColor,
        bottom: UIColor,
        size: CGSize = CGSize(width: 256, height: 256),
        topFraction: CGFloat = 0.5
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let topHeight = size.height * topFraction
            top.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: size.width, height: topHeight))
            bottom.setFill()
            rendererContext.fill(CGRect(x: 0, y: topHeight, width: size.width, height: size.height - topHeight))
        }
    }

    /// 上=青空 (0.35,0.55,0.90)・下=茶色の地上 (0.45,0.35,0.25) の半々画像
    private func makeBlueSkyOverGroundImage() -> UIImage {
        makeTwoBandUIImage(
            top: UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1),
            bottom: UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        )
    }

    /// 本番（`PostViewModel.makeAnalysisCIImage`）と同じく、長辺 512 に縮小した `.up` 画像の CIImage を作る
    private func analysisCIImage(from image: UIImage) async throws -> CIImage {
        let resized = try await imageService.resizeImage(image, maxSize: CGSize(width: 512, height: 512))
        return try XCTUnwrap(CIImage(image: resized))
    }

    /// 画像の上端 `topFraction` だけが白（=空）のマスクを作る。
    /// - Note: CIImage は y=0 が下端（UIKit と上下逆）なので、上端の帯は高い y 側に置く。
    private func makeTopBandMask(extent: CGRect, topFraction: CGFloat) -> CIImage {
        let bandHeight = extent.height * topFraction
        let band = CGRect(x: extent.minX, y: extent.maxY - bandHeight, width: extent.width, height: bandHeight)
        let white = CIImage(color: CIColor.white).cropped(to: band)
        let black = CIImage(color: CIColor.black).cropped(to: extent)
        return white.composited(over: black)
    }

    /// 上端 `topFraction` の画素値が `value`、それ以外が 0 のマスクを、`HeuristicSkyMaskProvider` と同じ
    /// DeviceGray・`.colorSpace: NSNull()`（色管理なし＝値そのもの）で作る。
    private func makeRawGrayTopBandMask(extent: CGRect, topFraction: CGFloat, value: UInt8) throws -> CIImage {
        let width = Int(extent.width)
        let height = Int(extent.height)
        let bandRows = Int((CGFloat(height) * topFraction).rounded())
        var bytes = [UInt8](repeating: 0, count: width * height)
        // ビットマップは行 0 が上端
        for y in 0 ..< bandRows {
            for x in 0 ..< width {
                bytes[y * width + x] = value
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let cgImage = try XCTUnwrap(context.makeImage())
        return CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// `#RRGGBB` を 0...255 の RGB に分解する
    private func rgb(fromHex hex: String) -> (r: Int, g: Int, b: Int)? {
        guard hex.hasPrefix("#"), hex.count == 7, let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return (r: (value >> 16) & 0xFF, g: (value >> 8) & 0xFF, b: value & 0xFF)
    }
}
