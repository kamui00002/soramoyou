//
//  Draft.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseFirestore

/// 下書きエンティティ
struct Draft: Identifiable, Codable {
    let id: String
    let userId: String
    let images: [ImageInfo]
    let editedImages: [ImageInfo]?
    let editSettings: EditSettings?
    /// 【Phase 2 追加】EditRecipe V1 フォーマット（新形式）
    ///
    /// 読み込み優先順位: editRecipeV1 → editSettings → デフォルト値
    ///
    /// 後方互換戦略: 旧 `editSettings` フィールドはそのまま維持し、
    /// 旧バージョンのアプリでも読み込めるようにする。
    /// `editRecipeV1` は新フィールドとして並列で追加。
    let editRecipeV1: EditRecipe?
    let caption: String?
    let hashtags: [String]?
    let location: Location?
    let visibility: Visibility
    let createdAt: Date
    var updatedAt: Date

    /// 最も適切な EditRecipe を返す（優先度: editRecipeV1 > editSettings > default）
    var resolvedRecipe: EditRecipe {
        if let recipe = editRecipeV1 { return recipe }
        if let settings = editSettings { return EditRecipe(from: settings) }
        return EditRecipe()
    }

    init(
        id: String,
        userId: String,
        images: [ImageInfo],
        editedImages: [ImageInfo]? = nil,
        editSettings: EditSettings? = nil,
        editRecipeV1: EditRecipe? = nil,
        caption: String? = nil,
        hashtags: [String]? = nil,
        location: Location? = nil,
        visibility: Visibility = .public,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.images = images
        self.editedImages = editedImages
        self.editSettings = editSettings
        self.editRecipeV1 = editRecipeV1
        self.caption = caption
        self.hashtags = hashtags
        self.location = location
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    // MARK: - Firestore Mapping
    
    /// Firestoreドキュメントデータに変換
    /// 注意: firestore.rules が 'id' フィールドを期待するため、'id' をキーとして使用
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "id": id,
            "userId": userId,
            "images": images.map { $0.toFirestoreData() },
            "visibility": visibility.rawValue,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]
        
        if let editedImages = editedImages {
            data["editedImages"] = editedImages.map { $0.toFirestoreData() }
        }
        
        if let editSettings = editSettings {
            data["editSettings"] = editSettings.toFirestoreData()
        }

        // 【Phase 2】editRecipeV1 を新フィールドとして並列で保存
        // 旧 editSettings フィールドはそのまま維持（旧バージョンのアプリでも読める）
        if let recipe = editRecipeV1 {
            data["editRecipeV1"] = recipe.toFirestoreData()
        }

        if let caption = caption {
            data["caption"] = caption
        }
        
        if let hashtags = hashtags {
            data["hashtags"] = hashtags
        }
        
        if let location = location {
            data["location"] = location.toFirestoreData()
        }
        
        return data
    }
    
    /// Firestoreドキュメントデータから初期化
    /// 注意: 'id' と 'draftId' の両方をサポート（後方互換性のため）
    init(from documentData: [String: Any]) throws {
        // 'id' フィールドを優先、なければ 'draftId' を使用（後方互換性）
        guard let draftId = documentData["id"] as? String ?? documentData["draftId"] as? String,
              let userId = documentData["userId"] as? String else {
            throw DraftModelError.missingRequiredFields
        }

        self.id = draftId
        self.userId = userId
        
        // images配列の変換
        if let imagesData = documentData["images"] as? [[String: Any]] {
            self.images = imagesData.compactMap { ImageInfo(from: $0) }
        } else {
            throw DraftModelError.invalidImages
        }
        
        // editedImages配列の変換
        if let editedImagesData = documentData["editedImages"] as? [[String: Any]] {
            self.editedImages = editedImagesData.compactMap { ImageInfo(from: $0) }
        } else {
            self.editedImages = nil
        }
        
        // editSettingsの変換（後方互換: 旧フィールドを維持）
        if let editSettingsData = documentData["editSettings"] as? [String: Any] {
            self.editSettings = EditSettings(from: editSettingsData)
        } else {
            self.editSettings = nil
        }

        // 【Phase 2】editRecipeV1 の読み込み（新フィールド）
        // 優先度: editRecipeV1 > editSettings（resolvedRecipe で処理）
        if let recipeData = documentData["editRecipeV1"] as? [String: Any] {
            self.editRecipeV1 = EditRecipe(from: recipeData)
        } else {
            self.editRecipeV1 = nil
        }

        self.caption = documentData["caption"] as? String
        self.hashtags = documentData["hashtags"] as? [String]
        
        // locationの変換
        if let locationData = documentData["location"] as? [String: Any] {
            self.location = Location(from: locationData)
        } else {
            self.location = nil
        }
        
        if let visibilityString = documentData["visibility"] as? String {
            self.visibility = Visibility(rawValue: visibilityString) ?? .public
        } else {
            self.visibility = .public
        }
        
        // TimestampからDateに変換
        if let createdAtTimestamp = documentData["createdAt"] as? Timestamp {
            self.createdAt = createdAtTimestamp.dateValue()
        } else {
            self.createdAt = Date()
        }
        
        if let updatedAtTimestamp = documentData["updatedAt"] as? Timestamp {
            self.updatedAt = updatedAtTimestamp.dateValue()
        } else {
            self.updatedAt = Date()
        }
    }
    
    /// Firestore DocumentSnapshotから初期化
    init?(from document: DocumentSnapshot) {
        guard let data = document.data() else {
            return nil
        }
        
        do {
            try self.init(from: data)
        } catch {
            return nil
        }
    }
}

// MARK: - DraftModelError

enum DraftModelError: Error {
    case missingRequiredFields
    case invalidImages
}




