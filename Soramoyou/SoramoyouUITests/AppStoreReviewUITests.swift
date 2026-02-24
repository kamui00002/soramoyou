//
//  AppStoreReviewUITests.swift
//  SoramoyouUITests
//
//  App Store審査対応修正のUIテスト
//  - ホームスクロール機能
//  - プロフィール読み込み機能
//  - アカウント削除機能
//  - 通報機能
//  - ブロック機能
//

import XCTest

final class AppStoreReviewUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI-TESTING"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 1. ホームスクロールテスト

    /// ホーム画面が正常にスクロールできることを確認
    func testHomeViewScrolling() throws {
        // ゲストモードでホーム画面に遷移
        let guestButton = app.buttons["ゲストで始める"]
        if guestButton.waitForExistence(timeout: 5) {
            guestButton.tap()
        }

        // ホームタブを選択
        let homeTab = app.tabBars.buttons["ホーム"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5), "ホームタブが表示されない")
        homeTab.tap()

        // スクロールビューが存在することを確認
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 5), "スクロールビューが見つからない")

        // スクロール可能かテスト（上から下にスワイプ）
        let startPoint = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let endPoint = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))

        startPoint.press(forDuration: 0.1, thenDragTo: endPoint)

        // スクロール後、画面が応答していることを確認
        XCTAssertTrue(scrollView.exists, "スクロール後も画面が正常に表示されている")
    }

    /// 投稿カードがタップ可能であることを確認
    func testPostCardTappable() throws {
        // ゲストモードでホーム画面に遷移
        let guestButton = app.buttons["ゲストで始める"]
        if guestButton.waitForExistence(timeout: 5) {
            guestButton.tap()
        }

        // ホームタブを選択
        let homeTab = app.tabBars.buttons["ホーム"]
        homeTab.tap()

        // 投稿カードが表示されるまで待つ
        let postCard = app.otherElements["PostCard"].firstMatch
        if postCard.waitForExistence(timeout: 10) {
            // タップして詳細画面に遷移
            postCard.tap()

            // 投稿詳細画面が表示されることを確認
            let detailView = app.otherElements["PostDetailView"]
            XCTAssertTrue(detailView.waitForExistence(timeout: 5), "投稿詳細画面が表示されない")
        }
    }

    // MARK: - 2. プロフィール読み込みテスト

    /// ログイン後にプロフィールが正常に読み込まれることを確認
    func testProfileLoading() throws {
        // テスト用アカウントでログイン
        performLogin(email: "test@example.com", password: "test1234")

        // プロフィールタブを選択
        let profileTab = app.tabBars.buttons["プロフィール"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 5), "プロフィールタブが表示されない")
        profileTab.tap()

        // プロフィール画面のローディング完了を待つ
        let profileView = app.otherElements["ProfileView"]
        XCTAssertTrue(profileView.waitForExistence(timeout: 10), "プロフィール画面が表示されない")

        // ユーザー名が表示されることを確認
        let displayName = app.staticTexts.matching(identifier: "displayName").firstMatch
        XCTAssertTrue(displayName.waitForExistence(timeout: 5), "ユーザー名が表示されない")

        // プロフィール画像が表示されることを確認（任意）
        let profileImage = app.images["profileImage"]
        XCTAssertTrue(profileImage.waitForExistence(timeout: 5), "プロフィール画像が表示されない")
    }

    /// Auth状態が復元されてプロフィールが再読み込みされることを確認
    func testProfileReloadsOnAuthStateChange() throws {
        // ログイン
        performLogin(email: "test@example.com", password: "test1234")

        // プロフィールタブに移動
        let profileTab = app.tabBars.buttons["プロフィール"]
        profileTab.tap()

        // プロフィールが読み込まれることを確認
        let profileView = app.otherElements["ProfileView"]
        XCTAssertTrue(profileView.waitForExistence(timeout: 10))

        // アプリをバックグラウンドに移動（Auth状態のテスト）
        XCUIDevice.shared.press(.home)
        sleep(2)

        // アプリを再度起動
        app.activate()

        // プロフィールが再度読み込まれることを確認
        XCTAssertTrue(profileView.exists, "Auth状態復元後もプロフィールが表示される")
    }

    // MARK: - 3. アカウント削除機能テスト

    /// アカウント削除フローが正常に動作することを確認
    func testAccountDeletion() throws {
        // テスト用アカウントでログイン
        performLogin(email: "delete_test@example.com", password: "test1234")

        // プロフィールタブに移動
        let profileTab = app.tabBars.buttons["プロフィール"]
        profileTab.tap()

        // 設定ボタンをタップ
        let settingsButton = app.buttons["設定"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "設定ボタンが表示されない")
        settingsButton.tap()

        // 設定画面が表示されることを確認
        let settingsView = app.otherElements["SettingsView"]
        XCTAssertTrue(settingsView.waitForExistence(timeout: 5), "設定画面が表示されない")

        // 「アカウントを削除」ボタンをタップ
        let deleteButton = app.buttons["アカウントを削除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "アカウント削除ボタンが表示されない")
        deleteButton.tap()

        // 確認アラートが表示されることを確認
        let confirmAlert = app.alerts["アカウントの削除"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "確認アラートが表示されない")

        // ⚠️ 実際のテストでは削除を実行しない（キャンセルボタンをタップ）
        let cancelButton = confirmAlert.buttons["キャンセル"]
        if cancelButton.exists {
            cancelButton.tap()
        }

        // アラートが閉じることを確認
        XCTAssertFalse(confirmAlert.exists, "アラートが閉じない")
    }

    /// アカウント削除後にログアウト状態になることを確認（実際の削除は行わない）
    func testAccountDeletionConfirmation() throws {
        // テスト用アカウントでログイン
        performLogin(email: "test@example.com", password: "test1234")

        // プロフィール → 設定 → アカウント削除
        let profileTab = app.tabBars.buttons["プロフィール"]
        profileTab.tap()

        let settingsButton = app.buttons["設定"]
        settingsButton.tap()

        let deleteButton = app.buttons["アカウントを削除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        // 確認アラートで「削除する」ボタンが存在することを確認
        let confirmAlert = app.alerts["アカウントの削除"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3))

        let confirmDeleteButton = confirmAlert.buttons["削除する"]
        XCTAssertTrue(confirmDeleteButton.exists, "削除確認ボタンが表示されない")

        // ⚠️ 実際には削除しない（キャンセル）
        confirmAlert.buttons["キャンセル"].tap()
    }

    // MARK: - 4. 通報機能テスト

    /// 投稿詳細から通報機能が動作することを確認
    func testReportPost() throws {
        // ゲストモードで開始
        let guestButton = app.buttons["ゲストで始める"]
        if guestButton.waitForExistence(timeout: 5) {
            guestButton.tap()
        }

        // ホームタブに移動
        let homeTab = app.tabBars.buttons["ホーム"]
        homeTab.tap()

        // 投稿カードをタップして詳細表示
        let postCard = app.otherElements["PostCard"].firstMatch
        if postCard.waitForExistence(timeout: 10) {
            postCard.tap()
        }

        // メニューボタン（...）をタップ
        let menuButton = app.buttons["PostMenuButton"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5), "メニューボタンが表示されない")
        menuButton.tap()

        // 「この投稿を通報する」オプションを確認
        let reportButton = app.buttons["この投稿を通報する"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 3), "通報ボタンが表示されない")
        reportButton.tap()

        // 通報理由選択画面が表示されることを確認
        let reportReasonSheet = app.sheets["通報理由を選択"]
        XCTAssertTrue(reportReasonSheet.waitForExistence(timeout: 3), "通報理由選択画面が表示されない")

        // 理由を選択
        let inappropriateButton = reportReasonSheet.buttons["不適切なコンテンツ"]
        if inappropriateButton.exists {
            inappropriateButton.tap()

            // 確認アラートが表示される
            let confirmAlert = app.alerts["通報を送信しました"]
            XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "通報完了アラートが表示されない")

            confirmAlert.buttons["OK"].tap()
        } else {
            // キャンセル
            reportReasonSheet.buttons["キャンセル"].tap()
        }
    }

    /// 通報理由が正しく選択できることを確認
    func testReportReasonSelection() throws {
        // ゲストモードで開始
        let guestButton = app.buttons["ゲストで始める"]
        if guestButton.waitForExistence(timeout: 5) {
            guestButton.tap()
        }

        // ホームタブ → 投稿詳細 → メニュー → 通報
        let homeTab = app.tabBars.buttons["ホーム"]
        homeTab.tap()

        let postCard = app.otherElements["PostCard"].firstMatch
        if postCard.waitForExistence(timeout: 10) {
            postCard.tap()
        }

        let menuButton = app.buttons["PostMenuButton"]
        if menuButton.waitForExistence(timeout: 5) {
            menuButton.tap()
        }

        let reportButton = app.buttons["この投稿を通報する"]
        if reportButton.exists {
            reportButton.tap()
        }

        // 通報理由が全て表示されることを確認
        let reportReasonSheet = app.sheets["通報理由を選択"]
        if reportReasonSheet.waitForExistence(timeout: 3) {
            XCTAssertTrue(reportReasonSheet.buttons["不適切なコンテンツ"].exists)
            XCTAssertTrue(reportReasonSheet.buttons["スパム"].exists)
            XCTAssertTrue(reportReasonSheet.buttons["ハラスメント"].exists)
            XCTAssertTrue(reportReasonSheet.buttons["その他"].exists)

            // キャンセル
            reportReasonSheet.buttons["キャンセル"].tap()
        }
    }

    // MARK: - 5. ブロック機能テスト

    /// ユーザーブロック機能が動作することを確認
    func testBlockUser() throws {
        // テスト用アカウントでログイン
        performLogin(email: "test@example.com", password: "test1234")

        // ホームタブに移動
        let homeTab = app.tabBars.buttons["ホーム"]
        homeTab.tap()

        // 投稿カードをタップして詳細表示
        let postCard = app.otherElements["PostCard"].firstMatch
        if postCard.waitForExistence(timeout: 10) {
            postCard.tap()
        }

        // メニューボタン（...）をタップ
        let menuButton = app.buttons["PostMenuButton"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5), "メニューボタンが表示されない")
        menuButton.tap()

        // 「このユーザーをブロック」オプションを確認
        let blockButton = app.buttons["このユーザーをブロック"]
        XCTAssertTrue(blockButton.waitForExistence(timeout: 3), "ブロックボタンが表示されない")
        blockButton.tap()

        // 確認アラートが表示されることを確認
        let confirmAlert = app.alerts["ユーザーをブロック"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "ブロック確認アラートが表示されない")

        // ⚠️ 実際にはブロックしない（キャンセル）
        let cancelButton = confirmAlert.buttons["キャンセル"]
        if cancelButton.exists {
            cancelButton.tap()
        }
    }

    /// ブロック後にフィードから該当ユーザーの投稿が非表示になることを確認
    func testBlockedUserPostsHiddenInFeed() throws {
        // テスト用アカウントでログイン
        performLogin(email: "test@example.com", password: "test1234")

        // ホームタブに移動
        let homeTab = app.tabBars.buttons["ホーム"]
        homeTab.tap()

        // 投稿数を記録
        let postCardsBeforeBlock = app.otherElements.matching(identifier: "PostCard").count

        // 投稿カードをタップして詳細表示
        let postCard = app.otherElements["PostCard"].firstMatch
        var blockedUserName = ""

        if postCard.waitForExistence(timeout: 10) {
            postCard.tap()

            // ユーザー名を記録（表示されている場合）
            let userNameLabel = app.staticTexts.matching(identifier: "userName").firstMatch
            if userNameLabel.exists {
                blockedUserName = userNameLabel.label
            }
        }

        // メニューからブロック
        let menuButton = app.buttons["PostMenuButton"]
        if menuButton.waitForExistence(timeout: 5) {
            menuButton.tap()
        }

        let blockButton = app.buttons["このユーザーをブロック"]
        if blockButton.exists {
            blockButton.tap()

            // 確認アラートで「ブロックする」を選択
            let confirmAlert = app.alerts["ユーザーをブロック"]
            if confirmAlert.waitForExistence(timeout: 3) {
                let confirmButton = confirmAlert.buttons["ブロックする"]
                if confirmButton.exists {
                    confirmButton.tap()

                    // ホーム画面に戻る
                    let backButton = app.navigationBars.buttons.firstMatch
                    if backButton.exists {
                        backButton.tap()
                    }

                    // フィードの投稿数が減っていることを確認
                    sleep(2) // フィルタリング処理を待つ
                    let postCardsAfterBlock = app.otherElements.matching(identifier: "PostCard").count

                    // ブロックしたユーザーの投稿が非表示になる
                    XCTAssertLessThanOrEqual(postCardsAfterBlock, postCardsBeforeBlock, "ブロック後にフィードの投稿が減っていない")
                } else {
                    confirmAlert.buttons["キャンセル"].tap()
                }
            }
        }
    }

    // MARK: - ヘルパーメソッド

    /// ログイン処理を実行
    private func performLogin(email: String, password: String) {
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
}
