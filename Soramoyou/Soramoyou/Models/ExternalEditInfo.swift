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

    init(
        hasAdjustments: Bool,
        formatIdentifier: String? = nil,
        isHDR: Bool = false,
        isLivePhoto: Bool = false,
        isPanorama: Bool = false,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.hasAdjustments = hasAdjustments
        self.formatIdentifier = formatIdentifier
        self.isHDR = isHDR
        self.isLivePhoto = isLivePhoto
        self.isPanorama = isPanorama
        self.creationDate = creationDate
        self.modificationDate = modificationDate
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
    }
}
