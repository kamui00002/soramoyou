//
//  SoratomoComposeViewModel.swift
//  Soramoyou
//
//  そらともの投稿画面の ViewModel ⭐️
//  （tasks 13.7・13.8・design.md の SoratomoComposeView・ViewModel と「投稿と通知」のシーケンス・
//   要件 6.1〜6.12・7.5・12.2〜12.5・14.3・15.4・16.1）
//
//  投稿は次の順で進める。順番を入れ替えないこと（画像の無い投稿を作らないため・要件 6.6・6.11・12.4）。
//    1. 事前確認（通信の有無・今日の自分の投稿件数）
//    2. 新しい投稿 ID を作る（試行ごとに新しく作る）
//    3. 変換（`SoratomoImageEncoder.encode`・メインアクターの外）
//    4. 2 枚の並行アップロード（`SoratomoImageStoreProtocol.upload`）
//    5. 投稿のデータの保存（`SoratomoSkyServiceProtocol.createSky`）← 画像が 2 枚そろってからだけ
//
//  ⚠️ 失敗した投稿は下書きにせず、通信が戻っても自動では送り直さない（要件 12.3）。
//     再試行は利用者の操作（`submit()` をもう一度）だけで、そのたびに新しい投稿 ID を使う。
//

import Foundation
import ImageIO
import UIKit

/// そらともの投稿画面の ViewModel
///
/// 写真の元のバイト列とキャプションを持ち、確定（`submit()`）で事前確認→変換→アップロード→保存を行う。
/// 失敗しても写真とキャプションは消さない（要件 6.10）。
@MainActor
final class SoratomoComposeViewModel: ObservableObject {
    // MARK: - 型

    /// 投稿画面の段階
    enum Phase: Equatable {
        /// 入力中（まだ確定していない）
        case editing
        /// 事前確認中（通信の有無・今日の件数）
        case checking
        /// 写真を送信用の 2 枚に変換している
        case encoding
        /// 2 枚をアップロードしている（`progress` は 2 枚を合わせた 0.0〜1.0）
        case uploading(progress: Double)
        /// 投稿のデータを保存している（ここからは猶予切れでも中止しない）
        case saving
        /// 失敗した（`message` は画面に出す固定の文言）。入力は残っていて、再試行できる
        case failed(message: String)
        /// 投稿が完了した（画面は閉じてタイムラインへ戻る）
        case finished
    }

    /// 背景で処理を続けるための口（`beginBackgroundTask` を包んだもの）
    ///
    /// - 引数: 猶予が切れたときに呼ぶ処理（メインアクターで呼ぶ）
    /// - 戻り値: 終わらせるときに `EndBackgroundTask` へ渡す識別子
    typealias BeginBackgroundTask = @MainActor (_ onExpiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    /// 背景で処理を続ける口を閉じる（`endBackgroundTask` を包んだもの）
    typealias EndBackgroundTask = @MainActor (UIBackgroundTaskIdentifier) -> Void
    /// 写真の元のバイト列を送信用の 2 枚に変換する（既定は `SoratomoImageEncoder.encode` をメインアクターの外で呼ぶ）
    ///
    /// ⚠️ 失敗は `throws(SoratomoError)` ではなく `Result` で返す。typed throws の関数の型を値として持つ
    ///    （Optional で包む・既定値にする）と、実行時の型の情報に iOS 18 が要る。下限は iOS 16 のため。
    typealias Encode = @Sendable (Data) async -> Result<SoratomoEncodedImages, SoratomoError>

    // MARK: - 定数

    /// 1 つのグループへ 1 日に投稿できる件数（要件 6.12。v1 はアプリ側だけで判定する）
    nonisolated static let dailyPostLimit = 20
    /// プレビューの長辺（ピクセル）。画面に出すだけなので、送る画像より小さく作る
    nonisolated static let previewMaxPixel = 1200

    // MARK: - Published

    /// いまの段階
    @Published private(set) var phase: Phase = .editing
    /// 選んだ写真の元のバイト列（読めない写真なら nil）
    @Published private(set) var photoData: Data?
    /// 選んだ写真のプレビュー（向きを画素に反映済み）
    @Published private(set) var previewImage: UIImage?
    /// 写真が使えなかったときの固定の文言（使える写真を選んだら nil）
    @Published private(set) var photoErrorMessage: String?
    /// 改行を取り除いたキャプション（入力は `updateCaption(_:)` を通す）
    @Published private(set) var caption: String = ""

    // MARK: - 依存

    /// 投稿先のグループ ID（開いているグループ 1 つだけ・要件 6.5）
    let groupId: String
    /// 投稿のサービス
    private let skyService: any SoratomoSkyServiceProtocol
    /// 画像の保存と削除
    private let imageStore: any SoratomoImageStoreProtocol
    /// 通信できる状態か
    private let isOnline: () -> Bool
    /// いまログインしている利用者の uid（未ログインなら nil）
    private let currentUid: () -> String?
    /// いまの時刻（日次件数の「今日」と、所要時間の計測に使う。テストで差し替える）
    private let now: () -> Date
    /// 写真の変換
    private let encode: Encode
    /// 背景で処理を続ける口
    private let beginBackgroundTask: BeginBackgroundTask
    /// 背景で処理を続ける口を閉じる
    private let endBackgroundTask: EndBackgroundTask
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void

    // MARK: - 送信中の状態

    /// いま開いている背景の処理の識別子（閉じたら nil。二重に閉じないため）
    private var backgroundTaskId: UIBackgroundTaskIdentifier?
    /// 送信中の試行で、猶予切れが起きたか
    private var backgroundExpired = false
    /// いまアップロードしている置き場所（猶予切れのときに取り消すため）
    private var uploadingPaths: SoratomoImagePaths?
    /// 写真を選び直した回数（古い写真のプレビュー作りが、新しい写真を上書きしないため）
    private var photoGeneration = 0

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 投稿先のグループ ID
    ///   - skyService: 投稿のサービス
    ///   - imageStore: 画像の保存と削除
    ///   - isOnline: 通信できる状態かを返す
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - now: いまの時刻を返す（既定は `Date()`）
    ///   - encode: 写真の変換（既定はメインアクターの外で `SoratomoImageEncoder.encode`）
    ///   - beginBackgroundTask: 背景で処理を続ける口（既定は `UIApplication.beginBackgroundTask`）
    ///   - endBackgroundTask: 背景で処理を続ける口を閉じる（既定は `UIApplication.endBackgroundTask`）
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    init(
        groupId: String,
        skyService: any SoratomoSkyServiceProtocol,
        imageStore: any SoratomoImageStoreProtocol,
        isOnline: @escaping () -> Bool,
        currentUid: @escaping () -> String?,
        now: @escaping () -> Date = Date.init,
        // 関数の参照ではなくクロージャで包む（Swift 5 モードで、参照を @Sendable に変える警告を出さないため）
        encode: @escaping Encode = { await SoratomoComposeViewModel.encodeOffMainActor($0) },
        beginBackgroundTask: @escaping BeginBackgroundTask = SoratomoComposeViewModel.beginApplicationBackgroundTask,
        endBackgroundTask: @escaping EndBackgroundTask = SoratomoComposeViewModel.endApplicationBackgroundTask,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log
    ) {
        self.groupId = groupId
        self.skyService = skyService
        self.imageStore = imageStore
        self.isOnline = isOnline
        self.currentUid = currentUid
        self.now = now
        self.encode = encode
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.logEvent = logEvent
    }

    // MARK: - 表示用

    /// 送信の途中か（事前確認から保存まで）。この間は確定・写真の選び直し・閉じる操作を受け付けない
    var isBusy: Bool {
        switch phase {
        case .checking, .encoding, .uploading, .saving:
            true
        case .editing, .failed, .finished:
            false
        }
    }

    /// キャプションの残り文字数（コードポイントで数える・tasks 10.3。超えていれば負の数）
    var captionRemaining: Int {
        SoratomoTextRules.captionMax - SoratomoTextRules.length(caption)
    }

    /// キャプションが上限（100 文字）を超えているか（超えている間は確定できない・要件 6.4）
    var isCaptionOverLimit: Bool {
        !SoratomoTextRules.isCaptionWithinLimit(caption)
    }

    /// 確定できるか（写真が使えて、キャプションが上限以内で、送信中・完了後でない）
    var canSubmit: Bool {
        photoData != nil && !isCaptionOverLimit && !isBusy && phase != .finished
    }

    /// 失敗の文言（失敗していなければ nil）
    var failureMessage: String? {
        guard case let .failed(message) = phase else { return nil }
        return message
    }

    // MARK: - 入力

    /// キャプションの入力を受け取る（改行を取り除く・要件 6.3）
    ///
    /// 上限を超えた入力も切り詰めずに残し、超えたことを画面に示す（要件 6.4）。
    /// - Parameter raw: 入力されたままのキャプション
    func updateCaption(_ raw: String) {
        let sanitized = SoratomoTextRules.sanitizeCaption(raw)
        if sanitized != caption {
            caption = sanitized
        }
    }

    /// 写真の選択の結果を受け取り、プレビューを作る
    ///
    /// 読めない写真（バイト列を取り出せない・画像として開けない）なら、写真を持たずに
    /// 「使えない」ことを伝える。投稿は始めない（要件 7.5）。
    /// - Parameter data: 写真の元のバイト列（取り出せなかったら nil）
    func selectPhoto(_ data: Data?) async {
        // 送信中は選び直させない（送っている写真と画面の写真が食い違うため）
        guard !isBusy, phase != .finished else { return }

        photoGeneration += 1
        let generation = photoGeneration

        guard let data, !data.isEmpty else {
            showUnreadablePhoto()
            return
        }

        // プレビュー作りは画像の展開を伴うので、メインアクターの外で行う
        let preview = await Self.makePreview(from: data)

        // 待っている間に別の写真が選ばれていたら、古い結果は捨てる
        guard generation == photoGeneration else { return }

        guard let preview else {
            showUnreadablePhoto()
            return
        }
        photoData = data
        previewImage = preview
        photoErrorMessage = nil
        // 失敗の後に写真を選び直したら、入力中に戻す
        if case .failed = phase {
            phase = .editing
        }
    }

    // MARK: - 送信

    /// 投稿を確定する（再試行も同じ操作）
    ///
    /// 送信中・完了後・確定できない入力のときは何もしない（二重の確定を受け付けない・要件 6.7）。
    func submit() async {
        // ⚠️ 最初の `await` より前に段階を進める。ここより後で進めると、事前確認を待っている間に
        //    2 回目の確定が入り込み、投稿が 2 件できる
        guard canSubmit, let photoData else { return }
        phase = .checking

        // 所要時間は「確定から完了まで」（soratomo_post_created の duration_ms）
        let startedAt = now()
        let captionToSend = caption

        // 未ログインでは送れない（通常はここに来ない。サインアウト時の画面の破棄は 14.1）
        guard let uid = currentUid() else {
            phase = .failed(message: SoratomoError.unknown.userMessage)
            return
        }

        // 1. 事前確認（止めたときは写真とキャプションを残す・要件 6.12・12.2）
        guard await passesPrecheck(uid: uid) else { return }

        // 2. 試行ごとに新しい投稿 ID（失敗の後の再試行で、前の試行の画像や投稿と混ざらないため）
        let skyId = skyService.newSkyId(groupId: groupId)
        let paths = SoratomoImagePaths(groupId: groupId, authorId: uid, skyId: skyId)

        // 背景へ移っても、OS の猶予の中で続ける（要件 6.11）
        startBackgroundTask()
        defer { finishBackgroundTask() }

        // 3. 変換
        phase = .encoding
        let images: SoratomoEncodedImages
        switch await encode(photoData) {
        case let .success(encoded):
            images = encoded
        case let .failure(error):
            SoratomoError.record(error, context: "soratomo.encodeSkyImage")
            fail(stage: .image, error: error)
            return
        }
        // 変換は途中で止められないので、終わった直後に猶予切れを確かめる（まだ何も送っていない）
        if backgroundExpired {
            fail(stage: .image, error: .backgroundExpired)
            return
        }

        // 4. 2 枚の並行アップロード
        phase = .uploading(progress: 0)
        uploadingPaths = paths
        do {
            try await imageStore.upload(images, to: paths) { [weak self] value in
                // 進み具合はどのスレッドからも来うるので、メインアクターへ移してから反映する
                Task { @MainActor [weak self] in
                    self?.updateUploadProgress(value)
                }
            }
        } catch {
            uploadingPaths = nil
            // 猶予切れで取り消した upload は `.unknown` で返る。猶予切れとして扱う
            let reason: SoratomoError = backgroundExpired && error == .unknown ? .backgroundExpired : error
            SoratomoError.record(reason, context: "soratomo.uploadSkyImages")
            // 片方だけ届いていることがあるので、消してから失敗を出す（要件 12.4）
            _ = await imageStore.delete(paths)
            fail(stage: .upload, error: reason)
            return
        }
        uploadingPaths = nil
        // アップロードが終わった直後に猶予が切れていたら、保存を送らずに後始末する
        if backgroundExpired {
            _ = await imageStore.delete(paths)
            fail(stage: .upload, error: .backgroundExpired)
            return
        }

        // 5. 保存（画像が 2 枚そろってからだけ・要件 6.6）。ここからは猶予切れでも中止しない
        phase = .saving
        let draft = SoratomoSkyDraft(
            groupId: groupId,
            skyId: skyId,
            authorId: uid,
            caption: captionToSend.isEmpty ? nil : captionToSend,
            pixelWidth: images.pixelWidth,
            pixelHeight: images.pixelHeight
        )
        do {
            try await skyService.createSky(draft)
        } catch {
            // 失敗の記録は handleSaveFailure の中で行う（サーバーにあった＝成功のときは記録しない）
            guard await handleSaveFailure(error, paths: paths, skyId: skyId) else { return }
        }

        // 完了（新しい投稿はタイムラインの監視で先頭に届く・要件 6.8）
        let durationMs = Int((now().timeIntervalSince(startedAt) * 1000).rounded())
        logEvent(.postCreated(hasCaption: !captionToSend.isEmpty, durationMs: max(0, durationMs)))
        phase = .finished
    }

    // MARK: - Private: 事前確認

    /// 通信の有無と、今日の自分の投稿件数を確かめる
    ///
    /// - 件数が数えられなかった（nil）ときは止めない（tasks 11.2・13.7）
    /// - 止めたときは `soratomo_post_failed`（stage は precheck）を記録する。
    ///   ⚠️ 事前確認で止めたことは「検査」の結果なので、非致命エラーとしては記録しない
    /// - Returns: 進めてよければ true
    private func passesPrecheck(uid: String) async -> Bool {
        guard isOnline() else {
            fail(stage: .precheck, error: .network)
            return false
        }
        let since = SoratomoDaySection.startOfDay(for: now())
        if let count = await skyService.countTodaySkies(groupId: groupId, authorId: uid, since: since),
           count >= Self.dailyPostLimit
        {
            fail(stage: .precheck, error: .dailyLimit)
            return false
        }
        return true
    }

    // MARK: - Private: 保存の失敗

    /// 保存の失敗の後始末をする
    ///
    /// - `.network` の失敗は、保存の結果が確定していないことがある。サーバーで投稿の有無を確かめ、
    ///   あれば成功として扱う。無ければ画像を消して失敗にする。確かめられなければ、画像を残して失敗にする
    ///   （画像の無い投稿よりも、取り残しの画像を選ぶ・design.md「投稿と通知」）
    /// - それ以外の失敗は、画像を消してから失敗にする（要件 6.9）
    /// - Returns: 成功として扱ってよければ true
    private func handleSaveFailure(_ error: SoratomoError, paths: SoratomoImagePaths, skyId: String) async -> Bool {
        if error == .network {
            do {
                if try await skyService.skyExistsOnServer(groupId: groupId, skyId: skyId) {
                    return true
                }
            } catch let verificationError {
                // 確かめられなかった。投稿があるかもしれないので、画像は消さない。
                // 計測の reason は保存の失敗（error）で出し、確かめの失敗は別の文脈で記録する
                SoratomoError.record(error, context: "soratomo.createSky")
                SoratomoError.record(verificationError, context: "soratomo.skyExistsOnServer")
                fail(stage: .save, error: error)
                return false
            }
        }
        SoratomoError.record(error, context: "soratomo.createSky")
        _ = await imageStore.delete(paths)
        fail(stage: .save, error: error)
        return false
    }

    // MARK: - Private: 失敗と進み具合

    /// 失敗として扱う（入力は残し、`soratomo_post_failed` を記録する）
    private func fail(stage: SoratomoPostFailStage, error: SoratomoError) {
        logEvent(.postFailed(stage: stage, reason: SoratomoPostFailReason(stage: stage, error: error)))
        phase = .failed(message: error.userMessage)
    }

    /// 読めない写真を選んだときの表示にする（写真は持たない）
    private func showUnreadablePhoto() {
        photoData = nil
        previewImage = nil
        photoErrorMessage = SoratomoError.imageUnreadable.userMessage
    }

    /// アップロードの進み具合を反映する（アップロード中だけ。保存へ進んだ後に届いた遅い値は捨てる）
    private func updateUploadProgress(_ value: Double) {
        guard case .uploading = phase else { return }
        phase = .uploading(progress: min(max(value, 0), 1))
    }

    // MARK: - Private: 背景の処理

    /// 背景で処理を続ける口を開く（試行ごとに 1 回）
    private func startBackgroundTask() {
        backgroundExpired = false
        backgroundTaskId = beginBackgroundTask { [weak self] in
            self?.handleBackgroundExpiration()
        }
    }

    /// 猶予が切れたときの処理（OS がメインスレッドで呼ぶ）
    ///
    /// 変換中とアップロード中だけ中止する。保存を送った後は中止せず、結果を待つ（要件 6.11）。
    /// ⚠️ この処理から戻る前に口を閉じないと、OS にアプリを終了させられる。
    private func handleBackgroundExpiration() {
        switch phase {
        case .encoding:
            // 変換は途中で止められない。終わった直後に `submit()` が見て失敗にする
            backgroundExpired = true
        case .uploading:
            backgroundExpired = true
            if let uploadingPaths {
                // 取り消した upload は `.unknown` で返り、`submit()` が後始末する
                imageStore.cancelUploads(to: uploadingPaths)
            }
        case .editing, .checking, .saving, .failed, .finished:
            break
        }
        finishBackgroundTask()
    }

    /// 背景で処理を続ける口を閉じる（2 回目以降は何もしない）
    private func finishBackgroundTask() {
        guard let id = backgroundTaskId else { return }
        backgroundTaskId = nil
        endBackgroundTask(id)
    }

    // MARK: - 既定の依存

    /// `SoratomoImageEncoder.encode` をメインアクターの外で呼ぶ（CPU を使う同期処理のため）
    ///
    /// 失敗は `Result` で返す（`Encode` の注意を参照。typed throws の関数の型は iOS 18 が要るため）。
    nonisolated static func encodeOffMainActor(_ data: Data) async -> Result<SoratomoEncodedImages, SoratomoError> {
        await Task.detached(priority: .userInitiated) { () -> Result<SoratomoEncodedImages, SoratomoError> in
            // クロージャの中の do / catch は、投げる型を書かないと `any Error` に推論されるので、明示する
            do throws(SoratomoError) {
                return try .success(SoratomoImageEncoder.encode(source: data))
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// 本番の背景の口（`UIApplication.beginBackgroundTask`）
    ///
    /// 猶予切れのハンドラは OS がメインスレッドで呼ぶので、メインアクターの処理として呼ぶ。
    static func beginApplicationBackgroundTask(
        _ onExpiration: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "soratomo.post") {
            MainActor.assumeIsolated {
                onExpiration()
            }
        }
    }

    /// 本番の背景の口を閉じる（`UIApplication.endBackgroundTask`）
    static func endApplicationBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    /// 元のバイト列から、向きを画素に反映したプレビューを作る（メインアクターの外）
    ///
    /// 開き方と縮小は送信用の変換（`SoratomoImageEncoder.openSource`・`renderImage`）と同じ部品を使う。
    /// - Returns: 読めなければ nil
    nonisolated static func makePreview(from data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let opened = try? SoratomoImageEncoder.openSource(data),
                  let cgImage = SoratomoImageEncoder.renderImage(from: opened, maxPixel: previewMaxPixel)
            else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}
