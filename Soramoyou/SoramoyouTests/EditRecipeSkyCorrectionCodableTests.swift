//
//  EditRecipeSkyCorrectionCodableTests.swift
//  SoramoyouTests
//
//  ⭐️ EditRecipe.skyCorrectionIntensity（ワンタップ空補正）の符号化・復号テスト。
//
//  ⚠️ 設計メモ: `skyCorrectionIntensity` は仕様上「Double（既定0）」だったが、実装時に
//  `EditRecipe` の `Codable` 適合がコンパイラ合成であることを確認したところ、
//  非 Optional プロパティは「宣言時のデフォルト値があってもキー欠落で `keyNotFound` を
//  throw する」ことが判明した（`= 0` はメンバワイズイニシャライザにのみ効き、
//  合成デコーダには効かない。実機で `JSONDecoder().decode` を使い検証済み）。
//  これは EditRecipe の brillianceNorm 以降の全フィールドが Optional である理由と同じで、
//  旧下書き JSON にこのキーが存在しない以上、Optional にしないと後方互換が壊れる。
//  そのため型は `Double?` とし、nil を「未適用（0相当）」として扱う設計にした。
//  本ファイルの `testDecodingLegacyJSONWithoutKeyYieldsNil` がその根拠を示すテスト。
//

import XCTest
@testable import Soramoyou

final class EditRecipeSkyCorrectionCodableTests: XCTestCase {

    // MARK: - JSON (Codable) 往復

    /// skyCorrectionIntensity を設定した EditRecipe が JSON 往復で値を保持することを確認する
    func testJSONRoundTripPreservesValue() throws {
        var recipe = EditRecipe()
        recipe.skyCorrectionIntensity = 0.7

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)

        XCTAssertEqual(decoded.skyCorrectionIntensity, 0.7)
    }

    /// skyCorrectionIntensity が nil（未適用）のまま JSON 往復しても nil を維持することを確認する
    func testJSONRoundTripPreservesNil() throws {
        let recipe = EditRecipe()
        XCTAssertNil(recipe.skyCorrectionIntensity)

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)

        XCTAssertNil(decoded.skyCorrectionIntensity)
    }

    /// 【後方互換の要】`skyCorrectionIntensity` キーが存在しない旧下書き JSON をデコードしても
    /// 例外を投げず、nil（未適用）として読み込めることを確認する。
    ///
    /// このテストが失敗する（= throw する）ようなら、フィールドを非 Optional に戻してはいけない
    /// というシグナルである（コメント冒頭の設計メモ参照）。
    func testDecodingLegacyJSONWithoutKeyYieldsNil() throws {
        // 意図的に skyCorrectionIntensity キーを含まない、機能追加前の EditRecipe 相当の JSON。
        let legacyJSON = """
        {
            "schemaVersion": 1,
            "recipeVersion": "2026.03",
            "exposureEV": 0.5,
            "brightnessCI": 0,
            "contrastCI": 1.1,
            "gamma": 1.0,
            "highlights": 1.0,
            "shadowAmount": 1.0,
            "blackPointBias": 0,
            "saturationCI": 1.2
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(EditRecipe.self, from: legacyJSON)

        XCTAssertNil(decoded.skyCorrectionIntensity, "旧下書きJSONにキーが無い場合は nil（未適用）として読み込む必要がある")
        // 他の既存フィールドも正しく読めていることを合わせて確認（デコード自体が壊れていないか）
        XCTAssertEqual(decoded.exposureEV, 0.5)
        XCTAssertEqual(decoded.contrastCI, 1.1)
    }

    // MARK: - Firestore 辞書変換往復

    /// skyCorrectionIntensity を設定した EditRecipe が Firestore 辞書往復で値を保持することを確認する
    func testFirestoreRoundTripPreservesValue() throws {
        var recipe = EditRecipe()
        recipe.skyCorrectionIntensity = 0.42

        let data = recipe.toFirestoreData()
        XCTAssertEqual(data["skyCorrectionIntensity"] as? Double, 0.42)

        let decoded = try XCTUnwrap(EditRecipe(from: data))
        XCTAssertEqual(decoded.skyCorrectionIntensity, 0.42)
    }

    /// skyCorrectionIntensity 未設定（nil）の EditRecipe は Firestore 辞書にキー自体を含めないことを確認する
    /// （`toFirestoreData()` の Optional フィールドの既存流儀: 未設定は「キーを書かない」）
    func testFirestoreRoundTripOmitsKeyWhenNil() throws {
        let recipe = EditRecipe()
        let data = recipe.toFirestoreData()

        XCTAssertNil(data["skyCorrectionIntensity"], "未設定なら Firestore 辞書にキー自体を含めない")

        let decoded = try XCTUnwrap(EditRecipe(from: data))
        XCTAssertNil(decoded.skyCorrectionIntensity)
    }

    /// 【後方互換】skyCorrectionIntensity キーを含まない旧 Firestore ドキュメント（辞書）を
    /// 読み込んでも nil（未適用）になることを確認する。
    func testFirestoreDecodingLegacyDictWithoutKeyYieldsNil() throws {
        let legacyData: [String: Any] = [
            "schemaVersion": 1,
            "recipeVersion": "2026.03",
            "exposureEV": 0.0,
            "brightnessCI": 0.0,
            "contrastCI": 1.0,
            "gamma": 1.0,
            "highlights": 1.0,
            "shadowAmount": 1.0,
            "blackPointBias": 0.0,
            "saturationCI": 1.0
        ]

        let decoded = try XCTUnwrap(EditRecipe(from: legacyData))
        XCTAssertNil(decoded.skyCorrectionIntensity)
    }

    // MARK: - サニタイズ

    /// 範囲外の値（1.0 超）は 1.0 にクランプされることを確認する
    func testFirestoreSanitizeClampsAboveRange() throws {
        var data: [String: Any] = EditRecipe().toFirestoreData()
        data["skyCorrectionIntensity"] = 1.5

        let decoded = try XCTUnwrap(EditRecipe(from: data))
        XCTAssertEqual(decoded.skyCorrectionIntensity, 1.0)
    }

    /// 範囲外の値（負値）は 0.0 にクランプされることを確認する
    func testFirestoreSanitizeClampsBelowRange() throws {
        var data: [String: Any] = EditRecipe().toFirestoreData()
        data["skyCorrectionIntensity"] = -0.3

        let decoded = try XCTUnwrap(EditRecipe(from: data))
        XCTAssertEqual(decoded.skyCorrectionIntensity, 0.0)
    }

    /// NaN は nil（未設定扱い）に落ちることを確認する（壊れた値を後段の CIFilter に伝播させない）
    func testFirestoreSanitizeNaNBecomesNil() throws {
        var data: [String: Any] = EditRecipe().toFirestoreData()
        data["skyCorrectionIntensity"] = Double.nan

        let decoded = try XCTUnwrap(EditRecipe(from: data))
        XCTAssertNil(decoded.skyCorrectionIntensity)
    }
}
