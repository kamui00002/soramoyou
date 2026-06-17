//
//  SoramoyouWidget.swift
//  SoramoyouWidget
//
//  ホーム画面ウィジェット本体。App Group キャッシュ（本体が書いた写真＋index）を読み、
//  3モード（アルバム / 今の空 / 抽象色）で空を表示する。
//  - Entry に UIImage は積まない（メモリ30MB対策）。描画直前に ImageIO でダウンサンプル。
//  - 写真が無い時は空グラデーションにフォールバック。
//

import SwiftUI
import UIKit
import WidgetKit

// MARK: - Timeline Entry（軽量：パスと局面のみ・UIImage は積まない）

struct SkyEntry: TimelineEntry {
    let date: Date
    let mode: WidgetDisplayMode
    let phase: SkyPhase
    /// 表示する写真の絶対パス。無ければ nil（→ グラデ表示）。
    let imagePath: String?
    /// タップ時のディープリンク用 postId。
    let postId: String?
}

// MARK: - Provider

struct Provider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> SkyEntry {
        // プレースホルダはグラデのみ（写真ロードを避けチラつき防止）。
        let now = Date()
        return SkyEntry(date: now, mode: .currentSky, phase: phase(at: now), imagePath: nil, postId: nil)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SkyEntry {
        makeEntry(at: Date(), mode: configuration.mode, index: WidgetCacheReader.loadIndex())
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SkyEntry> {
        let index = WidgetCacheReader.loadIndex()
        let now = Date()
        let calendar = Calendar.current
        var entries: [SkyEntry] = []
        // 今から1時間ごとに12点。局面の変化と写真ローテーションに追従させる。
        for hourOffset in 0..<12 {
            let date = calendar.date(byAdding: .hour, value: hourOffset, to: now)
                ?? now.addingTimeInterval(Double(hourOffset) * 3600)
            entries.append(makeEntry(at: date, mode: configuration.mode, index: index))
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    // MARK: 組み立て

    /// その時刻・現在地（暫定東京）の空の局面。
    private func phase(at date: Date) -> SkyPhase {
        let loc = WidgetLocation.current()
        return SkyPhase.current(at: date, latitude: loc.latitude, longitude: loc.longitude, timeZone: .current)
    }

    private func makeEntry(at date: Date, mode: WidgetDisplayMode, index: WidgetIndex) -> SkyEntry {
        let currentPhase = phase(at: date)
        let picked: WidgetIndex.Entry?
        switch mode {
        case .abstract:
            picked = nil   // 抽象色は写真を出さない
        case .album:
            picked = WidgetPhotoSelector.albumPick(from: index.entries, at: date)
        case .currentSky:
            // 今の局面に合う写真。無ければ nil＝グラデにフォールバック。
            picked = WidgetPhotoSelector.skyPick(from: index.entries, phase: currentPhase, at: date)
        }
        let path = picked.flatMap { WidgetCacheReader.imageURL(for: $0)?.path }
        return SkyEntry(date: date, mode: mode, phase: currentPhase, imagePath: path, postId: picked?.postId)
    }
}

// MARK: - View

struct SoramoyouWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    /// ファミリーごとのダウンサンプル長辺（小さいほど省メモリ）。
    private var maxPixel: CGFloat {
        switch family {
        case .systemSmall: return 400
        case .systemMedium: return 700
        case .systemLarge: return 900
        default: return 600
        }
    }

    /// 描画直前に 1 度だけダウンサンプルして読む。
    private var loadedImage: UIImage? {
        guard let path = entry.imagePath else { return nil }
        return WidgetImageLoader.downsampled(at: URL(fileURLWithPath: path), maxPixel: maxPixel)
    }

    var body: some View {
        // コンテンツは透明。空（写真 or グラデ）は containerBackground が全面に描く。
        Color.clear
            .containerBackground(for: .widget) {
                background
            }
            .widgetURL(WidgetDeepLink.post(entry.postId))
    }

    @ViewBuilder
    private var background: some View {
        if let image = loadedImage {
            photo(image)
        } else {
            AbstractSkyView(phase: entry.phase, date: entry.date)
        }
    }

    @ViewBuilder
    private func photo(_ image: UIImage) -> some View {
        if #available(iOS 18.0, *) {
            // iOS26 の tinted/clear でも写真はフルカラー維持。
            // widgetAccentedRenderingMode は Image 専用なので resizable 直後（scaledToFill より前）に置く。
            Image(uiImage: image)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFill()
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}

// MARK: - Widget

struct SoramoyouWidget: Widget {
    let kind: String = "SoramoyouWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            SoramoyouWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("そらもよう")
        .description("空の写真やグラデーションをホーム画面に表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    SoramoyouWidget()
} timeline: {
    SkyEntry(date: .now, mode: .abstract, phase: .goldenHour, imagePath: nil, postId: nil)
    SkyEntry(date: .now, mode: .abstract, phase: .night, imagePath: nil, postId: nil)
}
