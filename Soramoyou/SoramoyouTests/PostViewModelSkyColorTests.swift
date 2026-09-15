//
//  PostViewModelSkyColorTests.swift
//  SoramoyouTests
//
//  ⭐️ 主要色・色温度を「空の部分から取るか／画像全体から取るか」の切り替えを検証する。
//  空マスクの被覆率 ≥0.05 かつ確信度 ≥0.3 のときだけ空マスクを ImageService に渡し、
//  それ以外（空が少ない・確信が低い・マスク生成に失敗）は nil を渡して画像全体から計算する。
//  抽出は `setSelectedImages(_:externalEditInfos:)` が起動する Task で行われるため、
//  `imageInfoExtractionTask` を await して完了を待つ。
//

import XCTest
import UIKit
import CoreImage
@testable import Soramoyou

@MainActor
final class PostViewModelSkyColorTests: XCTestCase {

    /// 8×8 のダミー画像（色の計算はモックが受けるので中身は問わない）
    private func dummyImage() -> UIImage {
        let size = CGSize(width: 8, height: 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 画像解析・分類器・空マスクをモックに差し替えた ViewModel と、検証用のモックを返す
    private func makeViewModel(
        coverage: Double = 0.5,
        confidence: Double = 0.5,
        shouldThrow: Bool = false
    ) -> (PostViewModel, MockImageService, MockSkyMaskProvider) {
        let imageService = MockImageService()
        let maskProvider = MockSkyMaskProvider()
        maskProvider.coverage = coverage
        maskProvider.confidence = confidence
        maskProvider.shouldThrow = shouldThrow
        let vm = PostViewModel(
            userId: "u1",
            imageService: imageService,
            firestoreService: MockFirestoreService(),
            skyTypeClassifier: SkyColorStubSkyTypeClassifier(),
            skyMaskProvider: maskProvider
        )
        return (vm, imageService, maskProvider)
    }

    /// 抽出 Task を起動し、完了まで待つ
    private func setImagesAndWait(_ vm: PostViewModel) async {
        vm.setSelectedImages([dummyImage()])
        await vm.imageInfoExtractionTask?.value
    }

    // MARK: - 閾値ゲート

    func testUsesSkyMaskWhenCoverageAndConfidenceAreEnough() async throws {
        let (vm, imageService, maskProvider) = makeViewModel(coverage: 0.5, confidence: 0.5)
        await setImagesAndWait(vm)

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertTrue(info.colorsFromSky, "被覆率・確信度が閾値以上なら空の部分から色を取る")
        XCTAssertEqual(imageService.lastExtractColorsHadSkyMask, true, "ImageService に空マスクが渡されている")
        XCTAssertEqual(imageService.lastColorTemperatureHadSkyMask, true, "色温度側にも同じ空マスクが渡されている")
        XCTAssertEqual(try XCTUnwrap(info.skyCoverage), 0.5, accuracy: 1e-9)
        XCTAssertEqual(maskProvider.callCount, 1, "マスク生成は抽出 1 回につき 1 回だけ")
        XCTAssertEqual(info.colorTemperature, 6500)
    }

    func testFallsBackToWholeImageWhenCoverageIsTooLow() async throws {
        let (vm, imageService, _) = makeViewModel(coverage: 0.01, confidence: 0.9)
        await setImagesAndWait(vm)

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertFalse(info.colorsFromSky, "空がほとんど写っていなければ画像全体から計算する")
        XCTAssertEqual(imageService.lastExtractColorsHadSkyMask, false, "マスクは渡さない（nil）")
        XCTAssertEqual(imageService.lastColorTemperatureHadSkyMask, false, "色温度側もマスクを渡さない")
        XCTAssertEqual(try XCTUnwrap(info.skyCoverage), 0.01, accuracy: 1e-9, "被覆率は計装用に記録する")
    }

    func testFallsBackToWholeImageWhenConfidenceIsTooLow() async throws {
        let (vm, imageService, _) = makeViewModel(coverage: 0.5, confidence: 0.1)
        await setImagesAndWait(vm)

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertFalse(info.colorsFromSky, "判定に確信が無ければ画像全体から計算する")
        XCTAssertEqual(imageService.lastExtractColorsHadSkyMask, false)
        XCTAssertEqual(imageService.lastColorTemperatureHadSkyMask, false, "色温度側もマスクを渡さない")
        XCTAssertEqual(try XCTUnwrap(info.skyCoverage), 0.5, accuracy: 1e-9)
    }

    /// review-full general keep: 閾値はちょうど 0.05 / 0.3 でも通す（`>=`）。境界値のテストが無いと
    /// `>` への書き換えを検知できない。
    func testUsesSkyMaskWhenCoverageAndConfidenceAreExactlyAtThreshold() async throws {
        let (vm, imageService, _) = makeViewModel(coverage: 0.05, confidence: 0.3)
        await setImagesAndWait(vm)

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertTrue(info.colorsFromSky, "被覆率・確信度がちょうど閾値なら空の部分から色を取る（>= のはず）")
        XCTAssertEqual(imageService.lastExtractColorsHadSkyMask, true)
        XCTAssertEqual(imageService.lastColorTemperatureHadSkyMask, true, "色温度側にも同じ空マスクが渡されている")
        XCTAssertEqual(try XCTUnwrap(info.skyCoverage), 0.05, accuracy: 1e-9)
    }

    /// 閾値のすぐ下（0.049 / 0.3 いずれか一方でも下回る）では画像全体にフォールバックする。
    func testFallsBackToWholeImageWhenJustBelowThreshold() async throws {
        let (vm, imageService, _) = makeViewModel(coverage: 0.049, confidence: 0.3)
        await setImagesAndWait(vm)

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertFalse(info.colorsFromSky, "被覆率が閾値をわずかに下回れば画像全体から計算する")
        XCTAssertEqual(imageService.lastExtractColorsHadSkyMask, false)
        XCTAssertEqual(imageService.lastColorTemperatureHadSkyMask, false)
    }

    func testMaskGenerationFailureStillCompletesExtraction() async throws {
        let (vm, imageService, _) = makeViewModel(shouldThrow: true)
        await setImagesAndWait(vm)

        let info = try XCTUnwrap(vm.extractedInfo, "マスク生成に失敗しても色・色温度の抽出は完了する")
        XCTAssertFalse(info.colorsFromSky)
        XCTAssertNil(info.skyCoverage, "マスクが無いので被覆率は記録しない")
        XCTAssertEqual(imageService.lastExtractColorsHadSkyMask, false, "解析用画像はあるのでマスク無しで CIImage 版を呼ぶ")
        XCTAssertEqual(imageService.lastColorTemperatureHadSkyMask, false, "色温度側もマスク無しで呼ぶ")
        XCTAssertFalse(info.skyColors.isEmpty)
    }

    // MARK: - 解析用画像（向きの焼き込み）

    /// 縦撮り（`.right`）の写真は、向きを焼き込んだ縦長・origin (0,0) の画像としてマスク生成に渡る。
    /// 焼き込まないと、空マスク provider（`.up` 前提）が横倒しの画像を解析し、空の位置を取り違える。
    func testRightOrientedImageIsBakedBeforeSkyMask() async throws {
        let (vm, _, maskProvider) = makeViewModel()
        // 画素は 16×8（横長）、表示は `.right` で 8×16（縦長）
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 8), format: format).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        }
        let cgImage = try XCTUnwrap(landscape.cgImage)
        let portrait = UIImage(cgImage: cgImage, scale: 1, orientation: .right)

        vm.setSelectedImages([portrait])
        await vm.imageInfoExtractionTask?.value

        let extent = try XCTUnwrap(maskProvider.lastImageExtent)
        XCTAssertEqual(extent.size, CGSize(width: 8, height: 16), "表示どおりの縦長で渡す")
        XCTAssertEqual(extent.origin, .zero, "`.oriented` で非ゼロになりうる origin を (0,0) に揃える")
    }

    // MARK: - 空タイプ選択で再構築しても計装値を落とさない

    func testSkyTypeSelectionKeepsSkyColorInstrumentation() async throws {
        let (vm, _, _) = makeViewModel(coverage: 0.42, confidence: 0.8)
        await setImagesAndWait(vm)

        vm.selectSkyType(.sunset)

        let info = try XCTUnwrap(vm.extractedInfo)
        XCTAssertEqual(info.skyType, .sunset)
        XCTAssertTrue(info.colorsFromSky, "extractedInfo を再構築しても colorsFromSky を引き継ぐ")
        XCTAssertEqual(try XCTUnwrap(info.skyCoverage), 0.42, accuracy: 1e-9, "同じく skyCoverage も引き継ぐ")
    }
}

// MARK: - Stub SkyTypeClassifier

/// 常に `.clear` を返す分類器。抽出 Task を Vision 依存なしで完走させるためのスタブ。
/// （`PostViewModelCapturedAtTests` のスタブは private のため、このファイル用に同型を持つ）
private final class SkyColorStubSkyTypeClassifier: SkyTypeClassifierProtocol {
    func classify(_: UIImage, timeOfDay: TimeOfDay?) async throws -> SkyTypeClassificationResult {
        SkyTypeClassificationResult(
            skyType: .clear,
            confidence: 1.0,
            dominantColors: [],
            usedTimeOfDay: timeOfDay != nil,
            details: "stub"
        )
    }
}
