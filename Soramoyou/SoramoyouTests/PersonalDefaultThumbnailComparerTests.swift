//
//  PersonalDefaultThumbnailComparerTests.swift
//  SoramoyouTests
//
//  ⭐️ パーソナルAI編集（柱1 v2）の純関数テスト:
//  「AIで自動編集」候補シートの重複判定を実画像の知覚差で行う
//  PersonalDefaultThumbnailComparer の仕様検証。
//
//  ⚠️ 実測値と閾値(distinctThreshold=3.7・2026-08-04 較正)の関係が変わった場合に
//  気付けるよう、実レンダリング回帰テストでは meanAbsoluteDifference の実値を必ず print する。
//  期待どおりの結果にならなかった場合、このテスト側で distinctThreshold を
//  勝手に動かしてグリーンにするのではなく、実測値と期待の食い違いをそのまま報告する
//  （distinctThreshold の最終決定は呼び出し元が行う）。
//

@testable import Soramoyou
import UIKit
import XCTest

final class PersonalDefaultThumbnailComparerTests: XCTestCase {
    // MARK: - 基本ケース

    /// 同一画像同士を比較すると差はほぼ0で、distinct とは判定されない。
    func testMeanAbsoluteDifference_identicalImages_isZeroAndNotDistinct() {
        let image = makeSyntheticSkyImage(size: CGSize(width: 64, height: 64))

        let diff = PersonalDefaultThumbnailComparer.meanAbsoluteDifference(image, image)
        print("🔍 [同一画像] meanAbsoluteDifference=\(diff)")

        XCTAssertEqual(diff, 0, accuracy: 0.01, "同一画像の差分は0のはず")
        XCTAssertFalse(
            PersonalDefaultThumbnailComparer.isVisuallyDistinct(image, from: [image]),
            "同一画像は区別できないはず"
        )
    }

    /// 真っ黒 vs 真っ白は全チャンネルが最大差(255)になるため、差は200以上・distinct と判定される。
    func testMeanAbsoluteDifference_blackVsWhite_isAboveThresholdAndDistinct() {
        let black = makeSolidColorImage(.black, size: CGSize(width: 64, height: 64))
        let white = makeSolidColorImage(.white, size: CGSize(width: 64, height: 64))

        let diff = PersonalDefaultThumbnailComparer.meanAbsoluteDifference(black, white)
        print("🔍 [黒 vs 白] meanAbsoluteDifference=\(diff)")

        XCTAssertGreaterThanOrEqual(diff, 200, "黒vs白は最大級の差分になるはず")
        XCTAssertTrue(
            PersonalDefaultThumbnailComparer.isVisuallyDistinct(white, from: [black]),
            "黒vs白は明確に区別できるはず"
        )
    }

    // MARK: - 実レンダリング回帰テスト（最重要）

    //
    // 2026-08-04 に distinctThreshold を実測較正（20 → 3.7）した際の根拠データに基づく
    // 回帰テスト群。較正の詳細（3画像×全条件マトリクス、有効レンジ (3.25, 4.16] の算出根拠）は
    // `PersonalDefaultThumbnailComparer.distinctThreshold` の doc コメントを参照。
    // 実測は一時ファイル TEMP_ThumbnailComparerCalibrationTests（test_sim・実測後に削除済み）で
    // 行い、以下の3テストはその実測のうち「将来壊れたら気づきたい境界」だけを抜き出したもの。

    /// 固定プリセット4種（vivid/warm/cool/drama）は必ず distinct と判定される
    /// （＝候補シートから消えて埋まらなくなる、という事故を防ぐ回帰）。
    ///
    /// 較正時、①明るい青空+雲の画像で filter=cool の diff=4.16 が「distinctになるべき」
    /// 4条件の中で最も閾値(3.7)に近い（最も厳しい）値だったため、その画像を再利用する。
    /// `.natural` はフィルタなしと恒等（下記 `testRealRendering_naturalFilterIsIdenticalToNoFilter`
    /// 参照）のためここでは対象外。
    func testRealRendering_fixedPresets_fourRealFiltersAreDistinct() async throws {
        let imageService = ImageService()
        let sourceImage = makeSyntheticSkyImage()

        var baseRecipe = EditRecipe()
        baseRecipe.exposureEV = 0.3
        baseRecipe.saturationCI = 1.15
        baseRecipe.contrastCI = 1.05

        let baseImage = try await imageService.applyEditRecipe(baseRecipe, to: sourceImage)

        for filter: FilterType in [.vivid, .warm, .cool, .drama] {
            var variant = baseRecipe
            variant.appliedFilter = filter
            let variantImage = try await imageService.applyEditRecipe(variant, to: sourceImage)
            let diff = PersonalDefaultThumbnailComparer.meanAbsoluteDifference(baseImage, variantImage)

            print("🔍 [実レンダリング] filter=\(filter.rawValue) diff=\(diff) (閾値=\(PersonalDefaultThumbnailComparer.distinctThreshold))")

            XCTAssertTrue(
                PersonalDefaultThumbnailComparer.isVisuallyDistinct(variantImage, from: [baseImage]),
                "filter=\(filter.rawValue) は見分けがつくはずなのに not distinct と判定された (diff=\(diff))"
            )
        }
    }

    /// warmthNorm+0.10 / saturationCI+0.08 の微差は distinct と判定されない
    /// （＝ほぼ同じ見た目の候補が誤って複数並ぶ、という事故を防ぐ回帰）。
    ///
    /// 較正時、②夕焼けグラデーションの画像で saturationCI+0.08 の diff=3.25 が
    /// 「not distinctになるべき」条件の中で最も閾値(3.7)に近い（最も厳しい）値だったため、
    /// その画像を再利用する。
    func testRealRendering_microDiffs_areNotDistinct() async throws {
        let imageService = ImageService()
        let sourceImage = makeSunsetGradientImage()

        var baseRecipe = EditRecipe()
        baseRecipe.exposureEV = 0.3
        baseRecipe.saturationCI = 1.15
        baseRecipe.contrastCI = 1.05

        var warmthVariant = baseRecipe
        warmthVariant.warmthNorm = 0.10

        var saturationVariant = baseRecipe
        saturationVariant.saturationCI += 0.08

        let baseImage = try await imageService.applyEditRecipe(baseRecipe, to: sourceImage)
        let warmthImage = try await imageService.applyEditRecipe(warmthVariant, to: sourceImage)
        let saturationImage = try await imageService.applyEditRecipe(saturationVariant, to: sourceImage)

        let warmthDiff = PersonalDefaultThumbnailComparer.meanAbsoluteDifference(baseImage, warmthImage)
        let saturationDiff = PersonalDefaultThumbnailComparer.meanAbsoluteDifference(baseImage, saturationImage)

        print("🔍 [実レンダリング] warmthNorm+0.10 diff=\(warmthDiff) (閾値=\(PersonalDefaultThumbnailComparer.distinctThreshold))")
        print("🔍 [実レンダリング] saturationCI+0.08 diff=\(saturationDiff) (閾値=\(PersonalDefaultThumbnailComparer.distinctThreshold))")

        XCTAssertFalse(
            PersonalDefaultThumbnailComparer.isVisuallyDistinct(warmthImage, from: [baseImage]),
            "warmthNorm+0.10 は見分けがつかないはずなのに distinct と判定された (diff=\(warmthDiff))"
        )
        XCTAssertFalse(
            PersonalDefaultThumbnailComparer.isVisuallyDistinct(saturationImage, from: [baseImage]),
            "saturationCI+0.08 は見分けがつかないはずなのに distinct と判定された (diff=\(saturationDiff))"
        )
    }

    /// `.natural` フィルタは「フィルタなしの基準レシピ」と常に meanAbsoluteDifference=0 になり、
    /// distinct とは判定されない。
    ///
    /// これは較正の結果ではなく、`FilterGraphBuilder.applyFilter(_:to:)` の `.natural` ケース
    /// （`FilterGraphBuilder.swift:412-413`、`case .natural: return image`）が**恒等変換**である
    /// という構造的事実による（どんな画像・どんな閾値でも必ず0.0になる）。
    /// 実際の候補プールでは `FixedPresetKind.natural.recipe` は常に完全に中立な `EditRecipe()` であり、
    /// 他候補（あなたの定番等）は `EditRecipe.isNeutral` のコーパス書き込み時ゲートにより中立値と
    /// 一致することが実質的にないため、実運用でこの重複が発生することは想定していない。
    /// このテストは「もし将来 `.natural` の実装が恒等変換でなくなった／同一フィールド値の
    /// フィルタなし候補と共存するようになった」場合に気付けるようにするための tripwire。
    func testRealRendering_naturalFilterIsIdenticalToNoFilter_notDistinct() async throws {
        let imageService = ImageService()
        let sourceImage = makeSyntheticSkyImage()

        var baseRecipe = EditRecipe()
        baseRecipe.exposureEV = 0.3
        baseRecipe.saturationCI = 1.15
        baseRecipe.contrastCI = 1.05

        var naturalVariant = baseRecipe
        naturalVariant.appliedFilter = .natural

        let baseImage = try await imageService.applyEditRecipe(baseRecipe, to: sourceImage)
        let naturalImage = try await imageService.applyEditRecipe(naturalVariant, to: sourceImage)

        let diff = PersonalDefaultThumbnailComparer.meanAbsoluteDifference(baseImage, naturalImage)
        print("🔍 [実レンダリング] filter=natural diff=\(diff) (恒等変換のため常に0.0のはず)")

        XCTAssertEqual(diff, 0, accuracy: 0.01, ".natural は恒等変換のため差分は0のはず")
        XCTAssertFalse(
            PersonalDefaultThumbnailComparer.isVisuallyDistinct(naturalImage, from: [baseImage]),
            ".natural はフィルタなしと恒等のはずなのに distinct と判定された (diff=\(diff))"
        )
    }

    // MARK: - Helper

    /// 「AIで自動編集」候補比較の回帰テストで使う、空っぽい合成写真を生成する。
    /// 単色ではなく上(濃い青空)→下(白っぽい霞)のグラデーション＋雲相当の白い矩形を敷くことで、
    /// 露出・彩度・フィルタなど編集の効きがそれらしく画素値へ反映される「空写真らしさ」を模する
    /// （単色画像だと明暗差が一様にしか出ず、実写真での知覚差の検証にならないため）。
    private func makeSyntheticSkyImage(size: CGSize = CGSize(width: 300, height: 300)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            let colors = [
                UIColor(red: 0.25, green: 0.45, blue: 0.85, alpha: 1.0).cgColor,
                UIColor(red: 0.80, green: 0.87, blue: 0.95, alpha: 1.0).cgColor,
            ]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors as CFArray,
                locations: [0, 1]
            ) else {
                XCTFail("テスト用グラデーションの生成に失敗")
                return
            }
            cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )

            // 雲相当の矩形を2つ敷く（グラデーションだけだと露出・彩度・フィルタの効きが
            // 単調すぎて、実写真に近い知覚差の検証にならないため）
            UIColor.white.withAlphaComponent(0.85).setFill()
            rendererContext.fill(CGRect(
                x: size.width * 0.10, y: size.height * 0.30,
                width: size.width * 0.40, height: size.height * 0.15
            ))
            rendererContext.fill(CGRect(
                x: size.width * 0.55, y: size.height * 0.55,
                width: size.width * 0.30, height: size.height * 0.12
            ))
        }
    }

    /// 夕焼け相当の暖色グラデーション（オレンジ→ピンク→紫 + 太陽相当の高輝度円）。
    /// 較正時、この画像で saturationCI+0.08 の diff が3画像中最大（＝最も閾値に近い）
    /// だったため、`testRealRendering_microDiffs_areNotDistinct` の回帰対象として採用する。
    private func makeSunsetGradientImage(size: CGSize = CGSize(width: 300, height: 300)) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            let colors = [
                UIColor(red: 0.95, green: 0.45, blue: 0.15, alpha: 1.0).cgColor, // 濃いオレンジ
                UIColor(red: 0.90, green: 0.55, blue: 0.55, alpha: 1.0).cgColor, // ピンク
                UIColor(red: 0.45, green: 0.30, blue: 0.55, alpha: 1.0).cgColor, // 紫
            ]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors as CFArray,
                locations: [0, 0.5, 1]
            ) else {
                XCTFail("テスト用グラデーションの生成に失敗")
                return
            }
            cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )

            // 太陽相当の明るい円（夕焼け写真らしい高輝度領域を作る）
            UIColor(red: 1.0, green: 0.85, blue: 0.55, alpha: 0.9).setFill()
            let sunRect = CGRect(
                x: size.width * 0.35, y: size.height * 0.35,
                width: size.width * 0.30, height: size.width * 0.30
            )
            rendererContext.cgContext.fillEllipse(in: sunRect)
        }
    }

    /// 単色のテスト画像を生成する（基本ケースの黒/白比較用）。
    private func makeSolidColorImage(_ color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
