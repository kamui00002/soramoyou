//
//  SkyStitchViewModelTests.swift
//  SoramoyouTests
//
//  ⭐️ 広角合成(v2)の状態機械を検証する（無料化後）。
//  - 合成成功 → previewReady（合成画像を保持）
//  - 合成失敗 → failed（プレビューに到達しない）
//  - status=.ok でも画像が nil の異常系 → failed
//  実 OpenCV には依存せず、stitch を注入する。
//
//  ※ 課金（PaymentService）は広角合成の無料化に伴い本 ViewModel から外したため、
//    購入系テスト・MockPayment は削除した。StoreKit 本体テストは将来の AI 補正課金で再導入する。
//

import XCTest
import UIKit
@testable import Soramoyou

final class SkyStitchViewModelTests: XCTestCase {

    private func dummyImage() -> UIImage {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        return r.image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }

    @MainActor
    private func makeVM(stitchStatus: SkyStitchStatus, image: UIImage?) -> SkyStitchViewModel {
        SkyStitchViewModel(
            stitch: { _ in SkyStitchResult(status: stitchStatus, image: image) }
        )
    }

    // MARK: - 合成

    @MainActor
    func testStitchOkLeadsToPreviewReady() async {
        let vm = makeVM(stitchStatus: .ok, image: dummyImage())
        await vm.runStitch([dummyImage(), dummyImage()])
        // previewReady(UIImage) は associated value 非Optional＝guard 通過自体が「合成画像あり」の検証。
        guard case .previewReady = vm.state else { return XCTFail("ok なら previewReady。実際: \(vm.state)") }
    }

    @MainActor
    func testStitchFailureLeadsToFailedNotPreview() async {
        let vm = makeVM(stitchStatus: .needMoreImages, image: nil)
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else { return XCTFail("失敗時は failed。実際: \(vm.state)") }
    }

    @MainActor
    func testStitchOkButNilImageIsFailure() async {
        // status=.ok でも image=nil の異常系は failed（プレビューに進ませない）
        let vm = makeVM(stitchStatus: .ok, image: nil)
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else { return XCTFail("ok+nil画像は failed。実際: \(vm.state)") }
    }

    // MARK: - 並走時の世代ガード

    /// 呼び出し順で挙動を変えるスレッドセーフなカウンタ（注入 stitch は detached task 上で走るため）。
    private final class CallTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    }

    @MainActor
    func testStaleResultDoesNotOverwriteNewerStitch() async {
        // 「もう一度ためす」連打などで合成が並走したとき、先に始まった遅い旧世代の結果が
        // 後着しても、最新世代の state を上書きしないことを検証する。
        // 1回目の呼び出し=遅く成功 / 2回目=即失敗、と呼び出し順で出し分けて並走を作る。
        let image = dummyImage()
        let tracker = CallTracker()
        let vm = SkyStitchViewModel(
            stitch: { _ in
                if tracker.next() == 1 {
                    Thread.sleep(forTimeInterval: 0.3)   // 旧世代: 新世代より後に完了させる
                    return SkyStitchResult(status: .ok, image: image)
                }
                return SkyStitchResult(status: .needMoreImages, image: nil)  // 新世代: 即失敗
            }
        )

        // 旧世代を開始（await しない＝並走させる）
        let firstRun = Task { await vm.runStitch([self.dummyImage(), self.dummyImage()]) }
        // 旧世代の detached task が走り出す猶予（tracker=1 を先に取らせる）
        try? await Task.sleep(nanoseconds: 50_000_000)

        // 新世代を開始（即 failed で返る）
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else {
            return XCTFail("新世代は即 failed のはず。実際: \(vm.state)")
        }

        // 旧世代の完了を待つ → 後着した previewReady が failed を上書きしていないこと
        _ = await firstRun.value
        guard case .failed = vm.state else {
            return XCTFail("旧世代の後着結果が最新 state を上書きしてはいけない。実際: \(vm.state)")
        }
    }
}
