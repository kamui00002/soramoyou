//
//  BannerAdView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import GoogleMobileAds

struct BannerAdView: UIViewControllerRepresentable {
    let adUnitID: String
    
    init(adUnitID: String = AdService.testBannerAdUnitID) {
        self.adUnitID = adUnitID
    }
    
    func makeUIViewController(context: Context) -> BannerAdViewController {
        let viewController = BannerAdViewController(adUnitID: adUnitID)
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: BannerAdViewController, context: Context) {
        // 更新は不要
    }
}

// MARK: - Banner Ad View Controller

class BannerAdViewController: UIViewController {
    let adUnitID: String
    private var bannerView: BannerView?
    
    init(adUnitID: String) {
        self.adUnitID = adUnitID
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        loadBannerAd()
    }
    
    private func loadBannerAd() {
        Task {
            do {
                let banner = try await AdService.shared.loadBannerAd(adUnitID: adUnitID)
                await MainActor.run {
                    self.bannerView = banner
                    self.setupBannerView(banner)
                }
            } catch {
                // エラーはログに記録されるが、アプリの動作には影響しない
                print("Failed to load banner ad: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupBannerView(_ bannerView: BannerView) {
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

struct BannerAdContainer: View {
    let adUnitID: String
    
    init(adUnitID: String = AdService.testBannerAdUnitID) {
        self.adUnitID = adUnitID
    }
    
    var body: some View {
        BannerAdView(adUnitID: adUnitID)
            .frame(height: getBannerHeight())
            .frame(maxWidth: .infinity)
    }
    
    private func getBannerHeight() -> CGFloat {
        let adSize = AdService.shared.getBannerAdSize()
        return adSize.size.height
    }
}

