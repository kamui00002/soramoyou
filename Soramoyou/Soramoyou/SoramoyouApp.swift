//
//  SoramoyouApp.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import FirebaseCore
import FirebaseCrashlytics
#if canImport(FirebaseAppCheck)
import FirebaseAppCheck
#endif

@main
struct SoramoyouApp: App {
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var likeManager = LikeManager()
    
    init() {
        // App Check Provider Factory を Firebase 初期化前に登録 (SR-H1)
        // 本番では AppAttest、DEBUG では DebugProvider を使う。
        // FirebaseAppCheck SPM 未リンクのため #if canImport でガード — リンク追加で活性化。
        #if canImport(FirebaseAppCheck)
        #if DEBUG
        let providerFactory: AppCheckProviderFactory = AppCheckDebugProviderFactory()
        #else
        let providerFactory: AppCheckProviderFactory = SoramoyouAppCheckProviderFactory()
        #endif
        AppCheck.setAppCheckProviderFactory(providerFactory)
        #endif

        // Firebase初期化
        FirebaseApp.configure()
        
        // Crashlyticsの設定
        setupCrashlytics()
        
        // 注意: AdMob/ATT初期化はContentViewのonAppearで実行
        // init()ではビューが表示されていないため、ATTダイアログが表示されない
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
                .environmentObject(likeManager)
        }
    }
}
