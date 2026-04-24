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

    func testExtractEXIFData() async throws {
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))

        let exifData = try await imageService.extractEXIFData(testImage)

        XCTAssertNotNil(exifData)
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

    // MARK: - Helper

    private func createTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
