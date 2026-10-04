//
//  SoratomoModels.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）のモデル ⭐️
//  グループ・メンバー・投稿と、投稿の画像のパスの規則（tasks 10.4・design.md の Data Models）。
//
//  ⚠️ そらともの投稿（SoratomoSky）は既存の投稿（Post）とは別の型にしている。
//     既存の画面・お気に入り・おすすめ・ウィジェット・カレンダーの処理は Post しか受け取らないので、
//     グループの中だけで見せる空が、公開の画面や集計へ型の上で混ざらない（要件 13.2〜13.4）。
//     Post へ変換する口（init(from: SoratomoSky) など）を作らないこと。
//

import Foundation

// MARK: - グループ

/// そらとものグループ（Firestore の `soratomoGroups/{groupId}`）
///
/// 書き手は Functions だけ（作成・参加・招待コードの再発行は Callable のトランザクションの中で変わる）。
struct SoratomoGroup: Identifiable, Equatable, Sendable {
    /// グループ ID（Firestore の自動 ID）
    let id: String
    /// グループ名（前後の空白を除いた 1〜30 文字）
    let name: String
    /// オーナーの uid
    let ownerId: String
    /// いま有効な招待コード（グループごとに 1 つ）
    let inviteCode: SoratomoInviteCode
    /// メンバー数（20 以下。`members` の件数と等しい）
    let memberCount: Int
    /// 作成日時
    let createdAt: Date
    /// 最後に投稿・参加があった日時（グループ一覧の並び順に使う）
    let lastActivityAt: Date
}

// MARK: - メンバー

/// グループの中での役割（Firestore の `members/{uid}.role`）
enum SoratomoMemberRole: String, Sendable {
    /// グループを作った人（招待コードを再発行できる）
    case owner
    /// 招待コードで参加した人
    case member
}

/// グループのメンバー（Firestore の `soratomoGroups/{groupId}/members/{uid}`）
struct SoratomoMember: Identifiable, Equatable, Sendable {
    /// メンバーの uid（文書 ID と同じ）
    let id: String
    /// オーナーかメンバーか
    let role: SoratomoMemberRole
    /// 参加日時
    let joinedAt: Date
}

// MARK: - 投稿

/// そらともの投稿（Firestore の `soratomoGroups/{groupId}/skies/{skyId}`）
///
/// 作成と削除だけで、更新しない。画像の場所は持たず、`imagePaths` で ID から導く
/// （ルールが画像のパスや URL の項目を拒否するため・要件 11.12）。
struct SoratomoSky: Identifiable, Equatable, Sendable {
    /// 投稿 ID（Firestore の自動 ID）
    let id: String
    /// 投稿先のグループ ID
    let groupId: String
    /// 投稿者の uid
    let authorId: String
    /// キャプション（改行を除いた 1〜100 文字。無ければ nil）
    let caption: String?
    /// 表示用画像の幅（ピクセル・1〜2048）
    let pixelWidth: Int
    /// 表示用画像の高さ（ピクセル・1〜2048）
    let pixelHeight: Int
    /// 作成日時（サーバーの時刻。送信直後は推定値で読む）
    let createdAt: Date

    /// この投稿の画像のパス（表示用とサムネイル）
    var imagePaths: SoratomoImagePaths {
        SoratomoImagePaths(groupId: groupId, authorId: authorId, skyId: id)
    }
}

// MARK: - 画像のパス

/// そらともの投稿の画像の、Storage 上のパス（表示用とサムネイル）
///
/// パスはこの型だけが作る（1 か所の規則）。アップロード・削除・取得とキャッシュの鍵（tasks 11.4）は、
/// すべてこの型から受け取る。
/// ⚠️ storage.rules の `match /soratomo/{groupId}/{authorId}/{skyId}/{fileName}` と一致させること。
///    ルールは `authorId` が要求した本人か、`groupId` のメンバーかをパスから判定する。
struct SoratomoImagePaths: Hashable, Sendable {
    /// 表示用画像（長辺 2048px 以下）: `soratomo/{groupId}/{authorId}/{skyId}/display.jpg`
    let display: String
    /// サムネイル: `soratomo/{groupId}/{authorId}/{skyId}/thumb.jpg`
    let thumbnail: String

    /// - Parameters:
    ///   - groupId: 投稿先のグループ ID
    ///   - authorId: 投稿者の uid
    ///   - skyId: 投稿 ID
    init(groupId: String, authorId: String, skyId: String) {
        let folder = "soratomo/\(groupId)/\(authorId)/\(skyId)"
        display = "\(folder)/display.jpg"
        thumbnail = "\(folder)/thumb.jpg"
    }
}
