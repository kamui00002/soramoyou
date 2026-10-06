//
//  SoratomoProfileServiceTests.swift
//  SoramoyouTests
//
//  表示名とそらとも通知の保存（SoratomoProfileService）のテスト ⭐️（tasks 11.5）
//
//  Firestore の読み書きは `SoratomoProfileDataSource` の差し替えで済ませる（トランザクションそのものは、
//  Firestore エミュレーターが無いと試せないので、ここでは「どう書くか」を決める純関数だけを確かめる）。
//  確かめること:
//  - 表示名が要るかの判定（前後の空白を除く・すでにある名前は要らない）
//  - 保存の失敗（通信を含む）が SoratomoError として返ること（読み取りは `.read`・書き込みは `.write` の写し）
//  - 保存に渡る値（前後の空白を除いた表示名・uid・そらとも通知のオンオフ）
//  - すでに名前がある・文書が無いときの書き方の判断
//

import FirebaseFirestore
@testable import Soramoyou
import XCTest

final class SoratomoProfileServiceTests: XCTestCase {
    // MARK: - 補助

    /// 表示名を返す・保存する窓口の代役（返す結果を先に決め、呼ばれた引数を記録する）
    private final class SoratomoProfileDataSourceStub: SoratomoProfileDataSource, @unchecked Sendable {
        var displayNameResult: Result<String?, Error> = .success(nil)
        var saveResult: Result<Void, Error> = .success(())
        var notifyResult: Result<Void, Error> = .success(())

        private(set) var fetchCalls: [String] = []
        private(set) var saveCalls: [(uid: String, displayName: String)] = []
        private(set) var notifyCalls: [(uid: String, enabled: Bool)] = []

        func fetchUserDisplayName(uid: String) async throws -> String? {
            fetchCalls.append(uid)
            return try displayNameResult.get()
        }

        func saveDisplayName(uid: String, displayName: String) async throws {
            saveCalls.append((uid, displayName))
            try saveResult.get()
        }

        func setNotifySoratomo(uid: String, enabled: Bool) async throws {
            notifyCalls.append((uid, enabled))
            try notifyResult.get()
        }
    }

    private let stub = SoratomoProfileDataSourceStub()

    private var service: SoratomoProfileService {
        SoratomoProfileService(dataSource: stub)
    }

    /// 検証を通った表示名を作る（`SoratomoDisplayName` は検証の窓口からしか作れない）
    private func makeName(_ raw: String) throws -> SoratomoDisplayName {
        switch SoratomoTextRules.validateDisplayName(raw) {
        case let .success(name):
            return name
        case let .failure(error):
            throw error
        }
    }

    private func firestoreError(_ code: FirestoreErrorCode.Code) -> NSError {
        NSError(domain: FirestoreErrorDomain, code: code.rawValue)
    }

    /// 機内モード・圏外の通信エラー
    private var offlineError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
    }

    /// 投げられたエラーを `SoratomoError` として取り出す（`SoratomoError` 以外なら nil）
    private func soratomoError(_ error: Error) -> SoratomoError? {
        error as? SoratomoError
    }

    /// 書き込みの失敗の写し（保存・そらとも通知で共通）。⚠️ 権限の拒否は `.permissionDenied` のまま
    private var writeFailureCases: [(underlying: Error, expected: SoratomoError)] {
        [
            (offlineError, .network),
            (firestoreError(.unavailable), .network),
            (firestoreError(.deadlineExceeded), .network),
            (firestoreError(.permissionDenied), .permissionDenied),
            (firestoreError(.unauthenticated), .permissionDenied),
            (firestoreError(.notFound), .unknown),
            (NSError(domain: "other", code: 1), .unknown),
            // トランザクションの中で「利用者の文書が無い」を失敗にしたときのエラー
            (NSError(domain: "SoratomoProfileFirestoreDataSource", code: 404), .unknown),
            // すでに SoratomoError ならそのまま
            (SoratomoError.displayNameInvalid, .displayNameInvalid),
        ]
    }

    // MARK: - 表示名が要るか

    func testNeedsDisplayNameIsTrueForMissingOrBlankName() async throws {
        // 無い・空・空白だけ・改行だけ・全角の空白だけは「要る」（要件 18.1）
        let blankNames: [String?] = [nil, "", "   ", "\n", " \n\t ", "\u{3000}"]
        for raw in blankNames {
            stub.displayNameResult = .success(raw)
            let needs = try await service.needsDisplayName(uid: "u1")
            XCTAssertTrue(needs, "raw=\(String(describing: raw))")
        }
        XCTAssertEqual(stub.fetchCalls, Array(repeating: "u1", count: blankNames.count))
    }

    func testNeedsDisplayNameIsFalseWhenNameIsSet() async throws {
        // 前後に空白があっても、中身があれば「要らない」。20 文字を超える既存の名前（50 文字まで）も「要らない」（要件 18.6）
        let longName = String(repeating: "あ", count: 50)
        for raw in ["そら", " そら ", longName] {
            stub.displayNameResult = .success(raw)
            let needs = try await service.needsDisplayName(uid: "u1")
            XCTAssertFalse(needs, "raw=\(raw)")
        }
    }

    func testNeedsDisplayNameFailuresBecomeSoratomoError() async {
        // 読み取りの失敗: 通信は `.network`、権限の拒否は `.notMember`（読み取りの写し）
        let cases: [(underlying: Error, expected: SoratomoError)] = [
            (offlineError, .network),
            (firestoreError(.unavailable), .network),
            (firestoreError(.deadlineExceeded), .network),
            (firestoreError(.permissionDenied), .notMember),
            (firestoreError(.unauthenticated), .permissionDenied),
            (NSError(domain: "other", code: 1), .unknown),
        ]
        for (underlying, expected) in cases {
            stub.displayNameResult = .failure(underlying)
            do {
                _ = try await service.needsDisplayName(uid: "u1")
                XCTFail("失敗するはず: \(expected)")
            } catch {
                XCTAssertEqual(soratomoError(error), expected)
            }
        }
    }

    // MARK: - 表示名の保存

    func testSaveDisplayNamePassesUidAndTrimmedName() async throws {
        // 検証を通った（前後の空白を除いた）表示名が、そのまま保存の窓口に渡る
        let name = try makeName("  そら  ")

        try await service.saveDisplayName(uid: "u1", name: name)

        XCTAssertEqual(stub.saveCalls.count, 1)
        XCTAssertEqual(stub.saveCalls.first?.uid, "u1")
        XCTAssertEqual(stub.saveCalls.first?.displayName, "そら")
    }

    func testSaveDisplayNameFailuresBecomeSoratomoError() async throws {
        // 保存の失敗（通信を含む）は、先へ進ませないために SoratomoError として返る（要件 18.5）
        let name = try makeName("そら")
        for (underlying, expected) in writeFailureCases {
            stub.saveResult = .failure(underlying)
            do {
                try await service.saveDisplayName(uid: "u1", name: name)
                XCTFail("失敗するはず: \(expected)")
            } catch {
                XCTAssertEqual(soratomoError(error), expected)
            }
        }
        XCTAssertEqual(stub.saveCalls.count, writeFailureCases.count)
    }

    // MARK: - そらとも通知の保存

    func testSetNotifySoratomoPassesUidAndFlag() async throws {
        try await service.setNotifySoratomo(uid: "u1", enabled: true)
        try await service.setNotifySoratomo(uid: "u1", enabled: false)

        XCTAssertEqual(stub.notifyCalls.map(\.uid), ["u1", "u1"])
        XCTAssertEqual(stub.notifyCalls.map(\.enabled), [true, false])
    }

    func testSetNotifySoratomoFailuresBecomeSoratomoError() async {
        for (underlying, expected) in writeFailureCases {
            stub.notifyResult = .failure(underlying)
            do {
                try await service.setNotifySoratomo(uid: "u1", enabled: true)
                XCTFail("失敗するはず: \(expected)")
            } catch {
                XCTAssertEqual(soratomoError(error), expected)
            }
        }
        XCTAssertEqual(stub.notifyCalls.count, writeFailureCases.count)
    }

    // MARK: - uid が空（ログインしていない）

    func testEmptyUidFailsWithoutTouchingFirestore() async throws {
        // Firestore は空のドキュメント ID で落ちるので、窓口を呼ばずに認証の失敗と同じ `.permissionDenied` にする
        let name = try makeName("そら")

        do {
            _ = try await service.needsDisplayName(uid: "")
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(soratomoError(error), .permissionDenied)
        }
        do {
            try await service.saveDisplayName(uid: "", name: name)
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(soratomoError(error), .permissionDenied)
        }
        do {
            try await service.setNotifySoratomo(uid: "", enabled: true)
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(soratomoError(error), .permissionDenied)
        }

        XCTAssertTrue(stub.fetchCalls.isEmpty)
        XCTAssertTrue(stub.saveCalls.isEmpty)
        XCTAssertTrue(stub.notifyCalls.isEmpty)
    }

    // MARK: - 保存のトランザクションの中の判断（純関数）

    func testWritePlanKeepsExistingName() {
        // すでに名前がある（50 文字までを含む）なら、何も書かない（要件 18.6・すでにある名前は変えない）
        let longName = String(repeating: "あ", count: 50)
        for existing in ["そら", " そら ", longName] {
            XCTAssertEqual(
                SoratomoProfileService.displayNameWritePlan(userDocumentExists: true, existingDisplayName: existing),
                .keepExisting,
                "existing=\(existing)"
            )
        }
    }

    func testWritePlanWritesWhenNameIsMissingOrBlank() {
        let blankNames: [String?] = [nil, "", "   ", "\n", "\u{3000}"]
        for existing in blankNames {
            XCTAssertEqual(
                SoratomoProfileService.displayNameWritePlan(userDocumentExists: true, existingDisplayName: existing),
                .write,
                "existing=\(String(describing: existing))"
            )
        }
    }

    func testWritePlanFailsWhenUserDocumentIsMissing() {
        // 利用者の文書が無いときは、文書全体を作らずに失敗にする（名前が入っていても書けない）
        XCTAssertEqual(
            SoratomoProfileService.displayNameWritePlan(userDocumentExists: false, existingDisplayName: nil),
            .userDocumentMissing
        )
        XCTAssertEqual(
            SoratomoProfileService.displayNameWritePlan(userDocumentExists: false, existingDisplayName: "そら"),
            .userDocumentMissing
        )
    }
}
