//
//  SoratomoGroupFormViewModel.swift
//  Soramoyou
//
//  そらともの「グループを作る」「招待コードで参加」のシートの ViewModel ⭐️
//  （tasks 13.2・13.3・design.md の SoratomoGroupFormViewModel・SoratomoDisplayNameStep・
//    要件 2・4・10.1・10.5・12.2・12.5・14.3・15.4・18）
//
//  シートの中の流れ:
//    1. ガイドラインへの同意と、表示名が要るかを確かめる（`fetchConsentStatus`・`needsDisplayName`）
//    1.5 現行の版に同意していなければ、ガイドラインの全文（release-gate 10.4・要件 10.1・10.3・10.4・10.6〜10.8）
//        →「同意する」で記録に成功したら 2 へ／「同意しない」は記録せずにシートを閉じる
//    2. 要るなら表示名の入力（13.2）→ 保存に成功したら 3 へ
//    3. グループ名か招待コードの入力（13.3）→ 作成か参加に成功したら 4 へ
//       サーバーが「同意が必要」で拒否したら 1.5 へ戻り、入力は残す（要件 10.11）
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
        /// ガイドラインの全文と同意（release-gate 10.4。`trigger` は計測に使うきっかけ）
        case guideline(SoratomoGuidelineTrigger)
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
    /// ガイドラインへの同意の状態を読み、同意を記録するサービス
    private let guidelineService: any SoratomoGuidelineServiceProtocol
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
    /// ガイドラインで「同意しない」を選んだとき（シートを閉じて一覧へ戻す・要件 10.4）
    private let onDeclined: () -> Void

    /// 同意を記録した後に進む段（表示名の入力か、グループ名・招待コードの入力）
    private var stepAfterGuideline: Step = .form

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
    ///   - guidelineService: ガイドラインへの同意の状態を読み、同意を記録するサービス
    ///   - primer: 通知の事前説明の判定
    ///   - isOnline: いま通信できる状態かを返す
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    ///   - onCompleted: 成功したときに、進む先のパスを受け取る
    ///   - onDeclined: ガイドラインで「同意しない」を選んだとき（シートを閉じる）
    init(
        mode: SoratomoGroupFormMode,
        groupService: any SoratomoGroupServiceProtocol,
        profileService: any SoratomoProfileServiceProtocol,
        guidelineService: any SoratomoGuidelineServiceProtocol,
        primer: any SoratomoNotificationPrimerProtocol,
        isOnline: @escaping () -> Bool,
        currentUid: @escaping () -> String?,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log,
        onCompleted: @escaping ([SoratomoDestination]) -> Void,
        onDeclined: @escaping () -> Void
    ) {
        self.mode = mode
        self.groupService = groupService
        self.profileService = profileService
        self.guidelineService = guidelineService
        self.primer = primer
        self.isOnline = isOnline
        self.currentUid = currentUid
        self.logEvent = logEvent
        self.onCompleted = onCompleted
        self.onDeclined = onDeclined
    }

    // MARK: - 1. 同意と表示名が要るか

    /// ガイドラインへの同意と表示名の入力が要るかを確かめ、最初の段を決める（シートを開いたとき・やり直しのときに呼ぶ）
    ///
    /// - 現行の版に同意していない → ガイドラインの全文（要件 10.1）。同意の後に、下の段へ進む
    ///   ⚠️ 入口の判定（`SoratomoEntryGate.needsGuideline`）は使わない。所属が 0 のときに偽を返すので、
    ///      初めてグループを作る人に全文が出なくなる
    /// - 同意の状態を読めなかった → 全文を出さずに進む。作成と参加はサーバーが同意を確かめて拒否し、
    ///   その拒否（`.consentRequired`）で全文へ戻る（要件 10.10・10.11）。ここで止めると、読めないだけで先へ進めなくなる
    /// - 表示名が要る（未設定か空白だけ）→ 表示名の入力（要件 18.1）
    /// - 表示名が要らない（設定済み）→ グループ名か招待コードの入力（要件 18.6）
    /// - 表示名が要るかを確かめられなかった（どのエラーでも）→ 先へ進ませず、固定の文言とやり直しの操作を出す
    func start() async {
        // 確かめている途中と、確かめた後（同意・入力中・処理中）は、もう一度確かめない
        switch step {
        case .checking, .checkFailed:
            break
        case .guideline, .displayName, .form, .primer:
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

        // 同意の状態（読めなければ同意済みとして扱い、全文を出さずに進む。理由は上の説明の「読めなかった」）
        let hasAgreed: Bool
        do {
            hasAgreed = try await guidelineService.fetchConsentStatus(uid: uid).hasAgreedCurrent
        } catch {
            SoratomoError.record(error, context: "soratomo.fetchConsentStatus")
            hasAgreed = true
        }

        do {
            let needs = try await profileService.needsDisplayName(uid: uid)
            let next: Step = needs ? .displayName : .form
            if hasAgreed {
                step = next
            } else {
                stepAfterGuideline = next
                step = .guideline(guidelineTrigger)
            }
        } catch {
            // ⚠️ 権限の拒否は `.notMember` に写るが、その文言（「グループを開けませんでした」）はこの場面に合わない。
            //    通信のときだけ通信の文言、それ以外は「うまくいきませんでした」の文言にする
            SoratomoError.record(error, context: "soratomo.needsDisplayName")
            let message = error == .network ? SoratomoError.network.userMessage : SoratomoError.unknown.userMessage
            step = .checkFailed(message: message)
        }
    }

    // MARK: - 1.5 ガイドラインへの同意（release-gate 10.4）

    /// 「同意する」を選んだ（全文の段で呼ぶ）
    ///
    /// - 通信できなければ、記録せずに「同意を記録できませんでした」を出し、先へ進ませない（要件 10.7）
    /// - 記録に成功してから、表示名かグループ名・招待コードの入力へ進む（要件 10.6）
    /// - 記録に失敗したら、先へ進ませない。アプリが古い（サーバーの版のほうが新しい）ならアップデートの案内、
    ///   それ以外は「同意を記録できませんでした」
    /// - ⚠️ 選んだ操作の計測（`soratomo_guideline_result`）は全文の画面が記録する。ここでは記録しない（二重に数えない）
    func agreeGuideline() async {
        guard case .guideline = step, phase == .idle else { return }

        guard isOnline() else {
            errorMessage = SoratomoFailedAction.agreeGuideline.userMessage
            return
        }

        // ⚠️ 最初の await より前に処理中にする（二重の確定を防ぐ）
        phase = .processing
        defer { phase = .idle }

        do {
            try await guidelineService.agree(version: SoratomoGuideline.currentVersion)
            errorMessage = nil
            step = stepAfterGuideline
        } catch {
            SoratomoError.record(error, context: "soratomo.agreeGuideline")
            errorMessage = error == .outdatedApp
                ? SoratomoError.outdatedApp.userMessage
                : SoratomoFailedAction.agreeGuideline.userMessage
        }
    }

    /// 「同意しない」を選んだ（全文の段で呼ぶ）。同意を記録せず、シートを閉じて一覧へ戻す（要件 10.4）
    func declineGuideline() {
        guard case .guideline = step, phase == .idle else { return }
        onDeclined()
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
            logEvent(.createFailed(SoratomoCreateFailReason(error)))
            phase = .idle
            showSubmitFailure(error)
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
            logEvent(.joinFailed(SoratomoJoinFailReason(error)))
            phase = .idle
            showSubmitFailure(error)
        }
    }

    /// 作成・参加の失敗を出す（入力は消さない・要件 2.6・4.9・11.7）
    ///
    /// - 「同意が必要」（サーバーが同意の記録を見つけられなかった）→ 全文の段へ戻す。同意したら入力の段へ戻る（要件 10.11）
    /// - それ以外 → 固定の文言（利用停止はお問い合わせの方法つき・アプリが古いはアップデートの案内・
    ///   NGワードは該当した語を含めない）
    private func showSubmitFailure(_ error: SoratomoError) {
        if error == .consentRequired {
            errorMessage = nil
            stepAfterGuideline = .form
            step = .guideline(guidelineTrigger)
        } else {
            errorMessage = error.userMessage
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

    /// 全文を出したきっかけ（計測に使う）
    var guidelineTrigger: SoratomoGuidelineTrigger {
        mode == .create ? .create : .join
    }

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
        case .guideline, .displayName, .form:
            phase == .idle
        }
    }
}
