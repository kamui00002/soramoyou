//
//  EditViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import XCTest
@testable import Soramoyou
import UIKit

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
    var applyEditToolCalled = false
    var generatePreviewCalled = false
    var applyEditSettingsCalled = false
    
    func applyFilter(_ filter: FilterType, to image: UIImage) async throws -> UIImage {
        applyFilterCalled = true
        return image
    }
    
    func applyEditTool(_ tool: EditTool, value: Float, to image: UIImage) async throws -> UIImage {
        applyEditToolCalled = true
        return image
    }
    
    func applyEditSettings(_ settings: EditSettings, to image: UIImage) async throws -> UIImage {
        applyEditSettingsCalled = true
        return image
    }
    
    func generatePreview(_ image: UIImage, edits: EditSettings) async throws -> UIImage {
        generatePreviewCalled = true
        return image
    }
    
    func resizeImage(_ image: UIImage, maxSize: CGSize) async throws -> UIImage {
        return image
    }
    
    func compressImage(_ image: UIImage, quality: CGFloat) async throws -> Data {
        return Data()
    }
}

class MockFirestoreService: FirestoreServiceProtocol {
    func fetchUser(userId: String) async throws -> User {
        return User(id: userId, email: "test@example.com")
    }
    
    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { return post }
    func fetchPosts(limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func fetchPost(postId: String) async throws -> Post { throw FirestoreServiceError.notFound }
    func deletePost(postId: String) async throws {}
    func fetchUserPosts(userId: String, limit: Int, lastDocument: DocumentSnapshot?) async throws -> [Post] { return [] }
    func saveDraft(_ draft: Draft) async throws -> Draft { return draft }
    func fetchDrafts(userId: String) async throws -> [Draft] { return [] }
    func loadDraft(draftId: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId: String) async throws {}
    func updateUser(_ user: User) async throws -> User { return user }
    func updateEditTools(userId: String, tools: [EditTool], order: [String]) async throws {}
    func searchByHashtag(_ hashtag: String) async throws -> [Post] { return [] }
    func searchByColor(_ color: String, threshold: Double?) async throws -> [Post] { return [] }
    func searchByTimeOfDay(_ timeOfDay: TimeOfDay) async throws -> [Post] { return [] }
    func searchBySkyType(_ skyType: SkyType) async throws -> [Post] { return [] }
    func searchPosts(hashtag: String?, color: String?, timeOfDay: TimeOfDay?, skyType: SkyType?, colorThreshold: Double?) async throws -> [Post] { return [] }
}


