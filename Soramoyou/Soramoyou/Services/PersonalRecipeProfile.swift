// ⭐️ PersonalRecipeProfile.swift
// パーソナルAI編集（柱1 v1）: 過去のレシピから「あなたの定番」を統計的に導く純関数
//
//  PersonalRecipeProfile.swift
//  Soramoyou
//

import Foundation

/// ユーザー自身の過去の編集（`RecipeCorpusEntry` の集合）から
/// 「あなたの定番」レシピを統計的に導く純粋ロジック。
///
/// 設計方針（v1 = 機械学習を使わない）:
/// - 物理スケール値（露出・コントラスト等）は**平均**。
/// - 正規化 Optional 値は**設定されていた回数分だけ平均**（普段触らない項目は nil のまま）。
/// - `appliedFilter` は**最頻フィルタ**。
/// - `cropRectNorm` / `toneCurvePoints` は写真固有のため**転写しない**。
/// - データ不足（`minimumSamples` 未満）なら nil を返し、先回り適用しない。
///
/// 副作用なし・I/O なしの純関数なので単体テストで網羅できる。
enum PersonalRecipeProfile {

    /// 「あなたの定番」を成立させる最小サンプル数。これ未満なら nil。
    static let minimumSamples = 3

    /// 指定 skyType の「あなたの定番」レシピを返す。
    ///
    /// - Parameters:
    ///   - skyType: 対象の空タイプ。一致サンプルが `minimumSamples` 未満なら全体へフォールバック。
    ///   - entries: ユーザーのコーパス（古い順でも新しい順でも可）。
    ///   - minimumSamples: これ未満のサンプルでは nil を返す（既定 `minimumSamples`）。
    /// - Returns: 代表レシピ。データ不足なら nil。
    static func representative(
        for skyType: SkyType?,
        from entries: [RecipeCorpusEntry],
        minimumSamples: Int = PersonalRecipeProfile.minimumSamples
    ) -> EditRecipe? {
        guard !entries.isEmpty else { return nil }

        // skyType 一致サンプルを優先。十分に無ければ全体へフォールバック。
        let matched: [RecipeCorpusEntry]
        if let skyType {
            matched = entries.filter { $0.skyType == skyType }
        } else {
            matched = []
        }
        let sample = matched.count >= minimumSamples ? matched : entries
        guard sample.count >= minimumSamples else { return nil }

        let recipes = sample.map { $0.recipe }
        var result = EditRecipe()

        // 物理スケール（常に値あり）→ 平均
        result.exposureEV     = average(recipes.map { $0.exposureEV })
        result.brightnessCI   = average(recipes.map { $0.brightnessCI })
        result.contrastCI     = average(recipes.map { $0.contrastCI })
        result.gamma          = average(recipes.map { $0.gamma })
        result.highlights     = average(recipes.map { $0.highlights })
        result.shadowAmount   = average(recipes.map { $0.shadowAmount })
        result.blackPointBias = average(recipes.map { $0.blackPointBias })
        result.saturationCI   = average(recipes.map { $0.saturationCI })

        // 正規化 Optional → 設定されていた分のみ平均（無ければ nil のまま）
        result.brillianceNorm        = averageOptional(recipes.map { $0.brillianceNorm })
        result.naturalSaturationNorm = averageOptional(recipes.map { $0.naturalSaturationNorm })
        result.warmthNorm            = averageOptional(recipes.map { $0.warmthNorm })
        result.tintNorm              = averageOptional(recipes.map { $0.tintNorm })
        result.sharpnessNorm         = averageOptional(recipes.map { $0.sharpnessNorm })
        result.vignetteNorm          = averageOptional(recipes.map { $0.vignetteNorm })
        result.colorTemperatureNorm  = averageOptional(recipes.map { $0.colorTemperatureNorm })
        result.whiteBalanceNorm      = averageOptional(recipes.map { $0.whiteBalanceNorm })
        result.textureNorm           = averageOptional(recipes.map { $0.textureNorm })
        result.clarityNorm           = averageOptional(recipes.map { $0.clarityNorm })
        result.dehazeNorm            = averageOptional(recipes.map { $0.dehazeNorm })
        result.grainNorm             = averageOptional(recipes.map { $0.grainNorm })
        result.fadeNorm              = averageOptional(recipes.map { $0.fadeNorm })
        result.noiseReductionNorm    = averageOptional(recipes.map { $0.noiseReductionNorm })
        result.curvesNorm            = averageOptional(recipes.map { $0.curvesNorm })
        result.hslNorm               = averageOptional(recipes.map { $0.hslNorm })
        result.lensCorrectionNorm    = averageOptional(recipes.map { $0.lensCorrectionNorm })
        result.doubleExposureNorm    = averageOptional(recipes.map { $0.doubleExposureNorm })
        result.style2DToneNorm       = averageOptional(recipes.map { $0.style2DToneNorm })
        result.style2DColorNorm      = averageOptional(recipes.map { $0.style2DColorNorm })

        // フィルターは最頻
        result.appliedFilter = mostCommonFilter(recipes.compactMap { $0.appliedFilter })

        // cropRectNorm / toneCurvePoints は写真固有 → 転写しない（既定の nil のまま）
        return result
    }

    // MARK: - Private helpers

    /// 単純平均（空なら 0）。
    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 非 nil の値だけを平均。1 つも無ければ nil。
    private static func averageOptional(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +) / Double(present.count)
    }

    /// 最頻フィルタを返す（空なら nil）。同数の場合の優先順位は未定義（v1 では許容）。
    private static func mostCommonFilter(_ filters: [FilterType]) -> FilterType? {
        guard !filters.isEmpty else { return nil }
        let counts = Dictionary(grouping: filters, by: { $0 }).mapValues { $0.count }
        return counts.max { lhs, rhs in lhs.value < rhs.value }?.key
    }
}
