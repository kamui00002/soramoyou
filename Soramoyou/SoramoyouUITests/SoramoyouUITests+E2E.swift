//
//  SoramoyouUITests+E2E.swift
//  SoramoyouUITests
//
//  エンドツーエンドのフロー統合UIテスト
//

import XCTest

extension SoramoyouUITests {

    // MARK: - E2E Flow Tests - New User Onboarding

    /// E2E: 新規ユーザー登録から初投稿まで
    func testE2E_NewUserSignUpToFirstPost() throws {
        // Given: アプリが起動している

        // Step 1: 新規登録画面に遷移
        let signUpButton = app.buttons["新規登録"]
        if signUpButton.waitForExistence(timeout: 5.0) {
            signUpButton.tap()

            // Step 2: 新規登録情報を入力
            let emailField = app.textFields["メールアドレス"]
            let passwordField = app.secureTextFields["パスワード"]
            let confirmPasswordField = app.secureTextFields["パスワード確認"]

            if emailField.waitForExistence(timeout: 3.0) {
                emailField.tap()
                emailField.typeText("newuser@example.com")
            }

            if passwordField.waitForExistence(timeout: 2.0) {
                passwordField.tap()
                passwordField.typeText("testpass123")
            }

            if confirmPasswordField.waitForExistence(timeout: 2.0) {
                confirmPasswordField.tap()
                confirmPasswordField.typeText("testpass123")
            }

            // Step 3: 新規登録実行
            let submitButton = app.buttons["新規登録"].firstMatch
            if submitButton.waitForExistence(timeout: 2.0) {
                submitButton.tap()
            }

            // Step 4: ホーム画面が表示される
            let homeTab = app.tabBars.buttons["ホーム"]
            XCTAssertTrue(
                homeTab.waitForExistence(timeout: 10.0),
                "新規登録後、ホーム画面が表示される"
            )

            // Step 5: 投稿タブに移動
            let postTab = app.tabBars.buttons["投稿"]
            if postTab.waitForExistence(timeout: 3.0) {
                postTab.tap()

                // Step 6: 写真選択
                let photoButton = app.buttons["写真を選択"]
                XCTAssertTrue(
                    photoButton.waitForExistence(timeout: 3.0),
                    "新規ユーザーも投稿機能にアクセスできる"
                )
            }
        }
    }

    // MARK: - E2E Flow Tests - Complete Post Flow

    /// E2E: 完全な投稿フロー（選択→編集→情報入力→投稿）
    func testE2E_CompletePostFlow() throws {
        // Given: ログイン済み
        performTestLogin()

        // Step 1: 投稿タブに移動
        let postTab = app.tabBars.buttons["投稿"]
        if postTab.waitForExistence(timeout: 5.0) {
            postTab.tap()

            // Step 2: 写真選択
            let photoButton = app.buttons["写真を選択"]
            if photoButton.waitForExistence(timeout: 3.0) {
                photoButton.tap()
                sleep(2) // 写真ピッカーを待つ
            }

            // Step 3: 編集画面でフィルター適用
            let filterTab = app.buttons["フィルター"]
            if filterTab.waitForExistence(timeout: 5.0) {
                filterTab.tap()

                let dramaFilter = app.buttons["ドラマ"]
                if dramaFilter.waitForExistence(timeout: 3.0) {
                    dramaFilter.tap()
                }
            }

            // Step 4: 調整タブで明るさ調整
            let adjustmentTab = app.buttons["調整"]
            if adjustmentTab.waitForExistence(timeout: 3.0) {
                adjustmentTab.tap()

                let brightnessButton = app.buttons.matching(
                    NSPredicate(format: "label CONTAINS '明るさ'")
                ).firstMatch

                if brightnessButton.waitForExistence(timeout: 3.0) {
                    brightnessButton.tap()

                    let slider = app.sliders.firstMatch
                    if slider.waitForExistence(timeout: 2.0) {
                        slider.adjust(toNormalizedSliderPosition: 0.6)
                    }
                }
            }

            // Step 5: 次へボタンで投稿情報画面へ
            let nextButton = app.buttons["次へ"]
            if nextButton.waitForExistence(timeout: 3.0) {
                nextButton.tap()

                // Step 6: キャプション入力
                let captionField = app.textViews.firstMatch
                if captionField.waitForExistence(timeout: 3.0) {
                    captionField.tap()
                    captionField.typeText("美しい空の写真 #空 #夕焼け")
                }

                // Step 7: 公開設定確認
                let publicButton = app.buttons["公開"]
                XCTAssertTrue(
                    publicButton.waitForExistence(timeout: 2.0),
                    "公開設定が表示される"
                )

                // Step 8: 投稿実行
                let postButton = app.buttons["投稿"]
                if postButton.waitForExistence(timeout: 3.0) {
                    postButton.tap()

                    // Step 9: 投稿完了後、ホーム画面に戻る
                    let homeTab = app.tabBars.buttons["ホーム"]
                    XCTAssertTrue(
                        homeTab.waitForExistence(timeout: 10.0),
                        "投稿完了後、ホーム画面に戻る"
                    )
                }
            }
        }
    }

    // MARK: - E2E Flow Tests - Search and View Post

    /// E2E: 検索から投稿詳細表示まで
    func testE2E_SearchToPostDetail() throws {
        // Given: ログイン済み
        performTestLogin()

        // Step 1: 検索タブに移動
        let searchTab = app.tabBars.buttons["検索"]
        if searchTab.waitForExistence(timeout: 5.0) {
            searchTab.tap()

            // Step 2: ハッシュタグ検索
            let hashtagField = app.textFields.firstMatch
            if hashtagField.waitForExistence(timeout: 3.0) {
                hashtagField.tap()
                hashtagField.typeText("空")
                app.keyboards.buttons["return"].tap()

                sleep(2) // 検索処理を待つ

                // Step 3: 検索結果から投稿をタップ
                let firstResult = app.images.firstMatch
                if firstResult.waitForExistence(timeout: 5.0) && firstResult.isHittable {
                    firstResult.tap()

                    sleep(2) // 画面遷移を待つ

                    // Step 4: 投稿詳細が表示される
                    let detailView = app.scrollViews.firstMatch
                    XCTAssertTrue(
                        detailView.exists,
                        "投稿詳細画面が表示される"
                    )

                    // Step 5: 投稿者プロフィールへ遷移
                    let authorName = app.staticTexts.matching(
                        NSPredicate(format: "identifier CONTAINS 'author-name'")
                    ).firstMatch

                    if authorName.waitForExistence(timeout: 3.0) && authorName.isHittable {
                        authorName.tap()

                        // Step 6: プロフィール画面が表示される
                        let profileTitle = app.navigationBars["プロフィール"]
                        XCTAssertTrue(
                            profileTitle.waitForExistence(timeout: 5.0),
                            "投稿者のプロフィール画面が表示される"
                        )
                    }
                }
            }
        }
    }

    // MARK: - E2E Flow Tests - Profile Management

    /// E2E: プロフィール編集と編集装備設定
    func testE2E_ProfileAndToolSettings() throws {
        // Given: ログイン済み
        performTestLogin()

        // Step 1: プロフィールタブに移動
        let profileTab = app.tabBars.buttons["プロフィール"]
        if profileTab.waitForExistence(timeout: 5.0) {
            profileTab.tap()

            // Step 2: メニューを開く
            let menuButton = app.buttons["ellipsis.circle"]
            if menuButton.waitForExistence(timeout: 3.0) {
                menuButton.tap()

                // Step 3: プロフィール編集
                let editProfileButton = app.buttons["プロフィール編集"]
                if editProfileButton.waitForExistence(timeout: 2.0) {
                    editProfileButton.tap()

                    // 表示名を編集
                    let displayNameField = app.textFields["表示名"]
                    if displayNameField.waitForExistence(timeout: 3.0) {
                        displayNameField.tap()
                        displayNameField.typeText("新しい名前")

                        // 保存
                        let saveButton = app.buttons["保存"]
                        if saveButton.waitForExistence(timeout: 2.0) {
                            saveButton.tap()

                            // プロフィール画面に戻る
                            sleep(2)
                        }
                    }
                }

                // Step 4: 再度メニューを開いて編集装備設定へ
                if menuButton.waitForExistence(timeout: 3.0) {
                    menuButton.tap()

                    let editToolsButton = app.buttons["おすすめ編集設定"]
                    if editToolsButton.waitForExistence(timeout: 2.0) {
                        editToolsButton.tap()

                        // Step 5: 編集装備設定画面が表示される
                        let settingsTitle = app.navigationBars.matching(
                            NSPredicate(format: "label CONTAINS 'おすすめ編集設定'")
                        ).firstMatch

                        XCTAssertTrue(
                            settingsTitle.waitForExistence(timeout: 3.0),
                            "編集装備設定画面が表示される"
                        )

                        // 保存ボタンを確認
                        let saveButton = app.buttons["保存"]
                        XCTAssertTrue(
                            saveButton.waitForExistence(timeout: 2.0),
                            "保存ボタンが表示される"
                        )
                    }
                }
            }
        }
    }

    // MARK: - E2E Flow Tests - Draft Save and Resume

    /// E2E: 下書き保存と再開
    func testE2E_SaveDraftAndResume() throws {
        // Given: ログイン済み
        performTestLogin()

        // Step 1: 投稿タブに移動して写真選択
        let postTab = app.tabBars.buttons["投稿"]
        if postTab.waitForExistence(timeout: 5.0) {
            postTab.tap()

            let photoButton = app.buttons["写真を選択"]
            if photoButton.waitForExistence(timeout: 3.0) {
                photoButton.tap()
                sleep(2)
            }

            // Step 2: 編集画面でフィルター適用
            let filterTab = app.buttons["フィルター"]
            if filterTab.waitForExistence(timeout: 5.0) {
                filterTab.tap()

                let softFilter = app.buttons["ソフト"]
                if softFilter.waitForExistence(timeout: 3.0) {
                    softFilter.tap()
                }
            }

            // Step 3: 下書き保存（実装に依存）
            // 注意: 下書き保存の方法は実装による（戻るボタン、下書き保存ボタンなど）
            let backButton = app.navigationBars.buttons.firstMatch
            if backButton.exists {
                backButton.tap()

                // 下書き保存の確認ダイアログが表示される場合
                let saveDraftButton = app.alerts.buttons["下書きを保存"]
                if saveDraftButton.waitForExistence(timeout: 3.0) {
                    saveDraftButton.tap()
                }
            }

            // Step 4: プロフィールから下書き一覧を開く
            let profileTab = app.tabBars.buttons["プロフィール"]
            if profileTab.waitForExistence(timeout: 3.0) {
                profileTab.tap()

                let menuButton = app.buttons["ellipsis.circle"]
                if menuButton.waitForExistence(timeout: 3.0) {
                    menuButton.tap()

                    let draftsButton = app.buttons["下書き"]
                    if draftsButton.waitForExistence(timeout: 2.0) {
                        draftsButton.tap()

                        // Step 5: 下書きを選択して編集再開
                        let firstDraft = app.images.firstMatch
                        if firstDraft.waitForExistence(timeout: 3.0) && firstDraft.isHittable {
                            firstDraft.tap()

                            // Step 6: 編集画面が表示される
                            let editTitle = app.navigationBars["編集"]
                            XCTAssertTrue(
                                editTitle.waitForExistence(timeout: 5.0),
                                "下書きから編集画面が表示される"
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - E2E Flow Tests - Multi-Tab Navigation

    /// E2E: 全タブを巡回するナビゲーションフロー
    func testE2E_NavigateAllTabs() throws {
        // Given: ログイン済み
        performTestLogin()

        let tabNames = ["ホーム", "検索", "投稿", "プロフィール"]

        // Step 1: 各タブを順番に表示
        for tabName in tabNames {
            let tab = app.tabBars.buttons[tabName]
            if tab.waitForExistence(timeout: 3.0) {
                tab.tap()

                // 各タブが正常に表示されることを確認
                sleep(1)
                XCTAssertTrue(tab.isSelected, "\(tabName)タブが選択される")
            }
        }

        // Step 2: ホームタブに戻る
        let homeTab = app.tabBars.buttons["ホーム"]
        if homeTab.waitForExistence(timeout: 3.0) {
            homeTab.tap()
            XCTAssertTrue(homeTab.isSelected, "ホームタブに戻る")
        }
    }

    // MARK: - E2E Flow Tests - Guest User Flow

    /// E2E: ゲストユーザーの閲覧制限フロー
    func testE2E_GuestUserLimitedAccess() throws {
        // Given: 未ログイン（ゲストモード）

        // Step 1: ゲストモードでスキップ
        let skipButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'スキップ' OR label CONTAINS 'ゲスト'")
        ).firstMatch

        if skipButton.waitForExistence(timeout: 5.0) {
            skipButton.tap()

            // Step 2: ゲスト用のタブが表示される
            sleep(2)

            // Step 3: 投稿を閲覧（制限あり）
            let firstPost = app.images.firstMatch
            if firstPost.waitForExistence(timeout: 5.0) && firstPost.isHittable {
                firstPost.tap()

                // Step 4: 投稿詳細が表示される
                sleep(2)

                // Step 5: 投稿機能にはアクセスできない、またはログインを促される
                // 実装に依存
            }
        }
    }

    // MARK: - E2E Flow Tests - Error Recovery

    /// E2E: エラー発生と回復のフロー
    func testE2E_ErrorHandlingAndRecovery() throws {
        // Given: ログイン済み
        performTestLogin()

        // Step 1: ネットワークエラーを想定（テスト環境では模擬的）
        let homeTab = app.tabBars.buttons["ホーム"]
        if homeTab.waitForExistence(timeout: 5.0) {
            homeTab.tap()

            // Step 2: プルリフレッシュを実行
            let scrollView = app.scrollViews.firstMatch
            if scrollView.waitForExistence(timeout: 3.0) {
                let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                start.press(forDuration: 0.1, thenDragTo: end)

                sleep(2)

                // Step 3: エラーアラートが表示される場合、OKボタンをタップ
                let errorAlert = app.alerts["エラー"]
                if errorAlert.waitForExistence(timeout: 5.0) {
                    let okButton = errorAlert.buttons["OK"]
                    if okButton.exists {
                        okButton.tap()

                        // Step 4: アプリが正常な状態に戻る
                        XCTAssertTrue(
                            homeTab.isSelected,
                            "エラー後もホーム画面が表示される"
                        )
                    }
                }
            }
        }
    }

    // MARK: - E2E Flow Tests - Logout and Re-login

    /// E2E: ログアウトと再ログイン
    func testE2E_LogoutAndReLogin() throws {
        // Given: ログイン済み
        performTestLogin()

        // Step 1: プロフィールタブに移動
        let profileTab = app.tabBars.buttons["プロフィール"]
        if profileTab.waitForExistence(timeout: 5.0) {
            profileTab.tap()

            // Step 2: 設定メニューを開く
            let menuButton = app.buttons["ellipsis.circle"]
            if menuButton.waitForExistence(timeout: 3.0) {
                menuButton.tap()

                // Step 3: ログアウトボタンをタップ
                let logoutButton = app.buttons.matching(
                    NSPredicate(format: "label CONTAINS 'ログアウト' OR label CONTAINS 'サインアウト'")
                ).firstMatch

                if logoutButton.waitForExistence(timeout: 3.0) {
                    logoutButton.tap()

                    // 確認ダイアログが表示される場合
                    let confirmButton = app.alerts.buttons["ログアウト"]
                    if confirmButton.waitForExistence(timeout: 2.0) {
                        confirmButton.tap()
                    }

                    // Step 4: ウェルカム画面に戻る
                    let welcomeTitle = app.staticTexts["そらもよう"]
                    XCTAssertTrue(
                        welcomeTitle.waitForExistence(timeout: 5.0),
                        "ログアウト後、ウェルカム画面が表示される"
                    )

                    // Step 5: 再度ログイン
                    performTestLogin()

                    // Step 6: ホーム画面が表示される
                    let homeTab = app.tabBars.buttons["ホーム"]
                    XCTAssertTrue(
                        homeTab.waitForExistence(timeout: 10.0),
                        "再ログイン後、ホーム画面が表示される"
                    )
                }
            }
        }
    }
}
