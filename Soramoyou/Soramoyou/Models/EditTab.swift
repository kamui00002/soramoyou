// ⭐️ EditTab.swift
// 編集画面のタブ種別を定義する列挙型
//
// そらもよう - 空を撮る、空を集める
// 編集画面UI改善で追加

import Foundation
import SwiftUI

/// 編集画面のタブ種別
/// - フィルター: 写真フィルターの選択
/// - 編集ツール: 露出・コントラスト等の調整
/// - 切り取り: 回転・反転・トリミング
enum EditTab: String, CaseIterable, Identifiable {
    case filter = "フィルター"
    case adjustment = "編集ツール"
    case crop = "切り取り"

    var id: String { rawValue }

    /// タブのアイコン名（SF Symbols）
    var iconName: String {
        switch self {
        case .filter:
            return "camera.filters"
        case .adjustment:
            return "slider.horizontal.3"
        case .crop:
            return "crop.rotate"
        }
    }

    /// タブの表示名
    var displayName: String {
        rawValue
    }
}

/// 切り取り機能のアスペクト比
enum CropAspectRatio: String, CaseIterable, Identifiable {
    case free = "フリー"
    case square = "1:1"
    case fourThree = "4:3"
    case sixteenNine = "16:9"

    var id: String { rawValue }

    /// アスペクト比の値（nil の場合はフリー）
    var ratio: CGFloat? {
        switch self {
        case .free:
            return nil
        case .square:
            return 1.0
        case .fourThree:
            return 4.0 / 3.0
        case .sixteenNine:
            return 16.0 / 9.0
        }
    }

    /// 表示名
    var displayName: String {
        rawValue
    }
}

/// 回転・反転の種類
enum CropTransformType {
    case rotateLeft      // 左に90度回転
    case rotateRight     // 右に90度回転
    case flipHorizontal  // 左右反転
    case flipVertical    // 上下反転
}
