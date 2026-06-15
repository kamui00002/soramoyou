//
//  Feedback.swift
//  Soramoyou
//
//  アプリ内フィードバック（ユーザー → Firestore `feedback` コレクション）
//  App Store レビュー任せにせず、アプリ内から不具合・要望を直接送れる導線。
//  読み取りは管理者のみ（Firebase コンソール）。
//

import Foundation
import FirebaseFirestore

/// フィードバックの種別（任意・送信時のトリアージ用）
enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug      // 不具合
    case request  // 要望
    case other    // その他

    var id: String { rawValue }

    /// 画面表示名
    var displayName: String {
        switch self {
        case .bug: return "不具合"
        case .request: return "要望"
        case .other: return "その他"
        }
    }
}

/// アプリ内フィードバック1件
struct Feedback: Identifiable {
    let id: String
    let userId: String
    let message: String
    /// 種別（`FeedbackCategory.rawValue`。任意）
    let category: String?
    /// 送信時のアプリバージョン（例 "1.7.4 (57)"。トラブル切り分け用・任意）
    let appVersion: String?
    /// 送信時の端末情報（例 "iOS 18.5 / iPhone"。任意）
    let deviceInfo: String?

    init(
        id: String = UUID().uuidString,
        userId: String,
        message: String,
        category: String? = nil,
        appVersion: String? = nil,
        deviceInfo: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.message = message
        self.category = category
        self.appVersion = appVersion
        self.deviceInfo = deviceInfo
    }

    /// 本文のバリデーション（1〜1000文字）。`firestore.rules` の上限と一致させること。
    var isValid: Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && message.count <= 1000
    }

    // MARK: - Firestore Mapping

    /// Firestore ドキュメントデータに変換。
    /// createdAt はサーバー時刻（reportPost と同方針）。
    /// キーは `firestore.rules` の `hasAll(['userId','message','createdAt'])` を必ず満たす。
    func toFirestoreData() -> [String: Any] {
        var data: [String: Any] = [
            "userId": userId,
            "message": message,
            "createdAt": FieldValue.serverTimestamp()
        ]
        // 任意項目は値があるときだけ書き込む（hasAll は追加キーを許容）
        if let category = category {
            data["category"] = category
        }
        if let appVersion = appVersion {
            data["appVersion"] = appVersion
        }
        if let deviceInfo = deviceInfo {
            data["deviceInfo"] = deviceInfo
        }
        return data
    }
}
