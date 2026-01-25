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

    private let sharedDefaults: UserDefaults
    private let appGroupIdentifier = "group.com.soramoyou.app"
    private let processingQueue = DispatchQueue(label: "com.soramoyou.widget.processing", qos: .utility)
    private var pendingReload: DispatchWorkItem?

    private init() {
        // App Groupが利用できない場合は標準のUserDefaultsを使用（デバッグ用）
        if let defaults = UserDefaults(suiteName: appGroupIdentifier) {
            sharedDefaults = defaults
        } else {
            sharedDefaults = UserDefaults.standard
            LoggingService.shared.log("App Group not available, using standard UserDefaults", level: .warning)
        }
    }

    // MARK: - Latest Post Update

    /// 最新の投稿データをウィジェットに共有（非同期）
    func updateLatestPost(
        image: UIImage?,
        caption: String?,
        skyType: String?,
        timeOfDay: String?
    ) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // 画像を圧縮してData化（バックグラウンドスレッドで実行）
            if let image = image {
                let resizedImage = self.resizeImage(image, maxWidth: 300)
                let imageData = resizedImage.jpegData(compressionQuality: 0.7)
                self.sharedDefaults.set(imageData, forKey: "widget_latest_image")
            }

            self.sharedDefaults.set(caption, forKey: "widget_latest_caption")
            self.sharedDefaults.set(skyType, forKey: "widget_latest_sky_type")
            self.sharedDefaults.set(timeOfDay, forKey: "widget_latest_time_of_day")
            self.sharedDefaults.set(Date().timeIntervalSince1970, forKey: "widget_last_update")

            // ウィジェットを更新（デバウンス付き）
            self.scheduleReloadWidgets()
        }
    }

    // MARK: - Today Stats Update

    /// 今日の統計データをウィジェットに共有
    func updateTodayStats(postsCount: Int, dominantSkyType: String?) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            self.sharedDefaults.set(postsCount, forKey: "widget_today_posts_count")
            self.sharedDefaults.set(dominantSkyType, forKey: "widget_today_dominant_sky")
            self.sharedDefaults.set(Date().timeIntervalSince1970, forKey: "widget_last_update")

            // ウィジェットを更新（デバウンス付き）
            self.scheduleReloadWidgets()
        }
    }

    // MARK: - Collection Update

    /// コレクションの画像をウィジェットに共有（非同期）
    func updateCollectionImages(_ images: [UIImage]) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            // 最大5枚の画像を保存
            let limitedImages = Array(images.prefix(5))

            for (index, image) in limitedImages.enumerated() {
                let resizedImage = self.resizeImage(image, maxWidth: 300)
                let imageData = resizedImage.jpegData(compressionQuality: 0.7)
                self.sharedDefaults.set(imageData, forKey: "widget_collection_image_\(index)")
            }

            self.sharedDefaults.set(limitedImages.count, forKey: "widget_collection_count")
            self.sharedDefaults.set(Date().timeIntervalSince1970, forKey: "widget_last_update")

            self.scheduleReloadWidgets()
        }
    }

    // MARK: - Widget Reload

    /// ウィジェット更新をスケジュール（デバウンス付き）
    private func scheduleReloadWidgets() {
        // 前のペンディングリロードをキャンセル
        pendingReload?.cancel()

        // 500ms後にリロード実行（連続呼び出しをまとめる）
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.reloadWidgets()
            }
        }
        pendingReload = workItem
        processingQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// すべてのウィジェットを更新
    func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// 特定のウィジェットを更新
    func reloadWidget(kind: String) {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    // MARK: - Utility

    /// 画像をリサイズ（バックグラウンドスレッドで実行推奨）
    private func resizeImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let scale = maxWidth / image.size.width
        if scale >= 1.0 {
            return image
        }

        let newSize = CGSize(
            width: maxWidth,
            height: image.size.height * scale
        )

        // UIGraphicsImageRendererを使用（より安全でモダンなAPI）
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// ウィジェットデータをクリア
    func clearAllWidgetData() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

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
                self.sharedDefaults.removeObject(forKey: key)
            }

            // コレクション画像もクリア
            for i in 0..<5 {
                self.sharedDefaults.removeObject(forKey: "widget_collection_image_\(i)")
            }

            self.scheduleReloadWidgets()
        }
    }
}

// MARK: - WidgetKind Constants

enum WidgetKind {
    static let skyPhoto = "SkyPhotoWidget"
    static let todaySky = "TodaySkyWidget"
}
