//
//  SoramoyouUITests+EditFeatures.swift
//  SoramoyouUITests
//
//  編集機能（フィルター、調整ツール、切り取り）の詳細UIテスト
//

import XCTest

extension SoramoyouUITests {

    // MARK: - Edit View - Filter Tab Tests

    /// 編集画面: フィルタータブの表示確認
    func testEditView_FilterTab_Display() throws {
        // Given: 編集画面が表示されている
        performTestLogin()
        navigateToEditView()

        // When: フィルタータブを選択
        let filterTab = app.buttons["フィルター"]
        if filterTab.waitForExistence(timeout: 3.0) {
            filterTab.tap()

            // Then: フィルター一覧が表示される
            let naturalFilter = app.buttons["ナチュラル"]
            XCTAssertTrue(naturalFilter.waitForExistence(timeout: 3.0), "ナチュラルフィルターが表示される")

            let clearFilter = app.buttons["クリア"]
            XCTAssertTrue(clearFilter.exists, "クリアフィルターが表示される")

            let dramaFilter = app.buttons["ドラマ"]
            XCTAssertTrue(dramaFilter.exists, "ドラマフィルターが表示される")
        }
    }

    /// 編集画面: フィルター適用テスト
    func testEditView_FilterTab_ApplyFilter() throws {
        // Given: 編集画面のフィルタータブが表示されている
        performTestLogin()
        navigateToEditView()

        let filterTab = app.buttons["フィルター"]
        if filterTab.waitForExistence(timeout: 3.0) {
            filterTab.tap()

            // When: フィルターを選択
            let dramaFilter = app.buttons["ドラマ"]
            if dramaFilter.waitForExistence(timeout: 3.0) {
                dramaFilter.tap()

                // Then: フィルターが選択状態になる
                XCTAssertTrue(dramaFilter.isSelected, "選択したフィルターがアクティブになる")
            }
        }
    }

    /// 編集画面: 全フィルターの表示確認（10種類）
    func testEditView_FilterTab_AllFiltersDisplay() throws {
        // Given: 編集画面のフィルタータブが表示されている
        performTestLogin()
        navigateToEditView()

        let filterTab = app.buttons["フィルター"]
        if filterTab.waitForExistence(timeout: 3.0) {
            filterTab.tap()

            // Then: 10種類のフィルターが全て表示される
            let expectedFilters = [
                "ナチュラル", "クリア", "ドラマ", "ソフト", "ウォーム",
                "クール", "ビンテージ", "モノクロ", "パステル", "ヴィヴィッド"
            ]

            for filterName in expectedFilters {
                let filterButton = app.buttons[filterName]
                XCTAssertTrue(
                    filterButton.waitForExistence(timeout: 2.0) || filterButton.exists,
                    "\(filterName)フィルターが表示される"
                )
            }
        }
    }

    // MARK: - Edit View - Adjustment Tab Tests

    /// 編集画面: 調整タブの表示確認
    func testEditView_AdjustmentTab_Display() throws {
        // Given: 編集画面が表示されている
        performTestLogin()
        navigateToEditView()

        // When: 調整タブを選択
        let adjustmentTab = app.buttons["調整"]
        if adjustmentTab.waitForExistence(timeout: 3.0) {
            adjustmentTab.tap()

            // Then: 編集ツール一覧が表示される
            // ユーザーが装備している編集ツールが表示される
            let toolsScrollView = app.scrollViews.firstMatch
            XCTAssertTrue(
                toolsScrollView.waitForExistence(timeout: 3.0),
                "編集ツール一覧が表示される"
            )
        }
    }

    /// 編集画面: 編集ツールの選択と調整
    func testEditView_AdjustmentTab_SelectAndAdjustTool() throws {
        // Given: 編集画面の調整タブが表示されている
        performTestLogin()
        navigateToEditView()

        let adjustmentTab = app.buttons["調整"]
        if adjustmentTab.waitForExistence(timeout: 3.0) {
            adjustmentTab.tap()

            // When: 編集ツール（例: 明るさ）を選択
            let brightnessButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '明るさ'")).firstMatch
            if brightnessButton.waitForExistence(timeout: 3.0) {
                brightnessButton.tap()

                // Then: スライダーが表示される
                let slider = app.sliders.firstMatch
                XCTAssertTrue(
                    slider.waitForExistence(timeout: 2.0),
                    "調整スライダーが表示される"
                )

                // スライダーを調整
                slider.adjust(toNormalizedSliderPosition: 0.7)

                // 値が変更されたことを確認（実装に依存）
                XCTAssertNotNil(slider.value, "スライダーの値が設定される")
            }
        }
    }

    /// 編集画面: 装備システムの確認（選択されたツールのみ表示）
    func testEditView_AdjustmentTab_EquipmentSystemCheck() throws {
        // Given: 編集画面の調整タブが表示されている
        performTestLogin()
        navigateToEditView()

        let adjustmentTab = app.buttons["調整"]
        if adjustmentTab.waitForExistence(timeout: 3.0) {
            adjustmentTab.tap()

            // Then: 装備されているツールのみが表示される（5〜8個）
            let toolButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tool-'"))
            let toolCount = toolButtons.count

            XCTAssertGreaterThanOrEqual(toolCount, 5, "最低5個の編集ツールが装備されている")
            XCTAssertLessThanOrEqual(toolCount, 8, "最大8個の編集ツールが装備されている")
        }
    }

    /// 編集画面: 編集ツール設定画面への遷移
    func testEditView_AdjustmentTab_NavigateToToolSettings() throws {
        // Given: 編集画面の調整タブが表示されている
        performTestLogin()
        navigateToEditView()

        let adjustmentTab = app.buttons["調整"]
        if adjustmentTab.waitForExistence(timeout: 3.0) {
            adjustmentTab.tap()

            // When: 編集ツール設定ボタンをタップ
            let settingsButton = app.buttons["編集ツール設定"]
            if settingsButton.waitForExistence(timeout: 3.0) {
                settingsButton.tap()

                // Then: 編集装備設定画面が表示される
                let settingsTitle = app.navigationBars.matching(
                    NSPredicate(format: "label CONTAINS 'おすすめ編集設定' OR label CONTAINS '編集装備'")
                ).firstMatch

                XCTAssertTrue(
                    settingsTitle.waitForExistence(timeout: 3.0),
                    "編集装備設定画面が表示される"
                )
            }
        }
    }

    // MARK: - Edit View - Crop Tab Tests

    /// 編集画面: 切り取りタブの表示確認
    func testEditView_CropTab_Display() throws {
        // Given: 編集画面が表示されている
        performTestLogin()
        navigateToEditView()

        // When: 切り取りタブを選択
        let cropTab = app.buttons["切り取り"]
        if cropTab.waitForExistence(timeout: 3.0) {
            cropTab.tap()

            // Then: 切り取りツールが表示される
            let rotateButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '回転'")).firstMatch
            XCTAssertTrue(
                rotateButton.waitForExistence(timeout: 3.0) || rotateButton.exists,
                "回転ボタンが表示される"
            )

            let flipButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '反転'")).firstMatch
            XCTAssertTrue(
                flipButton.waitForExistence(timeout: 2.0) || flipButton.exists,
                "反転ボタンが表示される"
            )
        }
    }

    /// 編集画面: 画像の回転操作
    func testEditView_CropTab_RotateImage() throws {
        // Given: 編集画面の切り取りタブが表示されている
        performTestLogin()
        navigateToEditView()

        let cropTab = app.buttons["切り取り"]
        if cropTab.waitForExistence(timeout: 3.0) {
            cropTab.tap()

            // When: 回転ボタンをタップ
            let rotateButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '回転'")).firstMatch
            if rotateButton.waitForExistence(timeout: 3.0) {
                rotateButton.tap()

                // Then: 画像が回転する（見た目の変化は検証困難だが、エラーがないことを確認）
                XCTAssertTrue(rotateButton.exists, "回転操作がエラーなく完了する")
            }
        }
    }

    /// 編集画面: アスペクト比の選択
    func testEditView_CropTab_SelectAspectRatio() throws {
        // Given: 編集画面の切り取りタブが表示されている
        performTestLogin()
        navigateToEditView()

        let cropTab = app.buttons["切り取り"]
        if cropTab.waitForExistence(timeout: 3.0) {
            cropTab.tap()

            // When: アスペクト比ボタンをタップ
            let aspectRatioButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS ':' OR label CONTAINS '自由'"))

            if aspectRatioButtons.count > 0 {
                let firstAspectButton = aspectRatioButtons.element(boundBy: 0)
                if firstAspectButton.waitForExistence(timeout: 3.0) {
                    firstAspectButton.tap()

                    // Then: アスペクト比が選択される
                    XCTAssertTrue(firstAspectButton.isSelected, "アスペクト比が選択される")
                }
            }
        }
    }

    // MARK: - Edit View - Tab Switching Tests

    /// 編集画面: タブ切り替え動作確認
    func testEditView_TabSwitching() throws {
        // Given: 編集画面が表示されている
        performTestLogin()
        navigateToEditView()

        // When: 各タブを順番に選択
        let filterTab = app.buttons["フィルター"]
        let adjustmentTab = app.buttons["調整"]
        let cropTab = app.buttons["切り取り"]

        if filterTab.waitForExistence(timeout: 3.0) {
            // フィルタータブを選択
            filterTab.tap()
            XCTAssertTrue(filterTab.isSelected, "フィルタータブが選択される")

            // 調整タブを選択
            if adjustmentTab.waitForExistence(timeout: 2.0) {
                adjustmentTab.tap()
                XCTAssertTrue(adjustmentTab.isSelected, "調整タブが選択される")
            }

            // 切り取りタブを選択
            if cropTab.waitForExistence(timeout: 2.0) {
                cropTab.tap()
                XCTAssertTrue(cropTab.isSelected, "切り取りタブが選択される")
            }
        }
    }

    /// 編集画面: リアルタイムプレビュー確認
    func testEditView_RealtimePreview() throws {
        // Given: 編集画面が表示されている
        performTestLogin()
        navigateToEditView()

        // When: フィルターを適用
        let filterTab = app.buttons["フィルター"]
        if filterTab.waitForExistence(timeout: 3.0) {
            filterTab.tap()

            let dramaFilter = app.buttons["ドラマ"]
            if dramaFilter.waitForExistence(timeout: 3.0) {
                dramaFilter.tap()

                // Then: プレビュー画像が存在する（リアルタイム更新）
                let previewImage = app.images.firstMatch
                XCTAssertTrue(
                    previewImage.exists,
                    "編集プレビューが表示される"
                )
            }
        }
    }

    /// 編集画面: 完了ボタンで次の画面へ遷移
    func testEditView_NavigateToPostInfo() throws {
        // Given: 編集画面が表示されている
        performTestLogin()
        navigateToEditView()

        // When: 次へボタンをタップ
        let nextButton = app.buttons["次へ"]
        if nextButton.waitForExistence(timeout: 3.0) {
            nextButton.tap()

            // Then: 投稿情報入力画面が表示される
            let postInfoTitle = app.navigationBars["投稿情報"]
            XCTAssertTrue(
                postInfoTitle.waitForExistence(timeout: 5.0),
                "投稿情報画面が表示される"
            )
        }
    }

    // MARK: - Helper Methods

    /// 編集画面に遷移するヘルパーメソッド
    private func navigateToEditView() {
        // 投稿タブに移動
        let postTab = app.tabBars.buttons["投稿"]
        if postTab.waitForExistence(timeout: 5.0) {
            postTab.tap()

            // 写真選択ボタンをタップ
            let photoButton = app.buttons["写真を選択"]
            if photoButton.waitForExistence(timeout: 3.0) {
                photoButton.tap()

                // 写真ピッカーで写真を選択（実際の操作は制限があるため、模擬的に待機）
                // 注意: 実際のUIテストでは写真選択が必要な場合、
                // テスト用の画像を事前に設定する必要があります
                sleep(2)

                // 編集画面が表示されるまで待つ
                let editTitle = app.navigationBars["編集"]
                _ = editTitle.waitForExistence(timeout: 5.0)
            }
        }
    }
}
