//
//  EditScopeTests.swift
//  SoramoyouTests
//
//  ⭐️ 編集の適用範囲（EditRecipe.editScope = .skyOnly / .whole）のユニットテスト
//
//  上下2色に塗り分けた合成画像と、上半分だけ白の合成マスクを入力し、
//  「空だけ」スコープで地上の画素が保たれることを検証する。
//
//  ⚠️ 検証の作法: 「地上が変わらない」という pass は、
//     ①スコープが正しく効いている ②そもそも計測が効いていない
//     の2通りに読めるため、pass だけでは区別できない。
//     そこで各テストで**先に陽性対照**（`.whole` では地上が確かに変わること）を
//     確認してから、`.skyOnly` で変わらないことを確認する。
//

import CoreImage
import CoreImage.CIFilterBuiltins
@testable import Soramoyou
import UIKit
import XCTest

final class EditScopeTests: XCTestCase {
    /// テスト内で使い回す CIContext（1個生成して再利用）
    private let context = CIContext()

    /// 合成画像のサイズ（フェザー半径＝短辺×0.01 が 2.56px になる大きさ）
    private static let imageSize = CGSize(width: 256, height: 256)

    // MARK: - Helpers

    /// 上=空色・下=地上色に塗り分けた CIImage を生成する
    /// （`SkyMaskProviderTests.makeTwoBandImage` と同型。テストターゲット内で
    ///   private ヘルパーを共有できないため、同じパターンをこのファイルにも持つ）
    private func makeTwoBandImage(top: UIColor, bottom: UIColor) -> CIImage {
        let size = Self.imageSize
        // ⚠️ UIGraphicsImageRenderer は既定で端末倍率（2x/3x）で描画するため、scale=1 に
        // 固定しないと「指定サイズ」と「実ピクセルサイズ」がズレる（256指定でも 3x なら 768px）。
        // サンプリング領域（skyBand / groundBand）を `imageSize` 基準で計算しているので、
        // ここを固定しないと測る場所が画像の別の場所になる（`SkyReplacementCompositorTests` と同じ理由）。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { rendererContext in
            top.setFill()
            rendererContext.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            bottom.setFill()
            rendererContext.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
        return CIImage(image: uiImage)!
    }

    /// 上半分=白(空)・下半分=黒(非空) のマスクを生成する。
    /// `SkyMaskProviderProtocol` が返すマスクと同じ規約（1.0=空）。
    private func makeTopHalfSkyMask() -> CIImage {
        makeTwoBandImage(top: .white, bottom: .black)
    }

    /// 指定領域の平均 RGB（各 0...1）を取得する。
    /// - Note: CIImage の座標系は y=0 が**下端**（UIKit と上下逆）。
    ///   「画像の上端バンド」は y が大きい側になる。
    private func averageRGB(_ image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect

        guard let outputImage = filter.outputImage,
              let cgImage = context.createCGImage(outputImage, from: CGRect(x: 0, y: 0, width: 1, height: 1))
        else {
            XCTFail("areaAverage の CGImage 化に失敗")
            return (0, 0, 0)
        }

        var pixelData = [UInt8](repeating: 0, count: 4)
        guard let pixelContext = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            XCTFail("CGContext 生成に失敗")
            return (0, 0, 0)
        }
        pixelContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return (
            Double(pixelData[0]) / 255.0,
            Double(pixelData[1]) / 255.0,
            Double(pixelData[2]) / 255.0
        )
    }

    /// 2色の距離（チャンネルごとの差の最大値）
    private func maxChannelDelta(
        _ a: (r: Double, g: Double, b: Double),
        _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))
    }

    /// 画像の上端バンド（＝空側）。フェザーの影響を避けるため境界から十分離す。
    private var skyBand: CGRect {
        let s = Self.imageSize
        return CGRect(x: 0, y: s.height * 0.75, width: s.width, height: s.height * 0.20)
    }

    /// 画像の下端バンド（＝地上側）。フェザーの影響を避けるため境界から十分離す。
    private var groundBand: CGRect {
        let s = Self.imageSize
        return CGRect(x: 0, y: s.height * 0.05, width: s.width, height: s.height * 0.20)
    }

    /// サンプリング領域が実 extent 基準になっていることを確認する。
    ///
    /// `skyBand` / `groundBand` は `imageSize`（論理サイズ）で計算しているため、
    /// 実 extent がそれと違うと「空を測っているつもりで地上を測る」事故になる
    /// （実際にこのファイルの初版で踏んだ。原因は renderer の scale 未固定）。
    private func assertExtentMatchesImageSize(_ image: CIImage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            image.extent.size, Self.imageSize,
            "合成画像の実 extent が imageSize と一致していない。サンプリング領域の計算が破綻する",
            file: file, line: line
        )
    }

    /// 「効きが目に見える」強い編集レシピ（彩度を抜いてグレースケール化する）。
    /// 微妙な編集だと閾値の較正が必要になるため、はっきり差が出るものを使う。
    private func makeStrongRecipe(scope: EditScope?) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.saturationCI = 0.0 // 完全に彩度を抜く（中立は 1.0）
        recipe.editScope = scope
        return recipe
    }

    /// 変化量のしきい値。合成画像＋彩度0の編集は色が大きく動くので、
    /// 8bit 量子化やフィルタ実装差より十分大きい値を「変化あり」の基準にする。
    private static let changedThreshold: Double = 0.05
    /// 「変化なし」の許容値（8bit 量子化・色空間往復の丸め誤差を吸収する）
    private static let unchangedTolerance: Double = 0.01

    // MARK: - Tests

    /// 「空だけ」スコープでは、地上の画素が編集前のまま保たれる。
    ///
    /// 陽性対照つき: 同じレシピを `.whole` で掛けたときに地上が**確かに変わる**ことを
    /// 先に確認し、計測（areaAverage による画素サンプリング）が効いていることを立証してから、
    /// `.skyOnly` で変わらないことを確認する。
    func test_skyOnlyScope_leavesGroundUnchanged() throws {
        let source = makeTwoBandImage(
            top: UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1), // 青空
            bottom: UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1) // 地面の茶色
        )
        let mask = makeTopHalfSkyMask()
        assertExtentMatchesImageSize(source)
        assertExtentMatchesImageSize(mask)
        let groundBefore = averageRGB(source, in: groundBand)

        // ── 陽性対照: `.whole` なら地上は確かに変わる ──
        let wholeResult = FilterGraphBuilder.buildGraph(
            recipe: makeStrongRecipe(scope: .whole),
            source: source,
            skyMask: mask
        )
        let groundAfterWhole = averageRGB(wholeResult, in: groundBand)
        let wholeDelta = maxChannelDelta(groundBefore, groundAfterWhole)
        XCTAssertGreaterThan(
            wholeDelta, Self.changedThreshold,
            """
            陽性対照が取れていない: `.whole` でも地上が変化していない（delta=\(wholeDelta)）。
            この場合、下の `.skyOnly` の pass は「スコープが効いている」証拠にならないため、
            まず計測方法（サンプリング領域・レシピの効き）を疑うこと。
            """
        )

        // ── 本題: `.skyOnly` なら地上は変わらない ──
        let skyOnlyResult = FilterGraphBuilder.buildGraph(
            recipe: makeStrongRecipe(scope: .skyOnly),
            source: source,
            skyMask: mask
        )
        let groundAfterSkyOnly = averageRGB(skyOnlyResult, in: groundBand)
        let skyOnlyDelta = maxChannelDelta(groundBefore, groundAfterSkyOnly)
        XCTAssertLessThan(
            skyOnlyDelta, Self.unchangedTolerance,
            "「空だけ」スコープなのに地上が変化している（delta=\(skyOnlyDelta)）"
        )
    }

    /// 「空だけ」スコープでも、空の領域にはちゃんと編集が効く。
    /// （地上が変わらないだけでは「何も適用されていない」可能性を否定できないため対で検証する）
    func test_skyOnlyScope_stillAppliesToSky() throws {
        let source = makeTwoBandImage(
            top: UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1),
            bottom: UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        )
        let mask = makeTopHalfSkyMask()
        assertExtentMatchesImageSize(source)
        assertExtentMatchesImageSize(mask)
        let skyBefore = averageRGB(source, in: skyBand)

        let result = FilterGraphBuilder.buildGraph(
            recipe: makeStrongRecipe(scope: .skyOnly),
            source: source,
            skyMask: mask
        )
        let skyAfter = averageRGB(result, in: skyBand)
        let delta = maxChannelDelta(skyBefore, skyAfter)
        XCTAssertGreaterThan(
            delta, Self.changedThreshold,
            "「空だけ」スコープで空にも編集が効いていない（delta=\(delta)）＝マスク合成の向きが逆の疑い"
        )
    }

    /// マスクが渡されない場合、「空だけ」スコープは全体経路へフォールバックする（意図的な挙動）。
    ///
    /// この挙動に依存して、呼び出し側（`EditViewModel`）は
    /// 「マスクが取れなかったらレシピの `editScope` も nil に戻す」責任を負う。
    /// 挙動を変えるときは `EditViewModel` 側のフォールバックも必ず一緒に見直すこと。
    func test_skyOnlyScope_withoutMask_fallsBackToWholeImage() throws {
        let source = makeTwoBandImage(
            top: UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1),
            bottom: UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        )

        let withoutMask = FilterGraphBuilder.buildGraph(
            recipe: makeStrongRecipe(scope: .skyOnly),
            source: source,
            skyMask: nil
        )
        let whole = FilterGraphBuilder.buildGraph(
            recipe: makeStrongRecipe(scope: .whole),
            source: source,
            skyMask: nil
        )

        let groundWithoutMask = averageRGB(withoutMask, in: groundBand)
        let groundWhole = averageRGB(whole, in: groundBand)
        XCTAssertLessThan(
            maxChannelDelta(groundWithoutMask, groundWhole), Self.unchangedTolerance,
            "マスク無しの `.skyOnly` は全体経路と同じ結果になるはず"
        )
    }

    /// 「空だけ」スコープが、全体に掛かる仕上げステップ（クロップ・ワンタップ空補正）と
    /// 同時に指定されても破綻しないこと。
    ///
    /// `.skyOnly` 経路は派生レシピでこの3つ（HDR・空補正・クロップ）を nil にしてから
    /// 再帰し、合成後に `applyGlobalTail` で全体へ掛け直す設計。
    /// 設計上いちばん絡む組み合わせなので、明示的に通しておく。
    func test_skyOnlyScope_composesWithCropAndSkyCorrection() throws {
        let source = makeTwoBandImage(
            top: UIColor(red: 0.35, green: 0.55, blue: 0.90, alpha: 1),
            bottom: UIColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1)
        )
        let mask = makeTopHalfSkyMask()
        assertExtentMatchesImageSize(source)

        var recipe = makeStrongRecipe(scope: .skyOnly)
        recipe.skyCorrectionIntensity = 0.7                                  // 全体経路で空にだけ効く
        recipe.cropRectNorm = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.5) // 上半分＝空側だけ残す

        let result = FilterGraphBuilder.buildGraph(recipe: recipe, source: source, skyMask: mask)

        // クロップが最終 extent に効いている（＝ `applyGlobalTail` まで到達している）
        XCTAssertEqual(
            result.extent.height, Self.imageSize.height * 0.5, accuracy: 1.0,
            "クロップが最終出力に反映されていない（全体に掛ける仕上げステップに到達していない疑い）"
        )
        XCTAssertEqual(result.extent.width, Self.imageSize.width, accuracy: 1.0)

        // 実体化できる（フィルタグラフが壊れていない）
        XCTAssertNotNil(
            context.createCGImage(result, from: result.extent),
            "「空だけ」＋クロップ＋空補正の組み合わせでグラフの実体化に失敗した"
        )
    }

    /// `editScope` を持たない旧レシピ（Firestore の既存ドキュメント）が読めること。
    /// nil は `.whole`（全体）として解釈される。
    func test_legacyRecipeWithoutEditScope_decodesAsWholeScope() throws {
        // `editScope` キーを持たない Firestore データ（1.10.1 以前の全ドキュメントがこの形）
        let legacyData: [String: Any] = [
            "schemaVersion": 1,
            "saturationCI": 1.5,
        ]
        let recipe = try XCTUnwrap(EditRecipe(from: legacyData), "旧レシピのデコードに失敗した")

        XCTAssertNil(recipe.editScope, "editScope キーが無い旧レシピは nil になる")
        XCTAssertFalse(recipe.isSkyOnlyScope, "nil は「全体」として解釈される")
    }

    /// 未知の `editScope` 文字列（将来スコープの追加・データ破損）は全体にフォールバックする。
    func test_unknownEditScopeString_fallsBackToWholeScope() throws {
        let data: [String: Any] = [
            "schemaVersion": 1,
            "editScope": "groundOnly", // 未知の値
        ]
        let recipe = try XCTUnwrap(EditRecipe(from: data))

        XCTAssertNil(recipe.editScope, "未知の文字列は nil（全体）に落ちる")
    }

    /// `editScope` が Firestore へ往復しても保たれること（`.skyOnly` の永続化）。
    func test_editScope_roundTripsThroughFirestoreData() throws {
        var recipe = EditRecipe()
        recipe.editScope = .skyOnly

        let data = recipe.toFirestoreData()
        XCTAssertEqual(data["editScope"] as? String, "skyOnly")

        let restored = try XCTUnwrap(EditRecipe(from: data))
        XCTAssertEqual(restored.editScope, .skyOnly)
    }

    /// 空マスクが使えない描画経路（サムネイル生成）では、空マスク依存フィールドが揃って落ちること。
    ///
    /// `skyCorrectionIntensity` だけ落として `editScope` を残すと、
    /// 「レシピは空だけ・見た目は全体」のサムネイルになり、本適用と食い違う。
    func test_mergingPhotoSpecificFields_dropsSkyDependentFieldsWhenMaskUnavailable() throws {
        var current = EditRecipe()
        current.skyCorrectionIntensity = 0.7
        current.editScope = .skyOnly
        current.cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

        // サムネイル生成用（マスク無し）: 空マスク依存フィールドは揃って nil になる
        let forThumbnail = EditRecipe().mergingPhotoSpecificFields(from: current, skyMaskAvailable: false)
        XCTAssertNil(forThumbnail.skyCorrectionIntensity, "マスク無しでは空補正強度を転写しない")
        XCTAssertNil(forThumbnail.editScope, "マスク無しでは適用範囲を転写しない")
        XCTAssertEqual(forThumbnail.cropRectNorm, current.cropRectNorm, "クロップはマスクに依存しないので常に転写される")

        // 本適用用（マスクあり・既定）: 両方とも転写される
        let forApply = EditRecipe().mergingPhotoSpecificFields(from: current)
        XCTAssertEqual(forApply.skyCorrectionIntensity, 0.7)
        XCTAssertEqual(forApply.editScope, .skyOnly)
    }

    /// レシピ共有の種（`preparedAsSharedSeed`）からは適用範囲が落ちること。
    /// 受け手の写真は空の形も量も違うため、`.skyOnly` をそのまま渡すと別の領域に掛かる。
    func test_preparedAsSharedSeed_dropsEditScope() throws {
        var recipe = EditRecipe()
        recipe.editScope = .skyOnly
        recipe.saturationCI = 1.4

        let seed = recipe.preparedAsSharedSeed()
        XCTAssertNil(seed.editScope, "共有する種には適用範囲を含めない")
        XCTAssertEqual(seed.saturationCI, 1.4, "写真に依存しない編集値は保たれる")
    }

    /// 🔧 回帰テスト（レビュー指摘A）: レンズ補正は画素を**動かす**処理なので「空だけ」に包まず、
    /// 合成後に画像全体へ掛ける。包むと、マスク（歪める前の形）で「歪めた空」と「歪めていない地上」を
    /// 継ぎ合わせることになり、地平線や電線が境界で**ずれて切れる**。
    ///
    /// レンズ補正だけのレシピなら、`.skyOnly` と `.whole` は**画素単位で同じ**になるはず。
    /// 市松模様を使うのは、単色だと画素が動いても平均色が変わらず、ずれを検出できないため。
    ///
    /// 陽性対照: 先に「レンズ補正で地上の画素が確かに動く」ことを確認してから一致を見る。
    func test_skyOnlyScope_appliesLensCorrectionToWholeImage() throws {
        let size = Self.imageSize
        let checker = CIFilter.checkerboardGenerator()
        checker.center = .zero
        checker.color0 = CIColor(red: 1, green: 1, blue: 1)
        checker.color1 = CIColor(red: 0, green: 0, blue: 0)
        checker.width = 8
        let source = try XCTUnwrap(checker.outputImage)
            .cropped(to: CGRect(origin: .zero, size: size))

        var recipe = EditRecipe()
        recipe.lensCorrectionNorm = 1.0 // スライダー最大（-1...1）。歪みがはっきり出る値

        recipe.editScope = .whole
        let whole = FilterGraphBuilder.buildGraph(recipe: recipe, source: source, skyMask: nil)
        recipe.editScope = .skyOnly
        let skyOnly = FilterGraphBuilder.buildGraph(recipe: recipe, source: source, skyMask: makeTopHalfSkyMask())

        // 陽性対照: レンズ補正で地上の市松が確かに動いている（＝差分計測が効いている）
        let movedByLens = averageRGB(absoluteDifference(whole, source), in: groundBand)
        XCTAssertGreaterThan(
            maxChannelDelta(movedByLens, (0, 0, 0)), Self.changedThreshold,
            "陽性対照: レンズ補正で地上の画素が動いていない（計測が効いていない）"
        )

        // 本題: 地上側も空側と同じく歪んでいる＝全体経路と一致する。
        //
        // ⚠️ 絶対値ではなく「空側の差」を基準線にして比べる。空は修正の前後どちらでも両経路で歪めるので、
        //    空側の差は「処理経路の違いだけで出る誤差」になる。実測（2026-09-20・Mac の CoreImage で再現）では
        //    合成を1段挟むだけで白黒の境目の補間結果がリニア色空間ぶん変わり、空・地上とも約 0.04 ずれる
        //    （色管理を切ると 1/255 まで消える＝スコープとは無関係）。修正前は地上だけが約 0.73 ずれる。
        let skyDiff = maxChannelDelta(averageRGB(absoluteDifference(skyOnly, whole), in: skyBand), (0, 0, 0))
        let groundDiff = maxChannelDelta(averageRGB(absoluteDifference(skyOnly, whole), in: groundBand), (0, 0, 0))
        XCTAssertLessThan(
            groundDiff - skyDiff, Self.unchangedTolerance,
            "「空だけ」でレンズ補正が地上に掛かっていない（空と地上の境界で像がずれる）: ground=\(groundDiff) sky=\(skyDiff)"
        )
    }

    /// 2画像の画素ごとの差の絶対値（`CIDifferenceBlendMode`）
    private func absoluteDifference(_ a: CIImage, _ b: CIImage) -> CIImage {
        let filter = CIFilter.differenceBlendMode()
        filter.inputImage = a
        filter.backgroundImage = b
        return filter.outputImage ?? a
    }
}
