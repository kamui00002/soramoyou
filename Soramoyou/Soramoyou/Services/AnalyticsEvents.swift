//
//  AnalyticsEvents.swift
//  Soramoyou
//
//  Created on 2026-05-14.
//
//  Firebase Analytics のカスタムイベント名・パラメータキーを 1 ファイルに集約。
//  実送信は LoggingService.shared.logEvent ファサード経由 (PII sanitize 込み)。
//  既存の error_occurred / retry_operation / network_retry_stats は GA4 上の
//  過去データと繋がっているため、prefix 統一のためだけにリネームしない。
//

import Foundation

// MARK: - Event Names

/// Soramoyou カスタム Analytics イベント。
///
/// 命名規則:
/// - prefix `sm_` (Soramoyou 略。Firebase 予約イベント・第三者 SDK との衝突回避)
/// - スネークケース、過去形動詞
enum AnalyticsEvent: String {
    case screenView = "sm_screen_view"
    case postCompleted = "sm_post_completed"
    case likeTapped = "sm_like_tapped"
    case commentPosted = "sm_comment_posted"
    case searchExecuted = "sm_search_executed"
}

// MARK: - Parameter Keys

/// Analytics イベントのパラメータキー定義。
enum AnalyticsParam {
    static let screenName = "screen_name"
    static let skyType = "sky_type"
    static let hasLocation = "has_location"
    static let postId = "post_id"
    static let commentLength = "comment_length"
    static let searchTermLength = "search_term_length"
    static let searchType = "search_type"
}

// MARK: - Screen Name Values

/// `screen_name` パラメータの推奨値。表記揺れを避けるため enum 経由を推奨。
enum AnalyticsScreen: String {
    case home
    case gallery
    case galleryDetail = "gallery_detail"
    case search
    case profile
    case post
}

// MARK: - Search Type Values

/// `search_type` パラメータの推奨値。
enum AnalyticsSearchType: String {
    case text
    case hashtag
    case color
    case timeOfDay = "time_of_day"
    case skyType = "sky_type"
}

// MARK: - Logger Facade Extension

extension LoggingService {
    /// 型安全な enum 経由でイベントを送信する便利メソッド。
    /// 内部で既存の logEvent(_:parameters:) を呼ぶため、PII sanitize 層が適用される。
    func logEvent(_ event: AnalyticsEvent, parameters: [String: Any]? = nil) {
        logEvent(event.rawValue, parameters: parameters)
    }
}
