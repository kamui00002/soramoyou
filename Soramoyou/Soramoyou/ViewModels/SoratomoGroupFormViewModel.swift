//
//  SoratomoGroupFormViewModel.swift
//  Soramoyou
//
//  そらともの「グループを作る」「招待コードで参加」のシートの ViewModel ⭐️
//  （tasks 13.2・13.3・design.md の SoratomoGroupFormViewModel・SoratomoDisplayNameStep・
//    要件 2・4・10.1・10.5・12.2・12.5・14.3・15.4・18）
//
//  シートの中の流れ:
//    1. 表示名が要るかを確かめる（`needsDisplayName`）
//    2. 要るなら表示名の入力（13.2）→ 保存に成功したら 3 へ
//    3. グループ名か招待コードの入力（13.3）→ 作成か参加に成功したら 4 へ
//    4. 通知の事前説明の判定（`primer.decide()`・12.2）→ 事前説明か設定の案内があれば出し、閉じたら完了。無ければすぐ完了
//  完了したら、進む先のパスを `onCompleted` で返す（一覧がルーターのパスに入れて、シートを閉じる）。
//

import Foundation

/// そらともの「グループを作る」「招待コードで参加」のシートの ViewModel
///
/// - 二重の確定を防ぐのは `phase`。確定の処理を始めるとき、最初の `await` より前に `.processing` にする。
///   ボタンを 2 回押すと `Task` が 2 つ作られるが、2 つ目は `phase` を見て何もせずに戻る（要件 2.7・4.10）。
/// - 失敗しても入力（表示名・グループ名・招待コード）は消さない（要件 2.6・4.9・18.5）。
/// - 画面の文言は固定の文言（`SoratomoError.userMessage`・`SoratomoFailedAction.saveDisplayName.userMessage`）だけを出す。
/// - 入力の検査以外の失敗は `SoratomoError.record` で非致命エラーとして記録する（要件 15.4）。
@MainActor
final class SoratomoGroupFormViewModel: ObservableObject {
    // MARK: - 型

    /// シートのいまの段
    enum Step: Equatable {
        /// 表示名が要るかを確かめている
        case checking
        /// 表示名が要るかを確かめられなかった（先へは進ませない。`message` は固定の文言）
        case checkFailed(message: String)
        /// 表示名の入力（13.2）
        case displayName
        /// グループ名か招待コードの入力（13.3）
        case form
        /// 通知の事前説明か、設定の案内を出している（`.none` は入らない）
        case primer(SoratomoPrimerDecision)
    }

    /// 確定の処理の状態（二重の確定を防ぐ）
    enum Phase: Equatable {
        /// 確定を受け付ける
        case idle
        /// 保存・作成・参加・事前説明の判定をしている（確定を受け付けない）
        case processing
        /// 作成か参加に成功した（このシートでは、もう確定を受け付けない）
        case completed
    }

    // MARK: - Properties

    /// 作成か参加か
    let mode: SoratomoGroupFormMode

    /// シートのいまの段
    @Published private(set) var step: Step = .checking
    /// 確定の処理の状態
    @Published private(set) var phase: Phase = .idle
    /// いまの段で出す失敗の文言（固定の文言。無ければ nil）
    @Published private(set) var errorMessage: String?

    /// 表示名の入力（失敗しても消さない）
    @Published var displayNameInput = ""
    /// グループ名の入力（作成のとき。失敗しても消さない）
    @Published var groupNameInput = ""
    /// 招待コードの入力（参加のとき。失敗しても消さない）
    @Published var inviteCodeInput = ""

    /// グループのサービス
    private let groupService: any SoratomoGroupServiceProtocol
    /// 表示名のサービス
    private let profileService: any SoratomoProfileServiceProtocol
    /// 通知の事前説明の判定
    private let primer: any SoratomoNotificationPrimerProtocol
    /// いま通信できる状態か（確定の前の確認に使う）
    private let isOnline: () -> Bool
    /// いまログインしている利用者の uid（未ログインなら nil）
    private let currentUid: () -> String?
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void
    /// 成功したときに、進む先のパスを渡す
    private let onCompleted: ([SoratomoDestination]) -> Void

    /// 作成で使っている要求 ID と、そのときのグループ名（前後の空白を除いたもの）
    ///
    /// 同じグループ名で確定し直す間は、同じ要求 ID を送る。タイムアウトなどで結果が分からないまま
    /// 確定し直しても、サーバーは同じ要求 ID を 1 回の作成として扱うので、2 つ目のグループができない（要件 2.7）。
    /// グループ名を変えて確定したら、新しい要求 ID にする。
    /// ⚠️ 比べるのは入力のままの文字列ではなく、前後の空白を除いた名前。サーバーに送る名前が同じなら、
    ///    途中で書き換えて元に戻した場合も同じ要求 ID になる（2 つ目のグループを作らない側に倒す）。
    private var pendingCreate: (name: String, requestId: UUID)?

    /// 作成か参加に成功した後の、進む先のパス（事前説明を閉じたときに渡す）
    private var completedDestinations: [SoratomoDestination]?

    // MARK: - Init

    /// - Parameters:
    ///   - mode: 作成か参加か
    ///   - groupService: グループのサービス
    ///   - profileService: 表示名のサービス
    ///   - primer: 通知の事前説明の判定
    ///   - isOnline: いま通信できる状態かを返す
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    ///   - onCompleted: 成功したときに、進む先のパスを受け取る
    init(
        mode: SoratomoGroupFormMode,
        groupService: any SoratomoGroupServiceProtocol,
        profileService: any SoratomoProfileServiceProtocol,
        primer: any SoratomoNotificationPrimerProtocol,
        isOnline: @escaping () -> Bool,
        currentUid: @escaping () -> String?,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log,
        onCompleted: @escaping ([SoratomoDestination]) -> Void
    ) {
        self.mode = mode
        self.groupService = groupService
        self.profileService = profileService
        self.primer = primer
        self.isOnline = isOnline
        self.currentUid = currentUid
        self.logEvent = logEvent
        self.onCompleted = onCompleted
    }

    // MARK: - 1. 表示名が要るか

    /// 表示名の入力が要るかを確かめ、最初の段を決める（シートを開いたとき・やり直しのときに呼ぶ）
    ///
    /// - 要る（未設定か空白だけ）→ 表示名の入力（要件 18.1）
    /// - 要らない（設定済み）→ グループ名か招待コードの入力（要件 18.6）
    /// - 確かめられなかった（どのエラーでも）→ 先へ進ませず、固定の文言とやり直しの操作を出す
    func start() async {
        // 確かめている途中と、確かめた後（入力中・処理中）は、もう一度確かめない
        switch step {
        case .checking, .checkFailed:
            break
        case .displayName, .form, .primer:
            return
        }
        guard phase == .idle else { return }

        phase = .processing
        step = .checking
        defer { phase = .idle }

        guard let uid = currentUid() else {
            // 未ログイン（サインアウト直後など）。サインアウト時の画面の破棄は 14.1 が行うので、ここでは止めるだけ
            step = .checkFailed(message: SoratomoError.unknown.userMessage)
            return
        }

        do {
            let needs = try await profileService.needsDisplayName(uid: uid)
            step = needs ? .displayName : .form
        } catch {
            // ⚠️ 権限の拒否は `.notMember` に写るが、その文言（「グループを開けませんでした」）はこの場面に合わない。
            //    通信のときだけ通信の文言、それ以外は「うまくいきませんでした」の文言にする
            SoratomoError.record(error, context: "soratomo.needsDisplayName")
            let message = error == .network ? SoratomoError.network.userMessage : SoratomoError.unknown.userMessage
            step = .checkFailed(message: message)
        }
    }

    // MARK: - 2. 表示名の保存（13.2）

    /// 表示名を確定する（表示名の入力の段で呼ぶ）
    ///
    /// - 前後の空白を除いて 1〜20 文字でなければ、保存せずに文字数の条件を出す（要件 18.2・18.3）
    /// - 通信できなければ、保存せずに「保存できませんでした」を出す（要件 18.5）
    /// - 保存に成功したら、グループ名か招待コードの入力へ進む（要件 18.4）
    /// - 保存に失敗したら、先へ進まず「保存できませんでした」を出し、入力を残す（要件 18.5）
    func saveDisplayName() async {
        guard step == .displayName, phase == .idle else { return }

        let trigger: SoratomoDisplayNameTrigger = mode == .create ? .create : .join

        // 文字数の検査（入力の検査なので、非致命エラーには記録しない）
        let name: SoratomoDisplayName
        switch SoratomoTextRules.validateDisplayName(displayNameInput) {
        case let .success(validated):
            name = validated
        case .failure:
            errorMessage = SoratomoError.displayNameInvalid.userMessage
            logEvent(.displayNameFailed(.invalidLength))
            return
        }

        // 通信の確認（明らかに通信できないときは、送る前に止める）
        guard isOnline() else {
            errorMessage = SoratomoFailedAction.saveDisplayName.userMessage
            logEvent(.displayNameFailed(.network))
            return
        }

        guard let uid = currentUid() else {
            errorMessage = SoratomoFailedAction.saveDisplayName.userMessage
            logEvent(.displayNameFailed(.unknown))
            return
        }

        phase = .processing
        defer { phase = .idle }

        do {
            try await profileService.saveDisplayName(uid: uid, name: name)
            errorMessage = nil
            logEvent(.displayNameSaved(trigger: trigger))
            step = .form
        } catch {
            SoratomoError.record(error, context: "soratomo.saveDisplayName")
            // 種類（通信・その他）に関わらず、操作の文言を出す。計測の理由は種類から写す
            errorMessage = SoratomoFailedAction.saveDisplayName.userMessage
            logEvent(.displayNameFailed(SoratomoDisplayNameFailReason(error)))
        }
    }

    // MARK: - 3. 作成か参加（13.3）

    /// グループ名か招待コードを確定する（入力の段で呼ぶ）
    ///
    /// 作成・参加のどちらでも、成功したら事前説明の判定へ進む。失敗したら固定の文言を出し、入力を残す。
    func submit() async {
        guard step == .form, phase == .idle else { return }

        switch mode {
        case .create:
            await submitCreate()
        case .join:
            await submitJoin()
        }
    }

    /// グループを作る
    private func submitCreate() async {
        // グループ名の検査（前後の空白を除いて 1〜30 文字・要件 2.2・2.3）
        let name: String
        switch SoratomoTextRules.validateGroupName(groupNameInput) {
        case let .success(validated):
            name = validated
        case .failure:
            errorMessage = SoratomoError.invalidName.userMessage
            logEvent(.createFailed(.invalidName))
            return
        }

        // 通信の確認（通信できなければ作らない・要件 2.6・12.2）
        guard isOnline() else {
            errorMessage = SoratomoError.network.userMessage
            logEvent(.createFailed(.network))
            return
        }

        // 要求 ID（同じ名前なら前と同じものを使う）
        let requestId: UUID
        if let pending = pendingCreate, pending.name == name {
            requestId = pending.requestId
        } else {
            requestId = UUID()
            pendingCreate = (name, requestId)
        }

        // ⚠️ 最初の await より前に処理中にする（二重の確定を防ぐ・要件 2.7）
        phase = .processing

        do {
            let summary = try await groupService.createGroup(name: name, requestId: requestId)
            errorMessage = nil
            logEvent(.groupCreated)
            // 作成の後は招待の共有画面へ（招待の画面から戻るとタイムライン・要件 2.1）
            await finish(destinations: [.timeline(groupId: summary.groupId), .invite(groupId: summary.groupId)])
        } catch {
            SoratomoError.record(error, context: "soratomo.createGroup")
            errorMessage = error.userMessage
            logEvent(.createFailed(SoratomoCreateFailReason(error)))
            phase = .idle
        }
    }

    /// 招待コードで参加する
    private func submitJoin() async {
        // 形の検査（正規化して 8 文字にならなければ、サーバーへ問い合わせない・要件 4.3）
        guard let code = SoratomoInviteCode.parse(userInput: inviteCodeInput) else {
            errorMessage = SoratomoError.invalidFormat.userMessage
            logEvent(.joinFailed(.invalidFormat))
            return
        }

        // 通信の確認（通信できなければ参加しない・要件 4.9・12.2）
        guard isOnline() else {
            errorMessage = SoratomoError.network.userMessage
            logEvent(.joinFailed(.network))
            return
        }

        // ⚠️ 最初の await より前に処理中にする（二重の確定を防ぐ・要件 4.10）
        phase = .processing

        do {
            let result = try await groupService.joinGroup(code: code)
            errorMessage = nil
            logEvent(.groupJoined(alreadyMember: result.alreadyMember))
            // 既存のメンバーだった場合も、エラーにせずタイムラインへ（要件 4.4・4.8）
            await finish(destinations: [.timeline(groupId: result.groupId)])
        } catch {
            SoratomoError.record(error, context: "soratomo.joinGroup")
            errorMessage = error.userMessage
            logEvent(.joinFailed(SoratomoJoinFailReason(error)))
            phase = .idle
        }
    }

    // MARK: - 4. 事前説明（12.2）

    /// 作成か参加の成功の後、事前説明か設定の案内を出すかを決める
    ///
    /// 出すものがあれば `.primer` の段にし、閉じられたら（`finishPrimer()`）完了にする。無ければすぐ完了にする。
    /// 「1 回だけ」の記録は primer と事前説明の画面が持つ（この ViewModel は判定を呼ぶだけ）。
    private func finish(destinations: [SoratomoDestination]) async {
        phase = .completed
        completedDestinations = destinations

        let decision = await primer.decide()
        switch decision {
        case .showPrimer, .showSettingsGuide:
            step = .primer(decision)
        case .none:
            complete()
        }
    }

    /// 事前説明か設定の案内が閉じられた（`SoratomoNotificationPrimerView` の `onFinished`）
    func finishPrimer() {
        guard case .primer = step else { return }
        complete()
    }

    /// 進む先のパスを渡す（1 回だけ）
    private func complete() {
        guard let destinations = completedDestinations else { return }
        completedDestinations = nil
        onCompleted(destinations)
    }

    // MARK: - 表示用

    /// 処理中か完了後か（true の間は確定のボタンを無効にする）
    var isProcessing: Bool {
        phase != .idle
    }

    /// シートを閉じる操作を出してよいか
    ///
    /// 処理中（作成や参加の結果を待っている間）と、事前説明・設定の案内を出している間は閉じさせない。
    /// 事前説明は、選ばずに閉じられると「出した」記録が残らず、次にもう一度出てしまうため（要件 10.1・10.4）。
    /// 表示名が要るかを確かめている間（読み取りだけで、何も書いていない）は、閉じてよい
    /// （圏外でキャッシュも無いと読み取りが長く待つことがあり、閉じられないと出口が無くなるため）。
    var canCancel: Bool {
        switch step {
        case .checking, .checkFailed:
            true
        case .primer:
            false
        case .displayName, .form:
            phase == .idle
        }
    }
}
