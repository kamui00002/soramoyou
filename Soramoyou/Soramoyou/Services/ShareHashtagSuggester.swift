//
//  ShareHashtagSuggester.swift
//  Soramoyou
//
//  空カード共有パック ⭐️: 投稿の skyType / timeOfDay / mood から
//  外部SNS共有時のハッシュタグ候補を提案する純関数サービス。
//
//  - Firestore / UI に一切依存しない（テスト容易性のため）。
//  - 静的マッピングのみ。ネットワーク呼び出し・AIは使わない。
//  - 返り値は "#" を含まない生の単語（既存の hashtags 保存規約に合わせる。
//    "#" は表示・コピー側で付与する。cf. PostViewModel.extractHashtags）。
//

import Foundation

/// 共有カード用ハッシュタグ提案（純関数）
enum ShareHashtagSuggester {

    /// 常に含める共通タグ（投稿内容に関わらず）
    private static let commonTags = ["イマソラ", "そらもよう"]

    /// skyType ごとの候補タグ
    private static func tag(for skyType: SkyType) -> String {
        switch skyType {
        case .clear: return "青空"
        case .cloudy: return "曇り空"
        case .sunset: return "夕焼け"
        case .sunrise: return "朝焼け"
        case .storm: return "嵐"
        }
    }

    /// timeOfDay ごとの候補タグ
    private static func tag(for timeOfDay: TimeOfDay) -> String {
        switch timeOfDay {
        case .morning: return "朝焼け"
        case .afternoon: return "青空"
        case .evening: return "夕焼け"
        case .night: return "星空"
        }
    }

    /// mood ごとの候補タグ
    private static func tag(for mood: Mood) -> String {
        switch mood {
        case .calm: return "癒しの空"
        case .uplifted: return "晴れやかな気分"
        case .wistful: return "切ない空"
        case .dignified: return "凛とした空"
        case .dreamy: return "夢見心地"
        }
    }

    /// ハッシュタグ候補を最大5個まで提案する。
    ///
    /// 順序: skyType → timeOfDay → mood → 共通タグ の順で、重複するタグ文字列は
    /// 最初の出現のみを残す（例: skyType=.sunrise と timeOfDay=.morning は
    /// どちらも「朝焼け」にマップされるため1つにまとまる）。
    /// - Returns: "#" を含まない生の単語配列（最大5件）
    static func suggest(skyType: SkyType?, timeOfDay: TimeOfDay?, mood: Mood?) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ candidate: String?) {
            guard let candidate, !seen.contains(candidate) else { return }
            seen.insert(candidate)
            ordered.append(candidate)
        }

        append(skyType.map(tag(for:)))
        append(timeOfDay.map(tag(for:)))
        append(mood.map(tag(for:)))
        commonTags.forEach(append)

        // 安全網: 現行マッピングでは skyType/timeOfDay/mood(3) + 共通(2) = 最大5件で
        // 超過しないが、将来マッピングが増えても仕様上限（5個）を明示的に守る。
        return Array(ordered.prefix(5))
    }
}
