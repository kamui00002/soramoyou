//
//  FirebaseEmulatorSwitchTests.swift
//  SoramoyouTests
//
//  テストのときに Firebase の接続先が Emulator へ切り替わっているかのテスト ⭐️
//  （セキュリティ監査 2026-10-14 の 5-1・REPORT §7 ②）
//
//  - ネットワークは使わない。設定を読むだけなので、Emulator が動いていなくても結果は変わらない
//  - 単体テストはアプリの中で動く（TEST_HOST）。アプリの起動処理（SoramoyouApp.init）が
//    切り替えを済ませた後の状態を、ここで読む
//  - Firebase を使う他のテストより先に、これを 1 本だけ回して緑を確かめる
//

#if DEBUG
    import FirebaseCore
    import FirebaseFirestore
    import FirebaseFunctions
    @testable import Soramoyou
    import XCTest

    final class FirebaseEmulatorSwitchTests: XCTestCase {
        // MARK: - テスト中かどうかの判定

        /// 目印が 1 つも無ければ、テスト中とみなさない（普段の起動は本番につなぐ）
        func testNoSignalsWhenNothingIsSet() {
            let signals = FirebaseEmulatorSwitch.testSignals(environment: [:], xctestLoaded: false)
            XCTAssertTrue(signals.isEmpty)
        }

        /// 関係ない環境変数や、"1" 以外の値では気づかない
        func testIgnoresUnrelatedValues() {
            let signals = FirebaseEmulatorSwitch.testSignals(
                environment: ["PATH": "/usr/bin", "SORAMOYOU_FIREBASE_EMULATOR": "0"],
                xctestLoaded: false
            )
            XCTAssertTrue(signals.isEmpty)
        }

        /// Xcode が入れる 3 つの環境変数は、どれか 1 つでも気づく
        func testDetectsEachXcodeKey() {
            for key in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
                let signals = FirebaseEmulatorSwitch.testSignals(environment: [key: "x"], xctestLoaded: false)
                XCTAssertEqual(signals, [key], "\(key) だけを入れたとき")
            }
        }

        /// XCTest が読み込まれていれば気づく
        func testDetectsLoadedXCTest() {
            let signals = FirebaseEmulatorSwitch.testSignals(environment: [:], xctestLoaded: true)
            XCTAssertEqual(signals, ["XCTestCase"])
        }

        /// UI テストの目印（"1"）で気づく
        func testDetectsUITestEnvironmentKey() {
            let signals = FirebaseEmulatorSwitch.testSignals(
                environment: ["SORAMOYOU_FIREBASE_EMULATOR": "1"],
                xctestLoaded: false
            )
            XCTAssertEqual(signals, ["SORAMOYOU_FIREBASE_EMULATOR"])
        }

        // MARK: - アプリの起動処理が本当に切り替えたか

        /// 接続情報のプロジェクト ID とバケットが demo- の偽物になっている
        func testAppUsesDemoProject() throws {
            let options = try XCTUnwrap(FirebaseApp.app()?.options, "Firebase が始まっていない")
            XCTAssertEqual(options.projectID, "demo-soramoyou-security")
            XCTAssertEqual(options.storageBucket, "demo-soramoyou-security.appspot.com")
        }

        /// Firestore の宛先が Emulator になっている（SSL なし・キャッシュはメモリだけ）
        func testFirestorePointsToEmulator() {
            let settings = Firestore.firestore().settings
            XCTAssertEqual(settings.host, "127.0.0.1:8080")
            XCTAssertFalse(settings.isSSLEnabled)
            XCTAssertTrue(settings.cacheSettings is MemoryCacheSettings)
        }

        /// そらともが使う region の Functions が Emulator を向いている。
        /// 呼ぶたびに新しい部品が作られる作りだと、ここで nil になる（切り替えが効いていない）
        func testFunctionsPointsToEmulator() {
            let functions = Functions.functions(region: SoratomoGroupService.region)
            XCTAssertEqual(functions.emulatorOrigin, "http://127.0.0.1:5001")
        }

        /// 画面の目印が読む判定も、切り替わったと答える
        func testIsActive() {
            XCTAssertTrue(FirebaseEmulatorSwitch.isActive)
        }
    }
#endif
