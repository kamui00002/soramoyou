//
//  SkyPhotoWidget.swift
//  SoramoyouWidget
//
//  Created on 2025-12-06.
//

import WidgetKit
import SwiftUI

// MARK: - Widget Entry

struct SkyPhotoEntry: TimelineEntry {
    let date: Date
    let imageData: Data?
    let caption: String?
    let skyType: String?
    let timeOfDay: String?
    let configuration: ConfigurationAppIntent

    static var placeholder: SkyPhotoEntry {
        SkyPhotoEntry(
            date: Date(),
            imageData: nil,
            caption: "美しい空の写真",
            skyType: "sunset",
            timeOfDay: "evening",
            configuration: ConfigurationAppIntent()
        )
    }
}

// MARK: - Configuration Intent

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "空もよう設定"
    static var description: IntentDescription = IntentDescription("ウィジェットの表示設定")

    @Parameter(title: "表示タイプ", default: .latestPost)
    var displayType: DisplayType

    @Parameter(title: "更新頻度", default: .hourly)
    var updateFrequency: UpdateFrequency
}

enum DisplayType: String, AppEnum {
    case latestPost = "latest"
    case randomFromCollection = "random"
    case todaysPhoto = "today"

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "表示タイプ"
    }

    static var caseDisplayRepresentations: [DisplayType: DisplayRepresentation] {
        [
            .latestPost: "最新の投稿",
            .randomFromCollection: "コレクションからランダム",
            .todaysPhoto: "今日の空"
        ]
    }
}

enum UpdateFrequency: String, AppEnum {
    case hourly = "hourly"
    case daily = "daily"
    case manual = "manual"

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "更新頻度"
    }

    static var caseDisplayRepresentations: [UpdateFrequency: DisplayRepresentation] {
        [
            .hourly: "1時間ごと",
            .daily: "1日ごと",
            .manual: "手動のみ"
        ]
    }
}

// MARK: - Timeline Provider

struct SkyPhotoProvider: AppIntentTimelineProvider {
    typealias Entry = SkyPhotoEntry
    typealias Intent = ConfigurationAppIntent

    func placeholder(in context: Context) -> SkyPhotoEntry {
        .placeholder
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SkyPhotoEntry {
        await getEntry(for: configuration)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SkyPhotoEntry> {
        let entry = await getEntry(for: configuration)

        // 更新頻度に応じてタイムラインを設定
        let refreshDate: Date
        switch configuration.updateFrequency {
        case .hourly:
            refreshDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        case .daily:
            refreshDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        case .manual:
            refreshDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        }

        return Timeline(entries: [entry], policy: .after(refreshDate))
    }

    private func getEntry(for configuration: ConfigurationAppIntent) async -> SkyPhotoEntry {
        // App Groupから共有データを取得
        let sharedDefaults = UserDefaults(suiteName: "group.com.soramoyou.app")

        let imageData = sharedDefaults?.data(forKey: "widget_latest_image")
        let caption = sharedDefaults?.string(forKey: "widget_latest_caption")
        let skyType = sharedDefaults?.string(forKey: "widget_latest_sky_type")
        let timeOfDay = sharedDefaults?.string(forKey: "widget_latest_time_of_day")

        return SkyPhotoEntry(
            date: Date(),
            imageData: imageData,
            caption: caption,
            skyType: skyType,
            timeOfDay: timeOfDay,
            configuration: configuration
        )
    }
}

// MARK: - Widget View

struct SkyPhotoWidgetEntryView: View {
    var entry: SkyPhotoProvider.Entry
    @Environment(\.widgetFamily) var widgetFamily

    var body: some View {
        ZStack {
            // 背景グラデーション
            backgroundGradient

            // コンテンツ
            VStack {
                if let imageData = entry.imageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholderView
                }
            }

            // オーバーレイ情報
            if widgetFamily != .systemSmall {
                overlayInfo
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: gradientColors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var gradientColors: [Color] {
        switch entry.timeOfDay {
        case "morning":
            return [Color(red: 1.0, green: 0.8, blue: 0.6), Color(red: 0.4, green: 0.6, blue: 0.9)]
        case "afternoon":
            return [Color(red: 0.4, green: 0.7, blue: 1.0), Color(red: 0.2, green: 0.5, blue: 0.9)]
        case "evening":
            return [Color(red: 1.0, green: 0.5, blue: 0.3), Color(red: 0.5, green: 0.2, blue: 0.5)]
        case "night":
            return [Color(red: 0.1, green: 0.1, blue: 0.3), Color.black]
        default:
            return [Color(red: 0.68, green: 0.85, blue: 0.90), Color(red: 0.39, green: 0.58, blue: 0.93)]
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "cloud.sun.fill")
                .font(.system(size: widgetFamily == .systemSmall ? 40 : 60))
                .foregroundColor(.white)

            if widgetFamily != .systemSmall {
                Text("そらもよう")
                    .font(.headline)
                    .foregroundColor(.white)

                Text("空の写真を共有しよう")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    private var overlayInfo: some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let caption = entry.caption {
                        Text(caption)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .lineLimit(2)
                    }

                    if let skyType = entry.skyType {
                        Text(skyTypeDisplayName(skyType))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
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
        default: return type
        }
    }
}

// MARK: - Widget Definition

struct SkyPhotoWidget: Widget {
    let kind: String = "SkyPhotoWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: SkyPhotoProvider()) { entry in
            SkyPhotoWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("空の写真")
        .description("最新の空の写真を表示します")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    SkyPhotoWidget()
} timeline: {
    SkyPhotoEntry.placeholder
}

#Preview(as: .systemMedium) {
    SkyPhotoWidget()
} timeline: {
    SkyPhotoEntry.placeholder
}
