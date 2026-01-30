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

    // MARK: - Helper Methods

    private func createTestImage(size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

