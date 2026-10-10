//
//  SoratomoRootView.swift
//  Soramoyou
//
//  そらともの根の画面（NavigationStack）⭐️
//  （tasks 13.1・design.md の SoratomoRootView・SoratomoRouter・要件 5.1・10.9）
//
//  ルーターのパス（`SoratomoRouter.path`）を NavigationStack に結び、4 つの行き先
//  （タイムライン・招待・メンバー一覧・投稿詳細）をここで 1 回だけ対応づける。
//  ⚠️ 13.2〜13.9 の担当は、このファイルを変えない。自分の画面のファイル（同じ init）の中身を置き換える。
//  全画面のカバーから出すのは 14.1（MainTabView）の担当。
//  release-gate 10.5: 開くたびに同意の状態を確かめ、入口の判定（`SoratomoEntryGate.needsGuideline`）が真なら、
//  NavigationStack の代わりにガイドラインの全文を出す（要件 10.2・10.5・10.6）。
//

import SwiftUI
import UIKit

/// そらともの根の画面
///
/// - パスが空なら一覧、`[.timeline(groupId:)]` なら一覧の上にタイムライン（通知の行き先の形）
/// - ルーターの一時表示（`notice`。「グループを開けませんでした」など）を、上部に数秒だけ出す
/// - 開くたびに（全画面のカバーは開くたびに作り直される）同意の状態を確かめる。所属があって現行の版に
///   同意していなければ、一覧の代わりに全文を出す。通知のタップで開いたときも同じ判定をし、行き先（`router.path`）は残す
struct SoratomoRootView: View {
    /// 入口の段
    enum EntryState: Equatable {
        /// 同意の状態を確かめている
        case checking
        /// ガイドラインの全文を出している（同意を求める）
        case guideline
        /// 一覧（または通知の行き先）を出している
        case open
    }

    // MARK: - Properties

    /// そらともへの遷移を決めるルーター（アプリでは `SoratomoRouter.shared`）
    @ObservedObject var router: SoratomoRouter
    /// サービスの容れ物（アプリでは `SoratomoDependencies.live`）
    let dependencies: SoratomoDependencies

    /// 一時表示を出しておく時間（秒）
    private static let noticeSeconds: UInt64 = 3

    /// 入口の段
    @State private var entryState: EntryState = .checking
    /// 同意を記録している途中か
    @State private var isAgreeing = false
    /// 同意の記録の失敗の文言（無ければ nil）
    @State private var agreeErrorMessage: String?

    // MARK: - Body

    var body: some View {
        entryContent
            .overlay(alignment: .top) {
                noticeBanner
            }
            // 一時表示が変わるたびに、数秒後に消す（同じ文言が続けて来ても、id が nil を挟むので数え直す）
            .task(id: router.notice) {
                guard router.notice != nil else { return }
                try? await Task.sleep(nanoseconds: Self.noticeSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                router.notice = nil
            }
            .task {
                await checkEntry()
            }
    }

    // MARK: - 入口（release-gate 10.5）

    /// 入口の段ごとの中身
    @ViewBuilder
    private var entryContent: some View {
        switch entryState {
        case .checking:
            // 一覧より先に全文を出すため、確かめ終わるまで一覧を出さない（要件 10.2）
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .soratomoSkyBackground()
                .accessibilityLabel("準備しています")
                // 圏外でキャッシュも無いと読み取りが長く待つことがあるので、確かめている間も閉じられるようにする
                // （全画面のカバーは下へのスワイプで閉じられない）
                .overlay(alignment: .topLeading) {
                    Button {
                        router.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .padding(.leading, 8)
                    .accessibilityLabel("そらともを閉じる")
                }
        case .guideline:
            SoratomoGuidelineView(
                mode: .consent(
                    trigger: .entry,
                    isAgreeing: isAgreeing,
                    onAgree: {
                        Task { await agree() }
                    },
                    onDecline: {
                        // 同意を記録せず、そらともの画面を閉じる（要件 10.5）
                        router.dismiss()
                    }
                )
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                if let agreeErrorMessage {
                    Label(agreeErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.bar)
                        .accessibilityLabel(agreeErrorMessage)
                }
            }
        case .open:
            navigationStack
        }
    }

    /// 同意の状態を確かめ、入口の段を決める（開くたびに 1 回）
    ///
    /// 読めなかったときは全文を出さずに開く（作成と参加はサーバーが同意を確かめる・`SoratomoEntryGate` の決まり）
    private func checkEntry() async {
        guard entryState == .checking else { return }
        var status: SoratomoConsentStatus?
        if let uid = dependencies.currentUid() {
            do {
                status = try await dependencies.guidelineService.fetchConsentStatus(uid: uid)
            } catch {
                SoratomoError.record(error, context: "soratomo.entry.fetchConsentStatus")
            }
        }
        entryState = SoratomoEntryGate.needsGuideline(status: status) ? .guideline : .open
    }

    /// 「同意する」を選んだ。記録に成功してから一覧（または通知の行き先）を出す（要件 10.6・10.7）
    private func agree() async {
        guard entryState == .guideline, !isAgreeing else { return }
        guard dependencies.network.isOnline else {
            agreeErrorMessage = SoratomoFailedAction.agreeGuideline.userMessage
            return
        }
        isAgreeing = true
        defer { isAgreeing = false }
        do {
            try await dependencies.guidelineService.agree(version: SoratomoGuideline.currentVersion)
            agreeErrorMessage = nil
            entryState = .open
        } catch {
            SoratomoError.record(error, context: "soratomo.entry.agreeGuideline")
            agreeErrorMessage = error == .outdatedApp
                ? SoratomoError.outdatedApp.userMessage
                : SoratomoFailedAction.agreeGuideline.userMessage
        }
    }

    // MARK: - ナビゲーション

    /// 一覧と 4 つの行き先
    private var navigationStack: some View {
        NavigationStack(path: $router.path) {
            SoratomoGroupListView(router: router, dependencies: dependencies)
                .soratomoSkyBackground()
                .navigationDestination(for: SoratomoDestination.self) { destination in
                    view(for: destination)
                }
        }
        // 画面名の記録（要件 14.5）。各画面の onAppear は、戻るスワイプを途中でやめたときなどに重ねて発火しうるので、
        // パス（`router.path`）を単一の真実源にして「画面の切り替え 1 回 = 記録 1 回」にする（MainTabView の selectedTab と同じ形）。
        // 投稿画面（シート）はパスに入らないので、投稿画面の側で記録する
        .task {
            SoratomoAnalytics.screen(Self.screen(for: router.path))
        }
        .onChange(of: router.path) { newPath in
            // 閉じるとき（dismiss は isPresented を先に false にしてからパスを空にする）は記録しない
            guard router.isPresented else { return }
            SoratomoAnalytics.screen(Self.screen(for: newPath))
        }
    }

    // MARK: - 画面名

    /// パスの末尾（いま見えている画面）の画面名。パスが空なら一覧
    static func screen(for path: [SoratomoDestination]) -> SoratomoScreen {
        switch path.last {
        case nil: .groupList
        case .timeline: .timeline
        case .invite: .invite
        case .members: .members
        case .skyDetail: .skyDetail
        }
    }

    // MARK: - 行き先

    /// 行き先ごとの画面（13.4・13.5・13.9 の担当が、それぞれのファイルの中身を作る）
    @ViewBuilder
    private func view(for destination: SoratomoDestination) -> some View {
        switch destination {
        // 背景は雲つきの空にそろえる（SoratomoSkyBackground.swift）。投稿詳細だけは写真の色を邪魔しないよう付けない
        case let .timeline(groupId):
            SoratomoTimelineView(groupId: groupId, router: router, dependencies: dependencies)
                .soratomoSkyBackground()
        case let .invite(groupId):
            SoratomoInviteView(groupId: groupId, dependencies: dependencies)
                .soratomoSkyBackground()
        case let .members(groupId):
            SoratomoMembersView(groupId: groupId, dependencies: dependencies)
                .soratomoSkyBackground()
        case let .skyDetail(groupId, skyId):
            SoratomoSkyDetailView(groupId: groupId, skyId: skyId, dependencies: dependencies)
        }
    }

    // MARK: - 一時表示

    /// ルーターの一時表示（無ければ何も出さない）
    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = router.notice {
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                // VoiceOver では、出た時点で読み上げる
                .accessibilityAddTraits(.updatesFrequently)
                .onAppear {
                    UIAccessibility.post(notification: .announcement, argument: notice)
                }
        }
    }
}
