//
//  StorageImageURLTests.swift
//  SoramoyouTests
//
//  Firebase Storage の画像の URL の確かめのテスト ⭐️
//
//  - 通すのは、決まり（Policy）の scheme・ホスト・ポート・バケットに合い、パスがちょうど /v0/b/<バケット>/o/<名前> の URL だけ
//  - 本番の決まりのポートは「無し」と 443 の 2 つだけ
//  - 通した URL は URL(string:) と同じ値のまま返す
//  - 決まりが無いときは何も通さない
//  期待する値は、ここに直接書く（入力から作った値どうしを比べると、何もしない実装でも緑になるため）
//

import FirebaseCore
@testable import Soramoyou
import XCTest

final class StorageImageURLTests: XCTestCase {
    // MARK: - 決まり

    /// 本番と同じ決まり
    private let production = StorageImageURL.Policy(
        scheme: "https",
        host: "firebasestorage.googleapis.com",
        ports: [nil, 443],
        bucket: "soramoyou-ios.firebasestorage.app"
    )

    /// テストの Emulator と同じ決まり
    private let emulator = StorageImageURL.Policy(
        scheme: "http",
        host: "127.0.0.1",
        ports: [9199],
        bucket: "demo-soramoyou-security.appspot.com"
    )

    /// 本番に入っている形（ホストのあとに :443）
    private let productionURLWith443 =
        "https://firebasestorage.googleapis.com:443/v0/b/soramoyou-ios.firebasestorage.app/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1"

    // MARK: - 通す形

    func testAcceptsProductionURLWithPort443() {
        // 本番に入っている :443 付きの形を、そのままの値で通す
        XCTAssertEqual(
            StorageImageURL.url(from: productionURLWith443, policy: production)?.absoluteString,
            "https://firebasestorage.googleapis.com:443/v0/b/soramoyou-ios.firebasestorage.app/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t1"
        )
    }

    func testAcceptsProductionURLWithoutPort() {
        // ポートの書かれていない形も、そのままの値で通す
        XCTAssertEqual(
            StorageImageURL.url(
                from: "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/thumbnails%2Fu1%2Fpublic%2Fa_thumb.jpg?alt=media&token=t2",
                policy: production
            )?.absoluteString,
            "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/thumbnails%2Fu1%2Fpublic%2Fa_thumb.jpg?alt=media&token=t2"
        )
    }

    func testAcceptsEmulatorURL() {
        // Emulator の決まりでは http・127.0.0.1:9199 の形を通す
        XCTAssertEqual(
            StorageImageURL.url(
                from: "http://127.0.0.1:9199/v0/b/demo-soramoyou-security.appspot.com/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t3",
                policy: emulator
            )?.absoluteString,
            "http://127.0.0.1:9199/v0/b/demo-soramoyou-security.appspot.com/o/posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=t3"
        )
    }

    // MARK: - 通さない形

    func testPort8443IsNotAccepted() {
        // 本番の決まりのポートは「無し」と 443 だけ
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com:8443/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
    }

    func testAcceptsOnlyPolicyPortsForEmulator() {
        // Emulator の決まりのポートは 9199 だけ（書かれていない形も通さない）
        XCTAssertNil(StorageImageURL.url(
            from: "http://127.0.0.1/v0/b/demo-soramoyou-security.appspot.com/o/a.jpg",
            policy: emulator
        ))
        XCTAssertNil(StorageImageURL.url(
            from: "http://127.0.0.1:9198/v0/b/demo-soramoyou-security.appspot.com/o/a.jpg",
            policy: emulator
        ))
    }

    func testAcceptsOnlyPolicyScheme() {
        // 本番の決まりでは https だけ通す
        XCTAssertNil(StorageImageURL.url(
            from: "http://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
    }

    func testAcceptsOnlyPolicyHostExactly() {
        // ホストは決まりと完全一致のものだけ通す
        XCTAssertNil(StorageImageURL.url(
            from: "https://example.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com.example.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
        XCTAssertNil(StorageImageURL.url(
            from: "https://storage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
    }

    func testAcceptsOnlyPolicyBucket() {
        // バケットは soramoyou-ios.firebasestorage.app の 1 つだけ（appspot.com の別名も通さない）
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.appspot.com/o/a.jpg",
            policy: production
        ))
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com/v0/b/other-project.firebasestorage.app/o/a.jpg",
            policy: production
        ))
    }

    func testAcceptsOnlyStorageObjectPath() {
        // パスはちょうど /v0/b/<バケット>/o/<名前> だけ通す
        // 名前の中の / が %2F になっていない
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/posts/u1/public/a.jpg",
            policy: production
        ))
        // 名前が空
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/",
            policy: production
        ))
        // 前に余計な段がある
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com/x/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
        // 版が v0 でない
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com/v1/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
        // o の段が無い
        XCTAssertNil(StorageImageURL.url(
            from: "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/a.jpg",
            policy: production
        ))
    }

    func testAcceptsOnlyURLWithoutUserInfo() {
        // ホストの前に利用者名・パスワードが付いていない形だけ通す
        XCTAssertNil(StorageImageURL.url(
            from: "https://user@firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
        XCTAssertNil(StorageImageURL.url(
            from: "https://user:pass@firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/a.jpg",
            policy: production
        ))
    }

    func testAcceptsNothingForEmptyInput() {
        // 値が無い・空の文字列は通さない
        XCTAssertNil(StorageImageURL.url(from: nil, policy: production))
        XCTAssertNil(StorageImageURL.url(from: "", policy: production))
    }

    func testAcceptsNothingWithoutPolicy() {
        // 決まりが無いときは、本番の形でも通さない
        XCTAssertNil(StorageImageURL.url(from: productionURLWith443, policy: nil))
    }

    // MARK: - 決まりの作り方

    /// projectID と storageBucket だけを変えた接続情報（plist は読まない）
    private func options(projectID: String?, storageBucket: String?) -> FirebaseOptions {
        let options = FirebaseOptions(googleAppID: "1:1234567890:ios:0000000000000000", gcmSenderID: "1234567890")
        options.projectID = projectID
        options.storageBucket = storageBucket
        return options
    }

    func testPolicyFromProductionOptions() {
        // 本番の接続情報からは、https・firebasestorage.googleapis.com・ポート無しか 443・storageBucket の決まり
        XCTAssertEqual(
            StorageImageURL.policy(from: options(projectID: "soramoyou-ios", storageBucket: "soramoyou-ios.firebasestorage.app")),
            production
        )
    }

    func testPolicyFromEmulatorOptions() {
        // Emulator の接続情報からは、http・127.0.0.1:9199・storageBucket の決まり
        XCTAssertEqual(
            StorageImageURL.policy(from: options(
                projectID: "demo-soramoyou-security",
                storageBucket: "demo-soramoyou-security.appspot.com"
            )),
            emulator
        )
    }

    func testNoPolicyWithoutOptionsOrBucket() {
        // 接続情報・storageBucket が無いときは決まりを作らない
        XCTAssertNil(StorageImageURL.policy(from: nil))
        XCTAssertNil(StorageImageURL.policy(from: options(projectID: "soramoyou-ios", storageBucket: nil)))
        XCTAssertNil(StorageImageURL.policy(from: options(projectID: "soramoyou-ios", storageBucket: "")))
    }

    func testLiveIsEmulatorPolicyDuringTests() {
        // テストは Emulator の接続情報で動く（FirebaseEmulatorSwitch）ので、live は Emulator の決まり
        XCTAssertEqual(StorageImageURL.live, emulator)
    }

    // MARK: - 今の決まり（live）で確かめる版（アイコンなど）

    func testLiveVersionAcceptsEmulatorURLDuringTests() {
        // テスト中の live は Emulator の決まりなので、Emulator の形をそのままの値で通す
        XCTAssertEqual(
            StorageImageURL.url(
                from: "http://127.0.0.1:9199/v0/b/demo-soramoyou-security.appspot.com/o/profile_images%2Fu1%2Fprofile.jpg?alt=media&token=t4"
            )?.absoluteString,
            "http://127.0.0.1:9199/v0/b/demo-soramoyou-security.appspot.com/o/profile_images%2Fu1%2Fprofile.jpg?alt=media&token=t4"
        )
    }

    func testLiveVersionAcceptsOnlyLivePolicy() {
        // live の決まりに合わない URL は通さない（テスト中は本番の形も通さない）
        XCTAssertNil(StorageImageURL.url(from: "https://example.com/v0/b/demo-soramoyou-security.appspot.com/o/a.jpg"))
        XCTAssertNil(StorageImageURL.url(from: "http://127.0.0.1:9199/v0/b/other-bucket.appspot.com/o/a.jpg"))
        XCTAssertNil(StorageImageURL.url(from: productionURLWith443))
    }

    func testLiveVersionAcceptsNothingForEmptyInput() {
        // 値が無い・空の文字列は通さない
        XCTAssertNil(StorageImageURL.url(from: nil))
        XCTAssertNil(StorageImageURL.url(from: ""))
    }
}
