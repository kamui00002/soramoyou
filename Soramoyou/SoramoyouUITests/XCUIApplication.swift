//
//  XCUIApplication.swift
//  SoramoyouUITests
//
//  UI テストで起動するアプリに、Firebase を Emulator へ切り替える目印を必ず渡す ⭐️
//  （セキュリティ監査 2026-10-14 の 5-1・REPORT §7 ②）
//
//  - なぜ同じ名前か：Swift は「このターゲットの中にある名前」を、取り込んだ XCTest の名前より先に見つける。
//    だから UI テストの中で XCUIApplication() と書けば、全部この版になり、目印の渡し忘れが起きない
//  - 目印が無いと、アプリは普段の起動と同じく本番（plist の接続先）につながる
//    （アプリ側の受け取りは Soramoyou/Services/FirebaseEmulatorSwitch.swift）
//  - ⚠️ 抜け道：元の型を、モジュール名を付けてわざわざ書くと、この版を通らない。
//    その書き方は scripts/check-uitests-launch-guard.sh が CI で見張る（この下の宣言 1 行だけは例外）
//  - 元の型の置き場は、Xcode 27 では XCUIAutomation（XCTest から移った）。XCTest のモジュール名では書けない。
//    XCTest の中には同じ名前のクラス XCTest もあり、Swift がそちらを先に見つけてコンパイルが通らないため
//  - 目印は起動の直前に入れる（テストが launchEnvironment を丸ごと入れ替えても消えないように）
//

import XCTest
import XCUIAutomation

class XCUIApplication: XCUIAutomation.XCUIApplication {
    /// アプリに渡す目印の名前（アプリ側の FirebaseEmulatorSwitch.uiTestEnvironmentKey と同じ）
    static let firebaseEmulatorKey = "SORAMOYOU_FIREBASE_EMULATOR"

    /// 起動する（目印を入れてから、XCTest の本来の起動へ回す）
    override func launch() {
        launchEnvironment[Self.firebaseEmulatorKey] = "1"
        super.launch()
    }

    /// 前に出す（起動していなければ起動する。そのときも目印が乗るよう、先に入れておく）
    override func activate() {
        launchEnvironment[Self.firebaseEmulatorKey] = "1"
        super.activate()
    }
}
