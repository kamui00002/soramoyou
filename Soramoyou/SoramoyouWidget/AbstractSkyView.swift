//
//  AbstractSkyView.swift
//  SoramoyouWidget
//
//  Mode C（抽象色）／写真が無い時に表示する「美しい空」。
//  写真ゼロでも映えるよう、深みのあるグラデ＋天体（太陽/月）＋星＋時刻ラベルで構成する。
//  ⚠️ widget セーフ: SwiftUI と同梱の SkyPhase のみ。
//

import SwiftUI

/// 局面ごとの抽象的な空（グラデ＋天体＋星＋時刻）。
struct AbstractSkyView: View {
    let phase: SkyPhase
    let date: Date

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 1. ベースグラデ（3 stop で深み）
                LinearGradient(colors: SkyDesign.gradientStops(for: phase), startPoint: .top, endPoint: .bottom)

                // 2. 星（夜・薄明のみ・奥に置く）
                if SkyDesign.showsStars(phase) {
                    stars(in: geo.size)
                }

                // 3. 天体（太陽 or 月＋グロー）
                celestial
                    .position(
                        x: geo.size.width * SkyDesign.celestialPosition(for: phase).x,
                        y: geo.size.height * SkyDesign.celestialPosition(for: phase).y
                    )

                // 4. 時刻＋局面ラベル（左下・控えめ）
                VStack(alignment: .leading, spacing: 0) {
                    Text(phase.displayName)
                        .font(.caption).fontWeight(.semibold)
                    Text(date, style: .time)
                        .font(.caption2)
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(12)
            }
        }
    }

    /// 太陽 or 月（柔らかいグローつき）。
    @ViewBuilder
    private var celestial: some View {
        let isSun = SkyDesign.isSun(phase)
        ZStack {
            Circle()
                .fill(isSun ? Color.yellow.opacity(0.35) : Color.white.opacity(0.22))
                .frame(width: 60, height: 60)
                .blur(radius: 13)
            Circle()
                .fill(
                    isSun
                    ? LinearGradient(colors: [.white, Color(red: 1.0, green: 0.85, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    : LinearGradient(colors: [Color(white: 0.97), Color(white: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 28, height: 28)
        }
    }

    /// 固定位置の星々（決定的・チラつきなし）。
    private func stars(in size: CGSize) -> some View {
        ForEach(Array(SkyDesign.stars.enumerated()), id: \.offset) { _, star in
            Circle()
                .fill(.white)
                .frame(width: star.size, height: star.size)
                .opacity(star.opacity)
                .position(x: size.width * star.x, y: size.height * star.y)
        }
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

    /// 天体の相対位置（0...1）。
    static func celestialPosition(for phase: SkyPhase) -> (x: CGFloat, y: CGFloat) {
        switch phase {
        case .dawn: return (0.78, 0.36)
        case .morning: return (0.74, 0.26)
        case .day: return (0.50, 0.18)
        case .goldenHour: return (0.28, 0.34)
        case .dusk: return (0.24, 0.40)
        case .night: return (0.72, 0.24)
        }
    }

    /// 固定の星の配置（相対座標・サイズ・不透明度）。
    static let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double)] = [
        (0.12, 0.18, 2.0, 0.90), (0.22, 0.30, 1.5, 0.55), (0.34, 0.12, 2.5, 0.80), (0.46, 0.22, 1.5, 0.50),
        (0.58, 0.14, 2.0, 0.85), (0.66, 0.33, 1.5, 0.55), (0.18, 0.46, 1.5, 0.50), (0.40, 0.40, 2.0, 0.70),
        (0.86, 0.20, 1.5, 0.60), (0.92, 0.40, 2.0, 0.75), (0.08, 0.34, 1.5, 0.50), (0.52, 0.50, 1.5, 0.45),
        (0.30, 0.56, 1.5, 0.50), (0.72, 0.52, 2.0, 0.60), (0.62, 0.46, 1.5, 0.50), (0.84, 0.58, 1.5, 0.50)
    ]
}
