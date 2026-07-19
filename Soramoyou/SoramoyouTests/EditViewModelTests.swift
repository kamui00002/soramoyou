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

    /// ⭐️ 回帰テスト (2026-05-28): 明るさ編集が編集後画像のピクセルに「焼き込まれる」ことを検証する。
    /// 既存テストは editSettings (recipe 値) のみ検証しており、generateFinalImages が
    /// 実際にピクセルを変えるかは未検証だった。投稿された編集後画像が編集前と同一になる
    /// バグ (editSettings は保存されるが画像が素通し) を捕捉する。実 ImageService を使う。
    /// 検証は平均輝度で行うため、ここでは輝度に効く「明るさ」を適用する
    /// （彩度など色相方向の編集は平均輝度をほぼ変えないため、別途検証する想定）。
    func test_generateFinalImages_bakesEditsIntoPixels() async throws {
        let baseImage = Self.makeSolidImage(
            color: UIColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
        )
        let realVM = EditViewModel(
            images: [baseImage],
            userId: nil,
            imageService: ImageService(),
            firestoreService: mockFirestoreService
        )

        // 明るさを上げる編集を適用（輝度で反映を検証できる）
        realVM.setToolValue(1.0, for: .brightness)

        let outputs = try await realVM.generateFinalImages()
        XCTAssertEqual(outputs.count, 1)

        let inLum = Self.meanLuminance(baseImage)
        let outLum = Self.meanLuminance(outputs[0])
        XCTAssertGreaterThan(
            outLum - inLum, 5.0,
            "編集後画像に明るさ編集が反映されていない (in=\(inLum) out=\(outLum))"
        )
    }

    /// 単色テスト画像を生成
    static func makeSolidImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 100, height: 100)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// UIImage の平均輝度 (0...255) を 16x16 にダウンサンプルして算出
    static func meanLuminance(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return -1 }
        let w = 16, h = 16
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        var i = 0
        while i < data.count {
            sum += 0.299 * Double(data[i]) + 0.587 * Double(data[i + 1]) + 0.114 * Double(data[i + 2])
            i += 4
        }
        return sum / Double(w * h)
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

    /// 🔧 回帰テスト（不具合: スタイル調整 → 普通編集でスタイルが基準に戻る）:
    /// スタイルパッド (style2DToneNorm / style2DColorNorm) を設定したあとに普通編集ツール
    /// (露出・明るさ等) を操作しても、スタイルが脱落しないことを検証する。これらは
    /// EditRecipe 専用フィールドで EditSettings 変換では失われるため、editSettings の
    /// setter 側で明示的に保全する必要がある。修正前はこのテストは FAIL する。
    func testEditSettingsSetterPreservesStyle2D() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        // 事前条件: スタイルパッドの値を設定（トーン軸 / カラー軸, 範囲 [-1, 1]）
        viewModel.editRecipe.style2DToneNorm = 0.3
        viewModel.editRecipe.style2DColorNorm = -0.4

        // スライダー操作をシミュレート（editSettings.setValue 経由 → 内部で setter 発火）
        viewModel.setToolValue(0.3, for: .brightness)
        viewModel.setToolValue(-0.2, for: .contrast)
        viewModel.setToolValue(0.5, for: .exposure)

        // スタイルが保持されていること（バグ時は nil = 基準に戻る）
        XCTAssertEqual(viewModel.editRecipe.style2DToneNorm ?? -999, 0.3, accuracy: 0.0001,
                       "style2DToneNorm が脱落している（スタイル調整が基準に戻る不具合）")
        XCTAssertEqual(viewModel.editRecipe.style2DColorNorm ?? -999, -0.4, accuracy: 0.0001,
                       "style2DColorNorm が脱落している（スタイル調整が基準に戻る不具合）")
    }

    /// 🔧 回帰テスト（リセット経路の保全確認）:
    /// resetStyle2D() で意図的に基準へ戻したあとに普通編集ツールを操作しても、スタイルが
    /// nil のまま維持される（サルベージが意図したリセットを壊さない）ことを検証する。
    func testResetStyle2DStaysResetAfterToolEdit() async {
        let testImage = createTestImage()
        viewModel.setImages([testImage])
        await Task.yield()

        // スタイルを設定してから明示リセット
        viewModel.editRecipe.style2DToneNorm = 0.5
        viewModel.editRecipe.style2DColorNorm = 0.5
        viewModel.resetStyle2D()

        // 普通編集ツールを操作（setter 発火）
        viewModel.setToolValue(0.3, for: .brightness)

        // リセット済み（nil）のままであること
        XCTAssertNil(viewModel.editRecipe.style2DToneNorm, "リセットしたスタイルが復活している")
        XCTAssertNil(viewModel.editRecipe.style2DColorNorm, "リセットしたスタイルが復活している")
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
    
    // MARK: - パーソナルAI編集「AIで自動編集」（柱1 v1 / G5）

    func testApplyPersonalDefaultAppliesRepresentativeAndPreservesPhotoSpecific() async {
        // Arrange: 一時コーパスに3件の編集（exposureEV=1.0, saturationCI=1.4）を仕込む
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RecipeCorpusStore(baseDirectory: tmp)
        for _ in 0..<3 {
            var r = EditRecipe()
            r.exposureEV = 1.0
            r.saturationCI = 1.4
            store.append(RecipeCorpusEntry(recipe: r, skyType: .clear), userId: "u1")
        }

        let vm = EditViewModel(
            images: [createTestImage()],
            userId: "u1",
            imageService: MockImageService(),
            firestoreService: MockFirestoreService(),
            recipeCorpusStore: store
        )
        // 写真固有の編集（クロップ・HDR）を現在値として設定
        vm.editRecipe.cropRectNorm = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        vm.editRecipe.targetDynamicRange = .hdr

        // Act
        vm.refreshPersonalDefaultAvailability()
        XCTAssertTrue(vm.hasPersonalDefault, "3件以上で『あなたの定番』が利用可能")
        vm.applyPersonalDefault()

        // Assert: 代表値が適用され、写真固有編集は保持される
        XCTAssertEqual(vm.editRecipe.exposureEV, 1.0, accuracy: 0.0001)
        XCTAssertEqual(vm.editRecipe.saturationCI, 1.4, accuracy: 0.0001)
        XCTAssertEqual(vm.editRecipe.cropRectNorm, CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), "クロップは保持")
        XCTAssertEqual(vm.editRecipe.targetDynamicRange, .hdr, "HDR指定は保持（C1修正の検証）")
    }

    func testRefreshPersonalDefaultUnavailableBelowMinimum() async {
        // 2件のみ → 定番は利用不可（ボタン非表示）
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RecipeCorpusStore(baseDirectory: tmp)
        for _ in 0..<2 {
            var r = EditRecipe(); r.exposureEV = 1.0
            store.append(RecipeCorpusEntry(recipe: r, skyType: .clear), userId: "u1")
        }
        let vm = EditViewModel(
            images: [createTestImage()],
            userId: "u1",
            imageService: MockImageService(),
            firestoreService: MockFirestoreService(),
            recipeCorpusStore: store
        )
        vm.refreshPersonalDefaultAvailability()
        XCTAssertFalse(vm.hasPersonalDefault, "データ不足ではボタンを出さない")
    }

    // MARK: - レシピ共有シード（initialRecipe）

    func testInitialRecipeSeedsEditorAndSurvivesImageSwitch() async {
        // Given: 共有レシピを seed としてエディタを起動（複数画像）
        var seed = EditRecipe()
        seed.exposureEV = 1.0
        seed.warmthNorm = 0.4
        seed.appliedFilter = .warm
        let testImages = [createTestImage(), createTestImage()]

        // When
        let seededViewModel = EditViewModel(
            images: testImages,
            userId: nil,
            imageService: mockImageService,
            firestoreService: mockFirestoreService,
            initialRecipe: seed
        )
        await Task.yield()

        // Then: 現在のレシピが seed と一致する
        XCTAssertEqual(seededViewModel.editRecipe, seed)

        // 画像を切り替えても seed が保持される（全 imageStates に seed が入っている）
        seededViewModel.nextImage()
        await Task.yield()
        XCTAssertEqual(seededViewModel.editRecipe, seed, "2枚目に切り替えても seed が効いている")

        seededViewModel.previousImage()
        await Task.yield()
        XCTAssertEqual(seededViewModel.editRecipe, seed, "1枚目に戻っても seed が保持されている")
    }

    func testInitWithoutInitialRecipeStaysNeutral() async {
        // initialRecipe を渡さない既存経路では中立レシピのまま（既存挙動の回帰確認）
        let plainViewModel = EditViewModel(
            images: [createTestImage()],
            userId: nil,
            imageService: mockImageService,
            firestoreService: mockFirestoreService
        )
        XCTAssertTrue(plainViewModel.editRecipe.isNeutral)
    }

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

    /// - Parameter skyMask: ワンタップ空補正のモックでは未使用（呼び出しの有無のみ確認する既存テストのため）
    func generatePreview(_ image: UIImage, recipe: EditRecipe, skyMask: CIImage?) async throws -> UIImage {
        generatePreviewCalled = true
        return image
    }

    /// - Parameter skyMask: ワンタップ空補正のモックでは未使用（呼び出しの有無のみ確認する既存テストのため）
    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe: EditRecipe, skyMask: CIImage?) -> UIImage? {
        generatePreviewCalled = true
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// - Parameter skyMask: ワンタップ空補正のモックでは未使用（呼び出しの有無のみ確認する既存テストのため）
    func applyEditRecipe(_ recipe: EditRecipe, to image: UIImage, skyMask: CIImage?) async throws -> UIImage {
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



