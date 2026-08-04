//
//  EditViewModelTests.swift
//  SoramoyouTests
//
//  Created on 2025-12-06.
//

import CoreImage
import FirebaseFirestore
@testable import Soramoyou
import UIKit
import XCTest

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

    /// 🆕 G4回帰テスト: `loadEquippedTools()` 内で `refreshPersonalDefaultAvailability()` を
    /// `guard let userId else { ... return }` より前に呼んでいることが生命線であることを守るテスト。
    /// この呼び出し順序を入れ替え、ユーザーガードの後ろに `refreshPersonalDefaultAvailability()` を
    /// 移動すると、未ログイン時はガードで早期 return してしまい候補が一度も算出されなくなる
    /// （＝このテストが落ちることで順序回帰を検知するのが狙い）。
    func testLoadEquippedToolsWithoutUserStillPopulatesCandidates() async {
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
        XCTAssertEqual(
            viewModel.personalDefaultCandidatePool.count, FixedPresetKind.allCases.count,
            "未ログインでも固定プリセット全件（プールは打ち切りなし）で候補プールが埋まる"
        )
        XCTAssertTrue(viewModel.hasPersonalDefault, "未ログインでも『AIで自動編集』ボタンは表示される")
    }

    // MARK: - ワンタップ空補正: マスクキャッシュのライフサイクル（レビュー keep 対応 #7）

    /// 🔧 レビュー指摘2 回帰テスト:
    /// `ensureSkyMaskCached` の await 中（`skyMaskProvider.makeSkyMask` の非同期処理中）に
    /// ユーザーが画像を切り替えると、`currentImageIndex` を await 後に読み直していた旧実装では
    /// 「画像0向けに生成したマスク」が「切替後の画像1のキャッシュ」として誤って紐付いてしまう。
    /// この誤紐付けが起きると、`applySkyCorrection()` の末尾で呼ばれる `generatePreview()` が
    /// 画像1向けにマスクを再生成すべきところを「画像1のキャッシュは既に有効」と誤判定して
    /// スキップしてしまう（＝ makeSkyMask の呼び出し回数が 1 回のまま増えない）。
    /// 修正後は await 前にキャプチャした画像インデックス（0）で正しくタグ付けされるため、
    /// 画像1に対しては cache miss と判定され、`generatePreview()` が画像1向けのマスクを
    /// 正しく再生成する（＝呼び出し回数が 2 回になる）。
    func testEnsureSkyMaskCachedTagsCacheWithImageIndexCapturedBeforeAwait() async throws {
        let images = [createTestImage(), createTestImage()]
        let slowProvider = MockSkyMaskProvider()
        slowProvider.delayNanoseconds = 100_000_000 // 100ms: 画像切替を割り込ませるための猶予
        slowProvider.coverage = 0.5
        slowProvider.confidence = 0.5
        let vm = EditViewModel(
            images: images,
            userId: nil,
            imageService: MockImageService(),
            firestoreService: MockFirestoreService(),
            skyMaskProvider: slowProvider
        )
        await Task.yield()

        // 画像0に対して「空を整える」を開始する（内部の makeSkyMask の await 中に中断される）
        let correctionTask = Task { @MainActor in
            await vm.applySkyCorrection()
        }

        // correctionTask が makeSkyMask の Task.sleep に到達するまで進行させてから、
        // まだ real-time の sleep（100ms）が完了しないうちに（＝完全に同期的に）画像を切り替える。
        // 切替自体は await を挟まないため、100ms のスリープが終わるより確実に先に完了する。
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        XCTAssertEqual(slowProvider.callCount, 1, "この時点で1回目の makeSkyMask は呼ばれ始めているべき")
        vm.nextImage()
        XCTAssertEqual(vm.currentImageIndex, 1, "画像切替がレース発生前に完了しているべき")

        await correctionTask.value

        XCTAssertEqual(
            slowProvider.callCount, 2,
            "画像1向けにマスクが再生成されるべき（画像0のマスクを画像1のものと誤認してスキップしていないか＝レース修正の回帰）"
        )
    }

    /// 🔧 回帰テスト: 空マスクの skyCoverage / confidence がしきい値未満のとき、
    /// `applySkyCorrection()` は errorMessage をセットし、skyCorrectionIntensity を
    /// 変更しない（適用しない）ことを検証する。
    func testApplySkyCorrectionSetsErrorAndKeepsIntensityUnchangedWhenMaskQualityInsufficient() async throws {
        // ケース1: coverage 不足（skyCorrectionMinCoverage=0.05 未満）
        let lowCoverageProvider = MockSkyMaskProvider()
        lowCoverageProvider.coverage = 0.01
        lowCoverageProvider.confidence = 0.5
        let vmLowCoverage = EditViewModel(
            images: [createTestImage()],
            userId: nil,
            imageService: MockImageService(),
            firestoreService: MockFirestoreService(),
            skyMaskProvider: lowCoverageProvider
        )
        await Task.yield()

        let intensityBeforeLowCoverage = vmLowCoverage.editRecipe.skyCorrectionIntensity
        await vmLowCoverage.applySkyCorrection()

        XCTAssertEqual(vmLowCoverage.editRecipe.skyCorrectionIntensity, intensityBeforeLowCoverage,
                       "coverage不足時は intensity を変更してはならない")
        XCTAssertNotNil(vmLowCoverage.errorMessage, "coverage不足時は errorMessage を表示するべき")

        // ケース2: confidence 不足（skyCorrectionMinConfidence=0.3 未満）
        let lowConfidenceProvider = MockSkyMaskProvider()
        lowConfidenceProvider.coverage = 0.5
        lowConfidenceProvider.confidence = 0.1
        let vmLowConfidence = EditViewModel(
            images: [createTestImage()],
            userId: nil,
            imageService: MockImageService(),
            firestoreService: MockFirestoreService(),
            skyMaskProvider: lowConfidenceProvider
        )
        await Task.yield()

        let intensityBeforeLowConfidence = vmLowConfidence.editRecipe.skyCorrectionIntensity
        await vmLowConfidence.applySkyCorrection()

        XCTAssertEqual(vmLowConfidence.editRecipe.skyCorrectionIntensity, intensityBeforeLowConfidence,
                       "confidence不足時は intensity を変更してはならない")
        XCTAssertNotNil(vmLowConfidence.errorMessage, "confidence不足時は errorMessage を表示するべき")
    }

    // MARK: - Helper Methods

    // MARK: - パーソナルAI編集「AIで自動編集」（柱1 v1 / G5）

    func testApplyPersonalDefaultAppliesRepresentativeAndPreservesPhotoSpecific() async {
        // Arrange: 一時コーパスに3件の編集（exposureEV=1.0, saturationCI=1.4）を仕込む
        let (vm, tmp) = makeCorpusFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 写真固有の編集（クロップ・HDR・空補正）を現在値として設定
        vm.editRecipe.cropRectNorm = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        vm.editRecipe.targetDynamicRange = .hdr
        vm.editRecipe.skyCorrectionIntensity = 0.6

        // Act
        vm.refreshPersonalDefaultAvailability()
        XCTAssertTrue(vm.hasPersonalDefault, "3件以上で『あなたの定番』が利用可能")
        vm.applyPersonalDefault()

        // Assert: 代表値が適用され、写真固有編集は保持される
        XCTAssertEqual(vm.editRecipe.exposureEV, 1.0, accuracy: 0.0001)
        XCTAssertEqual(vm.editRecipe.saturationCI, 1.4, accuracy: 0.0001)
        XCTAssertEqual(vm.editRecipe.cropRectNorm, CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), "クロップは保持")
        XCTAssertEqual(vm.editRecipe.targetDynamicRange, .hdr, "HDR指定は保持（C1修正の検証）")
        XCTAssertEqual(vm.editRecipe.skyCorrectionIntensity ?? -1, 0.6, accuracy: 0.0001,
                       "空補正の強度は保持（統合レビューで発見した消失バグの回帰防止）")
    }

    /// 🆕 候補プール（柱1 v2）: コーパスに十分な履歴があると、
    /// 「全体の定番」が先頭 + 固定プリセット全件で埋められることを検証する。
    /// プール化により件数の打ち切りは無くなったため、件数は「1(全体の定番) + プリセット全件」の
    /// 固定値になる（空タイプ別「晴れの定番」は全体候補と isSimilar 判定で重複排除される想定）。
    func testRefreshPersonalDefaultAvailabilityPopulatesCandidates() async {
        // Arrange: testApplyPersonalDefaultAppliesRepresentativeAndPreservesPhotoSpecific と同じ仕込み
        // （exposureEV/saturationCI が全件一致するため、空タイプ別「晴れの定番」は全体候補と isSimilar 判定で
        //   重複排除される）。
        let (vm, tmp) = makeCorpusFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Act
        vm.refreshPersonalDefaultAvailability()

        // Assert
        XCTAssertEqual(
            vm.personalDefaultCandidatePool.count, 1 + FixedPresetKind.allCases.count,
            "候補プールは打ち切りなし：全体の定番1件 + 固定プリセット全件（実際: \(vm.personalDefaultCandidatePool.count)件）"
        )
        XCTAssertEqual(vm.personalDefaultCandidatePool.first?.kind, .overallDefault,
                       "3件以上の履歴があれば先頭候補は全体の『あなたの定番』")
        XCTAssertTrue(vm.hasPersonalDefault)
    }

    /// 🆕 候補プール（柱1 v2）: コーパスが0件（新規ユーザー・未ログイン想定）でも
    /// 固定プリセット全件で候補プールが必ず埋まる新仕様を検証する。
    func testRefreshPersonalDefaultShowsPresetsWithoutHistory() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RecipeCorpusStore(baseDirectory: tmp)

        let vm = EditViewModel(
            images: [createTestImage()],
            userId: nil,
            imageService: MockImageService(),
            firestoreService: MockFirestoreService(),
            recipeCorpusStore: store
        )

        vm.refreshPersonalDefaultAvailability()

        XCTAssertEqual(
            vm.personalDefaultCandidatePool.count, FixedPresetKind.allCases.count,
            "履歴0件では固定プリセット全件（プールは打ち切りなし）で埋まる"
        )
        XCTAssertTrue(
            vm.personalDefaultCandidatePool.allSatisfy { candidate in
                if case .preset = candidate.kind { return true }
                return false
            },
            "履歴0件では『あなたの定番』系は1件も成立せず、全候補が固定プリセットになる"
        )
        XCTAssertTrue(vm.hasPersonalDefault, "履歴が無くても固定プリセットでボタンは表示される（新規ユーザー常時表示の確定仕様）")
    }

    /// 🆕 候補シート経由の適用パス（applyPersonalDefaultCandidate）版の回帰テスト。
    /// testApplyPersonalDefaultAppliesRepresentativeAndPreservesPhotoSpecific と同型だが、
    /// 「あなたの定番」単体適用（applyPersonalDefault）ではなく候補シートで選択した候補を適用する
    /// 経路（本番でUIから実際に呼ばれる経路）でも 913a3cd 回帰（写真固有フィールド消失）が
    /// 起きないことを確認する。
    func testApplyPersonalDefaultCandidatePreservesPhotoSpecificFields() async {
        // Arrange
        let (vm, tmp) = makeCorpusFixture()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 写真固有の編集（クロップ・HDR・空補正）を現在値として設定
        vm.editRecipe.cropRectNorm = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        vm.editRecipe.targetDynamicRange = .hdr
        vm.editRecipe.skyCorrectionIntensity = 0.6

        // Act: 候補プールから「全体の定番」候補を選んで適用
        vm.refreshPersonalDefaultAvailability()
        guard let overallCandidate = vm.personalDefaultCandidatePool.first(where: { $0.kind == .overallDefault }) else {
            XCTFail("『全体の定番』候補が候補プールに見つからない")
            return
        }
        // displayIndex はシート側で描画後に選別した表示リスト内の位置。
        // このテストは候補プールから直接取得しているためシートの選別を経ていないが、
        // applyPersonalDefaultCandidate 自体は displayIndex を計装にしか使わないため、
        // 適用結果の検証（写真固有フィールドの保持）には影響しない。
        vm.applyPersonalDefaultCandidate(overallCandidate, displayIndex: 0)

        // Assert: 代表値が適用され、写真固有編集は保持される
        XCTAssertEqual(vm.editRecipe.exposureEV, 1.0, accuracy: 0.0001)
        XCTAssertEqual(vm.editRecipe.saturationCI, 1.4, accuracy: 0.0001)
        XCTAssertEqual(vm.editRecipe.cropRectNorm, CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5), "クロップは保持")
        XCTAssertEqual(vm.editRecipe.targetDynamicRange, .hdr, "HDR指定は保持")
        XCTAssertEqual(vm.editRecipe.skyCorrectionIntensity ?? -1, 0.6, accuracy: 0.0001,
                       "空補正の強度は保持（候補シート経由の適用パスでも913a3cd回帰が起きないことの確認）")
    }

    /// 【仕様変更に伴う書き換え】旧テスト `testRefreshPersonalDefaultUnavailableBelowMinimum` は
    /// 「3件未満なら hasPersonalDefault=false（ボタン非表示）」という旧仕様を検証していたが、
    /// 候補プール導入（柱1 v2 / `PersonalDefaultCandidateProvider`）で
    /// 「履歴不足でも固定プリセット全件を保証し常時表示する」に仕様が変わったため、
    /// 新仕様に合わせて内容を書き換えた（テスト名も実態に合わせて変更）。
    func testRefreshPersonalDefaultBelowMinimumShowsPresetOnly() async {
        // 2件のみ（minimumSamples=3 未満）→ 全体/空タイプ別の「あなたの定番」は不成立だが、
        // 固定プリセットのみで候補プールが埋まることを検証する。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = RecipeCorpusStore(baseDirectory: tmp)
        for _ in 0 ..< 2 {
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

        XCTAssertTrue(vm.hasPersonalDefault, "履歴不足でも固定プリセットでボタンは表示される（新仕様）")
        XCTAssertEqual(
            vm.personalDefaultCandidatePool.count, FixedPresetKind.allCases.count,
            "『あなたの定番』系が不成立のため固定プリセット全件のみになる（プールは打ち切りなし）"
        )
        XCTAssertTrue(
            vm.personalDefaultCandidatePool.allSatisfy { candidate in
                if case .preset = candidate.kind { return true }
                return false
            },
            "2件（3件未満）では『あなたの定番』系候補は成立せず、全て固定プリセットになる"
        )
    }

    /// 🆕 `EditRecipe.mergingPhotoSpecificFields(from:includeSkyCorrection:)` の
    /// `includeSkyCorrection` 引数そのものを検証する（候補パス/サムネイル生成パスの土台となる純関数）。
    /// - `includeSkyCorrection: false`（サムネイル生成用）→ skyCorrectionIntensity は nil になる
    ///   （skyMask なしで描画するため intensity を転写しても見た目に反映されず、
    ///   「レシピは値あり・見た目は補正なし」の食い違いになるのを防ぐ挙動）。
    /// - `includeSkyCorrection` 省略時（既定 true・本適用用）→ 現在値をそのまま転写する。
    func testMergingPhotoSpecificFields_excludesSkyCorrectionWhenRequested() async {
        var candidateRecipe = EditRecipe()
        candidateRecipe.exposureEV = 0.5

        var current = EditRecipe()
        current.skyCorrectionIntensity = 0.7
        current.cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        current.targetDynamicRange = .hdr

        // includeSkyCorrection: false を明示 → skyCorrectionIntensity は転写されず nil
        let mergedWithoutSkyCorrection = candidateRecipe.mergingPhotoSpecificFields(
            from: current, includeSkyCorrection: false
        )
        XCTAssertNil(mergedWithoutSkyCorrection.skyCorrectionIntensity, "includeSkyCorrection: false では空補正強度を転写しない")
        XCTAssertEqual(mergedWithoutSkyCorrection.cropRectNorm, current.cropRectNorm, "クロップは includeSkyCorrection に関わらず常に転写される")
        XCTAssertEqual(mergedWithoutSkyCorrection.targetDynamicRange, current.targetDynamicRange, "HDR指定も常に転写される")

        // includeSkyCorrection 省略（既定 true）→ 現在値を転写する
        let mergedWithSkyCorrection = candidateRecipe.mergingPhotoSpecificFields(from: current)
        XCTAssertEqual(mergedWithSkyCorrection.skyCorrectionIntensity ?? -1, 0.7, accuracy: 0.0001,
                       "既定(true)では空補正強度を転写する")
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

    /// 🆕 S4対応: 「あなたの定番」系テストで繰り返し使うコーパス fixture 構築を1箇所に集約する。
    /// exposureEV=1.0 / saturationCI=1.4 の編集レシピを skyType=.clear・userId="u1" で3件
    /// コーパスに積んだ状態の `EditViewModel` を返す。呼び出し側は返却された一時ディレクトリを
    /// `defer { try? FileManager.default.removeItem(at: tmp) }` で必ず削除すること
    /// （元の各テストで tmp 生成直後に defer していたのと同じ後始末をテスト側に残すため）。
    /// - Returns: (vm: 構築済み EditViewModel, tmp: 一時コーパスディレクトリ)
    private func makeCorpusFixture() -> (vm: EditViewModel, tmp: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("epd-\(UUID().uuidString)", isDirectory: true)
        let store = RecipeCorpusStore(baseDirectory: tmp)
        for _ in 0 ..< 3 {
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
        return (vm, tmp)
    }
}

// MARK: - Mock Services

class MockImageService: ImageServiceProtocol {
    var applyFilterCalled = false
    var generatePreviewCalled = false
    /// 旧 applyEditTool/applyEditSettings 呼び出し痕跡テスト用の互換フラグ。
    /// 現行実装では applyEditRecipe が呼ばれたときに true になる。
    var applyEditSettingsCalled = false

    func applyFilter(_: FilterType, to image: UIImage) async throws -> UIImage {
        applyFilterCalled = true
        return image
    }

    /// - Parameter skyMask: ワンタップ空補正のモックでは未使用（呼び出しの有無のみ確認する既存テストのため）
    func generatePreview(_ image: UIImage, recipe _: EditRecipe, skyMask _: CIImage?) async throws -> UIImage {
        generatePreviewCalled = true
        return image
    }

    /// - Parameter skyMask: ワンタップ空補正のモックでは未使用（呼び出しの有無のみ確認する既存テストのため）
    func generatePreviewFromCIImage(_ ciImage: CIImage, recipe _: EditRecipe, skyMask _: CIImage?) -> UIImage? {
        generatePreviewCalled = true
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// - Parameter skyMask: ワンタップ空補正のモックでは未使用（呼び出しの有無のみ確認する既存テストのため）
    func applyEditRecipe(_: EditRecipe, to image: UIImage, skyMask _: CIImage?) async throws -> UIImage {
        applyEditSettingsCalled = true
        return image
    }

    func resizeCIImage(_ ciImage: CIImage, maxSize _: CGSize) -> CIImage {
        ciImage
    }

    func resizeImage(_ image: UIImage, maxSize _: CGSize) async throws -> UIImage {
        image
    }

    func compressImage(_: UIImage, quality _: CGFloat) async throws -> Data {
        Data()
    }

    func extractColors(_: UIImage, maxCount _: Int) async throws -> [String] {
        ["#87CEEB", "#F0F8FF", "#FFFFFF"]
    }

    func calculateColorTemperature(_: UIImage) async throws -> Int {
        6500
    }

    func detectSkyType(_: UIImage) async throws -> SkyType {
        .clear
    }

    func extractEXIFData(_: UIImage) async throws -> EXIFData {
        EXIFData()
    }
}

class MockFirestoreService: FirestoreServiceProtocol {
    func fetchUser(userId: String) async throws -> User {
        User(id: userId, email: "test@example.com")
    }

    // その他のメソッドは空実装
    func createPost(_ post: Post) async throws -> Post { post }
    func fetchPosts(limit _: Int, lastDocument _: DocumentSnapshot?) async throws -> [Post] { [] }
    func fetchPostsWithSnapshot(limit _: Int, lastDocument _: DocumentSnapshot?) async throws -> (posts: [Post], lastDocument: DocumentSnapshot?) { ([], nil) }
    func fetchPost(postId _: String) async throws -> Post { throw FirestoreServiceError.notFound }
    func deletePost(postId _: String, userId _: String) async throws {}
    func fetchUserPosts(userId _: String, limit _: Int, lastDocument _: DocumentSnapshot?) async throws -> [Post] { [] }
    func saveDraft(_ draft: Draft) async throws -> Draft { draft }
    func fetchDrafts(userId _: String) async throws -> [Draft] { [] }
    func loadDraft(draftId _: String) async throws -> Draft { throw FirestoreServiceError.notFound }
    func deleteDraft(draftId _: String) async throws {}
    func updateUser(_ user: User) async throws -> User { user }
    func updateEditTools(userId _: String, tools _: [EditTool], order _: [String]) async throws {}
    func syncPostsCount(userId _: String, count _: Int) async throws {}
    func fetchPublicProfile(userId _: String) async throws -> PublicProfile { throw FirestoreServiceError.notFound }
    func updatePublicProfile(_: PublicProfile) async throws {}
    func createPublicProfile(from _: User) async throws {}
    func deleteUserData(userId _: String) async throws {}
    func reportPost(postId _: String, reporterId _: String, reportedUserId _: String, reason _: String) async throws {}
    func blockUser(userId _: String, blockedUserId _: String) async throws {}
    func unblockUser(userId _: String, blockedUserId _: String) async throws {}
    func fetchBlockedUserIds(userId _: String) async throws -> [String] { [] }
    func searchByHashtag(_: String) async throws -> [Post] { [] }
    func searchByColor(_: String, threshold _: Double?) async throws -> [Post] { [] }
    func searchByTimeOfDay(_: TimeOfDay) async throws -> [Post] { [] }
    func searchBySkyType(_: SkyType) async throws -> [Post] { [] }
    func searchPosts(
        hashtag _: String?,
        color _: String?,
        timeOfDay _: TimeOfDay?,
        skyType _: SkyType?,
        colorThreshold _: Double?,
        limit _: Int
    ) async throws -> [Post] { [] }
}

// MARK: - Mock SkyMaskProvider（ワンタップ空補正: レビュー keep 対応 #7）

/// テスト用の空マスクプロバイダ。`delayNanoseconds` を設定すると `makeSkyMask` 内で
/// `Task.sleep` してから結果を返す（`ensureSkyMaskCached` のレース条件テスト用）。
/// `coverage`/`confidence` を個別に差し替えられるようにし、しきい値未満のケースも
/// 再現できるようにする。
final class MockSkyMaskProvider: SkyMaskProviderProtocol {
    var delayNanoseconds: UInt64 = 0
    var coverage: Double = 0.5
    var confidence: Double = 0.5
    /// makeSkyMask が呼ばれた回数（キャッシュ再利用の検証に使う）
    private(set) var callCount = 0

    func makeSkyMask(for image: CIImage, quality _: SkyMaskQuality) async throws -> SkyMask {
        callCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        // このテストではマスクの中身自体は検証対象外のため単色の白マスクで代用する
        let mask = CIImage(color: CIColor.white).cropped(to: image.extent)
        return SkyMask(mask: mask, skyCoverage: coverage, confidence: confidence)
    }
}
