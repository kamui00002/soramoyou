//
//  SoratomoNotificationPrimer.swift ⭐️
//  Soramoyou
//
//  そらともの「通知の事前説明」と「設定の案内」を出すかの判定（tasks 12.2・要件 10.1〜10.6・10.17）
//
//  グループの作成・参加が終わったときに、次のどれを出すかを決める。
//    - 端末の通知許可がまだ決まっていない、かつ事前説明をまだ出していない → 事前説明を出す
//    - 端末の通知許可が拒否されている、かつ設定の案内をまだ出していない   → 設定の案内を出す
//    - それ以外 → 何も出さない
//  「出した」という記録は端末の UserDefaults に残す（通知の許可は端末ごとのため、アカウントではなく端末で数える）。
//
//  ⚠️ 通知の許可ダイアログは、既存の `PushNotificationManager.requestAuthorizationAndRegister()` だけを通す。
//     ここから UNUserNotificationCenter.requestAuthorization を直接呼ばない（要件 10.6・独自の経路で重ねて出さない）。
//     許可状態を「読む」だけは UNUserNotificationCenter から直接行う（許可の要求は伴わない）。
//  ⚠️ 画面の部品は Views/Soratomo/SoratomoNotificationPrimerView.swift。呼び出しの組み込みは tasks 13.3。
//

import Foundation
import UserNotifications

// MARK: - 判定の結果

/// 作成・参加の完了後に出すもの
enum SoratomoPrimerDecision: Equatable {
    /// 通知の事前説明を出す（端末の許可が未決定で、まだ出していない）
    case showPrimer
    /// 設定アプリで通知を許可する方法の案内を出す（端末の許可が拒否で、まだ案内していない）
    case showSettingsGuide
    /// 何も出さない
    case none
}

// MARK: - 窓口

/// 通知の事前説明の窓口
///
/// 画面（`SoratomoNotificationPrimerView`）と、作成・参加の ViewModel（tasks 13.3）は、この protocol だけを見る。
@MainActor
protocol SoratomoNotificationPrimerProtocol {
    /// 端末の許可状態と、端末内の「出した」記録から、何を出すかを決める
    ///
    /// 記録は書き換えない（読むだけ）。呼んだだけでは「出した」ことにならない。
    func decide() async -> SoratomoPrimerDecision

    /// 事前説明で選んだ操作を処理する
    ///
    /// - `allow`（「通知を受け取る」）: `PushNotificationManager.requestAuthorizationAndRegister` だけを通して
    ///   OS の許可ダイアログを出す。
    /// - `later`（「あとで」）: 何も要求しない。
    ///
    /// どちらも「事前説明を出した」記録を残し、`soratomo_notification_prompt_result` を 1 回だけ記録する。
    /// - Parameter choice: 選んだ操作
    /// - Returns: 通知が許可されたか（`later` は常に false）。
    ///   すでに選んだ後（処理中を含む）の呼び出しは、何もせず false を返し、計測も記録も増やさない。
    func handle(choice: SoratomoPrimerChoice) async -> Bool

    /// 設定の案内を出したことを記録する（何度呼んでも同じ。案内の画面が表示されたときに呼ぶ）
    func markSettingsGuideShown()
}

// MARK: - 実装

/// 通知の事前説明の判定と、選んだ操作の処理
///
/// 端末の許可状態の読み取り・UserDefaults・許可の要求・計測は、init の引数で差し替えられる
/// （既定は本番の仕組み。単体テストで差し替える）。
@MainActor
final class SoratomoNotificationPrimer: SoratomoNotificationPrimerProtocol {
    // MARK: 端末内の記録のキー（design.md のとおり。変えると既読が消えて、もう一度出てしまう）

    /// 事前説明を出した（選んだ）記録のキー
    static let primerShownKey = "soratomo.notificationPrimerShown"
    /// 設定の案内を出した記録のキー
    static let settingsGuideShownKey = "soratomo.notificationSettingsGuideShown"

    // MARK: 差し替えられるもの

    /// 端末の通知許可の状態を読む
    private let readAuthorizationStatus: () async -> UNAuthorizationStatus
    /// 「出した」記録の置き場
    private let defaults: UserDefaults
    /// 通知の許可を求める（許可されたか を返す）
    private let requestAuthorization: () async -> Bool
    /// 計測を記録する
    private let log: (SoratomoEvent) -> Void

    /// - Parameters:
    ///   - readAuthorizationStatus: 端末の通知許可の状態を読む。既定は、通知センターの現在の設定
    ///   - defaults: 「出した」記録の置き場。既定は標準の UserDefaults
    ///   - requestAuthorization: 通知の許可を求める。既定は既存の `PushNotificationManager`
    ///     （許可されたら APNs 登録まで行う）
    ///   - log: 計測を記録する。既定は `SoratomoAnalytics.log`
    init(
        readAuthorizationStatus: @escaping () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        defaults: UserDefaults = .standard,
        requestAuthorization: @escaping () async -> Bool = {
            await PushNotificationManager.shared.requestAuthorizationAndRegister()
        },
        log: @escaping (SoratomoEvent) -> Void = { SoratomoAnalytics.log($0) }
    ) {
        self.readAuthorizationStatus = readAuthorizationStatus
        self.defaults = defaults
        self.requestAuthorization = requestAuthorization
        self.log = log
    }

    // MARK: SoratomoNotificationPrimerProtocol

    func decide() async -> SoratomoPrimerDecision {
        let status = await readAuthorizationStatus()
        switch status {
        case .notDetermined:
            // 未決定: まだ事前説明を出していないときだけ出す（10.1）
            return defaults.bool(forKey: Self.primerShownKey) ? .none : .showPrimer
        case .denied:
            // 拒否: まだ設定の案内を出していないときだけ出す（10.5）
            return defaults.bool(forKey: Self.settingsGuideShownKey) ? .none : .showSettingsGuide
        case .authorized, .provisional, .ephemeral:
            // 許可済み（仮の許可・一時的な許可を含む）: 説明も案内も要らない
            return .none
        @unknown default:
            // 将来の OS で増えた状態は、利用者に何も出さない側へ倒す（出し過ぎない）
            return .none
        }
    }

    func handle(choice: SoratomoPrimerChoice) async -> Bool {
        // すでに選んだ後（許可ダイアログの待ち中を含む）の呼び出しでは、許可の要求も計測も増やさない。
        // 「出した」記録を最初の await より前に書くので、連打されても 2 つ目はここで止まる（選んだときに 1 回だけ）
        guard !defaults.bool(forKey: Self.primerShownKey) else { return false }

        // 選んだ時点で「出した」ことにする。許可ダイアログの待ち中にアプリが終了されても、
        // 事前説明をもう一度出さないため（10.1・10.4 の「1 回だけ」）
        defaults.set(true, forKey: Self.primerShownKey)

        switch choice {
        case .allow:
            // 既存の通知許可の仕組みだけを通す（10.3・10.6）
            let granted = await requestAuthorization()
            log(.notificationPromptResult(choice: .allow, granted: granted))
            return granted
        case .later:
            // 「あとで」は OS の許可ダイアログを出さない（10.4）。何も求めていないので granted は false
            log(.notificationPromptResult(choice: .later, granted: false))
            return false
        }
    }

    func markSettingsGuideShown() {
        defaults.set(true, forKey: Self.settingsGuideShownKey)
    }
}
