//
//  SoratomoRouter.swift
//  Soramoyou
//
//  そらともへの遷移を 1 か所で決めるルーター ⭐️
//  （tasks 12.1・design.md の SoratomoRouter・要件 10.7〜10.12・14.3）
//
//  ホームの入口のボタンと、そらともの新着通知のタップから、そらともの画面へ行く遷移をここで決める。
//  既存の画面（GoldenHourNotificationManager・ContentView・MainTabView・HomeView）への差し込みは
//  tasks 14.1 の担当で、このファイルは既存のファイルを一切参照しない。
//

import Foundation

// MARK: - 通知のデータ

/// そらともの新着通知のデータ（FCM の data）
///
/// 送信側（functions/soratomo.js の `onSoratomoSkyCreated`）が `{ type: "soratomoPost", groupId, postId }` を送る。
/// FCM の data の値はすべて文字列で、`postId` には投稿（空）の ID が入る。
struct SoratomoNotificationPayload: Equatable, Sendable {
    /// 通知のデータの `type` の値
    ///
    /// ⚠️ 送信側（functions/soratomo.js）の `type` と同じ文字列にする。
    ///    既存の通知の `type`（like・comment・newPost・follow・recommend）とは重ならない。
    static let typeValue = "soratomoPost"

    /// 通知のグループの ID
    let groupId: String
    /// 通知の投稿の ID
    let postId: String

    /// 通知のデータから行き先を読む
    ///
    /// `type` が `soratomoPost` で、`groupId` と `postId` が使える文字列のときだけ返す。
    /// 既存の通知（いいね・コメント・新着投稿・フォロー・おすすめ）は `type` が違うので、ここで nil になる。
    /// ゴールデンアワーの通知は `userInfo` を持たない（空）ので、これも nil になる。
    /// - Parameter userInfo: 通知のタップで渡された `content.userInfo`
    /// - Returns: 行き先。そらともの通知でない・データが揃わないときは nil
    static func parse(_ userInfo: [AnyHashable: Any]) -> SoratomoNotificationPayload? {
        guard let typeText = userInfo["type"] as? String, typeText == typeValue,
              let groupId = userInfo["groupId"] as? String, isUsableId(groupId),
              let postId = userInfo["postId"] as? String, isUsableId(postId)
        else {
            return nil
        }
        return SoratomoNotificationPayload(groupId: groupId, postId: postId)
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
/// - 表示できるかは、ログイン状態・機能フラグ・ほかの全画面の表示（What's New など）の有無で決まる。
///   これらが分かった時点で、呼び出し側が `resolvePending` を呼ぶ
/// - 未ログインなら破棄して `signed_out`、機能フラグが無効なら破棄して `flag_off` を記録する
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
///
/// アプリ全体で 1 つの `shared` を使う。単体テストでは記録の関数を差し替えて作る。
@MainActor
final class SoratomoRouter: ObservableObject {
    /// アプリ全体で使うルーター
    static let shared = SoratomoRouter()

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

    /// 結果待ちのグループ ID（通知から開いたタイムラインで、まだ結果が決まっていないもの）
    ///
    /// 通知のタップ 1 回につき、結果（`opened` か `not_member`）を 1 回だけ記録するための覚え。
    /// 記録したら nil に戻す。nil の間は、`reportAccessible` と `reportNotAccessible` は記録しない。
    /// 入口の一覧から開いたグループの読み込みが、通知の計測に混ざらないのもこのため。
    private var awaitingGroupId: String?

    /// - Parameter logEvent: 計測の記録の関数。既定は本番の `SoratomoAnalytics.log`
    init(logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log) {
        self.logEvent = logEvent
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
        awaitingGroupId = nil
        dismiss()
    }

    // MARK: 通知のタップ

    /// 通知のタップで渡されたデータを受け取る
    ///
    /// そらともの通知（`type` が `soratomoPost` で `groupId`・`postId` が揃うもの）だけを保留にする。
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
    /// ログイン状態・機能フラグ・ほかのモーダルの有無が分かった時点で呼ぶ。保留が無ければ何もしない。
    /// 判定は上から順に行う。
    /// 1. 未ログイン: 破棄して `signed_out` を記録する（フラグの状態に関わらない。サインアウト中はフラグも
    ///    「無効（未ログイン）」になるので、フラグを先に見ると `signed_out` が `flag_off` に化ける）
    /// 2. フラグが判定前（`unknown`）: 保留のまま待つ（判定が済む前に `flag_off` を記録しない）
    /// 3. フラグが無効: 破棄して `flag_off` を記録する
    /// 4. フラグが有効: `canPresent` が false の間は保留のまま待つ。true なら一覧の上にタイムラインを開く。
    ///    この時点では記録せず、結果待ちとして覚える（結果は `reportAccessible` / `reportNotAccessible` などで決まる）。
    ///    前の通知の結果待ちが残っていれば、先に `opened` として確定してから置き換える
    ///
    /// `signed_out` と `flag_off` は、保留を空にするのと同時に 1 回だけ記録する（結果がここで確定するため）。
    /// 続けて呼んでも、保留が無いので記録は増えない。
    /// - Parameters:
    ///   - session: ログイン状態
    ///   - gate: 機能フラグの判定の状態
    ///   - canPresent: そらともの画面を出してよいか。What's New などほかの全画面の表示中は false
    func resolvePending(session: SoratomoSession, gate: SoratomoFeatureGate.State, canPresent: Bool) {
        guard let payload = pending else { return }

        if session == .signedOut {
            discardPending(as: .signedOut)
            return
        }

        switch gate {
        case .unknown, .disabled(.tokenUnavailable):
            // 判定前・トークンを一時的に取れない間は、保留のまま待つ。取れなかったのは通信などのせいで、
            // フラグが無効と決まったわけではない（flag_off と記録すると計測の意味がずれる。レビューで直した）。
            // 前面に戻ったときにゲートが判定し直し、結果が変わればもう一度ここが呼ばれる
            return
        case .disabled:
            discardPending(as: .flagOff)
        case .enabled:
            guard canPresent else { return }
            // 前の通知のタイムラインの結果が決まっていなければ、先に opened として確定する
            // （下で結果待ちを新しいグループに置き換えるので、ここで確定しないと前の分の記録が 0 件になる）
            settleAwaitingAsOpened()
            pending = nil
            notice = nil
            // 「一覧の上にタイムライン」の形（一覧はパスの根）。すでにそらともの画面を開いていても、
            // 通知のグループのタイムラインへ置き換える
            path = [.timeline(groupId: payload.groupId)]
            // まだ記録しない。タイムラインがグループを読めるか分からないので、結果待ちとして覚える
            awaitingGroupId = payload.groupId
            isPresented = true
        }
    }

    /// タイムラインがグループを読めたときに呼ぶ
    ///
    /// ⚠️ 13.5 のタイムラインが、グループを最初に読めたときに呼ぶこと。
    ///
    /// 結果待ちのグループと一致するときだけ、`opened` を 1 回記録して結果待ちを消す。
    /// 一致しないとき（入口の一覧から開いた・すでに結果が決まっている・別のグループ）は何もしない。
    /// - Parameter groupId: 読めたグループの ID
    func reportAccessible(groupId: String) {
        guard awaitingGroupId == groupId else { return }

        awaitingGroupId = nil
        logEvent(.notificationOpened(.opened))
    }

    /// タイムラインがグループを読めなかったときに呼ぶ（一覧へ戻し、一時表示を出す）
    ///
    /// 結果待ちのグループと一致するときだけ、通知の結果として `not_member` を 1 回記録して結果待ちを消す。
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

        if awaitingGroupId == groupId {
            awaitingGroupId = nil
            logEvent(.notificationOpened(.notMember))
        }
    }

    // MARK: - Private

    /// 結果待ちが残っていれば、`opened` を 1 回記録して結果待ちを消す
    ///
    /// 結果待ちが無ければ何もしない（続けて呼んでも記録は増えない）。
    /// 読めない知らせが来ないまま画面を閉じた・開き直した・次の通知で置き換えたときに使う。
    private func settleAwaitingAsOpened() {
        guard awaitingGroupId != nil else { return }

        awaitingGroupId = nil
        logEvent(.notificationOpened(.opened))
    }

    /// 保留の行き先を破棄して、結果を記録する（そらともの画面は出さず、通常どおりアプリを開く）
    private func discardPending(as result: SoratomoNotificationOpenResult) {
        pending = nil
        logEvent(.notificationOpened(result))
    }
}
