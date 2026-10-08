//
//  SoratomoAccountDeletionServiceTests.swift
//  SoramoyouTests
//
//  退会のそらとも分のサービス（SoratomoAccountDeletionService）のテスト ⭐️（release-gate 9.4）
//  - 送る Callable の名前・値・制限時間
//  - 完了が返るまで呼び続けること、完了が返ったらそれ以上呼ばないこと
//  - 8 回で終わらないときの `.incomplete` と文言
//  - 失敗の写し（通信・制限時間切れ → `.network`、それ以外 → `.unknown`）と、失敗したら呼び直さないこと
//  - 戻り値の形が違うとき
//
//  ⚠️ Functions には接続しない。窓口（SoratomoAccountDeletionDataSource）を偽物に差し替える。
//

import FirebaseFunctions
@testable import Soramoyou
import XCTest

// MARK: - 偽物

/// 窓口の偽物（呼ばれた引数を記録し、決めた結果を順に返す。使い切ったら最後の結果を返し続ける）
private final class FakeAccountDeletionDataSource: SoratomoAccountDeletionDataSource, @unchecked Sendable {
    // 返す結果（呼ばれた順）
    var results: [Result<Any, Error>] = [.success(["done": true])]

    // 呼ばれた引数
    private(set) var calls: [(name: String, payload: [String: Any], timeout: TimeInterval)] = []

    func callCallable(_ name: String, payload: [String: Any], timeout: TimeInterval) async throws -> Any {
        calls.append((name, payload, timeout))
        let index = min(calls.count - 1, results.count - 1)
        return try results[index].get()
    }
}

final class SoratomoAccountDeletionServiceTests: XCTestCase {
    // MARK: - 部品

    private var dataSource: FakeAccountDeletionDataSource!
    private var service: SoratomoAccountDeletionService!

    override func setUp() {
        super.setUp()
        resetParts()
    }

    /// 偽物とサービスを作り直す（1 つのテストで複数の場合を流すときにも使う）
    private func resetParts() {
        dataSource = FakeAccountDeletionDataSource()
        service = SoratomoAccountDeletionService(dataSource: dataSource)
    }

    override func tearDown() {
        service = nil
        dataSource = nil
        super.tearDown()
    }

    /// Callable が返す失敗
    private func functionsError(_ code: FunctionsErrorCode) -> NSError {
        NSError(
            domain: FunctionsErrorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "サーバーの文言（画面に出さない）"]
        )
    }

    /// 投げた失敗（投げなければ nil）
    private func deletionError() async -> SoratomoAccountDeletionError? {
        do {
            try await service.deleteMyData()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - 送るもの

    /// Callable の名前は soratomoDeleteMyData、値は空、制限時間は 75 秒（design.md の退会）
    func testDeleteSendsCallableNameEmptyPayloadAndTimeout() async {
        let error = await deletionError()

        XCTAssertNil(error)
        XCTAssertEqual(dataSource.calls.count, 1, "1 回目で完了したら、それ以上呼ばない")
        XCTAssertEqual(dataSource.calls.first?.name, "soratomoDeleteMyData")
        XCTAssertEqual(dataSource.calls.first?.payload.isEmpty, true)
        XCTAssertEqual(dataSource.calls.first?.timeout, 75)
        XCTAssertEqual(SoratomoAccountDeletionService.maxCalls, 8)
    }

    // MARK: - 呼び直し

    /// ⭐️ 完了（done: true）が返るまで呼び続ける。返ったら止める
    func testDeleteCallsAgainUntilDone() async {
        dataSource.results = [
            .success(["done": false]),
            .success(["done": false]),
            .success(["done": false]),
            .success(["done": true]),
            .success(["done": false]), // 呼ばれないはず
        ]

        let error = await deletionError()

        XCTAssertNil(error)
        XCTAssertEqual(dataSource.calls.count, 4)
    }

    /// ⭐️ 8 回呼んでも終わらなければ `.incomplete`。9 回目は呼ばない。文言は「時間をおいて」
    func testDeleteGivesUpAfterMaxCallsWithIncomplete() async {
        dataSource.results = [.success(["done": false])]

        let error = await deletionError()

        XCTAssertEqual(error, .incomplete)
        XCTAssertEqual(dataSource.calls.count, 8)
        XCTAssertEqual(error?.errorDescription, "時間をおいてもう一度お試しください")
    }

    /// 8 回目で完了すれば成功
    func testDeleteSucceedsWhenDoneOnLastCall() async {
        dataSource.results = Array(repeating: .success(["done": false]), count: 7) + [.success(["done": true])]

        let error = await deletionError()

        XCTAssertNil(error)
        XCTAssertEqual(dataSource.calls.count, 8)
    }

    // MARK: - 失敗の写し

    /// 通信・制限時間切れは `.network`（文言は「通信できませんでした」）。失敗したら呼び直さない
    func testDeleteMapsNetworkFailuresToNetworkWithoutRetrying() async {
        let cases: [Error] = [
            functionsError(.unavailable),
            functionsError(.deadlineExceeded),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
        ]
        for failure in cases {
            resetParts()
            dataSource.results = [.failure(failure), .success(["done": true])]

            let error = await deletionError()

            XCTAssertEqual(error, .network, "\(failure)")
            XCTAssertEqual(dataSource.calls.count, 1, "失敗したら呼び直さない: \(failure)")
            XCTAssertEqual(error?.errorDescription, "通信できませんでした。インターネットにつながる場所でもう一度お試しください")
        }
    }

    /// 通信以外の失敗（未ログイン・サーバーの失敗など）は `.unknown`
    func testDeleteMapsOtherFailuresToUnknown() async {
        let cases: [Error] = [
            functionsError(.unauthenticated),
            functionsError(.internal),
            NSError(domain: "other", code: 1),
        ]
        for failure in cases {
            resetParts()
            dataSource.results = [.failure(failure)]

            let error = await deletionError()

            XCTAssertEqual(error, .unknown, "\(failure)")
            XCTAssertEqual(error?.errorDescription, "時間をおいてもう一度お試しください")
        }
    }

    /// 途中の回で失敗したら、そこで止めて失敗を投げる
    func testDeleteStopsOnFailureAfterPartialProgress() async {
        dataSource.results = [.success(["done": false]), .failure(functionsError(.unavailable))]

        let error = await deletionError()

        XCTAssertEqual(error, .network)
        XCTAssertEqual(dataSource.calls.count, 2)
    }

    /// 戻り値の形が違えば `.unknown`（呼び直さない）
    func testDeleteRejectsMalformedResponse() async {
        let cases: [Any] = [["done": "true"], ["ok": true], "done", NSNull()]
        for response in cases {
            resetParts()
            dataSource.results = [.success(response)]

            let error = await deletionError()

            XCTAssertEqual(error, .unknown, "\(response)")
            XCTAssertEqual(dataSource.calls.count, 1)
        }
    }
}
