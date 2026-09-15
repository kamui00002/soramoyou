//
//  ExternalEditInfo.swift
//  Soramoyou
//
//  写真ライブラリの PHAsset から取得できる「外部編集情報」を表すモデル。 ⭐️
//
//  iPhone 純正「写真」アプリや他社アプリで編集された画像をアップロードした際に、
//  ギャラリーで「写真Appで編集済み」のようなバッジを表示するために利用する。
//
//  ⚠️ 制約: Apple は PHAdjustmentData の中身（露出 +20% 等の数値）を公開 API では
//  提供していないため、このモデルでは「誰が編集したか（formatIdentifier）」と
//  「編集の有無（hasAdjustments）」、PHAsset から取得できるメタ情報のみを扱う。
//

import Foundation
import FirebaseFirestore

/// 外部アプリ（iPhone 写真App / 他社アプリ）の編集情報を表す Value Object
struct ExternalEditInfo: Codable, Equatable {

    /// 写真Appまたは他社アプリで編集されているか（PHAsset.mediaSubtypes.photoEdited）
    let hasAdjustments: Bool

    /// 編集アプリのバンドル ID（例: `"com.apple.photo"` = Apple 純正写真App、
    /// `"com.soramoyou.photo-editor"` = そらもよう自身）。未取得時は nil。
    let formatIdentifier: String?

    /// HDR 画像か（PHAsset.mediaSubtypes.photoHDR）
    let isHDR: Bool

    /// Live Photo か
    let isLivePhoto: Bool

    /// パノラマ画像か
    let isPanorama: Bool

    /// 撮影日時（PHAsset.creationDate）
    let creationDate: Date?

    /// 最後に編集された日時（PHAsset.modificationDate）
    let modificationDate: Date?

    /// 元ファイルの EXIF `DateTimeOriginal` から読んだ撮影日時。
    ///
    /// `creationDate`（PHAsset.creationDate）とは別に持つのは、写真ライブラリの作成日時が
    /// 「保存した時刻」（他アプリからの保存・AirDrop 受信など）を指すことがあり、撮影の瞬間を
    /// 表す EXIF の値のほうが投稿の `capturedAt` として正しいため。ピッカー時点で元ファイルから
    /// 読む（UIImage に変換した後では EXIF が失われる）。EXIF を持たない画像
    /// （スクリーンショット等）や読み取り失敗時は nil で、`creationDate` に補完される。
    let exifCapturedAt: Date?

    init(
        hasAdjustments: Bool,
        formatIdentifier: String? = nil,
        isHDR: Bool = false,
        isLivePhoto: Bool = false,
        isPanorama: Bool = false,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        exifCapturedAt: Date? = nil
    ) {
        self.hasAdjustments = hasAdjustments
        self.formatIdentifier = formatIdentifier
        self.isHDR = isHDR
        self.isLivePhoto = isLivePhoto
        self.isPanorama = isPanorama
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.exifCapturedAt = exifCapturedAt
    }

    // MARK: - 撮影日時の解決

    /// 投稿の撮影日時（`Post.capturedAt`）として採用する値と、その出所。
    /// 優先順位は EXIF → 写真ライブラリの作成日時 → nil（ユーザー決定事項）。
    /// 出所を返すのは、`post_completed` の `captured_at_source` で「EXIF が読めている割合」を
    /// 運用で追えるようにするため（不具合の再発を計装で検知する）。
    var resolvedCapturedAt: (date: Date, source: CapturedAtSource)? {
        if let exifCapturedAt {
            return (exifCapturedAt, .exif)
        }
        if let creationDate {
            return (creationDate, .asset)
        }
        return nil
    }

    // MARK: - 表示用ヘルパー

    /// バッジの表示文字列。編集アプリに応じて分岐。
    /// `nil` の場合はバッジを表示しない。
    var badgeLabel: String? {
        guard hasAdjustments else { return nil }
        switch formatIdentifier {
        case "com.apple.photo":
            return "写真Appで編集済み"
        case "com.soramoyou.photo-editor":
            // そらもよう自身の編集は通常別の表示（編集レシピ詳細）が出るため、ここでは何も出さない
            return nil
        case let id? where !id.isEmpty:
            return "外部アプリで編集済み"
        default:
            return "編集済み"
        }
    }

    /// 撮影特性のサブラベル（HDR/Live/Pano）
    var subtypeBadges: [String] {
        var labels: [String] = []
        if isHDR { labels.append("HDR") }
        if isLivePhoto { labels.append("Live") }
        if isPanorama { labels.append("Pano") }
        return labels
    }

    // MARK: - Firestore Mapping

    /// Firestore ドキュメントデータに変換
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "hasAdjustments": hasAdjustments,
            "isHDR": isHDR,
            "isLivePhoto": isLivePhoto,
            "isPanorama": isPanorama
        ]
        if let formatIdentifier = formatIdentifier {
            data["formatIdentifier"] = formatIdentifier
        }
        if let creationDate = creationDate {
            data["creationDate"] = Timestamp(date: creationDate)
        }
        if let modificationDate = modificationDate {
            data["modificationDate"] = Timestamp(date: modificationDate)
        }
        // nil は省略（旧ドキュメントと同形状を保つ＝後方互換）
        if let exifCapturedAt = exifCapturedAt {
            data["exifCapturedAt"] = Timestamp(date: exifCapturedAt)
        }
        return data
    }

    /// Firestore ドキュメントデータから初期化
    init?(from documentData: [String: Any]) {
        guard let hasAdjustments = documentData["hasAdjustments"] as? Bool else {
            return nil
        }
        self.hasAdjustments = hasAdjustments
        self.formatIdentifier = documentData["formatIdentifier"] as? String
        self.isHDR = documentData["isHDR"] as? Bool ?? false
        self.isLivePhoto = documentData["isLivePhoto"] as? Bool ?? false
        self.isPanorama = documentData["isPanorama"] as? Bool ?? false
        if let creationTs = documentData["creationDate"] as? Timestamp {
            self.creationDate = creationTs.dateValue()
        } else {
            self.creationDate = documentData["creationDate"] as? Date
        }
        if let modTs = documentData["modificationDate"] as? Timestamp {
            self.modificationDate = modTs.dateValue()
        } else {
            self.modificationDate = documentData["modificationDate"] as? Date
        }
        // creationDate と同じく Timestamp / Date の両対応（キー無し＝旧ドキュメントは nil）
        if let exifTs = documentData["exifCapturedAt"] as? Timestamp {
            self.exifCapturedAt = exifTs.dateValue()
        } else {
            self.exifCapturedAt = documentData["exifCapturedAt"] as? Date
        }
    }
}

// MARK: - CapturedAtSource

/// `Post.capturedAt` の出所。計装（`post_completed.captured_at_source`）と
/// `ExtractedImageInfo` で共有する。`rawValue` がそのままイベントの属性値になる。
/// `preserved` のみ計装専用（`ExtractedImageInfo.capturedAtSource` には現れない。
/// 再編集は抽出を通らず元投稿の値をそのまま保持するため）。
enum CapturedAtSource: String {
    /// 元ファイルの EXIF `DateTimeOriginal`
    case exif
    /// 写真ライブラリの作成日時（PHAsset.creationDate）
    case asset
    /// どちらも無い（合成投稿・権限なしのスクリーンショット等）
    case none
    /// 再編集で元投稿の値をそのまま保持した（抽出はしていない）。計装専用。
    case preserved
}
