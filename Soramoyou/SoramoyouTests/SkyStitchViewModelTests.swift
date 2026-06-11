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
            stitch: { _, _ in SkyStitchResult(status: stitchStatus, image: image) }
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

    // MARK: - 撮り方(style)の伝達

    @MainActor
    func testRunStitchPassesCurrentStyleToStitcher() async {
        // runStitch が「呼び出し時点の style」を stitch 関数へ渡すことを検証する。
        // 共有可変状態を避けるため、style ごとに異なる結果を返して終端状態で観測する
        // （.grid → 成功=previewReady / .pan → needMoreImages=failed）。
        let image = dummyImage()
        let vm = SkyStitchViewModel(
            stitch: { _, style in
                style == .grid
                    ? SkyStitchResult(status: .ok, image: image)
                    : SkyStitchResult(status: .needMoreImages, image: nil)
            }
        )

        // 既定は .grid → previewReady になるはず
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .previewReady = vm.state else {
            return XCTFail("既定 .grid が渡れば previewReady。実際: \(vm.state)")
        }

        // .pan へ切り替えて繋ぎ直す → 切替後の style が渡り failed になるはず
        vm.style = .pan
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else {
            return XCTFail("切替後の .pan が渡れば failed。実際: \(vm.state)")
        }
    }

    // MARK: - 並走時の世代ガード

    @MainActor
    func testStaleResultDoesNotOverwriteNewerStitch() async {
        // 遅い旧世代(.grid=成功)と速い新世代(.pan=失敗)を並走させ、
        // 旧世代の結果が後着しても最新世代の state を上書きしないことを検証する。
        let image = dummyImage()
        let vm = SkyStitchViewModel(
            stitch: { _, style in
                if style == .grid {
                    // 旧世代: わざと遅らせて新世代より後に完了させる（注入クロージャは BG 実行なので sleep 可）
                    Thread.sleep(forTimeInterval: 0.3)
                    return SkyStitchResult(status: .ok, image: image)
                }
                return SkyStitchResult(status: .needMoreImages, image: nil)
            }
        )

        // 旧世代(.grid)を開始（await しない＝並走させる）
        let firstRun = Task { await vm.runStitch([self.dummyImage(), self.dummyImage()]) }
        // 旧世代の開始（state=.stitching への遷移）を待ってから新世代を始める
        try? await Task.sleep(nanoseconds: 50_000_000)

        // 新世代: 撮り方を切り替えて繋ぎ直し（即 failed で返る）
        vm.style = .pan
        await vm.runStitch([dummyImage(), dummyImage()])
        guard case .failed = vm.state else {
            return XCTFail("新世代(.pan)は即 failed のはず。実際: \(vm.state)")
        }

        // 旧世代の完了を待つ → 後着した previewReady が failed を上書きしていないこと
        _ = await firstRun.value
        guard case .failed = vm.state else {
            return XCTFail("旧世代の後着結果が最新 state を上書きしてはいけない。実際: \(vm.state)")
        }
    }
}
