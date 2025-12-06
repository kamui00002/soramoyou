//
//  ImageInfo.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation

/// 画像情報Value Object
struct ImageInfo: Codable, Equatable {
    let url: String
    let thumbnail: String?
    let width: Int
    let height: Int
    let order: Int
    
    init(
        url: String,
        thumbnail: String? = nil,
        width: Int,
        height: Int,
        order: Int
    ) {
        self.url = url
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
        self.order = order
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
    }
}

