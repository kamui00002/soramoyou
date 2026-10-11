//
//  SoratomoGroupListViewModel.swift
//  Soramoyou
//
//  そらとものグループ一覧の ViewModel ⭐️
//  （tasks 13.1・design.md の SoratomoGroupListView・ViewModel・要件 5.1〜5.6・14.3・15.4）
//  （leave-group 8.4・design.md の SoratomoGroupListViewModel・SoratomoGroupFormViewModel（変更）・要件 5.3・5.6）
//

import Foundation

/// そらとものグループ一覧の ViewModel
///
/// - 自分が入っているグループを、最新の活動の新しい順に読む（並べ替えはサービスが行う・最大 10 件）
/// - `soratomo_opened`（group_count）は、この ViewModel が生きている間に、最初に読めたときだけ 1 回記録する。
///   読めなかったときは記録しない（件数が分からないため。失敗は非致命エラーとして記録する）
/// - 読み込みの失敗は、固定の文言（`SoratomoError.userMessage`）で出す。サーバーの文言は出さない
/// - この端末で抜けたグループ（`SoratomoLeftGroups` の記録にあるもの）は、サーバーが「メンバーだ」と
///   確かめたときだけ出す（leave-group 8.4・要件 5.3・5.6）。Firestore の端末のキャッシュには、
///   抜けた直後のグループがしばらく残るため、一覧の問い合わせの結果だけを信じない
@MainActor
final class SoratomoGroupListViewModel: ObservableObject {
    // MARK: - Properties

    /// 一覧の読み込み状態。失敗は `SoratomoError` で持つ
    @Published private(set) var state: LoadableState<[SoratomoGroup]> = .idle

    /// グループのサービス
    private let groupService: any SoratomoGroupServiceProtocol
    /// いまログインしている利用者の uid（未ログインなら nil）
    private let currentUid: () -> String?
    /// 抜けるのサービス（記録にあるグループの、サーバーでの所属の再確認に使う）
    private let leaveService: any SoratomoLeaveServiceProtocol
    /// この端末で抜けたグループの記録
    private let leftGroups: SoratomoLeftGroups
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void

    /// `soratomo_opened` を記録したか（1 回だけ記録するため）
    private var hasLoggedOpened = false

    // MARK: - Init

    /// - Parameters:
    ///   - groupService: グループのサービス
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - leaveService: 抜けるのサービス（記録にあるグループの所属を、サーバーで確かめる）
    ///   - leftGroups: この端末で抜けたグループの記録。
    ///     ⚠️ 既定値を付けない。既定の `SoratomoLeftGroups()` は本物の UserDefaults に書くので、テストが本物の記録を汚す
    ///   - logsOpened: `soratomo_opened` を記録するか。入口から開いたときだけ true（要件 14 の表の「入口からグループ一覧を開いた」）。
    ///     通知から開いたとき（一覧の上にタイムライン）は false にする（14.3 の点検で直した）
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    init(
        groupService: any SoratomoGroupServiceProtocol,
        currentUid: @escaping () -> String?,
        leaveService: any SoratomoLeaveServiceProtocol,
        leftGroups: SoratomoLeftGroups,
        logsOpened: Bool = true,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log
    ) {
        self.groupService = groupService
        self.currentUid = currentUid
        self.leaveService = leaveService
        self.leftGroups = leftGroups
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
    /// - 読んだグループのうち、この端末で抜けた記録があるものだけ、サーバーでの所属を確かめる（1 件ずつ順に）。
    ///   `.member`（別の端末で入り直した）なら記録から外して出す。`.notMember`・`.unknown`（圏外など）なら出さない。
    ///   記録に無いグループは、確かめずにそのまま出す
    /// - `soratomo_opened` の `group_count` は、隠した後の（出す）件数
    /// - 前に読んだ一覧に、この端末で抜けた記録のあるグループがあれば、読み直しを待たずにすぐ外す
    ///   （抜けた直後に一覧へ戻った瞬間にも出さない・要件 5.2・5.3。下の「すぐに外す」のコメント）
    func load() async {
        guard let uid = currentUid() else { return }

        // すぐに外す（leave-group 8.4・要件 5.2・5.3）:
        // 抜けた直後に一覧へ戻ると、読み直し（一覧の問い合わせとサーバーでの所属の確認）が終わるまで、
        // 前に読んだ一覧が出たままになる。そこに抜けたグループのカードが残っていると押せてしまい、
        // 押すとタイムラインが「グループを開けませんでした」を出す。記録は端末にあって待たずに読めるので、
        // 最初の await より前に外す。サーバーで「メンバーだ」と確かめられたもの（別の端末で入り直した）は、
        // 下の読み直し（visibleGroups）で戻る。計測（hasLoggedOpened）には触れない
        if case let .loaded(current) = state {
            let kept = current.filter { !leftGroups.contains($0.id, uid: uid) }
            if kept.count != current.count {
                state = .loaded(kept)
            }
        }

        if !state.isLoaded {
            state = .loading
        }

        do {
            let fetched = try await groupService.fetchMyGroups(uid: uid)
            let groups = await visibleGroups(fetched, uid: uid)
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

    // MARK: - 抜けたグループを隠す（leave-group 8.4）

    /// 読んだグループから、この端末で抜けたまま戻っていないものを取り除く
    ///
    /// - 記録にあるグループ → `membershipOnServer` の結果が `.member` のときだけ残し、記録から外す
    /// - 記録に無いグループ → 確かめずに残す（今までの振る舞い）
    /// - Parameters:
    ///   - groups: 一覧の問い合わせで読んだグループ（並びは保つ）
    ///   - uid: いまの利用者の uid（読み込みを始めたときのもの）
    /// - Returns: 出してよいグループ
    private func visibleGroups(_ groups: [SoratomoGroup], uid: String) async -> [SoratomoGroup] {
        var visible: [SoratomoGroup] = []
        for group in groups {
            guard leftGroups.contains(group.id, uid: uid) else {
                visible.append(group)
                continue
            }
            switch await leaveService.membershipOnServer(groupId: group.id, uid: uid) {
            case .member:
                // 別の端末で入り直した。もう抜けた状態ではないので、記録から外して出す
                leftGroups.remove(group.id, uid: uid)
                visible.append(group)
            case .notMember, .unknown:
                // 抜けている・確かめられない（圏外など）は出さない。記録は残す
                break
            }
        }
        return visible
    }

    // MARK: - 表示用

    /// 読み込みの失敗を伝える固定の文言（失敗していなければ nil）
    var errorMessage: String? {
        guard case let .error(error) = state else { return nil }
        // サービスは SoratomoError だけを投げる（typed throws）。念のため、それ以外は「不明」の文言にする
        return (error as? SoratomoError ?? .unknown).userMessage
    }
}
