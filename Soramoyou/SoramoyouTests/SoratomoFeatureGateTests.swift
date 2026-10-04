//
//  SoratomoFeatureGateTests.swift
//  SoramoyouTests
//
//  そらともの機能フラグの判定（SoratomoFeatureGate）のテスト ⭐️（tasks 10.6）
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoFeatureGateTests: XCTestCase {
    // MARK: - Mock

    /// アカウントの窓口のモック（ログイン状態とクレームの取得結果を決められる）
    @MainActor
    private final class MockClaimsProvider: SoratomoClaimsProviding {
        struct TokenError: Error {}

        /// いまのアカウントの種類（nil = 未ログイン）
        var kind: SoratomoAccountKind?
        /// クレームの取得結果（呼ばれるたびに先頭から使う。空なら「クレーム無し」）
        var results: [Result<[String: Any], Error>] = []
        /// クレームの取得で渡された forceRefresh の記録
        private(set) var forceRefreshCalls: [Bool] = []
        /// true にすると、次の取得を `release()` まで止める（待っている間の操作を試すため）
        var holdNextCall = false
        private var held: CheckedContinuation<Void, Never>?
        var isHolding: Bool {
            held != nil
        }

        func currentAccountKind() -> SoratomoAccountKind? {
            kind
        }

        func claims(forceRefresh: Bool) async throws -> [String: Any] {
            forceRefreshCalls.append(forceRefresh)
            let result = results.isEmpty ? .success([:]) : results.removeFirst()
            if holdNextCall {
                holdNextCall = false
                await withCheckedContinuation { held = $0 }
            }
            return try result.get()
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    private var provider: MockClaimsProvider!
    private var gate: SoratomoFeatureGate!

    override func setUp() async throws {
        provider = MockClaimsProvider()
        gate = SoratomoFeatureGate(provider: provider)
    }

    /// 止めたクレームの取得に評価が届くまで待つ
    ///
    /// 上限を付けて、届かないまま終わったら失敗にする（無限に待たない）。
    /// たとえば DEBUG で常に有効にする抜け道があると、取得まで届かずに評価が終わる。
    private func waitUntilHolding(file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        for _ in 0 ..< 1000 {
            if provider.isHolding {
                return true
            }
            await Task.yield()
        }
        XCTFail("クレームの取得が呼ばれなかった", file: file, line: line)
        return false
    }

    // MARK: - 初期状態

    func testStartsUnknownAndHidden() {
        // 判定が済むまでは入口を出さない
        XCTAssertEqual(gate.state, .unknown)
        XCTAssertFalse(gate.isEnabled)
    }

    // MARK: - 無効になる場合

    func testSignedOutIsDisabledWithoutReadingToken() async {
        provider.kind = nil
        let state = await gate.evaluate()
        XCTAssertEqual(state, .disabled(.signedOut))
        XCTAssertFalse(gate.isEnabled)
        XCTAssertEqual(provider.forceRefreshCalls, [])
    }

    func testAnonymousIsDisabledWithoutReadingToken() async {
        // 匿名アカウントは、クレームがあっても読まずに無効
        provider.kind = .anonymous
        provider.results = [.success(["soratomoBeta": true])]
        let state = await gate.evaluate()
        XCTAssertEqual(state, .disabled(.anonymous))
        XCTAssertFalse(gate.isEnabled)
        XCTAssertEqual(provider.forceRefreshCalls, [])
    }

    func testMissingClaimIsDisabled() async {
        // ⚠️ テストは Debug ビルドで動く。ここで無効になることが「DEBUG でも例外を設けない」ことの確認になる
        //    （SkyMotionAccess のように DEBUG で常に有効にすると、このテストが落ちる）
        provider.kind = .registered
        provider.results = [.success(["skyMotionBeta": true])]
        let state = await gate.evaluate()
        XCTAssertEqual(state, .disabled(.claimMissing))
        XCTAssertFalse(gate.isEnabled)
    }

    func testNonTrueClaimValuesAreDisabled() async {
        // false と文字列の "true" は有効にしない（ルールの `== true` と同じ）。
        // 数値の 1 はここでは試さない: 本番のクレームは JSON から NSNumber で届き、`as? Bool` は 1 を true と
        // 読むため、Swift の Int で試しても本番の挙動を表さない（付与のスクリプトは真偽値の true だけを書く）
        provider.kind = .registered
        for value: Any in [false, "true"] {
            provider.results = [.success(["soratomoBeta": value])]
            let state = await gate.evaluate()
            XCTAssertEqual(state, .disabled(.claimMissing), "soratomoBeta=\(value)")
        }
    }

    func testTokenFailureIsDisabled() async {
        // 取得の失敗は無効に倒す
        provider.kind = .registered
        provider.results = [.failure(MockClaimsProvider.TokenError())]
        let state = await gate.evaluate()
        XCTAssertEqual(state, .disabled(.tokenUnavailable))
        XCTAssertFalse(gate.isEnabled)
    }

    func testReevaluateAfterTokenFailureBecomesEnabled() async {
        // 起動時に取れなかったら、前面に戻ったときの判定し直しで有効になる（レビューで足した）
        provider.kind = .registered
        provider.results = [.failure(MockClaimsProvider.TokenError()), .success(["soratomoBeta": true])]
        await gate.evaluate()
        XCTAssertEqual(gate.state, .disabled(.tokenUnavailable))

        let state = await gate.reevaluateIfTokenUnavailable()

        XCTAssertEqual(state, .enabled)
        XCTAssertEqual(provider.forceRefreshCalls.count, 2)
    }

    func testReevaluateDoesNothingUnlessTokenUnavailable() async {
        // クレーム無しで決まった判定は、前面に戻っても問い合わせ直さない
        provider.kind = .registered
        provider.results = [.success([:])]
        await gate.evaluate()
        XCTAssertEqual(gate.state, .disabled(.claimMissing))

        let state = await gate.reevaluateIfTokenUnavailable()

        XCTAssertEqual(state, .disabled(.claimMissing))
        XCTAssertEqual(provider.forceRefreshCalls.count, 1)
    }

    // MARK: - 有効になる場合

    func testTrueClaimIsEnabled() async {
        provider.kind = .registered
        provider.results = [.success(["soratomoBeta": true, "skyMotionBeta": true])]
        let state = await gate.evaluate()
        XCTAssertEqual(state, .enabled)
        XCTAssertTrue(gate.isEnabled)
    }

    // MARK: - トークンの強制的な更新

    func testOnlyFirstTokenReadForcesRefresh() async {
        // 付与の直後でもログインし直さずに使えるよう、起動ごとの最初の取得だけ強制的に更新する
        provider.kind = .registered
        provider.results = [.success(["soratomoBeta": true]), .success(["soratomoBeta": true])]
        await gate.evaluate()
        await gate.evaluate()
        XCTAssertEqual(provider.forceRefreshCalls, [true, false])
    }

    func testFailedForcedRefreshIsRetriedNextTime() async {
        // 強制的な更新に失敗したら、次の評価でもう一度強制する（古いトークンのまま確定させない）
        provider.kind = .registered
        provider.results = [
            .failure(MockClaimsProvider.TokenError()),
            .success(["soratomoBeta": true]),
            .success(["soratomoBeta": true]),
        ]
        await gate.evaluate()
        await gate.evaluate()
        await gate.evaluate()
        XCTAssertEqual(provider.forceRefreshCalls, [true, true, false])
        XCTAssertEqual(gate.state, .enabled)
    }

    func testSignedOutEvaluationDoesNotConsumeForcedRefresh() async {
        // 未ログインの評価ではトークンを読まないので、ログイン後の最初の取得で強制する
        provider.kind = nil
        await gate.evaluate()
        provider.kind = .registered
        provider.results = [.success(["soratomoBeta": true])]
        await gate.evaluate()
        XCTAssertEqual(provider.forceRefreshCalls, [true])
    }

    // MARK: - サインアウト

    func testResetReturnsToUnknown() async {
        provider.kind = .registered
        provider.results = [.success(["soratomoBeta": true])]
        await gate.evaluate()
        XCTAssertTrue(gate.isEnabled)

        gate.reset()
        XCTAssertEqual(gate.state, .unknown)
        XCTAssertFalse(gate.isEnabled)
    }

    func testResetDuringEvaluationDiscardsStaleResult() async {
        // トークンを待っている間にサインアウトしたら、待っていた「有効」で上書きしない
        provider.kind = .registered
        provider.results = [.success(["soratomoBeta": true])]
        provider.holdNextCall = true

        let evaluation = Task { await gate.evaluate() }
        guard await waitUntilHolding() else {
            provider.release()
            return
        }
        gate.reset()
        provider.release()
        let returned = await evaluation.value

        XCTAssertEqual(gate.state, .unknown)
        XCTAssertEqual(returned, .unknown)
        XCTAssertFalse(gate.isEnabled)
    }

    func testNewerEvaluationWinsOverOlderOne() async {
        // 先に始めた評価が後から終わっても、後の評価の結果を上書きしない
        provider.kind = .registered
        provider.results = [.success(["soratomoBeta": true]), .success([:])]
        provider.holdNextCall = true

        let older = Task { await gate.evaluate() }
        guard await waitUntilHolding() else {
            provider.release()
            return
        }
        let newer = await gate.evaluate()
        XCTAssertEqual(newer, .disabled(.claimMissing))

        provider.release()
        _ = await older.value
        XCTAssertEqual(gate.state, .disabled(.claimMissing))
    }
}
