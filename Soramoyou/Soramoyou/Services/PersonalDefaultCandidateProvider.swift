// ⭐️ PersonalDefaultCandidateProvider.swift
// パーソナルAI編集（柱1 v2）: 「AIで自動編集」候補シートに並べる編集パターン一覧を導く純関数
//
//  PersonalDefaultCandidateProvider.swift
//  Soramoyou
//

import Foundation

// MARK: - PersonalDefaultCandidate

/// 「AIで自動編集」ボタンをタップした際に候補シートへ並べる編集パターン 1 件。
///
/// - `Identifiable`: SwiftUI の List/ForEach へそのまま渡せるように。
/// - `Equatable`: プレビュー差分検知・スナップショットテストに使用。
struct PersonalDefaultCandidate: Identifiable, Equatable {
    /// 候補の種類。
    ///
    /// 計装（Analytics）に PII を含まない安定文字列を送るため、
    /// `SkyType` / `FixedPresetKind` の rawValue を経由した表現を `analyticsValue` に持つ。
    enum Kind: Equatable {
        /// 過去の編集履歴全体から導いた「あなたの定番」（従来の「AIで自動編集」と同じ挙動）
        case overallDefault
        /// 特定の空タイプに絞った「あなたの定番」
        case skyType(SkyType)
        /// 固定プリセット（履歴が少ない/無いユーザー向けのフォールバック）
        case preset(FixedPresetKind)

        /// 計装イベントに載せる安定文字列（PII を含まない）。
        var analyticsValue: String {
            switch self {
            case .overallDefault:
                "overall"
            case let .skyType(skyType):
                "sky_\(skyType.rawValue)"
            case let .preset(preset):
                "preset_\(preset.rawValue)"
            }
        }
    }

    /// 候補の種類。
    let kind: Kind
    /// 候補シートに表示する日本語ラベル（例:「あなたの定番」「晴れの定番」「くっきり」）。
    let label: String
    /// この候補を適用したときのレシピ（写真固有フィールドは含まない「作風だけ」のレシピ）。
    let recipe: EditRecipe

    /// `Identifiable` 適合。`kind` から導出するため候補一覧内で一意になる。
    var id: String { kind.analyticsValue }
}

// MARK: - FixedPresetKind

/// 履歴データが少ない・無いユーザーでも必ず候補を出せる固定プリセット。
///
/// `FilterGraphBuilder` で検証済みの既存 `FilterType` のみを土台にする
/// （新規の編集係数をここで発明しない）。
enum FixedPresetKind: String, CaseIterable {
    case vivid
    case warm
    case cool
    case drama
    case natural

    /// 候補として採用する優先順位（先頭ほど優先的に採用される）。
    static let priorityOrder: [FixedPresetKind] = [.vivid, .warm, .cool, .drama, .natural]

    /// 対応する既存 `FilterType`。
    var filterType: FilterType {
        switch self {
        case .vivid: .vivid
        case .warm: .warm
        case .cool: .cool
        case .drama: .drama
        case .natural: .natural
        }
    }

    /// 候補シートに表示する日本語ラベル。
    var label: String {
        switch self {
        case .vivid: "くっきり"
        case .warm: "あたたかく"
        case .cool: "すずしく"
        case .drama: "ドラマチック"
        case .natural: "ナチュラル"
        }
    }

    /// このプリセットを適用したときのレシピ。
    ///
    /// `EditRecipe()` の中立初期値に `appliedFilter` を立てるだけ。
    /// フィルタそのものの見た目は `FilterGraphBuilder` が担うため、
    /// ここで新規の物理値・係数は発明しない。
    var recipe: EditRecipe {
        var recipe = EditRecipe()
        recipe.appliedFilter = filterType
        return recipe
    }
}

// MARK: - PersonalDefaultCandidateProvider

/// 「AIで自動編集」候補シートに並べる編集パターンの一覧を導出する純関数群。
///
/// 設計方針:
/// - `PersonalRecipeProfile` と同じく副作用なし・I/O なしの純関数のみで構成し、単体テストで網羅する。
/// - 候補は「全体の定番 → 空タイプ別の定番 → 固定プリセット」の優先順で埋め、
///   新規ユーザー（履歴 0 件）でも `minCandidateCount` 件は必ず表示できるようにする。
/// - `isSimilar` で見た目上ほぼ同じレシピの重複掲載を避ける。
enum PersonalDefaultCandidateProvider {
    /// 候補シートに出す最小件数。履歴が少なくても固定プリセットで埋めてこれを満たす。
    static let minCandidateCount = 4
    /// 候補シートに出す最大件数（表示が煩雑にならないための上限）。
    static let maxCandidateCount = 5

    /// コーパスから候補一覧を導出する。
    ///
    /// 手順:
    /// 1. 全体の「あなたの定番」（`PersonalRecipeProfile.representative(for: nil, from:)` が成立すれば先頭に追加）。
    ///    ⚠️ 履歴不足で nil でも `return` せず続行する
    ///    （新規ユーザーにも固定プリセットで候補を出す確定仕様のため）。
    /// 2. 空タイプ別の「〇〇の定番」を、`RecipeCorpusProfile.minimumSamples` 件以上ある空タイプに限り、
    ///    サンプル数降順（同数は `SkyType.allCases` の宣言順）で `maxCandidateCount` 件まで追加。
    /// 3. まだ `minCandidateCount` 件に満たなければ、`FixedPresetKind.priorityOrder` から補充する。
    ///
    /// いずれの段階でも既採用候補と `isSimilar` な結果は追加しない
    /// （候補シートに似た結果ばかり並ぶのを防ぐ）。
    static func candidates(from entries: [RecipeCorpusEntry]) -> [PersonalDefaultCandidate] {
        var result: [PersonalDefaultCandidate] = []

        // (a) 全体の「あなたの定番」。
        if let overallRecipe = PersonalRecipeProfile.representative(for: nil, from: entries) {
            result.append(
                PersonalDefaultCandidate(kind: .overallDefault, label: "あなたの定番", recipe: overallRecipe)
            )
        }

        // (b) 空タイプ別の定番。
        // まず「minimumSamples 件以上ある空タイプ」だけを (skyType, サンプル数, 宣言順index) で収集し、
        // サンプル数降順・同数は宣言順というルールで決定的にソートする
        // （毎回同じ候補順になるように。辞書やSet経由の非決定的な順序を避ける）。
        let skyTypeStats: [(skyType: SkyType, sampleCount: Int, declarationIndex: Int)] =
            SkyType.allCases.enumerated().compactMap { index, skyType in
                let sampleCount = entries.filter { $0.skyType == skyType }.count
                guard sampleCount >= PersonalRecipeProfile.minimumSamples else { return nil }
                return (skyType, sampleCount, index)
            }

        let sortedSkyTypeStats = skyTypeStats.sorted { lhs, rhs in
            if lhs.sampleCount != rhs.sampleCount {
                return lhs.sampleCount > rhs.sampleCount
            }
            return lhs.declarationIndex < rhs.declarationIndex
        }

        for stat in sortedSkyTypeStats {
            guard result.count < maxCandidateCount else { break }
            // sampleCount は既に minimumSamples 以上を保証済みなので、
            // representative(for:from:) は matched（skyType 一致サンプル）を使って算出される
            // （全体へのフォールバックは発生しない）。
            guard let recipe = PersonalRecipeProfile.representative(for: stat.skyType, from: entries) else { continue }
            guard !result.contains(where: { isSimilar($0.recipe, recipe) }) else { continue }
            result.append(
                PersonalDefaultCandidate(
                    kind: .skyType(stat.skyType),
                    label: "\(stat.skyType.displayName)の定番",
                    recipe: recipe
                )
            )
        }

        // (c) 固定プリセットで最低件数を保証する。
        for preset in FixedPresetKind.priorityOrder {
            guard result.count < minCandidateCount else { break }
            let recipe = preset.recipe
            guard !result.contains(where: { isSimilar($0.recipe, recipe) }) else { continue }
            result.append(PersonalDefaultCandidate(kind: .preset(preset), label: preset.label, recipe: recipe))
        }

        return result
    }

    /// 2 つのレシピが「見た目上ほぼ同じ」かどうかを固定閾値で判定する。
    ///
    /// 候補シートに似た結果ばかり並ぶのを避けるための重複排除に使う。
    /// 閾値は「体感で違いが分かるかどうか」の粗いヒューリスティックであり、
    /// 統計的な厳密さは狙っていない。
    static func isSimilar(_ a: EditRecipe, _ b: EditRecipe) -> Bool {
        guard a.appliedFilter == b.appliedFilter else { return false }
        guard abs(a.exposureEV - b.exposureEV) < 0.15 else { return false }
        guard abs(a.saturationCI - b.saturationCI) < 0.08 else { return false }
        guard abs(a.contrastCI - b.contrastCI) < 0.08 else { return false }
        guard absDiff(a.warmthNorm, b.warmthNorm) < 0.10 else { return false }
        guard absDiff(a.style2DToneNorm, b.style2DToneNorm) < 0.15 else { return false }
        guard absDiff(a.style2DColorNorm, b.style2DColorNorm) < 0.15 else { return false }
        return true
    }

    /// Optional Double 同士の差の絶対値。片方または両方が nil の場合は 0 として扱う
    /// （「一度も触っていない」＝ 0 相当という `EditRecipe` 側の設計に合わせる）。
    private static func absDiff(_ a: Double?, _ b: Double?) -> Double {
        abs((a ?? 0) - (b ?? 0))
    }
}
