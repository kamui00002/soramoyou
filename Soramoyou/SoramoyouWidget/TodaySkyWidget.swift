//
//  TodaySkyWidget.swift
//  SoramoyouWidget
//
//  Created on 2025-12-06.
//

import WidgetKit
import SwiftUI

// MARK: - Today Sky Entry

struct TodaySkyEntry: TimelineEntry {
    let date: Date
    let postsCount: Int
    let dominantSkyType: String?
    let lastUpdateTime: Date?
}

// MARK: - Today Sky Provider

struct TodaySkyProvider: TimelineProvider {
    typealias Entry = TodaySkyEntry

    func placeholder(in context: Context) -> TodaySkyEntry {
        TodaySkyEntry(
            date: Date(),
            postsCount: 12,
            dominantSkyType: "clear",
            lastUpdateTime: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TodaySkyEntry) -> Void) {
        let entry = getEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodaySkyEntry>) -> Void) {
        let entry = getEntry()

        // 1時間ごとに更新
        let refreshDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }

    private func getEntry() -> TodaySkyEntry {
        let sharedDefaults = UserDefaults(suiteName: "group.com.soramoyou.app")

        let postsCount = sharedDefaults?.integer(forKey: "widget_today_posts_count") ?? 0
        let dominantSkyType = sharedDefaults?.string(forKey: "widget_today_dominant_sky")
        let lastUpdateInterval = sharedDefaults?.double(forKey: "widget_last_update") ?? 0
        let lastUpdateTime = lastUpdateInterval > 0 ? Date(timeIntervalSince1970: lastUpdateInterval) : nil

        return TodaySkyEntry(
            date: Date(),
            postsCount: postsCount,
            dominantSkyType: dominantSkyType,
            lastUpdateTime: lastUpdateTime
        )
    }
}

// MARK: - Today Sky Widget View

struct TodaySkyWidgetEntryView: View {
    var entry: TodaySkyProvider.Entry
    @Environment(\.widgetFamily) var widgetFamily

    var body: some View {
        ZStack {
            // 背景
            backgroundGradient

            VStack(spacing: 8) {
                // アイコン
                skyIcon
                    .font(.system(size: iconSize))
                    .foregroundColor(.white)
                    .symbolEffect(.bounce, options: .repeating)

                // 今日の空タイプ
                if let skyType = entry.dominantSkyType {
                    Text(skyTypeDisplayName(skyType))
                        .font(.headline)
                        .foregroundColor(.white)
                }

                // 投稿数
                if widgetFamily != .systemSmall {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.stack")
                            .font(.caption2)
                        Text("今日 \(entry.postsCount) 件の投稿")
                            .font(.caption)
                    }
                    .foregroundColor(.white.opacity(0.8))
                }

                // 更新時刻
                if widgetFamily == .systemMedium || widgetFamily == .systemLarge {
                    if let updateTime = entry.lastUpdateTime {
                        Text("更新: \(updateTime, style: .time)")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .padding()
        }
    }

    private var iconSize: CGFloat {
        switch widgetFamily {
        case .systemSmall: return 36
        case .systemMedium: return 44
        case .systemLarge: return 56
        default: return 40
        }
    }

    private var skyIcon: Image {
        guard let skyType = entry.dominantSkyType else {
            return Image(systemName: "cloud.sun.fill")
        }

        switch skyType {
        case "clear":
            return Image(systemName: "sun.max.fill")
        case "cloudy":
            return Image(systemName: "cloud.fill")
        case "rainy":
            return Image(systemName: "cloud.rain.fill")
        case "sunset":
            return Image(systemName: "sunset.fill")
        case "sunrise":
            return Image(systemName: "sunrise.fill")
        case "night":
            return Image(systemName: "moon.stars.fill")
        case "starry":
            return Image(systemName: "sparkles")
        case "rainbow":
            return Image(systemName: "rainbow")
        case "storm":
            return Image(systemName: "cloud.bolt.fill")
        case "snow":
            return Image(systemName: "snowflake")
        default:
            return Image(systemName: "cloud.sun.fill")
        }
    }

    private var backgroundGradient: some View {
        let colors = gradientColors(for: entry.dominantSkyType)
        return LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func gradientColors(for skyType: String?) -> [Color] {
        switch skyType {
        case "clear":
            return [Color(red: 0.4, green: 0.7, blue: 1.0), Color(red: 0.2, green: 0.5, blue: 0.9)]
        case "cloudy":
            return [Color(red: 0.6, green: 0.65, blue: 0.7), Color(red: 0.4, green: 0.45, blue: 0.5)]
        case "rainy":
            return [Color(red: 0.3, green: 0.4, blue: 0.5), Color(red: 0.2, green: 0.25, blue: 0.35)]
        case "sunset":
            return [Color(red: 1.0, green: 0.5, blue: 0.3), Color(red: 0.8, green: 0.3, blue: 0.4)]
        case "sunrise":
            return [Color(red: 1.0, green: 0.7, blue: 0.5), Color(red: 0.9, green: 0.5, blue: 0.6)]
        case "night":
            return [Color(red: 0.1, green: 0.1, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.15)]
        case "starry":
            return [Color(red: 0.05, green: 0.05, blue: 0.2), Color.black]
        case "rainbow":
            return [Color(red: 0.5, green: 0.7, blue: 1.0), Color(red: 0.9, green: 0.7, blue: 0.9)]
        case "storm":
            return [Color(red: 0.2, green: 0.2, blue: 0.3), Color(red: 0.1, green: 0.1, blue: 0.15)]
        case "snow":
            return [Color(red: 0.85, green: 0.9, blue: 0.95), Color(red: 0.7, green: 0.8, blue: 0.9)]
        default:
            return [Color(red: 0.68, green: 0.85, blue: 0.90), Color(red: 0.39, green: 0.58, blue: 0.93)]
        }
    }

    private func skyTypeDisplayName(_ type: String) -> String {
        switch type {
        case "clear": return "晴れ"
        case "cloudy": return "曇り"
        case "rainy": return "雨"
        case "sunset": return "夕焼け"
        case "sunrise": return "朝焼け"
        case "night": return "夜空"
        case "starry": return "星空"
        case "rainbow": return "虹"
        case "storm": return "嵐"
        case "snow": return "雪"
        default: return "空模様"
        }
    }
}

// MARK: - Today Sky Widget Definition

struct TodaySkyWidget: Widget {
    let kind: String = "TodaySkyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodaySkyProvider()) { entry in
            TodaySkyWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("今日の空")
        .description("今日の空模様と投稿数を表示します")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    TodaySkyWidget()
} timeline: {
    TodaySkyEntry(date: Date(), postsCount: 15, dominantSkyType: "sunset", lastUpdateTime: Date())
}

#Preview(as: .systemMedium) {
    TodaySkyWidget()
} timeline: {
    TodaySkyEntry(date: Date(), postsCount: 15, dominantSkyType: "clear", lastUpdateTime: Date())
}
