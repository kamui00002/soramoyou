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
//  ⚠️ 前提：Firebase Emulator（auth 9099・firestore 8080・storage 9199・プロジェクト demo-soramoyou-security）が起きていること。
//     UI テストのアプリは必ず Emulator につながる（XCUIApplication.swift）。アカウントと投稿は
//     UITestEmulatorSeeder がテストのたびに置き直す（本番のアカウントは使わない）
//

import XCTest

final class AppStoreReviewUITests: XCTestCase {
    var app: XCUIApplication!
    /// 種まきした人の uid（通報が保存されたかの確かめで使う）
    private var seeded: UITestEmulatorSeeder.Seeded!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Emulator を空にして、決まったアカウントと投稿を置く（テストの順番に左右されないよう毎回）
        seeded = try UITestEmulatorSeeder.resetAndSeed()

        // 広告の追跡の許可（ATT）や通知の許可など、システムのダイアログが操作をふさいだら閉じる
        addUIInterruptionMonitor(withDescription: "システムのダイアログ") { alert in
            for label in ["Appにトラッキングしないように要求", "Ask App Not to Track", "許可しない", "Don’t Allow", "Don't Allow"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        app = XCUIApplication()
        app.launchArguments = [
            // アプリが読む UI テストの目印（AuthViewModel.swift・ContentView.swift の "UI_TESTING"）。
            // RESET_AUTH_STATE で前のテストのログインを消し、毎回ウェルカム画面から始める
            "UI_TESTING", "RESET_AUTH_STATE",
            // 初回のオンボーディングを飛ばす（ContentView.swift の @AppStorage("hasCompletedOnboarding")）。
            // 「-キー 値」は UserDefaults の起動引数の欄に入り、保存されている値より先に読まれる
            "-hasCompletedOnboarding", "YES",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 1. ホームスクロールテスト

    /// ホーム画面が正常にスクロールできることを確認
    func testHomeViewScrolling() throws {
        // ゲストモードでホーム画面に遷移
        enterAsGuest()

        // ホームタブを選択
        let homeTab = tabButton("ホーム")
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
        enterAsGuest()

        // ホームタブを選択
        tabButton("ホーム").tap()

        // 投稿カードをタップすると、投稿詳細（「…」メニューのある画面）が開く
        openFirstPostDetail()
    }

    // MARK: - 2. プロフィール読み込みテスト

    /// ログイン後にプロフィールが正常に読み込まれることを確認
    func testProfileLoading() throws {
        // テスト用アカウントでログイン
        performLogin(UITestEmulatorSeeder.tester)

        // プロフィールタブを選択
        let profileTab = tabButton("プロフィール")
        XCTAssertTrue(profileTab.waitForExistence(timeout: 5), "プロフィールタブが表示されない")
        tapAfterClearingSavePasswordSheet(profileTab)

        // プロフィール画面が表示されることを確認（自分のプロフィールにだけある「…」メニュー）
        let profileMenu = app.buttons["ProfileMenuButton"]
        XCTAssertTrue(profileMenu.waitForExistence(timeout: 10), "プロフィール画面が表示されない")

        // ユーザー名（種まきした表示名）が表示されることを確認
        let displayName = app.staticTexts[UITestEmulatorSeeder.tester.displayName]
        XCTAssertTrue(displayName.waitForExistence(timeout: 5), "ユーザー名が表示されない")

        // プロフィール画像が表示されることを確認（写真を置いていないので、仮の絵）
        let profileImage = app.images["profileImage"]
        XCTAssertTrue(profileImage.waitForExistence(timeout: 5), "プロフィール画像が表示されない")
    }

    /// Auth状態が復元されてプロフィールが再読み込みされることを確認
    func testProfileReloadsOnAuthStateChange() throws {
        // ログイン
        performLogin(UITestEmulatorSeeder.tester)

        // プロフィールタブに移動
        let profileTab = tabButton("プロフィール")
        XCTAssertTrue(profileTab.waitForExistence(timeout: 5), "プロフィールタブが表示されない")
        tapAfterClearingSavePasswordSheet(profileTab)

        // プロフィールが読み込まれることを確認（種まきした表示名）
        let displayName = app.staticTexts[UITestEmulatorSeeder.tester.displayName]
        XCTAssertTrue(displayName.waitForExistence(timeout: 10), "プロフィールが読み込まれない")

        // アプリをバックグラウンドに移動（Auth状態のテスト）
        XCUIDevice.shared.press(.home)
        sleep(2)

        // アプリを再度起動
        app.activate()

        // プロフィールが再度読み込まれることを確認
        XCTAssertTrue(displayName.waitForExistence(timeout: 10), "Auth状態復元後もプロフィールが表示される")
    }

    // MARK: - 3. アカウント削除機能テスト

    /// アカウント削除フローが正常に動作することを確認
    func testAccountDeletion() throws {
        // テスト用アカウントでログイン
        performLogin(UITestEmulatorSeeder.deleteTester)

        // プロフィール → 「…」メニュー → 設定
        openSettings()

        // 「アカウントを削除」ボタンをタップ（行はアイコンと文字で 1 つのボタンなので、文字を含むもので探す）
        let deleteButton = buttonContaining("アカウントを削除")
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "アカウント削除ボタンが表示されない")
        scrollUntilHittable(deleteButton)
        deleteButton.tap()

        // 確認アラートが表示されることを確認（題は SettingsView.swift の .alert("アカウントを削除")）
        let confirmAlert = app.alerts["アカウントを削除"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "確認アラートが表示されない")

        // ⚠️ 実際のテストでは削除を実行しない（キャンセルボタンをタップ）
        let cancelButton = confirmAlert.buttons["キャンセル"]
        XCTAssertTrue(cancelButton.exists, "キャンセルボタンが表示されない")
        cancelButton.tap()

        // アラートが閉じることを確認
        XCTAssertTrue(confirmAlert.waitForNonExistence(timeout: 3), "アラートが閉じない")
    }

    /// アカウント削除の確認アラートに「削除する」ボタンがあることを確認（実際の削除は行わない）
    func testAccountDeletionConfirmation() throws {
        // テスト用アカウントでログイン
        performLogin(UITestEmulatorSeeder.tester)

        // プロフィール → 「…」メニュー → 設定 → アカウント削除
        openSettings()

        let deleteButton = buttonContaining("アカウントを削除")
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "アカウント削除ボタンが表示されない")
        scrollUntilHittable(deleteButton)
        deleteButton.tap()

        // 確認アラートで「削除する」ボタンが存在することを確認
        let confirmAlert = app.alerts["アカウントを削除"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "確認アラートが表示されない")

        let confirmDeleteButton = confirmAlert.buttons["削除する"]
        XCTAssertTrue(confirmDeleteButton.exists, "削除確認ボタンが表示されない")

        // ⚠️ 実際には削除しない（キャンセル）
        confirmAlert.buttons["キャンセル"].tap()
    }

    /// 退会を本当に実行し、Storage の写真・サムネイル・元画像・アイコンと、Firestore の users・posts が消えることを確認
    ///
    /// 消すのは Emulator の中の使い捨てのアカウント（`deleteTester`）だけ。
    /// ⚠️ そらともの削除（Functions の soratomoDeleteMyData）は `UITestFunctionsStandIn` が代わりに「完了」を返す。
    /// このテストが確かめるのは、そのあとにアプリが行う Storage と Firestore の削除。
    func testAccountDeletionRemovesStorageAndFirestoreData() throws {
        // Functions の代役を起こす（テストの終わりに必ず止める）
        let functionsStandIn = try UITestFunctionsStandIn()
        try functionsStandIn.start()
        defer { functionsStandIn.stop() }

        // 退会する人の写真・サムネイル・元画像・アイコンと、その写真を指す投稿を置く
        let uid = seeded.deleteTesterUid
        let targets = try UITestEmulatorSeeder.seedDeletionTargets(uid: uid)
        let documentPaths = ["users/\(uid)", "posts/\(targets.postId)"]

        // 消す前に「ある」ことを確かめる。これが無いと、置き場所の書き間違いでも「消えた」に見えてしまう
        for path in targets.storagePaths {
            XCTAssertTrue(try UITestEmulatorSeeder.storageObjectExists(path), "退会の前に Storage に無い: \(path)")
        }
        for path in documentPaths {
            XCTAssertTrue(try UITestEmulatorSeeder.documentExists(path), "退会の前に Firestore に無い: \(path)")
        }

        // ログイン → プロフィール → 「…」メニュー → 設定 → アカウントを削除 → 削除する
        performLogin(UITestEmulatorSeeder.deleteTester)
        openSettings()

        let deleteButton = buttonContaining("アカウントを削除")
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "アカウント削除ボタンが表示されない")
        scrollUntilHittable(deleteButton)
        deleteButton.tap()

        let confirmAlert = app.alerts["アカウントを削除"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "確認アラートが表示されない")
        confirmAlert.buttons["削除する"].tap()

        // メールとパスワードの人は、消す前にパスワードの入れ直しを求められる（SettingsView.swift の .alert("パスワードを入力")）
        let reauthAlert = app.alerts["パスワードを入力"]
        XCTAssertTrue(reauthAlert.waitForExistence(timeout: 10), "パスワードの入れ直しのアラートが表示されない")
        let reauthEmail = reauthAlert.textFields["メールアドレス"]
        XCTAssertTrue(reauthEmail.waitForExistence(timeout: 3), "入れ直しのメールアドレスの欄が表示されない")
        reauthEmail.tap()
        reauthEmail.typeText(UITestEmulatorSeeder.deleteTester.email)
        let reauthPassword = reauthAlert.secureTextFields["パスワード"]
        XCTAssertTrue(reauthPassword.waitForExistence(timeout: 3), "入れ直しのパスワードの欄が表示されない")
        reauthPassword.tap()
        reauthPassword.typeText(UITestEmulatorSeeder.deleteTester.password)

        // 「確認して削除」を押す。2026-11-15 の実走では、押す動作は出たのにアラートが閉じず、退会が始まらなかった。
        // なので、押せる状態かを先に確かめ、押したあとにアラートが閉じたことまで見る
        let confirmReauthButton = reauthAlert.buttons["確認して削除"]
        XCTAssertTrue(confirmReauthButton.waitForExistence(timeout: 3), "「確認して削除」のボタンが表示されない")
        if confirmReauthButton.isHittable {
            note("「確認して削除」は押せる状態（isHittable = true）")
        } else {
            // キーボードがかぶさっている見込み。改行でキーボードを閉じてから、もう一度見る
            note("「確認して削除」は押せない状態（isHittable = false）。改行でキーボードを閉じる")
            reauthPassword.typeText("\n")
            XCTAssertTrue(reauthAlert.exists, "キーボードを閉じたらパスワードの入れ直しのアラートが消えた")
            XCTAssertTrue(confirmReauthButton.isHittable, "キーボードを閉じても「確認して削除」が押せない")
            note("キーボードを閉じたあと、「確認して削除」は押せる状態（isHittable = true）")
        }
        confirmReauthButton.tap()

        // 押せていれば、アラートは必ず閉じる（SwiftUI のアラートのボタンは、押されたらアラートを閉じる）
        if reauthAlert.waitForNonExistence(timeout: 5) {
            note("「確認して削除」を押せた（1 回目でアラートが閉じた）")
        } else {
            // 閉じていない＝押せていない。もう一度だけ、ボタンの真ん中の位置を直接押す
            note("「確認して削除」を押せなかった（アラートが残っている）。真ん中の位置をもう一度押す")
            confirmReauthButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            guard reauthAlert.waitForNonExistence(timeout: 5) else {
                note("「確認して削除」を 2 回押しても押せなかった（アラートが残っている）")
                XCTFail("「確認して削除」を 2 回押してもアラートが閉じない（退会が始まっていない）。代役に届いた要求: \(functionsStandIn.receivedRequests)")
                return
            }
            note("「確認して削除」を押せた（2 回目でアラートが閉じた）")
        }

        // 退会が終わるとログインが外れ、ウェルカム画面に戻る（「ゲストとして閲覧」はウェルカム画面にだけある）。
        // 失敗したときはアプリが「エラー」のアラートを出すので、その文をそのまま失敗の理由にする
        let welcomeGuestButton = buttonContaining("ゲストとして閲覧")
        let errorAlert = app.alerts["エラー"]
        let deadline = Date().addingTimeInterval(120)
        while !welcomeGuestButton.exists, Date() < deadline {
            if errorAlert.exists {
                let message = errorAlert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " / ")
                XCTFail("退会がアプリのエラーで止まった: \(message)。代役に届いた要求: \(functionsStandIn.receivedRequests)")
                return
            }
            sleep(1)
        }
        XCTAssertTrue(
            welcomeGuestButton.exists,
            "退会のあと 120 秒たってもウェルカム画面に戻らない。代役に届いた要求: \(functionsStandIn.receivedRequests)"
        )
        note("代役に届いた要求: \(functionsStandIn.receivedRequests)")

        // 代役が呼ばれたこと（＝アプリの退会の流れを通ったこと）
        XCTAssertGreaterThanOrEqual(functionsStandIn.answeredCount, 1, "そらともの削除の呼び出しが代役に届いていない")

        // 消えたことを確かめる：Storage の写真・サムネイル・元画像・アイコン、Firestore の users・posts
        for path in targets.storagePaths {
            XCTAssertFalse(try UITestEmulatorSeeder.storageObjectExists(path), "退会のあとも Storage に残っている: \(path)")
        }
        for path in documentPaths {
            XCTAssertFalse(try UITestEmulatorSeeder.documentExists(path), "退会のあとも Firestore に残っている: \(path)")
        }
    }

    // MARK: - 4. 通報機能テスト

    /// 投稿詳細から通報でき、通報が保存されることを確認
    ///
    /// ログインして通報する。ゲストは通報を送らない作り（PostDetailViewModel.submitReport の最初の guard）なので、
    /// ゲストのままだと「通報しました」が出ても何も保存されず、送れたかを確かめられない。
    func testReportPost() throws {
        // テスト用アカウントでログイン
        performLogin(UITestEmulatorSeeder.tester)

        // ホームタブ → 投稿詳細
        tabButton("ホーム").tap()
        openFirstPostDetail()

        // メニューボタン（…）をタップ
        app.buttons["PostMenuButton"].tap()

        // 「この投稿を通報」オプションを確認（HomeView.swift のメニューの文言）
        let reportButton = app.buttons["この投稿を通報"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 3), "通報ボタンが表示されない")
        reportButton.tap()

        // 通報理由を選ぶ（確認ダイアログ。題は既定で隠れるので、理由のボタンで確かめる）
        let inappropriateButton = app.buttons["不適切なコンテンツ"]
        XCTAssertTrue(inappropriateButton.waitForExistence(timeout: 3), "通報理由選択画面が表示されない")
        inappropriateButton.tap()

        // 通報完了のアラートが表示される（HomeView.swift の .alert("通報しました")）
        let confirmAlert = app.alerts["通報しました"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 5), "通報完了アラートが表示されない")
        confirmAlert.buttons["OK"].tap()

        // 通報が Emulator に 1 件保存されたことを確認（画面の「通報しました」だけでは、送れたかは分からない）
        XCTAssertEqual(try UITestEmulatorSeeder.reportCount(reporterId: seeded.testerUid), 1, "通報が保存されていない")
    }

    /// 通報理由が全て表示されることを確認（選ばずに閉じるので、通報は送らない）
    ///
    /// ログインして見る。ゲストが通報を押すと、理由の一覧でなく「ログインが必要です」が出る（HomeView.swift）。
    /// アカウントは Emulator に種まきしたもの（本番のアカウントは使わない）。
    func testReportReasonSelection() throws {
        // 種まきしたアカウントでログイン
        performLogin(UITestEmulatorSeeder.tester)

        // ホームタブ → 投稿詳細 → メニュー → 通報
        tapAfterClearingSavePasswordSheet(tabButton("ホーム"))
        openFirstPostDetail()
        app.buttons["PostMenuButton"].tap()

        let reportButton = app.buttons["この投稿を通報"]
        XCTAssertTrue(reportButton.waitForExistence(timeout: 3), "通報ボタンが表示されない")
        reportButton.tap()

        // 通報理由が全て表示されることを確認（ReportReason.swift の displayName の 5 つ）
        for reason in ["不適切なコンテンツ", "スパム・迷惑行為", "嫌がらせ・誹謗中傷", "著作権侵害", "その他"] {
            XCTAssertTrue(app.buttons[reason].waitForExistence(timeout: 3), "通報理由「\(reason)」が表示されない")
        }

        // 選ばずに閉じる。iOS 26 以降の確認ダイアログは吹き出しの形で「キャンセル」のボタンが出ないので、
        // ボタンがあれば押す。無ければ、吹き出しの外側にシステムが敷く「閉じるための領域」
        // （識別子 PopoverDismissRegion・画面全体の大きさ）の左上寄りをタップして閉じる。
        // 領域の真ん中は吹き出し（理由のボタン）と重なるので、tap() でなく場所を指定して押す
        let cancelButton = app.buttons["キャンセル"]
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        if cancelButton.exists {
            cancelButton.tap()
        } else if dismissRegion.exists {
            dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        } else {
            XCTFail("通報理由の選択を閉じる手段（キャンセル・吹き出しの外側の領域）が見つからない")
        }
        // どちらの閉じ方でも、理由のボタンが消えたことで閉じたと確かめる（閉じなければここで落ちる）
        XCTAssertTrue(app.buttons["不適切なコンテンツ"].waitForNonExistence(timeout: 3), "通報理由の選択が閉じない")
    }

    /// ゲストが通報・ブロックを押すと「ログインが必要です」が出て、通報理由やブロックの確認へは進まないことを確認
    ///
    /// ゲストは通報もブロックも送れない。押したら案内を出す作り（HomeView.swift の .alert("ログインが必要です")）。
    func testGuestReportAndBlockRequireLogin() throws {
        // ゲストモードで開始
        enterAsGuest()

        // ホームタブ → 投稿詳細
        tabButton("ホーム").tap()
        openFirstPostDetail()

        let loginRequiredAlert = app.alerts["ログインが必要です"]
        for item in ["この投稿を通報", "このユーザーをブロック"] {
            // 「…」メニュー → 通報（2 周目はブロック）
            app.buttons["PostMenuButton"].tap()
            let menuItem = app.buttons[item]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "メニューに「\(item)」が表示されない")
            menuItem.tap()

            // 案内が出る
            XCTAssertTrue(loginRequiredAlert.waitForExistence(timeout: 5), "ゲストが「\(item)」を押しても「ログインが必要です」が出ない")
            // 先へは進んでいない（通報理由の一覧も、ブロックの確認も出ていない）
            XCTAssertFalse(app.buttons["不適切なコンテンツ"].exists, "ゲストなのに通報理由の一覧が出ている")
            XCTAssertFalse(app.alerts["ユーザーをブロック"].exists, "ゲストなのにブロックの確認が出ている")

            // OK で閉じる（次の周でメニューを開き直せるように、閉じたことまで見る）
            loginRequiredAlert.buttons["OK"].tap()
            XCTAssertTrue(loginRequiredAlert.waitForNonExistence(timeout: 3), "「ログインが必要です」が閉じない")
        }
    }

    // MARK: - 5. ブロック機能テスト

    /// ユーザーブロック機能の確認アラートが出ることを確認（実際にはブロックしない）
    func testBlockUser() throws {
        // テスト用アカウントでログイン
        performLogin(UITestEmulatorSeeder.tester)

        // ホームタブ → 投稿詳細（先頭は他の人の投稿。テスト用アカウントは投稿を持たない）
        tabButton("ホーム").tap()
        openFirstPostDetail()

        // メニューボタン（...）をタップ
        app.buttons["PostMenuButton"].tap()

        // 「このユーザーをブロック」オプションを確認
        let blockButton = app.buttons["このユーザーをブロック"]
        XCTAssertTrue(blockButton.waitForExistence(timeout: 3), "ブロックボタンが表示されない")
        blockButton.tap()

        // 確認アラートが表示されることを確認
        let confirmAlert = app.alerts["ユーザーをブロック"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "ブロック確認アラートが表示されない")

        // ⚠️ 実際にはブロックしない（キャンセル）
        let cancelButton = confirmAlert.buttons["キャンセル"]
        XCTAssertTrue(cancelButton.exists, "キャンセルボタンが表示されない")
        cancelButton.tap()
        XCTAssertTrue(confirmAlert.waitForNonExistence(timeout: 3), "アラートが閉じない")
    }

    /// ブロック後にフィードから該当ユーザーの投稿が消え、他の人の投稿は残ることを確認
    ///
    /// 投稿者 A（新しい 2 件）と投稿者 B（古い 1 件）を置き、先頭（A の投稿）からブロックする。
    /// 件数の比べ（<=）だと、ブロックが効かなくても通ってしまうので、どの投稿が消えてどれが残るかで確かめる。
    func testBlockedUserPostsHiddenInFeed() throws {
        // テスト用アカウントでログイン
        performLogin(UITestEmulatorSeeder.tester)

        // ホームタブに移動
        tabButton("ホーム").tap()

        // ブロックの前：先頭に投稿者 A の投稿が出ている（読み込みを待ってから見る）
        let postA1 = app.staticTexts[UITestEmulatorSeeder.captionsA[0]]
        XCTAssertTrue(postA1.waitForExistence(timeout: 10), "投稿者 A の投稿がホームに出ていない")

        // 先頭（いちばん新しい＝投稿者 A）の投稿を開き、メニューからブロックする
        openFirstPostDetail()
        app.buttons["PostMenuButton"].tap()

        let blockButton = app.buttons["このユーザーをブロック"]
        XCTAssertTrue(blockButton.waitForExistence(timeout: 3), "ブロックボタンが表示されない")
        blockButton.tap()

        // 確認アラートで「ブロック」を選択（HomeView.swift の .alert("ユーザーをブロック") のボタン）
        let confirmAlert = app.alerts["ユーザーをブロック"]
        XCTAssertTrue(confirmAlert.waitForExistence(timeout: 3), "ブロック確認アラートが表示されない")
        confirmAlert.buttons["ブロック"].tap()

        // ブロックすると投稿詳細は自分で閉じる（HomeView.swift の blockPostAuthor → dismiss）。戻るボタンは押さない
        XCTAssertTrue(app.buttons["PostMenuButton"].waitForNonExistence(timeout: 5), "ブロック後に投稿詳細が閉じない")

        // ブロックの後：投稿者 A の投稿は 2 件とも消え、投稿者 B の投稿は残る（A が消えて先頭に来る）
        XCTAssertTrue(postA1.waitForNonExistence(timeout: 5), "ブロックした人の投稿（A1）がホームに残っている")
        XCTAssertFalse(app.staticTexts[UITestEmulatorSeeder.captionsA[1]].exists, "ブロックした人の投稿（A2）がホームに残っている")
        let postB1 = app.staticTexts[UITestEmulatorSeeder.captionsB[0]]
        XCTAssertTrue(postB1.waitForExistence(timeout: 5), "ブロックしていない人の投稿（B1）まで消えた")
    }

    // MARK: - ヘルパーメソッド

    /// ウェルカム画面から「ゲストとして閲覧」で入る
    private func enterAsGuest() {
        // ボタンはアイコンと文字で 1 つなので、文字を含むもので探す（WelcomeView.swift の「ゲストとして閲覧」）
        let guestButton = buttonContaining("ゲストとして閲覧")
        XCTAssertTrue(guestButton.waitForExistence(timeout: 5), "ゲストとして閲覧のボタンが表示されない")
        guestButton.tap()

        let homeTab = tabButton("ホーム")
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10), "ゲストで入った後にホーム画面が表示されない")
        dismissWhatsNewIfShown()
    }

    /// ログイン処理を実行（アカウントは UITestEmulatorSeeder が置いたもの）
    private func performLogin(_ account: UITestEmulatorSeeder.Account) {
        // ウェルカム画面からログインに遷移
        let loginButton = app.buttons["ログイン"]
        XCTAssertTrue(loginButton.waitForExistence(timeout: 5), "ウェルカム画面のログインボタンが表示されない")
        loginButton.tap()

        // メールアドレスを入力
        let emailField = app.textFields["メールアドレス"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5), "メールアドレスの欄が表示されない")
        emailField.tap()
        // タップが効かずキーボードが出ないまま打つと「焦点が無い」で落ちる（2026-11-13 の実走）。
        // キーボードが出るまで待ち、出なければもう一度だけタップしてから打つ
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 3) {
            emailField.tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "メールアドレスの欄をタップしてもキーボードが出ない")
        }
        emailField.typeText(account.email)

        // パスワードを入力し、改行で送る（LoginView.swift のパスワード欄は改行でログインする。
        // ログイン画面の「ログイン」ボタンは矢印の絵と文字で 1 つのボタンなので、改行で送るほうが確実）
        let passwordField = app.secureTextFields["パスワード"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 3), "パスワードの欄が表示されない")
        passwordField.tap()
        passwordField.typeText(account.password + "\n")

        // ホーム画面が表示されるまで待つ
        let homeTab = tabButton("ホーム")
        XCTAssertTrue(homeTab.waitForExistence(timeout: 10), "ログイン後にホーム画面が表示されない")
        // ログインの直後に iOS が出す「パスワードを保存しますか?」を先に閉じる（かぶさると下が押せない）。
        // What's New の後から遅れて出ることもあるので、後ろでももう一度だけ短く見る
        dismissSavePasswordSheetIfShown(timeout: 3)
        dismissWhatsNewIfShown()
        dismissSavePasswordSheetIfShown(timeout: 1)
    }

    /// iOS の「パスワードを保存しますか?」が出ていたら「今はしない」を押して閉じる
    ///
    /// 2026-11-13 の実走の失敗時の画面の一覧では、このシートは別のプロセス（システム側）が描いているが、
    /// アプリの画面の木の中（アプリの Window の下の Sheet）に入っていた。なのでまずアプリの中で探し、
    /// 見つからなければシステム側（springboard）でも探す。出なければ待つだけで何もしない。
    private func dismissSavePasswordSheetIfShown(timeout: TimeInterval) {
        // 日本語は「今はしない」、英語は "Not Now"
        let notNow = NSPredicate(format: "label IN %@", ["今はしない", "Not Now"])
        // アプリの中にも同じ文字のボタンがありうるので、シートの中のボタンだけを見る
        var button = app.sheets.buttons.matching(notNow).firstMatch
        if !button.waitForExistence(timeout: timeout) {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            button = springboard.buttons.matching(notNow).firstMatch
            guard button.exists else { return }
        }
        // 見つけてから押すまでの間に消えていたら何もしない
        guard button.exists, button.isHittable else { return }
        button.tap()
        XCTAssertTrue(button.waitForNonExistence(timeout: 3), "パスワードの保存のシートが閉じない")
    }

    /// パスワードの保存のシートが出ていれば閉じてから、要素を押す
    ///
    /// シートはログインの少し後に遅れて出ることがあり（2026-11-13 の実走）、かぶさるとタップが下に届かない。
    /// ログインの後に画面を切り替えるタップは、これを通す。
    private func tapAfterClearingSavePasswordSheet(_ element: XCUIElement) {
        dismissSavePasswordSheetIfShown(timeout: 1)
        element.tap()
    }

    /// メニューを開き、中の項目が出なければ、シートを閉じてからもう一度だけ開き直す
    ///
    /// 項目が出たかどうかの確認（XCTAssert）は呼ぶ側でする。
    private func openMenu(_ menu: XCUIElement, expecting item: XCUIElement) {
        tapAfterClearingSavePasswordSheet(menu)
        if item.waitForExistence(timeout: 3) { return }
        // 出なかった：タップの後からシートがかぶさった見込み。閉じて、まだ項目が無ければ開き直す
        dismissSavePasswordSheetIfShown(timeout: 1)
        if !item.exists { menu.tap() }
    }

    /// What's New（新機能の紹介）が出たら閉じる
    ///
    /// オンボーディングを飛ばすと「アップデートした人」として扱われ、ホームの少し後に全画面で出る（MainTabView.swift）。
    /// 閉じると既読になり、同じシミュレーターの次の起動からは出ない。出なければ待つだけで何もしない。
    private func dismissWhatsNewIfShown() {
        let closeButton = app.buttons["閉じる"]
        guard closeButton.waitForExistence(timeout: 4) else { return }
        // 見つけてから押すまでの間に消えることがある（2026-11-13 の実走で、押す時には無くて落ちた）。
        // 押す直前にもう一度、あって押せる状態かを確かめ、消えていたら何もしない
        guard closeButton.exists, closeButton.isHittable else { return }
        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 3), "What's New が閉じない")
    }

    /// ホームの先頭の投稿カードをタップし、投稿詳細が開いたことを確かめる
    private func openFirstPostDetail() {
        // 投稿カードが表示されるまで待つ（HomeView.swift の PostCard の目印）
        let postCard = app.otherElements["PostCard"].firstMatch
        XCTAssertTrue(postCard.waitForExistence(timeout: 10), "投稿カードが表示されない")
        postCard.tap()

        // 投稿詳細画面が表示されることを確認（詳細にだけある「…」メニュー）
        let menuButton = app.buttons["PostMenuButton"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5), "投稿詳細画面が表示されない")
    }

    /// プロフィール → 「…」メニュー → 設定 を開く
    private func openSettings() {
        let profileTab = tabButton("プロフィール")
        XCTAssertTrue(profileTab.waitForExistence(timeout: 5), "プロフィールタブが表示されない")
        tapAfterClearingSavePasswordSheet(profileTab)

        // 設定は自分のプロフィールの「…」メニューの中にある（ProfileView.swift）
        let profileMenu = app.buttons["ProfileMenuButton"]
        XCTAssertTrue(profileMenu.waitForExistence(timeout: 10), "プロフィールの「…」メニューが表示されない")
        let settingsButton = app.buttons["設定"]
        openMenu(profileMenu, expecting: settingsButton)
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3), "設定ボタンが表示されない")
        settingsButton.tap()

        // 設定画面が表示されることを確認（SettingsView.swift の題「設定」）
        XCTAssertTrue(app.navigationBars["設定"].waitForExistence(timeout: 5), "設定画面が表示されない")
    }

    /// テストのログに 1 行残す（xcodebuild のログに「t = …s」の行として出る）
    private func note(_ message: String) {
        XCTContext.runActivity(named: "📝 \(message)") { _ in }
    }

    /// 画面の下のタブのボタン（「ホーム」「プロフィール」など）
    ///
    /// `app.tabBars` では探さない。ログイン後の画面（MainTabView.swift）は自作のタブバーで、
    /// TabBar という種類の入れ物が無いので、`app.tabBars.buttons[…]` だと画面が出ていても見つからない。
    /// ゲストの画面（GuestTabView）は本物の TabView なので、どちらでも見つかるよう、入れ物を問わずボタンの名前で探す。
    private func tabButton(_ title: String) -> XCUIElement {
        app.buttons[title].firstMatch
    }

    /// 文字を含むボタン（アイコンと文字で 1 つになっているボタン用）
    private func buttonContaining(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 押せる位置に来るまで上へスワイプする（画面の下のほうにあるボタン用）
    private func scrollUntilHittable(_ element: XCUIElement, maxSwipes: Int = 5) {
        var swipes = 0
        while !element.isHittable, swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }
}
