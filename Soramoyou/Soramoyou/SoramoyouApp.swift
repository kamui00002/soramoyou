//
//  SoramoyouApp.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI
import FirebaseCore
import FirebaseCrashlytics
import UserNotifications

@main
struct SoramoyouApp: App {
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var likeManager = LikeManager()
    /// シーンの状態（フォアグラウンド復帰でゴールデンアワー通知を洗い替えするために監視）
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Firebase初期化
        FirebaseApp.configure()

        // Crashlyticsの設定
        setupCrashlytics()

        // ゴールデンアワー通知のデリゲート設定
        // （通知タップからのコールドローンチに応答するため、起動完了前に設定する必要がある）
        UNUserNotificationCenter.current().delegate = GoldenHourNotificationManager.shared

        // 注意: AdMob/ATT初期化はContentViewのonAppearで実行
        // init()ではビューが表示されていないため、ATTダイアログが表示されない

        #if DEBUG
        // シミュレータ確認用：launchArg SEED_WIDGET でサンプルの空をウィジェットキャッシュへ投入する。
        if ProcessInfo.processInfo.arguments.contains("SEED_WIDGET") {
            WidgetCacheManager.shared.debugSeed()
        }
        // 一バケット偏り（evening 5枚）を再現し、アルバムと今の空が別写真を選ぶか検証ログを出す。
        if ProcessInfo.processInfo.arguments.contains("SEED_WIDGET_ONE_BUCKET") {
            WidgetCacheManager.shared.debugSeedOneBucket()
        }
        #endif
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
        .onChange(of: scenePhase) { newPhase in
            // フォアグラウンド復帰のたびに、有効ならゴールデンアワー通知の14日窓を洗い替えする
            if newPhase == .active {
                // インストール済みウィジェットの数・サイズを起動後1回だけ計測（普及度 KPI）
                WidgetCacheManager.shared.logActiveWidgetsOncePerLaunch()
                Task {
                    await GoldenHourNotificationManager.shared.rescheduleIfEnabled()
                }
            }
        }
    }
}
