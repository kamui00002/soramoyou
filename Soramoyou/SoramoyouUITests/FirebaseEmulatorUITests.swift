//
//  FirebaseEmulatorUITests.swift
//  SoramoyouUITests
//
//  UI テストで起動したアプリが、Firebase を Emulator へ切り替えたかを確かめる ⭐️
//  （セキュリティ監査 2026-10-14 の 5-1・REPORT §7 ②）
//
//  - UI テストを回すときは、最初にこれを 1 本だけ回して緑を確かめてから、ほかを回す
//    （例：-only-testing:SoramoyouUITests/FirebaseEmulatorUITests）
//  - アプリの画面にある見えない目印（識別子 firebase-connection）を読む。文字が emulator なら切り替わっている。
//    production なら本番につながっている。要素が見つからなければ、目印の作りかアプリの起動が壊れている
//  - ⚠️ 落ちたとき、アプリはもう起動している（production なら本番につながったまま）。だから落とす前にアプリを止める
//

import XCTest

final class FirebaseEmulatorUITests: XCTestCase {
    /// アプリ側の FirebaseConnectionMarker.identifier と同じ値（UI テストからはアプリの型を読めないので文字で持つ）
    private let markerIdentifier = "firebase-connection"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// アプリが Emulator に切り替わっていることを、画面の目印で確かめる
    func testAppIsConnectedToEmulator() {
        // UI テストのターゲットにある同じ名前の版（XCUIApplication.swift）。目印を必ず入れて起動する
        let app = XCUIApplication()
        app.launch()

        let marker = app.descendants(matching: .any)[markerIdentifier]
        guard marker.waitForExistence(timeout: 15) else {
            app.terminate()
            XCTFail("接続先の目印（\(markerIdentifier)）が画面にありません。目印の作りか、アプリの起動を確かめてください")
            return
        }

        let label = marker.label
        if label != "emulator" {
            // 本番につながったまま、ほかの操作をさせない
            app.terminate()
        }
        XCTAssertEqual(label, "emulator", "Emulator に切り替わっていません（production なら本番につながっています）")
    }
}
