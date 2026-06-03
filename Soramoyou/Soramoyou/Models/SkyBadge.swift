//
//  SkyBadge.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）の達成バッジ定義。
//  判定は CollectionState に対する純粋な述語で行う。
//

import Foundation

/// バッジの進捗（例: 47都道府県中 12）。
struct BadgeProgress: Equatable {
    let current: Int
    let total: Int

    /// 達成済みか
    var isComplete: Bool { current >= total }
}

/// 図鑑の達成バッジ。
///
/// `isUnlocked` / `progress` は `CollectionState` に対する純関数なので、
/// データの蓄積に応じて都度導出する（保存不要）。
struct SkyBadge: Identifiable {
    let id: String
    let title: String
    let description: String
    /// SF Symbols アイコン名
    let iconName: String
    /// 解放済みか
    let isUnlocked: (CollectionState) -> Bool
    /// 進捗（current/total）
    let progress: (CollectionState) -> BadgeProgress

    /// バッジの静的カタログ。
    static let all: [SkyBadge] = [
        SkyBadge(
            id: "first_sky",
            title: "はじめての空",
            description: "初めて空を投稿した",
            iconName: "sparkles",
            isUnlocked: { $0.totalPosts >= 1 },
            progress: { BadgeProgress(current: min($0.totalPosts, 1), total: 1) }
        ),
        SkyBadge(
            id: "collector_10",
            title: "空コレクター",
            description: "10枚の空を集めた",
            iconName: "square.stack.3d.up.fill",
            isUnlocked: { $0.totalPosts >= 10 },
            progress: { BadgeProgress(current: min($0.totalPosts, 10), total: 10) }
        ),
        SkyBadge(
            id: "all_sky_types",
            title: "空模様コンプリート",
            description: "5種類の空（晴れ・曇り・夕焼け・朝焼け・嵐）をすべて集めた",
            iconName: "cloud.sun.fill",
            isUnlocked: { $0.skyTypes.count >= SkyType.allCases.count },
            progress: { BadgeProgress(current: $0.skyTypes.count, total: SkyType.allCases.count) }
        ),
        SkyBadge(
            id: "all_times",
            title: "一日の空",
            description: "朝・昼・夕方・夜の空を集めた",
            iconName: "clock.fill",
            isUnlocked: { $0.timeOfDays.count >= TimeOfDay.allCases.count },
            progress: { BadgeProgress(current: $0.timeOfDays.count, total: TimeOfDay.allCases.count) }
        ),
        SkyBadge(
            id: "all_seasons",
            title: "四季の空",
            description: "春・夏・秋・冬の空を集めた",
            iconName: "leaf.fill",
            isUnlocked: { $0.seasons.count >= Season.allCases.count },
            progress: { BadgeProgress(current: $0.seasons.count, total: Season.allCases.count) }
        ),
        SkyBadge(
            id: "sunset_hunter",
            title: "夕焼けハンター",
            description: "夕焼けの空を集めた",
            iconName: "sunset.fill",
            isUnlocked: { $0.skyTypes.contains(.sunset) },
            progress: { BadgeProgress(current: $0.skyTypes.contains(.sunset) ? 1 : 0, total: 1) }
        ),
        SkyBadge(
            id: "sunrise_hunter",
            title: "朝焼けハンター",
            description: "朝焼けの空を集めた",
            iconName: "sunrise.fill",
            isUnlocked: { $0.skyTypes.contains(.sunrise) },
            progress: { BadgeProgress(current: $0.skyTypes.contains(.sunrise) ? 1 : 0, total: 1) }
        ),
        SkyBadge(
            id: "all_47",
            title: "全国の空",
            description: "47都道府県の空を集めた",
            iconName: "map.fill",
            isUnlocked: { $0.prefectures.count >= JapanPrefecture.allNames.count },
            progress: { BadgeProgress(current: $0.prefectures.count, total: JapanPrefecture.allNames.count) }
        )
    ]
}
