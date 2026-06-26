//
//  AppDelegate.swift
//  Soramoyou
//
//  APNs デバイストークンを受け取り、FCM に橋渡しするためだけの最小 AppDelegate。
//
//  なぜ必要か:
//    SwiftUI の `@main struct App` 構成には旧来の AppDelegate が存在しない。
//    そのため `didRegisterForRemoteNotificationsWithDeviceToken`（Apple から APNs
//    デバイストークンが返ってくる受け口）を実装する場所が無く、APNs トークンが
//    FirebaseMessaging に渡らない。結果 FCM は
//      「APNS device token not set before retrieving FCM Token …」
//      「Declining request for FCM Token since no APNS Token specified」
//    を出してトークン発行を却下し、users/{uid}.fcmToken が永遠に書かれない
//    （＝誰にもプッシュ通知が届かない）。
//    Firebase の AppDelegate swizzling は既定 ON だが、AppDelegate 自体が不在だと
//    フックする相手が無く空振りするため、ここで明示的に受け口を用意して橋渡しする。
//
//  ⚠️ 役割はこの1点（APNs → FCM の橋渡し）だけに限定する:
//    - UNUserNotificationCenterDelegate には一切関与しない
//      （フォアグラウンド表示・通知タップ計測は GoldenHourNotificationManager が保持。
//       ここで delegate を奪うと golden-hour 通知のタップ処理が壊れる）。
//    - MessagingDelegate（FCM トークン受信）にも関与しない
//      （PushNotificationManager が保持）。
//

import UIKit
import FirebaseMessaging

/// APNs デバイストークンを FCM に橋渡しするためだけの最小 AppDelegate。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Apple から APNs デバイストークンが返ってきたら、FirebaseMessaging に渡す。
    /// これが FCM 登録トークン発行の前提（無いと FCM トークンが出ない）。
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // FCM に APNs トークンを引き渡す。以降 FirebaseMessaging が FCM トークンを mint できる。
        Messaging.messaging().apnsToken = deviceToken
    }

    /// APNs 登録に失敗したケース。沈黙させずログに残す（トークン値は出さない）。
    /// 通知が一切来ないのに落ちない「沈黙バグ」を本番で切り分けられるようにする。
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("❌ APNs 登録失敗 error=\(error.localizedDescription)")
    }
}
