// ⭐️ PostEditingContext.swift
// 投稿済み画像の「再編集」で、編集対象の投稿情報をエディタ→投稿情報画面→PostViewModel へ運ぶ seed。
//
//  Created on 2026-06-09.
//
//  再編集フロー: GalleryDetailView の「編集」→ originalImages を DL → このコンテキストを作り
//  EditView(editingContext:) → PostInfoView(editingContext:) → PostViewModel.seedForEditing(_:)。
//  保存時は createPost ではなく updatePost（既存 postId を上書き・カウント/作成日時は保持）。
//

import Foundation

/// 再編集対象の投稿から抽出した seed＋保持メタ。
struct PostEditingContext {
    /// 上書き更新する既存投稿の ID
    let postId: String

    // MARK: - 編集可能（エディタ/投稿情報で書き換わる）
    let caption: String?
    let frameCaption: String?
    let mood: Mood?
    let frameStyle: FrameStyle
    let visibility: Visibility
    let hashtags: [String]

    // MARK: - 保持メタ（再編集では変えない。Firestore ルール要件＋一貫性のため）
    let likesCount: Int
    let commentsCount: Int
    let createdAt: Date
    let skyColors: [String]?
    let capturedAt: Date?
    let timeOfDay: TimeOfDay?
    let skyType: SkyType?
    let colorTemperature: Int?
    let location: Location?

    /// 旧 Storage パス（更新成功後にベストエフォート削除＝孤児ファイル防止）。
    /// 再アップロードで新 URL になるため Kingfisher の URL キャッシュは自然に更新される。
    let oldStoragePaths: [String]

    init(post: Post) {
        self.postId = post.id
        self.caption = post.caption
        self.frameCaption = post.frameCaption
        self.mood = post.mood
        self.frameStyle = Self.parseStyle(from: post.frameId)
        self.visibility = post.visibility
        self.hashtags = post.hashtags ?? []
        self.likesCount = post.likesCount
        self.commentsCount = post.commentsCount
        self.createdAt = post.createdAt
        self.skyColors = post.skyColors
        self.capturedAt = post.capturedAt
        self.timeOfDay = post.timeOfDay
        self.skyType = post.skyType
        self.colorTemperature = post.colorTemperature
        self.location = post.location

        var paths: [String] = []
        for img in post.images {
            if let p = img.storagePath { paths.append(p) }
            if let t = img.thumbnailStoragePath { paths.append(t) }
        }
        for img in post.originalImages ?? [] {
            if let p = img.storagePath { paths.append(p) }
        }
        self.oldStoragePaths = paths
    }

    /// frameId "mood_style"（例 "calm_matte"）の末尾から枠スタイルを復元する。
    /// 解析できない/旧形式（例 "frame_wistful_01"）は classic にフォールバック。
    private static func parseStyle(from frameId: String?) -> FrameStyle {
        guard let frameId, let suffix = frameId.split(separator: "_").last else { return .classic }
        return FrameStyle(rawValue: String(suffix)) ?? .classic
    }
}
