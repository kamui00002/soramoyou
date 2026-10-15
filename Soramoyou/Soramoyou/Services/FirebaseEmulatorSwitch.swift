//
//  FirebaseEmulatorSwitch.swift
//  Soramoyou
//
//  テストのときだけ、Firebase の接続先を Emulator（手元の Mac で動く偽物の Firebase）へ切り替える ⭐️
//  （セキュリティ監査 2026-10-14 の 5-1・REPORT §7 ② (a)）
//
//  - なぜ要るか：これが無いと、テストは GoogleService-Info.plist の接続先＝本番につながる
//    （アカウント作成・画像のアップロード・投稿の書き込み・通報が本番に残る）
//  - 単体テスト（SoramoyouTests）はアプリの中で動く（TEST_HOST）ので、Xcode が入れる環境変数で気づける
//  - UI テスト（SoramoyouUITests）はアプリが別のプロセスで動くので、テスト側が
//    launchEnvironment["SORAMOYOU_FIREBASE_EMULATOR"] = "1" を渡す。渡すのは UI テストのターゲットにある
//    同じ名前の XCUIApplication（SoramoyouUITests/XCUIApplication.swift）で、起動のたびに必ず入れる。
//    ⚠️ その版を通らずに起動した UI テストは、普段の起動と同じく本番につながる
//       （通らない書き方は scripts/check-uitests-launch-guard.sh が CI で見張る）
//  - 本当に切り替わったかは、画面の見えない目印（FirebaseConnectionMarker）で UI テストから読める
//  - 本番に落ちない作り（fail closed）：
//    ① 接続情報のプロジェクト ID と API キーを demo- の偽物に差し替える。切り替えを忘れた部品が
//       Google に届いても、存在しないプロジェクトなので拒否される
//    ② 4 つの部品（Auth・Firestore・Storage・Functions）を 127.0.0.1 へ向ける。Emulator が
//       動いていなければ、つながらずにテストが落ちる（本番へは行かない）
//  - ファイル全体を DEBUG だけにする（App Store に出す版には入らない）
//

#if DEBUG
    import FirebaseAuth
    import FirebaseCore
    import FirebaseFirestore
    import FirebaseFunctions
    import FirebaseStorage
    import Foundation
    import SwiftUI

    enum FirebaseEmulatorSwitch {
        // MARK: - 接続先

        /// テストで使うプロジェクト ID。CI（functions の test:emulator）と同じ名前にそろえる。
        /// demo- で始まる ID は Firebase に本物として存在しないので、Google に届いても拒否される
        static let projectID = "demo-soramoyou-security"

        /// Emulator の宛先。localhost だとシミュレーターが IPv6（::1）を先に引いて、
        /// 127.0.0.1 で待っている Emulator につながらないことがあるため、数字で書く
        static let host = "127.0.0.1"

        /// ポートは firebase.json の emulators と同じ値。Functions は firebase.json に無いが、
        /// firebase-tools の既定（5001）へ向けておく（動いていなければ、つながらずに落ちる）
        static let authPort = 9099
        static let firestorePort = 8080
        static let storagePort = 9199
        static let functionsPort = 5001

        /// UI テストがアプリに渡す目印（環境変数の名前）
        static let uiTestEnvironmentKey = "SORAMOYOU_FIREBASE_EMULATOR"

        /// 偽の API キー。Firebase の部品の中には、API キーが「A で始まる 39 文字」の形かを
        /// 起動時に確かめるものがあるため、形だけ合わせる（本物の鍵の書き出し AIza は使わない）
        private static let fakeAPIKey = "AdemoSoramoyouSecurityFakeKey0000000000"

        // MARK: - テスト中かどうか

        /// テスト中だと分かる目印のうち、見つかったものの名前を返す（空ならテスト中ではない）
        /// - Parameters:
        ///   - environment: プロセスの環境変数（ProcessInfo.processInfo.environment）
        ///   - xctestLoaded: XCTest がこのプロセスに読み込まれているか
        /// - Returns: 見つかった目印の名前。どれで気づいたかをログに出すために使う
        static func testSignals(environment: [String: String], xctestLoaded: Bool) -> [String] {
            // 単体テストのとき Xcode が入れる環境変数。Xcode の版で名前が変わっても拾えるよう 3 つ見る
            let xcodeKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            var signals = xcodeKeys.filter { environment[$0] != nil }
            if xctestLoaded {
                signals.append("XCTestCase")
            }
            if environment[uiTestEnvironmentKey] == "1" {
                signals.append(uiTestEnvironmentKey)
            }
            return signals
        }

        // MARK: - 切り替え

        /// テスト用の接続情報で Firebase を始め、4 つの部品を Emulator へ向ける。
        /// ⚠️ FirebaseApp.configure() の代わりに呼ぶ。どの部品も、ここより前に使ってはいけない
        ///    （Firestore は使い始めた後に宛先を変えるとクラッシュする）
        /// - Parameter signals: testSignals(environment:xctestLoaded:) の結果（ログに出すだけ）
        static func configureForTesting(signals: [String]) {
            // plist を読めないときは、本番の設定にも偽物にもせず、その場で止める
            guard let options = FirebaseOptions.defaultOptions() else {
                fatalError("テスト中なのに GoogleService-Info.plist を読めません。Emulator に切り替えられないので止めます")
            }
            // ① 接続情報を偽物に差し替える。
            //    アプリの ID（googleAppID）と送信者 ID は plist のまま（起動時の形の確かめで落ちないように）
            options.projectID = projectID
            options.apiKey = fakeAPIKey
            options.storageBucket = "\(projectID).appspot.com"
            FirebaseApp.configure(options: options)

            // ② 4 つの部品を Emulator へ向ける
            Auth.auth().useEmulator(withHost: host, port: authPort)

            // Firestore は設定を作り直して丸ごと渡す。キャッシュはメモリだけにして、
            // 前のテストの実行で残ったデータを持ち込まない
            let settings = FirestoreSettings()
            settings.host = "\(host):\(firestorePort)"
            settings.isSSLEnabled = false
            settings.cacheSettings = MemoryCacheSettings()
            Firestore.firestore().settings = settings

            Storage.storage().useEmulator(withHost: host, port: storagePort)

            // Functions は region ごとに別の部品になる。アプリ（そらとも）は全部この region を使うので、
            // 同じ region の部品に掛ける（region なしの Functions.functions() に掛けても効かない）
            Functions.functions(region: SoratomoGroupService.region)
                .useEmulator(withHost: host, port: functionsPort)

            print("🧪 テスト中なので Firebase を Emulator（\(host)・\(projectID)）へ切り替えました。目印: \(signals.joined(separator: ", "))")
        }

        // MARK: - 切り替わったかの確かめ

        /// 今の Firebase が Emulator を向いているか。設定を覚えておくのでなく、実際の部品の設定を読み直す。
        /// Auth と Storage は宛先を読む口が無いので、読める 3 つ（接続情報・Firestore・Functions）で代表させる
        static var isActive: Bool {
            // 普段の Debug 実行は本物の ID なので、ここで止まる（Firestore などには触らない）
            guard FirebaseApp.app()?.options.projectID == projectID else { return false }
            return Firestore.firestore().settings.host == "\(host):\(firestorePort)"
                && Functions.functions(region: SoratomoGroupService.region).emulatorOrigin
                == "http://\(host):\(functionsPort)"
        }
    }

    /// 接続先の目印（見えない・押せない）⭐️
    /// UI テストは識別子 firebase-connection の要素を探し、文字が emulator であることを確かめる。
    /// Debug では切り替えの有無にかかわらず出しておく。文字が production なら「本番につながった」、
    /// 要素が見つからなければ「目印の作りが壊れている」と、落ちた理由を分けて読めるようにするため
    struct FirebaseConnectionMarker: View {
        static let identifier = "firebase-connection"

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(FirebaseEmulatorSwitch.isActive ? "emulator" : "production")
                .accessibilityIdentifier(Self.identifier)
                .allowsHitTesting(false)
        }
    }
#endif
