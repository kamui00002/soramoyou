//
//  Visibility.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 投稿の公開設定
enum Visibility: String, Codable, CaseIterable {
    case `public` = "public"
    case followers = "followers"
    case `private` = "private"
    
    /// 表示名
    var displayName: String {
        switch self {
        case .public: return "公開"
        case .followers: return "フォロワーのみ"
        case .private: return "非公開"
        }
    }
}




