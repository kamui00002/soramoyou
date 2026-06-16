//
//  WidgetIndex.swift
//  Soramoyou
//
//  本体アプリがウィジェット向けに App Group へ書き出す「キャッシュ一覧」のモデル。
//  本体が投稿時/バックフィル時に書き、ウィジェット拡張は *読むだけ*。
//
//  設計の要点:
//    - 画像は **相対ファイル名** で持つ（`AppGroup.imagesDirectoryURL` 配下の名前のみ）。
//      コンテナの絶対パスはプロセス・再インストールで変わり得るため、絶対 URL を
//      保存すると別プロセス（ウィジェット）で解決できず空表示になる。
//    - リモート URL（Firebase の `ImageInfo.thumbnail`）は **持たない**。
//      ウィジェットは通信せずローカル JPEG だけを描画する（オフライン安全・30MB対策）。
//    - `timeOfDay` は `TimeOfDay.rawValue`（"morning"/"afternoon"/"evening"/"night"）を String で保持。
//      enum 依存を避け widget セーフに保つ。旧投稿は nil。
//
//  ⚠️ widget セーフ: Foundation のみ。両ターゲットに Target Membership で所属させる。
//

import Foundation

/// ウィジェットキャッシュのインデックス（`widget_index.json` の中身）。
struct WidgetIndex: Codable, Equatable {

    /// スキーマ版。将来フィールドを増やしたときの前方互換判定に使う。
    var schemaVersion: Int
    /// 本体が最後に書き出した時刻（デバッグ・鮮度判定用）。
    var updatedAt: Date
    /// キャッシュ済み投稿の一覧（新しい順で保存する想定）。
    var entries: [Entry]

    /// 現行スキーマ版。フィールド追加時にインクリメントする。
    static let currentSchemaVersion = 1

    /// 空のインデックス（コンテナ未初期化・全削除後の既定値）。
    static let empty = WidgetIndex(
        schemaVersion: currentSchemaVersion,
        updatedAt: Date(timeIntervalSince1970: 0),
        entries: []
    )

    /// 1 投稿ぶんのキャッシュエントリ。
    struct Entry: Codable, Equatable, Identifiable {
        /// 投稿 ID。タップ時のディープリンク（`soramoyou://post/{id}`）に使う。
        let postId: String
        /// `AppGroup.imagesDirectoryURL` 配下の相対ファイル名（例 "ABC123.jpg"）。
        let imageFileName: String
        /// 時間帯タグ（`TimeOfDay.rawValue`）。Mode B の写真マッチに使う。旧投稿は nil。
        let timeOfDay: String?
        /// 抽出された空の色（"#RRGGBB" 最大5色）。Mode C のフォールバック彩色に使う。無ければ空配列。
        let skyColors: [String]
        /// 投稿日時。ローテーション順・鮮度判定に使う。
        let createdAt: Date

        /// `Identifiable` 準拠（SwiftUI の ForEach 等で使うため）。
        var id: String { postId }
    }
}
