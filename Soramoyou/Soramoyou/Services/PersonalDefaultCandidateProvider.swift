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
///
/// ⚠️ 宣言順＝候補として採用する優先順位（先頭ほど優先的に採用される）。
/// `candidatePool(from:)` は `CaseIterable` の `allCases`（＝この宣言順）を
/// そのままプールへの追加順として使うため、ケースの並び替えは優先順位の変更を意味する。
enum FixedPresetKind: String, CaseIterable {
    case vivid
    case warm
    case cool
    case drama
    case natural

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

/// 「AIで自動編集」候補シートの**候補プール**を導出する純関数群。
///
/// 設計方針:
/// - `PersonalRecipeProfile` と同じく副作用なし・I/O なしの純関数のみで構成し、単体テストで網羅する。
/// - 候補は「（指定空タイプ or 全体の）定番 → 固定プリセット」の優先順で並べる。
///   ⚠️ ここでは件数を絞り込まない（打ち切りなし）。実際に何件表示するかは、
///   このプールを実際に描画してサムネイル同士を見た目で比較する呼び出し側
///   （`PersonalDefaultThumbnailComparer`、別タスクで実装）が決める。
/// - `isSimilar` は「描画前の安価なふるい」として残す（明らかに同一のレシピを
///   描画コストをかけずに落とすため）。最終的な見た目の重複判定（人間の目には
///   同じに見えるか）は描画後に `PersonalDefaultThumbnailComparer` が担う。
///
/// ⚠️ 仕様変更（候補シートに空タイプ切替 UI を置く方式へ移行）:
/// 旧仕様は「minimumSamples 以上ある空タイプ全ての定番」を1プールに混在させていたため、
/// 目の前の1枚（晴れ or 夕焼けのどちらか）とは無関係な空タイプの定番まで並び、
/// 「似た定番が3枚並ぶ」問題を起こしていた。新仕様では呼び出し側（候補シート）が
/// 空タイプを1つ選び、そのプールには**その空タイプの定番（または全体へのフォールバック）
/// 1件だけ**を先頭に置く。関係ない空タイプの定番はそもそもプールに入れない。
enum PersonalDefaultCandidateProvider {
    /// 候補シートに出す最小件数の目安。
    ///
    /// ⚠️ プール化に伴い、この定数はもう「打ち切りの下限」としては使われない
    /// （`candidatePool(from:)` は常に条件を満たす候補を全部プールへ入れる）。
    /// 呼び出し側（見た目で選別する側）が最終的に何件表示するかを決める際の
    /// 目安値として残している。
    static let minCandidateCount = 4
    /// 候補シートに出す最大件数の目安。
    ///
    /// ⚠️ プール化に伴い、この定数はもう「打ち切りの上限」としては使われない
    /// （`candidatePool(from:)` は空タイプ別候補を件数で打ち切らない）。
    /// 呼び出し側が最終的に何件表示するかを決める際の目安値として残している。
    static let maxCandidateCount = 5

    /// 履歴が `PersonalRecipeProfile.minimumSamples` 件以上ある空タイプを、サンプル数降順で返す。
    ///
    /// 候補シートの空タイプ切替 UI で「選べる空タイプ」を出すために使う
    /// （サンプル不足の空タイプを選ばせても定番を作れず意味がないため、そもそも選択肢に出さない）。
    ///
    /// 決定的な順序にするため (skyType, サンプル数, 宣言順index) を先に収集してからソートする
    /// （辞書やSet経由の非決定的な順序を避ける）。サンプル数が同数の場合は
    /// `SkyType.allCases` の宣言順で並べる。
    static func selectableSkyTypes(from entries: [RecipeCorpusEntry]) -> [SkyType] {
        skyTypeStats(from: entries).map(\.skyType)
    }

    /// 指定した空タイプ向けの候補プールを導出する。
    ///
    /// 「4〜5件に絞り込んだ最終リスト」ではなく、**優先順に並んだ候補プール**を返す。
    /// 実際に何件表示するかは、描画後に見た目で選別する呼び出し側が決める
    /// （このメソッドは件数で打ち切らない）。
    ///
    /// 手順:
    /// 1. 先頭候補（定番系は最大1件。これが今回の変更の要点）:
    ///    - `skyType` が指定され、かつその空タイプの履歴が `PersonalRecipeProfile.minimumSamples`
    ///      件以上あれば、その空タイプの定番（`representative(for: skyType, from:)`）を先頭に置く。
    ///      ⚠️ `representative(for:from:)` 自身にも「一致サンプル不足なら全体へフォールバック」する
    ///      ロジックがあるため、ここで事前に件数を確認してから呼ぶ
    ///      （そうしないと、フォールバックで実質「全体の定番」を計算したのに
    ///      ラベルだけ「〇〇の定番」と表示する食い違いが起きる）。
    ///    - それ以外（`skyType` が nil、または該当履歴が不足）は「あなたの定番」
    ///      （`representative(for: nil, from:)`）にフォールバックする。
    ///    - それも作れなければ（履歴が全体でも不足）先頭候補なし。
    /// 2. 固定プリセットを `FixedPresetKind.allCases`（宣言順＝優先順位）から**常に全件**プールの末尾に追加する
    ///    （履歴の有無・多寡に関わらず、フォールバックとして必ず全プリセットをプールに含める）。
    ///
    /// いずれの段階でも既採用候補と `isSimilar` な結果は追加しない
    /// （描画前の安価なふるいとして、明らかに同一のレシピを描画コストをかけずに落とす。
    ///  最終的な見た目の重複判定は描画後に `PersonalDefaultThumbnailComparer` が行う）。
    static func candidatePool(from entries: [RecipeCorpusEntry], skyType: SkyType?) -> [PersonalDefaultCandidate] {
        var result: [PersonalDefaultCandidate] = []

        // (a) 先頭候補: 指定空タイプの定番 → 「あなたの定番」の順にフォールバック。
        // ⚠️ 複数の空タイプの定番を1つのプールに混ぜない（定番系は最大1件）というのが
        // 今回の仕様変更の要点。関係ない空タイプの定番を出さないことで
        // 「似た定番が3枚並ぶ」問題を根本的に解消する。
        if
            let skyType,
            entries.filter({ $0.skyType == skyType }).count >= PersonalRecipeProfile.minimumSamples,
            let skyTypeRecipe = PersonalRecipeProfile.representative(for: skyType, from: entries)
        {
            result.append(
                PersonalDefaultCandidate(
                    kind: .skyType(skyType),
                    label: "\(skyType.displayName)の定番",
                    recipe: skyTypeRecipe
                )
            )
        } else if let overallRecipe = PersonalRecipeProfile.representative(for: nil, from: entries) {
            result.append(
                PersonalDefaultCandidate(kind: .overallDefault, label: "あなたの定番", recipe: overallRecipe)
            )
        }

        // (b) 固定プリセットは常に全件をプールの末尾に追加する（宣言順＝優先順位。
        // enum FixedPresetKind のコメント参照）。
        // ⚠️ プールなので「最低件数を満たしたら打ち切り」はしない
        // （履歴が豊富なユーザーでも、表示側が選べるようにプリセット全5件を候補として渡す）。
        for preset in FixedPresetKind.allCases {
            let recipe = preset.recipe
            guard !result.contains(where: { isSimilar($0.recipe, recipe) }) else { continue }
            result.append(PersonalDefaultCandidate(kind: .preset(preset), label: preset.label, recipe: recipe))
        }

        return result
    }

    /// 旧シグネチャ（空タイプ指定なし）の薄いオーバーロード。
    ///
    /// 呼び出し側の移行を壊さないよう、`candidatePool(from:skyType: nil)` へ委譲するだけに留める
    /// （= 常に「あなたの定番」へフォールバックする。空タイプ別の定番が欲しい場合は
    /// `candidatePool(from:skyType:)` を明示的に呼ぶこと）。
    static func candidatePool(from entries: [RecipeCorpusEntry]) -> [PersonalDefaultCandidate] {
        candidatePool(from: entries, skyType: nil)
    }

    /// 2 つのレシピが「見た目上ほぼ同じ」かどうかを固定閾値で判定する。
    ///
    /// `candidatePool(from:)` における重複排除（描画前の安価なふるい）に使う。
    /// これは前段の粗いふるいであり、最終的な見た目の重複判定（人間の目に同じに見えるか）は
    /// 描画後に `PersonalDefaultThumbnailComparer`（別タスクで実装）が行う。
    /// 閾値は「体感で違いが分かるかどうか」の粗いヒューリスティックであり、
    /// 統計的な厳密さは狙っていない。⚠️ 今回のタスクでは閾値の数値自体は変更しない
    /// （実測との乖離があっても、数値調整は別タスクの責務）。
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

    /// `minimumSamples` 件以上ある空タイプを (skyType, サンプル数, 宣言順index) の形で収集し、
    /// サンプル数降順・同数は宣言順というルールで決定的にソートする。
    ///
    /// `selectableSkyTypes(from:)` から使う内部ヘルパー。
    private static func skyTypeStats(
        from entries: [RecipeCorpusEntry]
    ) -> [(skyType: SkyType, sampleCount: Int, declarationIndex: Int)] {
        let stats: [(skyType: SkyType, sampleCount: Int, declarationIndex: Int)] =
            SkyType.allCases.enumerated().compactMap { index, skyType in
                let sampleCount = entries.filter { $0.skyType == skyType }.count
                guard sampleCount >= PersonalRecipeProfile.minimumSamples else { return nil }
                return (skyType, sampleCount, index)
            }

        return stats.sorted { lhs, rhs in
            if lhs.sampleCount != rhs.sampleCount {
                return lhs.sampleCount > rhs.sampleCount
            }
            return lhs.declarationIndex < rhs.declarationIndex
        }
    }
}
