//
//  SoratomoServiceContracts.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）のサービスの契約 ⭐️
//  グループ・投稿・画像・表示名のサービスの protocol と、サービスどうしで受け渡す型を先に置く
//  （tasks 11.1・11.2・11.3・11.4・11.5 の土台・design.md の「iOS: サービス」の Service Interface）。
//
//  ⚠️ このファイルは Firebase・Kingfisher を import しない。
//     画面の ViewModel（tasks 13.x）とテストのモックは、この protocol だけに依存させる。
//     実装（Firestore・Functions・Storage を呼ぶ側）は、各サービスのファイルに置く。
//

import Foundation

// MARK: - Firestore のパス

/// そらともの Firestore のコレクション名（design.md の Physical Data Model）
///
/// ⚠️ firestore.rules・functions/soratomoStore.js と同じ名前にする。
///    名前を 1 か所にまとめて、サービスごとに文字列を打ち間違えないようにする。
enum SoratomoFirestorePath {
    /// グループ: `soratomoGroups/{groupId}`（書き手は Functions だけ）
    static let groups = "soratomoGroups"
    /// メンバー: `soratomoGroups/{groupId}/members/{uid}`（書き手は Functions だけ）
    static let members = "members"
    /// 投稿: `soratomoGroups/{groupId}/skies/{skyId}`（アプリが作成と削除だけを行う）
    static let skies = "skies"
    /// 利用者ごとの所属の集計: `soratomoUsers/{uid}`（書き手は Functions だけ）
    static let users = "soratomoUsers"
    /// 利用者ごとの所属の写し: `soratomoUsers/{uid}/groups/{groupId}`（書き手は Functions だけ）
    static let userGroups = "groups"
}

// MARK: - 監視の札

/// 監視（Firestore のリスナーなど）を止めるための札
///
/// サービスの `observe〜` が返す。止め方は作る側がクロージャで渡す（Firestore なら
/// `ListenerRegistration.remove()`、モックなら記録だけ）。
///
/// - `cancel()` は何度呼んでも、止める処理は 1 回しか走らない。
/// - ⚠️ 札が解放されると、自動で止まる（`deinit` で `cancel()` を呼ぶ）。
///   監視を続けたい間は、ViewModel のプロパティに札を持っておくこと。`_ = service.observe…` のように
///   受け取らずに捨てると、その場で監視が止まる。
///   逆に、件数の上限を伸ばして張り直すとき（tasks 11.2）は、新しい札でプロパティを上書きするだけで
///   古い監視が止まる（止め忘れによる二重の監視を防ぐため、この形にした）。
final class SoratomoListenerToken: @unchecked Sendable {
    /// 止める処理（止めた後は nil）。ロックの中でだけ読み書きする
    private var onCancel: (() -> Void)?
    /// `onCancel` を複数のスレッドから同時に触らないためのロック
    private let lock = NSLock()

    /// - Parameter onCancel: 止める処理（1 回だけ呼ばれる）
    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    deinit {
        cancel()
    }

    /// もう止めたか
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onCancel == nil
    }

    /// 監視を止める（2 回目以降は何もしない）
    func cancel() {
        // 止める処理はロックの外で呼ぶ（中で呼ぶと、止める処理が札に触ったときに止まったままになる）
        lock.lock()
        let action = onCancel
        onCancel = nil
        lock.unlock()
        action?()
    }
}

// MARK: - グループ（tasks 11.1）

/// グループを作った直後の要約（Callable `soratomoCreateGroup` の戻り値）
struct SoratomoGroupSummary: Equatable, Sendable {
    /// 作ったグループの ID
    let groupId: String
    /// 前後の空白を除いたグループ名
    let name: String
    /// 発行された招待コード
    let inviteCode: SoratomoInviteCode
    /// メンバー数（作った直後は 1）
    let memberCount: Int
}

/// 招待コードで参加した結果（Callable `soratomoJoinGroup` の戻り値）
struct SoratomoJoinResult: Equatable, Sendable {
    /// 参加したグループの ID
    let groupId: String
    /// すでにメンバーだったか（true でもエラーではない・要件 4.8）
    let alreadyMember: Bool
}

/// グループのサービス（作成・参加・再発行の Callable と、メンバーとしての読み取り）
///
/// - 失敗はすべて `SoratomoError` に写して投げる。サーバーの文言は画面に出さない（要件 12.5）。
/// - 読み取り・監視が権限の拒否か不在で失敗したら `.notMember` にする。
/// - `observeGroup` の `onChange` はメインアクターで呼ぶ（Firestore のコールバックから呼ぶときは、
///   メインアクターへ移ってから呼ぶ）。
protocol SoratomoGroupServiceProtocol: Sendable {
    /// グループを作る
    /// - Parameters:
    ///   - name: 前後の空白を除いたグループ名（`SoratomoTextRules.validateGroupName` を通したもの）
    ///   - requestId: 呼び出し側が作る要求 ID。同じ ID で送り直しても二重に作られない
    func createGroup(name: String, requestId: UUID) async throws(SoratomoError) -> SoratomoGroupSummary

    /// 招待コードで参加する
    func joinGroup(code: SoratomoInviteCode) async throws(SoratomoError) -> SoratomoJoinResult

    /// 招待コードを再発行する（オーナーだけ）。それまでの招待コードは無効になる
    func regenerateInviteCode(groupId: String) async throws(SoratomoError) -> SoratomoInviteCode

    /// 自分が入っているグループを、最新の活動時刻の新しい順に返す（最大 10 件）
    func fetchMyGroups(uid: String) async throws(SoratomoError) -> [SoratomoGroup]

    /// グループ（名前・メンバー数）を監視する
    /// - Returns: 監視の札。持っている間だけ監視が続く
    func observeGroup(
        groupId: String,
        onChange: @escaping @MainActor (Result<SoratomoGroup, SoratomoError>) -> Void
    ) -> SoratomoListenerToken

    /// メンバー一覧を取得する（オーナーは `role == .owner`）
    func fetchMembers(groupId: String) async throws(SoratomoError) -> [SoratomoMember]
}

// MARK: - 投稿（tasks 11.2）

/// 保存する投稿の中身（画像はアップロード済みで、パスは ID から導く）
struct SoratomoSkyDraft: Equatable, Sendable {
    /// 投稿先のグループ ID
    let groupId: String
    /// 投稿 ID（`newSkyId(groupId:)` で先に作り、画像のパスにも使う）
    let skyId: String
    /// 投稿者の uid
    let authorId: String
    /// 改行を除いた 1〜100 文字のキャプション。空なら nil（項目ごと省く）
    let caption: String?
    /// 表示用画像の幅（ピクセル）
    let pixelWidth: Int
    /// 表示用画像の高さ（ピクセル）
    let pixelHeight: Int
}

/// タイムラインの監視の 1 回分の結果
struct SoratomoTimelineSnapshot: Equatable, Sendable {
    /// 作成日時の新しい順の投稿
    let skies: [SoratomoSky]
    /// 端末のキャッシュからの結果か（オフラインの表示に使う・要件 12.1）
    let isFromCache: Bool
    /// 続きがありうるか（件数が上限と等しい）
    let mayHaveMore: Bool
}

/// 投稿のサービス（タイムラインの監視と、投稿の作成・削除・日次件数）
///
/// - 作成と削除は書き込みだけのトランザクションで行う。オフラインでは `.network` で失敗し、端末内に積まれない。
/// - `.network` で終わった作成・削除は、結果が確定していないことがある。成否は `skyExistsOnServer` で確かめる。
/// - `observeTimeline` の `onChange` はメインアクターで呼ぶ。
protocol SoratomoSkyServiceProtocol: Sendable {
    /// 新しい投稿 ID を作る（通信しない）
    func newSkyId(groupId: String) -> String

    /// タイムラインを監視する（作成日時の新しい順・最大 `limit` 件）
    /// - Returns: 監視の札。上限を変えるときは張り直して、札を差し替える
    func observeTimeline(
        groupId: String,
        limit: Int,
        onChange: @escaping @MainActor (Result<SoratomoTimelineSnapshot, SoratomoError>) -> Void
    ) -> SoratomoListenerToken

    /// 投稿を作る（作成日時はサーバーの時刻）
    func createSky(_ draft: SoratomoSkyDraft) async throws(SoratomoError)

    /// 投稿がサーバーにあるかを、キャッシュを使わずに確かめる（結果が確定しない失敗の後に使う）
    func skyExistsOnServer(groupId: String, skyId: String) async throws(SoratomoError) -> Bool

    /// 投稿を削除する（画像は消さない。画像は `SoratomoImageStoreProtocol.delete` で消す）
    func deleteSky(groupId: String, skyId: String) async throws(SoratomoError)

    /// 自分の今日（端末のタイムゾーン）の投稿件数を数える
    /// - Returns: 件数。数えられなければ nil（投稿は止めない）
    func countTodaySkies(groupId: String, authorId: String, since startOfLocalDay: Date) async -> Int?
}

// MARK: - 画像（tasks 11.3・11.4）

/// 送信する 2 枚の JPEG（メタデータ無し・正立済み）
///
/// `SoratomoImageEncoder.encode(source:)`（tasks 11.3）が作り、
/// `SoratomoImageStoreProtocol.upload(_:to:progress:)`（tasks 11.4）が受け取る。
struct SoratomoEncodedImages: Equatable, Sendable {
    /// 表示用（長辺 2048px 以下・1,572,864 バイト以下）
    let display: Data
    /// サムネイル（長辺 512px 以下・204,800 バイト以下）
    let thumbnail: Data
    /// 表示用画像の幅（ピクセル）
    let pixelWidth: Int
    /// 表示用画像の高さ（ピクセル）
    let pixelHeight: Int
}

/// 2 枚の画像の削除の結果
enum SoratomoImageDeleteOutcome: Equatable, Sendable {
    /// 2 枚とも消えた（もともと無かった場合を含む）
    case deleted
    /// どちらかの削除に失敗した（非致命エラーとして記録済み・要件 8.20）
    case partiallyFailed
}

/// 画像の保存と削除
///
/// ⚠️ ダウンロード URL を作らず、保存しない（要件 8.14・11.13）。
protocol SoratomoImageStoreProtocol: Sendable {
    /// 2 枚を並行してアップロードする
    /// - Parameters:
    ///   - images: 送る 2 枚
    ///   - paths: 置き場所（`SoratomoImagePaths` だけが作る）
    ///   - progress: 2 枚を合わせた進み具合（0.0〜1.0）。どのスレッドから呼ばれるかは決めない
    func upload(
        _ images: SoratomoEncodedImages,
        to paths: SoratomoImagePaths,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(SoratomoError)

    /// 進行中のアップロードを取り消す
    func cancelUploads(to paths: SoratomoImagePaths)

    /// 2 枚を並行して削除する（失敗しても投げない）
    func delete(_ paths: SoratomoImagePaths) async -> SoratomoImageDeleteOutcome
}

// MARK: - 表示名とそらとも通知（tasks 11.5）

/// 表示名の事前入力と、そらとも通知の保存
protocol SoratomoProfileServiceProtocol: Sendable {
    /// 表示名の入力が要るか（`users/{uid}.displayName` が無いか空白だけなら true）
    func needsDisplayName(uid: String) async throws(SoratomoError) -> Bool

    /// 表示名を保存する（`users` と `publicProfiles` を 1 つのトランザクションで）
    func saveDisplayName(uid: String, name: SoratomoDisplayName) async throws(SoratomoError)

    /// そらとも通知のオン・オフを保存する（`users/{uid}.notifySoratomo` だけを更新）
    func setNotifySoratomo(uid: String, enabled: Bool) async throws(SoratomoError)
}
