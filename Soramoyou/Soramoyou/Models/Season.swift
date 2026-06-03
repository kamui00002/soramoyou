//
//  Season.swift
//  Soramoyou
//
//  空コレクション図鑑（柱2）の季節軸。
//

import Foundation

/// 季節（図鑑の収集軸の1つ）
enum Season: String, Codable, CaseIterable {
    case spring
    case summer
    case autumn
    case winter

    /// 表示名
    var displayName: String {
        switch self {
        case .spring: return "春"
        case .summer: return "夏"
        case .autumn: return "秋"
        case .winter: return "冬"
        }
    }

    /// SF Symbols アイコン名 ☀️
    var iconName: String {
        switch self {
        case .spring: return "leaf.fill"
        case .summer: return "sun.max.fill"
        case .autumn: return "wind"
        case .winter: return "snowflake"
        }
    }

    /// 日付（月）から季節を判定する。
    /// 3〜5月=春 / 6〜8月=夏 / 9〜11月=秋 / 12・1・2月=冬。
    static func from(date: Date) -> Season {
        let month = Calendar.current.component(.month, from: date)
        switch month {
        case 3...5:   return .spring
        case 6...8:   return .summer
        case 9...11:  return .autumn
        default:      return .winter   // 12, 1, 2
        }
    }
}
