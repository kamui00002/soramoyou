// ⭐️ CollageModels.swift
// 投稿の種別（単写真 / 配置写真 / 広角合成）と配置写真レイアウトの定義
//
//  Created on 2026-06-10.
//
//  機能: v1「配置写真（朝・昼・夜・雨などを並べる）」/ v2「広角合成（課金）」の共通データ。
//  - 保存は Firestore の固定文字列 raw value（表示名変更で壊れない・後方互換）。
//  - 旧投稿・通常投稿は postKind 欠落＝`.single` 相当として扱う（PostKind(rawValue:) が nil を返す）。
//  - 配置写真は「合成せず並べた1枚」を焼き込んで images に1枚だけ保存する（burn-in 方式）。
//    そのため表示側（ホーム/ギャラリー/詳細）は無改修で動く。
//

import SwiftUI

// MARK: - PostKind

/// 投稿の種別。未設定（旧投稿・通常投稿）は `.single` とみなす。
///
/// `.collage`=配置写真（並べる・合成しない・必ず成功・無料）、
/// `.panorama`=広角合成（OpenCV で1枚に繋ぐ・課金）。種別を持つことで
/// 「再編集を出さない」「抽出メタを付けない」等の分岐と、課金/図鑑の集計を一貫させる。
enum PostKind: String, Codable, CaseIterable, Identifiable {
    case single
    case collage
    case panorama

    var id: String { rawValue }

    /// 合成系（複数素材を1枚に畳んだ）投稿か判定する述語。
    /// 例: 「合成投稿は元素材を復元できないので再編集を出さない」等の判定に使える。
    var isComposite: Bool { self == .collage || self == .panorama }

    /// 投稿モード選択 UI 用の表示名
    var displayName: String {
        switch self {
        case .single:   return "通常"
        case .collage:  return "配置写真"
        case .panorama: return "広角合成"
        }
    }
}

// MARK: - CollageLayout

/// 配置写真のレイアウト（並べ方）。`.collage` のときのみ意味を持つ。
enum CollageLayout: String, Codable, CaseIterable, Identifiable {
    case grid2x2     // 2×2 グリッド（朝/昼/夜/雨 など4枚）
    case vertical4   // 縦1列4分割（時間の流れを縦に）

    var id: String { rawValue }

    /// 表示名（レイアウト選択 UI 用）
    var displayName: String {
        switch self {
        case .grid2x2:   return "2×2"
        case .vertical4: return "縦4分割"
        }
    }

    /// SF Symbols アイコン名（選択チップ用）
    var iconName: String {
        switch self {
        case .grid2x2:   return "square.grid.2x2"
        case .vertical4: return "rectangle.split.1x2"
        }
    }
}
