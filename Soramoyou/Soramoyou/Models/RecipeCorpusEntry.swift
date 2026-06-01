// ⭐️ RecipeCorpusEntry.swift
// パーソナルAI編集の学習データ 1 件（あなたの過去の仕上げ）
//
//  RecipeCorpusEntry.swift
//  Soramoyou
//

import Foundation

/// ユーザー自身の「確定した編集レシピ」を 1 件記録するコーパスエントリ。
///
/// 設計方針:
/// - パーソナルAI編集（柱1）の学習データの最小単位。投稿/保存の確定時に追記する。
/// - `skyType` 別に「あなたの定番」を集計するため、撮影空タイプを併せて保持する。
/// - `Codable`: ローカル JSON への永続化に使用（`RecipeCorpusStore`）。
/// - 画像・位置などの個人情報は含めない（表現パラメータのみ）。プライバシー配慮。
struct RecipeCorpusEntry: Codable, Equatable {
    /// 確定した編集レシピ（完全版）
    let recipe: EditRecipe
    /// その写真の空タイプ（未判定なら nil）。skyType 別集計のキーに使う。
    let skyType: SkyType?
    /// 撮影日時（EXIF 由来、無ければ nil）。将来の季節・時間帯別集計に使う。
    let capturedAt: Date?
    /// この編集を確定・記録した日時。新しさによる重み付けに使う。
    let savedAt: Date

    init(recipe: EditRecipe, skyType: SkyType?, capturedAt: Date? = nil, savedAt: Date = Date()) {
        self.recipe = recipe
        self.skyType = skyType
        self.capturedAt = capturedAt
        self.savedAt = savedAt
    }
}
