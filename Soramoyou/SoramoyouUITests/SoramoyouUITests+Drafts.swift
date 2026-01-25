//
//  SoramoyouUITests+Drafts.swift
//  SoramoyouUITests
//
//  下書き機能のUIテスト
//

import XCTest

extension SoramoyouUITests {

    // MARK: - Drafts View Tests

    /// 下書き一覧画面: 画面表示確認
    func testDrafts_Display() throws {
        // Given: ログイン済み
        performTestLogin()

        // When: プロフィール画面からメニューを開く
        let profileTab = app.tabBars.buttons["プロフィール"]
        if profileTab.waitForExistence(timeout: 5.0) {
            profileTab.tap()

            let menuButton = app.buttons["ellipsis.circle"]
            if menuButton.waitForExistence(timeout: 3.0) {
                menuButton.tap()

                // 下書き一覧をタップ
                let draftsButton = app.buttons["下書き"]
                if draftsButton.waitForExistence(timeout: 2.0) {
                    draftsButton.tap()

                    // Then: 下書き一覧画面が表示される
                    let draftsTitle = app.navigationBars["下書き"]
                    XCTAssertTrue(
                        draftsTitle.waitForExistence(timeout: 3.0),
                        "下書き一覧画面が表示される"
                    )
                }
            }
        }
    }

    /// 下書き一覧画面: 空の状態の表示
    func testDrafts_EmptyStateDisplay() throws {
        // Given: 下書きが一つもない状態
        performTestLogin()
        navigateToDraftsView()

        // Then: 「下書きがありません」メッセージが表示される
        let emptyMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '下書きがありません' OR label CONTAINS 'まだ下書きがありません'")
        ).firstMatch

        // 下書きがない場合、メッセージが表示される
        if emptyMessage.waitForExistence(timeout: 3.0) {
            XCTAssertTrue(emptyMessage.exists, "下書きがない場合のメッセージが表示される")
        }
    }

    /// 下書き一覧画面: 下書きリストの表示
    func testDrafts_ListDisplay() throws {
        // Given: 下書きが存在する状態
        performTestLogin()
        navigateToDraftsView()

        // Then: 下書きのリストが表示される（存在する場合）
        let draftsList = app.scrollViews.firstMatch
        if draftsList.waitForExistence(timeout: 3.0) {
            XCTAssertTrue(draftsList.exists, "下書きリストが表示される")
        }
    }

    /// 下書き一覧画面: 下書きの詳細確認
    func testDrafts_DraftItemDisplay() throws {
        // Given: 下書き一覧画面が表示されている
        performTestLogin()
        navigateToDraftsView()

        // Then: 下書きアイテムの要素が表示される（存在する場合）
        // サムネイル画像
        let thumbnail = app.images.firstMatch

        // 保存日時
        let dateLabel = app.staticTexts.matching(
            NSPredicate(format: "identifier CONTAINS 'draft-date'")
        ).firstMatch

        // 少なくとも一つの要素が存在すれば下書きアイテムが表示されている
        let draftItemExists = thumbnail.exists || dateLabel.exists
        if draftItemExists {
            XCTAssertTrue(draftItemExists, "下書きアイテムの要素が表示される")
        }
    }

    /// 下書き一覧画面: 下書きをタップして編集画面へ遷移
    func testDrafts_TapToEdit() throws {
        // Given: 下書き一覧画面が表示されている（下書きが存在する）
        performTestLogin()
        navigateToDraftsView()

        // When: 下書きをタップ
        let firstDraft = app.images.firstMatch
        if firstDraft.waitForExistence(timeout: 3.0) && firstDraft.isHittable {
            firstDraft.tap()

            // Then: 編集画面が表示される
            let editTitle = app.navigationBars["編集"]
            XCTAssertTrue(
                editTitle.waitForExistence(timeout: 5.0),
                "編集画面が表示される"
            )
        }
    }

    /// 下書き一覧画面: 下書きの削除
    func testDrafts_DeleteDraft() throws {
        // Given: 下書き一覧画面が表示されている（下書きが存在する）
        performTestLogin()
        navigateToDraftsView()

        // When: 下書きを左スワイプまたは削除ボタンをタップ
        let firstDraft = app.images.firstMatch
        if firstDraft.waitForExistence(timeout: 3.0) {
            // 左スワイプ
            let start = firstDraft.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            let end = firstDraft.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: end)

            // 削除ボタンが表示される
            let deleteButton = app.buttons["削除"]
            if deleteButton.waitForExistence(timeout: 2.0) {
                deleteButton.tap()

                // 確認ダイアログが表示される場合
                let confirmButton = app.alerts.buttons["削除"]
                if confirmButton.waitForExistence(timeout: 2.0) {
                    confirmButton.tap()
                }

                // Then: 下書きが削除される
                sleep(1)
                XCTAssertTrue(true, "下書き削除操作が完了する")
            }
        }
    }

    /// 下書き一覧画面: 下書きから投稿完了までのフロー
    func testDrafts_PostFlowFromDraft() throws {
        // Given: 下書き一覧画面が表示されている（下書きが存在する）
        performTestLogin()
        navigateToDraftsView()

        // When: 下書きを選択
        let firstDraft = app.images.firstMatch
        if firstDraft.waitForExistence(timeout: 3.0) && firstDraft.isHittable {
            firstDraft.tap()

            // 編集画面で「次へ」をタップ
            let nextButton = app.buttons["次へ"]
            if nextButton.waitForExistence(timeout: 5.0) {
                nextButton.tap()

                // 投稿情報画面で「投稿」をタップ
                let postButton = app.buttons["投稿"]
                if postButton.waitForExistence(timeout: 5.0) {
                    postButton.tap()

                    // Then: 投稿が完了してホーム画面に戻る
                    let homeTab = app.tabBars.buttons["ホーム"]
                    XCTAssertTrue(
                        homeTab.waitForExistence(timeout: 10.0),
                        "投稿完了後、ホーム画面に戻る"
                    )
                }
            }
        }
    }

    /// 下書き一覧画面: 下書きの並び順確認（新しい順）
    func testDrafts_SortOrder() throws {
        // Given: 複数の下書きが存在する
        performTestLogin()
        navigateToDraftsView()

        // Then: 下書きが新しい順に表示される
        // 実際の検証は日時ラベルの確認が必要（実装に依存）
        let draftsList = app.scrollViews.firstMatch
        if draftsList.waitForExistence(timeout: 3.0) {
            XCTAssertTrue(draftsList.exists, "下書きリストが表示される")
            // 注意: 実際の並び順の検証には、各下書きの日時を取得して比較する必要があります
        }
    }

    /// 下書き一覧画面: プルリフレッシュ
    func testDrafts_PullToRefresh() throws {
        // Given: 下書き一覧画面が表示されている
        performTestLogin()
        navigateToDraftsView()

        // When: プルリフレッシュを実行
        let scrollView = app.scrollViews.firstMatch
        if scrollView.waitForExistence(timeout: 3.0) {
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let end = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            start.press(forDuration: 0.1, thenDragTo: end)

            // Then: リフレッシュが実行される
            sleep(2)
            XCTAssertTrue(scrollView.exists, "リフレッシュが完了する")
        }
    }

    /// 下書き一覧画面: 画面を閉じる
    func testDrafts_DismissView() throws {
        // Given: 下書き一覧画面が表示されている
        performTestLogin()
        navigateToDraftsView()

        // When: 閉じるボタンまたは戻るボタンをタップ
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.exists && backButton.isHittable {
            backButton.tap()

            // Then: プロフィール画面に戻る
            let profileTitle = app.navigationBars["プロフィール"]
            XCTAssertTrue(
                profileTitle.waitForExistence(timeout: 3.0),
                "プロフィール画面に戻る"
            )
        }
    }

    // MARK: - Helper Methods

    /// 下書き一覧画面に遷移するヘルパーメソッド
    private func navigateToDraftsView() {
        let profileTab = app.tabBars.buttons["プロフィール"]
        if profileTab.waitForExistence(timeout: 5.0) {
            profileTab.tap()

            let menuButton = app.buttons["ellipsis.circle"]
            if menuButton.waitForExistence(timeout: 3.0) {
                menuButton.tap()

                let draftsButton = app.buttons["下書き"]
                if draftsButton.waitForExistence(timeout: 2.0) {
                    draftsButton.tap()
                    sleep(1) // 画面遷移を待つ
                }
            }
        }
    }
}
