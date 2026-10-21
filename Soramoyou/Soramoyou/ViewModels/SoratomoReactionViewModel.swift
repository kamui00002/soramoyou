//
//  SoratomoReactionViewModel.swift
//  Soramoyou
//
//  そらともの投稿へのリアクションの操作の ViewModel ⭐️
//  （soratomo-reactions 7.6・design.md の SoratomoReactionViewModel の節・
//   要件 1.3, 1.4, 1.5, 1.6, 1.9, 1.10, 2.6, 5.2, 8.8, 10.1, 10.2, 10.3, 10.4, 10.5, 10.7, 14.1, 15.1, 15.3）
//
//  - 1 つのグループの投稿へのリアクションの操作（付ける・外す・選び直す）と、自分の分の一時の上書き・失敗の文言・計測を受け持つ
//  - 楽観的な表示（1.9）: 送っている間（.sending）と、サーバーが受け付けてから 10 秒（.confirmed）だけ、
//    自分の分を上書きで画面に出す。10 秒たったら上書きを手放し、表示を監視の値（サーバーの状態）に戻す（2.6）。
//    手放すのは札（token）が同じときだけ（あとから選び直した新しい上書きを、前の操作のタスクが消さないため）
//  - 送る前に通信が無ければ送らない（10.1・10.2）。端末に操作を積まない（送り直しの列を持たない）
//  - ブロックの一覧が変わったら objectWillChange を送り、画面に数を作り直させる（5.2）
//
//  ⚠️ 想定外の失敗（.unknown・.permissionDenied）の非致命エラーの記録は、この ViewModel では行わない。
//     記録はサービス（7.5 の SoratomoReactionService の setReaction が失敗を写すところ）の 1 か所だけにする
//     （利用者の決定 2026-10-21）。ViewModel でも記録すると、1 回の失敗が 2 件として残り、件数を数え違えるため。
//     このファイルでは `SoratomoError` の `record` を 1 回も呼ばない（design.md の失敗の手順 6 と tasks.md 7.6 も、
//     同じ決定に書き直し済み）。
//  ⚠️ 計測（logEvent）に入るのは列挙の値と数だけ。uid・グループ ID・投稿 ID は SoratomoEvent の型の上で入らない（14.1・15.3）。
//  ⚠️ この ViewModel はサービスの容れ物（SoratomoDependencies）を受け取らない。
//     protocol とクロージャと SoratomoBlockedAuthors だけを受け取り、単体テストではモックとクロージャと、
//     テスト用の通知センターで作った SoratomoBlockedAuthors で作る。
//

import Combine
import Foundation

// MARK: - 失敗の知らせ

/// リアクションの失敗を伝える知らせ（文言は固定。内部のエラーコードは出さない・要件 10.4）
///
/// タイムラインの `SoratomoModerationNotice` と同じく、画面は `userMessage` だけを出す。
/// 失敗の種類（`SoratomoError`）をそのまま持つのは、画面とテストが「どの失敗だったか」を見分けられるようにするため。
enum SoratomoReactionNotice: Equatable {
    /// 付ける・外す・選び直すに失敗した（送る前に通信が無いと分かったときも `.network`）
    case failed(SoratomoError)

    /// 画面に出す文言（design.md の文言の表。利用者の入力やサーバーの文言を含めない・要件 15.1）
    var userMessage: String {
        switch self {
        case .failed(.network):
            // 送る前に通信が無かった（10.1）・送った後に通信が切れた・制限時間切れ
            SoratomoError.network.userMessage
        case .failed(.skyGone):
            // 投稿がもう無い（8.8）。タイムラインからは onSkyGone で取り除く
            SoratomoError.skyGone.userMessage
        case .failed(.notMember):
            // 既存の `SoratomoError.notMember.userMessage`（「グループを開けませんでした」）は開く操作の文なので、
            // リアクションの操作に合う独自の文にする（design.md の文言の表）
            "このグループのメンバーではないため、リアクションできませんでした"
        case .failed(.suspended):
            // 停止とお問い合わせの方法（10.5）
            SoratomoError.suspended.userMessage
        case .failed:
            // 想定外（.unknown・.permissionDenied など）は原因を言い切れないので、時間をおく案内だけにする
            "リアクションできませんでした。時間をおいてもう一度お試しください"
        }
    }
}

// MARK: - ViewModel

/// そらともの投稿へのリアクションの操作の ViewModel（1 つのグループの投稿だけを扱う）
@MainActor
final class SoratomoReactionViewModel: ObservableObject {
    // MARK: - 型

    /// 上書きの段階
    enum Phase: Equatable {
        /// 要求を送っている間（同じ投稿の操作を重ねて受け付けない・1.10）
        case sending
        /// サーバーが受け付けた後（監視の結果が届くまでの間、応答の値を出しておく・1.9）
        case confirmed
    }

    /// 自分の分の一時の上書き（1 つの投稿につき 1 つ）
    struct Overlay: Equatable {
        /// 画面に出す自分の分（この絵文字を付けた・外した）
        let value: SoratomoReactionOverride
        /// 送っている間か、確定した後か
        let phase: Phase
        /// 10 秒後の手放しで、新しい上書きを消さないための札（1 回の操作ごとに作り直す）
        let token: UUID
    }

    // MARK: - 公開する状態

    /// 投稿 ID → 自分の分の一時の上書き（このグループの投稿だけ）
    @Published private(set) var overlays: [String: Overlay] = [:]

    /// 失敗の知らせ（出し終えたら画面が nil に戻す）
    @Published var notice: SoratomoReactionNotice?

    /// 扱うグループの ID（要求の送り先のグループも、投稿の値でなくこれを使う）
    let groupId: String

    /// 確定した上書きを手放すタスク（投稿 ID → タスク。単体テストで完了を待つために公開する）
    ///
    /// 同じ投稿で新しい操作を始めたら控えを捨てる。前のタスクは止めずに走らせるが、札が違うので何も消さない。
    private(set) var expiryTasks: [String: Task<Void, Never>] = [:]

    // MARK: - 依存

    /// リアクションのサービス（Callable `soratomoSetReaction`）
    private let reactionService: any SoratomoReactionServiceProtocol
    /// ブロックした投稿者（アプリ全体で 1 つ。数と一覧からブロックした人の分を除くのに使う・5.1〜5.3）
    private let blockedAuthors: SoratomoBlockedAuthors
    /// いまログインしている利用者の uid（未ログインなら nil。空文字もログアウト中として扱う）
    private let currentUid: () -> String?
    /// 通信できる状態か（送る前の確認・10.1）
    private let isOnline: @MainActor () -> Bool
    /// 送った先の投稿がもう無いと分かったときに呼ぶ（タイムラインから取り除くため・8.8。
    /// タイムラインの ViewModel には `removeGoneSky(_:)` の口がある）
    private let onSkyGone: @MainActor (SoratomoSky) -> Void
    /// 確定した上書きを手放すまでの時間（ナノ秒。既定は 10 秒・2.6）
    private let confirmedLifetimeNanoseconds: UInt64
    /// 待つ口（既定は `Task.sleep`。単体テストで差し替えて、10 秒を待たずに手放しを確かめる）
    private let sleep: @Sendable (UInt64) async -> Void
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void

    /// ブロックの一覧の購読（変わったら objectWillChange を送る）
    private var blockedSubscription: AnyCancellable?

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 扱うグループの ID
    ///   - reactionService: リアクションのサービス
    ///   - blockedAuthors: ブロックした投稿者（本番は `SoratomoDependencies.live.blockedAuthors`）
    ///   - currentUid: いまログインしている利用者の uid を返す（nil か空文字ならログアウト中として扱う）
    ///   - isOnline: 通信できる状態かを返す
    ///   - onSkyGone: 送った先の投稿がもう無いと分かったときに呼ぶ
    ///   - confirmedLifetimeNanoseconds: 確定した上書きを手放すまでの時間。既定は 10 秒
    ///   - sleep: 待つ口。既定は `Task.sleep`（キャンセルされても投げずに戻る）
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    init(
        groupId: String,
        reactionService: any SoratomoReactionServiceProtocol,
        blockedAuthors: SoratomoBlockedAuthors,
        currentUid: @escaping () -> String?,
        isOnline: @escaping @MainActor () -> Bool,
        onSkyGone: @escaping @MainActor (SoratomoSky) -> Void,
        confirmedLifetimeNanoseconds: UInt64 = 10_000_000_000,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) },
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log
    ) {
        self.groupId = groupId
        self.reactionService = reactionService
        self.blockedAuthors = blockedAuthors
        self.currentUid = currentUid
        self.isOnline = isOnline
        self.onSkyGone = onSkyGone
        self.confirmedLifetimeNanoseconds = confirmedLifetimeNanoseconds
        self.sleep = sleep
        self.logEvent = logEvent

        // ブロックの一覧が変わったら、画面に作り直させる（5.2 の「手動で更新しなくても数が変わる」）。
        // 数そのものはここで覚えない。画面が描き直すときに summary(for:server:) が blockedAuthors.ids を読み直すので、
        // ここでは「変わる」ことだけを知らせればよい。
        // ⚠️ @Published は値が入る「前」に流れるが、objectWillChange も「変わる前」の知らせなので順番は合う
        //    （画面は知らせを受けた後の描き直しで、入った後の値を読む）。
        //    receive(on:) を付けないのは、変更と同じ流れで直ちに知らせるため（部品はメインアクター・タイムラインと同じ形）。
        //    dropFirst() は、購読した瞬間に流れてくるいまの値を「変化」として扱わないため。
        blockedSubscription = blockedAuthors.$ids
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                }
            }
    }

    // MARK: - 表示の判定

    /// 操作を出してよいか（ログイン中で、自分の投稿でない・1.6）
    ///
    /// ブロックした相手の投稿・この端末で通報した投稿は、投稿そのものがタイムラインに出ない（1.11）ので、ここでは見ない。
    /// - Parameter sky: 判定する投稿
    /// - Returns: 操作を出してよければ true
    func canReact(to sky: SoratomoSky) -> Bool {
        guard let uid = signedInUid else { return false }
        return sky.authorId != uid
    }

    /// この投稿の要求を送っている間か（1.10）
    /// - Parameter sky: 判定する投稿
    /// - Returns: 送っている間なら true（確定した後の 10 秒は偽。次の操作を受け付ける）
    func isSending(_ sky: SoratomoSky) -> Bool {
        overlays[sky.id]?.phase == .sending
    }

    /// 画面に出す数と一覧
    ///
    /// サーバーの値（監視の最新）に自分の分の上書きを重ね、ブロックした人の分を除く（1.9・5.1〜5.3）。
    /// ログアウト中は自分の uid が無いので、上書きは使われない（`SoratomoReactionSummary.make` の決まり）。
    /// - Parameters:
    ///   - sky: 投稿（上書きを引く鍵に ID を使う）
    ///   - server: 監視の最新のリアクション（タイムラインは `sky.reactions`、詳細は `observeSky` の値）
    /// - Returns: 画面に出す数と一覧
    func summary(for sky: SoratomoSky, server: SoratomoReactions) -> SoratomoReactionSummary {
        SoratomoReactionSummary.make(
            reactions: server,
            myUid: signedInUid,
            myOverride: overlays[sky.id]?.value,
            blockedUserIds: blockedAuthors.ids
        )
    }

    // MARK: - 操作

    /// メニューで絵文字を選んだ（同じ絵文字なら外す・違えば付ける／選び直す・1.3〜1.5）
    ///
    /// 1. 操作を出してよくない・この投稿の要求を送っている間なら、何もしない（1.6・1.10）
    /// 2. いまの自分の絵文字（上書きを反映した値）と同じなら外す、違えば付ける。選び直しも計測の `action` は `add`
    /// 3. 通信が無ければ送らずに、通信の文言と `soratomo_reaction_failed`（`offline`）で終える（10.1・10.2）
    /// 4. 上書きを `.sending` で入れてから送る（楽観的な表示・1.9）
    /// 5. 成功: 上書きを応答の値の `.confirmed` にし、10 秒後に同じ札のときだけ手放す（2.6）。結果に応じて記録する
    /// 6. 失敗: 上書きをすぐ戻し（10.3）、文言を出す（10.4・10.5）。投稿がもう無ければタイムラインから取り除く（8.8）
    /// - Parameters:
    ///   - kind: 選んだ絵文字
    ///   - sky: 操作した投稿
    ///   - server: 監視の最新のリアクション（いまの自分の絵文字を決めるのに使う）
    ///   - source: 操作した画面（計測の `source`）
    func choose(
        _ kind: SoratomoReactionKind,
        for sky: SoratomoSky,
        server: SoratomoReactions,
        source: SoratomoModerationSource
    ) async {
        // ① 出してよくない操作・重ねた操作は、サービスも記録も知らせも上書きも触らずに捨てる
        guard canReact(to: sky), !isSending(sky) else { return }

        // ② 上書きを反映した「いまの自分の絵文字」と比べる。確定した上書きの 10 秒の間に監視の値がまだ古くても、
        //    画面に見えている状態どおりに「外す」「付ける」を決めるため
        let target: SoratomoReactionKind? = summary(for: sky, server: server).myKind == kind ? nil : kind
        let action: SoratomoReactionFailAction = target == nil ? .remove : .add

        // ③ 送る前の通信の確認。送らないので上書きも入れない（数は監視のキャッシュのまま・10.6）
        guard isOnline() else {
            notice = .failed(.network)
            logEvent(.reactionFailed(action: action, reason: .offline))
            return
        }

        // ④ 1 回の操作ごとに新しい札を作る。前の手放しのタスクの控えは捨てるだけで、タスクは止めない
        //    （前のタスクは待ち終えても、札が違うので何も消さない）
        let skyId = sky.id
        let token = UUID()
        expiryTasks[skyId] = nil
        overlays[skyId] = Overlay(value: Self.override(for: target), phase: .sending, token: token)

        // ⑤ 送る（送り先のグループは、この ViewModel のグループ）
        let change: SoratomoReactionChange
        do throws(SoratomoError) {
            change = try await reactionService.setReaction(groupId: groupId, skyId: skyId, kind: target)
        } catch {
            fail(error, sky: sky, token: token, action: action)
            return
        }

        // ⑥ 成功
        confirm(change, skyId: skyId, token: token, target: target, source: source)
    }

    /// 押した人の一覧を開いた（`soratomo_reactions_viewed`）
    /// - Parameter count: 一覧の人数
    func didOpenReactors(count: Int) {
        logEvent(.reactionsViewed(reactionCount: count))
    }

    // MARK: - Private

    /// 自分の uid（`currentUid()` が nil か空文字ならログアウト中として nil）
    ///
    /// `canReact(to:)` と `summary(for:server:)` が同じ判定を使うよう、ここ 1 か所にまとめる。
    private var signedInUid: String? {
        guard let uid = currentUid(), !uid.isEmpty else { return nil }
        return uid
    }

    /// 送る・返ってきた自分の絵文字（nil は外れている）を、上書きの値にする
    private static func override(for kind: SoratomoReactionKind?) -> SoratomoReactionOverride {
        kind.map { .set($0) } ?? .removed
    }

    /// 成功した後: 上書きを確定し、手放しのタスクを作り、結果を記録する
    ///
    /// - 上書きの値は、送った値でなくサーバーが返した「書いた後の自分のリアクション」にする（1.9）。札は変えない
    /// - `unchanged`（同じ絵文字をもう一度送った・形の違う応答の代わり）も、上書きは確定して手放すが、記録はしない（D3）
    /// - Parameters:
    ///   - change: サーバーの応答
    ///   - skyId: 投稿 ID
    ///   - token: この操作の札
    ///   - target: 送った絵文字（nil は外す）。応答に絵文字が無いときの計測の名前の代わりに使う
    ///   - source: 操作した画面
    private func confirm(
        _ change: SoratomoReactionChange,
        skyId: String,
        token: UUID,
        target: SoratomoReactionKind?,
        source: SoratomoModerationSource
    ) {
        overlays[skyId] = Overlay(value: Self.override(for: change.kind), phase: .confirmed, token: token)
        scheduleRelease(skyId: skyId, token: token)

        switch change.outcome {
        case .added, .replaced:
            // 名前は応答の値を優先し、無ければ送った値（両方無いのは想定外の組み合わせなので記録しない）
            guard let kind = change.kind ?? target else { return }
            logEvent(.reactionAdded(kind: kind, source: source, replaced: change.outcome == .replaced))
        case .removed:
            logEvent(.reactionRemoved(source: source))
        case .unchanged:
            // サーバーは何も変えていないので、付けた・外したとは数えない（D3・承認済み）
            break
        }
    }

    /// 確定した上書きを、決めた時間の後に手放す（同じ札のときだけ・2.6）
    ///
    /// 手放した後は、表示が監視の値（サーバーの状態）に戻る。監視の結果が先に届いていれば、見た目は変わらない。
    /// - `self` は弱く持つ（画面を閉じた後に、待っている間だけ ViewModel を生かし続けない）
    /// - 待つ口と時間は先に取り出しておく（待っている間に `self` が無くなっても、待ち終えて何もせずに終われるように）
    /// - タスクはメインアクターの文脈を受け継ぐので、待ち終えた後の上書きの操作はメインアクターで行われる
    private func scheduleRelease(skyId: String, token: UUID) {
        let wait = sleep
        let lifetime = confirmedLifetimeNanoseconds
        expiryTasks[skyId] = Task { [weak self] in
            await wait(lifetime)
            self?.releaseConfirmed(skyId: skyId, token: token)
        }
    }

    /// 札が同じなら、上書きと手放しのタスクの控えを捨てる
    ///
    /// 札が違うのは、待っている間に同じ投稿で新しい操作が始まったとき。新しい上書きと、その手放しのタスクの控えは残す。
    private func releaseConfirmed(skyId: String, token: UUID) {
        guard overlays[skyId]?.token == token else { return }
        overlays[skyId] = nil
        expiryTasks[skyId] = nil
    }

    /// 失敗した後: 上書きを戻し、文言を出し、記録する
    ///
    /// - 上書きはすぐ消す（10.3）。札が同じときだけ消すのは、手放しと同じく、ほかの操作の上書きを消さないため
    /// - 投稿がもう無い（`.skyGone`）なら、タイムラインから取り除く（8.8）
    /// - 想定外（`.unknown`・`.permissionDenied`）でも、ここでは非致命エラーの記録をしない。
    ///   記録はサービスが失敗を写すときに済ませている（1 回の失敗を 2 件にしない・利用者の決定 2026-10-21）
    /// - Parameters:
    ///   - error: サービスが写した失敗の種類
    ///   - sky: 操作した投稿
    ///   - token: この操作の札
    ///   - action: 計測の `action`（外すなら `remove`、付ける・選び直すなら `add`）
    private func fail(_ error: SoratomoError, sky: SoratomoSky, token: UUID, action: SoratomoReactionFailAction) {
        if overlays[sky.id]?.token == token {
            overlays[sky.id] = nil
        }
        notice = .failed(error)
        if error == .skyGone {
            onSkyGone(sky)
        }
        logEvent(.reactionFailed(action: action, reason: SoratomoReactionFailReason(error)))
    }
}
