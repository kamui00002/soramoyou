//
//  SoratomoComposeViewModelTests.swift
//  SoramoyouTests
//
//  そらともの投稿画面の ViewModel のテスト ⭐️（tasks 13.7・13.8）
//
//  - 二重の確定を受け付けないこと
//  - 失敗で入力（写真とキャプション）が残り、再試行は新しい投稿 ID で行うこと
//  - 保存の失敗で、アップロード済みの画像の削除が呼ばれること
//  - 件数の数え方の失敗（nil）で投稿を止めないこと
//  - 事前確認（通信・日次件数）、結果が確定しない保存の確かめ方、猶予切れ、キャプションの規則
//

@testable import Soramoyou
import UIKit
import XCTest

@MainActor
final class SoratomoComposeViewModelTests: XCTestCase {
    // MARK: - テスト用の代役

    /// 記録した計測を覚える
    private final class EventLog {
        var events: [SoratomoEvent] = []
    }

    /// 背景の処理の口の代役（猶予切れを、テストから起こせる）
    @MainActor
    private final class BackgroundTaskStub {
        /// 開いた回数
        var beginCount = 0
        /// 閉じた識別子
        var ended: [UIBackgroundTaskIdentifier] = []
        /// 猶予切れのときに呼ぶ処理（最後に開いた口のもの）
        var onExpiration: (@MainActor () -> Void)?

        /// 猶予切れを起こす
        func expire() {
            onExpiration?()
        }
    }

    /// 変換を途中で止めておく門（二重の確定を、送信の途中で試すため）
    /// プレビューの作成を止めるかの切り替え（最初の写真は止めず、選び直した写真だけ止めるため）
    private final class PreviewSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var block = false
        var shouldBlock: Bool {
            get { lock.lock(); defer { lock.unlock() }; return block }
            set { lock.lock(); block = newValue; lock.unlock() }
        }
    }

    private final class EncodeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var entered = false
        /// 開けたか（入ったことの記録と待ちの登録の間に開けられても、待ち続けないため）
        private var opened = false

        /// 変換に入ったか
        var hasEntered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return entered
        }

        /// 門が開くまで待つ
        ///
        /// 止めるのは最初に入った 1 回だけ。2 回目以降はすぐに通す
        /// （二重の確定のガードを壊したときに、テストが待ち続けずに XCTAssert で落ちるようにするため）
        func wait() async {
            guard claimFirstEntry() else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }

        /// 最初に入ったのが自分なら true（入ったことを記録する）
        private func claimFirstEntry() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !entered else { return false }
            entered = true
            return true
        }

        /// 門を開ける
        func open() {
            lock.lock()
            opened = true
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    /// 呼ばれるたびに 1 秒進む時計（所要時間の計測を確かめるため）
    private final class SteppingClock {
        private var current = Date(timeIntervalSince1970: 1_000_000)

        func now() -> Date {
            defer { current = current.addingTimeInterval(1) }
            return current
        }
    }

    /// 変換の結果の代役（中身は使われない）
    private static let encodedImages = SoratomoEncodedImages(
        display: Data([0x01]),
        thumbnail: Data([0x02]),
        pixelWidth: 8,
        pixelHeight: 6
    )

    /// プレビューを作れる小さな JPEG（8×6 ピクセル）
    private static func makeJPEG() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    // MARK: - 組み立て

    private var skyService: MockSoratomoSkyService!
    private var imageStore: MockSoratomoImageStore!
    private var log: EventLog!
    private var background: BackgroundTaskStub!
    private var online: Bool!

    override func setUp() {
        super.setUp()
        skyService = MockSoratomoSkyService()
        imageStore = MockSoratomoImageStore()
        log = EventLog()
        background = BackgroundTaskStub()
        online = true
        // 既定は「すべて成功・今日はまだ 0 件」。各テストで失敗させたいところだけ変える
        skyService.todaySkyCount = 0
        skyService.createSkyResult = .success(())
        imageStore.uploadResult = .success(())
    }

    /// テスト対象を作る
    private func makeViewModel(
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000_000) },
        encode: SoratomoComposeViewModel.Encode? = nil,
        makePreview: SoratomoComposeViewModel.MakePreview? = nil
    ) -> SoratomoComposeViewModel {
        let images = Self.encodedImages
        // 既定の変換は、決まった 2 枚を返すだけ
        let succeedingEncode: SoratomoComposeViewModel.Encode = { _ in .success(images) }
        let log = log!
        let background = background!
        return SoratomoComposeViewModel(
            groupId: "g1",
            skyService: skyService,
            imageStore: imageStore,
            isOnline: { [unowned self] in self.online },
            currentUid: { "me" },
            now: now,
            encode: encode ?? succeedingEncode,
            makePreview: makePreview ?? { await SoratomoComposeViewModel.makePreview(from: $0) },
            beginBackgroundTask: { handler in
                background.beginCount += 1
                background.onExpiration = handler
                return UIBackgroundTaskIdentifier(rawValue: 7)
            },
            endBackgroundTask: { background.ended.append($0) },
            logEvent: { log.events.append($0) }
        )
    }

    // MARK: - 写真の選び直し（レビューで直した）

    func testReselectingPhotoBlocksSubmitUntilPreviewIsReady() async {
        let gate = EncodeGate()
        let previewSwitch = PreviewSwitch()
        let viewModel = makeViewModel(makePreview: { data in
            if previewSwitch.shouldBlock {
                await gate.wait()
            }
            return await SoratomoComposeViewModel.makePreview(from: data)
        })
        // 写真 A を選んで、確定できる状態にする
        await fillInput(viewModel)

        // 写真 B を選び直す。プレビューを作っている間は、前の写真（A）を送らせない
        previewSwitch.shouldBlock = true
        let reselect = Task { await viewModel.selectPhoto(Self.makeJPEG()) }
        while !gate.hasEntered {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isPreparingPhoto)
        XCTAssertFalse(viewModel.canSubmit)
        await viewModel.submit()
        XCTAssertTrue(skyService.newSkyIdCalls.isEmpty)

        // B のプレビューができたら、確定できる
        gate.open()
        await reselect.value
        XCTAssertFalse(viewModel.isPreparingPhoto)
        XCTAssertTrue(viewModel.canSubmit)
    }

    /// 写真とキャプションを入れた状態にする
    private func fillInput(_ viewModel: SoratomoComposeViewModel, caption: String = "夕焼け") async {
        await viewModel.selectPhoto(Self.makeJPEG())
        viewModel.updateCaption(caption)
        XCTAssertTrue(viewModel.canSubmit, "前提: 確定できる入力になっている")
    }

    // MARK: - 成功

    func testSuccessfulPostCreatesSkyAfterUploadAndLogsCreated() async {
        let clock = SteppingClock()
        let viewModel = makeViewModel(now: { clock.now() })
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(imageStore.uploadCalls.count, 1)
        XCTAssertEqual(imageStore.uploadCalls.first?.paths, SoratomoImagePaths(groupId: "g1", authorId: "me", skyId: "sky-1"))
        XCTAssertEqual(
            skyService.createSkyCalls,
            [SoratomoSkyDraft(groupId: "g1", skyId: "sky-1", authorId: "me", caption: "夕焼け", pixelWidth: 8, pixelHeight: 6)]
        )
        XCTAssertTrue(imageStore.deleteCalls.isEmpty)
        // 時計は「確定」「事前確認の今日」「完了」の 3 回読まれ、1 秒ずつ進む → 確定から完了まで 2 秒
        XCTAssertEqual(log.events, [.postCreated(hasCaption: true, durationMs: 2000)])
        // 背景の口は開いて、閉じている
        XCTAssertEqual(background.beginCount, 1)
        XCTAssertEqual(background.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    func testEmptyCaptionIsSavedWithoutCaption() async {
        let viewModel = makeViewModel()
        await fillInput(viewModel, caption: "")

        await viewModel.submit()

        XCTAssertNil(skyService.createSkyCalls.first?.caption)
        XCTAssertEqual(log.events, [.postCreated(hasCaption: false, durationMs: 0)])
    }

    // MARK: - 二重の確定

    func testSecondSubmitWhileSendingIsIgnored() async {
        let gate = EncodeGate()
        let images = Self.encodedImages
        let viewModel = makeViewModel(encode: { _ in
            await gate.wait()
            return .success(images)
        })
        await fillInput(viewModel)

        let first = Task { await viewModel.submit() }
        // 変換に入るまで待つ（固定の時間では待たない）
        while !gate.hasEntered {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.isBusy)
        XCTAssertFalse(viewModel.canSubmit)

        // 送信の途中の 2 回目の確定は、何もしない
        await viewModel.submit()

        gate.open()
        await first.value

        XCTAssertEqual(skyService.newSkyIdCalls.count, 1)
        XCTAssertEqual(skyService.countTodaySkiesCalls.count, 1)
        XCTAssertEqual(imageStore.uploadCalls.count, 1)
        XCTAssertEqual(skyService.createSkyCalls.count, 1)
        XCTAssertEqual(viewModel.phase, .finished)
    }

    func testSubmitAfterFinishedDoesNothing() async {
        let viewModel = makeViewModel()
        await fillInput(viewModel)
        await viewModel.submit()

        await viewModel.submit()

        XCTAssertEqual(skyService.createSkyCalls.count, 1)
    }

    // MARK: - 失敗で入力が残る・再試行

    func testUploadFailureKeepsInputDeletesImagesAndRetriesWithNewSkyId() async {
        imageStore.uploadResult = .failure(.network)
        let viewModel = makeViewModel()
        await fillInput(viewModel)
        let photo = viewModel.photoData

        await viewModel.submit()

        // 入力は残り、再試行できる
        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.network.userMessage))
        XCTAssertEqual(viewModel.photoData, photo)
        XCTAssertNotNil(viewModel.previewImage)
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertTrue(viewModel.canSubmit)
        // 投稿のデータは作らず、届いたかもしれない画像を消す
        XCTAssertTrue(skyService.createSkyCalls.isEmpty)
        XCTAssertEqual(imageStore.deleteCalls, [SoratomoImagePaths(groupId: "g1", authorId: "me", skyId: "sky-1")])
        XCTAssertEqual(log.events, [.postFailed(stage: .upload, reason: .network)])

        // 再試行は新しい投稿 ID で行う
        imageStore.uploadResult = .success(())
        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(skyService.newSkyIdCalls.count, 2)
        XCTAssertEqual(skyService.createSkyCalls.map(\.skyId), ["sky-2"])
    }

    func testEncodeFailureKeepsInputAndDoesNotUpload() async {
        let viewModel = makeViewModel(encode: { _ in
            .failure(.imageTooLarge)
        })
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.imageTooLarge.userMessage))
        XCTAssertNotNil(viewModel.photoData)
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertTrue(imageStore.uploadCalls.isEmpty)
        XCTAssertTrue(imageStore.deleteCalls.isEmpty)
        XCTAssertEqual(log.events, [.postFailed(stage: .image, reason: .tooLarge)])
    }

    // MARK: - 保存の失敗

    func testSaveFailureDeletesUploadedImagesBeforeFailing() async {
        skyService.createSkyResult = .failure(.permissionDenied)
        let viewModel = makeViewModel()
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertEqual(skyService.createSkyCalls.count, 1)
        XCTAssertEqual(imageStore.deleteCalls, [SoratomoImagePaths(groupId: "g1", authorId: "me", skyId: "sky-1")])
        // 確定しない失敗ではないので、サーバーには確かめない
        XCTAssertTrue(skyService.skyExistsOnServerCalls.isEmpty)
        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.permissionDenied.userMessage))
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertNotNil(viewModel.photoData)
        XCTAssertEqual(log.events, [.postFailed(stage: .save, reason: .permission)])
    }

    // MARK: - 結果が確定しない失敗の送り直し（release-gate 10.3・要件 11.8）

    func testUncertainSaveIsRetriedOnceWithSameDraftAndSucceeds() async {
        skyService.createSkyResultQueue = [.failure(.network), .success(())]
        let viewModel = makeViewModel()
        await fillInput(viewModel)

        await viewModel.submit()

        // 同じ投稿 ID（同じ draft）で 1 回だけ送り直す。サーバーへの有無の確かめは使わない
        XCTAssertEqual(skyService.createSkyCalls.map(\.skyId), ["sky-1", "sky-1"])
        XCTAssertEqual(skyService.createSkyCalls.first, skyService.createSkyCalls.last)
        XCTAssertEqual(skyService.newSkyIdCalls.count, 1)
        XCTAssertTrue(skyService.skyExistsOnServerCalls.isEmpty)
        XCTAssertTrue(imageStore.deleteCalls.isEmpty)
        XCTAssertEqual(viewModel.phase, .finished)
        XCTAssertEqual(log.events, [.postCreated(hasCaption: true, durationMs: 0)])
    }

    func testRetryRejectedForCertainDeletesImages() async {
        skyService.createSkyResultQueue = [.failure(.network), .failure(.suspended)]
        let viewModel = makeViewModel()
        await fillInput(viewModel)

        await viewModel.submit()

        // 送り直しが確定した拒否なら、画像を消して失敗（その拒否の文言）
        XCTAssertEqual(skyService.createSkyCalls.count, 2)
        XCTAssertEqual(imageStore.deleteCalls, [SoratomoImagePaths(groupId: "g1", authorId: "me", skyId: "sky-1")])
        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.suspended.userMessage))
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertNotNil(viewModel.photoData)
        XCTAssertEqual(log.events, [.postFailed(stage: .save, reason: .unknown)])
    }

    func testRetryStillUncertainKeepsImagesAndDoesNotRetryAgain() async {
        skyService.createSkyResult = .failure(.network)
        let viewModel = makeViewModel()
        await fillInput(viewModel)

        await viewModel.submit()

        // 送り直しは 1 回だけ。また確定しなければ、投稿があるかもしれないので画像は消さない
        XCTAssertEqual(skyService.createSkyCalls.count, 2)
        XCTAssertTrue(imageStore.deleteCalls.isEmpty)
        XCTAssertTrue(skyService.skyExistsOnServerCalls.isEmpty)
        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.network.userMessage))
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertNotNil(viewModel.photoData)
        XCTAssertEqual(log.events, [.postFailed(stage: .save, reason: .network)])
    }

    // MARK: - NGワード（release-gate 10.3・要件 11.7〜11.9・15.2）

    func testNgWordDeletesImagesKeepsInputAndDoesNotRetry() async {
        skyService.createSkyResult = .failure(.ngWord)
        let viewModel = makeViewModel()
        await fillInput(viewModel)
        let photo = viewModel.photoData

        await viewModel.submit()

        // 確定した拒否なので送り直さず、アップロード済みの画像を消す
        XCTAssertEqual(skyService.createSkyCalls.count, 1)
        XCTAssertEqual(imageStore.deleteCalls, [SoratomoImagePaths(groupId: "g1", authorId: "me", skyId: "sky-1")])
        // 「使えない言葉が含まれています」を出し、どの語かは示さない。写真とキャプションは残す
        XCTAssertEqual(viewModel.phase, .failed(message: "使えない言葉が含まれています"))
        XCTAssertEqual(viewModel.photoData, photo)
        XCTAssertNotNil(viewModel.previewImage)
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertTrue(viewModel.canSubmit)
        XCTAssertEqual(log.events, [.postFailed(stage: .save, reason: .ngWord)])
    }

    // MARK: - 事前確認

    func testCountFailureDoesNotStopPosting() async {
        skyService.todaySkyCount = nil
        let viewModel = makeViewModel()
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertEqual(skyService.countTodaySkiesCalls.count, 1)
        XCTAssertEqual(skyService.createSkyCalls.count, 1)
        XCTAssertEqual(viewModel.phase, .finished)
    }

    func testDailyLimitStopsAtPrecheckAndKeepsInput() async {
        skyService.todaySkyCount = SoratomoComposeViewModel.dailyPostLimit
        let now = Date(timeIntervalSince1970: 1_000_000)
        let viewModel = makeViewModel(now: { now })
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.dailyLimit.userMessage))
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertNotNil(viewModel.photoData)
        XCTAssertTrue(skyService.newSkyIdCalls.isEmpty)
        XCTAssertTrue(imageStore.uploadCalls.isEmpty)
        XCTAssertEqual(log.events, [.postFailed(stage: .precheck, reason: .dailyLimit)])
        // 今日の始まり（端末のタイムゾーン）から、自分の投稿をそのグループで数える
        XCTAssertEqual(skyService.countTodaySkiesCalls.first?.groupId, "g1")
        XCTAssertEqual(skyService.countTodaySkiesCalls.first?.authorId, "me")
        XCTAssertEqual(skyService.countTodaySkiesCalls.first?.since, SoratomoDaySection.startOfDay(for: now))
    }

    func testBelowDailyLimitPosts() async {
        skyService.todaySkyCount = SoratomoComposeViewModel.dailyPostLimit - 1
        let viewModel = makeViewModel()
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .finished)
    }

    func testOfflineStopsAtPrecheckAndKeepsInput() async {
        online = false
        let viewModel = makeViewModel()
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.network.userMessage))
        XCTAssertEqual(viewModel.caption, "夕焼け")
        XCTAssertTrue(skyService.countTodaySkiesCalls.isEmpty)
        XCTAssertTrue(skyService.newSkyIdCalls.isEmpty)
        XCTAssertEqual(log.events, [.postFailed(stage: .precheck, reason: .offline)])
    }

    // MARK: - 猶予切れ

    func testBackgroundExpirationDuringEncodingFailsWithoutUpload() async {
        let images = Self.encodedImages
        let background = background!
        let viewModel = makeViewModel(encode: { _ in
            // 変換の途中で猶予が切れる
            await background.expire()
            return .success(images)
        })
        await fillInput(viewModel)

        await viewModel.submit()

        XCTAssertTrue(imageStore.uploadCalls.isEmpty)
        XCTAssertTrue(skyService.createSkyCalls.isEmpty)
        XCTAssertEqual(viewModel.phase, .failed(message: SoratomoError.backgroundExpired.userMessage))
        XCTAssertEqual(log.events, [.postFailed(stage: .image, reason: .background)])
        // 猶予切れのときに口を閉じ、二重には閉じない
        XCTAssertEqual(background.ended, [UIBackgroundTaskIdentifier(rawValue: 7)])
    }

    // MARK: - 入力

    func testCaptionRemovesNewlinesAndOverLimitBlocksSubmit() async {
        let viewModel = makeViewModel()
        await viewModel.selectPhoto(Self.makeJPEG())

        viewModel.updateCaption("朝\nの\r\n空")
        XCTAssertEqual(viewModel.caption, "朝の空")

        viewModel.updateCaption(String(repeating: "空", count: SoratomoTextRules.captionMax))
        XCTAssertFalse(viewModel.isCaptionOverLimit)
        XCTAssertEqual(viewModel.captionRemaining, 0)
        XCTAssertTrue(viewModel.canSubmit)

        viewModel.updateCaption(String(repeating: "空", count: SoratomoTextRules.captionMax + 1))
        XCTAssertTrue(viewModel.isCaptionOverLimit)
        XCTAssertEqual(viewModel.captionRemaining, -1)
        XCTAssertFalse(viewModel.canSubmit)

        // 超えている間に確定しても、何も始めない
        await viewModel.submit()
        XCTAssertEqual(viewModel.phase, .editing)
        XCTAssertTrue(skyService.countTodaySkiesCalls.isEmpty)
    }

    func testUnreadablePhotoIsRejectedBeforePosting() async {
        let viewModel = makeViewModel()

        await viewModel.selectPhoto(Data([0x00, 0x01, 0x02]))

        XCTAssertNil(viewModel.photoData)
        XCTAssertNil(viewModel.previewImage)
        XCTAssertEqual(viewModel.photoErrorMessage, SoratomoError.imageUnreadable.userMessage)
        XCTAssertFalse(viewModel.canSubmit)

        // 取り出せなかった写真（nil）も同じ
        await viewModel.selectPhoto(nil)
        XCTAssertEqual(viewModel.photoErrorMessage, SoratomoError.imageUnreadable.userMessage)

        // 読める写真を選び直せば使える
        await viewModel.selectPhoto(Self.makeJPEG())
        XCTAssertNotNil(viewModel.photoData)
        XCTAssertNotNil(viewModel.previewImage)
        XCTAssertNil(viewModel.photoErrorMessage)
    }
}
