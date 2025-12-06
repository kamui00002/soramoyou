//
//  FilterType.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 画像フィルターの種類
enum FilterType: String, Codable, CaseIterable {
    case natural = "natural"
    case clear = "clear"
    case drama = "drama"
    case soft = "soft"
    case warm = "warm"
    case cool = "cool"
    case vintage = "vintage"
    case monochrome = "monochrome"
    case pastel = "pastel"
    case vivid = "vivid"
    
    /// 表示名
    var displayName: String {
        switch self {
        case .natural: return "ナチュラル"
        case .clear: return "クリア"
        case .drama: return "ドラマ"
        case .soft: return "ソフト"
        case .warm: return "ウォーム"
        case .cool: return "クール"
        case .vintage: return "ビンテージ"
        case .monochrome: return "モノクロ"
        case .pastel: return "パステル"
        case .vivid: return "ヴィヴィッド"
        }
    }
}


