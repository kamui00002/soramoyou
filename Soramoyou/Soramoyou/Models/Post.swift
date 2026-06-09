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
    let originalImages: [ImageInfo]?  // オリジナル画像（編集前）
    let editSettings: EditSettings?    // 編集設定
    /// 投稿に添付された編集レシピ（Firestore `editRecipeV1`）
    /// - パーソナルAI編集のコーパス・レシピ共有のための「完全な編集情報」。
    /// - 旧投稿との後方互換のため Optional。`editSettings`（旧・lossy）は置換せず残す。
    let attachedRecipe: EditRecipe?
    let caption: String?
    /// 機能1: 投稿にまとう気分（mood）。未選択投稿・旧投稿は nil。
    let mood: Mood?
    /// 機能1: 適用した気分フレームの ID。フレーム未適用・旧投稿は nil。
    let frameId: String?
    /// 機能1: フレーム（額縁）に焼き込む一言コメント。通常の `caption`（ハッシュタグ等）とは別物。
    /// フレームには **この値だけ** を焼く。未入力・旧投稿は nil。
    let frameCaption: String?
    /// 機能1: フレーム文字色（"#RRGGBB"）。ユーザー未選択（おまかせ）・旧投稿は nil＝style 自動色。
    let frameTextColorHex: String?
    /// 機能1: フレーム文字フォント。ユーザー未選択・旧投稿は nil＝mood 既定フォント。
    let frameFontStyle: FrameFontStyle?
    /// 投稿種別（single/collage/panorama）。nil=旧投稿・通常投稿＝single 相当。
    let postKind: PostKind?
    /// 配置写真のレイアウト（postKind==.collage のときのみ）。
    let collageLayout: CollageLayout?
    /// 配置写真の各パネルの一言ラベル（朝/昼/夜/雨 など・任意）。collage のときのみ。
    let panelLabels: [String]?
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
        originalImages: [ImageInfo]? = nil,
        editSettings: EditSettings? = nil,
        attachedRecipe: EditRecipe? = nil,
        caption: String? = nil,
        mood: Mood? = nil,
        frameId: String? = nil,
        frameCaption: String? = nil,
        frameTextColorHex: String? = nil,
        frameFontStyle: FrameFontStyle? = nil,
        postKind: PostKind? = nil,
        collageLayout: CollageLayout? = nil,
        panelLabels: [String]? = nil,
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
        self.originalImages = originalImages
        self.editSettings = editSettings
        self.attachedRecipe = attachedRecipe
        self.caption = caption
        self.mood = mood
        self.frameId = frameId
        self.frameCaption = frameCaption
        self.frameTextColorHex = frameTextColorHex
        self.frameFontStyle = frameFontStyle
        self.postKind = postKind
        self.collageLayout = collageLayout
        self.panelLabels = panelLabels
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

        if let mood = mood {
            data["mood"] = mood.rawValue
        }

        if let frameId = frameId {
            data["frameId"] = frameId
        }

        if let frameCaption = frameCaption {
            data["frameCaption"] = frameCaption
        }

        if let frameTextColorHex = frameTextColorHex {
            data["frameTextColorHex"] = frameTextColorHex
        }

        if let frameFontStyle = frameFontStyle {
            data["frameFontStyle"] = frameFontStyle.rawValue
        }

        if let postKind = postKind {
            data["postKind"] = postKind.rawValue
        }

        if let collageLayout = collageLayout {
            data["collageLayout"] = collageLayout.rawValue
        }

        if let panelLabels = panelLabels {
            data["panelLabels"] = panelLabels
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

        // オリジナル画像（編集前）
        if let originalImages = originalImages {
            data["originalImages"] = originalImages.map { $0.toFirestoreData() }
        }

        // 編集設定
        if let editSettings = editSettings {
            data["editSettings"] = editSettings.toFirestoreData()
        }

        // 添付編集レシピ（完全版）。後方互換のための追加フィールドで editSettings は残す。
        if let attachedRecipe = attachedRecipe {
            data["editRecipeV1"] = attachedRecipe.toFirestoreData()
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

        // オリジナル画像の変換（オプショナル - 後方互換性）
        if let originalImagesData = documentData["originalImages"] as? [[String: Any]] {
            self.originalImages = originalImagesData.compactMap { ImageInfo(from: $0) }
        } else {
            self.originalImages = nil
        }

        // 編集設定の変換（オプショナル - 後方互換性）
        if let editSettingsData = documentData["editSettings"] as? [String: Any] {
            self.editSettings = EditSettings(from: editSettingsData)
        } else {
            self.editSettings = nil
        }

        // 添付編集レシピの変換（オプショナル - 後方互換性）
        // schemaVersion 欠落や壊れた値は EditRecipe.init?(from:) が弾く（nil を返す）。
        if let recipeData = documentData["editRecipeV1"] as? [String: Any] {
            self.attachedRecipe = EditRecipe(from: recipeData)
        } else {
            self.attachedRecipe = nil
        }

        self.caption = documentData["caption"] as? String

        // 機能1: mood / frameId（後方互換のため Optional）
        if let moodString = documentData["mood"] as? String {
            self.mood = Mood(rawValue: moodString)
        } else {
            self.mood = nil
        }
        self.frameId = documentData["frameId"] as? String
        self.frameCaption = documentData["frameCaption"] as? String
        self.frameTextColorHex = documentData["frameTextColorHex"] as? String
        // フォント: 旧データ・未知の値は nil（mood 既定へフォールバック）
        if let fontRaw = documentData["frameFontStyle"] as? String {
            self.frameFontStyle = FrameFontStyle(rawValue: fontRaw)
        } else {
            self.frameFontStyle = nil
        }

        // 投稿種別/配置レイアウト（後方互換: 旧データ・未知値は nil＝single 相当）
        if let kindRaw = documentData["postKind"] as? String {
            self.postKind = PostKind(rawValue: kindRaw)
        } else {
            self.postKind = nil
        }
        if let layoutRaw = documentData["collageLayout"] as? String {
            self.collageLayout = CollageLayout(rawValue: layoutRaw)
        } else {
            self.collageLayout = nil
        }
        self.panelLabels = documentData["panelLabels"] as? [String]

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




