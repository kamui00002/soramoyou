//
//  BatchDrainerTests.swift
//  SoramoyouTests
//
//  「取得 → 削除」を繰り返すドレインループの単体テスト ⭐️
//
//  退会処理で follows を消すときに使う制御構造。Firestore に触らない純粋なループなので、
//  ここだけは実データ・エミュレータ無しで検証できる。壊れやすい条件は次の 4 つ:
//    ① いつ終わるか（空 / 最終ページ）
//    ② 全件消えるか（複数ページ）
//    ③ 削除が効かないときに無限ループしないか
//    ④ fetch / delete の失敗がそのまま呼び出し側へ伝わり、途中で止まるか
//

import XCTest
@testable import Soramoyou

/// テスト用のエラー（fetch 側と delete 側のどちらが投げたかを区別する）
private enum StubError: Error, Equatable {
    case fetchFailed
    case deleteFailed
}

/// 取得と削除を模したインメモリのスタブ。
/// 「実際に消える」ことで終了判定まで含めて検証できる。
private actor FakeStore {
    private(set) var items: [Int]
    private(set) var fetchCount = 0
    private(set) var deleteCount = 0
    /// true にすると delete が何もしない（＝削除が無言で効かない障害の再現）
    private let deleteIsNoop: Bool
    /// 設定すると fetch がこのエラーを投げる（＝permission-denied や通信断の再現）
    private let fetchError: Error?
    /// 設定すると delete がこのエラーを投げる（＝バッチ commit 失敗の再現）
    private let deleteError: Error?

    init(count: Int, deleteIsNoop: Bool = false, fetchError: Error? = nil, deleteError: Error? = nil) {
        items = Array(0 ..< count)
        self.deleteIsNoop = deleteIsNoop
        self.fetchError = fetchError
        self.deleteError = deleteError
    }

    /// 常に先頭から取り直す（カーソルを使わない本番実装と同じ振る舞い）
    /// 呼ばれた回数は失敗時も数える（「何回目で落ちたか」を検証するため）。
    func fetch(pageSize: Int) throws -> [Int] {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return Array(items.prefix(pageSize))
    }

    func delete(_ targets: [Int]) throws {
        deleteCount += 1
        if let deleteError { throw deleteError }
        guard !deleteIsNoop else { return }
        let targetSet = Set(targets)
        items.removeAll { targetSet.contains($0) }
    }

    /// 検証用に 3 つの値をまとめて取り出す（await を 1 回で済ませる）
    func snapshot() -> (remaining: Int, fetchCount: Int, deleteCount: Int) {
        (items.count, fetchCount, deleteCount)
    }
}

final class BatchDrainerTests: XCTestCase {

    /// 対象が最初から無ければ、削除は 1 回も呼ばれない。
    func testDrainDoesNothingWhenNothingToDelete() async throws {
        let store = FakeStore(count: 0)

        try await drainAll(store, pageSize: 50)

        let result = await store.snapshot()
        XCTAssertEqual(result.fetchCount, 1)
        XCTAssertEqual(result.deleteCount, 0)
    }

    /// 1 ページに満たない件数は、取得 1 回・削除 1 回で終わる。
    /// （空を確認するためだけの余計な 1 回を撃たない ＝ 読み取り課金を無駄にしない）
    func testDrainStopsAfterPartialPage() async throws {
        let store = FakeStore(count: 30)

        try await drainAll(store, pageSize: 50)

        let result = await store.snapshot()
        XCTAssertEqual(result.remaining, 0)
        XCTAssertEqual(result.fetchCount, 1)
        XCTAssertEqual(result.deleteCount, 1)
    }

    /// 複数ページにまたがっても全件消える。
    /// 120 件 / 50 件ずつ → 50, 50, 20 の 3 ページ。
    func testDrainDeletesAcrossMultiplePages() async throws {
        let store = FakeStore(count: 120)

        try await drainAll(store, pageSize: 50)

        let result = await store.snapshot()
        XCTAssertEqual(result.remaining, 0)
        XCTAssertEqual(result.fetchCount, 3)
        XCTAssertEqual(result.deleteCount, 3)
    }

    /// ちょうど pageSize の倍数でも取りこぼさない（境界値）。
    /// 100 件 / 50 件ずつ → 50, 50 を消し、3 回目の取得で空を確認して終わる。
    func testDrainHandlesExactMultipleOfPageSize() async throws {
        let store = FakeStore(count: 100)

        try await drainAll(store, pageSize: 50)

        let result = await store.snapshot()
        XCTAssertEqual(result.remaining, 0)
        XCTAssertEqual(result.fetchCount, 3)
        XCTAssertEqual(result.deleteCount, 2)
    }

    /// ⭐️ 削除が無言で効かない場合、無限ループせず例外になる。
    /// 「毎回同じ 50 件が返り続ける」状況を再現する。
    func testDrainThrowsWhenDeleteIsIneffective() async throws {
        let store = FakeStore(count: 60, deleteIsNoop: true)

        do {
            try await drainAll(store, pageSize: 50, maxPages: 3)
            XCTFail("削除が効いていないのに正常終了してはいけない")
        } catch let error as BatchDrainer.DrainError {
            switch error {
            case let .exceededMaxPages(maxPages):
                XCTAssertEqual(maxPages, 3)
            }
        }

        // 上限ちょうどで打ち切られている（それ以上回っていない）
        let result = await store.snapshot()
        XCTAssertEqual(result.fetchCount, 3)
    }

    /// ⭐️ fetch が失敗したら、そのエラーがそのまま呼び出し側へ伝わり、削除は 1 回も呼ばれない。
    /// （取れていないものを消しにいかない。permission-denied や通信断を黙って飲み込まない）
    func testDrainPropagatesFetchErrorWithoutDeleting() async {
        let store = FakeStore(count: 10, fetchError: StubError.fetchFailed)

        do {
            try await drainAll(store, pageSize: 50)
            XCTFail("fetch が失敗したのに正常終了してはいけない")
        } catch let error as StubError {
            XCTAssertEqual(error, .fetchFailed)
        } catch {
            XCTFail("想定外のエラー型: \(error)")
        }

        let result = await store.snapshot()
        XCTAssertEqual(result.fetchCount, 1)
        XCTAssertEqual(result.deleteCount, 0, "取得に失敗したページを消しにいってはいけない")
        XCTAssertEqual(result.remaining, 10)
    }

    /// ⭐️ delete が失敗したらループはそこで止まり、次のページを取りにいかない。
    /// 120 件あっても fetch 1 回・delete 1 回で終わり、対象は 1 件も減っていない。
    func testDrainPropagatesDeleteErrorAndStops() async {
        let store = FakeStore(count: 120, deleteError: StubError.deleteFailed)

        do {
            try await drainAll(store, pageSize: 50)
            XCTFail("delete が失敗したのに正常終了してはいけない")
        } catch let error as StubError {
            XCTAssertEqual(error, .deleteFailed)
        } catch {
            XCTFail("想定外のエラー型: \(error)")
        }

        let result = await store.snapshot()
        XCTAssertEqual(result.fetchCount, 1, "失敗後に次のページを取りにいってはいけない")
        XCTAssertEqual(result.deleteCount, 1)
        XCTAssertEqual(result.remaining, 120)
    }

    /// pageSize が 0 以下なら何もしない（進捗ゼロで回り続けるのを防ぐ）。
    func testDrainWithNonPositivePageSizeDoesNothing() async throws {
        let store = FakeStore(count: 10)

        try await drainAll(store, pageSize: 0)

        let result = await store.snapshot()
        XCTAssertEqual(result.fetchCount, 0)
        XCTAssertEqual(result.remaining, 10)
    }

    // MARK: - Helpers

    /// スタブに対してドレインを回す共通処理
    private func drainAll(_ store: FakeStore, pageSize: Int, maxPages: Int = 200) async throws {
        try await BatchDrainer.drain(
            pageSize: pageSize,
            maxPages: maxPages,
            fetch: { size in try await store.fetch(pageSize: size) },
            delete: { targets in try await store.delete(targets) }
        )
    }
}
