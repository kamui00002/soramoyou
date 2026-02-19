//
//  UITestHelpers.swift
//  SoramoyouUITests
//
//  UIテスト用のヘルパークラスと拡張機能
//

import XCTest

// MARK: - XCUIElement 拡張

extension XCUIElement {
    /// 要素が表示されてタップ可能になるまで待つ
    func waitUntilTappable(timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// スクロールして要素を表示させてからタップ
    func scrollToAndTap() {
        var retries = 3
        while !isHittable && retries > 0 {
            swipeUp()
            retries -= 1
        }

        if isHittable {
            tap()
        }
    }

    /// テキストを全消去してから入力
    func clearAndTypeText(_ text: String) {
        guard let stringValue = value as? String else {
            XCTFail("要素にテキスト値がありません")
            return
        }

        // 既存のテキストを削除
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: stringValue.count)
        typeText(deleteString)

        // 新しいテキストを入力
        typeText(text)
    }
}

// MARK: - テストヘルパークラス

class UITestHelpers {

    /// テスト用アカウント情報
    struct TestAccount {
        static let email = "uitest@example.com"
        static let password = "UITest1234"
        static let displayName = "UIテストユーザー"

        static let deleteTestEmail = "delete_test@example.com"
        static let deleteTestPassword = "Delete1234"
    }

    /// スプリングボード（システムアラート用）
    static var springboard: XCUIApplication {
        return XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    /// アプリを再起動
    static func restartApp(_ app: XCUIApplication) {
        app.terminate()
        sleep(1)
        app.launch()
    }

    /// ログイン処理
    static func performLogin(app: XCUIApplication, email: String, password: String) {
        // ウェルカム画面からログインに遷移
        let loginButton = app.buttons["ログイン"]
        if loginButton.waitForExistence(timeout: 5) {
            loginButton.tap()
        }

        // メールアドレスを入力
        let emailField = app.textFields["メールアドレス"]
        if emailField.waitForExistence(timeout: 3) {
            emailField.tap()
            emailField.typeText(email)
        }

        // パスワードを入力
        let passwordField = app.secureTextFields["パスワード"]
        if passwordField.exists {
            passwordField.tap()
            passwordField.typeText(password)
        }

        // ログインボタンをタップ
        let submitButton = app.buttons["ログイン"]
        if submitButton.exists {
            submitButton.tap()
        }

        // ホーム画面が表示されるまで待つ
        let homeTab = app.tabBars.buttons["ホーム"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10), "ログイン後にホーム画面が表示されない")
    }

    /// ゲストモードで開始
    static func startAsGuest(app: XCUIApplication) {
        let guestButton = app.buttons["ゲストで始める"]
        if guestButton.waitForExistence(timeout: 5) {
            guestButton.tap()
        }
    }

    /// ログアウト処理
    static func performLogout(app: XCUIApplication) {
        // プロフィールタブに移動
        let profileTab = app.tabBars.buttons["プロフィール"]
        if profileTab.waitForExistence(timeout: 5) {
            profileTab.tap()
        }

        // 設定ボタンをタップ
        let settingsButton = app.buttons["設定"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        }

        // ログアウトボタンをタップ
        let logoutButton = app.buttons["ログアウト"]
        if logoutButton.waitForExistence(timeout: 5) {
            logoutButton.tap()
        }

        // 確認アラートで「ログアウト」を選択
        let confirmAlert = app.alerts["ログアウト"]
        if confirmAlert.waitForExistence(timeout: 3) {
            let confirmButton = confirmAlert.buttons["ログアウト"]
            if confirmButton.exists {
                confirmButton.tap()
            }
        }
    }

    /// スクリーンショットを撮影してアタッチ
    static func takeScreenshot(app: XCUIApplication, name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "スクリーンショット: \(name)") { activity in
            activity.add(attachment)
        }
    }

    /// ホームタブに移動
    static func navigateToHome(app: XCUIApplication) {
        let homeTab = app.tabBars.buttons["ホーム"]
        if homeTab.exists {
            homeTab.tap()
        }
    }

    /// プロフィールタブに移動
    static func navigateToProfile(app: XCUIApplication) {
        let profileTab = app.tabBars.buttons["プロフィール"]
        if profileTab.exists {
            profileTab.tap()
        }
    }

    /// 検索タブに移動
    static func navigateToSearch(app: XCUIApplication) {
        let searchTab = app.tabBars.buttons["検索"]
        if searchTab.exists {
            searchTab.tap()
        }
    }

    /// 設定画面を開く
    static func navigateToSettings(app: XCUIApplication) {
        navigateToProfile(app: app)

        let settingsButton = app.buttons["設定"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        }
    }

    /// システムアラートを処理
    static func handleSystemAlert(app: XCUIApplication, buttonTitle: String) {
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let button = alert.buttons[buttonTitle]
            if button.exists {
                button.tap()
            } else {
                // フォールバック: 最初のボタンをタップ
                alert.buttons.firstMatch.tap()
            }
        }
    }

    /// ATTダイアログを処理（許可/拒否）
    static func handleATTDialog(allow: Bool) {
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            if allow {
                let allowButton = alert.buttons["許可"]
                if allowButton.exists {
                    allowButton.tap()
                }
            } else {
                let denyButton = alert.buttons["Askアプリにトラッキングしないように要求"]
                if denyButton.exists {
                    denyButton.tap()
                }
            }
        }
    }

    /// カメラロールアクセス許可ダイアログを処理
    static func handlePhotoLibraryPermission(allow: Bool) {
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            if allow {
                // 「すべての写真へのアクセスを許可」または「選択した写真へのアクセスを許可」
                let allowButton = alert.buttons.matching(NSPredicate(format: "label CONTAINS '許可'")).firstMatch
                if allowButton.exists {
                    allowButton.tap()
                }
            } else {
                let denyButton = alert.buttons["許可しない"]
                if denyButton.exists {
                    denyButton.tap()
                }
            }
        }
    }

    /// 位置情報アクセス許可ダイアログを処理
    static func handleLocationPermission(allow: Bool) {
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            if allow {
                let allowButton = alert.buttons["Appの使用中は許可"]
                if allowButton.exists {
                    allowButton.tap()
                }
            } else {
                let denyButton = alert.buttons["許可しない"]
                if denyButton.exists {
                    denyButton.tap()
                }
            }
        }
    }
}
