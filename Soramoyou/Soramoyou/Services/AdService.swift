//
//  AdService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//
//  AdMob広告サービス
//  クラッシュ防止対策を施した安全な広告管理

import Foundation
import UIKit
import GoogleMobileAds
import Combine
import os.log
import AppTrackingTransparency
import AdSupport

protocol AdServiceProtocol {
    func initialize() async
    func loadBannerAd(adUnitID: String) async throws -> BannerView
    func getBannerAdSize() -> AdSize
}

class AdService: NSObject, AdServiceProtocol {
    static let shared = AdService()
    static let isAdsEnabled = true

    /// SDK初期化が完了したかどうか（スレッドセーフ）
    @MainActor
    private(set) var isInitialized = false
    private var isATTRequested = false
    /// 初期化中の重複防止フラグ
    private var isInitializing = false
    private let logger = Logger(subsystem: "com.soramoyou", category: "AdService")

    // 本番用バナー広告ユニットID
    static let bannerAdUnitID = "ca-app-pub-5237930968754753/3919828319"

    /// 広告読み込みのリトライ回数上限
    static let maxRetryCount = 3
    /// リトライ間隔（秒）
    static let retryInterval: UInt64 = 2_000_000_000 // 2秒

    private override init() {
        super.init()
    }

    // MARK: - ATT (App Tracking Transparency)

    /// ATT（トラッキング許可）をリクエスト
    /// - Returns: トラッキングが許可されたかどうか
    @MainActor
    func requestTrackingAuthorization() async -> Bool {
        guard !isATTRequested else {
            return ATTrackingManager.trackingAuthorizationStatus == .authorized
        }

        guard #available(iOS 14, *) else {
            logger.info("ATT not required for iOS < 14")
            return true
        }

        let currentStatus = ATTrackingManager.trackingAuthorizationStatus

        switch currentStatus {
        case .authorized:
            logger.info("ATT already authorized")
            isATTRequested = true
            return true
        case .denied, .restricted:
            logger.info("ATT denied or restricted")
            isATTRequested = true
            return false
        case .notDetermined:
            logger.info("Requesting ATT authorization")
            let status = await ATTrackingManager.requestTrackingAuthorization()
            isATTRequested = true

            switch status {
            case .authorized:
                logger.info("ATT authorized by user")
                return true
            case .denied:
                logger.info("ATT denied by user")
                return false
            case .restricted:
                logger.info("ATT restricted")
                return false
            case .notDetermined:
                logger.warning("ATT still not determined after request")
                return false
            @unknown default:
                logger.warning("ATT unknown status")
                return false
            }
        @unknown default:
            logger.warning("ATT unknown current status")
            isATTRequested = true
            return false
        }
    }

    /// 現在のトラッキング許可ステータスを取得
    var trackingAuthorizationStatus: ATTrackingManager.AuthorizationStatus {
        if #available(iOS 14, *) {
            return ATTrackingManager.trackingAuthorizationStatus
        } else {
            return .authorized
        }
    }

    // MARK: - Initialization

    /// AdMob SDKを安全に初期化（ATTリクエスト後に呼び出すこと）
    /// 重複呼び出し・初期化中の再呼び出しを防止
    @MainActor
    func initialize() async {
        guard Self.isAdsEnabled else {
            logger.info("AdMob initialization is disabled")
            return
        }
        guard !isInitialized, !isInitializing else {
            return
        }

        isInitializing = true

        // ATTリクエストがまだの場合は先にリクエスト
        if !isATTRequested {
            _ = await requestTrackingAuthorization()
        }

        // Continuation を使って初期化完了を確実に待つ
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            MobileAds.shared.start { [weak self] status in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                Task { @MainActor in
                    self.isInitialized = true
                    self.isInitializing = false

                    if status.adapterStatusesByClassName.isEmpty {
                        self.logger.info("AdMob SDK initialized successfully")
                    } else {
                        self.logger.info("AdMob SDK initialized: \(status.adapterStatusesByClassName.keys.joined(separator: ", "))")
                    }
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Load Banner Ad

    /// バナー広告を安全に読み込む
    /// SDK未初期化の場合は初期化を待ってから読み込む
    @MainActor
    func loadBannerAd(adUnitID: String) async throws -> BannerView {
        guard Self.isAdsEnabled else {
            throw AdServiceError.adsDisabled
        }

        // 初期化されていない場合は初期化を待つ
        if !isInitialized {
            await initialize()
        }

        // 初期化に失敗した場合はエラーを返す（クラッシュさせない）
        guard isInitialized else {
            logger.error("AdMob SDK initialization failed, skipping ad load")
            throw AdServiceError.initializationFailed
        }

        let bannerView = BannerView(adSize: getBannerAdSize())
        bannerView.adUnitID = adUnitID
        bannerView.delegate = self

        let request = Request()
        bannerView.load(request)

        return bannerView
    }

    /// バナー広告のサイズを取得
    func getBannerAdSize() -> AdSize {
        return AdSizeBanner
    }
}

// MARK: - BannerViewDelegate

extension AdService: BannerViewDelegate {
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        logger.info("Banner ad loaded successfully: \(bannerView.adUnitID ?? "unknown")")
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        logger.error("Banner ad failed to load: \(error.localizedDescription)")
    }

    func bannerViewDidRecordImpression(_ bannerView: BannerView) {
        logger.info("Banner ad impression recorded")
    }

    func bannerViewWillPresentScreen(_ bannerView: BannerView) {
        logger.info("Banner ad clicked")
    }

    func bannerViewWillDismissScreen(_ bannerView: BannerView) {
        logger.info("Banner ad screen will dismiss")
    }

    func bannerViewDidDismissScreen(_ bannerView: BannerView) {
        logger.info("Banner ad screen dismissed")
    }
}

// MARK: - Error Types

enum AdServiceError: LocalizedError {
    case adsDisabled
    case initializationFailed

    var errorDescription: String? {
        switch self {
        case .adsDisabled:
            return "広告が無効化されています"
        case .initializationFailed:
            return "広告サービスの初期化に失敗しました"
        }
    }
}
