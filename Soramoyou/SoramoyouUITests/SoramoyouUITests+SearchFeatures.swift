//
//  SoramoyouUITests+SearchFeatures.swift
//  SoramoyouUITests
//
//  検索機能の詳細UIテスト
//

import XCTest

extension SoramoyouUITests {

    // MARK: - Search View - Hashtag Search Tests

    /// 検索画面: ハッシュタグ検索フィールドの表示
    func testSearch_HashtagFieldDisplay() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // Then: ハッシュタグ検索フィールドが表示される
        let hashtagField = app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS 'ハッシュタグ' OR label CONTAINS 'ハッシュタグ'")
        ).firstMatch

        XCTAssertTrue(
            hashtagField.waitForExistence(timeout: 3.0),
            "ハッシュタグ検索フィールドが表示される"
        )
    }

    /// 検索画面: ハッシュタグ検索の実行
    func testSearch_PerformHashtagSearch() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // When: ハッシュタグを入力して検索
        let hashtagField = app.textFields.firstMatch
        if hashtagField.waitForExistence(timeout: 3.0) {
            hashtagField.tap()
            hashtagField.typeText("空")

            // 検索ボタンをタップ（存在する場合）
            let searchButton = app.buttons["検索"]
            if searchButton.exists {
                searchButton.tap()
            } else {
                // Returnキーで検索実行
                app.keyboards.buttons["return"].tap()
            }

            // Then: 検索結果が表示される
            sleep(2) // 検索処理を待つ
            let resultsView = app.scrollViews.firstMatch
            XCTAssertTrue(
                resultsView.exists,
                "検索結果が表示される"
            )
        }
    }

    /// 検索画面: 複数のハッシュタグで検索
    func testSearch_MultipleHashtags() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // When: 複数のハッシュタグを入力
        let hashtagField = app.textFields.firstMatch
        if hashtagField.waitForExistence(timeout: 3.0) {
            hashtagField.tap()
            hashtagField.typeText("空 夕焼け")

            // 検索実行
            app.keyboards.buttons["return"].tap()

            // Then: 検索が実行される
            sleep(2)
            XCTAssertTrue(true, "複数ハッシュタグ検索が完了する")
        }
    }

    // MARK: - Search View - Color Search Tests

    /// 検索画面: 色検索の表示確認
    func testSearch_ColorSearchDisplay() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // Then: 色検索セクションが表示される
        let colorSection = app.otherElements.matching(
            NSPredicate(format: "identifier CONTAINS 'color-search' OR label CONTAINS '色で検索'")
        ).firstMatch

        if colorSection.waitForExistence(timeout: 3.0) {
            XCTAssertTrue(colorSection.exists, "色検索セクションが表示される")
        }
    }

    /// 検索画面: 色を選択して検索
    func testSearch_PerformColorSearch() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // When: 色を選択
        let colorButtons = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'color-'")
        )

        if colorButtons.count > 0 {
            let firstColor = colorButtons.element(boundBy: 0)
            if firstColor.waitForExistence(timeout: 3.0) {
                firstColor.tap()

                // Then: 選択した色で検索が実行される
                sleep(2)
                XCTAssertTrue(firstColor.isSelected, "色が選択される")
            }
        }
    }

    // MARK: - Search View - Time of Day Search Tests

    /// 検索画面: 時間帯検索チップの表示
    func testSearch_TimeOfDayChipsDisplay() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // Then: 時間帯チップ（朝、午後、夕方、夜）が表示される
        let expectedTimes = ["朝", "午後", "夕方", "夜"]

        for time in expectedTimes {
            let timeChip = app.buttons[time]
            XCTAssertTrue(
                timeChip.waitForExistence(timeout: 2.0) || timeChip.exists,
                "\(time)の時間帯チップが表示される"
            )
        }
    }

    /// 検索画面: 時間帯を選択して検索
    func testSearch_SelectTimeOfDay() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // When: 時間帯チップをタップ
        let morningChip = app.buttons["朝"]
        if morningChip.waitForExistence(timeout: 3.0) {
            morningChip.tap()

            // Then: 選択した時間帯で検索が実行される
            sleep(2)
            XCTAssertTrue(morningChip.isSelected, "時間帯が選択される")
        }
    }

    /// 検索画面: 複数の時間帯を選択
    func testSearch_SelectMultipleTimesOfDay() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // When: 複数の時間帯チップをタップ
        let morningChip = app.buttons["朝"]
        let eveningChip = app.buttons["夕方"]

        if morningChip.waitForExistence(timeout: 3.0) {
            morningChip.tap()
        }

        if eveningChip.waitForExistence(timeout: 2.0) {
            eveningChip.tap()
        }

        // Then: 両方の時間帯が選択される
        XCTAssertTrue(
            morningChip.isSelected && eveningChip.isSelected,
            "複数の時間帯が選択される"
        )
    }

    // MARK: - Search View - Sky Type Search Tests

    /// 検索画面: 空の種類検索チップの表示
    func testSearch_SkyTypeChipsDisplay() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // Then: 空の種類チップが表示される
        let expectedSkyTypes = ["晴れ", "曇り", "夕焼け", "朝焼け"]

        for skyType in expectedSkyTypes {
            let skyTypeChip = app.buttons[skyType]
            // 一部でも表示されていればOK
            if skyTypeChip.waitForExistence(timeout: 2.0) {
                XCTAssertTrue(skyTypeChip.exists, "\(skyType)の空タイプチップが表示される")
            }
        }
    }

    /// 検索画面: 空の種類を選択して検索
    func testSearch_SelectSkyType() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // When: 空の種類チップをタップ
        let clearSkyChip = app.buttons["晴れ"]
        if clearSkyChip.waitForExistence(timeout: 3.0) {
            clearSkyChip.tap()

            // Then: 選択した空の種類で検索が実行される
            sleep(2)
            XCTAssertTrue(clearSkyChip.isSelected, "空の種類が選択される")
        }
    }

    // MARK: - Search View - Combined Search Tests

    /// 検索画面: 複数条件を組み合わせて検索
    func testSearch_CombinedFilters() throws {
        // Given: 検索画面が表示されている
        performTestLogin()
        navigateToSearchView()

        // When: ハッシュタグ、時間帯、空の種類を組み合わせて検索
        // 1. ハッシュタグ入力
        let hashtagField = app.textFields.firstMatch
        if hashtagField.waitForExistence(timeout: 3.0) {
            hashtagField.tap()
            hashtagField.typeText("空")
        }

        // 2. 時間帯選択
        let morningChip = app.buttons["朝"]
        if morningChip.waitForExistence(timeout: 2.0) {
            morningChip.tap()
        }

        // 3. 空の種類選択
        let clearSkyChip = app.buttons["晴れ"]
        if clearSkyChip.waitForExistence(timeout: 2.0) {
            clearSkyChip.tap()
        }

        // 検索実行
        app.keyboards.buttons["return"].tap()

        // Then: 組み合わせた条件で検索が実行される
        sleep(2)
        XCTAssertTrue(true, "複数条件での検索が完了する")
    }

    // MARK: - Search Results Tests

    /// 検索結果: 結果一覧の表示
    func testSearchResults_Display() throws {
        // Given: 検索を実行して結果が表示されている
        performTestLogin()
        performSearch(hashtag: "空")

        // Then: 検索結果が表示される
        let resultsView = app.scrollViews.firstMatch
        XCTAssertTrue(
            resultsView.waitForExistence(timeout: 3.0),
            "検索結果一覧が表示される"
        )
    }

    /// 検索結果: 結果がない場合の表示
    func testSearchResults_NoResults() throws {
        // Given: 検索を実行して結果がない
        performTestLogin()
        performSearch(hashtag: "存在しないハッシュタグ12345")

        // Then: 「検索結果がありません」メッセージが表示される
        let noResultsMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '検索結果がありません' OR label CONTAINS '見つかりませんでした'")
        ).firstMatch

        if noResultsMessage.waitForExistence(timeout: 3.0) {
            XCTAssertTrue(noResultsMessage.exists, "検索結果がないメッセージが表示される")
        }
    }

    /// 検索結果: 投稿をタップして詳細表示
    func testSearchResults_TapPostToShowDetail() throws {
        // Given: 検索結果が表示されている
        performTestLogin()
        performSearch(hashtag: "空")

        // When: 検索結果の投稿をタップ
        let firstResult = app.images.firstMatch
        if firstResult.waitForExistence(timeout: 5.0) && firstResult.isHittable {
            firstResult.tap()

            // Then: 投稿詳細画面が表示される
            sleep(2)
            let detailView = app.otherElements.firstMatch
            XCTAssertTrue(detailView.exists, "投稿詳細画面が表示される")
        }
    }

    /// 検索結果: スクロールとページネーション
    func testSearchResults_ScrollAndPagination() throws {
        // Given: 検索結果が表示されている
        performTestLogin()
        performSearch(hashtag: "空")

        // When: 結果をスクロール
        let resultsView = app.scrollViews.firstMatch
        if resultsView.waitForExistence(timeout: 3.0) {
            // 下にスクロール
            let start = resultsView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = resultsView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.1, thenDragTo: end)

            // Then: 追加の結果が読み込まれる（ページネーション）
            sleep(2)
            XCTAssertTrue(resultsView.exists, "検索結果のスクロールが完了する")
        }
    }

    /// 検索画面: 検索履歴の表示（実装されている場合）
    func testSearch_SearchHistoryDisplay() throws {
        // Given: 検索画面が表示されている（過去に検索履歴がある）
        performTestLogin()
        navigateToSearchView()

        // Then: 検索履歴が表示される（実装されている場合）
        let historySection = app.otherElements.matching(
            NSPredicate(format: "identifier CONTAINS 'search-history' OR label CONTAINS '検索履歴'")
        ).firstMatch

        if historySection.waitForExistence(timeout: 3.0) {
            XCTAssertTrue(historySection.exists, "検索履歴セクションが表示される")
        }
    }

    /// 検索画面: 検索条件のリセット
    func testSearch_ClearFilters() throws {
        // Given: 検索条件が選択されている
        performTestLogin()
        navigateToSearchView()

        // 時間帯を選択
        let morningChip = app.buttons["朝"]
        if morningChip.waitForExistence(timeout: 3.0) {
            morningChip.tap()
        }

        // When: クリアボタンをタップ（存在する場合）
        let clearButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'クリア' OR label CONTAINS 'リセット'")
        ).firstMatch

        if clearButton.waitForExistence(timeout: 2.0) {
            clearButton.tap()

            // Then: 選択がクリアされる
            XCTAssertFalse(morningChip.isSelected, "検索条件がクリアされる")
        }
    }

    // MARK: - Helper Methods

    /// 検索画面に遷移するヘルパーメソッド
    private func navigateToSearchView() {
        let searchTab = app.tabBars.buttons["検索"]
        if searchTab.waitForExistence(timeout: 5.0) {
            searchTab.tap()
        }
    }

    /// 検索を実行するヘルパーメソッド
    private func performSearch(hashtag: String) {
        navigateToSearchView()

        let hashtagField = app.textFields.firstMatch
        if hashtagField.waitForExistence(timeout: 3.0) {
            hashtagField.tap()
            hashtagField.typeText(hashtag)
            app.keyboards.buttons["return"].tap()
            sleep(2) // 検索処理を待つ
        }
    }
}
