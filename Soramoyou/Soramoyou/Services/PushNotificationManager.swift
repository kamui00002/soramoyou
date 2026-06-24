//
//  PushNotificationManager.swift
//  Soramoyou
//
//  プッシュ通知（FCM）の「受信側プラミング」。
//  役割は3つだけに絞る（送信判定や配信内容プレフは別レイヤー）:
//    1. FCM 登録トークンを受け取り、ログイン中ユーザーの users/{uid} にマージ保存する。
//    2. すでに通知が許可されているユーザーを「無言で」APNs 登録する（起動時）。
//    3. 明示操作（プッシュ系トグルON 等の良い瞬間）から通知許可を要求して登録する。
//
//  ⚠️ 通知許可は端末に1つだけ（UNUserNotificationCenter）。ゴールデンアワー通知と共有するため、
//     ここで勝手に二重プロンプトを出さない。許可状態を見て登録するだけにする。
//  ⚠️ UNUserNotificationCenter.delegate は GoldenHourNotificationManager が保持している。
//     ここでは奪わない（奪うと golden-hour のタップ処理が壊れる）。FCM は既定で APNs メソッドを
//     swizzling するため、APNs トークン受け渡しに AppDelegate は不要。
//

import Foundation
import FirebaseMessaging
import FirebaseAuth
import FirebaseFirestore
import UserNotifications
import UIKit

/// FCM の受信側プラミング（トークン保存・許可要求・APNs 登録）。
final class PushNotificationManager: NSObject, MessagingDelegate {
    static let shared = PushNotificationManager()
    private override init() { super.init() }

    /// FirebaseApp.configure() の直後に1回呼ぶ。Messaging の登録トークン通知を受け取れるようにする。
    func configure() {
        Messaging.messaging().delegate = self
    }

    /// すでに通知を許可しているユーザーだけ、プロンプトを出さずに APNs 登録する（起動時に呼ぶ想定）。
    /// 未許可（notDetermined / denied）のときは何もしない＝唐突な許可ダイアログを出さない。
    func registerForPushIfAuthorized() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            default:
                break
            }
        }
    }

    /// 明示操作（プッシュ系トグルON 等）から通知許可を要求し、許可されたら APNs 登録する。
    /// すでに許可済みなら即登録。拒否なら登録しない。
    /// - Returns: 通知が許可されているか（＝プッシュを受け取れる状態か）。
    @discardableResult
    func requestAuthorizationAndRegister() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            // ephemeral（App Clip 等の一時許可）も「許可済み」として扱い、登録する。
            await registerOnMain()
            return true
        case .denied:
            return false
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            if granted { await registerOnMain() }
            return granted
        @unknown default:
            return false
        }
    }

    /// ログイン直後など、現在の FCM トークンを取得してログイン中なら保存する（トークン更新を待たずに同期）。
    func syncTokenIfLoggedIn() {
        guard Auth.auth().currentUser != nil else { return }
        Messaging.messaging().token { [weak self] token, error in
            if let token {
                self?.saveToken(token)
            } else if let error {
                print("❌ FCMトークン取得失敗 error=\(error.localizedDescription)")
            }
        }
    }

    /// ログアウト時に、現在のユーザーの users/{uid}.fcmToken を削除する。
    /// 共有端末で別アカウントにこの端末のトークンが残り、旧ユーザー宛の通知が誤配信されるのを防ぐ。
    /// ⚠️ Auth がまだ有効なうち（authService.signOut の前）に呼ぶこと（rules の所有者更新を通すため）。
    func clearTokenForCurrentUser() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            try await Firestore.firestore().collection("users").document(uid).updateData([
                "fcmToken": FieldValue.delete(),
                "fcmTokenUpdatedAt": FieldValue.delete()
            ])
        } catch {
            print("❌ FCMトークン削除失敗 uid=\(uid) error=\(error.localizedDescription)")
        }
    }

    // MARK: - MessagingDelegate

    /// 登録トークンが発行・更新されたときに呼ばれる。ログイン中なら Firestore に保存する。
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        saveToken(fcmToken)
    }

    // MARK: - Private

    @MainActor
    private func registerOnMain() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// FCM トークンをログイン中ユーザーの users/{uid} にマージ保存する（他フィールドは潰さない）。
    /// 未ログイン時は保存しない（ログイン後に `syncTokenIfLoggedIn()` で再保存される）。
    private func saveToken(_ token: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid).setData([
            "fcmToken": token,
            "fcmTokenUpdatedAt": FieldValue.serverTimestamp()
        ], merge: true) { error in
            if let error {
                // 失敗を握りつぶさない。print に加えてテレメトリへ送る。
                // FCMトークン保存失敗は「通知が一切来ないが落ちない」沈黙バグで、本番で検知できないと
                // 原因不明の苦情になる（Crashlytics は落ちないと拾えない）。トークン値はログに出さない。
                print("❌ FCMトークン保存失敗 uid=\(uid) error=\(error.localizedDescription)")
                LoggingService.shared.recordNonFatalError(error, context: "PushNotificationManager.saveToken")
            }
        }
    }
}
