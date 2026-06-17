//
//  AbstractSkyView.swift
//  SoramoyouWidget
//
//  Mode C（抽象色）／写真が無い時に表示する「美しい空」。
//  サイズ（small/medium/large）に応じて天体・星・雲・ラベルを拡大し、大きいウィジェットでも
//  寂しくならないよう、大気グロー・雲・地平のかすみで奥行きを足す。
//  ⚠️ widget セーフ: SwiftUI と同梱の SkyPhase のみ。
//

import SwiftUI
import WidgetKit

/// 局面ごとの抽象的な空（グラデ＋大気グロー＋星/雲＋天体＋地平かすみ＋時刻）。
struct AbstractSkyView: View {
    @Environment(\.widgetFamily) private var family
    let phase: SkyPhase
    let date: Date

    /// サイズに応じた拡大率（大ウィジェットの間延びを防ぐ）。
    private var sizeScale: CGFloat {
        switch family {
        case .systemSmall: return 1.0
        case .systemMedium: return 1.25
        case .systemLarge: return 1.75
        default: return 1.0
        }
    }
    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            let pos = SkyDesign.celestialPosition(for: phase)
            ZStack {
                // 1. ベースグラデ
                LinearGradient(colors: SkyDesign.gradientStops(for: phase), startPoint: .top, endPoint: .bottom)

                // 2. 天体まわりの大気グロー（豪華さの肝）
                RadialGradient(
                    colors: [(SkyDesign.isSun(phase) ? Color.yellow : Color.white).opacity(0.30), .clear],
                    center: .center, startRadius: 0, endRadius: 95 * sizeScale
                )
                .frame(width: 190 * sizeScale, height: 190 * sizeScale)
                .position(x: s.width * pos.x, y: s.height * pos.y)
                .blendMode(.screen)

                // 3. 星（夜・薄明・大サイズは増量）
                if SkyDesign.showsStars(phase) {
                    stars(in: s)
                }

                // 4. 雲（昼系・「天気の時の寂しさ」対策）
                if SkyDesign.showsClouds(phase) {
                    clouds(in: s)
                }

                // 5. 天体本体（太陽 or 月）
                celestial
                    .position(x: s.width * pos.x, y: s.height * pos.y)

                // 6. 地平のかすみ（下方向に局面色をうっすら）
                LinearGradient(colors: [.clear, SkyDesign.horizonHaze(for: phase)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)

                // 7. 時刻＋局面ラベル
                label
            }
            .ignoresSafeArea()
        }
    }

    /// 太陽 or 月（柔らかいグローつき・サイズ拡大）。
    private var celestial: some View {
        let isSun = SkyDesign.isSun(phase)
        return ZStack {
            Circle()
                .fill(isSun ? Color.yellow.opacity(0.35) : Color.white.opacity(0.22))
                .frame(width: 60 * sizeScale, height: 60 * sizeScale)
                .blur(radius: 13 * sizeScale)
            Circle()
                .fill(
                    isSun
                    ? LinearGradient(colors: [.white, Color(red: 1.0, green: 0.85, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color(white: 0.97), Color(white: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 28 * sizeScale, height: 28 * sizeScale)
        }
    }

    /// 固定位置の星々（決定的・サイズ拡大・大サイズは増量＋淡い光彩）。
    private func stars(in size: CGSize) -> some View {
        let list = isLarge ? SkyDesign.stars + SkyDesign.starsExtra : SkyDesign.stars
        return ForEach(Array(list.enumerated()), id: \.offset) { _, star in
            Circle()
                .fill(.white)
                .frame(width: star.size * sizeScale, height: star.size * sizeScale)
                .opacity(star.opacity)
                .shadow(color: .white.opacity(star.opacity * 0.7), radius: star.size * sizeScale * 0.9)
                .position(x: size.width * star.x, y: size.height * star.y)
        }
    }

    /// 昼系の柔らかい雲（ぼかしただ円を重ねる）。
    private func clouds(in size: CGSize) -> some View {
        let tint = SkyDesign.cloudTint(for: phase)
        return ForEach(Array(SkyDesign.clouds.enumerated()), id: \.offset) { _, cloud in
            Ellipse()
                .fill(tint.opacity(cloud.opacity))
                .frame(width: cloud.w * size.width, height: cloud.h * size.width)
                .blur(radius: 9 * sizeScale)
                .position(x: size.width * cloud.x, y: size.height * cloud.y)
        }
    }

    /// 局面名＋時刻（サイズで拡大）。
    private var label: some View {
        VStack(alignment: .leading, spacing: isLarge ? 2 : 0) {
            Text(phase.displayName)
                .font(isLarge ? .title3 : .caption)
                .fontWeight(.semibold)
            Text(date, style: .time)
                .font(isLarge ? .headline : .caption2)
                .opacity(0.9)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(isLarge ? 18 : 12)
    }
}

/// 抽象スカイの配色・配置データ（純データ）。
enum SkyDesign {
    /// 局面ごとの 3 stop グラデ（上 → 下）。
    static func gradientStops(for phase: SkyPhase) -> [Color] {
        switch phase {
        case .night:
            return [Color(red: 0.03, green: 0.04, blue: 0.12), Color(red: 0.07, green: 0.09, blue: 0.22), Color(red: 0.13, green: 0.16, blue: 0.32)]
        case .dawn:
            return [Color(red: 0.13, green: 0.13, blue: 0.30), Color(red: 0.46, green: 0.32, blue: 0.46), Color(red: 0.96, green: 0.63, blue: 0.50)]
        case .morning:
            return [Color(red: 0.30, green: 0.58, blue: 0.90), Color(red: 0.58, green: 0.78, blue: 0.96), Color(red: 0.87, green: 0.94, blue: 0.99)]
        case .day:
            return [Color(red: 0.13, green: 0.45, blue: 0.90), Color(red: 0.35, green: 0.66, blue: 0.96), Color(red: 0.75, green: 0.89, blue: 0.99)]
        case .goldenHour:
            return [Color(red: 0.99, green: 0.75, blue: 0.34), Color(red: 0.98, green: 0.55, blue: 0.32), Color(red: 0.90, green: 0.38, blue: 0.43)]
        case .dusk:
            return [Color(red: 0.16, green: 0.13, blue: 0.35), Color(red: 0.46, green: 0.24, blue: 0.47), Color(red: 0.83, green: 0.43, blue: 0.46)]
        }
    }

    /// 太陽を出す局面か（false なら月）。
    static func isSun(_ phase: SkyPhase) -> Bool {
        switch phase {
        case .morning, .day, .goldenHour: return true
        case .night, .dawn, .dusk: return false
        }
    }

    /// 星を出す局面か。
    static func showsStars(_ phase: SkyPhase) -> Bool {
        switch phase {
        case .night, .dawn, .dusk: return true
        case .morning, .day, .goldenHour: return false
        }
    }

    /// 雲を出す局面か（昼系。日中の寂しさ対策）。
    static func showsClouds(_ phase: SkyPhase) -> Bool {
        switch phase {
        case .morning, .day, .goldenHour: return true
        case .night, .dawn, .dusk: return false
        }
    }

    /// 雲の色味（黄金時は暖色寄り）。
    static func cloudTint(for phase: SkyPhase) -> Color {
        switch phase {
        case .goldenHour: return Color(red: 1.0, green: 0.93, blue: 0.86)
        default: return .white
        }
    }

    /// 地平のかすみ色（局面で変化）。
    static func horizonHaze(for phase: SkyPhase) -> Color {
        switch phase {
        case .night: return Color(red: 0.10, green: 0.13, blue: 0.28).opacity(0.55)
        case .dawn: return Color(red: 0.98, green: 0.70, blue: 0.55).opacity(0.45)
        case .morning: return Color(red: 0.85, green: 0.93, blue: 0.99).opacity(0.50)
        case .day: return Color(red: 0.78, green: 0.90, blue: 0.99).opacity(0.50)
        case .goldenHour: return Color(red: 0.98, green: 0.55, blue: 0.42).opacity(0.50)
        case .dusk: return Color(red: 0.55, green: 0.35, blue: 0.45).opacity(0.50)
        }
    }

    /// 天体の相対位置（0...1）。
    static func celestialPosition(for phase: SkyPhase) -> (x: CGFloat, y: CGFloat) {
        switch phase {
        case .dawn: return (0.78, 0.34)
        case .morning: return (0.76, 0.24)
        case .day: return (0.50, 0.18)
        case .goldenHour: return (0.26, 0.32)
        case .dusk: return (0.24, 0.38)
        case .night: return (0.74, 0.22)
        }
    }

    /// 基本の星の配置（相対座標・サイズ・不透明度）。
    static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.12, 0.18, 2.0, 0.90), (0.22, 0.30, 1.5, 0.55), (0.34, 0.12, 2.5, 0.80), (0.46, 0.22, 1.5, 0.50),
        (0.58, 0.14, 2.0, 0.85), (0.66, 0.33, 1.5, 0.55), (0.18, 0.46, 1.5, 0.50), (0.40, 0.40, 2.0, 0.70),
        (0.86, 0.20, 1.5, 0.60), (0.92, 0.40, 2.0, 0.75), (0.08, 0.34, 1.5, 0.50), (0.52, 0.50, 1.5, 0.45),
        (0.30, 0.56, 1.5, 0.50), (0.72, 0.52, 2.0, 0.60), (0.62, 0.46, 1.5, 0.50), (0.84, 0.58, 1.5, 0.50)
    ]

    /// 大ウィジェット用の追加の星（密度を上げて豪華に）。
    static let starsExtra: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.16, 0.62, 1.5, 0.45), (0.26, 0.70, 2.0, 0.55), (0.44, 0.64, 1.5, 0.50), (0.56, 0.72, 1.5, 0.45),
        (0.70, 0.66, 2.0, 0.60), (0.82, 0.72, 1.5, 0.50), (0.10, 0.74, 1.5, 0.40), (0.90, 0.62, 1.5, 0.50),
        (0.38, 0.30, 2.5, 0.70), (0.50, 0.10, 2.0, 0.65), (0.78, 0.40, 1.5, 0.45), (0.20, 0.10, 1.5, 0.55)
    ]

    /// 昼系の雲（相対座標・幅/高さは width 比・不透明度）。
    static let clouds: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, opacity: Double)] = [
        (0.32, 0.30, 0.46, 0.15, 0.55),
        (0.70, 0.20, 0.36, 0.12, 0.45),
        (0.52, 0.46, 0.52, 0.16, 0.40),
        (0.16, 0.54, 0.32, 0.11, 0.38)
    ]
}
