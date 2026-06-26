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
    // APNs デバイストークンを受け取り FCM に橋渡しする最小 AppDelegate を SwiftUI ライフサイクルに接続する。
    // これが無いと APNs トークンが FirebaseMessaging に渡らず、FCM トークンが発行されない（＝通知が届かない）。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var likeManager = LikeManager()
    /// シーンの状態（フォアグラウンド復帰でゴールデンアワー通知を洗い替えするために監視）
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Firebase初期化
        FirebaseApp.configure()

        // プッシュ通知(FCM)の登録トークン受け取りを有効化（configure() の直後に張る）。
        // ここでは許可ダイアログは出さない（許可済みユーザーの登録は scenePhase で行う）。
        PushNotificationManager.shared.configure()

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
                // すでに通知を許可しているユーザーは、無言で APNs 登録（＝FCMトークン発行）する。
                // 未許可ユーザーにはここではプロンプトを出さない（プッシュ系トグルON など明示操作で要求）。
                PushNotificationManager.shared.registerForPushIfAuthorized()
                Task {
                    await GoldenHourNotificationManager.shared.rescheduleIfEnabled()
                }
            }
        }
    }
}
