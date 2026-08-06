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
/// - 物理スケール値（露出・コントラスト等）は `savedAt` の新しさで重み付けした**加重平均**。
/// - 正規化 Optional 値は**重み付き使用率が過半数のときだけ**、設定されていた回だけの加重平均を採用
///   （普段触らない項目は nil のまま＝一度だけ使った項目が常に提案されるのを防ぐ）。
/// - `appliedFilter` は「フィルタなし（nil）」も 1 つの選択肢として含めた**重み付き最頻フィルタ**。
/// - `cropRectNorm` / `toneCurvePoints` は写真固有のため**転写しない**。
/// - データ不足（`minimumSamples` 未満）なら nil を返し、先回り適用しない。
///
/// 副作用なし・I/O なしの純関数なので単体テストで網羅できる。
enum PersonalRecipeProfile {
    /// 「あなたの定番」を成立させる最小サンプル数。これ未満なら nil。
    /// private を付けず internal のまま公開する: `PersonalDefaultCandidateProvider` が
    /// 空タイプ別候補の成立可否を判定する際、ここと同じ閾値を参照して二重定義を防ぐため。
    static let minimumSamples = 3

    /// 新しさによる減衰係数。直近の編集ほど定番に強く反映するため。
    /// `savedAt` 降順で i 番目（0=最新）の重みは `pow(recencyDecay, i)`。
    /// 0.8^k で約3件前=半減（0.8^3 ≈ 0.512）。
    static let recencyDecay = 0.8

    /// 正規化 Optional 項目を「定番」として採用するために必要な、重み付き使用率の閾値。
    /// これを超えないと nil のまま（一度だけ使った項目が常に提案される問題の修正）。
    static let optionalAdoptionThreshold = 0.5

    /// 指定 skyType の「あなたの定番」レシピを返す。
    ///
    /// 注: `EditViewModel` 経由の「あなたの定番」単体適用は引き続き `for: nil`
    /// （全体の代表値）を渡す。一方 `PersonalDefaultCandidateProvider.candidates(from:)`
    /// が空タイプ別候補シートのために `for: skyType` を渡して本番から呼び出すようになったため、
    /// skyType 一致ブランチはテスト専用ではなく本番経路でも実行される。
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
        let matched: [RecipeCorpusEntry] = if let skyType {
            entries.filter { $0.skyType == skyType }
        } else {
            []
        }
        let sample = matched.count >= minimumSamples ? matched : entries
        guard sample.count >= minimumSamples else { return nil }

        // savedAt の新しい順に並べ替え、i 番目（0=最新）に減衰重みを付与する。
        let sorted = sample.sorted { $0.savedAt > $1.savedAt }
        let weights = sorted.enumerated().map { pow(recencyDecay, Double($0.offset)) }
        let recipes = sorted.map(\.recipe)

        var result = EditRecipe()

        // 物理スケール（常に値あり）→ 新しさで重み付けした加重平均
        result.exposureEV = weightedAverage(values: recipes.map(\.exposureEV), weights: weights)
        result.brightnessCI = weightedAverage(values: recipes.map(\.brightnessCI), weights: weights)
        result.contrastCI = weightedAverage(values: recipes.map(\.contrastCI), weights: weights)
        result.gamma = weightedAverage(values: recipes.map(\.gamma), weights: weights)
        result.highlights = weightedAverage(values: recipes.map(\.highlights), weights: weights)
        result.shadowAmount = weightedAverage(values: recipes.map(\.shadowAmount), weights: weights)
        result.blackPointBias = weightedAverage(values: recipes.map(\.blackPointBias), weights: weights)
        result.saturationCI = weightedAverage(values: recipes.map(\.saturationCI), weights: weights)

        // 正規化 Optional → 重み付き使用率が過半数のときだけ、設定されていた分のみの加重平均を採用
        result.brillianceNorm = weightedAverageOptional(recipes.map(\.brillianceNorm), weights: weights)
        result.naturalSaturationNorm = weightedAverageOptional(recipes.map(\.naturalSaturationNorm), weights: weights)
        result.warmthNorm = weightedAverageOptional(recipes.map(\.warmthNorm), weights: weights)
        result.tintNorm = weightedAverageOptional(recipes.map(\.tintNorm), weights: weights)
        result.sharpnessNorm = weightedAverageOptional(recipes.map(\.sharpnessNorm), weights: weights)
        result.vignetteNorm = weightedAverageOptional(recipes.map(\.vignetteNorm), weights: weights)
        result.colorTemperatureNorm = weightedAverageOptional(recipes.map(\.colorTemperatureNorm), weights: weights)
        result.whiteBalanceNorm = weightedAverageOptional(recipes.map(\.whiteBalanceNorm), weights: weights)
        result.textureNorm = weightedAverageOptional(recipes.map(\.textureNorm), weights: weights)
        result.clarityNorm = weightedAverageOptional(recipes.map(\.clarityNorm), weights: weights)
        result.dehazeNorm = weightedAverageOptional(recipes.map(\.dehazeNorm), weights: weights)
        result.grainNorm = weightedAverageOptional(recipes.map(\.grainNorm), weights: weights)
        result.fadeNorm = weightedAverageOptional(recipes.map(\.fadeNorm), weights: weights)
        result.noiseReductionNorm = weightedAverageOptional(recipes.map(\.noiseReductionNorm), weights: weights)
        result.curvesNorm = weightedAverageOptional(recipes.map(\.curvesNorm), weights: weights)
        result.hslNorm = weightedAverageOptional(recipes.map(\.hslNorm), weights: weights)
        result.lensCorrectionNorm = weightedAverageOptional(recipes.map(\.lensCorrectionNorm), weights: weights)
        result.doubleExposureNorm = weightedAverageOptional(recipes.map(\.doubleExposureNorm), weights: weights)
        result.style2DToneNorm = weightedAverageOptional(recipes.map(\.style2DToneNorm), weights: weights)
        result.style2DColorNorm = weightedAverageOptional(recipes.map(\.style2DColorNorm), weights: weights)

        // フィルターは「フィルタなし」も 1 票として含めた重み付き最頻値
        result.appliedFilter = dominantFilter(recipes: recipes, weights: weights)

        // cropRectNorm / toneCurvePoints は写真固有 → 転写しない（既定の nil のまま）
        return result
    }

    // MARK: - Private helpers

    /// 重み付き平均 Σ(w_i × v_i) / Σ(w_i)。重みの合計が 0（空配列等）なら 0。
    private static func weightedAverage(values: [Double], weights: [Double]) -> Double {
        guard values.count == weights.count else { return 0 }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return 0 }
        let weightedSum = zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 }
        return weightedSum / totalWeight
    }

    /// 非 nil の値だけの重み付き平均を、重み付き使用率が `optionalAdoptionThreshold` を
    /// 超えたときだけ採用する。
    ///
    /// 一度だけ使った項目が常に提案される問題の修正。設計意図
    /// （普段触らない項目は nil のまま）を実装に反映する。
    private static func weightedAverageOptional(_ values: [Double?], weights: [Double]) -> Double? {
        guard values.count == weights.count else { return nil }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return nil }

        var presentWeight = 0.0
        var weightedSum = 0.0
        for (value, weight) in zip(values, weights) {
            guard let value else { continue }
            presentWeight += weight
            weightedSum += weight * value
        }

        let usageRate = presentWeight / totalWeight
        guard usageRate > optionalAdoptionThreshold, presentWeight > 0 else { return nil }
        return weightedSum / presentWeight
    }

    /// 「フィルタなし（nil）」も 1 つの選択肢として含めた重み付き最頻フィルタを返す。
    ///
    /// 旧実装は `compactMap` で nil 票を捨てていたため、1 件でもフィルタ付き投稿が
    /// あるとそれが最頻扱いになるバグがあった。この修正でフィルタなしが多数派なら
    /// nil（=定番はフィルタなし）を返す。
    ///
    /// 同率の場合はより新しいエントリ（`recipes`/`weights` 内でより手前＝savedAt 降順の
    /// 並びで先に出現する方）を含む選択肢を優先する決定的なタイブレークとする。
    private static func dominantFilter(recipes: [EditRecipe], weights: [Double]) -> FilterType? {
        guard recipes.count == weights.count else { return nil }

        var totals: [FilterType?: Double] = [:]
        var earliestOccurrence: [FilterType?: Int] = [:]
        for (index, pair) in zip(recipes, weights).enumerated() {
            let key = pair.0.appliedFilter
            totals[key, default: 0] += pair.1
            if earliestOccurrence[key] == nil {
                earliestOccurrence[key] = index
            }
        }

        let best = totals.max { lhs, rhs in
            if lhs.value != rhs.value {
                return lhs.value < rhs.value
            }
            // 同率タイブレーク: recipes/weights はすでに savedAt 降順（新しい順）なので、
            // occurrence index が小さい方＝より新しいエントリを含む方を優先する。
            let lhsIndex = earliestOccurrence[lhs.key] ?? Int.max
            let rhsIndex = earliestOccurrence[rhs.key] ?? Int.max
            return lhsIndex > rhsIndex
        }
        return best?.key
    }
}
