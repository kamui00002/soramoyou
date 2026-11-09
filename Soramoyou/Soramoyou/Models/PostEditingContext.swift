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

    /// 既存の原画像（再編集で原画像の中身は変わらない＝引き継ぐ）。
    /// 公開範囲を変えたときだけ、保存時に新しい公開範囲のフォルダへ写し直す（PostViewModel.relocateOriginalImagesForEditing・URL 側の E）。
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
        postId = post.id
        caption = post.caption
        frameCaption = post.frameCaption
        frameTextColorHex = post.frameTextColorHex
        frameFontStyle = post.frameFontStyle
        mood = post.mood
        frameStyle = Self.parseStyle(from: post.frameId)
        visibility = post.visibility
        hashtags = post.hashtags ?? []
        likesCount = post.likesCount
        commentsCount = post.commentsCount
        createdAt = post.createdAt
        skyColors = post.skyColors
        capturedAt = post.capturedAt
        timeOfDay = post.timeOfDay
        skyType = post.skyType
        colorTemperature = post.colorTemperature
        location = post.location
        originalImages = post.originalImages

        // 削除対象は「置換される編集済み画像（＋サムネ）」のみ。原画像は保持して引き継ぐので
        // ここには入れない（原画像 blob を消すと再編集不可になる＝C1 data-loss の原因だった）。
        // 公開範囲を変えて原画像を写し直したときの移す前の原画像は、写し終えて投稿を更新した後に PostViewModel が別に消す（URL 側の E）。
        var paths: [String] = []
        for img in post.images {
            if let p = img.storagePath { paths.append(p) }
            if let t = img.thumbnailStoragePath { paths.append(t) }
        }
        oldStoragePaths = paths
    }

    /// frameId "mood_style"（例 "calm_matte"）の末尾から枠スタイルを復元する。
    /// 解析できない/旧形式（例 "frame_wistful_01"）は classic にフォールバック。
    private static func parseStyle(from frameId: String?) -> FrameStyle {
        guard let frameId, let suffix = frameId.split(separator: "_").last else { return .classic }
        return FrameStyle(rawValue: String(suffix)) ?? .classic
    }
}
