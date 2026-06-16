//
//  SkyPhase.swift
//  Soramoyou
//
//  太陽イベント（薄明・日の出・南中・黄金時間・日没）を基準にした「今の空の局面」6 段階。
//  - Mode C（抽象色）: この phase ごとに空のグラデーションを描く。
//  - Mode B（今の空）: phase を 4 区分 `TimeOfDay`（朝/昼/夕/夜）へ畳み、自作写真のタグと突き合わせる。
//
//  設計:
//    - 局面判定は **純関数** `phase(at:transitions:)`。太陽の瞬間を境界に比較するだけで、
//      `SolarCalculator` への依存も `Date()`（現在時刻）への暗黙依存も無い＝テストが容易。
//    - `current(...)` が `SolarCalculator` を呼んで当日の太陽イベントを揃え、純関数へ渡す。
//      白夜・極夜（日の出/日没が無い高緯度）は時計ベースのフォールバックに落とす（日本では発生しない）。
//
//  ⚠️ widget セーフ: Foundation と同梱の `SolarCalculator` / `TimeOfDay` のみに依存。
//

import Foundation

/// 太陽イベント基準の空の局面（6 段階）。
enum SkyPhase: String, Codable, CaseIterable {
    /// 夜（市民薄明より太陽が低い・薄明前と薄明後の両方）。
    case night
    /// 夜明けの薄明（市民薄明開始〜日の出）。
    case dawn
    /// 朝（日の出〜南中帯の手前）。
    case morning
    /// 日中（南中帯〜黄金時間の手前）。
    case day
    /// 黄金時間（日没の少し前〜日没）。
    case goldenHour
    /// 夕暮れの薄明（日没〜市民薄明終了）。
    case dusk

    /// 4 区分 `TimeOfDay` への写像（Mode B の写真マッチ用）。
    /// - 朝＝{dawn, morning} / 昼＝{day} / 夕＝{goldenHour, dusk} / 夜＝{night}。
    var timeOfDay: TimeOfDay {
        switch self {
        case .night: return .night
        case .dawn, .morning: return .morning
        case .day: return .afternoon
        case .goldenHour, .dusk: return .evening
        }
    }

    /// 表示名（デバッグ・UI 用）。
    var displayName: String {
        switch self {
        case .night: return "夜"
        case .dawn: return "夜明け"
        case .morning: return "朝"
        case .day: return "日中"
        case .goldenHour: return "黄金時間"
        case .dusk: return "夕暮れ"
        }
    }

    // MARK: - 当日の太陽イベント境界

    /// 局面判定に使う当日の太陽イベント一式＋チューニング値。
    /// - 太陽イベントは白夜・極夜で nil になり得るため Optional。
    struct SolarTransitions: Equatable {
        /// 市民薄明の開始（夜明け前・-6°）。
        let civilDawn: Date?
        /// 日の出。
        let sunrise: Date?
        /// 南中。
        let solarNoon: Date?
        /// 日没。
        let sunset: Date?
        /// 市民薄明の終了（日没後・-6°）。
        let civilDusk: Date?
        /// 南中帯（day）の半幅（秒）。`solarNoon - noonHalfWidth` から day が始まる。
        let noonHalfWidth: TimeInterval
        /// 黄金時間のリード（秒）。`sunset - goldenHourLead` から goldenHour が始まる。
        let goldenHourLead: TimeInterval
    }

    /// 既定の南中帯半幅（90 分）。Decision 4（後から調整可）。
    static let defaultNoonHalfWidth: TimeInterval = 90 * 60
    /// 既定の黄金時間リード（75 分）。既存ゴールデンアワー通知の既定と揃える。
    static let defaultGoldenHourLead: TimeInterval = 75 * 60

    // MARK: - 純関数（境界比較のみ）

    /// 与えられた太陽イベント境界に対し、時刻 `t` がどの局面かを判定する純関数。
    /// - Note: 通常日（`sunrise`/`sunset` が存在する）を前提に設計。極夜の全 nil ケースは
    ///   `current(...)` 側で時計フォールバックに振り分けるため、ここには到達しない。
    static func phase(at t: Date, transitions tr: SolarTransitions) -> SkyPhase {
        // 日の出前: 薄明開始を過ぎていれば dawn、未満は night。
        if let sunrise = tr.sunrise, t < sunrise {
            if let dawn = tr.civilDawn, t >= dawn { return .dawn }
            return .night
        }
        // 日没後: 薄明終了より前なら dusk、以降は night。
        if let sunset = tr.sunset, t >= sunset {
            if let dusk = tr.civilDusk, t < dusk { return .dusk }
            return .night
        }
        // 日中（sunrise <= t < sunset）。南中帯の手前は morning。
        if let noon = tr.solarNoon {
            let middayStart = noon.addingTimeInterval(-tr.noonHalfWidth)
            if t < middayStart { return .morning }
        }
        // 黄金時間の開始以降は goldenHour、それ以外（南中帯〜黄金時間手前）は day。
        if let sunset = tr.sunset {
            let goldenStart = sunset.addingTimeInterval(-tr.goldenHourLead)
            if t >= goldenStart { return .goldenHour }
        }
        return .day
    }

    // MARK: - 便利関数（SolarCalculator と統合）

    /// 指定地点・時刻の空の局面を返す。太陽イベントを `SolarCalculator` で計算する。
    /// - Parameters:
    ///   - t: 判定する時刻（テストで固定可能）。
    ///   - noonHalfWidthMinutes / goldenHourLeadMinutes: チューニング（Decision 4・後調整可）。
    /// - Returns: 通常日は太陽ベースの局面。日の出/日没が計算できない高緯度は時計ベースのフォールバック。
    static func current(
        at t: Date,
        latitude: Double,
        longitude: Double,
        timeZone: TimeZone,
        noonHalfWidthMinutes: Double = 90,
        goldenHourLeadMinutes: Double = 75
    ) -> SkyPhase {
        let sunrise = SolarCalculator.sunrise(latitude: latitude, longitude: longitude, date: t, timeZone: timeZone)
        let sunset = SolarCalculator.sunset(latitude: latitude, longitude: longitude, date: t, timeZone: timeZone)

        // 白夜・極夜（日の出か日没が無い）は時計ベースにフォールバック。
        guard sunrise != nil, sunset != nil else {
            return fallbackPhase(for: t, timeZone: timeZone)
        }

        let transitions = SolarTransitions(
            civilDawn: SolarCalculator.civilDawn(latitude: latitude, longitude: longitude, date: t, timeZone: timeZone),
            sunrise: sunrise,
            solarNoon: SolarCalculator.solarNoon(longitude: longitude, date: t, timeZone: timeZone),
            sunset: sunset,
            civilDusk: SolarCalculator.civilDusk(latitude: latitude, longitude: longitude, date: t, timeZone: timeZone),
            noonHalfWidth: noonHalfWidthMinutes * 60,
            goldenHourLead: goldenHourLeadMinutes * 60
        )
        return phase(at: t, transitions: transitions)
    }

    /// 太陽イベントが計算できない場合の時計ベースのフォールバック（既存 `TimeOfDay.from` 由来）。
    static func fallbackPhase(for t: Date, timeZone: TimeZone) -> SkyPhase {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: t)
        switch hour {
        case 5..<7: return .dawn
        case 7..<11: return .morning
        case 11..<15: return .day
        case 15..<18: return .goldenHour
        case 18..<20: return .dusk
        default: return .night
        }
    }
}
