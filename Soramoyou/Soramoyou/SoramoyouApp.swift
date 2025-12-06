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
        Task {
            await AdService.shared.initialize()
        }
    }
    
    /// Crashlyticsの設定
    private func setupCrashlytics() {
        // デバッグビルドではCrashlyticsを無効化（オプション）
        #if DEBUG
        // デバッグモードではCrashlyticsを無効化しない（開発中もエラーを記録）
        #endif
        
        // カスタムキーを設定
        Crashlytics.crashlytics().setCustomValue("iOS", forKey: "platform")
        Crashlytics.crashlytics().setCustomValue(Bundle.main.bundleVersion ?? "unknown", forKey: "app_version")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authViewModel)
        }
    }
}


