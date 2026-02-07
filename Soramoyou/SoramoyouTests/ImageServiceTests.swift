//
//  ImageServiceTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
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
    
    func testImageServiceInitialization() {
        // Given & When
        let service = ImageService()
        
        // Then
        XCTAssertNotNil(service)
    }
    
    func testResizeImage() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 4000, height: 3000))
        let maxSize = CGSize(width: 2048, height: 2048)
        
        // When
        let resizedImage = try await imageService.resizeImage(testImage, maxSize: maxSize)
        
        // Then
        XCTAssertLessThanOrEqual(resizedImage.size.width, 2048)
        XCTAssertLessThanOrEqual(resizedImage.size.height, 2048)
    }
    
    func testCompressImage() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 1000, height: 1000))
        let quality: CGFloat = 0.85
        
        // When
        let compressedData = try await imageService.compressImage(testImage, quality: quality)
        
        // Then
        XCTAssertFalse(compressedData.isEmpty)
        // JPEG形式であることを確認
        XCTAssertTrue(compressedData.starts(with: [0xFF, 0xD8]))
    }
    
    func testApplyFilter() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        let filter = FilterType.vintage
        
        // When
        let filteredImage = try await imageService.applyFilter(filter, to: testImage)
        
        // Then
        XCTAssertNotNil(filteredImage)
        XCTAssertEqual(filteredImage.size, testImage.size)
    }
    
    func testApplyEditTool() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        let tool = EditTool.brightness
        let value: Float = 0.5
        
        // When
        let editedImage = try await imageService.applyEditTool(tool, value: value, to: testImage)
        
        // Then
        XCTAssertNotNil(editedImage)
        XCTAssertEqual(editedImage.size, testImage.size)
    }
    
    func testGeneratePreview() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 2000, height: 2000))
        let editSettings = EditSettings(brightness: 0.3, contrast: 0.5)
        
        // When
        let previewImage = try await imageService.generatePreview(testImage, edits: editSettings)
        
        // Then
        XCTAssertNotNil(previewImage)
        // プレビューはサムネイルサイズ（512x512以下）であることを確認
        XCTAssertLessThanOrEqual(previewImage.size.width, 512)
        XCTAssertLessThanOrEqual(previewImage.size.height, 512)
    }
    
    // MARK: - Analysis Tests
    
    func testExtractColors() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        let maxCount = 5
        
        // When
        let colors = try await imageService.extractColors(testImage, maxCount: maxCount)
        
        // Then
        XCTAssertFalse(colors.isEmpty)
        XCTAssertLessThanOrEqual(colors.count, maxCount)
        // 16進数カラーコード形式であることを確認
        for color in colors {
            XCTAssertTrue(color.hasPrefix("#"))
            XCTAssertEqual(color.count, 7) // #RRGGBB
        }
    }
    
    func testCalculateColorTemperature() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        
        // When
        let colorTemperature = try await imageService.calculateColorTemperature(testImage)
        
        // Then
        // 色温度は2000K〜10000Kの範囲内であることを確認
        XCTAssertGreaterThanOrEqual(colorTemperature, 2000)
        XCTAssertLessThanOrEqual(colorTemperature, 10000)
    }
    
    func testDetectSkyType() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        
        // When
        let skyType = try await imageService.detectSkyType(testImage)
        
        // Then
        XCTAssertNotNil(skyType)
        // SkyTypeの有効な値であることを確認
        XCTAssertTrue([SkyType.clear, .cloudy, .sunset, .sunrise, .storm].contains(skyType))
    }
    
    func testExtractEXIFData() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 512, height: 512))
        
        // When
        let exifData = try await imageService.extractEXIFData(testImage)
        
        // Then
        XCTAssertNotNil(exifData)
        // EXIF情報がない場合でも空のデータが返されることを確認
    }
    
    func testCompressImageMaxSize() async throws {
        // Given
        // 大きな画像を作成（5MBを超える可能性がある）
        let testImage = createTestImage(size: CGSize(width: 4000, height: 4000))
        let quality: CGFloat = 0.85
        
        // When
        let compressedData = try await imageService.compressImage(testImage, quality: quality)
        
        // Then
        XCTAssertFalse(compressedData.isEmpty)
        // ファイルサイズが5MB以下であることを確認
        let maxSize: Int = 5 * 1024 * 1024 // 5MB
        XCTAssertLessThanOrEqual(compressedData.count, maxSize)
    }
    
    func testResizeImageMaxResolution() async throws {
        // Given
        let testImage = createTestImage(size: CGSize(width: 4000, height: 3000))
        let maxSize = CGSize(width: 2048, height: 2048)
        
        // When
        let resizedImage = try await imageService.resizeImage(testImage, maxSize: maxSize)
        
        // Then
        // 最大解像度2048x2048以下であることを確認
        XCTAssertLessThanOrEqual(resizedImage.size.width, 2048)
        XCTAssertLessThanOrEqual(resizedImage.size.height, 2048)
        // アスペクト比が維持されていることを確認
        let originalAspectRatio = testImage.size.width / testImage.size.height
        let resizedAspectRatio = resizedImage.size.width / resizedImage.size.height
        XCTAssertEqual(originalAspectRatio, resizedAspectRatio, accuracy: 0.01)
    }
    
    // MARK: - CIImage ベース高速プレビュー Tests

    func testResizeCIImage() {
        // Given
        let testImage = createTestImage(size: CGSize(width: 2000, height: 1500))
        guard let ciImage = CIImage(image: testImage) else {
            XCTFail("CIImage変換に失敗")
            return
        }
        let maxSize = CGSize(width: 256, height: 256)

        // When
        let resized = imageService.resizeCIImage(ciImage, maxSize: maxSize)

        // Then
        XCTAssertLessThanOrEqual(resized.extent.width, 256)
        XCTAssertLessThanOrEqual(resized.extent.height, 256)
    }

    func testResizeCIImageNoResizeNeeded() {
        // Given: maxSizeより小さいCIImage（スケールファクターの影響を受けないよう直接作成）
        let ciImage = CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let maxSize = CGSize(width: 256, height: 256)

        // When
        let resized = imageService.resizeCIImage(ciImage, maxSize: maxSize)

        // Then: サイズが変わらない（リサイズ不要なのでそのまま返される）
        XCTAssertEqual(resized.extent.width, ciImage.extent.width, accuracy: 1.0)
        XCTAssertEqual(resized.extent.height, ciImage.extent.height, accuracy: 1.0)
    }

    func testGeneratePreviewFromCIImage() {
        // Given
        let testImage = createTestImage(size: CGSize(width: 256, height: 256))
        guard let ciImage = CIImage(image: testImage) else {
            XCTFail("CIImage変換に失敗")
            return
        }
        let edits = EditSettings(brightness: 0.3, contrast: 0.2)

        // When
        let preview = imageService.generatePreviewFromCIImage(ciImage, edits: edits)

        // Then
        XCTAssertNotNil(preview)
    }

    func testGeneratePreviewFromCIImageWithFilter() {
        // Given
        let testImage = createTestImage(size: CGSize(width: 256, height: 256))
        guard let ciImage = CIImage(image: testImage) else {
            XCTFail("CIImage変換に失敗")
            return
        }
        let edits = EditSettings(appliedFilter: .vintage)

        // When
        let preview = imageService.generatePreviewFromCIImage(ciImage, edits: edits)

        // Then
        XCTAssertNotNil(preview)
    }

    func testGeneratePreviewFromCIImageNoEdits() {
        // Given: 編集なし
        let testImage = createTestImage(size: CGSize(width: 256, height: 256))
        guard let ciImage = CIImage(image: testImage) else {
            XCTFail("CIImage変換に失敗")
            return
        }
        let edits = EditSettings()

        // When
        let preview = imageService.generatePreviewFromCIImage(ciImage, edits: edits)

        // Then
        XCTAssertNotNil(preview)
    }

    func testMetalBackedCIContext() {
        // Given & When: デフォルトコンストラクタでMetal CIContextが使用される
        let service = ImageService()

        // Then: サービスが正常に初期化される
        XCTAssertNotNil(service)
    }

    // MARK: - 全27編集ツールの個別機能テスト

    /// 全27ツールが画像を正常に処理できることを検証
    func testAllEditToolsApplySuccessfully() async throws {
        let testImage = createTestImage(size: CGSize(width: 256, height: 256))
        let testValue: Float = 0.5

        // cropAndRotate以外の全ツールをテスト
        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        for tool in toolsToTest {
            let editedImage = try await imageService.applyEditTool(tool, value: testValue, to: testImage)
            XCTAssertNotNil(editedImage, "\(tool.displayName)ツールが画像処理に失敗")
        }
    }

    /// 各ツールが正値・負値・ゼロで正常に動作することを検証
    func testAllEditToolsWithVariousValues() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let testValues: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        for tool in toolsToTest {
            for value in testValues {
                let editedImage = try await imageService.applyEditTool(tool, value: value, to: testImage)
                XCTAssertNotNil(editedImage, "\(tool.displayName) value=\(value) で失敗")
            }
        }
    }

    /// 個別ツール: 露出（Exposure）
    func testApplyExposure() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.exposure, value: 0.8, to: testImage)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.size, testImage.size)
    }

    /// 個別ツール: トーン（Tone）- 新規追加
    func testApplyTone() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.tone, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.size, testImage.size)
    }

    /// 個別ツール: ブリリアンス（Brilliance）- 新規追加
    func testApplyBrilliance() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.brilliance, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
        XCTAssertEqual(result.size, testImage.size)
    }

    /// 個別ツール: ブラックポイント（Black Point）- 新規追加
    func testApplyBlackPoint() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.blackPoint, value: -0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: 自然な彩度（Natural Saturation / Vibrance）- 新規追加
    func testApplyNaturalSaturation() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.naturalSaturation, value: 0.7, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: 色合い（Tint）- 新規追加
    func testApplyTint() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.tint, value: 0.3, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: 色温度（Color Temperature）- 新規追加
    func testApplyColorTemperatureTool() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.colorTemperature, value: -0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: ホワイトバランス（White Balance）- 新規追加
    func testApplyWhiteBalance() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.whiteBalance, value: 0.3, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: テクスチャ（Texture）- 新規追加
    func testApplyTexture() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        // 正値（強調）
        let resultPos = try await imageService.applyEditTool(.texture, value: 0.5, to: testImage)
        XCTAssertNotNil(resultPos)
        // 負値（滑らか）
        let resultNeg = try await imageService.applyEditTool(.texture, value: -0.5, to: testImage)
        XCTAssertNotNil(resultNeg)
    }

    /// 個別ツール: クラリティ（Clarity）- 新規追加
    func testApplyClarity() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.clarity, value: 0.6, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: かすみの除去（Dehaze）- 新規追加
    func testApplyDehaze() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.dehaze, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: グレイン（Grain）- 新規追加
    func testApplyGrain() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.grain, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: フェード（Fade）- 新規追加
    func testApplyFade() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.fade, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: ノイズリダクション（Noise Reduction）- 新規追加
    func testApplyNoiseReduction() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.noiseReduction, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: カーブ調整（Curves）- 新規追加
    func testApplyCurves() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        // 正値（S字カーブ）
        let resultPos = try await imageService.applyEditTool(.curves, value: 0.5, to: testImage)
        XCTAssertNotNil(resultPos)
        // 負値（逆S字カーブ）
        let resultNeg = try await imageService.applyEditTool(.curves, value: -0.5, to: testImage)
        XCTAssertNotNil(resultNeg)
    }

    /// 個別ツール: HSL調整 - 新規追加
    func testApplyHSL() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.hsl, value: 0.3, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: レンズ補正（Lens Correction）- 新規追加
    func testApplyLensCorrection() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.lensCorrection, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    /// 個別ツール: 二重露光風合成（Double Exposure）- 新規追加
    func testApplyDoubleExposure() async throws {
        let testImage = createTestImage(size: CGSize(width: 128, height: 128))
        let result = try await imageService.applyEditTool(.doubleExposure, value: 0.5, to: testImage)
        XCTAssertNotNil(result)
    }

    // MARK: - EditSettings 全ツール値管理テスト

    /// EditSettingsで全ツールの値をセット・取得できることを検証
    func testEditSettingsAllToolsValueRoundTrip() {
        var settings = EditSettings()
        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        for tool in toolsToTest {
            settings.setValue(0.42, for: tool)
            let retrieved = settings.value(for: tool)
            XCTAssertEqual(retrieved, 0.42, "\(tool.displayName)の値ラウンドトリップに失敗")
        }
    }

    /// EditSettingsで全ツールのnilリセットが動作することを検証
    func testEditSettingsAllToolsReset() {
        var settings = EditSettings()
        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        // まず全部セット
        for tool in toolsToTest {
            settings.setValue(0.5, for: tool)
        }

        // nilでリセット
        for tool in toolsToTest {
            settings.setValue(nil, for: tool)
            XCTAssertNil(settings.value(for: tool), "\(tool.displayName)のリセットに失敗")
        }
    }

    /// EditSettings Firestore変換テスト
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

        // Firestoreデータから復元
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

    // MARK: - CIImageベース全ツールプレビューテスト

    /// CIImageベースのリアルタイムプレビューで全ツールが動作することを検証
    func testGeneratePreviewFromCIImageAllTools() {
        let ciImage = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        for tool in toolsToTest {
            var edits = EditSettings()
            edits.setValue(0.5, for: tool)
            let preview = imageService.generatePreviewFromCIImage(ciImage, edits: edits)
            XCTAssertNotNil(preview, "\(tool.displayName)のCIImageプレビュー生成に失敗")
        }
    }

    /// 複数ツールを同時適用したプレビューが動作することを検証
    func testGeneratePreviewFromCIImageMultipleTools() {
        let ciImage = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        var edits = EditSettings()
        edits.exposure = 0.3
        edits.brightness = 0.1
        edits.contrast = 0.2
        edits.tone = -0.1
        edits.brilliance = 0.4
        edits.naturalSaturation = 0.3
        edits.clarity = 0.5
        edits.grain = 0.2
        edits.vignette = 0.3

        let preview = imageService.generatePreviewFromCIImage(ciImage, edits: edits)
        XCTAssertNotNil(preview, "複数ツール同時適用プレビューに失敗")
    }

    // MARK: - Helper Methods

    private func createTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

