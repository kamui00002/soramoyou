//
//  SoratomoFeatureGateTests.swift
//  SoramoyouTests
//
//  そらともの判定（SoratomoFeatureGate）のテスト ⭐️（tasks 10.6・soratomo-public-launch 6.1）
//

@testable import Soramoyou
import XCTest

@MainActor
final class SoratomoFeatureGateTests: XCTestCase {
    // MARK: - Mock

    /// アカウントの窓口のモック（ログイン状態を決められる・読まれた回数を数える）
    @MainActor
    private final class MockAccountProvider: SoratomoAccountProviding {
        /// いまのアカウントの種類（nil = 未ログイン）
        var kind: SoratomoAccountKind?
        /// `currentAccountKind()` が呼ばれた回数
        private(set) var kindReads = 0

        func currentAccountKind() -> SoratomoAccountKind? {
            kindReads += 1
            return kind
        }
    }

    private var provider: MockAccountProvider!
    private var gate: SoratomoFeatureGate!

    override func setUp() async throws {
        provider = MockAccountProvider()
        gate = SoratomoFeatureGate(provider: provider)
    }

    // MARK: - 初期状態

    func testStartsUnknownAndHidden() {
        // 判定が済むまでは入口を出さない
        XCTAssertEqual(gate.state, .unknown)
        XCTAssertFalse(gate.isEnabled)
    }

    // MARK: - 有効になる場合（public-launch 6.1）

    func testRegisteredWithoutClaimIsEnabled() {
        // 1.15.0 の一般公開: 登録済みでログインしていれば有効（public-launch 要件 2.1）。
        // 判定はクレームを読まない（窓口にクレームを渡す口が無い）ので、クレームの有無で結果は変わらない。
        // 判定を変える前の実装（クレームを読む）では、クレームの無い登録済みが無効になって赤だった（65a98ca）
        provider.kind = .registered
        let state = gate.evaluate()
        XCTAssertEqual(state, .enabled)
        XCTAssertTrue(gate.isEnabled)
    }

    func testEvaluateReadsOnlyTheAccountKind() {
        // evaluate() は窓口の currentAccountKind() を 1 回読むだけ（トークンの取得も通信もしない）
        provider.kind = .registered
        gate.evaluate()
        XCTAssertEqual(provider.kindReads, 1)
    }

    // MARK: - 無効になる場合

    func testSignedOutIsDisabled() {
        provider.kind = nil
        let state = gate.evaluate()
        XCTAssertEqual(state, .disabled(.signedOut))
        XCTAssertFalse(gate.isEnabled)
    }

    func testAnonymousIsDisabled() {
        // 匿名アカウント（ゲスト）は無効。ゲストと匿名のホームに入口が出ないことは、この判定が受け持つ
        provider.kind = .anonymous
        let state = gate.evaluate()
        XCTAssertEqual(state, .disabled(.anonymous))
        XCTAssertFalse(gate.isEnabled)
    }

    func testFollowsTheCurrentAccountOnEachEvaluation() {
        // 評価のたびに、そのときのアカウントの種類に従う（前の結果を引きずらない）
        provider.kind = .registered
        XCTAssertEqual(gate.evaluate(), .enabled)
        provider.kind = .anonymous
        XCTAssertEqual(gate.evaluate(), .disabled(.anonymous))
        provider.kind = nil
        XCTAssertEqual(gate.evaluate(), .disabled(.signedOut))
        XCTAssertEqual(gate.state, .disabled(.signedOut))
    }

    // MARK: - サインアウト

    func testResetReturnsToUnknown() {
        provider.kind = .registered
        gate.evaluate()
        XCTAssertTrue(gate.isEnabled)

        gate.reset()
        XCTAssertEqual(gate.state, .unknown)
        XCTAssertFalse(gate.isEnabled)
    }
}
