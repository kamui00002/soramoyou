//
//  SoratomoRouter.swift
//  Soramoyou
//
//  そらともへの遷移を 1 か所で決めるルーター ⭐️
//  （tasks 12.1・design.md の SoratomoRouter・要件 10.7〜10.12・14.3）
//
//  ホームの入口のボタンと、そらともの通知（新着投稿・リアクション）のタップから、そらともの画面へ行く遷移をここで決める。
//  リアクションの通知は soratomo-reactions 7.4 で足した（行き先は新着投稿と同じ。記録の `type` だけが違う）。
//  既存の画面（GoldenHourNotificationManager・ContentView・MainTabView・HomeView）への差し込みは
//  tasks 14.1 の担当で、このファイルは既存のファイルを一切参照しない。
//  ただし leave-group 8.3 から、抜けたグループの判定だけは `SoratomoDependencies`（そらともの型）を引く
//  （`shared` の組み立てで判定のたびに引く。`SoratomoDependencies` の組み立てはルーターに触れない）。
//

import Foundation

// MARK: - 通知のデータ

/// そらともの通知の種類（FCM の data の `type` で分ける・soratomo-reactions 7.4）
///
/// どちらの通知も行き先は同じ「一覧の上にタイムライン」で、保留・結果待ち・結果の決まり方も同じ
/// （soratomo-reactions 要件 7.1〜7.4・決定事項 P14）。違うのは、計測の `type` の値だけ（要件 15.5）。
enum SoratomoNotificationKind: Equatable, Sendable {
    /// 新着投稿の通知（`type` が `soratomoPost`）
    case post
    /// リアクションの通知（`type` が `soratomoReaction`）
    case reaction

    /// 計測（`soratomo_notification_opened` の `type`）の値
    ///
    /// 新着投稿は 1.15.0 までと同じ `post_created` のまま（既存の集計を割らない・要件 7.5・15.5）。
    var analyticsType: SoratomoNotificationOpenType {
        switch self {
        case .post: .postCreated
        case .reaction: .reaction
        }
    }
}

/// そらともの通知（新着投稿・リアクション）のデータ（FCM の data）
///
/// 送信側（functions/soratomo.js）は、新着投稿の `onSoratomoSkyCreated` が `{ type: "soratomoPost", groupId, postId }` を、
/// リアクションの `notifyReaction` が `{ type: "soratomoReaction", groupId, postId }` を送る。
/// FCM の data の値はすべて文字列で、`postId` にはどちらも投稿（空）の ID が入る（リアクションでは、付けられた投稿）。
struct SoratomoNotificationPayload: Equatable, Sendable {
    /// 新着投稿の通知のデータの `type` の値
    ///
    /// ⚠️ 送信側（functions/soratomo.js）の `type` と同じ文字列にする。
    ///    既存の通知の `type`（like・comment・newPost・follow・recommend）とは重ならない。
    static let typeValue = "soratomoPost"

    /// リアクションの通知のデータの `type` の値（soratomo-reactions 7.4）
    ///
    /// ⚠️ 送信側（functions/soratomo.js の `notifyReaction`）の `type` と同じ文字列にする。
    ///    既存の通知の `type` とも、新着投稿の `soratomoPost` とも重ならない。
    static let reactionTypeValue = "soratomoReaction"

    /// 通知のグループの ID
    let groupId: String
    /// 通知の投稿の ID
    let postId: String
    /// 通知の種類（新着投稿かリアクションか）
    ///
    /// 既定は新着投稿。既定値があるので、`SoratomoNotificationPayload(groupId:postId:)` の書き方はそのまま新着投稿になる。
    var kind: SoratomoNotificationKind = .post

    /// 通知のデータから行き先を読む
    ///
    /// `type` が `soratomoPost` か `soratomoReaction` で、`groupId` と `postId` が使える文字列のときだけ返す。
    /// 返す値の `kind` は `type` から決める（`soratomoPost` は新着投稿、`soratomoReaction` はリアクション）。
    /// 既存の通知（いいね・コメント・新着投稿・フォロー・おすすめ）は `type` が違うので、ここで nil になる。
    /// ゴールデンアワーの通知は `userInfo` を持たない（空）ので、これも nil になる。
    /// - Parameter userInfo: 通知のタップで渡された `content.userInfo`
    /// - Returns: 行き先。そらともの通知でない・データが揃わないときは nil
    static func parse(_ userInfo: [AnyHashable: Any]) -> SoratomoNotificationPayload? {
        guard let typeText = userInfo["type"] as? String, let kind = notificationKind(ofType: typeText),
              let groupId = userInfo["groupId"] as? String, isUsableId(groupId),
              let postId = userInfo["postId"] as? String, isUsableId(postId)
        else {
            return nil
        }
        return SoratomoNotificationPayload(groupId: groupId, postId: postId, kind: kind)
    }

    /// 通知のデータの `type` から、そらともの通知の種類を決める
    ///
    /// 大文字小文字の違いも含め、2 つの値と完全に一致するときだけ種類を返す（そらともの通知でなければ nil）。
    /// 名前をプロパティの `kind` と分けているのは、`parse` の中の `let kind = …` と名前の解決が重ならないようにするため。
    /// - Parameter typeText: 通知のデータの `type` の値
    /// - Returns: 通知の種類。そらともの通知の `type` でなければ nil
    private static func notificationKind(ofType typeText: String) -> SoratomoNotificationKind? {
        switch typeText {
        case typeValue: .post
        case reactionTypeValue: .reaction
        default: nil
        }
    }

    /// ID として使える文字列か（空でなく、`/` を含まない）
    ///
    /// Firestore のドキュメント ID には `/` を使えない。`/` を含む値でドキュメントを指すと
    /// Firestore の SDK が例外で止まるので、通知のデータの段階で弾く。
    private static func isUsableId(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/")
    }
}

// MARK: - 行き先・ログイン状態

/// そらともの画面の中の行き先（`NavigationStack` のパスの要素）
///
/// 通知の行き先は「一覧の上にタイムライン」の形にする。一覧はパスの根（パスが空のとき）なので、
/// 通知からは `[.timeline(groupId:)]` を入れる。
enum SoratomoDestination: Hashable {
    /// グループのタイムライン
    case timeline(groupId: String)
    /// グループの招待
    case invite(groupId: String)
    /// グループのメンバー一覧
    case members(groupId: String)
    /// 投稿の詳細
    case skyDetail(groupId: String, skyId: String)
}

/// ログイン状態（ContentView が確定してルーターへ渡す）
enum SoratomoSession: Equatable {
    case signedIn
    case signedOut
}

// MARK: - ルーター

/// そらともへの遷移を 1 か所で決めるルーター
///
/// - 通知のタップで受け取った行き先は、表示できると確認できるまで「保留」として持つ（`pending`）
/// - 表示できるかは、ログイン状態・そらともを使えるかの判定・ほかの全画面の表示（What's New など）の有無で決まる。
///   これらが分かった時点で、呼び出し側が `resolvePending` を呼ぶ
/// - 未ログインなら破棄して `signed_out`、そらともを使えない（匿名）なら破棄して `flag_off` を記録する
///   （どちらもそらともの画面は出さず、通常どおりアプリを開く）
/// - 表示できるときは、一覧の上にタイムラインを開く。この時点では、まだ記録しない
///   （タイムラインがグループを読めるか分からないので、結果は決まっていない。「結果待ち」として覚える）
/// - 結果待ちのタップの結果は、次のどれかで 1 回だけ決まって記録する（どの道でも、1 回のタップで記録は 1 件）
///   - `reportAccessible`: タイムラインがグループを読めた → `opened`
///     ⚠️ 13.5 のタイムラインが、グループを最初に読めたときに呼ぶこと（呼ばれないと `opened` は閉じるまで記録されない）
///   - `reportNotAccessible`: タイムラインがグループを読めなかった → 一覧へ戻して一時表示を出し、`not_member`
///   - 読めない知らせが来る前に、そらともの画面を閉じた・入口から開き直した・次の通知で開き直した → `opened`
///     （通知からグループの画面までは開けていて、読めない知らせは来ていないため）
///   - サインアウトの破棄（`clearOnSignOut`）→ 記録しない
/// - 記録の `type` は、どの結果（`opened`・`not_member`・`flag_off`・`signed_out`）でも、そのタップの通知の種類にする
///   （新着投稿は `post_created`・リアクションは `reaction`。行き先と結果の決まり方は、どちらの種類も同じ・soratomo-reactions 7.4）
///
/// アプリ全体で 1 つの `shared` を使う。単体テストでは記録の関数を差し替えて作る。
@MainActor
final class SoratomoRouter: ObservableObject {
    /// アプリ全体で使うルーター
    ///
    /// ⚠️ 抜けたグループの判定（`isLeftGroup`）は、`SoratomoDependencies.live` の組み立てで代入せず、ここで
    ///    判定のたびに `live` を引く。`live` は遅延で初期化され、最初に触るのはそらともの全画面のカバーの中身。
    ///    通知で冷えた起動をすると `resolvePending` が `live` より先に走るので、`live` の中で代入すると
    ///    判定が間に合わない（引いた時点で `live` が作られるここなら間に合う）。
    ///    サービスの init がこの `shared` に触れると初期化が輪になるため、触れないこと。
    static let shared = SoratomoRouter(isLeftGroup: { SoratomoDependencies.live.isLeftGroup($0) })

    /// そらともの画面（全画面のカバー）を出しているか
    ///
    /// 画面側のカバーの閉じる操作は、この値を直接 false にすることがある（`dismiss()` を通らない）。
    /// どちらの閉じ方でも結果待ちを確定するため、false になったときにも確定する。
    @Published var isPresented = false {
        didSet {
            if !isPresented {
                settleAwaitingAsOpened()
            }
        }
    }

    /// そらともの画面の中のパス。空なら一覧、`[.timeline(groupId:)]` なら一覧の上にタイムライン
    @Published var path: [SoratomoDestination] = []

    /// 「グループを開けませんでした」などの一時表示の文言。表示し終えたら画面側が nil に戻す
    @Published var notice: String?

    /// 表示できると確認できるまで持っている通知の行き先
    @Published private(set) var pending: SoratomoNotificationPayload?

    /// 計測の記録の関数（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void

    /// 結果待ちのグループ ID と通知の種類の組（通知から開いたタイムラインで、まだ結果が決まっていないもの）
    ///
    /// 通知のタップ 1 回につき、結果（`opened` か `not_member`）を 1 回だけ記録するための覚え。
    /// 記録したら nil に戻す。nil の間は、`reportAccessible` と `reportNotAccessible` は記録しない。
    /// 入口の一覧から開いたグループの読み込みが、通知の計測に混ざらないのもこのため。
    /// 種類も一緒に覚えるのは、結果が決まるのがタップより後（読めた・読めなかった・閉じた）で、
    /// そのときには保留（`pending`）がもう空になっているため。記録の `type` は、ここに覚えた種類から決める（soratomo-reactions 7.4）。
    private var awaiting: (groupId: String, kind: SoratomoNotificationKind)?

    /// この端末の、いまの利用者が抜けたグループか（leave-group 8.3・既定は常に偽）
    ///
    /// 通知のグループがここで真なら、タイムラインを開かずに「開けませんでした」の扱いにする。
    /// 本物は `SoratomoDependencies.live.isLeftGroup`（`shared` の組み立てで渡す）。
    private let isLeftGroup: @MainActor (String) -> Bool

    /// - Parameters:
    ///   - logEvent: 計測の記録の関数。既定は本番の `SoratomoAnalytics.log`
    ///   - isLeftGroup: 抜けたグループかの判定。既定は常に偽（記録に無いグループは今のまま開く）
    init(
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log,
        isLeftGroup: @escaping @MainActor (String) -> Bool = { _ in false }
    ) {
        self.logEvent = logEvent
        self.isLeftGroup = isLeftGroup
    }

    // MARK: 入口・閉じる

    /// ホームの入口のボタンから、そらともの画面（グループ一覧）を開く
    ///
    /// 通知のタイムラインの結果が決まる前に開き直したときは、前の通知の分を `opened` として確定する
    /// （パスを一覧に戻すので、そのタイムラインはもう見られない）。
    func openFromEntry() {
        settleAwaitingAsOpened()
        notice = nil
        path = []
        isPresented = true
    }

    /// そらともの画面を閉じる
    ///
    /// 保留の行き先（`pending`）は変えない。閉じる操作は、まだ表示できていない通知の行き先を消さない。
    /// 通知のタイムラインの結果が決まる前に閉じたときは、`opened` を 1 回記録する
    /// （グループの画面までは開けていて、読めない知らせは来ていないため）。
    func dismiss() {
        settleAwaitingAsOpened()
        isPresented = false
        path = []
        notice = nil
    }

    /// サインアウト時に、保留の行き先・結果待ち・そらともの画面の状態をすべて破棄する
    ///
    /// 計測は記録しない。結果待ちも、記録せずに消す（サインアウトの破棄は、1 回のタップの記録が 0 件になる唯一の道）。
    /// `signed_out` を記録するのは、未ログインの状態で `resolvePending` を呼んだときだけ。
    func clearOnSignOut() {
        pending = nil
        awaiting = nil
        dismiss()
    }

    // MARK: 通知のタップ

    /// 通知のタップで渡されたデータを受け取る
    ///
    /// そらともの通知（`type` が `soratomoPost` か `soratomoReaction` で `groupId`・`postId` が揃うもの）だけを保留にする。
    /// 保留には通知の種類（`kind`）も入り、後で決まる結果の記録の `type` に使う。
    /// 既存の通知とゴールデンアワーは何もしない（保留も、すでにある保留も変えない）。
    /// ここでは表示も記録もしない。表示できるかが分かった時点で `resolvePending` を呼ぶこと。
    /// すでに保留があるときは、新しいタップの行き先に置き換える。
    /// - Parameter userInfo: 通知のタップで渡された `content.userInfo`
    func receive(userInfo: [AnyHashable: Any]) {
        guard let payload = SoratomoNotificationPayload.parse(userInfo) else { return }
        pending = payload
    }

    /// 保留の行き先を、いまの状況で開くか・破棄するか・待つかを決める
    ///
    /// ログイン状態・そらともを使えるかの判定・ほかのモーダルの有無が分かった時点で呼ぶ。保留が無ければ何もしない。
    /// 判定は上から順に行う。
    /// 1. 未ログイン: 破棄して `signed_out` を記録する（判定の状態に関わらない。サインアウト中は判定も
    ///    「無効（未ログイン）」になるので、判定を先に見ると `signed_out` が `flag_off` に化ける）
    /// 2. 判定前（`unknown`）: 保留のまま待つ（判定が済む前に `flag_off` を記録しない）
    /// 3. そらともを使えない（匿名）: 破棄して `flag_off` を記録する（値の名前は 1.14.x までの機能フラグの名残。
    ///    1.14.x から届く記録と同じ集計で数えるため変えない・soratomo-public-launch 6.2）
    /// 4. 使える（登録済みでログイン）: `canPresent` が false の間は保留のまま待つ。true なら一覧の上にタイムラインを開く。
    ///    この時点では記録せず、結果待ちとして覚える（結果は `reportAccessible` / `reportNotAccessible` などで決まる）。
    ///    前の通知の結果待ちが残っていれば、先に `opened` として確定してから置き換える
    ///
    /// `signed_out` と `flag_off` は、保留を空にするのと同時に 1 回だけ記録する（結果がここで確定するため）。
    /// 続けて呼んでも、保留が無いので記録は増えない。記録の `type` は、どの道でも保留していた通知の種類にする。
    /// - Parameters:
    ///   - session: ログイン状態
    ///   - gate: そらともを使えるかの判定の状態
    ///   - canPresent: そらともの画面を出してよいか。What's New などほかの全画面の表示中は false
    func resolvePending(session: SoratomoSession, gate: SoratomoFeatureGate.State, canPresent: Bool) {
        guard let payload = pending else { return }

        if session == .signedOut {
            discardPending(payload, as: .signedOut)
            return
        }

        switch gate {
        case .unknown:
            // 判定前は、保留のまま待つ（判定が済む前に flag_off を記録しない）。判定が決まれば、もう一度ここが呼ばれる
            return
        case .disabled:
            discardPending(payload, as: .flagOff)
        case .enabled:
            guard canPresent else { return }
            // 抜けたグループの通知は、タイムラインを開かない（leave-group 8.3・要件 5.7）。
            // 結果待ちにもしない（開いていないので、ここで結果が決まる）。結果待ちが残っていれば先に確定する。
            // 計測は `not_member` を 1 回（`type` はこのタップの通知の種類）。保留を空にするので、続けて呼んでも増えない
            if isLeftGroup(payload.groupId) {
                settleAwaitingAsOpened()
                pending = nil
                path = []
                notice = SoratomoError.notMember.userMessage
                isPresented = true
                logEvent(.notificationOpened(.notMember, type: payload.kind.analyticsType))
                return
            }
            // 前の通知のタイムラインの結果が決まっていなければ、先に opened として確定する
            // （下で結果待ちを新しいグループに置き換えるので、ここで確定しないと前の分の記録が 0 件になる）
            settleAwaitingAsOpened()
            pending = nil
            notice = nil
            // 「一覧の上にタイムライン」の形（一覧はパスの根）。すでにそらともの画面を開いていても、
            // 通知のグループのタイムラインへ置き換える
            path = [.timeline(groupId: payload.groupId)]
            // まだ記録しない。タイムラインがグループを読めるか分からないので、結果待ちとして覚える
            // （結果が決まったときの記録の `type` に使うので、通知の種類も一緒に覚える）
            awaiting = (groupId: payload.groupId, kind: payload.kind)
            isPresented = true
        }
    }

    /// タイムラインがグループを読めたときに呼ぶ
    ///
    /// ⚠️ 13.5 のタイムラインが、グループを最初に読めたときに呼ぶこと。
    ///
    /// 結果待ちのグループと一致するときだけ、`opened` を 1 回記録して結果待ちを消す（`type` は結果待ちに覚えた通知の種類）。
    /// 一致しないとき（入口の一覧から開いた・すでに結果が決まっている・別のグループ）は何もしない。
    /// - Parameter groupId: 読めたグループの ID
    func reportAccessible(groupId: String) {
        guard let awaiting, awaiting.groupId == groupId else { return }

        self.awaiting = nil
        logEvent(.notificationOpened(.opened, type: awaiting.kind.analyticsType))
    }

    /// タイムラインがグループを読めなかったときに呼ぶ（一覧へ戻し、一時表示を出す）
    ///
    /// 結果待ちのグループと一致するときだけ、通知の結果として `not_member` を 1 回記録して結果待ちを消す
    /// （`type` は結果待ちに覚えた通知の種類）。
    /// 結果待ちを消すので、そのタップは、続けて閉じても `opened` が増えない（1 回のタップで記録は 1 件）。
    /// 一致しないとき（入口の一覧から開いた・すでに結果が決まっている・別のグループ）は記録しない。
    ///
    /// 一覧へ戻す動きと一時表示は、いまのパスにそのグループのタイムラインがあるときだけ行う。
    /// パスに無いとき（すでに別の画面へ移った後の遅い知らせ）は、画面を変えない。
    /// - Parameter groupId: 読めなかったグループの ID
    func reportNotAccessible(groupId: String) {
        if path.contains(.timeline(groupId: groupId)) {
            path = []
            notice = SoratomoError.notMember.userMessage
        }

        if let awaiting, awaiting.groupId == groupId {
            self.awaiting = nil
            logEvent(.notificationOpened(.notMember, type: awaiting.kind.analyticsType))
        }
    }

    // MARK: 抜けた後

    /// グループを抜けた後に、そのグループの画面を閉じて一時表示を出す（leave-group 8.3）
    ///
    /// パスに、そのグループの画面（タイムライン・招待・メンバー・投稿詳細）があるときだけ、
    /// 一覧へ戻して（`path = []`）`notice` を出す。別のグループの画面だけなら何も変えない。
    /// 計測はしない（`group_left` は抜けるの ViewModel が記録する）。
    /// - Parameters:
    ///   - groupId: 抜けたグループの ID
    ///   - notice: 一時表示の文言（抜けたグループの名前を含む。出すのは画面と VoiceOver の読み上げだけで、
    ///     計測・ログには渡さない。`SoratomoError.notMember.userMessage` とは違う文）
    func finishLeaving(groupId: String, notice: String) {
        guard path.contains(where: { $0.belongsTo(groupId: groupId) }) else { return }

        path = []
        self.notice = notice
    }

    // MARK: - Private

    /// 結果待ちが残っていれば、`opened` を 1 回記録して結果待ちを消す（`type` は結果待ちに覚えた通知の種類）
    ///
    /// 結果待ちが無ければ何もしない（続けて呼んでも記録は増えない）。
    /// 読めない知らせが来ないまま画面を閉じた・開き直した・次の通知で置き換えたときに使う。
    /// 次の通知で置き換えるときも、記録するのは前のタップの種類（新しいタップの種類ではない）。
    private func settleAwaitingAsOpened() {
        guard let awaiting else { return }

        self.awaiting = nil
        logEvent(.notificationOpened(.opened, type: awaiting.kind.analyticsType))
    }

    /// 保留の行き先を破棄して、結果を記録する（そらともの画面は出さず、通常どおりアプリを開く）
    /// - Parameters:
    ///   - payload: 破棄する保留の行き先（記録の `type` に、その通知の種類を使う）
    ///   - result: 記録する結果（`signed_out` か `flag_off`）
    private func discardPending(_ payload: SoratomoNotificationPayload, as result: SoratomoNotificationOpenResult) {
        pending = nil
        logEvent(.notificationOpened(result, type: payload.kind.analyticsType))
    }
}

// MARK: - 行き先のグループ

private extension SoratomoDestination {
    /// この行き先が、指定のグループの画面か（どの行き先もグループ ID を持つ）
    func belongsTo(groupId target: String) -> Bool {
        switch self {
        case let .timeline(groupId), let .invite(groupId), let .members(groupId):
            groupId == target
        case let .skyDetail(groupId, _):
            groupId == target
        }
    }
}
