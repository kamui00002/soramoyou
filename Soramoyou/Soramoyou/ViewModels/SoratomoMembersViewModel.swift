//
//  SoratomoMembersViewModel.swift
//  Soramoyou
//
//  そらとものメンバー一覧の ViewModel ⭐️
//  （tasks 13.9・design.md の SoratomoMembersView・ViewModel・要件 14.3・15.4・19.1・19.3）
//

import Foundation

/// そらとものメンバー一覧の ViewModel
///
/// - グループのメンバー全員を読み、オーナーを先頭に、その後は参加の古い順に並べる（要件 19.1・19.3）
/// - `soratomo_members_viewed`（member_count）は、この ViewModel が生きている間に、最初に読めたときだけ 1 回記録する。
///   読めなかったときは記録しない（人数が分からないため。失敗は非致命エラーとして記録する）
/// - 読み込みの失敗は、固定の文言（`SoratomoError.userMessage`）で出す。サーバーの文言は出さない
/// - 表示名とアイコンは、この ViewModel では持たない。画面が `SoratomoProfileStore` から出す
///   （ViewModel は `memberUids` を渡すだけ）
@MainActor
final class SoratomoMembersViewModel: ObservableObject {
    // MARK: - Properties

    /// メンバー一覧の読み込み状態（並べ終えたもの）。失敗は `SoratomoError` で持つ
    @Published private(set) var state: LoadableState<[SoratomoMember]> = .idle

    /// 表示するグループの ID
    private let groupId: String
    /// グループのサービス
    private let groupService: any SoratomoGroupServiceProtocol
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void

    /// `soratomo_members_viewed` を記録したか（1 回だけ記録するため）
    private var hasLoggedMembersViewed = false

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 表示するグループの ID
    ///   - groupService: グループのサービス
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    init(
        groupId: String,
        groupService: any SoratomoGroupServiceProtocol,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log
    ) {
        self.groupId = groupId
        self.groupService = groupService
        self.logEvent = logEvent
    }

    // MARK: - 読み込み

    /// メンバー一覧を読む
    ///
    /// 画面を開いたとき・引き下げで更新したとき・失敗の後に読み直すときに呼ぶ。
    /// - すでに読んだ一覧があるときは、読み直しの間も前の一覧を出したままにする（ちらつかせない）
    func load() async {
        if !state.isLoaded {
            state = .loading
        }

        do {
            let members = try await groupService.fetchMembers(groupId: groupId)
            let ordered = Self.ordered(members)
            state = .loaded(ordered)
            if !hasLoggedMembersViewed {
                hasLoggedMembersViewed = true
                // 人数だけを記録する（uid・表示名は入れない・要件 14.4）
                logEvent(.membersViewed(memberCount: ordered.count))
            }
        } catch {
            // 失敗は固定の文脈で記録する（文脈にグループ ID や利用者の入力を混ぜない・要件 15.1・15.4）
            SoratomoError.record(error, context: "soratomo.fetchMembers")
            state = .error(error)
        }
    }

    // MARK: - 並び順

    /// メンバーを、オーナーを先頭に、その後は参加の古い順に並べる（要件 19.3・design.md の「オーナーを先頭、その後は参加順」）
    ///
    /// サービス（`SoratomoGroupService.sortedForMembers`）は参加日時の古い順（同じなら uid の順）に並べるだけで、
    /// オーナーを先頭にはしない。オーナーは通常いちばん先に参加しているが、参加日時の記録がずれた場合にも
    /// 必ず先頭に来るよう、ここで「オーナーが先」を加えて並べ直す。
    /// 並べ直しはサービスの順に頼らない完全な比較にしている（最大 20 人なので負担は無く、
    /// モックなどサービス以外から渡された順不同の配列でも同じ結果になるため）。
    /// - Parameter members: 読み取れたメンバー（順不同でよい）
    /// - Returns: オーナー → 参加日時の古い順 → uid の順
    static func ordered(_ members: [SoratomoMember]) -> [SoratomoMember] {
        members.sorted { lhs, rhs in
            let lhsIsOwner = lhs.role == .owner
            let rhsIsOwner = rhs.role == .owner
            if lhsIsOwner != rhsIsOwner {
                // オーナーを先に置く
                return lhsIsOwner
            }
            if lhs.joinedAt != rhs.joinedAt {
                return lhs.joinedAt < rhs.joinedAt
            }
            // 参加日時が同じなら uid の順（並びを毎回同じにするため）
            return lhs.id < rhs.id
        }
    }

    // MARK: - 表示用

    /// 読み込んだメンバーの uid（画面が `SoratomoProfileStore.prefetch(uids:)` に渡す）
    var memberUids: Set<String> {
        guard case let .loaded(members) = state else { return [] }
        return Set(members.map(\.id))
    }

    /// 読み込みの失敗を伝える固定の文言（失敗していなければ nil）
    var errorMessage: String? {
        guard case let .error(error) = state else { return nil }
        // サービスは SoratomoError だけを投げる（typed throws）。念のため、それ以外は「不明」の文言にする
        return (error as? SoratomoError ?? .unknown).userMessage
    }
}
