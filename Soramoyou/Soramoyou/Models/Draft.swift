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
    let caption: String?
    let hashtags: [String]?
    let location: Location?
    let visibility: Visibility
    let createdAt: Date
    var updatedAt: Date
    
    init(
        id: String,
        userId: String,
        images: [ImageInfo],
        editedImages: [ImageInfo]? = nil,
        editSettings: EditSettings? = nil,
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
        self.caption = caption
        self.hashtags = hashtags
        self.location = location
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    // MARK: - Firestore Mapping
    
    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "draftId": id,
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
    init(from documentData: [String: Any]) throws {
        guard let draftId = documentData["draftId"] as? String,
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
        
        // editSettingsの変換
        if let editSettingsData = documentData["editSettings"] as? [String: Any] {
            self.editSettings = EditSettings(from: editSettingsData)
        } else {
            self.editSettings = nil
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


