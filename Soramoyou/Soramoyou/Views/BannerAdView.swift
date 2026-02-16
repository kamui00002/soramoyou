//
//  BannerAdView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//
//  AdMobバナー広告ビュー
//  クラッシュ防止: 広告無効時は非表示、読み込み失敗時はリトライ、
//  rootViewController未設定対策を実施

import SwiftUI
import GoogleMobileAds
import os.log

// MARK: - Banner Ad View (UIViewControllerRepresentable)

struct BannerAdView: UIViewControllerRepresentable {
    let adUnitID: String

    init(adUnitID: String = AdService.bannerAdUnitID) {
        self.adUnitID = adUnitID
    }

    func makeUIViewController(context: Context) -> BannerAdViewController {
        return BannerAdViewController(adUnitID: adUnitID)
    }

    func updateUIViewController(_ uiViewController: BannerAdViewController, context: Context) {
        // 更新は不要
    }
}

// MARK: - Banner Ad View Controller

/// バナー広告を管理するViewController
/// クラッシュ防止: viewDidAppear後にrootViewControllerを設定してから広告を読み込む
class BannerAdViewController: UIViewController {
    let adUnitID: String
    private var bannerView: BannerView?
    private var hasLoadedAd = false
    private var retryCount = 0
    private let logger = Logger(subsystem: "com.soramoyou", category: "BannerAdVC")

    init(adUnitID: String) {
        self.adUnitID = adUnitID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    /// viewDidAppear後に広告を読み込む（rootViewControllerが確実に設定されるため）
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        // 広告が無効な場合は何もしない
        guard AdService.isAdsEnabled else { return }

        // 初回のみ読み込み
        guard !hasLoadedAd else { return }
        hasLoadedAd = true

        loadBannerAd()
    }

    private func loadBannerAd() {
        Task {
            do {
                let banner = try await AdService.shared.loadBannerAd(adUnitID: adUnitID)
                await MainActor.run {
                    // rootViewControllerを確実に設定（クラッシュ防止の要）
                    banner.rootViewController = self
                    self.bannerView = banner
                    self.setupBannerView(banner)
                }
            } catch {
                logger.error("Failed to load banner ad: \(error.localizedDescription)")
                // リトライ（最大3回、指数バックオフ）
                await retryLoadIfNeeded()
            }
        }
    }

    /// 広告読み込み失敗時のリトライ（指数バックオフ）
    private func retryLoadIfNeeded() async {
        guard retryCount < AdService.maxRetryCount else {
            logger.warning("Banner ad retry limit reached (\(AdService.maxRetryCount))")
            return
        }
        retryCount += 1
        let delay = AdService.retryInterval * UInt64(retryCount)
        logger.info("Retrying banner ad load (attempt \(self.retryCount)) in \(delay / 1_000_000_000)s")

        do {
            try await Task.sleep(nanoseconds: delay)
        } catch {
            return
        }

        // ViewControllerがまだ表示中かチェック
        guard view.window != nil else {
            logger.info("View is no longer visible, skipping retry")
            return
        }

        loadBannerAd()
    }

    private func setupBannerView(_ bannerView: BannerView) {
        // 既存のバナーを削除
        self.bannerView?.removeFromSuperview()

        view.addSubview(bannerView)
        bannerView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            bannerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bannerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bannerView.widthAnchor.constraint(equalToConstant: bannerView.adSize.size.width),
            bannerView.heightAnchor.constraint(equalToConstant: bannerView.adSize.size.height)
        ])
    }
}

// MARK: - Banner Ad Container View

/// SwiftUIから使うバナー広告コンテナ
/// 広告が無効な場合は高さ0で表示しない
struct BannerAdContainer: View {
    let adUnitID: String

    init(adUnitID: String = AdService.bannerAdUnitID) {
        self.adUnitID = adUnitID
    }

    var body: some View {
        if AdService.isAdsEnabled {
            BannerAdView(adUnitID: adUnitID)
                .frame(height: getBannerHeight())
                .frame(maxWidth: .infinity)
        }
        // isAdsEnabled == false の場合は何も表示しない
    }

    private func getBannerHeight() -> CGFloat {
        let adSize = AdService.shared.getBannerAdSize()
        return adSize.size.height
    }
}
