//
//  SkyType.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 空の種類
enum SkyType: String, Codable, CaseIterable {
    case clear = "clear"
    case cloudy = "cloudy"
    case sunset = "sunset"
    case sunrise = "sunrise"
    case storm = "storm"

    /// 表示名
    var displayName: String {
        switch self {
        case .clear: return "晴れ"
        case .cloudy: return "曇り"
        case .sunset: return "夕焼け"
        case .sunrise: return "朝焼け"
        case .storm: return "嵐"
        }
    }

    /// SF Symbolsアイコン名 ☀️
    var iconName: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .cloudy: return "cloud.fill"
        case .sunset: return "sunset.fill"
        case .sunrise: return "sunrise.fill"
        case .storm: return "cloud.bolt.rain.fill"
        }
    }
}




