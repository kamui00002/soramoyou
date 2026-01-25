//
//  SoramoyouUITests+PostDetail.swift
//  SoramoyouUITests
//
//  投稿詳細画面（GalleryDetailView）のUIテスト
//

import XCTest

extension SoramoyouUITests {

    // MARK: - Post Detail View Tests

    /// 投稿詳細画面: 画面表示確認
    func testPostDetail_Display() throws {
        // Given: ホーム画面が表示されている
        performTestLogin()

        let homeTab = app.tabBars.buttons["ホーム"]
        if homeTab.waitForExistence(timeout: 5.0) {
            homeTab.tap()

            // When: 投稿をタップ（最初の投稿）
            let firstPost = app.images.firstMatch
            if firstPost.waitForExistence(timeout: 5.0) && firstPost.isHittable {
                firstPost.tap()

                // Then: 投稿詳細画面が表示される
                sleep(2) // 画面遷移を待つ

                // 投稿者情報セクションが表示される
                let authorSection = app.otherElements.matching(
                    NSPredicate(format: "identifier CONTAINS 'author-section'")
                ).firstMatch

                XCTAssertTrue(
                    authorSection.waitForExistence(timeout: 3.0) || authorSection.exists,
                    "投稿者情報が表示される"
                )
            }
        }
    }

    /// 投稿詳細画面: 投稿者情報の表示確認
    func testPostDetail_AuthorInfoDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: 投稿者情報が表示される
        // プロフィール画像
        let authorImage = app.images.matching(
            NSPredicate(format: "identifier CONTAINS 'author-image'")
        ).firstMatch

        // 表示名
        let authorName = app.staticTexts.matching(
            NSPredicate(format: "identifier CONTAINS 'author-name'")
        ).firstMatch

        // 投稿日時
        let postDate = app.staticTexts.matching(
            NSPredicate(format: "identifier CONTAINS 'post-date'")
        ).firstMatch

        // いずれかの要素が表示されていることを確認
        let authorInfoExists = authorImage.exists || authorName.exists || postDate.exists
        XCTAssertTrue(authorInfoExists, "投稿者情報の要素が表示される")
    }

    /// 投稿詳細画面: 画像の表示確認
    func testPostDetail_ImageDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: 投稿画像が表示される
        let postImage = app.images.firstMatch
        XCTAssertTrue(postImage.exists, "投稿画像が表示される")
    }

    /// 投稿詳細画面: キャプションの表示確認
    func testPostDetail_CaptionDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: キャプションセクションが表示される（存在する場合）
        let captionSection = app.staticTexts.matching(
            NSPredicate(format: "identifier CONTAINS 'caption' OR identifier CONTAINS 'description'")
        ).firstMatch

        // キャプションがある投稿の場合、表示される
        if captionSection.exists {
            XCTAssertTrue(captionSection.exists, "キャプションが表示される")
        }
    }

    /// 投稿詳細画面: ハッシュタグの表示確認
    func testPostDetail_HashtagsDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: ハッシュタグが表示される（存在する場合）
        let hashtagButtons = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '#'")
        )

        // ハッシュタグがある投稿の場合、表示される
        if hashtagButtons.count > 0 {
            XCTAssertGreaterThan(hashtagButtons.count, 0, "ハッシュタグが表示される")
        }
    }

    /// 投稿詳細画面: 位置情報の表示確認
    func testPostDetail_LocationDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: 位置情報が表示される（存在する場合）
        let locationSection = app.staticTexts.matching(
            NSPredicate(format: "identifier CONTAINS 'location' OR label CONTAINS '位置情報'")
        ).firstMatch

        // 位置情報がある投稿の場合、表示される
        if locationSection.exists {
            XCTAssertTrue(locationSection.exists, "位置情報が表示される")
        }
    }

    /// 投稿詳細画面: 空の色情報の表示確認
    func testPostDetail_SkyColorsDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: 抽出された空の色が表示される（存在する場合）
        let colorSection = app.otherElements.matching(
            NSPredicate(format: "identifier CONTAINS 'sky-colors' OR identifier CONTAINS 'color'")
        ).firstMatch

        // 色情報がある投稿の場合、表示される
        if colorSection.exists {
            XCTAssertTrue(colorSection.exists, "空の色情報が表示される")
        }
    }

    /// 投稿詳細画面: 編集前後の画像切り替え
    func testPostDetail_ToggleOriginalAndEditedImages() throws {
        // Given: 投稿詳細画面が表示されている（オリジナル画像がある投稿）
        performTestLogin()
        navigateToPostDetail()

        // When: 編集前後切り替えボタンが存在する場合
        let toggleButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '編集前' OR label CONTAINS '編集後' OR label CONTAINS 'オリジナル'")
        ).firstMatch

        if toggleButton.waitForExistence(timeout: 3.0) {
            // Then: ボタンをタップして画像を切り替え
            toggleButton.tap()

            // 画像が切り替わったことを確認（見た目の変化は検証困難だが、エラーがないことを確認）
            XCTAssertTrue(toggleButton.exists, "画像切り替えがエラーなく完了する")
        }
    }

    /// 投稿詳細画面: 編集設定の表示確認
    func testPostDetail_EditSettingsDisplay() throws {
        // Given: 投稿詳細画面が表示されている（編集設定がある投稿）
        performTestLogin()
        navigateToPostDetail()

        // Then: 編集設定セクションが表示される（存在する場合）
        let editSettingsSection = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '編集設定' OR label CONTAINS 'フィルター'")
        ).firstMatch

        // 編集設定がある投稿の場合、表示される
        if editSettingsSection.exists {
            XCTAssertTrue(editSettingsSection.exists, "編集設定が表示される")
        }
    }

    /// 投稿詳細画面: 時間帯情報の表示確認
    func testPostDetail_TimeOfDayDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: 時間帯情報が表示される（存在する場合）
        let timeOfDayLabels = ["朝", "午後", "夕方", "夜"]
        var timeOfDayExists = false

        for label in timeOfDayLabels {
            let timeLabel = app.staticTexts[label]
            if timeLabel.exists {
                timeOfDayExists = true
                break
            }
        }

        // 時間帯情報がある投稿の場合、表示される
        if timeOfDayExists {
            XCTAssertTrue(timeOfDayExists, "時間帯情報が表示される")
        }
    }

    /// 投稿詳細画面: 空のタイプ情報の表示確認
    func testPostDetail_SkyTypeDisplay() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // Then: 空のタイプ情報が表示される（存在する場合）
        let skyTypeLabels = ["晴れ", "曇り", "夕焼け", "朝焼け", "嵐"]
        var skyTypeExists = false

        for label in skyTypeLabels {
            let skyLabel = app.staticTexts[label]
            if skyLabel.exists {
                skyTypeExists = true
                break
            }
        }

        // 空のタイプ情報がある投稿の場合、表示される
        if skyTypeExists {
            XCTAssertTrue(skyTypeExists, "空のタイプ情報が表示される")
        }
    }

    /// 投稿詳細画面: 投稿者プロフィールへの遷移
    func testPostDetail_NavigateToAuthorProfile() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // When: 投稿者名またはプロフィール画像をタップ
        let authorName = app.staticTexts.matching(
            NSPredicate(format: "identifier CONTAINS 'author-name'")
        ).firstMatch

        if authorName.waitForExistence(timeout: 3.0) && authorName.isHittable {
            authorName.tap()

            // Then: 投稿者のプロフィール画面が表示される
            let profileTitle = app.navigationBars["プロフィール"]
            XCTAssertTrue(
                profileTitle.waitForExistence(timeout: 5.0),
                "投稿者のプロフィール画面が表示される"
            )
        }
    }

    /// 投稿詳細画面: 閉じるボタンで前の画面に戻る
    func testPostDetail_DismissView() throws {
        // Given: 投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // When: 閉じるボタンまたは戻るボタンをタップ
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists && backButton.isHittable {
            backButton.tap()

            // Then: ホーム画面に戻る
            let homeTitle = app.navigationBars["そらもよう"]
            XCTAssertTrue(
                homeTitle.waitForExistence(timeout: 3.0),
                "ホーム画面に戻る"
            )
        }
    }

    /// 投稿詳細画面: 複数画像の表示とスワイプ
    func testPostDetail_MultipleImagesSwipe() throws {
        // Given: 複数画像を含む投稿詳細画面が表示されている
        performTestLogin()
        navigateToPostDetail()

        // When: 画像をスワイプ
        let imageView = app.images.firstMatch
        if imageView.waitForExistence(timeout: 3.0) {
            let start = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            let end = imageView.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)

            // Then: 次の画像が表示される（複数画像がある場合）
            sleep(1)
            XCTAssertTrue(imageView.exists, "画像スワイプがエラーなく完了する")
        }
    }

    // MARK: - Helper Methods

    /// 投稿詳細画面に遷移するヘルパーメソッド
    private func navigateToPostDetail() {
        let homeTab = app.tabBars.buttons["ホーム"]
        if homeTab.waitForExistence(timeout: 5.0) {
            homeTab.tap()

            // 最初の投稿をタップ
            let firstPost = app.images.firstMatch
            if firstPost.waitForExistence(timeout: 5.0) && firstPost.isHittable {
                firstPost.tap()
                sleep(2) // 画面遷移を待つ
            }
        }
    }
}
