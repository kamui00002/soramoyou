//
//  AdService.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import Foundation
import GoogleMobileAds
import Combine
import os.log

protocol AdServiceProtocol {
    func initialize() async
    func loadBannerAd(adUnitID: String) async throws -> GADBannerView
    func getBannerAdSize() -> GADAdSize
}

class AdService: NSObject, AdServiceProtocol {
    static let shared = AdService()
    
    private var isInitialized = false
    private let logger = Logger(subsystem: "com.soramoyou", category: "AdService")
    
    // テスト用の広告ユニットID（本番環境では実際のIDに置き換える）
    static let testBannerAdUnitID = "ca-app-pub-3940256099942544/2934735716"
    
    private override init() {
        super.init()
    }
    
    // MARK: - Initialization
    
    /// AdMob SDKを初期化
    func initialize() async {
        guard !isInitialized else {
            return
        }
        
        await MainActor.run {
            GADMobileAds.sharedInstance().start(completionHandler: { [weak self] status in
                guard let self = self else { return }
                
                self.isInitialized = true
                
                if status.adapterStatusesByClassName.isEmpty {
                    self.logger.info("AdMob SDK initialized successfully")
                } else {
                    self.logger.warning("AdMob SDK initialized with warnings: \(status.adapterStatusesByClassName.keys.joined(separator: ", "))")
                }
            })
        }
    }
    
    // MARK: - Load Banner Ad
    
    /// バナー広告を読み込む
    func loadBannerAd(adUnitID: String) async throws -> GADBannerView {
        // 初期化されていない場合は初期化を試みる
        if !isInitialized {
            await initialize()
            // 初期化の完了を待つ（簡易的な実装）
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒待機
        }
        
        return await MainActor.run {
            let bannerView = GADBannerView(adSize: getBannerAdSize())
            bannerView.adUnitID = adUnitID
            bannerView.delegate = self
            
            // 広告を読み込む
            let request = GADRequest()
            bannerView.load(request)
            
            return bannerView
        }
    }
    
    /// バナー広告のサイズを取得
    func getBannerAdSize() -> GADAdSize {
        // 画面幅に合わせたバナー広告サイズを取得
        return GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(UIScreen.main.bounds.width)
    }
}

// MARK: - GADBannerViewDelegate

extension AdService: GADBannerViewDelegate {
    /// 広告が正常に読み込まれたとき
    func bannerViewDidReceiveAd(_ bannerView: GADBannerView) {
        logger.info("Banner ad loaded successfully: \(bannerView.adUnitID ?? "unknown")")
    }
    
    /// 広告の読み込みに失敗したとき
    func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
        // エラーをログに記録するが、アプリの動作には影響を与えない
        logger.error("Banner ad failed to load: \(error.localizedDescription)")
    }
    
    /// 広告が表示されたとき
    func bannerViewDidRecordImpression(_ bannerView: GADBannerView) {
        logger.info("Banner ad impression recorded: \(bannerView.adUnitID ?? "unknown")")
    }
    
    /// 広告がクリックされたとき
    func bannerViewWillPresentScreen(_ bannerView: GADBannerView) {
        logger.info("Banner ad clicked: \(bannerView.adUnitID ?? "unknown")")
    }
    
    /// 広告画面が閉じられたとき
    func bannerViewWillDismissScreen(_ bannerView: GADBannerView) {
        logger.info("Banner ad screen will dismiss: \(bannerView.adUnitID ?? "unknown")")
    }
    
    /// 広告画面が閉じられたとき
    func bannerViewDidDismissScreen(_ bannerView: GADBannerView) {
        logger.info("Banner ad screen dismissed: \(bannerView.adUnitID ?? "unknown")")
    }
}


