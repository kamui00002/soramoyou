//
//  Post.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import FirebaseFirestore

/// 投稿エンティティ
struct Post: Identifiable, Codable {
    let id: String
    let userId: String
    let images: [ImageInfo]
    let caption: String?
    let hashtags: [String]?
    let location: Location?
    let skyColors: [String]? // 最大5色、16進数カラーコード
    let capturedAt: Date?
    let timeOfDay: TimeOfDay?
    let skyType: SkyType?
    let colorTemperature: Int? // K表示
    let visibility: Visibility
    var likesCount: Int
    var commentsCount: Int
    let createdAt: Date
    var updatedAt: Date
    
    init(
        id: String,
        userId: String,
        images: [ImageInfo],
        caption: String? = nil,
        hashtags: [String]? = nil,
        location: Location? = nil,
        skyColors: [String]? = nil,
        capturedAt: Date? = nil,
        timeOfDay: TimeOfDay? = nil,
        skyType: SkyType? = nil,
        colorTemperature: Int? = nil,
        visibility: Visibility = .public,
        likesCount: Int = 0,
        commentsCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.images = images
        self.caption = caption
        self.hashtags = hashtags
        self.location = location
        // skyColorsは最大5色まで
        if let colors = skyColors, colors.count > 5 {
            self.skyColors = Array(colors.prefix(5))
        } else {
            self.skyColors = skyColors
        }
        self.capturedAt = capturedAt
        self.timeOfDay = timeOfDay
        self.skyType = skyType
        self.colorTemperature = colorTemperature
        self.visibility = visibility
        self.likesCount = likesCount
        self.commentsCount = commentsCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    // MARK: - Firestore Mapping
    
    /// Firestoreドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "postId": id,
            "userId": userId,
            "images": images.map { $0.toFirestoreData() },
            "visibility": visibility.rawValue,
            "likesCount": likesCount,
            "commentsCount": commentsCount,
            "createdAt": Timestamp(date: createdAt),
            "updatedAt": Timestamp(date: updatedAt)
        ]
        
        if let caption = caption {
            data["caption"] = caption
        }
        
        if let hashtags = hashtags {
            data["hashtags"] = hashtags
        }
        
        if let location = location {
            data["location"] = location.toFirestoreData()
        }
        
        if let skyColors = skyColors {
            data["skyColors"] = skyColors
        }
        
        if let capturedAt = capturedAt {
            data["capturedAt"] = Timestamp(date: capturedAt)
        }
        
        if let timeOfDay = timeOfDay {
            data["timeOfDay"] = timeOfDay.rawValue
        }
        
        if let skyType = skyType {
            data["skyType"] = skyType.rawValue
        }
        
        if let colorTemperature = colorTemperature {
            data["colorTemperature"] = colorTemperature
        }
        
        return data
    }
    
    /// Firestoreドキュメントデータから初期化
    init(from documentData: [String: Any]) throws {
        guard let postId = documentData["postId"] as? String,
              let userId = documentData["userId"] as? String else {
            throw PostModelError.missingRequiredFields
        }
        
        self.id = postId
        self.userId = userId
        
        // images配列の変換
        if let imagesData = documentData["images"] as? [[String: Any]] {
            self.images = imagesData.compactMap { ImageInfo(from: $0) }
        } else {
            throw PostModelError.invalidImages
        }
        
        self.caption = documentData["caption"] as? String
        self.hashtags = documentData["hashtags"] as? [String]
        
        // locationの変換
        if let locationData = documentData["location"] as? [String: Any] {
            self.location = Location(from: locationData)
        } else {
            self.location = nil
        }
        
        self.skyColors = documentData["skyColors"] as? [String]
        self.likesCount = documentData["likesCount"] as? Int ?? 0
        self.commentsCount = documentData["commentsCount"] as? Int ?? 0
        
        // TimestampからDateに変換
        if let capturedAtTimestamp = documentData["capturedAt"] as? Timestamp {
            self.capturedAt = capturedAtTimestamp.dateValue()
        } else {
            self.capturedAt = nil
        }
        
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
        
        // Enumの変換
        if let timeOfDayString = documentData["timeOfDay"] as? String {
            self.timeOfDay = TimeOfDay(rawValue: timeOfDayString)
        } else {
            self.timeOfDay = nil
        }
        
        if let skyTypeString = documentData["skyType"] as? String {
            self.skyType = SkyType(rawValue: skyTypeString)
        } else {
            self.skyType = nil
        }
        
        if let visibilityString = documentData["visibility"] as? String {
            self.visibility = Visibility(rawValue: visibilityString) ?? .public
        } else {
            self.visibility = .public
        }
        
        self.colorTemperature = documentData["colorTemperature"] as? Int
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

// MARK: - PostModelError

enum PostModelError: Error {
    case missingRequiredFields
    case invalidImages
}


