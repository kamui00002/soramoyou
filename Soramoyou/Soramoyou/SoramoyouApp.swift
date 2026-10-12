//
//  SoramoyouApp.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import FirebaseCore
import FirebaseCrashlytics
import SwiftUI
import UserNotifications

@main
struct SoramoyouApp: App {
    // APNs デバイストークンを受け取り FCM に橋渡しする最小 AppDelegate を SwiftUI ライフサイクルに接続する。
    // これが無いと APNs トークンが FirebaseMessaging に渡らず、FCM トークンが発行されない（＝通知が届かない）。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authViewModel = AuthViewModel()
    @StateObject private var likeManager = LikeManager()
    /// お気に入り（🔖）状態の共有 Manager ⭐️ いいねと同じく全画面で共有する
    @StateObject private var favoriteManager = FavoriteManager()
    /// そらとも（友達グループで空を共有）の入口を出すかの判定 ⭐️ ゲスト中の画面も同じものを読む。
    /// 評価（ログイン状態の確定時）とサインアウト時の reset() の呼び出しは ContentView 側（tasks 14.1）
    @StateObject private var soratomoGate = SoratomoFeatureGate()
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

        // PostHog（行動分析）の初期化。
        // Crashlytics は「アプリが落ちたとき」しか拾えないため、
        // 落ちないまま失敗している不具合を拾う受け皿としてここで有効化する。
        LoggingService.shared.configurePostHog()

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
        // CrashlyticsはFirebaseApp.configure()で自動的に有効化される。
        // ⭐️ 収集の有効／無効は Info.plist の FirebaseCrashlyticsCollectionEnabled（ビルド設定
        //    CRASHLYTICS_COLLECTION_ENABLED）で決める。Debug = NO / Release = YES。
        //    コードの setCrashlyticsCollectionEnabled() は端末に値が残って Info.plist より優先されるため、
        //    Debug で止めると、同じ端末に後から入れた TestFlight 版まで止まってしまう。だから使わない。
        #if DEBUG
            // Debug は dSYM を作らない（DEBUG_INFORMATION_FORMAT = dwarf）ので、このビルドのクラッシュは
            // Crashlytics に届いても関数名に直せない（「見つからない dSYM（必須）」として残り続ける）。
            // 収集を止めている間、レポートは端末に溜まって「送るか捨てるか」の指示を待つ。
            // 放っておくと、同じ端末で収集が有効なビルド（Release）を起動したときに溜まった分がまとめて送られる。
            // そうならないよう、Debug では起動のたびに溜まった分を捨てる。
            // ⚠️ 捨てられるのは「この起動より前」の分だけ。最後の Debug 起動中に溜まった分（クラッシュに限らず
            //    LoggingService.recordError の非致命エラーも）は、次に同じ端末で Release を起動すると送られうる。
            //    逆に、同じ端末に残っていた TestFlight 版の未送信分も、Debug を起動するとここで捨てられる
            //    （同じ bundle ID なので保存場所が共通）。どちらも開発者の端末だけの話なので許容している。
            Crashlytics.crashlytics().deleteUnsentReports()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authViewModel)
                .environmentObject(likeManager)
                .environmentObject(favoriteManager)
                .environmentObject(soratomoGate)
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
