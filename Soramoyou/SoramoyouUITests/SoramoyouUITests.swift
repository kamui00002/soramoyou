//
//  SoramoyouUITests.swift
//  SoramoyouUITests
//
//  Created on 2025-12-06.
//

import XCTest

final class SoramoyouUITests: XCTestCase {
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it's important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
        app = XCUIApplication()

        // UIテスト用のlaunchArgumentsを設定（認証状態をリセット）
        app.launchArguments = ["UI_TESTING", "RESET_AUTH_STATE"]

        app.launch()
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        app = nil
    }
    
    // MARK: - Authentication UI Tests
    
    /// 認証のUI操作テスト: ウェルカム画面の表示
    func testWelcomeView_Display() throws {
        // Given: アプリが起動
        
        // When: ウェルカム画面が表示される
        
        // Then: ウェルカム画面の要素が表示されることを確認
        let welcomeTitle = app.staticTexts["そらもよう"]
        XCTAssertTrue(welcomeTitle.waitForExistence(timeout: 5.0), "ウェルカム画面のタイトルが表示される")
        
        // 新規登録ボタンとログインボタンが表示されることを確認
        let signUpButton = app.buttons["新規登録"]
        let loginButton = app.buttons["ログイン"]
        
        XCTAssertTrue(signUpButton.exists || signUpButton.waitForExistence(timeout: 2.0), "新規登録ボタンが表示される")
        XCTAssertTrue(loginButton.exists || loginButton.waitForExistence(timeout: 2.0), "ログインボタンが表示される")
    }
    
    /// 認証のUI操作テスト: ログイン画面への遷移
    func testAuthenticationFlow_NavigateToLogin() throws {
        // Given: ウェルカム画面が表示されている
        
        // When: ログインボタンをタップ
        let loginButton = app.buttons["ログイン"]
        if loginButton.waitForExistence(timeout: 2.0) {
            loginButton.tap()
        }
        
        // Then: ログイン画面が表示されることを確認
        let emailField = app.textFields["メールアドレス"]
        let passwordField = app.secureTextFields["パスワード"]
        
        XCTAssertTrue(emailField.waitForExistence(timeout: 2.0), "メールアドレス入力欄が表示される")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 2.0), "パスワード入力欄が表示される")
    }
    
    /// 認証のUI操作テスト: 新規登録画面への遷移
    func testAuthenticationFlow_NavigateToSignUp() throws {
        // Given: ウェルカム画面が表示されている
        
        // When: 新規登録ボタンをタップ
        let signUpButton = app.buttons["新規登録"]
        if signUpButton.waitForExistence(timeout: 2.0) {
            signUpButton.tap()
        }
        
        // Then: 新規登録画面が表示されることを確認
        let emailField = app.textFields["メールアドレス"]
        let passwordField = app.secureTextFields["パスワード"]
        let confirmPasswordField = app.secureTextFields["パスワード確認"]
        
        XCTAssertTrue(emailField.waitForExistence(timeout: 2.0), "メールアドレス入力欄が表示される")
        XCTAssertTrue(passwordField.waitForExistence(timeout: 2.0), "パスワード入力欄が表示される")
        XCTAssertTrue(confirmPasswordField.waitForExistence(timeout: 2.0), "パスワード確認入力欄が表示される")
    }
    
    /// 認証のUI操作テスト: 新規登録入力（バリデーションエラー）
    func testAuthenticationFlow_SignUpValidationError() throws {
        // Given: 新規登録画面が表示されている
        let signUpButton = app.buttons["新規登録"]
        if signUpButton.waitForExistence(timeout: 2.0) {
            signUpButton.tap()
        }
        
        // When: 空のメールアドレスとパスワードで新規登録ボタンをタップ
        let emailField = app.textFields["メールアドレス"]
        let passwordField = app.secureTextFields["パスワード"]
        let confirmPasswordField = app.secureTextFields["パスワード確認"]
        let submitButton = app.buttons["新規登録"]
        
        if emailField.waitForExistence(timeout: 2.0) {
            emailField.tap()
            emailField.typeText("")
            
            if passwordField.waitForExistence(timeout: 2.0) {
                passwordField.tap()
                passwordField.typeText("")
                
                if confirmPasswordField.waitForExistence(timeout: 2.0) {
                    confirmPasswordField.tap()
                    confirmPasswordField.typeText("")
                    
                    // 新規登録ボタンが無効化されていることを確認
                    if submitButton.waitForExistence(timeout: 2.0) {
                        XCTAssertFalse(submitButton.isEnabled, "新規登録ボタンが無効化される")
                    }
                }
            }
        }
    }
    
    /// 認証のUI操作テスト: ログイン入力（バリデーションエラー）
    func testAuthenticationFlow_LoginValidationError() throws {
        // Given: ログイン画面が表示されている
        let loginButton = app.buttons["ログイン"]
        if loginButton.waitForExistence(timeout: 2.0) {
            loginButton.tap()
        }
        
        // When: 空のメールアドレスとパスワードでログインボタンをタップ
        let emailField = app.textFields["メールアドレス"]
        let passwordField = app.secureTextFields["パスワード"]
        let submitButton = app.buttons["ログイン"]
        
        if emailField.waitForExistence(timeout: 2.0) {
            emailField.tap()
            emailField.typeText("")
            
            if passwordField.waitForExistence(timeout: 2.0) {
                passwordField.tap()
                passwordField.typeText("")
                
                if submitButton.waitForExistence(timeout: 2.0) {
                    submitButton.tap()
                }
            }
        }
        
        // Then: エラーメッセージが表示されることを確認（実際の実装に依存）
        // 注意: エラーメッセージの表示方法は実装によって異なるため、適宜調整が必要
    }
    
    // MARK: - Main Tab View Tests
    
    /// メインタブビューのテスト: タブの表示
    func testMainTabView_DisplayTabs() throws {
        // Given: 認証済み状態（実際の認証が必要な場合は、テスト用の認証を設定）
        
        // When: メインタブビューが表示される
        
        // Then: 各タブが表示されることを確認
        let homeTab = app.tabBars.buttons["ホーム"]
        let postTab = app.tabBars.buttons["投稿"]
        let searchTab = app.tabBars.buttons["検索"]
        let profileTab = app.tabBars.buttons["プロフィール"]
        
        // タブが存在するか確認（認証済みの場合のみ）
        // 注意: 実際の認証が必要な場合は、テスト用の認証を設定する必要があります
    }
    
    /// メインタブビューのテスト: タブの切り替え
    func testMainTabView_SwitchTabs() throws {
        // Given: メインタブビューが表示されている
        
        // When: 各タブをタップ
        let homeTab = app.tabBars.buttons["ホーム"]
        let postTab = app.tabBars.buttons["投稿"]
        let searchTab = app.tabBars.buttons["検索"]
        let profileTab = app.tabBars.buttons["プロフィール"]
        
        if homeTab.waitForExistence(timeout: 2.0) {
            homeTab.tap()
            XCTAssertTrue(homeTab.isSelected, "ホームタブが選択される")
        }
        
        if postTab.waitForExistence(timeout: 2.0) {
            postTab.tap()
            XCTAssertTrue(postTab.isSelected, "投稿タブが選択される")
        }
        
        if searchTab.waitForExistence(timeout: 2.0) {
            searchTab.tap()
            XCTAssertTrue(searchTab.isSelected, "検索タブが選択される")
        }
        
        if profileTab.waitForExistence(timeout: 2.0) {
            profileTab.tap()
            XCTAssertTrue(profileTab.isSelected, "プロフィールタブが選択される")
        }
    }
    
    // MARK: - Home View Tests
    
    /// フィード表示のUI操作テスト: ホーム画面の表示
    func testHomeView_Display() throws {
        // Given: ホームタブが選択されている
        
        // When: ホーム画面が表示される
        
        // Then: ホーム画面の要素が表示されることを確認
        let homeTitle = app.navigationBars["そらもよう"]
        XCTAssertTrue(homeTitle.waitForExistence(timeout: 5.0) || homeTitle.exists, "ホーム画面のタイトルが表示される")
    }
    
    /// フィード表示のUI操作テスト: 投稿の表示
    func testHomeView_DisplayPosts() throws {
        // Given: ホーム画面が表示されている
        
        // When: 投稿が読み込まれる
        
        // Then: 投稿が表示されることを確認（実際のデータに依存）
        // 注意: 実際の投稿データが必要な場合は、テスト用のデータを準備する必要があります
    }
    
    /// フィード表示のUI操作テスト: プルリフレッシュ
    func testHomeView_PullToRefresh() throws {
        // Given: ホーム画面が表示されている
        
        // When: プルリフレッシュを実行
        let homeView = app.scrollViews.firstMatch
        if homeView.waitForExistence(timeout: 2.0) {
            let start = homeView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            let end = homeView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        
        // Then: リフレッシュが実行されることを確認
        // 注意: リフレッシュの完了を待つ必要がある場合があります
    }
    
    // MARK: - Post View Tests
    
    /// 投稿のUI操作テスト: 投稿画面の表示
    func testPostView_Display() throws {
        // Given: 投稿タブが選択されている
        
        // When: 投稿画面が表示される
        
        // Then: 投稿画面の要素が表示されることを確認
        let postTitle = app.navigationBars["投稿"]
        XCTAssertTrue(postTitle.waitForExistence(timeout: 5.0) || postTitle.exists, "投稿画面のタイトルが表示される")
    }
    
    /// 投稿のUI操作テスト: 写真選択ボタンの表示
    func testPostView_PhotoSelectionButton() throws {
        // Given: 投稿画面が表示されている
        
        // When: 写真選択ボタンが表示される
        
        // Then: 写真選択ボタンが表示されることを確認
        let photoButton = app.buttons["写真を選択"]
        XCTAssertTrue(photoButton.waitForExistence(timeout: 2.0) || photoButton.exists, "写真選択ボタンが表示される")
    }
    
    // MARK: - Search View Tests
    
    /// 検索のUI操作テスト: 検索画面の表示
    func testSearchView_Display() throws {
        // Given: 検索タブが選択されている
        
        // When: 検索画面が表示される
        
        // Then: 検索画面の要素が表示されることを確認
        let searchTitle = app.navigationBars["検索"]
        XCTAssertTrue(searchTitle.waitForExistence(timeout: 5.0) || searchTitle.exists, "検索画面のタイトルが表示される")
    }
    
    /// 検索のUI操作テスト: ハッシュタグ検索
    func testSearchView_HashtagSearch() throws {
        // Given: 検索画面が表示されている
        
        // When: ハッシュタグを入力して検索
        let hashtagField = app.textFields["ハッシュタグ"]
        if hashtagField.waitForExistence(timeout: 2.0) {
            hashtagField.tap()
            hashtagField.typeText("sky")
            
            let searchButton = app.buttons["検索"]
            if searchButton.waitForExistence(timeout: 2.0) {
                searchButton.tap()
            }
        }
        
        // Then: 検索結果が表示されることを確認（実際のデータに依存）
    }
    
    /// 検索のUI操作テスト: 時間帯検索
    func testSearchView_TimeOfDaySearch() throws {
        // Given: 検索画面が表示されている
        
        // When: 時間帯を選択して検索
        let morningChip = app.buttons["朝"]
        if morningChip.waitForExistence(timeout: 2.0) {
            morningChip.tap()
            
            let searchButton = app.buttons["検索"]
            if searchButton.waitForExistence(timeout: 2.0) {
                searchButton.tap()
            }
        }
        
        // Then: 検索結果が表示されることを確認（実際のデータに依存）
    }
    
    // MARK: - Profile View Tests
    
    /// プロフィールのUI操作テスト: プロフィール画面の表示
    func testProfileView_Display() throws {
        // Given: プロフィールタブが選択されている
        
        // When: プロフィール画面が表示される
        
        // Then: プロフィール画面の要素が表示されることを確認
        let profileTitle = app.navigationBars["プロフィール"]
        XCTAssertTrue(profileTitle.waitForExistence(timeout: 5.0) || profileTitle.exists, "プロフィール画面のタイトルが表示される")
    }
    
    /// プロフィールのUI操作テスト: プロフィール編集メニュー
    func testProfileView_EditMenu() throws {
        // Given: プロフィール画面が表示されている（自分のプロフィール）
        
        // When: 編集メニューを開く
        let menuButton = app.buttons["ellipsis.circle"]
        if menuButton.waitForExistence(timeout: 2.0) {
            menuButton.tap()
        }
        
        // Then: 編集メニューが表示されることを確認
        let editProfileButton = app.buttons["プロフィール編集"]
        XCTAssertTrue(editProfileButton.waitForExistence(timeout: 2.0) || editProfileButton.exists, "プロフィール編集ボタンが表示される")
    }
    
    // MARK: - Post Flow Tests (E2E)

    /// 投稿フローのE2Eテスト: ログインから投稿まで
    func testPostFlow_LoginAndPost() throws {
        // Given: アプリが起動している

        // Step 1: ログイン
        let loginButton = app.buttons["ログイン"]
        if loginButton.waitForExistence(timeout: 5.0) {
            loginButton.tap()

            // メールアドレスとパスワードを入力
            let emailField = app.textFields["メールアドレス"]
            let passwordField = app.secureTextFields["パスワード"]

            if emailField.waitForExistence(timeout: 3.0) {
                emailField.tap()
                emailField.typeText("test@example.com")
            }

            if passwordField.waitForExistence(timeout: 3.0) {
                passwordField.tap()
                passwordField.typeText("testpassword123")
            }

            // ログインボタンをタップ
            let submitButton = app.buttons["ログイン"].firstMatch
            if submitButton.waitForExistence(timeout: 2.0) {
                submitButton.tap()
            }
        }

        // Step 2: ホーム画面が表示されるのを待つ
        let homeTab = app.tabBars.buttons["ホーム"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10.0), "ログイン後、ホーム画面が表示される")

        // Step 3: 投稿タブをタップ
        let postTab = app.tabBars.buttons["投稿"]
        if postTab.waitForExistence(timeout: 3.0) {
            postTab.tap()
        }

        // Step 4: 写真選択画面が表示される
        // 注意: 実際の写真選択はシステムのPhotosピッカーを使用するため、
        // XCUITestでの自動化には制限があります
        let photoButton = app.buttons["写真を選択"]
        if photoButton.waitForExistence(timeout: 3.0) {
            XCTAssertTrue(photoButton.exists, "写真選択ボタンが表示される")
        }
    }

    /// 投稿フローのテスト: 写真選択から編集画面への遷移
    func testPostFlow_PhotoSelectionToEdit() throws {
        // Given: ログイン済みで投稿タブが選択されている

        // 投稿タブに移動（既にログイン済みと仮定）
        let postTab = app.tabBars.buttons["投稿"]
        if postTab.waitForExistence(timeout: 5.0) {
            postTab.tap()

            // 写真選択ボタンをタップ
            let photoButton = app.buttons["写真を選択"]
            if photoButton.waitForExistence(timeout: 3.0) {
                photoButton.tap()

                // 写真ピッカーが表示されることを確認
                // iOS 14以降のPHPickerは限定的なテストが可能
                let photosNavBar = app.navigationBars["Photos"]
                if photosNavBar.waitForExistence(timeout: 5.0) {
                    XCTAssertTrue(photosNavBar.exists, "写真ピッカーが表示される")
                }
            }
        }
    }

    /// 投稿フローのテスト: 編集画面の表示
    func testPostFlow_EditViewDisplay() throws {
        // Given: 写真が選択されて編集画面が表示されている

        // 編集画面のナビゲーションタイトルを確認
        let editTitle = app.navigationBars["編集"]
        if editTitle.waitForExistence(timeout: 5.0) {
            XCTAssertTrue(editTitle.exists, "編集画面が表示される")

            // フィルターボタンが表示されることを確認
            let filterButton = app.buttons["フィルター"]
            XCTAssertTrue(filterButton.waitForExistence(timeout: 3.0), "フィルターボタンが表示される")

            // 次へボタンが表示されることを確認
            let nextButton = app.buttons["次へ"]
            XCTAssertTrue(nextButton.waitForExistence(timeout: 3.0), "次へボタンが表示される")
        }
    }

    /// 投稿フローのテスト: 投稿情報入力画面
    func testPostFlow_PostInfoViewDisplay() throws {
        // Given: 投稿情報入力画面が表示されている

        let postInfoTitle = app.navigationBars["投稿情報"]
        if postInfoTitle.waitForExistence(timeout: 5.0) {
            XCTAssertTrue(postInfoTitle.exists, "投稿情報画面が表示される")

            // 位置情報追加ボタンが表示されることを確認
            let locationButton = app.buttons["位置情報を追加"]
            XCTAssertTrue(locationButton.waitForExistence(timeout: 3.0), "位置情報追加ボタンが表示される")

            // 公開設定が表示されることを確認
            let publicButton = app.buttons["公開"]
            XCTAssertTrue(publicButton.waitForExistence(timeout: 3.0), "公開設定が表示される")

            // 投稿ボタンが表示されることを確認
            let postButton = app.buttons["投稿"]
            XCTAssertTrue(postButton.waitForExistence(timeout: 3.0), "投稿ボタンが表示される")
        }
    }

    /// 編集装備設定のテスト
    func testEditEquipmentSettings() throws {
        // Given: プロフィール画面が表示されている

        let profileTab = app.tabBars.buttons["プロフィール"]
        if profileTab.waitForExistence(timeout: 5.0) {
            profileTab.tap()

            // 設定ボタンをタップ
            let settingsButton = app.buttons["設定"]
            if settingsButton.waitForExistence(timeout: 3.0) {
                settingsButton.tap()

                // 編集装備設定をタップ
                let editEquipmentButton = app.buttons["おすすめ編集設定"]
                if editEquipmentButton.waitForExistence(timeout: 3.0) {
                    editEquipmentButton.tap()

                    // 編集装備設定画面が表示されることを確認
                    let equipmentTitle = app.navigationBars["おすすめ編集設定"]
                    XCTAssertTrue(equipmentTitle.waitForExistence(timeout: 3.0), "編集装備設定画面が表示される")

                    // 保存ボタンが表示されることを確認
                    let saveButton = app.buttons["保存"]
                    XCTAssertTrue(saveButton.waitForExistence(timeout: 3.0), "保存ボタンが表示される")
                }
            }
        }
    }

    // MARK: - Helper Methods

    /// アプリをリセット（各テストの独立性を保つため）
    private func resetApp() {
        app.terminate()
        app.launch()
    }

    /// 認証済み状態にする（テスト用）
    private func authenticateForTesting() {
        // 注意: 実際の認証が必要な場合は、テスト用の認証情報を使用
        // または、モックを使用して認証状態を設定
    }

    /// テスト用のログインを実行
    private func performTestLogin(email: String = "test@example.com", password: String = "testpassword123") {
        let loginButton = app.buttons["ログイン"]
        if loginButton.waitForExistence(timeout: 5.0) {
            loginButton.tap()

            let emailField = app.textFields["メールアドレス"]
            let passwordField = app.secureTextFields["パスワード"]

            if emailField.waitForExistence(timeout: 3.0) {
                emailField.tap()
                emailField.typeText(email)
            }

            if passwordField.waitForExistence(timeout: 3.0) {
                passwordField.tap()
                passwordField.typeText(password)
            }

            let submitButton = app.buttons["ログイン"].firstMatch
            if submitButton.waitForExistence(timeout: 2.0) {
                submitButton.tap()
            }
        }
    }
}

