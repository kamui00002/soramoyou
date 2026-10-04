//
//  SoratomoImageStore.swift
//  Soramoyou
//
//  そらともの画像の保存（アップロード）と削除、Storage のエラーの写し ⭐️
//  （tasks 11.4・design.md の SoratomoImageStore・要件 6.6・6.9・6.11・8.17・8.20・11.5・11.13）
//
//  ⚠️ ダウンロード URL を作らず、保存しない（要件 8.14・11.13）。
//     画像の取得は SoratomoStorageImageProvider.swift の `getData` だけで行う。
//     パスは `SoratomoImagePaths` だけから受け取る（このファイルで文字列を組み立てない）。
//     計測（SoratomoAnalytics.log）は呼ばない（画面の ViewModel＝tasks 13.x の責務）。
//

import FirebaseStorage
import Foundation

// MARK: - 2 枚の進み具合

/// 表示用とサムネイルの 2 枚を合わせた、アップロードの進み具合
///
/// Storage の進み具合は 1 枚ごとにバイト数で届く。画面には 2 枚を合わせた 0.0〜1.0 を 1 本だけ出すので、
/// 送るデータの大きさ（バイト）を分母にして、2 枚の送れたバイト数を足して割る。
/// Storage に依存しない値の計算だけを持つので、単体テストで確かめられる。
struct SoratomoImageStoreProgress: Sendable {
    /// 1 枚ごとの、送るバイト数
    private let totals: [Int64]
    /// 1 枚ごとの、送れたバイト数
    private var completed: [Int64]
    /// 1 枚ごとの、送り終えたか
    private var finished: [Bool]

    /// - Parameter totals: 1 枚ごとの、送るバイト数（`Data.count`）。負の値は 0 とみなす
    init(totals: [Int64]) {
        self.totals = totals.map { max($0, 0) }
        completed = Array(repeating: 0, count: totals.count)
        finished = Array(repeating: false, count: totals.count)
    }

    /// 1 枚の進み具合を反映する
    ///
    /// 後ろへは戻さない（再試行で小さい値が届いても、表示の進み具合を巻き戻さない）。
    /// 送るバイト数を超えた値は、送るバイト数に丸める。範囲外の `index` は無視する。
    /// - Parameters:
    ///   - index: 何枚目か（0 始まり）
    ///   - completedBytes: その 1 枚の、送れたバイト数
    mutating func update(index: Int, completedBytes: Int64) {
        guard totals.indices.contains(index), !finished[index] else { return }
        let clamped = min(max(completedBytes, 0), totals[index])
        completed[index] = max(completed[index], clamped)
    }

    /// 1 枚を送り終えたことを反映する（最後の進み具合が届かなくても、その 1 枚は 100% にする）
    mutating func finish(index: Int) {
        guard totals.indices.contains(index) else { return }
        completed[index] = totals[index]
        finished[index] = true
    }

    /// 2 枚を合わせた進み具合（0.0〜1.0）
    var fraction: Double {
        let total = totals.reduce(0, +)
        guard total > 0 else {
            // 分母が 0 のときは、割れない。全部送り終えていたときだけ 100% にする
            return (!finished.isEmpty && finished.allSatisfy { $0 }) ? 1.0 : 0.0
        }
        let done = completed.reduce(0, +)
        return min(max(Double(done) / Double(total), 0.0), 1.0)
    }
}

// MARK: - Storage のエラーの写し

/// Storage（と通信）のエラーを `SoratomoError` へ写す
///
/// Wave 0 の `SoratomoError.fromFirestore` は Firestore と NSURLError だけを扱うので、
/// Storage のエラー（`FIRStorageErrorDomain`）の写しはここに置く。
///
/// | 元のエラー | アップロード | 取得 |
/// |---|---|---|
/// | `SoratomoError` | そのまま | そのまま |
/// | `NSURLErrorDomain`（取り消しを除く） | `.network` | `.network` |
/// | Storage の `unknown` が包んでいる通信のエラー（取り消しを除く） | `.network` | `.network` |
/// | `retryLimitExceeded`（再試行の時間切れ） | `.network` | `.network` |
/// | `unauthorized` | `.permissionDenied` | `.notMember` |
/// | `unauthenticated` | `.permissionDenied` | `.permissionDenied` |
/// | それ以外（`cancelled`・`objectNotFound` など） | `.unknown` | `.unknown` |
///
/// - `unauthorized` は、Storage のルール（メンバーの判定・フラグ・本人のパス）が拒否したとき。
///   取得では「メンバーでない」、書き込みでは「ルールに拒否された」と読む。
/// - 取り消し（`cancelled`）は、このファイルの `SoratomoImageStore` が制限時間か取り消しで止めたもの。
///   制限時間の判定（`.uploadTimeout`）は、止めた側が知っているので、ここでは `.unknown` にする。
enum SoratomoImageStoreErrorMapping {
    /// 失敗した操作（権限の拒否の意味が変わる）
    enum Operation {
        /// 画像の保存（書き込み）
        case upload
        /// 画像の取得（読み取り）
        case download
    }

    /// Storage のエラーの、ドメインとコード（`FirebaseStorage` の定義を使う）
    private static let storageDomain = StorageErrorDomain

    /// エラーを写す
    /// - Parameters:
    ///   - error: 元のエラー
    ///   - operation: 失敗した操作
    /// - Returns: 写した種類
    static func map(_ error: Error, operation: Operation) -> SoratomoError {
        if let soratomoError = error as? SoratomoError {
            return soratomoError
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // 取り消しは通信の失敗ではない（呼び出し側が止めた）
            return nsError.code == NSURLErrorCancelled ? .unknown : .network
        }
        guard nsError.domain == storageDomain else {
            return .unknown
        }
        switch nsError.code {
        case StorageErrorCode.unauthorized.rawValue:
            return operation == .download ? .notMember : .permissionDenied
        case StorageErrorCode.unauthenticated.rawValue:
            return .permissionDenied
        case StorageErrorCode.retryLimitExceeded.rawValue:
            return .network
        case StorageErrorCode.unknown.rawValue:
            // Storage は、HTTP の状態ではない失敗（圏外など）を `unknown` に包んで返す。
            // 元の通信のエラーが取り出せれば、通信の失敗として扱う
            if let code = wrappedURLErrorCode(in: nsError) {
                return code == NSURLErrorCancelled ? .unknown : .network
            }
            return .unknown
        default:
            return .unknown
        }
    }

    /// もともと無かった（`objectNotFound`）ことによる失敗か
    ///
    /// 削除では、もともと無いものは「消えた」と同じ扱いにする。
    static func isObjectNotFound(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == storageDomain && nsError.code == StorageErrorCode.objectNotFound.rawValue
    }

    /// Storage のエラーが包んでいる、通信（`NSURLErrorDomain`）の元のエラーのコードを探す
    ///
    /// Storage は元のエラーのドメインとコードを `ResponseErrorDomain`・`ResponseErrorCode` に、
    /// 元のエラー自体を `NSUnderlyingErrorKey` に入れる。
    private static func wrappedURLErrorCode(in nsError: NSError) -> Int? {
        if nsError.userInfo["ResponseErrorDomain"] as? String == NSURLErrorDomain {
            return nsError.userInfo["ResponseErrorCode"] as? Int
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain
        {
            return underlying.code
        }
        return nil
    }
}

// MARK: - 1 回のアップロード（2 枚）

/// 1 回のアップロード（表示用とサムネイルの 2 枚）の状態
///
/// Storage のコールバックは主スレッド、制限時間の判定は別のスレッド、取り消しは呼び出し元のスレッドから
/// 触られる。状態はすべて `lock` の中でだけ読み書きする。
/// 継続（`continuation`）の再開と、進み具合・タスクの取り消しは、ロックの外で行う
/// （中で呼ぶと、呼び出し先が戻ってきて同じロックを取ろうとして止まる）。
private final class SoratomoImageStoreUploadSession: @unchecked Sendable {
    /// 取り消しの理由
    enum CancelReason {
        /// 1 枚あたりの制限時間を超えた
        case timeout
        /// `cancelUploads(to:)` で取り消された
        case requested
    }

    /// 送る 1 枚
    struct Item {
        /// 置き場所
        let reference: StorageReference
        /// 送る JPEG
        let data: Data
    }

    /// 送る 2 枚
    private let items: [Item]
    /// 1 枚あたりの制限時間（秒）
    private let timeoutSeconds: TimeInterval
    /// 2 枚を合わせた進み具合の通知先
    private let onProgress: @Sendable (Double) -> Void

    /// 以下の状態を守るロック
    private let lock = NSLock()
    /// 2 枚を合わせた進み具合
    private var progress: SoratomoImageStoreProgress
    /// 1 枚ごとの Storage のタスク（取り消すために持つ）
    private var tasks: [StorageUploadTask?]
    /// 1 枚ごとの、制限時間の見張り
    private var timers: [DispatchWorkItem?]
    /// 1 枚ごとの、結果が届いたか
    private var finished: [Bool]
    /// 全体の結果が決まったか（決まった後に届いたコールバックは無視する）
    private var isDone = false
    /// 取り消した理由（取り消していなければ nil）
    private var cancelReason: CancelReason?
    /// 結果を待っている呼び出し元（1 回だけ再開する）
    private var continuation: CheckedContinuation<Result<Void, SoratomoError>, Never>?

    init(items: [Item], timeoutSeconds: TimeInterval, onProgress: @escaping @Sendable (Double) -> Void) {
        self.items = items
        self.timeoutSeconds = timeoutSeconds
        self.onProgress = onProgress
        progress = SoratomoImageStoreProgress(totals: items.map { Int64($0.data.count) })
        tasks = Array(repeating: nil, count: items.count)
        timers = Array(repeating: nil, count: items.count)
        finished = Array(repeating: false, count: items.count)
    }

    /// 2 枚を並行して送り、結果が決まるまで待つ
    ///
    /// 1 枚でも失敗したら、残りを取り消して、先に失敗した理由で終わる（投稿は 2 枚そろわないと作らない）。
    func run() async -> Result<Void, SoratomoError> {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            for index in items.indices {
                start(index: index)
            }
        }
    }

    /// 進行中のアップロードを取り消す（2 回目以降・結果が決まった後は何もしない）
    func cancel() {
        lock.lock()
        guard !isDone else {
            lock.unlock()
            return
        }
        if cancelReason == nil {
            cancelReason = .requested
        }
        let tasksToCancel = unfinishedTasksLocked()
        lock.unlock()
        tasksToCancel.forEach { $0.cancel() }
    }

    // MARK: - 開始

    /// 1 枚の送信を始める
    private func start(index: Int) {
        let item = items[index]
        let metadata = StorageMetadata()
        // 種類は JPEG にする（storage.rules は image/jpeg だけを許す・要件 11.5）。
        // contentType が無いと Storage の SDK は異常終了するので、必ず指定する
        metadata.contentType = "image/jpeg"

        // 完了のコールバックは、取り消しを含むすべての終わり方で 1 回だけ呼ばれる
        let task = item.reference.putData(item.data, metadata: metadata) { [weak self] _, error in
            self?.handleCompletion(index: index, error: error)
        }
        task.observe(.progress) { [weak self] snapshot in
            self?.handleProgress(index: index, completedBytes: snapshot.progress?.completedUnitCount ?? 0)
        }

        // 1 枚あたりの制限時間の見張り。送り終えたら handleCompletion が止める
        let timer = DispatchWorkItem { [weak self] in
            self?.handleTimeout(index: index)
        }
        lock.lock()
        tasks[index] = task
        timers[index] = timer
        // タスクを作る前に取り消し・失敗が決まっていたら、このタスクもすぐ止める
        let shouldCancelNow = cancelReason != nil || isDone
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)
        if shouldCancelNow {
            task.cancel()
        }
    }

    // MARK: - Storage からの通知

    /// 進み具合が届いた
    private func handleProgress(index: Int, completedBytes: Int64) {
        lock.lock()
        guard !isDone else {
            lock.unlock()
            return
        }
        progress.update(index: index, completedBytes: completedBytes)
        let fraction = progress.fraction
        lock.unlock()
        onProgress(fraction)
    }

    /// 1 枚の結果（成功か失敗）が届いた
    private func handleCompletion(index: Int, error: Error?) {
        lock.lock()
        guard !isDone, !finished[index] else {
            lock.unlock()
            return
        }
        finished[index] = true
        timers[index]?.cancel()
        timers[index] = nil

        if let error {
            // 1 枚でも失敗したら全体の失敗。先に失敗した理由で決める
            let result = Result<Void, SoratomoError>.failure(resolveFailure(error, reason: cancelReason))
            let (tasksToCancel, continuation) = completeLocked()
            lock.unlock()
            tasksToCancel.forEach { $0.cancel() }
            continuation?.resume(returning: result)
            return
        }

        progress.finish(index: index)
        let fraction = progress.fraction
        let allFinished = finished.allSatisfy { $0 }
        let continuation = allFinished ? completeLocked().continuation : nil
        lock.unlock()
        // 2 枚目の成功では、100% を通知してから結果を返す
        onProgress(fraction)
        continuation?.resume(returning: .success(()))
    }

    /// 1 枚が制限時間を超えた
    private func handleTimeout(index: Int) {
        lock.lock()
        guard !isDone, !finished[index] else {
            lock.unlock()
            return
        }
        if cancelReason == nil {
            cancelReason = .timeout
        }
        let tasksToCancel = unfinishedTasksLocked()
        lock.unlock()
        // 取り消された各タスクの失敗が handleCompletion に届き、`.uploadTimeout` で終わる
        tasksToCancel.forEach { $0.cancel() }
    }

    // MARK: - 状態の整理（ロックの中で呼ぶ）

    /// まだ結果が届いていないタスク
    private func unfinishedTasksLocked() -> [StorageUploadTask] {
        tasks.enumerated().compactMap { offset, task in
            finished[offset] ? nil : task
        }
    }

    /// 全体の結果が決まったときの後始末。止めるタスクと、結果を返す継続を取り出す
    private func completeLocked() -> (tasksToCancel: [StorageUploadTask], continuation: CheckedContinuation<Result<Void, SoratomoError>, Never>?) {
        isDone = true
        for timer in timers {
            timer?.cancel()
        }
        timers = Array(repeating: nil, count: timers.count)
        let tasksToCancel = unfinishedTasksLocked()
        tasks = Array(repeating: nil, count: tasks.count)
        let waitingContinuation = continuation
        continuation = nil
        return (tasksToCancel, waitingContinuation)
    }

    /// 失敗の理由を決める
    ///
    /// 制限時間で止めたなら `.uploadTimeout`、取り消しで止めたなら `.unknown`
    /// （バックグラウンドの猶予切れなど、取り消した理由は呼び出し側＝tasks 13.x が知っている）、
    /// どちらでもなければ Storage のエラーを写す。
    private func resolveFailure(_ error: Error, reason: CancelReason?) -> SoratomoError {
        switch reason {
        case .timeout:
            .uploadTimeout
        case .requested:
            .unknown
        case nil:
            SoratomoImageStoreErrorMapping.map(error, operation: .upload)
        }
    }
}

// MARK: - 画像の保存と削除

/// 画像の保存（アップロード）と削除（`SoratomoImageStoreProtocol` の実装）
///
/// - アップロードは表示用とサムネイルの 2 枚を並行して送り、種類は `image/jpeg`。
///   1 枚あたり 45 秒の制限時間（超えたら `.uploadTimeout`）か、`cancelUploads(to:)` で中止する。
///   既存の `Storage` の再試行時間（`maxUploadRetryTime` など）の設定は変えない
///   （制限時間はこのクラスが別に見張る）。
/// - 削除は 2 枚を並行して行う。もともと無いものは消えた扱い。それ以外の失敗は非致命エラーとして
///   記録し、`.partiallyFailed` を返す（要件 8.20）。
/// - キャッシュは消さない。投稿を削除したときは、続けて `SoratomoImageCache.remove(_:)` を呼ぶこと。
final class SoratomoImageStore: SoratomoImageStoreProtocol, @unchecked Sendable {
    /// 1 枚あたりのアップロードの制限時間（秒）
    static let uploadTimeoutSeconds: TimeInterval = 45

    /// 画像の置き場（既存のサービスと同じ、既定の Storage）
    private let storage: Storage
    /// 1 枚あたりの制限時間（秒）
    private let uploadTimeout: TimeInterval

    /// 進行中のアップロードを守るロック
    private let lock = NSLock()
    /// 進行中のアップロード（置き場所ごと）。`cancelUploads(to:)` が探すために持つ
    private var sessions: [SoratomoImagePaths: SoratomoImageStoreUploadSession] = [:]

    /// - Parameters:
    ///   - storage: 使う Storage。既定は既存のサービスと同じ `Storage.storage()`
    ///   - uploadTimeout: 1 枚あたりの制限時間（秒）。既定は 45 秒
    init(storage: Storage = Storage.storage(), uploadTimeout: TimeInterval = SoratomoImageStore.uploadTimeoutSeconds) {
        self.storage = storage
        self.uploadTimeout = uploadTimeout
    }

    // MARK: - アップロード

    func upload(
        _ images: SoratomoEncodedImages,
        to paths: SoratomoImagePaths,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(SoratomoError) {
        let root = storage.reference()
        let session = SoratomoImageStoreUploadSession(
            items: [
                .init(reference: root.child(paths.display), data: images.display),
                .init(reference: root.child(paths.thumbnail), data: images.thumbnail),
            ],
            timeoutSeconds: uploadTimeout,
            onProgress: progress
        )

        // 結果を待つ前に登録する（登録の後に `cancelUploads(to:)` が来ても、止められるように）
        register(session, for: paths)
        let result = await session.run()
        unregister(session, for: paths)

        switch result {
        case .success:
            return
        case let .failure(error):
            throw error
        }
    }

    func cancelUploads(to paths: SoratomoImagePaths) {
        lock.lock()
        let session = sessions[paths]
        lock.unlock()
        // ロックの外で取り消す（取り消しが、結果の通知とアップロードの後始末を呼ぶため）
        session?.cancel()
    }

    /// 進行中のアップロードとして登録する
    ///
    /// ロックの出し入れは、非同期の関数（`upload`）の中で直接せず、この同期の関数に分ける
    /// （`NSLock` は非同期の文脈から呼ぶと警告になるため）。
    private func register(_ session: SoratomoImageStoreUploadSession, for paths: SoratomoImagePaths) {
        lock.lock()
        sessions[paths] = session
        lock.unlock()
    }

    /// 進行中の登録を外す
    ///
    /// 自分が登録したものだけを外す（同じ置き場所で後から始まったアップロードを消さない）。
    private func unregister(_ session: SoratomoImageStoreUploadSession, for paths: SoratomoImagePaths) {
        lock.lock()
        if sessions[paths] === session {
            sessions[paths] = nil
        }
        lock.unlock()
    }

    // MARK: - 削除

    func delete(_ paths: SoratomoImagePaths) async -> SoratomoImageDeleteOutcome {
        // 2 枚を並行して消す。片方が失敗しても、もう片方は消す
        async let displayDeleted = deleteOne(path: paths.display, context: "soratomo.deleteImage.display")
        async let thumbnailDeleted = deleteOne(path: paths.thumbnail, context: "soratomo.deleteImage.thumbnail")
        let results = await (displayDeleted, thumbnailDeleted)
        return (results.0 && results.1) ? .deleted : .partiallyFailed
    }

    /// 1 枚を消す
    /// - Parameters:
    ///   - path: `SoratomoImagePaths` から受け取った Storage のパス
    ///   - context: 失敗を記録するときの、固定の文脈（利用者の入力・ID を混ぜない）
    /// - Returns: 消えたか（もともと無かった場合を含む）。失敗したら false
    private func deleteOne(path: String, context: StaticString) async -> Bool {
        do {
            try await storage.reference().child(path).delete()
            return true
        } catch {
            if SoratomoImageStoreErrorMapping.isObjectNotFound(error) {
                return true
            }
            // 投稿は消えているので画面には出さない。非致命エラーとして記録する（要件 8.20）
            SoratomoError.record(error, context: context)
            return false
        }
    }
}
