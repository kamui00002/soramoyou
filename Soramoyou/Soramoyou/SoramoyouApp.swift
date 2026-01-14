//
//  SoramoyouApp.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import FirebaseCore
import FirebaseCrashlytics

@main
struct SoramoyouApp: App {
    @StateObject private var authViewModel = AuthViewModel()
    
    init() {
        // Firebase初期化
        FirebaseApp.configure()
        
        // Crashlyticsの設定
        setupCrashlytics()
        
        // AdMob SDKを初期化（非同期で実行、アプリの起動をブロックしない）
        if AdService.isAdsEnabled {
            Task {
                await AdService.shared.initialize()
            }
        }
    }
    
    /// Crashlyticsの設定
    private func setupCrashlytics() {
        // CrashlyticsはFirebaseApp.configure()で自動的に有効化される
        // 追加の設定が必要な場合はここに記述
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authViewModel)
        }
    }
}
