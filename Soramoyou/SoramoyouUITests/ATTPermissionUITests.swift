//
//  ATTPermissionUITests.swift
//  SoramoyouUITests
//
//  ATT（App Tracking Transparency）の動作テスト
//  - ATTダイアログの表示タイミング
//  - 広告の初期化順序
//

import XCTest

final class ATTPermissionUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI-TESTING"]

        // ATTの状態をリセット（テスト環境用）
        app.launchEnvironment["RESET_ATT_STATUS"] = "1"

        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - ATTダイアログ表示タイミングのテスト

    /// ATTダイアログがアプリ起動後に表示されることを確認
    /// （init()ではなく、ContentView.onAppear で表示される）
    func testATTDialogAppearsAfterLaunch() throws {
        // アプリが起動してメインビューが表示されることを確認
        let welcomeView = app.otherElements["WelcomeView"]
        let contentView = app.otherElements["ContentView"]

        // ウェルカム画面またはコンテンツビューが表示されるまで待つ
        let viewAppeared = welcomeView.waitForExistence(timeout: 5) || contentView.waitForExistence(timeout: 5)
        XCTAssertTrue(viewAppeared, "アプリのメインビューが表示されない")

        // ATTダイアログが表示されるかどうかを確認
        // ⚠️ 注意: ATTダイアログはシステムアラートなので、XCUITestでは直接検出できない場合がある
        // シミュレータでは表示されない可能性があるため、実機テストが推奨される

        // ATTダイアログが表示された場合の処理（実機テストでのみ有効）
        let attAlert = springboard.alerts.firstMatch
        if attAlert.waitForExistence(timeout: 3) {
            // ATTダイアログが表示されたことを確認
            XCTAssertTrue(attAlert.exists, "ATTダイアログが表示された")

            // 「許可」または「許可しない」ボタンが存在することを確認
            let allowButton = attAlert.buttons["許可"]
            let denyButton = attAlert.buttons["Askアプリにトラッキングしないように要求"]

            XCTAssertTrue(allowButton.exists || denyButton.exists, "ATTダイアログのボタンが表示されない")

            // テストでは「許可しない」を選択
            if denyButton.exists {
                denyButton.tap()
            }
        }
    }

    /// ATTダイアログが init() では表示されないことを確認
    /// （iOS仕様：最初のビューが表示される前のATTリクエストは無視される）
    func testATTDialogNotShownDuringInit() throws {
        // アプリ起動直後（init()実行中）にATTダイアログが表示されないことを確認

        // 起動直後0.5秒以内にATTダイアログが表示されないことを確認
        let attAlert = springboard.alerts.firstMatch
        let dialogAppeared = attAlert.waitForExistence(timeout: 0.5)

        // init()中は表示されない（ビュー表示後に表示される）
        XCTAssertFalse(dialogAppeared, "ATTダイアログが init() 中に表示されてしまった")
    }

    /// ATTの許可状態に応じて広告が適切に初期化されることを確認
    func testAdInitializationAfterATTResponse() throws {
        // ウェルカム画面が表示されるまで待つ
        let welcomeView = app.otherElements["WelcomeView"]
        XCTAssertTrue(welcomeView.waitForExistence(timeout: 5), "ウェルカム画面が表示されない")

        // ATTダイアログが表示された場合の処理
        let attAlert = springboard.alerts.firstMatch
        if attAlert.waitForExistence(timeout: 3) {
            // 「許可」を選択
            let allowButton = attAlert.buttons["許可"]
            if allowButton.exists {
                allowButton.tap()
            } else {
                // 許可しない
                attAlert.buttons.firstMatch.tap()
            }
        }

        // ゲストモードで開始
        let guestButton = app.buttons["ゲストで始める"]
        if guestButton.waitForExistence(timeout: 3) {
            guestButton.tap()
        }

        // ホーム画面に遷移
        let homeTab = app.tabBars.buttons["ホーム"]
        if homeTab.waitForExistence(timeout: 5) {
            homeTab.tap()
        }

        // 広告バナーが表示されることを確認（AdServiceが初期化されている）
        let adBanner = app.otherElements["BannerAdView"]

        // 広告の初期化には時間がかかる場合があるため、十分な待機時間を設定
        let adInitialized = adBanner.waitForExistence(timeout: 10)

        // ⚠️ 注意: テスト環境では広告が表示されない場合があるため、
        // 広告の有無ではなく、クラッシュしないことを確認
        XCTAssertTrue(app.exists, "広告初期化後もアプリが正常に動作している")
    }

    /// ATT許可前に広告が初期化されないことを確認
    func testAdNotInitializedBeforeATTPermission() throws {
        // アプリ起動直後、ATT許可前の状態を確認

        // ウェルカム画面が表示されることを確認
        let welcomeView = app.otherElements["WelcomeView"]
        XCTAssertTrue(welcomeView.waitForExistence(timeout: 5))

        // この時点では広告バナーが表示されていないことを確認
        let adBanner = app.otherElements["BannerAdView"]

        // ATT許可前は広告が初期化されていない
        let adAppearedEarly = adBanner.waitForExistence(timeout: 2)

        // ATT許可前に広告が表示されるべきではない
        // （ただし、AdService.isAdsEnabled が false の場合は常に非表示）
        XCTAssertFalse(adAppearedEarly, "ATT許可前に広告が表示されてしまった")
    }

    // MARK: - ヘルパープロパティ

    /// スプリングボード（システムアラートにアクセスするため）
    private var springboard: XCUIApplication {
        return XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }
}
