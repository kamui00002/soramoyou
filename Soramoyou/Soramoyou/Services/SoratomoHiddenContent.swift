//
//  SoratomoHiddenContent.swift
//  Soramoyou
//
//  そらともで見せない投稿（ブロックした投稿者・この端末で通報した投稿）⭐️
//  （release-gate 9.1・design.md の「隠す集合」・要件 3.9・5.5・9.4・9.6・14.1）
//
//  - ブロックの一覧（SoratomoBlockedAuthors）: アプリ全体で 1 つ、セッションの間だけ持つ。読み込みの口は呼び出し側から渡す
//    （通報とブロックのサービスに直接依存させない）。既存のブロックの通知（`.userBlocked`）でも足す
//  - 通報した投稿（SoratomoReportedSkies）: 利用者ごとに端末（UserDefaults）へ残す。サインアウトではメモリだけ空にする
//  - 判定（SoratomoHiddenContent.hides）は、タイムラインと投稿詳細が同じものを使う
//  - ⚠️ ログ・計測に投稿者の名前やキャプションを出さない（ここで扱うのは内部 ID だけ・要件 14.1）
//

import Combine
import Foundation

// MARK: - 投稿のキーと判定

/// 投稿を 1 件だけ指すキー（グループ ID と投稿 ID）
///
/// 投稿 ID だけではグループをまたいで一意と言い切れないので、グループ ID と組にする。
struct SoratomoSkyKey: Hashable, Codable, Sendable {
    /// 投稿先のグループ ID
    let groupId: String
    /// 投稿 ID
    let skyId: String

    init(groupId: String, skyId: String) {
        self.groupId = groupId
        self.skyId = skyId
    }

    /// 投稿からキーを作る
    init(_ sky: SoratomoSky) {
        self.init(groupId: sky.groupId, skyId: sky.id)
    }
}

/// 見せない集合（ブロックした投稿者・この端末で通報した投稿）
struct SoratomoHiddenContent: Equatable, Sendable {
    /// ブロックした投稿者の uid
    var blockedAuthorIds: Set<String> = []
    /// この端末で通報した投稿
    var reportedSkies: Set<SoratomoSkyKey> = []

    /// この投稿を見せないか（投稿者をブロックしている・この投稿を通報した）
    /// - Parameter sky: 判定する投稿
    /// - Returns: 見せないなら true
    func hides(_ sky: SoratomoSky) -> Bool {
        blockedAuthorIds.contains(sky.authorId) || reportedSkies.contains(SoratomoSkyKey(sky))
    }
}

// MARK: - ブロックの一覧

/// ブロックした投稿者の一覧（アプリ全体で 1 つ。セッションの間だけ持つ）
///
/// 使い方: タイムラインを開いたときに `load(uid:using:)` で読み込む（ルートの画面でブロックした相手もここで入る・要件 9.6）。
/// そらともでブロックが保存されたら `add(_:)`。既存の `.userBlocked` 通知（ルートの投稿詳細・そらとものブロック）でも足す。
/// サインアウトで `clear()`。
@MainActor
final class SoratomoBlockedAuthors: ObservableObject {
    /// ブロックした投稿者の uid
    @Published private(set) var ids: Set<String> = []

    /// `clear()` を呼ぶたびに進む世代。読み込み中に `clear()` が呼ばれたら、戻ってきた結果を捨てる
    /// （サインアウト・アカウントの切り替えの前に始めた読み込みが、前の人の一覧を復活させないため）
    private var generation = 0
    /// 読み込み中に足した uid（読み込みの結果で置き換えるときに消さないため）
    private var addedDuringLoad: Set<String> = []
    /// 進行中の読み込みの数（タイムラインを続けて開くと重なる。0 に戻ったら `addedDuringLoad` を空にする）
    private var activeLoads = 0
    /// 既存のブロックの通知（`.userBlocked`）の購読
    private var userBlockedObserver: NSObjectProtocol?
    /// 購読する通知センター（テストで差し替える）
    private let notificationCenter: NotificationCenter

    /// - Parameter notificationCenter: `.userBlocked` を購読する通知センター。既定は `.default`
    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        userBlockedObserver = notificationCenter.addObserver(
            forName: .userBlocked,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userId = notification.userInfo?[Notification.blockedUserIdKey] as? String,
                  !userId.isEmpty else { return }
            Task { @MainActor in
                self?.add(userId)
            }
        }
    }

    deinit {
        if let observer = userBlockedObserver {
            notificationCenter.removeObserver(observer)
        }
    }

    /// サーバーのブロックの一覧（`users/{uid}.blockedUserIds`）を読み込んで置き換える
    ///
    /// - 読めたら、読んだ一覧と、読み込み中に足した uid を合わせたものにする（ルートの画面で解除した相手は外れる）。
    /// - 読めなかったら、今の一覧のまま偽を返す（表示を優先し、次に開いたときに読み直す・design.md）。
    /// - 読み込み中に `clear()` が呼ばれたら、結果を捨てて偽を返す。
    /// - Parameters:
    ///   - uid: 自分の uid
    ///   - fetch: 一覧を読む口（通報とブロックのサービスの `fetchBlockedUserIds` を呼び出し側が渡す）
    /// - Returns: 読めて反映したら true
    @discardableResult
    func load(uid: String, using fetch: (String) async throws -> Set<String>) async -> Bool {
        let startGeneration = generation
        activeLoads += 1
        defer {
            if generation == startGeneration {
                activeLoads -= 1
                if activeLoads == 0 {
                    addedDuringLoad = []
                }
            }
        }
        let fetched: Set<String>
        do {
            fetched = try await fetch(uid)
        } catch {
            return false
        }
        guard generation == startGeneration else { return false }
        ids = fetched.union(addedDuringLoad)
        return true
    }

    /// ブロックした投稿者を足す（そらとものブロックが保存された・`.userBlocked` を受けた）
    /// - Parameter authorId: ブロックした投稿者の uid
    func add(_ authorId: String) {
        guard !authorId.isEmpty else { return }
        if activeLoads > 0 {
            addedDuringLoad.insert(authorId)
        }
        ids.insert(authorId)
    }

    /// 一覧を空にする（サインアウト）
    func clear() {
        generation += 1
        activeLoads = 0
        addedDuringLoad = []
        ids = []
    }
}

// MARK: - この端末で通報した投稿

/// この端末で通報した投稿（利用者ごとに UserDefaults の `soratomo.reportedSkies.{uid}` に残す）
///
/// - 利用者ごとに分ける: アカウントを切り替えても、別の人の通報で隠さない・漏らさない（決定事項6）。
/// - 再起動しても隠したままにする（要件 5.5）。サインアウトでは端末の記録を消さない（同じ人が入り直したときも隠す）。
/// - 1 人あたり最大 `maxCount` 件。超えたら古いものから捨てる。
/// - 退会では `erase(uid:defaults:)` でその人の記録を消す（要件 3.9）。
@MainActor
final class SoratomoReportedSkies: ObservableObject {
    /// 1 人あたりに残す件数の上限
    static let maxCount = 1000

    /// いま読み込んでいる利用者の、通報した投稿
    @Published private(set) var keys: Set<SoratomoSkyKey> = []
    /// いま読み込んでいる利用者の uid（読み込む前・サインアウトの後は nil）
    private(set) var currentUid: String?
    /// 記録の置き場（テストで差し替える）
    private let defaults: UserDefaults

    /// - Parameter defaults: 記録の置き場。既定は `.standard`
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 利用者ごとの記録のキー
    static func storageKey(uid: String) -> String {
        "soratomo.reportedSkies.\(uid)"
    }

    /// その利用者の記録を読み込む（入口・サインインの後）
    /// - Parameter uid: 利用者の uid
    func load(uid: String) {
        currentUid = uid
        keys = Set(Self.stored(uid: uid, defaults: defaults))
    }

    /// 通報した投稿を足す（通報が受け付けられたとき）
    ///
    /// その利用者の記録の末尾に足して端末に残す。上限を超えたら古いものから捨てる。
    /// いま読み込んでいる利用者と同じなら、メモリにも足す。
    /// - Parameters:
    ///   - key: 通報した投稿
    ///   - uid: 通報した利用者の uid
    func add(_ key: SoratomoSkyKey, uid: String) {
        var list = Self.stored(uid: uid, defaults: defaults).filter { $0 != key }
        list.append(key)
        if list.count > Self.maxCount {
            list.removeFirst(list.count - Self.maxCount)
        }
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.storageKey(uid: uid))
        }
        if uid == currentUid {
            keys = Set(list)
        }
    }

    /// メモリだけを空にする（サインアウト。端末の記録は残す）
    func clear() {
        currentUid = nil
        keys = []
    }

    /// その利用者の端末の記録を消す（退会）
    /// - Parameters:
    ///   - uid: 退会する利用者の uid
    ///   - defaults: 記録の置き場。既定は `.standard`
    static func erase(uid: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey(uid: uid))
    }

    /// 端末に残した記録（古い順）。無い・読めないときは空
    private static func stored(uid: String, defaults: UserDefaults) -> [SoratomoSkyKey] {
        guard let data = defaults.data(forKey: storageKey(uid: uid)),
              let list = try? JSONDecoder().decode([SoratomoSkyKey].self, from: data)
        else {
            return []
        }
        return list
    }
}
