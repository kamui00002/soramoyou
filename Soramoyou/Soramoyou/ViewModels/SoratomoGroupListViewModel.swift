//
//  SoratomoGroupListViewModel.swift
//  Soramoyou
//
//  そらとものグループ一覧の ViewModel ⭐️
//  （tasks 13.1・design.md の SoratomoGroupListView・ViewModel・要件 5.1〜5.6・14.3・15.4）
//

import Foundation

/// そらとものグループ一覧の ViewModel
///
/// - 自分が入っているグループを、最新の活動の新しい順に読む（並べ替えはサービスが行う・最大 10 件）
/// - `soratomo_opened`（group_count）は、この ViewModel が生きている間に、最初に読めたときだけ 1 回記録する。
///   読めなかったときは記録しない（件数が分からないため。失敗は非致命エラーとして記録する）
/// - 読み込みの失敗は、固定の文言（`SoratomoError.userMessage`）で出す。サーバーの文言は出さない
@MainActor
final class SoratomoGroupListViewModel: ObservableObject {
    // MARK: - Properties

    /// 一覧の読み込み状態。失敗は `SoratomoError` で持つ
    @Published private(set) var state: LoadableState<[SoratomoGroup]> = .idle

    /// グループのサービス
    private let groupService: any SoratomoGroupServiceProtocol
    /// いまログインしている利用者の uid（未ログインなら nil）
    private let currentUid: () -> String?
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void

    /// `soratomo_opened` を記録したか（1 回だけ記録するため）
    private var hasLoggedOpened = false

    // MARK: - Init

    /// - Parameters:
    ///   - groupService: グループのサービス
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - logsOpened: `soratomo_opened` を記録するか。入口から開いたときだけ true（要件 14 の表の「入口からグループ一覧を開いた」）。
    ///     通知から開いたとき（一覧の上にタイムライン）は false にする（14.3 の点検で直した）
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    init(
        groupService: any SoratomoGroupServiceProtocol,
        currentUid: @escaping () -> String?,
        logsOpened: Bool = true,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log
    ) {
        self.groupService = groupService
        self.currentUid = currentUid
        self.logEvent = logEvent
        // 記録しないときは「記録済み」として始める（load の 1 回だけの判定をそのまま使う）
        hasLoggedOpened = !logsOpened
    }

    // MARK: - 読み込み

    /// 自分が入っているグループを読む
    ///
    /// 画面を開いたとき・作成や参加の後・タイムラインなどから一覧へ戻ったときに呼ぶ。
    /// - すでに読んだ一覧があるときは、読み直しの間も前の一覧を出したままにする（ちらつかせない）
    /// - 未ログイン（uid が nil）なら読まない。サインアウト時の画面の破棄は 14.1 が行う
    func load() async {
        guard let uid = currentUid() else { return }

        if !state.isLoaded {
            state = .loading
        }

        do {
            let groups = try await groupService.fetchMyGroups(uid: uid)
            state = .loaded(groups)
            if !hasLoggedOpened {
                hasLoggedOpened = true
                logEvent(.opened(groupCount: groups.count))
            }
        } catch {
            // 失敗は固定の文脈で記録する（文脈に利用者の入力や ID を混ぜない・要件 15.1）
            SoratomoError.record(error, context: "soratomo.fetchMyGroups")
            state = .error(error)
        }
    }

    // MARK: - 表示用

    /// 読み込みの失敗を伝える固定の文言（失敗していなければ nil）
    var errorMessage: String? {
        guard case let .error(error) = state else { return nil }
        // サービスは SoratomoError だけを投げる（typed throws）。念のため、それ以外は「不明」の文言にする
        return (error as? SoratomoError ?? .unknown).userMessage
    }
}
