//
//  TimeOfDay.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 時間帯
enum TimeOfDay: String, Codable, CaseIterable {
    case morning = "morning"
    case afternoon = "afternoon"
    case evening = "evening"
    case night = "night"
    
    /// 表示名
    var displayName: String {
        switch self {
        case .morning: return "朝"
        case .afternoon: return "昼"
        case .evening: return "夕方"
        case .night: return "夜"
        }
    }
    
    /// 時刻から時間帯を判定
    static func from(date: Date) -> TimeOfDay {
        let hour = Calendar.current.component(.hour, from: date)
        
        switch hour {
        case 5..<12:
            return .morning
        case 12..<17:
            return .afternoon
        case 17..<20:
            return .evening
        default:
            return .night
        }
    }
}


