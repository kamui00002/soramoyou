//
//  SoratomoLeaveViewModel.swift
//  Soramoyou
//
//  そらとものグループを 1 つだけ抜ける画面の状態 ⭐️
//  （leave-group 8.1・design.md の SoratomoLeaveViewModel・要件への差し戻し D1〜D4・
//    要件 1.2〜1.9・4.3・4.4・4.5・5.1・5.4・11.1・12.1）
//
//  流れ:
//    1. メニューの「グループを抜ける」→ `requestLeave()`。通信を確かめ、監視しているグループとメンバー一覧を読み、
//       引き継ぐ人と最後の 1 人を予測して、確認（`.confirming`）を出す
//    2. 確認の「キャンセル」→ `cancel()`（何も呼ばない）／「抜ける」→ `confirm()`
//    3. `confirm()` は、タイムラインの監視を止めてから抜けるのサービスを呼ぶ。
//       成功、または失敗の後にサーバーで「メンバーでない」と確かめられたら「抜けた後」へ進む。
//       メンバーのまま・確かめられないときは、失敗の文言を出し、監視を張り直して `.idle` へ戻す（もう一度選べる）
//    4. 「抜けた後」は 1 か所（`finishLeaving`）で、端末の記録 → 画像と投稿の覚え → 計測 → ルーター の順に 1 回ずつ呼ぶ
//
//  ⚠️ design.md は「ViewModel は計測だけを行い、onLeft が記録・キャッシュ・ルーターを行う」と書くが、
//     tasks.md の順（記録 → キャッシュ → 計測 → ルーター）を守るため、記録とキャッシュを別のクロージャ
//     （`rememberLeft`・`purgeLocalData`）に分け、この ViewModel が 4 つを順に呼ぶ（契約の「3」の決定）。
//  ⚠️ グループ名・引き継ぐ人の表示名は画面にだけ出す。計測・ログ・`SoratomoError.record` の文脈には入れない（要件 11.1）。
//

import Foundation

// MARK: - 確認に出す内容

/// 抜ける前の予測（引き継ぐ人と、最後の 1 人か）
///
/// サーバーの `pickNextOwner` と同じ規則で、アプリ側で先に予測する（確認の文言と計測に使う）。
/// 確認を出している間にほかの人が参加・退出すると、実際の結果と違いうる（要件 1 の補足で受け入れ済み）。
struct SoratomoLeavePrediction: Equatable {
    /// 自分がオーナーか（`ownerId == uid`）
    let isOwner: Bool
    /// 自分以外のメンバーが 0 人か（抜けるとグループごと消える）
    let isLastMember: Bool
    /// 引き継ぐ人の uid（オーナーで、ほかが残るときだけ。残りを参加の古い順に並べた先頭）
    let successorUid: String?
}

/// 確認に出す内容（画面にだけ出す。ログと計測には出さない・要件 11.1）
struct SoratomoLeaveConfirmation: Equatable {
    /// 共通の本文（要件 1.3。固定の文言で、何も差し込まない）
    private static let commonMessage =
        "このグループにあなたが投稿した空（写真とキャプション）は、すべて削除され、元に戻せません。招待コードがあればまた参加できますが、削除した投稿は戻りません。"
    /// 最後の 1 人のときに足す文（要件 1.5）
    private static let lastMemberMessage = "あなたが最後のメンバーのため、グループと招待コードも削除され、だれも参加できなくなります。"

    /// グループ名（題に差し込む）
    let groupName: String
    /// 予測（どの文を足すかを決める）
    let prediction: SoratomoLeavePrediction
    /// 引き継ぐ人の表示名。引き継ぎが無い（`prediction.successorUid == nil`）ときだけ nil。
    /// 引き継ぎがあって表示名を読めないときは、代替の `RankingDisplayText.authorName(nil)`（D2）
    let successorName: String?

    /// 確認の題（「{グループ名}を抜けますか？」）
    var title: String {
        "\(groupName)を抜けますか？"
    }

    /// 確認の本文（design.md の「確認の文言」の表の 3 通り）
    ///
    /// - 最後の 1 人（要件 1.5）: 共通 ＋ 空行 ＋ グループと招待コードも消える旨
    /// - オーナーで、ほかが残る（要件 1.4）: 共通 ＋ 空行 ＋ 「オーナーは{表示名}さんに引き継がれます。」
    /// - ただのメンバー（オーナーが残る）: 共通だけ
    var message: String {
        if prediction.isLastMember {
            return Self.commonMessage + "\n\n" + Self.lastMemberMessage
        }
        if prediction.successorUid != nil {
            // 表示名は init の時点で代替を入れてあるが、nil で作られても uid から作った文字を出さないように代替にする
            let name = successorName ?? RankingDisplayText.authorName(nil)
            return Self.commonMessage + "\n\n" + "オーナーは\(name)さんに引き継がれます。"
        }
        return Self.commonMessage
    }
}

/// 抜けた後にルーターへ渡すもの（`onLeft` の引数）
struct SoratomoLeftContext: Equatable {
    /// 抜けたグループの ID
    let groupId: String
    /// グループ名（一覧の一時表示にだけ使う。ログと計測には出さない）
    let groupName: String
    /// アプリが片づけの完了まで確かめたか（失敗の後に「メンバーでない」と分かって抜けた扱いにした 4.5 なら false）
    let completed: Bool

    /// 一覧に戻った後の一時表示の文言（要件 5.1・4.5）
    ///
    /// ⚠️ `SoratomoError.notMember.userMessage`（「グループを開けませんでした」）とは違う文にする（要件 5.2）
    var notice: String {
        completed
            ? "\(groupName)を抜けました"
            : "\(groupName)を抜けました。残りの片づけは自動で終わります"
    }
}

// MARK: - ViewModel

/// そらとものグループを 1 つだけ抜ける画面の状態（タイムラインの画面が `@StateObject` で持つ）
///
/// - 二重の確定を防ぐのは `phase`。`confirm()` は最初の `await` より前に `.leaving` にする（要件 1.9）。
/// - 確認を出すときに読んだ uid を覚えておき、`confirm()`・`absorbLostMembership(groupId:)`・「抜けた後」は
///   その uid を使う。`currentUid()` を読み直さない（サインアウト直後の経路で nil になり、端末の記録が落ちるのを防ぐ）
/// - 「抜けた後」へ進んだら `phase` は `.leaving` のまま `.idle` に戻さない。画面はルーターが閉じる
///   （覆いを外すと、閉じるまでの一瞬に操作できてしまうため）
/// - 画面の文言は固定の文言（`SoratomoError.userMessage`・`SoratomoFailedAction.userMessage`）だけを出す
@MainActor
final class SoratomoLeaveViewModel: ObservableObject {
    // MARK: - 型

    /// 抜けるの処理の段
    enum Phase: Equatable {
        /// メニューを受け付ける
        case idle
        /// 確認の材料（グループ・メンバー一覧・引き継ぐ人の表示名）を読んでいる
        case preparing
        /// 確認を出している（キャンセルか抜けるを待つ）
        case confirming(SoratomoLeaveConfirmation)
        /// 片づけの完了を待っている／抜けた後（画面全体を覆って操作させない・要件 1.9）
        case leaving
    }

    /// 確認に出した内容と、そのときに読んだ uid
    ///
    /// `confirm()`・`absorbLostMembership(groupId:)`・「抜けた後」は、ここの uid を使う。
    private struct Attempt {
        /// 確認に出した内容（予測とグループ名）
        let confirmation: SoratomoLeaveConfirmation
        /// 確認を出すときに読んだ uid
        let uid: String
    }

    // MARK: - 公開する状態

    /// 抜けるの処理の段
    @Published private(set) var phase: Phase = .idle

    /// 一時の知らせ（要件 1.7・1.8・4.4）。OK だけのアラートで出し、閉じたら画面が nil に戻す
    @Published var alertMessage: String?

    // MARK: - 依存

    /// 抜けるグループの ID
    private let groupId: String
    /// 抜けるのサービス
    private let leaveService: any SoratomoLeaveServiceProtocol
    /// グループのサービス（`fetchMembers` だけを使う）
    private let groupService: any SoratomoGroupServiceProtocol
    /// いまログインしている利用者の uid（未ログインなら nil）
    private let currentUid: () -> String?
    /// 通信できる状態か（メニューと確定の前の確認・要件 1.7）
    private let isOnline: @MainActor () -> Bool
    /// タイムラインが監視しているグループ（まだ読めていなければ nil）
    private let currentGroup: @MainActor () -> SoratomoGroup?
    /// 引き継ぐ人の表示名（読めない・未設定は nil）
    private let displayName: @MainActor (String) async -> String?
    /// タイムラインの監視を止める（抜けるの処理の間・要件 5.2）
    private let suspendTimeline: @MainActor () -> Void
    /// タイムラインの監視を張り直す（抜けられなかったとき・要件 4.4）
    private let resumeTimeline: @MainActor () -> Void
    /// この端末で抜けたグループとして記録する（本物は `SoratomoLeftGroups.insert`・要件 5.3・5.6）
    private let rememberLeft: @MainActor (_ groupId: String, _ uid: String) -> Void
    /// 端末の画像のキャッシュと投稿の覚えを消す（本物は `SoratomoImageCache.removeGroup` と
    /// `SoratomoSkyLookup.forget(groupId:)`・要件 5.4。ブロックの一覧・通報の記録・表示名の覚えには触れない）
    private let purgeLocalData: @MainActor (_ groupId: String) -> Void
    /// 一覧へ戻す（本物は `SoratomoRouter.finishLeaving(groupId:notice:)`・要件 5.1）
    private let onLeft: @MainActor (SoratomoLeftContext) -> Void
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void

    // MARK: - 覚え

    /// 確認に出している内容と uid（`.confirming` の間と、`confirm()` が結果を待つ間）
    private var preparedAttempt: Attempt?

    /// 未確定の抜ける（D1）
    ///
    /// 抜けるの失敗の後に、メンバーかどうかをサーバーで確かめられなかった（`.unknown`）ときだけ覚える。
    /// 実は抜けるが済んでいた場合、張り直した監視は、つながった時点で「メンバーでない」を届ける。
    /// そのとき（`absorbLostMembership`）と、もう一度メニューを押してメンバー一覧が「メンバーでない」で読めないときに、
    /// ここの内容で「抜けた後」へ進む。サーバーで「メンバーのまま」と分かったら消す。
    private var unresolvedLeave: Attempt?

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 抜けるグループの ID
    ///   - leaveService: 抜けるのサービス
    ///   - groupService: グループのサービス（`fetchMembers` だけを使う）
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - isOnline: 通信できる状態かを返す
    ///   - currentGroup: タイムラインが監視しているグループを返す（まだ読めていなければ nil）
    ///   - displayName: 引き継ぐ人の表示名を返す（読めない・未設定は nil）
    ///   - suspendTimeline: タイムラインの監視を止める（本番は `SoratomoTimelineViewModel.suspendObservation()`）
    ///   - resumeTimeline: タイムラインの監視を張り直す（本番は `SoratomoTimelineViewModel.start()`）
    ///   - rememberLeft: 抜けたグループを端末に記録する（本番は `SoratomoLeftGroups.insert`）
    ///   - purgeLocalData: 端末の画像のキャッシュと投稿の覚えを消す
    ///   - onLeft: 一覧へ戻す（本番は `SoratomoRouter.finishLeaving(groupId:notice:)`）
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    init(
        groupId: String,
        leaveService: any SoratomoLeaveServiceProtocol,
        groupService: any SoratomoGroupServiceProtocol,
        currentUid: @escaping () -> String?,
        isOnline: @escaping @MainActor () -> Bool,
        currentGroup: @escaping @MainActor () -> SoratomoGroup?,
        displayName: @escaping @MainActor (String) async -> String?,
        suspendTimeline: @escaping @MainActor () -> Void,
        resumeTimeline: @escaping @MainActor () -> Void,
        rememberLeft: @escaping @MainActor (_ groupId: String, _ uid: String) -> Void,
        purgeLocalData: @escaping @MainActor (_ groupId: String) -> Void,
        onLeft: @escaping @MainActor (SoratomoLeftContext) -> Void,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log
    ) {
        self.groupId = groupId
        self.leaveService = leaveService
        self.groupService = groupService
        self.currentUid = currentUid
        self.isOnline = isOnline
        self.currentGroup = currentGroup
        self.displayName = displayName
        self.suspendTimeline = suspendTimeline
        self.resumeTimeline = resumeTimeline
        self.rememberLeft = rememberLeft
        self.purgeLocalData = purgeLocalData
        self.onLeft = onLeft
        self.logEvent = logEvent
    }

    // MARK: - 1. メニュー → 確認

    /// メニューの「グループを抜ける」（確認の材料を読み、確認を出す）
    ///
    /// - `.idle` のときだけ受け付ける（確認・処理中に重ねて押しても何もしない）
    /// - 通信が無ければ、通信の文言だけを出す。計測は記録しない（要件 1.7）
    /// - uid・監視しているグループ・メンバー一覧のどれかが無い・読めない・自分がメンバー一覧にいないときは、
    ///   「グループの情報を読み込めませんでした」を出し、確認を出さずに `.idle` へ戻る（要件 1.8）
    /// - ただし「未確定の抜ける」を覚えていて、メンバー一覧が「メンバーでない」（`.notMember`）で読めないときは、
    ///   抜けるが済んでいたとみなして「抜けた後」へ進む（D1・`completed: false`）
    /// - 引き継ぐ人がいるときだけ、その人の表示名を読む。読めなければ代替の「ユーザー」で確認を出す（D2）
    func requestLeave() async {
        guard phase == .idle else { return }

        guard isOnline() else {
            alertMessage = SoratomoError.network.userMessage
            return
        }

        phase = .preparing

        guard let uid = currentUid(), !uid.isEmpty, let group = currentGroup() else {
            failPreparing()
            return
        }

        let members: [SoratomoMember]
        do throws(SoratomoError) {
            members = try await groupService.fetchMembers(groupId: groupId)
        } catch {
            // 待っている間に、監視の「メンバーでない」で「抜けた後」へ進んでいたら（absorbLostMembership）、何もしない
            guard phase == .preparing else { return }
            if error == .notMember, let unresolved = unresolvedLeave {
                // D1: 前の抜けるが実は済んでいた（ルールが読みを拒否した＝もうメンバーでない）
                finishLeaving(unresolved, groupDeleted: unresolved.confirmation.prediction.isLastMember, completed: false)
                return
            }
            // 固定の文脈で記録する（グループ ID・uid を混ぜない・要件 11.1）
            SoratomoError.record(error, context: "soratomo.prepareLeave")
            failPreparing()
            return
        }
        guard phase == .preparing else { return }

        guard let prediction = Self.predict(members: members, ownerId: group.ownerId, uid: uid) else {
            // 自分がメンバー一覧にいない（読めたのに自分がいない）。予測できないので確認を出さない
            failPreparing()
            return
        }

        var successorName: String?
        if let successorUid = prediction.successorUid {
            successorName = await Self.successorDisplayName(displayName(successorUid))
            guard phase == .preparing else { return }
        }

        let confirmation = SoratomoLeaveConfirmation(
            groupName: group.name,
            prediction: prediction,
            successorName: successorName
        )
        preparedAttempt = Attempt(confirmation: confirmation, uid: uid)
        phase = .confirming(confirmation)
    }

    /// 確認の「キャンセル」（要件 1.6）。確認を閉じて `.idle` に戻すだけで、何も呼ばない
    func cancel() {
        guard case .confirming = phase else { return }
        preparedAttempt = nil
        phase = .idle
    }

    // MARK: - 2. 確定

    /// 確認の「抜ける」
    ///
    /// - `.confirming` のときだけ受け付ける。最初の `await` より前に `.leaving` にするので、処理中の 2 回目は何もしない
    /// - 通信が無ければ、通信の文言を出し、`soratomo_leave_failed`（`network`）を記録して `.idle` へ戻る（D4）
    /// - タイムラインの監視を止めてから、抜けるのサービスを呼ぶ（止めないと「グループを開けませんでした」が出る・要件 5.2）
    /// - 成功 → 「抜けた後」（`groupDeleted` はサーバーの値・`completed: true`）
    /// - 失敗 → サーバーでメンバーかどうかを確かめて分ける（`handleLeaveFailure`）
    func confirm() async {
        guard case .confirming = phase, let attempt = preparedAttempt else { return }

        guard isOnline() else {
            alertMessage = SoratomoError.network.userMessage
            logEvent(.leaveFailed(.network))
            preparedAttempt = nil
            phase = .idle
            return
        }

        // ⚠️ 最初の await より前に処理中にする（二重の確定を防ぐ・要件 1.9）
        phase = .leaving
        suspendTimeline()

        do throws(SoratomoLeaveError) {
            let result = try await leaveService.leave(groupId: groupId)
            finishLeaving(attempt, groupDeleted: result.groupDeleted, completed: true)
        } catch {
            // 失敗の記録（SoratomoError.record）は、抜けるのサービスが固定の文脈で済ませている。ここでは重ねない
            await handleLeaveFailure(error, attempt: attempt)
        }
    }

    /// 抜けるの失敗の後に、サーバーでメンバーかどうかを確かめて分ける（要件 4.4・4.5・D1）
    ///
    /// | サーバーの答え | 扱い |
    /// |---|---|
    /// | メンバーでない | 抜けるは済んでいた（4.5）。「抜けた後」へ（`completed: false`・`groupDeleted` は予測の `isLastMember`） |
    /// | メンバーのまま | 抜けられなかった（4.4）。失敗の文言・監視の張り直し・`leave_failed`。未確定の覚えは消す |
    /// | 確かめられない | 4.4 と同じに扱い、未確定の抜けるとして覚える（D1） |
    private func handleLeaveFailure(_ error: SoratomoLeaveError, attempt: Attempt) async {
        let membership = await leaveService.membershipOnServer(groupId: groupId, uid: attempt.uid)
        switch membership {
        case .notMember:
            finishLeaving(attempt, groupDeleted: attempt.confirmation.prediction.isLastMember, completed: false)
        case .member:
            failLeaving(error, unresolved: nil)
        case .unknown:
            failLeaving(error, unresolved: attempt)
        }
    }

    /// 抜けられなかったことを出し、もう一度選べるように戻す（要件 4.4・12.1）
    ///
    /// - 文言: 通信（`.network`）なら通信の文言、それ以外（`.incomplete`・`.unknown`）は「グループを抜けられませんでした」
    /// - 計測: `soratomo_leave_failed` の `reason` は、通信なら `network`、それ以外は `unknown`
    /// - Parameters:
    ///   - error: 抜けるのサービスの失敗
    ///   - unresolved: 未確定の抜けるとして覚える内容（メンバーのままと分かったときは nil＝覚えを消す）
    private func failLeaving(_ error: SoratomoLeaveError, unresolved: Attempt?) {
        let reason: SoratomoLeaveFailReason
        switch error {
        case .network:
            alertMessage = SoratomoError.network.userMessage
            reason = .network
        case .incomplete, .unknown:
            alertMessage = SoratomoFailedAction.leaveGroup.userMessage
            reason = .unknown
        }
        resumeTimeline()
        logEvent(.leaveFailed(reason))
        unresolvedLeave = unresolved
        preparedAttempt = nil
        phase = .idle
    }

    // MARK: - 3. 監視が「メンバーでない」を届けたとき（D1）

    /// 未確定の抜けるの後に、張り直した監視が「メンバーでない」を届けたときに、タイムラインの画面が先に呼ぶ（D1）
    ///
    /// 未確定の抜けるを覚えていて、`groupId` がこのグループで、処理中（`.leaving`）でないときだけ、
    /// 覚えた内容で「抜けた後」へ進めて true を返す（「グループを開けませんでした」は出さない）。
    /// それ以外は何もせずに false を返す（画面はルーターへ「読めなかった」を知らせる）。
    /// - Parameter groupId: 監視が「メンバーでない」を届けたグループの ID
    /// - Returns: 「抜けた後」へ進めたら true
    func absorbLostMembership(groupId: String) -> Bool {
        guard let unresolved = unresolvedLeave, groupId == self.groupId, phase != .leaving else {
            return false
        }
        finishLeaving(unresolved, groupDeleted: unresolved.confirmation.prediction.isLastMember, completed: false)
        return true
    }

    // MARK: - 4. 抜けた後

    /// 抜けた後の後片づけと遷移（成功・4.5・D1 のすべてがここを通る）
    ///
    /// 一覧へ戻った時点で、抜けたグループが端末のどこにも出ないように、次の順に 1 回ずつ呼ぶ。
    /// 1. 端末の記録（`rememberLeft`・要件 5.3・5.6）
    /// 2. 画像のキャッシュと投稿の覚え（`purgeLocalData`・要件 5.4）
    /// 3. 計測 `soratomo_group_left`（`role` は予測の `isOwner`・要件 12.1。グループ名と表示名は型の上で入らない）
    /// 4. ルーター（`onLeft`・一覧へ戻して一時表示・要件 5.1）
    ///
    /// `phase` は `.leaving` のまま（`.idle` に戻さない）。覚えは呼ぶ前に消す（呼んだ先から重ねて呼ばれても二重にしない）。
    /// - Parameters:
    ///   - attempt: 確認に出した内容と uid
    ///   - groupDeleted: グループごと消えたか（成功はサーバーの値、4.5 と D1 は予測の `isLastMember`）
    ///   - completed: アプリが片づけの完了まで確かめたか
    private func finishLeaving(_ attempt: Attempt, groupDeleted: Bool, completed: Bool) {
        phase = .leaving
        preparedAttempt = nil
        unresolvedLeave = nil

        let role: SoratomoLeaveRole = attempt.confirmation.prediction.isOwner ? .owner : .member
        let context = SoratomoLeftContext(
            groupId: groupId,
            groupName: attempt.confirmation.groupName,
            completed: completed
        )

        rememberLeft(groupId, attempt.uid)
        purgeLocalData(groupId)
        logEvent(.groupLeft(role: role, groupDeleted: groupDeleted, completed: completed))
        onLeft(context)
    }

    // MARK: - 予測（純関数）

    /// 引き継ぐ人と最後の 1 人を予測する（単体テスト用に公開する）
    ///
    /// 自分を除いた残りを `SoratomoGroupService.sortedForMembers`（参加日時の古い順・同じなら uid の順）で並べ、
    /// 先頭を引き継ぐ人とする。サーバーの `pickNextOwner` と同じ規則（leave-group 3.6）。
    /// 自分がオーナーでなければ（オーナーが残る）引き継ぎは無い。
    /// - Parameters:
    ///   - members: メンバー一覧（順不同・自分を含む）
    ///   - ownerId: グループのオーナーの uid
    ///   - uid: 自分の uid
    /// - Returns: 予測。自分がメンバー一覧にいなければ nil
    static func predict(members: [SoratomoMember], ownerId: String, uid: String) -> SoratomoLeavePrediction? {
        guard members.contains(where: { $0.id == uid }) else { return nil }

        let others = SoratomoGroupService.sortedForMembers(members.filter { $0.id != uid })
        let isOwner = ownerId == uid
        return SoratomoLeavePrediction(
            isOwner: isOwner,
            isLastMember: others.isEmpty,
            successorUid: isOwner ? others.first?.id : nil
        )
    }

    // MARK: - Private

    /// 確認の材料を読めなかったことを出し、`.idle` へ戻す（要件 1.8）
    private func failPreparing() {
        alertMessage = SoratomoFailedAction.prepareLeave.userMessage
        preparedAttempt = nil
        phase = .idle
    }

    /// 確認に出す、引き継ぐ人の表示名（D2）
    ///
    /// 読めない・未設定（nil）・空白だけは、メンバー一覧と同じ代替の「ユーザー」（`RankingDisplayText.authorName(nil)`）にする。
    /// ⚠️ uid から作った文字（頭文字・先頭の数文字）で代用しない。
    /// - Parameter name: `displayName` が返した表示名
    private static func successorDisplayName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? RankingDisplayText.authorName(nil) : trimmed
    }
}
