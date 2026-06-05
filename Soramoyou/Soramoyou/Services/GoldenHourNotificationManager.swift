//
//  GoldenHourNotificationManager.swift
//  Soramoyou
//
//  ゴールデンアワー（日没前の写真好適時間帯）のローカル通知を管理する。
//  端末内の太陽計算（SolarCalculator）のみで完結し、気象 API・バックエンド・プッシュ基盤は不要。
//
//  仕組み:
//  - 設定 ON 時に現在地を1回取得し、粗い緯度経度（小数2桁 ≒ 1km）を UserDefaults に保存
//  - 今後14日分の「日没75分前」（= ゴールデンアワー開始の約15分前）を事前スケジュール
//  - アプリがフォアグラウンドになるたびに洗い替えし、14日窓をローリング維持
//

import Foundation
import CoreLocation
import UserNotifications

/// ゴールデンアワー通知の権限要求・スケジュール・削除を担うマネージャ。
/// UNUserNotificationCenterDelegate を兼ね、フォアグラウンド表示と通知タップの計測を行う。
@MainActor
final class GoldenHourNotificationManager: NSObject {

    static let shared = GoldenHourNotificationManager()

    // MARK: - 定数

    /// UserDefaults のキー（設定画面の @AppStorage と共有）
    enum DefaultsKey {
        /// 通知が有効か
        static let enabled = "goldenHourNotificationEnabled"
        /// 保存した粗い緯度（小数2桁）
        static let latitude = "goldenHourNotificationLatitude"
        /// 保存した粗い経度（小数2桁）
        static let longitude = "goldenHourNotificationLongitude"
    }

    /// 通知識別子の接頭辞（例: goldenhour-2026-06-05）。
    /// prefix 一致で削除することで、将来の他種の通知と衝突させない。
    static let identifierPrefix = "goldenhour-"

    /// 何日先まで事前スケジュールするか（iOS の pending 上限64に対して余裕を持たせる）
    private let scheduleDays = 14

    /// 日没の何分前に通知するか（ゴールデンアワー = 日没60分前〜日没、その開始15分前）
    private let notifyBeforeSunsetMinutes = 75

    // MARK: - 依存

    private let locationService: LocationServiceProtocol
    private let notificationCenter = UNUserNotificationCenter.current()

    init(locationService: LocationServiceProtocol = LocationService()) {
        self.locationService = locationService
        super.init()
    }

    // MARK: - 状態

    /// 通知が有効か（設定画面のトグルと同じ UserDefaults を参照）
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.enabled)
    }

    /// 設定 ON フローの結果（設定画面でのエラー表示分岐に使う）
    enum EnableResult {
        /// 有効化に成功（スケジュール済み）
        case enabled
        /// 通知権限が拒否された
        case notificationPermissionDenied
        /// 位置情報の権限が拒否された
        case locationPermissionDenied
        /// 位置情報の取得に失敗した（権限はあるが測位エラー等）
        case locationUnavailable
    }

    // MARK: - 有効化 / 無効化

    /// 通知を有効化する: 通知権限 → 位置権限+現在地取得 → 粗い座標を保存 → スケジュール。
    /// 失敗時は有効化せず、原因を返す（呼び出し側でトグルを戻して設定アプリへ誘導する）。
    func enable() async -> EnableResult {
        // 1. 通知権限（バッジは使わないため alert + sound のみ）
        let granted = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            return .notificationPermissionDenied
        }

        // 2. 現在地を1回取得（内部で位置権限も要求される）
        let location: CLLocation
        do {
            location = try await locationService.getCurrentLocation()
        } catch LocationServiceError.permissionDenied {
            return .locationPermissionDenied
        } catch {
            return .locationUnavailable
        }

        // 3. 粗い座標（小数2桁 ≒ 1km）だけを保存。日没時刻の計算に高精度は不要で、
        //    プライバシー面でも正確な現在地を持ち続けない。
        let coarseLatitude = (location.coordinate.latitude * 100).rounded() / 100
        let coarseLongitude = (location.coordinate.longitude * 100).rounded() / 100
        let defaults = UserDefaults.standard
        defaults.set(coarseLatitude, forKey: DefaultsKey.latitude)
        defaults.set(coarseLongitude, forKey: DefaultsKey.longitude)
        defaults.set(true, forKey: DefaultsKey.enabled)

        // 4. スケジュール
        let scheduledCount = await reschedule()
        LoggingService.shared.logEvent(
            "golden_hour_enabled",
            parameters: ["scheduled_count": scheduledCount]
        )
        return .enabled
    }

    /// 通知を無効化し、登録済みのゴールデンアワー通知をすべて削除する
    func disable() async {
        UserDefaults.standard.set(false, forKey: DefaultsKey.enabled)
        await removePendingGoldenHourNotifications()
        LoggingService.shared.logEvent("golden_hour_disabled", parameters: nil)
    }

    /// アプリがフォアグラウンドになった時に呼ぶ。有効なら14日窓を洗い替えする。
    func rescheduleIfEnabled() async {
        guard isEnabled else { return }
        await reschedule()
    }

    // MARK: - スケジュール本体

    /// 保存済みの座標から今後14日分の通知を洗い替えで登録する。
    /// - Returns: 登録した件数（座標未保存などで登録できない場合は 0）
    @discardableResult
    private func reschedule() async -> Int {
        let defaults = UserDefaults.standard
        // object(forKey:) で存在確認（double(forKey:) は未設定でも 0.0 を返すため）
        guard defaults.object(forKey: DefaultsKey.latitude) != nil,
              defaults.object(forKey: DefaultsKey.longitude) != nil else {
            return 0
        }
        let latitude = defaults.double(forKey: DefaultsKey.latitude)
        let longitude = defaults.double(forKey: DefaultsKey.longitude)

        // 既存のゴールデンアワー通知だけを削除してから登録（洗い替え）
        await removePendingGoldenHourNotifications()

        let fireDates = SolarCalculator.goldenHourFireDates(
            latitude: latitude,
            longitude: longitude,
            from: Date(),
            days: scheduleDays,
            notifyBeforeSunsetMinutes: notifyBeforeSunsetMinutes,
            timeZone: .current
        )

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "H:mm"
        timeFormatter.timeZone = .current

        var calendar = Calendar.current
        calendar.timeZone = .current

        for fireDate in fireDates {
            // 登録の途中で OFF に切り替えられたら中断する（disable() との競合で
            // 「OFF なのに通知が残る」状態を防ぐ。await を跨ぐ処理のため毎回確認する）
            guard isEnabled else {
                await removePendingGoldenHourNotifications()
                return 0
            }

            let sunset = fireDate.addingTimeInterval(Double(notifyBeforeSunsetMinutes) * 60.0)

            let content = UNMutableNotificationContent()
            content.title = "まもなくゴールデンアワー"
            content.body = "今日の日没は\(timeFormatter.string(from: sunset))。空がいちばん美しい時間です"
            content.sound = .default

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: Self.identifier(for: fireDate, calendar: calendar),
                content: content,
                trigger: trigger
            )
            try? await notificationCenter.add(request)
        }

        // 登録完了後にも OFF への切替が無かったか最終確認する（disable() の削除と
        // 入れ違いで add が着地した分を回収する）
        guard isEnabled else {
            await removePendingGoldenHourNotifications()
            return 0
        }
        return fireDates.count
    }

    /// 発火日から通知識別子を生成（例: goldenhour-2026-06-05）
    private static func identifier(for fireDate: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: fireDate)
        return String(
            format: "%@%04d-%02d-%02d",
            identifierPrefix, comps.year ?? 0, comps.month ?? 0, comps.day ?? 0
        )
    }

    /// 登録済みのゴールデンアワー通知（prefix 一致）だけを削除する
    private func removePendingGoldenHourNotifications() async {
        let pending = await notificationCenter.pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        guard !identifiers.isEmpty else { return }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension GoldenHourNotificationManager: UNUserNotificationCenterDelegate {

    /// アプリがフォアグラウンドでも通知をバナー表示する
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// 通知タップを計測する
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.identifier.hasPrefix(Self.identifierPrefix) {
            LoggingService.shared.logEvent("golden_hour_notification_tapped", parameters: nil)
        }
    }
}
