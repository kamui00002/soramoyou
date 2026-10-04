//
//  SoratomoInviteViewModel.swift
//  Soramoyou
//
//  そらともの招待コードの共有と再発行の ViewModel ⭐️
//  （tasks 13.4・design.md の SoratomoInviteView・ViewModel・要件 3.4〜3.8・3.11・3.12・14.3・15.4）
//

import Foundation
import UIKit

/// そらともの招待コードの共有と再発行の ViewModel
///
/// - グループ名・招待コード・オーナーは `observeGroup` の監視で取る（再発行の後の新しいコードも監視で届く）
/// - オーナーかどうかは、いまの uid とグループの `ownerId` を比べて決める。再発行の操作はオーナーにだけ出す（要件 3.8）
/// - 再発行に成功したら、返ってきた新しいコードをすぐに出す（監視の通知を待たない・要件 3.11）
/// - 再発行に失敗したら（通信できない場合を含む）、表示中のコードを変えずに固定の文言を出す（要件 3.12）
/// - 計測: `soratomo_invite_shared`（share_sheet・copy）・`soratomo_invite_code_regenerated`・
///   `soratomo_invite_regenerate_failed`（not_owner・network・unknown）。パラメータに招待コードやグループ名は入れない（要件 14.4）
@MainActor
final class SoratomoInviteViewModel: ObservableObject {
    // MARK: - 定数

    /// 招待文の 4 行目に入れる App Store の URL
    ///
    /// そらもよう自身の Apple ID（6758070979）。2026-10-05 に iTunes lookup（bundleId=com.yoshidometoru.Soramoyou）で確認した。
    /// ⚠️ `Views/SkyZukanView.swift` の `id6790911086` は別アプリ「天名」のページなので、写さないこと。
    private static let appStoreURL = "https://apps.apple.com/app/id6758070979"

    /// 「コピーしました」を出しておく時間（ナノ秒・2 秒）
    private static let copiedFeedbackNanoseconds: UInt64 = 2_000_000_000

    // MARK: - Properties

    /// グループ名（まだ読めていなければ nil）
    @Published private(set) var groupName: String?
    /// 表示中の招待コード（まだ読めていなければ nil）
    @Published private(set) var inviteCode: SoratomoInviteCode?
    /// いまの利用者がこのグループのオーナーか（再発行の操作を出すかどうか）
    @Published private(set) var isOwner = false
    /// グループを一度も読めずに監視が失敗したときの固定の文言（読めていれば nil）
    @Published private(set) var loadErrorMessage: String?
    /// 再発行の最中か（二重に送らないため・ボタンを押せなくするため）
    @Published private(set) var isRegenerating = false
    /// 再発行に失敗したときの固定の文言（失敗していなければ nil）
    @Published var regenerateErrorMessage: String?
    /// コピーした直後か（「コピーしました」を一時的に出すため）
    @Published private(set) var didCopy = false

    /// 表示するグループの ID
    private let groupId: String
    /// グループのサービス
    private let groupService: any SoratomoGroupServiceProtocol
    /// いまログインしている利用者の uid（未ログインなら nil）
    private let currentUid: () -> String?
    /// 計測の記録（既定は `SoratomoAnalytics.log`。単体テストで差し替える）
    private let logEvent: (SoratomoEvent) -> Void
    /// クリップボードへ写す処理（既定は `UIPasteboard.general`。単体テストで差し替え、本物のクリップボードを汚さない）
    private let copyToPasteboard: (String) -> Void

    /// グループの監視の札（持っている間だけ監視が続く。上書きすると古い監視は止まる）
    private var groupToken: SoratomoListenerToken?
    /// 「コピーしました」を消す処理（続けてコピーしたら、前の処理を止めて数え直す）
    private var copiedResetTask: Task<Void, Never>?

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 表示するグループの ID
    ///   - groupService: グループのサービス
    ///   - currentUid: いまログインしている利用者の uid を返す
    ///   - logEvent: 計測の記録。既定は本番の `SoratomoAnalytics.log`
    ///   - copyToPasteboard: クリップボードへ写す処理。既定は `UIPasteboard.general` へ写す
    init(
        groupId: String,
        groupService: any SoratomoGroupServiceProtocol,
        currentUid: @escaping () -> String?,
        logEvent: @escaping (SoratomoEvent) -> Void = SoratomoAnalytics.log,
        copyToPasteboard: @escaping (String) -> Void = { UIPasteboard.general.string = $0 }
    ) {
        self.groupId = groupId
        self.groupService = groupService
        self.currentUid = currentUid
        self.logEvent = logEvent
        self.copyToPasteboard = copyToPasteboard
    }

    // MARK: - 監視

    /// グループの監視を始める（画面を開いたときに呼ぶ）
    ///
    /// すでに監視していれば何もしない（画面に戻るたびに張り直さない）。
    func start() {
        guard groupToken == nil else { return }
        // ⚠️ self を強く捕まえると、札（self が持つ）→ 受け手 → self の循環になり、監視が止まらない
        groupToken = groupService.observeGroup(groupId: groupId) { [weak self] result in
            self?.handleGroupChange(result)
        }
    }

    /// 監視で届いた結果を画面の状態へ写す
    private func handleGroupChange(_ result: Result<SoratomoGroup, SoratomoError>) {
        switch result {
        case let .success(group):
            groupName = group.name
            inviteCode = group.inviteCode
            // 未ログイン（uid が nil）ならオーナーではない
            isOwner = currentUid().map { $0 == group.ownerId } ?? false
            loadErrorMessage = nil
        case let .failure(error):
            // 失敗は固定の文脈で記録する（文脈に ID・名前・コードを混ぜない・要件 15.1・15.4）
            SoratomoError.record(error, context: "soratomo.observeGroup.invite")
            // すでに読めた内容があれば、それを出したままにする（一時的な失敗で画面を消さない）
            if groupName == nil {
                loadErrorMessage = error.userMessage
            }
        }
    }

    // MARK: - 共有・コピー

    /// 共有シートに渡す招待文（コードとグループ名を読めていなければ nil）
    var inviteText: String? {
        guard let groupName, let inviteCode else { return nil }
        return Self.makeInviteText(groupName: groupName, inviteCode: inviteCode, appStoreURL: Self.appStoreURL)
    }

    /// 共有シートを開いたことを記録する（共有ボタンを押したときに呼ぶ）
    ///
    /// 要件 14 の表の `soratomo_invite_shared` は「共有シートを開いた」ときの記録なので、
    /// 共有を最後までしたかどうかでなく、開いた時点で記録する。
    func recordShareSheetOpened() {
        logEvent(.inviteShared(.shareSheet))
    }

    /// 招待コードを「XXXX-XXXX」の形でクリップボードへ写し、写したことを一時的に出す（要件 3.6）
    ///
    /// ハイフン付きのまま写しても、参加の入力ではハイフンを除いて読む（`SoratomoInviteCode.parse`）。
    func copyInviteCode() {
        guard let inviteCode else { return }
        copyToPasteboard(inviteCode.displayText)
        logEvent(.inviteShared(.copy))
        didCopy = true

        // 続けて押されたら、前の「消す処理」を止めて 2 秒を数え直す
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.copiedFeedbackNanoseconds)
            guard !Task.isCancelled else { return }
            self?.didCopy = false
        }
    }

    // MARK: - 再発行

    /// 招待コードを再発行する（確認で「再発行する」を選んだ後に呼ぶ）
    ///
    /// - オーナーでなければ何もしない（操作はオーナーにだけ出す。サーバーもオーナー以外を拒否する）
    /// - 通信の事前確認はしない（tasks 10.5 の事前確認の対象に再発行は無い）。通信できない失敗は
    ///   サービスが `.network` で返すので、ほかの失敗と同じく表示中のコードを変えずに文言を出す
    func regenerate() async {
        guard isOwner, !isRegenerating else { return }
        isRegenerating = true
        regenerateErrorMessage = nil
        defer { isRegenerating = false }

        do {
            let newCode = try await groupService.regenerateInviteCode(groupId: groupId)
            // 監視の通知を待たずに、新しいコードを出す（要件 3.11）
            inviteCode = newCode
            logEvent(.inviteCodeRegenerated)
        } catch {
            let failure = Self.soratomoError(from: error)
            // 表示中のコード（inviteCode）は変えない（要件 3.12）
            SoratomoError.record(failure, context: "soratomo.regenerateInviteCode")
            logEvent(.inviteRegenerateFailed(SoratomoRegenerateFailReason(failure)))
            regenerateErrorMessage = SoratomoFailedAction.regenerateInviteCode.userMessage
        }
    }

    // MARK: - 純関数

    /// 共有シートに渡す招待文を作る（要件 3.5 の 4 行のまま）
    ///
    /// - Parameters:
    ///   - groupName: グループ名
    ///   - inviteCode: 招待コード（「XXXX-XXXX」の形で入れる）
    ///   - appStoreURL: アプリをお持ちでない方に案内する App Store の URL
    /// - Returns: 改行で区切った 4 行の招待文
    nonisolated static func makeInviteText(
        groupName: String,
        inviteCode: SoratomoInviteCode,
        appStoreURL: String
    ) -> String {
        [
            "「\(groupName)」に招待されました。",
            "そらもようで空を共有しよう！",
            "招待コード: \(inviteCode.displayText)",
            "アプリをお持ちでない方: \(appStoreURL)",
        ].joined(separator: "\n")
    }

    /// サービスの失敗を `SoratomoError` にそろえる（サービスは typed throws なので、ふつうはそのまま返る）
    private static func soratomoError(from error: any Error) -> SoratomoError {
        error as? SoratomoError ?? .unknown
    }
}
