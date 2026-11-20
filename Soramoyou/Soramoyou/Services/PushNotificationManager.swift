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

import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import Foundation
import UIKit
import UserNotifications

/// FCM の受信側プラミング（トークン保存・許可要求・APNs 登録）。
final class PushNotificationManager: NSObject, MessagingDelegate {
    static let shared = PushNotificationManager()
    override private init() { super.init() }

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
            let granted = await (try? center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
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
    /// ⚠️ 電波が無いと削除は返事をしない。`tokenClearTimeout` を過ぎたら待つのをやめて戻る（ログアウトを止めない）。
    ///    そのときは users/{uid} に宛先が残り、共有端末で前の人宛の通知が届く余地が残る（承知の上での引き換え）。
    func clearTokenForCurrentUser() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let timeout = Self.tokenClearTimeout
        // 操作には uid だけを渡し、Firestore の参照は中で作る（Sendable でない値を持ち込まない）
        let outcome = await Self.wait(atMost: timeout) {
            try await Firestore.firestore().collection("users").document(uid).updateData([
                "fcmToken": FieldValue.delete(),
                "fcmTokenUpdatedAt": FieldValue.delete(),
            ])
        }
        // ログは返ってきた結果を見てここで 1 回だけ出す（時間切れの後に遅れて来た失敗では出さない）
        switch outcome {
        case .finished:
            break
        case let .failed(error):
            print("❌ FCMトークン削除失敗 uid=\(uid) error=\(error.localizedDescription)")
        case .timedOut:
            print("❌ FCMトークン削除が \(timeout) 以内に終わらない（電波が無い可能性）。待たずにログアウトを進める uid=\(uid)")
        }
    }

    // MARK: - 時間切れつきの待ち

    /// ログアウトのときにトークン削除を待つ時間の上限
    static let tokenClearTimeout: Duration = .seconds(3)

    /// 時間切れつきで待った操作の結果
    enum WaitOutcome {
        /// 時間内に終わった
        case finished
        /// 時間内に失敗した
        case failed(Error)
        /// 時間内に終わらなかった（操作は止めずに置いていく）
        case timedOut
    }

    /// 操作の終わりを `timeout` まで待つ。投げずに結果を返す（投げると signOut の catch に入り、ログアウトが止まる）
    /// - 操作と時計を別々の Task で動かし、先に終わった方の結果を 1 回だけ返す
    /// - 時間切れのあとも操作の Task は止めない（返事は捨てる）
    /// - ⚠️ withTaskGroup では作らない。グループは抜ける前に全部の子の終わりを待ち、
    ///   Firestore の async は取り消しに反応しないので、時間切れでも抜けられない（テストの陽性対照で実測済み）
    static func wait(
        atMost timeout: Duration,
        for operation: @escaping @Sendable () async throws -> Void
    ) async -> WaitOutcome {
        await withCheckedContinuation { continuation in
            let once = WaitResumeOnce(continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                once.resume(.timedOut)
            }
            Task {
                defer { timer.cancel() }
                do {
                    try await operation()
                    once.resume(.finished)
                } catch {
                    once.resume(.failed(error))
                }
            }
        }
    }

    /// continuation を 1 回だけ再開する（時間切れと操作の終わりの、先に来た方だけを通す）
    private final class WaitResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<WaitOutcome, Never>?

        init(_ continuation: CheckedContinuation<WaitOutcome, Never>) {
            self.continuation = continuation
        }

        /// 最初の呼び出しだけ continuation を再開する。2 回目以降は何もしない
        func resume(_ outcome: WaitOutcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }

    // MARK: - MessagingDelegate

    /// 登録トークンが発行・更新されたときに呼ばれる。ログイン中なら Firestore に保存する。
    func messaging(_: Messaging, didReceiveRegistrationToken fcmToken: String?) {
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
            "fcmTokenUpdatedAt": FieldValue.serverTimestamp(),
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
