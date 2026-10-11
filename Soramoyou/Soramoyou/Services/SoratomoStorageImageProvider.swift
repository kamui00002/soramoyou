//
//  SoratomoStorageImageProvider.swift
//  Soramoyou
//
//  そらともの画像の取得（メンバー判定を経る）と、そらとも専用の画像キャッシュ ⭐️
//  （tasks 11.4・design.md の SoratomoStorageImageProvider・SoratomoImageCache・
//   要件 8.14・11.13・12.1・12.4。グループごとのキャッシュは leave-group 7.3・要件 5.4・5.5）
//
//  ⚠️ ダウンロード URL を作らず、保存しない（要件 8.14・11.13）。
//     トークン付きの URL は、知っている人なら誰でも見られてしまう。
//     取得は `StorageReference.getData` だけで行う。これは毎回 Storage のルール
//     （グループのメンバーか）を通るので、グループを抜けた人・外された人は、その後は見られない。
//

import FirebaseStorage
import Foundation
import Kingfisher

// MARK: - 取得

/// そらともの画像を、Storage から取得して Kingfisher に渡す提供元
///
/// 使い方（画面側 = tasks 13.x）:
/// ```swift
/// KFImage(source: .provider(SoratomoStorageImageProvider(storagePath: sky.imagePaths.thumbnail)))
///     // ⚠️ 必ず付ける（付けないと、サインアウトでも抜けたときでも消えない）。パスは provider と同じもの
///     .targetCache(SoratomoImageCache.cache(forStoragePath: sky.imagePaths.thumbnail))
/// ```
/// - `storagePath` には、`SoratomoImagePaths` の `display` か `thumbnail` をそのまま渡す（自分で組み立てない）。
/// - キャッシュの鍵は `storagePath` そのもの。キャッシュにあれば、Storage には問い合わせない。
/// - 取得に失敗したときは、`SoratomoError`（`SoratomoImageStoreErrorMapping`）を `handler` に渡す。
///   Kingfisher は、これを `KingfisherError` に包んで画面側に返す。
struct SoratomoStorageImageProvider: ImageDataProvider {
    /// 1 枚あたりの、取得できる最大のバイト数
    ///
    /// 表示用の上限（1,572,864 バイト）より大きく、これを超える画像は取得しない。
    static let maxDataBytes: Int64 = 2_000_000

    /// 取得する画像の Storage のパス（`SoratomoImagePaths` の `display` か `thumbnail`）
    let storagePath: String

    /// キャッシュの鍵（Storage のパスそのもの）
    var cacheKey: String {
        storagePath
    }

    /// 画像のデータを取得する
    ///
    /// - Note: `contentURL` は実装しない（既定の nil のまま）。ダウンロード URL を持たないため。
    func data(handler: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        Storage.storage().reference().child(storagePath).getData(maxSize: Self.maxDataBytes) { data, error in
            if let data, error == nil {
                handler(.success(data))
            } else {
                // 権限の拒否・通信の失敗などを、そらともの失敗の種類に写して返す
                handler(.failure(SoratomoImageStoreErrorMapping.map(error ?? SoratomoError.unknown, operation: .download)))
            }
        }
    }
}

// MARK: - キャッシュ

/// そらとも専用の画像キャッシュ（アプリで使う口）
///
/// 既存の画面が使う Kingfisher の標準のキャッシュとは分ける。分けるのは、サインアウトのときに、
/// そらともの画像だけを（既存の画像に触らずに）消すため。
/// さらにグループごとにキャッシュを分ける（leave-group 7.3・要件 5.4・5.5）。グループを抜けたときに、
/// そのグループの画像だけを消すため。Kingfisher のディスクのファイル名は鍵のハッシュなので、
/// 1 つのキャッシュの中からグループの分だけを選んで消すことはできない。
/// 中身は `SoratomoGroupImageCaches`（テストでは一時フォルダで作る）。ここは本番用の 1 つへ流すだけ。
/// 鍵は Storage のパス（`SoratomoStorageImageProvider.cacheKey`）。
///
/// ⚠️ 画面側は、必ず `.targetCache(SoratomoImageCache.cache(forStoragePath: path))` を付けて読み込む
///    （`path` は provider に渡したものと同じ）。付け忘れると標準のキャッシュに入り、
///    `clear()` でも `remove(_:)` でも `removeGroup(_:)` でも消えない。
/// ⚠️ 画面側は、画像に processor（ダウンサンプリングなど）を付けない。付けると鍵が
///    `パス@processor の識別子` になり、`remove(_:)` が消す鍵と一致しなくなる。
enum SoratomoImageCache {
    /// グループに属さない共通のキャッシュ（名前 `soratomo`）
    ///
    /// - パスの形が `soratomo/{groupId}/…` でないときの受け皿（壊れた値で落とさないため。ふつうは空のまま）。
    /// - 1.14.x はすべてのグループの画像をここに入れていた。グループ単位で消せないので、
    ///   `purgeLegacyIfNeeded()` が 1 回だけ消す。`clear()` も消す。
    static let shared = ImageCache(name: "soratomo")

    /// 1.14.x の共通のキャッシュを消したかの印（UserDefaults のキー）
    static let legacyPurgedKey = "soratomo.legacyImageCachePurged"

    /// 本番用のグループごとのキャッシュ（親のフォルダは `Caches/soratomo-images/`）
    private static let live = SoratomoGroupImageCaches(
        parentDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("soratomo-images", isDirectory: true),
        fallback: shared
    )

    /// 画像の Storage のパスに合う、グループのキャッシュ
    /// - Parameter path: 画像の Storage のパス（`SoratomoImagePaths` の `display` か `thumbnail`）
    /// - Returns: そのグループのキャッシュ。パスの形が違えば `shared`
    static func cache(forStoragePath path: String) -> ImageCache {
        live.cache(forStoragePath: path)
    }

    /// そらとものキャッシュを、すべて消す（メモリとディスク）
    ///
    /// サインアウトで呼ぶ（呼び出しの配線は tasks 14.1）。別のアカウントに、前のアカウントの画像を見せないため。
    /// すべてのグループのキャッシュ（親のフォルダごと）と、`shared` を消す。
    /// ディスクの削除は裏で行われ、完了を待たない。
    static func clear() {
        live.clear()
    }

    /// 投稿の 2 枚（表示用・サムネイル）の鍵を、そのグループのキャッシュから消す
    ///
    /// 投稿を削除したときに呼ぶ（削除した画像が、端末に残らないように）。
    /// - Parameter paths: 消す投稿の画像の置き場所
    static func remove(_ paths: SoratomoImagePaths) {
        live.remove(paths)
    }

    /// 1 つのグループのキャッシュを、メモリとディスク（フォルダごと）から消す（グループを抜けたとき）
    ///
    /// ⚠️ タイムラインを閉じて監視を止めた後に呼ぶ（呼ぶのは 8.5）。画面が残っていると、再描画で
    ///    同じグループのキャッシュが作り直され、フォルダも戻る（Kingfisher は、書き込むときにフォルダが無ければ作る）。
    /// - Parameter groupId: 抜けたグループ ID
    static func removeGroup(_ groupId: String) {
        live.removeGroup(groupId)
    }

    /// 1.14.x の共通のキャッシュ（`shared`）を、1 回だけ消す（起動の後に呼ぶ。呼ぶ場所は 8.5）
    static func purgeLegacyIfNeeded() {
        live.purgeLegacyIfNeeded(defaults: .standard)
    }
}

/// 記録（非致命エラー）に残す、画像のキャッシュの失敗（ID もパスも持たない）
///
/// Kingfisher のエラーはフォルダのパス（グループ ID を含む）を持つので、そのまま記録しない（要件 11.1）。
private enum SoratomoImageCacheFailure: LocalizedError {
    /// グループのキャッシュのフォルダを作れなかった
    case cannotCreateGroupCache

    var errorDescription: String? {
        "soratomo: グループの画像のキャッシュを作れなかった"
    }
}

/// グループごとの画像のキャッシュ（`SoratomoImageCache` の中身）
///
/// - グループのキャッシュは `ImageCache(name: "soratomo.{groupId}", cacheDirectoryURL: 親のフォルダ)` で作り、
///   グループ ID ごとに覚えておく（同じグループには同じものを返す）。
///   置き場は `親のフォルダ/com.onevcat.Kingfisher.ImageCache.soratomo.{groupId}`（Kingfisher 8.6.2 の規則）。
/// - メモリの上限は、1 つのキャッシュの既定（物理メモリの 1/4）を、所属できるグループの上限で割った値にする
///   （上限までそろっても、1.14.x の共通のキャッシュ 1 つと同じ合計）。
/// - キャッシュを作れなかったとき（フォルダを作れない）は、覚えずに受け皿を返し、記録に残す。
///   そのときに入った画像は `removeGroup(_:)` では消えない（`clear()` で消える）。
/// - 覚えの読み書きはロックで守る（画面の描画と、抜けた後の後片づけの両方から呼ばれる）。
final class SoratomoGroupImageCaches: @unchecked Sendable {
    /// グループのキャッシュの名前の頭（`soratomo.{groupId}`）
    private static let groupCacheNamePrefix = "soratomo."

    /// グループのキャッシュのフォルダを置く、親のフォルダ
    let parentDirectory: URL
    /// グループに属さない受け皿のキャッシュ（本番は `SoratomoImageCache.shared`）
    let fallback: ImageCache

    /// グループ ID → そのグループのキャッシュ
    private var caches: [String: ImageCache] = [:]
    /// `caches` を守るロック
    private let lock = NSLock()
    /// フォルダの削除を行う列（メインを塞がない）
    private let diskQueue = DispatchQueue(label: "soratomo.groupImageCaches.disk")

    /// - Parameters:
    ///   - parentDirectory: グループのキャッシュのフォルダを置く、親のフォルダ
    ///   - fallback: パスの形が違うときに返す受け皿のキャッシュ
    init(parentDirectory: URL, fallback: ImageCache) {
        self.parentDirectory = parentDirectory
        self.fallback = fallback
    }

    /// グループのキャッシュの、メモリの上限（バイト）
    ///
    /// Kingfisher の既定（物理メモリの 1/4）を、所属できるグループの上限で割った値。
    static var groupMemoryCostLimit: Int {
        let limit = ProcessInfo.processInfo.physicalMemory / 4 / UInt64(SoratomoGroupService.maxListedGroups)
        return limit > UInt64(Int.max) ? Int.max : Int(limit)
    }

    /// 画像の Storage のパスから、グループ ID を取り出す
    /// - Parameter path: `soratomo/{groupId}/…` の形のパス
    /// - Returns: グループ ID。形が違えば nil
    static func groupId(fromStoragePath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "soratomo", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// グループのキャッシュのフォルダ（Kingfisher 8.6.2 の規則で組む。まだ作っていないグループにも使う）
    /// - Parameter groupId: グループ ID
    func directoryURL(forGroup groupId: String) -> URL {
        parentDirectory.appendingPathComponent(
            "com.onevcat.Kingfisher.ImageCache.\(Self.groupCacheNamePrefix)\(groupId)",
            isDirectory: true
        )
    }

    /// 画像の Storage のパスに合う、グループのキャッシュ（無ければ作って覚える）
    /// - Parameter path: 画像の Storage のパス
    /// - Returns: そのグループのキャッシュ。パスの形が違う・作れなかったときは受け皿
    func cache(forStoragePath path: String) -> ImageCache {
        guard let groupId = Self.groupId(fromStoragePath: path) else { return fallback }
        lock.lock()
        defer { lock.unlock() }
        if let cache = caches[groupId] {
            return cache
        }
        do {
            let cache = try ImageCache(
                name: "\(Self.groupCacheNamePrefix)\(groupId)",
                cacheDirectoryURL: parentDirectory
            )
            cache.memoryStorage.config.totalCostLimit = Self.groupMemoryCostLimit
            caches[groupId] = cache
            return cache
        } catch {
            SoratomoError.record(SoratomoImageCacheFailure.cannotCreateGroupCache, context: "soratomo.imageCache.create")
            return fallback
        }
    }

    /// 投稿の 2 枚（表示用・サムネイル）の鍵を、そのグループのキャッシュから消す（メモリとディスク）
    /// - Parameter paths: 消す投稿の画像の置き場所
    func remove(_ paths: SoratomoImagePaths) {
        cache(forStoragePath: paths.display).removeImage(forKey: paths.display)
        cache(forStoragePath: paths.thumbnail).removeImage(forKey: paths.thumbnail)
    }

    /// 1 つのグループのキャッシュを、メモリとディスク（フォルダごと）から消す
    ///
    /// 覚えから外してメモリを空にし、フォルダを裏で消す。覚えに無い（この起動では開いていない）グループでも、
    /// 前の起動で作ったフォルダが残っていれば消す。
    /// - Parameters:
    ///   - groupId: 消すグループ ID
    ///   - completion: フォルダを消し終えたときにメインで呼ぶ（テスト用）
    func removeGroup(_ groupId: String, completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        let cache = caches.removeValue(forKey: groupId)
        lock.unlock()
        // 外したインスタンスを「もう期限切れ」にしてから空にする（leave-group /review-full D2）。
        // 抜けた後に届いた読み込み途中の画像は、消す前に受け取ったこのインスタンスへ保存しに来る
        // （Kingfisher の provider の読み込みは取り消せない）。期限切れなら Kingfisher 8.6.2 の保存は
        // 書く前に戻るので（DiskStorage.swift:162・MemoryStorage.swift:146）、消したフォルダを作り直さない
        cache?.diskStorage.config.expiration = .expired
        cache?.memoryStorage.config.expiration = .expired
        cache?.clearMemoryCache()

        let directory = directoryURL(forGroup: groupId)
        diskQueue.async {
            try? FileManager.default.removeItem(at: directory)
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }

    /// すべてのグループのキャッシュ（親のフォルダごと）と、受け皿を消す（メモリとディスク）
    /// - Parameter completion: ディスクを消し終えたときにメインで呼ぶ（テスト用）
    func clear(completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        let all = Array(caches.values)
        caches.removeAll()
        lock.unlock()
        all.forEach { $0.clearMemoryCache() }

        let group = DispatchGroup()
        group.enter()
        let parent = parentDirectory
        diskQueue.async {
            try? FileManager.default.removeItem(at: parent)
            group.leave()
        }
        group.enter()
        fallback.clearCache { group.leave() }
        group.notify(queue: .main) { completion?() }
    }

    /// 受け皿（1.14.x の共通のキャッシュ）を、1 回だけ消す（メモリとディスク）
    /// - Parameters:
    ///   - defaults: 消したかの印の置き場
    ///   - completion: 消し終えたときにメインで呼ぶ。もう消していたら呼ばない（テスト用）
    func purgeLegacyIfNeeded(defaults: UserDefaults, completion: (@Sendable () -> Void)? = nil) {
        guard !defaults.bool(forKey: SoratomoImageCache.legacyPurgedKey) else { return }
        defaults.set(true, forKey: SoratomoImageCache.legacyPurgedKey)
        fallback.clearCache(completion: completion)
    }
}
