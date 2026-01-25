//
//  WidgetDataService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import UIKit
import WidgetKit

/// ウィジェットにデータを共有するサービス
class WidgetDataService {
    static let shared = WidgetDataService()

    private let sharedDefaults: UserDefaults?
    private let appGroupIdentifier = "group.com.soramoyou.app"

    private init() {
        sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
    }

    // MARK: - Latest Post Update

    /// 最新の投稿データをウィジェットに共有
    func updateLatestPost(
        image: UIImage?,
        caption: String?,
        skyType: String?,
        timeOfDay: String?
    ) {
        // 画像を圧縮してData化
        if let image = image {
            // ウィジェット用に小さくリサイズ（300px）
            let resizedImage = resizeImage(image, maxWidth: 300)
            let imageData = resizedImage.jpegData(compressionQuality: 0.7)
            sharedDefaults?.set(imageData, forKey: "widget_latest_image")
        }

        sharedDefaults?.set(caption, forKey: "widget_latest_caption")
        sharedDefaults?.set(skyType, forKey: "widget_latest_sky_type")
        sharedDefaults?.set(timeOfDay, forKey: "widget_latest_time_of_day")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "widget_last_update")

        // ウィジェットを更新
        reloadWidgets()
    }

    // MARK: - Today Stats Update

    /// 今日の統計データをウィジェットに共有
    func updateTodayStats(postsCount: Int, dominantSkyType: String?) {
        sharedDefaults?.set(postsCount, forKey: "widget_today_posts_count")
        sharedDefaults?.set(dominantSkyType, forKey: "widget_today_dominant_sky")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "widget_last_update")

        // ウィジェットを更新
        reloadWidgets()
    }

    // MARK: - Collection Update

    /// コレクションの画像をウィジェットに共有
    func updateCollectionImages(_ images: [UIImage]) {
        // 最大5枚の画像を保存
        let limitedImages = Array(images.prefix(5))

        for (index, image) in limitedImages.enumerated() {
            let resizedImage = resizeImage(image, maxWidth: 300)
            let imageData = resizedImage.jpegData(compressionQuality: 0.7)
            sharedDefaults?.set(imageData, forKey: "widget_collection_image_\(index)")
        }

        sharedDefaults?.set(limitedImages.count, forKey: "widget_collection_count")
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: "widget_last_update")

        reloadWidgets()
    }

    // MARK: - Widget Reload

    /// すべてのウィジェットを更新
    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 特定のウィジェットを更新
    func reloadWidget(kind: String) {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    // MARK: - Utility

    /// 画像をリサイズ
    private func resizeImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let scale = maxWidth / image.size.width
        if scale >= 1.0 {
            return image
        }

        let newSize = CGSize(
            width: maxWidth,
            height: image.size.height * scale
        )

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resizedImage ?? image
    }

    /// ウィジェットデータをクリア
    func clearAllWidgetData() {
        let keys = [
            "widget_latest_image",
            "widget_latest_caption",
            "widget_latest_sky_type",
            "widget_latest_time_of_day",
            "widget_today_posts_count",
            "widget_today_dominant_sky",
            "widget_collection_count",
            "widget_last_update"
        ]

        for key in keys {
            sharedDefaults?.removeObject(forKey: key)
        }

        // コレクション画像もクリア
        for i in 0..<5 {
            sharedDefaults?.removeObject(forKey: "widget_collection_image_\(i)")
        }

        reloadWidgets()
    }
}

// MARK: - WidgetKind Constants

enum WidgetKind {
    static let skyPhoto = "SkyPhotoWidget"
    static let todaySky = "TodaySkyWidget"
}
