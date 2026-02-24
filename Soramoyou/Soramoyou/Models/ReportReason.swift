//
//  ReportReason.swift
//  Soramoyou
//
//  通報理由の定義
//

import Foundation

/// 投稿の通報理由
enum ReportReason: String, CaseIterable {
    case inappropriate = "inappropriate"
    case spam = "spam"
    case harassment = "harassment"
    case copyright = "copyright"
    case other = "other"
    
    /// 日本語の表示名
    var displayName: String {
        switch self {
        case .inappropriate:
            return "不適切なコンテンツ"
        case .spam:
            return "スパム・迷惑行為"
        case .harassment:
            return "嫌がらせ・誹謗中傷"
        case .copyright:
            return "著作権侵害"
        case .other:
            return "その他"
        }
    }
}
