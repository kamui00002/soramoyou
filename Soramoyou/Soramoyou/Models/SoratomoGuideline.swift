//
//  SoratomoGuideline.swift
//  Soramoyou
//
//  そらともガイドライン（作成・参加・入口で同意を求める決まり）⭐️
//  （release-gate 8・design.md の「同意」の節）
//
//  いまは版の定数だけを持つ。本文の 4 つの節・同意の状態を読むサービス・全文の画面は release-gate 9.5 で足す。
//

import Foundation

/// そらともガイドライン
enum SoratomoGuideline {
    /// このアプリが知っているガイドラインの版
    ///
    /// サーバーが拒否に付ける版（`consent_required`・`outdated_guideline` の `details.currentVersion`）がこれより大きければ、
    /// アプリが古いので、全文を出さずにアップデートを案内する（`SoratomoGroupService.mapCallableError`）。
    /// ⚠️ functions/soratomoCore.js の GUIDELINE_VERSION と一致させる（両方の単体テストで値を固定している）
    static let currentVersion = 1
}
