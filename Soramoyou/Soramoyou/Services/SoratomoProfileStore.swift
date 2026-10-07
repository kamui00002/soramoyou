//
//  SoratomoProfileStore.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の、投稿者とメンバーの表示名・アイコン ⭐️
//  （tasks 11.5・design.md の SoratomoProfileStore・要件 8.6・8.7・8.8・19.1・19.2）
//
//  - 公開プロフィール（`publicProfiles/{uid}`）から取り、セッションの間だけ保持する
//  - 未設定・未取得は、既存の画面と同じ代替（名前は「ユーザー」・アイコンはプレースホルダー）にする
//  - ⚠️ 内部 ID（uid）から作った文字で代用しない（頭文字・先頭の数文字なども使わない）
//  - 保持を消す `clear()` を持つ。サインアウト・アカウント切替で呼ぶ配線は tasks 14.1 の責務
//

import Combine
import Foundation

// MARK: - 公開プロフィールの取得口（テストで差し替える）

/// 公開プロフィールを 1 件取る口
///
/// 既存の `FirestoreServiceProtocol.fetchPublicProfile(userId:)` と同じ形。
/// `FirestoreServiceProtocol` は大きく、モックが多数あるので、そらともは必要な 1 本だけを別の protocol に切る。
protocol SoratomoProfileFetcher: Sendable {
    /// 公開プロフィールを取る。無い・読めない・壊れているときは投げる
    /// - Note: 本物（`FirestoreService`）は、中の id がドキュメント ID と一致するかも確かめて、
    ///   なりすまし（他人の uid を書いた文書）を弾く（issue #133）
    func fetchPublicProfile(userId: String) async throws -> PublicProfile
}

/// 既存の `FirestoreServiceProtocol` を `SoratomoProfileFetcher` に包む
///
/// `FirestoreServiceProtocol` は `Sendable` ではないので `@unchecked` にしている。
/// 呼ぶのは `fetchPublicProfile` の 1 本だけで、読み取りだけ（状態を書き換えない）。
private struct SoratomoProfileFirestoreFetcher: SoratomoProfileFetcher, @unchecked Sendable {
    let firestoreService: FirestoreServiceProtocol

    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        try await firestoreService.fetchPublicProfile(userId: userId)
    }
}

// MARK: - ストア

/// 投稿者とメンバーの表示名・アイコンを、セッションの間だけ保持する
///
/// 使い方（タイムライン・メンバー一覧の ViewModel / View）:
/// 1. 投稿やメンバーの uid の集合で `prefetch(uids:)` を呼ぶ（取れていない分だけ取りに行く）
/// 2. 表示は `displayName(for:)` と `photoURL(for:)` から出す。`profiles` が `@Published` なので、
///    取れた時点で画面が更新される。取れていない間・取れなかったときは代替の表示になる
@MainActor
final class SoratomoProfileStore: ObservableObject {
    /// 取れた公開プロフィール（uid → プロフィール）。失敗した uid は入らない
    @Published private(set) var profiles: [String: PublicProfile] = [:]

    /// 公開プロフィールの取得口
    private let fetcher: any SoratomoProfileFetcher

    /// いま取りに行っている uid（同じ uid を二重に取りに行かないため）
    private var inFlight: Set<String> = []

    /// `clear()` を呼ぶたびに進む世代。取得中に `clear()` が呼ばれたら、戻ってきた結果を捨てる
    /// （サインアウト・アカウント切替の前に始めた取得が、切替の後に前の保持を復活させないため）
    private var generation = 0

    /// 自分のプロフィールの保存（`.profileUpdated` 通知）の購読
    private var profileUpdatedObserver: NSObjectProtocol?

    /// - Parameter fetcher: 公開プロフィールの取得口
    init(fetcher: any SoratomoProfileFetcher) {
        self.fetcher = fetcher
        setupProfileUpdatedObserver()
    }

    deinit {
        if let observer = profileUpdatedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// - Parameter firestoreService: 既存の Firestore サービス。既定は本物
    convenience init(firestoreService: FirestoreServiceProtocol = FirestoreService()) {
        self.init(fetcher: SoratomoProfileFirestoreFetcher(firestoreService: firestoreService))
    }

    // MARK: - 取得

    /// まだ持っていない uid の公開プロフィールを、並行して取りに行く
    ///
    /// - 持っている uid・取得中の uid・空の uid は取りに行かない。
    /// - 取れなかった uid（通信・壊れたデータ・プロフィールが無い）は保持しない。代替の表示のままになり、
    ///   次に `prefetch` を呼んだとき、もう一度取りに行く。
    /// - 別の `prefetch` がすでに取りに行っている uid は待たずに戻る。取れた時点で `profiles` が更新される。
    /// - 取得中に `clear()` が呼ばれたら、戻ってきた結果は捨てる。
    /// - Parameter uids: 取りたい uid の集合（投稿者・メンバーの uid）
    func prefetch(uids: Set<String>) async {
        let targets = uids.filter { uid in
            !uid.isEmpty && profiles[uid] == nil && !inFlight.contains(uid)
        }
        guard !targets.isEmpty else { return }

        let startGeneration = generation
        inFlight.formUnion(targets)
        // 子タスクに渡す取得口（自分の `fetcher` プロパティと同じ名前の自己代入にしないため、別の名前にする）
        let profileFetcher = fetcher

        let fetched = await withTaskGroup(
            of: (String, PublicProfile?).self,
            returning: [String: PublicProfile].self
        ) { group in
            for uid in targets {
                group.addTask {
                    var profile: PublicProfile?
                    do {
                        profile = try await profileFetcher.fetchPublicProfile(userId: uid)
                    } catch {
                        // 壊れた 1 件・通信の失敗を無言で落とさない。内部 ID だけを残す（表示名は残さない・要件 15.1）
                        print("❌ そらとも: 公開プロフィールの取得に失敗 uid=\(uid) error=\(error.localizedDescription)")
                    }
                    return (uid, profile)
                }
            }
            var result: [String: PublicProfile] = [:]
            for await (uid, profile) in group {
                if let profile {
                    result[uid] = profile
                }
            }
            return result
        }

        // 取得中に clear() が呼ばれていたら、結果も取得中の記録も触らない（clear() が作り直した状態を守る）
        guard generation == startGeneration else { return }
        inFlight.subtract(targets)
        if !fetched.isEmpty {
            profiles.merge(fetched) { _, new in new }
        }
    }

    // MARK: - 表示

    /// 表示名（未取得・取得に失敗・未設定・空白だけは「ユーザー」）
    ///
    /// 代替の規則は、既存の画面（ランキング・フォロー一覧・コメントなど）と同じ `RankingDisplayText.authorName`。
    /// ⚠️ uid から作った文字（頭文字・先頭の数文字）で代用しない。
    func displayName(for uid: String) -> String {
        RankingDisplayText.authorName(profiles[uid])
    }

    /// アイコン（プロフィール写真）の URL
    ///
    /// - Returns: 写真が設定されていれば URL。nil は「プレースホルダーのアイコンを出す」の意味
    ///   （未取得・取得に失敗・写真が未設定・空）。
    func photoURL(for uid: String) -> URL? {
        guard let raw = profiles[uid]?.photoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return URL(string: raw)
    }

    // MARK: - 自分のプロフィールの保存

    /// プロフィール編集の保存（`.profileUpdated` 通知）を購読する ☁️
    ///
    /// 一度取った uid は読み直さない（`prefetch` は持っていない uid だけを取りに行く）ので、
    /// プロフィール編集で表示名を変えても、タイムラインは再起動するまで古い名前のままだった。
    /// 購読の形は `.userBlocked`（PaginatedPostsViewModel）と同じ。
    private func setupProfileUpdatedObserver() {
        profileUpdatedObserver = NotificationCenter.default.addObserver(
            forName: .profileUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let uid = userInfo[Notification.profileUpdatedUserIdKey] as? String,
                  !uid.isEmpty else { return }
            // キーが無い＝未設定（nil）
            let displayName = userInfo[Notification.profileUpdatedDisplayNameKey] as? String
            let photoURL = userInfo[Notification.profileUpdatedPhotoURLKey] as? String
            Task { @MainActor in
                self?.applyProfileUpdate(uid: uid, displayName: displayName, photoURL: photoURL)
            }
        }
    }

    /// 保存された表示名とアイコンで、持っている覚えを差し替える
    ///
    /// - 持っていない uid は何もしない（次の `prefetch` がサーバーの新しい値を取る。`clear()` の後に
    ///   前の覚えを復活させないためでもある）
    /// - 表示名とアイコン以外（サーバーが保つカウンタなど）は触らない
    private func applyProfileUpdate(uid: String, displayName: String?, photoURL: String?) {
        guard var profile = profiles[uid] else { return }
        profile.displayName = displayName
        profile.photoURL = photoURL
        profiles[uid] = profile
    }

    // MARK: - 消去

    /// 保持している公開プロフィールをすべて消す（サインアウト・アカウント切替用。配線は tasks 14.1）
    ///
    /// 取得中のものがあれば、その結果も捨てる（戻ってきても保持に入れない）。
    func clear() {
        generation += 1
        inFlight.removeAll()
        if !profiles.isEmpty {
            profiles = [:]
        }
    }
}
