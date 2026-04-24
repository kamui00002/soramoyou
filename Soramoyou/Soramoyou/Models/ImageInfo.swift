//
//  ImageInfo.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//
//  🔧 2026-04-24 修正 (ultrareview bug_002):
//    - Firebase Storage の保存パスを storagePath / thumbnailStoragePath に記録。
//      削除時に download URL からパスを再構築する必要がなくなり、
//      アップロード時と 100% 一致するパスを使えるため、投稿削除時の
//      orphan file（Storage に画像が残り続ける問題）を根本解決。
//    - 旧データ互換のため両フィールドは Optional。
//

import Foundation

/// 画像情報Value Object
struct ImageInfo: Codable, Equatable {
    let url: String
    let thumbnail: String?
    let width: Int
    let height: Int
    let order: Int
    /// Firebase Storage 内のパス（例: `posts/{userId}/{visibility}/{imageId}.jpg`）。
    /// 削除・再アップロード時の識別に使う。旧データは nil の可能性があるため Optional。
    let storagePath: String?
    /// サムネイル画像の Firebase Storage パス。
    let thumbnailStoragePath: String?

    init(
        url: String,
        thumbnail: String? = nil,
        width: Int,
        height: Int,
        order: Int,
        storagePath: String? = nil,
        thumbnailStoragePath: String? = nil
    ) {
        self.url = url
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
        self.order = order
        self.storagePath = storagePath
        self.thumbnailStoragePath = thumbnailStoragePath
    }

    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "url": url,
            "width": width,
            "height": height,
            "order": order
        ]

        if let thumbnail = thumbnail {
            data["thumbnail"] = thumbnail
        }
        if let storagePath = storagePath {
            data["storagePath"] = storagePath
        }
        if let thumbnailStoragePath = thumbnailStoragePath {
            data["thumbnailStoragePath"] = thumbnailStoragePath
        }

        return data
    }

    /// Firestoreドキュメントデータから初期化
    init?(from documentData: [String: Any]) {
        guard let url = documentData["url"] as? String,
              let width = documentData["width"] as? Int,
              let height = documentData["height"] as? Int,
              let order = documentData["order"] as? Int else {
            return nil
        }

        self.url = url
        self.thumbnail = documentData["thumbnail"] as? String
        self.width = width
        self.height = height
        self.order = order
        self.storagePath = documentData["storagePath"] as? String
        self.thumbnailStoragePath = documentData["thumbnailStoragePath"] as? String
    }
}
