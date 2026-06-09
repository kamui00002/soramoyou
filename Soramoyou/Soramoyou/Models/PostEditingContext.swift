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
    let frameTextColorHex: String?
    let frameFontStyle: FrameFontStyle?
    let mood: Mood?
    let frameStyle: FrameStyle
    let visibility: Visibility
    let hashtags: [String]

    // MARK: - 保持メタ（再編集では変えない。Firestore ルール要件＋一貫性のため）
    /// 既存の原画像（再編集では原画像自体は変わらない＝そのまま引き継ぐ）。
    /// これを保持しないと上書き更新(setData全置換)で originalImages が消え、
    /// 次回以降の再編集や「編集前/編集後」トグルが壊れる（＝元画像 data-loss）。
    let originalImages: [ImageInfo]?
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
        self.frameTextColorHex = post.frameTextColorHex
        self.frameFontStyle = post.frameFontStyle
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
        self.originalImages = post.originalImages

        // 削除対象は「置換される編集済み画像（＋サムネ）」のみ。原画像は保持して引き継ぐので
        // 削除しない（原画像 blob を消すと再編集不可になる＝C1 data-loss の原因だった）。
        var paths: [String] = []
        for img in post.images {
            if let p = img.storagePath { paths.append(p) }
            if let t = img.thumbnailStoragePath { paths.append(t) }
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
