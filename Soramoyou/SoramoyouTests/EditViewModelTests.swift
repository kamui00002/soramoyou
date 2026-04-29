//
//  EditViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import UIKit
import CoreImage
import FirebaseFirestore

@MainActor
final class EditViewModelTests: XCTestCase {
    var viewModel: EditViewModel!
    var mockImageService: MockImageService!
    var mockFirestoreService: MockFirestoreService!
    
    override func setUp() {
        super.setUp()
        mockImageService = MockImageService()
        mockFirestoreService = MockFirestoreService()
        viewModel = EditViewModel(
            images: [],
            userId: nil,
            imageService: mockImageService,
            firestoreService: mockFirestoreService
        )
    }
    
    override func tearDown() {
        viewModel = nil
        mockImageService = nil
        mockFirestoreService = nil
        super.tearDown()
    }
    
    func testSetImages() async {
        // Given
        let testImages = [createTestImage(), createTestImage()]
        
        // When
        viewModel.setImages(testImages)
        
        // Then
        XCTAssertEqual(viewModel.originalImages.count, 2)
        XCTAssertEqual(viewModel.currentImageIndex, 0)
    }
    
    func testApplyFilter() async {
        // Given
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield() // 非同期処理を待機
        
        // When
        viewModel.applyFilter(.vintage)
        
        // Then
        XCTAssertEqual(viewModel.editSettings.appliedFilter, .vintage)
    }
    
    func testRemoveFilter() async {
        // Given
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        viewModel.applyFilter(.vintage)
        await Task.yield()
        
        // When
        viewModel.removeFilter()
        
        // Then
        XCTAssertNil(viewModel.editSettings.appliedFilter)
    }
    
    func testSetToolValue() async {
        // Given
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()
        
        // When
        viewModel.setToolValue(0.5, for: .brightness)
        
        // Then
        XCTAssertEqual(viewModel.editSettings.brightness, 0.5)
    }
    
    func testSetToolValueClamping() async {
        // Given
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()
        
        // When - 範囲外の値を設定
        viewModel.setToolValue(2.0, for: .brightness) // 1.0を超える値
        
        // Then - 1.0にクランプされる
        XCTAssertEqual(viewModel.editSettings.brightness, 1.0)
    }
    
    func testResetToolValue() async {
        // Given
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        viewModel.setToolValue(0.5, for: .brightness)
        await Task.yield()
        
        // When
        viewModel.resetToolValue(for: .brightness)
        
        // Then
        XCTAssertNil(viewModel.editSettings.brightness)
    }
    
    func testResetAllEdits() async {
        // Given
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        viewModel.applyFilter(.vintage)
        viewModel.setToolValue(0.5, for: .brightness)
        await Task.yield()
        
        // When
        viewModel.resetAllEdits()
        
        // Then
        XCTAssertNil(viewModel.editSettings.appliedFilter)
        XCTAssertNil(viewModel.editSettings.brightness)
    }
    
    func testNextImage() async {
        // Given
        let testImages = [createTestImage(), createTestImage()]
        viewModel.setImages(testImages)
        await Task.yield()
        
        // When
        viewModel.nextImage()
        
        // Then
        XCTAssertEqual(viewModel.currentImageIndex, 1)
    }
    
    func testPreviousImage() async {
        // Given
        let testImages = [createTestImage(), createTestImage()]
        viewModel.setImages(testImages)
        viewModel.nextImage()
        await Task.yield()
        
        // When
        viewModel.previousImage()
        
        // Then
        XCTAssertEqual(viewModel.currentImageIndex, 0)
    }
    
    /// 新規追加ツール（トーン）の値設定テスト
    func testSetToolValueTone() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        viewModel.setToolValue(0.7, for: .tone)
        XCTAssertEqual(viewModel.editSettings.tone, 0.7)
    }

    /// 新規追加ツール（ブリリアンス）の値設定テスト
    func testSetToolValueBrilliance() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        viewModel.setToolValue(-0.3, for: .brilliance)
        XCTAssertEqual(viewModel.editSettings.brilliance, -0.3)
    }

    /// H-3 対応: ノイズリダクションは片側スライダ（0...1）にクランプされる
    func testSetToolValueNoiseReductionClampsNegative() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        // 負値を入力しても 0 にクランプされ、Firestore や Recipe に負値が入り込まない
        viewModel.setToolValue(-0.7, for: .noiseReduction)
        XCTAssertEqual(viewModel.editSettings.noiseReduction, 0,
                       "ノイズリダクションの負値がクランプされていない（H-3 回帰）")

        // 正値はそのまま通る
        viewModel.setToolValue(0.6, for: .noiseReduction)
        XCTAssertEqual(viewModel.editSettings.noiseReduction ?? 0, 0.6, accuracy: 0.001)
    }

    /// H-3 対応: EditTool.sliderRange は .noiseReduction のみ 0...1、他は -1...1
    func testEditToolSliderRange() {
        for tool in EditTool.allCases {
            let range = tool.sliderRange
            if tool == .noiseReduction {
                XCTAssertEqual(range.lowerBound, 0,
                               "ノイズリダクションは片側スライダである必要がある")
                XCTAssertEqual(range.upperBound, 1)
            } else {
                XCTAssertEqual(range.lowerBound, -1,
                               "\(tool.displayName) は両側スライダである必要がある")
                XCTAssertEqual(range.upperBound, 1)
            }
        }
    }

    /// 新規追加ツール（自然な彩度）の値設定テスト
    func testSetToolValueNaturalSaturation() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        viewModel.setToolValue(0.6, for: .naturalSaturation)
        XCTAssertEqual(viewModel.editSettings.naturalSaturation, 0.6)
    }

    /// 全27ツールの値設定・リセットテスト
    func testSetAndResetAllTools() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        let toolsToTest = EditTool.allCases.filter { $0 != .cropAndRotate }

        for tool in toolsToTest {
            viewModel.setToolValue(0.42, for: tool)
            XCTAssertEqual(viewModel.editSettings.value(for: tool), 0.42,
                           "\(tool.displayName)の値設定に失敗")
        }

        for tool in toolsToTest {
            viewModel.resetToolValue(for: tool)
            XCTAssertNil(viewModel.editSettings.value(for: tool),
                         "\(tool.displayName)のリセットに失敗")
        }
    }

    /// リアルタイム編集フラグのテスト
    func testRealtimeEditingFlag() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        // リアルタイム値設定でフラグがtrueになる
        viewModel.setToolValueRealtime(0.5, for: .clarity)
        XCTAssertTrue(viewModel.isEditingRealtime)

        // finalizeでフラグがfalseに戻る
        viewModel.finalizeToolValue(for: .clarity)
        XCTAssertFalse(viewModel.isEditingRealtime)
    }

    /// 🔧 H2 回帰テスト:
    /// スライダー操作 (editSettings 経由の書き込み) をしても、EditSettings に存在しない
    /// toneCurvePoints / targetDynamicRange / cropRectNorm が脱落しないことを検証する。
    /// これらは EditRecipe → EditSettings 変換で失われるため、setter 側で明示的に保全する
    /// 必要がある (コードレビュー H2)。
    func testEditSettingsSetterPreservesRecipeOnlyFields() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        // 事前条件: recipe-only なフィールドを手動でセット
        var curve = ToneCurvePoints()
        curve.point0 = CurvePoint(x: 0.0, y: 0.05)
        curve.point1 = CurvePoint(x: 0.25, y: 0.2)
        curve.point2 = CurvePoint(x: 0.5, y: 0.5)
        curve.point3 = CurvePoint(x: 0.75, y: 0.8)
        curve.point4 = CurvePoint(x: 1.0, y: 0.95)
        viewModel.editRecipe.toneCurvePoints = curve
        viewModel.editRecipe.targetDynamicRange = .hdr
        viewModel.editRecipe.cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        // スライダー操作をシミュレート (editSettings.setValue 経由 → 内部で setter 発火)
        viewModel.setToolValue(0.3, for: .brightness)
        viewModel.setToolValue(-0.2, for: .contrast)
        viewModel.setToolValue(0.5, for: .exposure)

        // recipe-only フィールドが保持されていること
        XCTAssertNotNil(viewModel.editRecipe.toneCurvePoints, "toneCurvePoints が脱落している")
        XCTAssertEqual(viewModel.editRecipe.toneCurvePoints?.point1.y ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(viewModel.editRecipe.targetDynamicRange, DynamicRange.hdr)
        XCTAssertEqual(viewModel.editRecipe.cropRectNorm?.origin.x ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(viewModel.editRecipe.cropRectNorm?.width ?? -1, 0.8, accuracy: 0.0001)
    }

    func testLoadEquippedToolsWithoutUser() async {
        // Given
        viewModel = EditViewModel(
            images: [],
            userId: nil,
            imageService: mockImageService,
            firestoreService: mockFirestoreService
        )
        
        // When
        await viewModel.loadEquippedTools()
        
        // Then
        XCTAssertFalse(viewModel.equippedTools.isEmpty)
        // デフォルトツールが設定されていることを確認
        XCTAssertTrue(viewModel.equippedTools.contains(.brightness))
    }
    
    // MARK: - Helper Methods
    
    private func createTestImage(size: CGSize = CGSize(width: 512, height: 512)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Mock Services

class MockImageService: ImageServiceProtocol {
    var applyFilterCalled = false
    var generatePreviewCalled = false
    /// 旧 applyEditTool/applyEditSettings 呼び出し痕跡テスト用の互換フラグ。
    /// 現行実装では applyEditRecipe が呼ばれたときに true になる。
    var applyEditSettingsCalled = false

    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage {
        applyFilterCalled = true
        return image
    }

    func generatePreview(_ image: UIImage, recipe: EditRecipe) async throws -> UIImage {
        generatePreviewCalled = true
        return image
    }

    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe: EditRecipe) -> UIImage? {
        generatePreviewCalled = true
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    func applyEditRecipe(_ recipe: EditRecipe, to image: UIImage) async throws -> UIImage {
        applyEditSettingsCalled = true
        return image
    }

    func resizeCIImage(_ ciImage: CIImage, maxSize: CGSize) -> CIImage {
        return ciImage
    }

    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage {
        return image
    }
    
    func compressImage(_ image: UIImage, quality: CGFloat) async throws -> Data {
        return Data()
    }

    func extractColors(_ image: UIImage, maxCount: Int) async throws -> [String] {
        return ["#87CEEB", "#F0F8FF", "#FFFFFF"]
    }

    func calculateColorTemperature(_ image: UIImage) async throws -> Int {
        return 6500
    }

    func detectSkyType(_ image: UIImage) async throws -> SkyType {
        return .clear
    }

    func extractEXIFData(_ image: UIImage) async throws -> EXIFData {
        return EXIFData()
    }
}

class MockFirestoreService: FirestoreServiceProtocol {
    func fetchUser(userId: String) async throws -> User {
        return User(id: userId, email: "test@example.com")
    }

    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { return post }
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func fetchPostsWithSnapshot(limit: Int, lastDocument: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) { return ([], nil) }
    func fetchPost(postId: String) async throws -> Post { throw FirestoreServiceError.notFound }
    func deletePost(postId: String, userId: String) async throws {}
    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func saveDraft(_ draft: Draft) async throws -> Draft { return draft }
    func fetchDrafts(userId: String) async throws -> [Draft] { return [] }
    func loadDraft(draftId: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId: String) async throws {}
    func updateUser(_ user: User) async throws -> User { return user }
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {}
    func syncPostsCount(userId: String, count: Int) async throws {}
    func fetchPublicProfile(userId: String) async throws -> PublicProfile { throw FirestoreServiceError.notFound }
    func updatePublicProfile(_ profile: PublicProfile) async throws {}
    func createPublicProfile(from user: User) async throws {}
    func deleteUserData(userId: String) async throws {}
    func reportPost(postId: String, reporterId: String, reportedUserId: String, reason: String) async throws {}
    func blockUser(userId: String, blockedUserId: String) async throws {}
    func unblockUser(userId: String, blockedUserId: String) async throws {}
    func fetchBlockedUserIds(userId: String) async throws -> [String] { return [] }
    func searchByHashtag(_ hashtag: String) async throws -> [Post] { return [] }
    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post] { return [] }
    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post] { return [] }
    func searchBySkyType(_ skyType: SkyType) async throws -> [Post] { return [] }
    func searchPosts(
        hashtag: String?,
        color: String?,
        timeOfDay: TimeOfDay?,
        skyType: SkyType?,
        colorThreshold: Double?,
        limit: Int
    ) async throws -> [Post] { return [] }
}



