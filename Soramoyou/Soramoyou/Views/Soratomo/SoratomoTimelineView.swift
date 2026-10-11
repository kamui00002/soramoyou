//
//  SoratomoTimelineView.swift
//  Soramoyou
//
//  そらとものグループのタイムライン ⭐️
//  （tasks 13.5・13.6・13.4 の「タイムラインから招待を開ける」導線・design.md の SoratomoTimelineView・ViewModel・
//   要件 8.1〜8.20・10.9・12.1・14.5・16.4・16.5）
//
//  - 上部にグループ名とメンバー数。投稿・招待・メンバー一覧への導線を置く
//  - 投稿を日付の見出しで区切って新しい順に出す。末尾で 20 件ずつ足し、引き下げで最新の 20 件に戻す
//  - オフラインの間は、読み込んだ投稿を出したまま、先頭にオフラインであることを出す
//  - 自分の投稿だけに削除の操作を出し、確認の後に削除する（13.6）
//  - 自分以外の投稿には通報とブロックの操作を出す。通報は 5 つの理由から選び、ブロックは確認の後に行う
//    （release-gate 10.2・要件 5.1〜5.3・9.1・9.2・9.10）
//  - 右上のメニューから、このグループだけを抜ける。確認・処理中の覆いを出し、抜けた後の後片づけをつなぐ
//    （leave-group 8.5・要件 1.1〜1.3・1.6・1.9・5.1・5.4・5.5）
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView が使う）
//

import Kingfisher
import SwiftUI

/// グループのタイムライン
///
/// - グループを最初に読めたら `router.reportAccessible(groupId:)`、読めなかったら
///   `router.reportNotAccessible(groupId:)` を呼ぶ（ViewModel がクロージャ経由で呼ぶ・12.1 の記録は 1 タップ 1 回）
/// - 招待・メンバー一覧・投稿詳細へは `router.path.append(...)` で進む
/// - 投稿画面（13.7・13.8 の `SoratomoComposeView`）はシートで出す
struct SoratomoTimelineView: View {
    // MARK: - Properties

    /// 表示するグループの ID
    let groupId: String
    /// そらともへの遷移を決めるルーター
    @ObservedObject var router: SoratomoRouter
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    /// タイムラインの ViewModel
    @StateObject private var viewModel: SoratomoTimelineViewModel
    /// グループを抜ける画面の状態（タイムラインの ViewModel と、互いを弱参照でつないだ 1 組で作る・leave-group 8.5）
    @StateObject private var leaveViewModel: SoratomoLeaveViewModel
    /// 投稿者の表示名とアイコン（容れ物越しには変化が伝わらないので、別に持つ）
    @ObservedObject private var profileStore: SoratomoProfileStore
    /// 通信の有無（オフラインの表示に使う）
    @ObservedObject private var network: NetworkStatusMonitor

    /// 投稿画面のシートを出しているか
    @State private var isComposing = false
    /// 削除の確認を出している投稿（nil なら出していない）
    @State private var skyPendingDeletion: SoratomoSky?
    /// 通報の理由を選ばせている投稿（nil なら出していない）
    @State private var skyPendingReport: SoratomoSky?
    /// ブロックの確認を出している投稿（nil なら出していない）
    @State private var skyPendingBlock: SoratomoSky?
    /// 抜けるの確認に出している内容（nil なら出していない・leave-group 8.5）
    ///
    /// ⚠️ アラートの isPresented を `leaveViewModel.phase` から直接作らない。「抜ける」の本体は Task で後から走るので、
    ///    閉じた時点の setter で `cancel()` を呼ぶと `confirm()` が何もしなくなり、getter を phase にすると
    ///    閉じた直後もまだ `.confirming` なので出し直しうる。phase の変化でここへ写し、setter はここを消すだけにする
    @State private var leaveConfirmation: SoratomoLeaveConfirmation?

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 表示するグループの ID
    ///   - router: そらともへの遷移を決めるルーター
    ///   - dependencies: サービスの容れ物
    init(groupId: String, router: SoratomoRouter, dependencies: SoratomoDependencies) {
        self.groupId = groupId
        self.router = router
        self.dependencies = dependencies
        _profileStore = ObservedObject(wrappedValue: dependencies.profileStore)
        _network = ObservedObject(wrappedValue: dependencies.network)

        // タイムラインと抜けるの ViewModel は、互いを弱参照でつないだ 1 組として作る（leave-group 8.5）。
        // `StateObject` の中身（オートクロージャ）は、画面が最初に置かれたときに 1 回だけ評価され、
        // 作り直しの init では評価されない。2 つの `@StateObject` が同じ組を受け取れるように、組をこの init の
        // ローカル変数に覚え、最初に取り出したときにだけ作る（別々に作ると、互いに別の相手とつながってしまう）
        var pair: ViewModelPair?
        func makePair() -> ViewModelPair {
            if let pair {
                return pair
            }
            let made = Self.makeViewModels(groupId: groupId, router: router, dependencies: dependencies)
            pair = made
            return made
        }
        _viewModel = StateObject(wrappedValue: makePair().timeline)
        _leaveViewModel = StateObject(wrappedValue: makePair().leave)
    }

    // MARK: - ViewModel の組

    /// タイムラインと抜けるの ViewModel の組
    private typealias ViewModelPair = (timeline: SoratomoTimelineViewModel, leave: SoratomoLeaveViewModel)

    /// タイムラインと抜けるの ViewModel を、互いを弱参照でつないだ 1 組として作る（leave-group 8.5）
    ///
    /// - タイムラインの「読めなかった」の知らせは、先に抜けるの ViewModel に渡す（`absorbLostMembership`）。
    ///   未確定の抜けるが実は済んでいたと分かったら、そちらが「抜けた後」へ進めるので、ルーターへは知らせない（D1）
    /// - 抜けるの ViewModel は、タイムラインが監視しているグループを読み、監視を止める・張り直す（8.2）
    /// - どちらの向きも弱参照にして、輪を作らない（それぞれを強く持つのは、自分の `@StateObject` だけ）
    /// - ViewModel には容れ物を渡さず、中身（protocol とクロージャ）を取り出して渡す
    private static func makeViewModels(
        groupId: String,
        router: SoratomoRouter,
        dependencies: SoratomoDependencies
    ) -> ViewModelPair {
        let network = dependencies.network
        let skyLookup = dependencies.skyLookup
        let profileStore = dependencies.profileStore
        let leftGroups = dependencies.leftGroups

        // タイムラインを作る時点では、抜けるの ViewModel はまだ無い。作った後で入れる（弱参照）
        weak var weakLeave: SoratomoLeaveViewModel?

        let timeline = SoratomoTimelineViewModel(
            groupId: groupId,
            groupService: dependencies.groupService,
            skyService: dependencies.skyService,
            imageStore: dependencies.imageStore,
            currentUid: dependencies.currentUid,
            isOnline: { network.isOnline },
            reportAccessible: { [weak router] id in router?.reportAccessible(groupId: id) },
            reportNotAccessible: { [weak router] id in
                // D1: 張り直した監視が「メンバーでない」を届けた。未確定の抜けるが実は済んでいたなら、
                //     抜けるの ViewModel が「抜けた後」へ進めるので、「グループを開けませんでした」は出さない
                if weakLeave?.absorbLostMembership(groupId: id) == true {
                    return
                }
                router?.reportNotAccessible(groupId: id)
            },
            rememberSkies: { skies in skyLookup.remember(skies) },
            forgetSky: { groupId, skyId in skyLookup.forget(groupId: groupId, skyId: skyId) },
            moderationService: dependencies.moderationService,
            blockedAuthors: dependencies.blockedAuthors,
            reportedSkies: dependencies.reportedSkies
        )

        let leave = SoratomoLeaveViewModel(
            groupId: groupId,
            leaveService: dependencies.leaveService,
            groupService: dependencies.groupService,
            currentUid: dependencies.currentUid,
            isOnline: { network.isOnline },
            currentGroup: { [weak timeline] in timeline?.group },
            displayName: { uid in
                // 引き継ぐ人の表示名（確認に出すだけ）。読めない・取れていないときは nil を返し、代替の「ユーザー」にさせる（D2）。
                // ⚠️ 同じ uid を別の読み込みが取りに行っている最中なら、prefetch は待たずに戻るので nil になりうる（D2 の範囲）
                await profileStore.prefetch(uids: [uid])
                return profileStore.profiles[uid] != nil ? profileStore.displayName(for: uid) : nil
            },
            suspendTimeline: { [weak timeline] in timeline?.suspendObservation() },
            resumeTimeline: { [weak timeline] in
                guard let timeline else { return }
                Task { await timeline.start() }
            },
            rememberLeft: { groupId, uid in leftGroups.insert(groupId, uid: uid) },
            purgeLocalData: { groupId in
                // 画像のキャッシュ（メモリとディスク）と投稿の覚えだけを消す。ブロックの一覧・通報の記録・
                // 表示名とアイコンの覚えには触れない（要件 5.4）。2 回目は画面の onDisappear
                SoratomoImageCache.removeGroup(groupId)
                skyLookup.forget(groupId: groupId)
            },
            onLeft: { [weak router] context in
                router?.finishLeaving(groupId: context.groupId, notice: context.notice)
            }
        )
        weakLeave = leave
        return (timeline: timeline, leave: leave)
    }

    // MARK: - Body

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                // オフラインの間は、読み込んだ投稿を出したまま、先頭にオフラインであることを出す（要件 12.1）
                if !network.isOnline {
                    offlineBanner
                }
            }
            // 抜けるの処理の間は、中身を無効にして VoiceOver からも隠し、覆いだけを出す（leave-group 8.5・要件 1.9）
            .disabled(isLeaving)
            .accessibilityHidden(isLeaving)
            .overlay {
                if isLeaving {
                    leavingOverlay
                }
            }
            .navigationTitle(viewModel.group?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            // 抜けるの処理の間は戻らせない（戻るボタンを隠すと、端からのスワイプで戻る操作も止まる）
            .navigationBarBackButtonHidden(isLeaving)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // 抜けるの途中（確認の材料を読む間・確認・処理中）は、ほかの画面へ進ませない（leave-group 8.5）
                    membersButton
                        .disabled(isLeaveInProgress)
                    inviteButton
                        .disabled(isLeaveInProgress)
                    composeButton
                        .disabled(isLeaveInProgress)
                    leaveMenu
                        .disabled(isLeaveInProgress)
                }
            }
            .sheet(isPresented: $isComposing) {
                SoratomoComposeView(groupId: groupId, dependencies: dependencies) { _ in
                    // 新しい投稿はタイムラインの監視で先頭に届くので、ここでは閉じるだけ
                    isComposing = false
                }
            }
            .confirmationDialog(
                "この投稿を削除しますか？",
                isPresented: isConfirmingDeletion,
                titleVisibility: .visible,
                presenting: skyPendingDeletion
            ) { sky in
                Button("削除", role: .destructive) {
                    Task { await viewModel.delete(sky) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { _ in
                Text("削除した投稿は元に戻せません")
            }
            .alert(
                viewModel.deleteErrorMessage ?? "",
                isPresented: isShowingDeleteError
            ) {
                Button("OK", role: .cancel) {}
            }
            // 通報の理由は既存の通報と同じ 5 つから 1 つを選ばせる（要件 5.3）
            .confirmationDialog(
                "通報理由を選択",
                isPresented: isChoosingReportReason,
                titleVisibility: .visible,
                presenting: skyPendingReport
            ) { sky in
                ForEach(ReportReason.allCases, id: \.self) { reason in
                    Button(reason.displayName) {
                        Task { await viewModel.report(sky, reason: reason, source: .timeline) }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { _ in
                Text("通報したことは、投稿した人やほかのメンバーには知らされません")
            }
            // ブロックは確認してから行う（要件 9.2）。表示名は見出しにだけ使い、ログと計測には出さない（14.1）
            .alert(
                blockConfirmationTitle,
                isPresented: isConfirmingBlock,
                presenting: skyPendingBlock
            ) { sky in
                Button("キャンセル", role: .cancel) {}
                Button("ブロック", role: .destructive) {
                    Task { await viewModel.block(sky, source: .timeline) }
                }
            } message: { _ in
                // 消える範囲（そらともとホーム）と、相手に知らされないこと（要件 9.10）を書く
                Text("この人の投稿が、そらともとホームに表示されなくなります。ブロックしたことは相手に知らされません")
            }
            // 通報とブロックの結果の知らせ（要件 5.4〜5.7・9.9）
            .alert(
                viewModel.moderationNotice?.userMessage ?? "",
                isPresented: isShowingModerationNotice
            ) {
                Button("OK", role: .cancel) {}
            }
            // グループを抜ける確認（leave-group 8.5・要件 1.2〜1.6）。既存のブロックの確認と同じ型。
            // 題のグループ名と本文の引き継ぐ人の表示名は、画面に出すだけで、ログと計測には渡さない（要件 11.1）
            .alert(
                leaveConfirmation?.title ?? "",
                isPresented: isConfirmingLeave,
                presenting: leaveConfirmation
            ) { _ in
                Button("キャンセル", role: .cancel) {
                    leaveViewModel.cancel()
                }
                Button("抜ける", role: .destructive) {
                    Task { await leaveViewModel.confirm() }
                }
            } message: { confirmation in
                Text(confirmation.message)
            }
            // 抜けるの知らせ（通信が無い・グループの情報を読めない・抜けられなかった。要件 1.7・1.8・4.4）
            .alert(
                leaveViewModel.alertMessage ?? "",
                isPresented: isShowingLeaveAlert
            ) {
                Button("OK", role: .cancel) {}
            }
            // 確認の内容は phase の変化で @State に写す（`leaveConfirmation` の ⚠️ を参照）
            .onChange(of: leaveViewModel.phase) { phase in
                if case let .confirming(confirmation) = phase {
                    leaveConfirmation = confirmation
                } else {
                    leaveConfirmation = nil
                }
            }
            .task {
                // 投稿詳細が同じ ViewModel で削除できるように、いま開いているタイムラインとして知らせる
                dependencies.activeTimelineViewModel = viewModel
                await viewModel.start()
            }
            // 投稿者の表示名とアイコンを、まだ持っていない分だけ取りに行く
            .task(id: authorIds) {
                await profileStore.prefetch(uids: authorIds)
            }
            // 抜けた後の、2 回目の画像のキャッシュの消去（leave-group 8.5・要件 5.4）。
            // 1 回目は抜けるの ViewModel の後片づけ（`purgeLocalData`）。閉じるまでの間の再描画と読み込み途中の画像で、
            // Kingfisher がこのグループのキャッシュとフォルダを作り直しうるので、閉じた時点でもう 1 回消す。
            // 判定は端末の記録で行う（処理中に閉じた＝抜けられたか未確定のときは、記録が無いので消さない）。
            // 投稿詳細を上に積んだときにも呼ばれるが、そのときは記録に無いので何もしない
            .onDisappear {
                if dependencies.isLeftGroup(groupId) {
                    SoratomoImageCache.removeGroup(groupId)
                }
            }
            // 画面名の記録は根の画面（SoratomoRootView）がパスの変化で 1 回だけ行う（14.3 の点検で集約）
    }

    // MARK: - 中身

    /// 読み込みの状態ごとの中身
    @ViewBuilder
    private var content: some View {
        if viewModel.showsEmptyGuide {
            // 読めていて、表示が 0 件で、続きも無いときだけ（全部隠れて続きがありうるときは出さない・9.7）
            emptyGuide
        } else if !viewModel.skies.isEmpty || viewModel.hasLoadedTimeline {
            // 全部隠れて表示が 0 件でも、一覧を出す（末尾の「さらに読み込む」と読み込み中の表示を見せるため）
            timelineList
        } else if viewModel.timelineError != nil {
            errorView
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 日付の見出しで区切った投稿の一覧（1 投稿 = 1 枚のガラスのカード）
    private var timelineList: some View {
        List {
            groupHeader
                .listRowSeparator(.hidden)
                .soratomoClearRowBackground()

            ForEach(viewModel.days()) { day in
                Section {
                    // 日付は画面の上に貼り付く見出し（Section の header）にしない。行が透明なので、
                    // カードが見出しの下に潜って文字が重なるため。行として置き、VoiceOver の見出しの印だけ付ける
                    // （2026-10-05 ユーザー判断）
                    Text(day.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.soratomoSecondary)
                        .accessibilityAddTraits(.isHeader)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 0, trailing: 20))
                        .soratomoClearRowBackground()

                    ForEach(day.skies) { sky in
                        row(for: sky)
                            .soratomoCardRow()
                    }
                }
            }

            if viewModel.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .soratomoClearRowBackground()
            } else if viewModel.canLoadMoreManually {
                // 自動の続き読みで表示が増えず、続きがありうるとき（9.7）
                loadMoreButton
                    .listRowSeparator(.hidden)
                    .soratomoClearRowBackground()
            }
        }
        .listStyle(.plain)
        .refreshable {
            viewModel.refresh()
        }
    }

    /// 投稿 1 件のカード（選ぶと投稿詳細へ進む）
    private func row(for sky: SoratomoSky) -> some View {
        Button {
            router.path.append(.skyDetail(groupId: sky.groupId, skyId: sky.id))
        } label: {
            SoratomoTimelineRow(
                sky: sky,
                authorName: profileStore.displayName(for: sky.authorId),
                authorPhotoURL: profileStore.photoURL(for: sky.authorId),
                isDeleting: viewModel.deletingSkyIds.contains(sky.id)
            )
            // 行そのものが上下に 4pt の余白を持つので、上下は 10pt にして 14pt にそろえる
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // カードの余白をタップしても開けるように、カード全体を押せる範囲にする
            .contentShape(SoratomoCardSurface.shape)
        }
        .buttonStyle(.plain)
        .soratomoCard()
        .accessibilityHint("投稿を大きく表示します")
        // 削除の操作は投稿者本人にだけ出す（要件 8.15）。自分以外の投稿には通報とブロックだけを出す（要件 5.2）。
        // VoiceOver ではアクションとして読める
        .contextMenu {
            if viewModel.canDelete(sky) {
                Button(role: .destructive) {
                    skyPendingDeletion = sky
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .accessibilityLabel("この投稿を削除")
            } else if viewModel.canModerate(sky) {
                Button {
                    skyPendingReport = sky
                } label: {
                    Label("通報", systemImage: "exclamationmark.bubble")
                }
                .accessibilityLabel("この投稿を通報")
                // 送信の途中は重ねて受け付けない（要件 5.8）
                .disabled(viewModel.reportingSkyIds.contains(sky.id))

                Button(role: .destructive) {
                    skyPendingBlock = sky
                } label: {
                    Label("ブロック", systemImage: "hand.raised")
                }
                .accessibilityLabel("この投稿者をブロック")
                .disabled(viewModel.blockingAuthorIds.contains(sky.authorId))
            }
        }
        .onAppear {
            // 末尾の投稿が出たら、続きを読む（要件 8.3）
            if sky.id == viewModel.skies.last?.id {
                viewModel.loadMoreIfNeeded()
            }
        }
    }

    /// 上部のグループの頭文字のアイコン・グループ名・メンバー数（要件 8.13）
    @ViewBuilder
    private var groupHeader: some View {
        if let group = viewModel.group {
            HStack(spacing: 12) {
                // 飾り（VoiceOver では読まない）
                SoratomoGroupIcon(name: group.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(group.memberCount)人")
                        .font(.caption)
                        .foregroundStyle(.soratomoSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// 投稿が無い間の案内（要件 8.12）
    private var emptyGuide: some View {
        VStack(spacing: 16) {
            groupHeader
            Image(systemName: "cloud.sun")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("まだ投稿がありません。最初の空を共有しよう")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    isComposing = true
                } label: {
                    Label("空を投稿", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("空を投稿する")

                Button {
                    router.path.append(.invite(groupId: groupId))
                } label: {
                    Label("招待する", systemImage: "person.badge.plus")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("友達を招待する")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 投稿を一度も読めていないときの失敗（固定の文言と、読み直しの操作）
    private var errorView: some View {
        VStack(spacing: 12) {
            Text((viewModel.timelineError ?? .unknown).userMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("もう一度読み込む") {
                viewModel.refresh()
            }
            .accessibilityHint("タイムラインを読み直します")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 末尾の「さらに読み込む」（自動の続き読みが上限に達したときだけ出す・9.7）
    private var loadMoreButton: some View {
        Button("さらに読み込む") {
            viewModel.loadMoreIfNeeded()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityHint("続きの投稿を読み込みます")
    }

    /// 先頭に出すオフラインの表示
    private var offlineBanner: some View {
        Label("オフラインです。以前に読み込んだ投稿を表示しています", systemImage: "wifi.slash")
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(.bar)
            .accessibilityElement(children: .combine)
    }

    /// 抜けるの処理中の覆い（leave-group 8.5・要件 1.9）
    ///
    /// 画面全体を半透明で覆って下の中身を押させず、回る印と「グループを抜けています…」を出す。
    /// VoiceOver では 1 つの要素として読む（下の中身は `accessibilityHidden` で隠している）
    private var leavingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("グループを抜けています…")
                    .font(.subheadline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("グループを抜けています")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - ツールバーの導線

    /// メンバー一覧への導線（メンバー数も出す）
    private var membersButton: some View {
        Button {
            router.path.append(.members(groupId: groupId))
        } label: {
            Image(systemName: "person.2")
        }
        .accessibilityLabel(membersLabel)
    }

    /// 招待の画面への導線（13.4: タイムラインからいつでも開ける）
    private var inviteButton: some View {
        Button {
            router.path.append(.invite(groupId: groupId))
        } label: {
            Image(systemName: "person.badge.plus")
        }
        .accessibilityLabel("友達を招待する")
    }

    /// 投稿画面を開くボタン
    private var composeButton: some View {
        Button {
            isComposing = true
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("空を投稿する")
    }

    /// その他の操作のメニュー（いまは「グループを抜ける」だけ・leave-group 8.5・要件 1.1）
    private var leaveMenu: some View {
        Menu {
            Button(role: .destructive) {
                Task { await leaveViewModel.requestLeave() }
            } label: {
                Label("グループを抜ける", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("その他の操作")
    }

    // MARK: - 補助

    /// メンバー一覧のボタンの VoiceOver の読み上げ（人数が分かれば添える）
    private var membersLabel: String {
        if let count = viewModel.group?.memberCount {
            return "メンバー一覧、\(count)人"
        }
        return "メンバー一覧"
    }

    /// 表示中の投稿の投稿者の uid の集合（表示名とアイコンを取りに行く対象）
    private var authorIds: Set<String> {
        Set(viewModel.skies.map(\.authorId))
    }

    /// 削除の確認を出しているか（閉じたら対象を消す）
    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { skyPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    skyPendingDeletion = nil
                }
            }
        )
    }

    /// 通報の理由を選ばせているか（閉じたら対象を消す）
    private var isChoosingReportReason: Binding<Bool> {
        Binding(
            get: { skyPendingReport != nil },
            set: { isPresented in
                if !isPresented {
                    skyPendingReport = nil
                }
            }
        )
    }

    /// ブロックの確認を出しているか（閉じたら対象を消す）
    private var isConfirmingBlock: Binding<Bool> {
        Binding(
            get: { skyPendingBlock != nil },
            set: { isPresented in
                if !isPresented {
                    skyPendingBlock = nil
                }
            }
        )
    }

    /// ブロックの確認の見出し（表示名を使う。画面に出すだけで、ログと計測には渡さない・14.1）
    private var blockConfirmationTitle: String {
        guard let sky = skyPendingBlock else { return "" }
        return "\(profileStore.displayName(for: sky.authorId))さんをブロックしますか？"
    }

    /// 通報とブロックの結果の知らせを出しているか（閉じたら知らせを消す）
    ///
    /// 削除の失敗と同じく、タイムラインが一番上に出ているときだけ出す。投稿詳細は同じ ViewModel を使い、
    /// 自分で知らせを出すので、下に隠れたタイムラインからは出さない（二重に出さないため・10.6）
    private var isShowingModerationNotice: Binding<Bool> {
        Binding(
            get: { viewModel.moderationNotice != nil && router.path.last == .timeline(groupId: groupId) },
            set: { isPresented in
                if !isPresented {
                    viewModel.moderationNotice = nil
                }
            }
        )
    }

    /// 抜けるの処理中か（覆いを出し、中身と戻るを止める）
    private var isLeaving: Bool {
        leaveViewModel.phase == .leaving
    }

    /// 抜けるの途中か（確認の材料を読む間・確認・処理中。右上のボタンとメニューを止める）
    ///
    /// ⚠️ 8.5 の本文は「処理中（`.leaving`）の間だけ」と書くが、確認の材料を読む間（`.preparing`）に
    ///    別の画面へ進むと、確認がその画面の下で出ようとするので、`.idle` 以外のすべてで止める
    private var isLeaveInProgress: Bool {
        leaveViewModel.phase != .idle
    }

    /// 抜けるの確認と知らせを、いま出してよいか
    ///
    /// 確認の材料を読む間（`.preparing`）は中身を止めないので、その間に投稿詳細へ進む・投稿のシートや
    /// 投稿の確認を開くことがある。そのときは出さずに待ち、覆っていたものが閉じてタイムラインが一番上に
    /// 戻った時点で出す（確認の内容は `@State` に、知らせは ViewModel に残っているので消えない）。
    /// 既存の削除の失敗・通報とブロックの知らせと同じく、タイムラインが一番上のときだけ出す
    private var canPresentLeaveDialogs: Bool {
        router.path.last == .timeline(groupId: groupId)
            && !isComposing
            && skyPendingDeletion == nil
            && skyPendingReport == nil
            && skyPendingBlock == nil
    }

    /// 抜けるの確認を出しているか（閉じたら内容を消すだけ。キャンセルと確定は、それぞれのボタンが呼ぶ）
    private var isConfirmingLeave: Binding<Bool> {
        Binding(
            get: { leaveConfirmation != nil && canPresentLeaveDialogs },
            set: { isPresented in
                if !isPresented {
                    leaveConfirmation = nil
                }
            }
        )
    }

    /// 抜けるの知らせを出しているか（閉じたら文言を消す）
    private var isShowingLeaveAlert: Binding<Bool> {
        Binding(
            get: { leaveViewModel.alertMessage != nil && canPresentLeaveDialogs },
            set: { isPresented in
                if !isPresented {
                    leaveViewModel.alertMessage = nil
                }
            }
        )
    }

    /// 削除の失敗を出しているか（閉じたら文言を消す）
    ///
    /// タイムラインが一番上に出ているときだけ出す。投稿詳細から削除して失敗したときは、
    /// 詳細が同じ文言を出すので、下に隠れたタイムラインからは出さない（二重に出さないため）
    private var isShowingDeleteError: Binding<Bool> {
        Binding(
            get: { viewModel.deleteErrorMessage != nil && router.path.last == .timeline(groupId: groupId) },
            set: { isPresented in
                if !isPresented {
                    viewModel.deleteErrorMessage = nil
                }
            }
        )
    }
}

// MARK: - 行

/// タイムラインの投稿 1 件の行（サムネイル・投稿者・投稿時刻・2 行までのキャプション・要件 8.6）
struct SoratomoTimelineRow: View {
    /// 表示する投稿
    let sky: SoratomoSky
    /// 投稿者の表示名（未設定・未取得は「ユーザー」）
    let authorName: String
    /// 投稿者のアイコンの URL（nil ならプレースホルダー）
    let authorPhotoURL: URL?
    /// 削除の途中か
    let isDeleting: Bool

    /// サムネイルの一辺（pt）
    private static let thumbnailSize: CGFloat = 72

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // アイコンは既存の画面と同じ部品（未設定はプレースホルダー・要件 8.8）
                    UserAvatarView(photoURL: authorPhotoURL?.absoluteString, size: 24)
                        .accessibilityHidden(true)
                    Text(authorName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(sky.createdAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.soratomoSecondary)
                }
                if let caption = sky.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.body)
                        .lineLimit(2)
                }
                if isDeleting {
                    Text("削除しています…")
                        .font(.caption)
                        .foregroundStyle(.soratomoSecondary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(isDeleting ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    /// サムネイル（メンバー判定を経る取得経路・要件 8.14）
    ///
    /// ⚠️ `.targetCache(SoratomoImageCache.cache(forStoragePath:))`（パスは provider と同じ）を必ず付け、
    ///    processor は付けない（付けると鍵が変わり、削除やサインアウトや抜けたときに消せなくなる）
    private var thumbnail: some View {
        KFImage(source: .provider(SoratomoStorageImageProvider(storagePath: sky.imagePaths.thumbnail)))
            .targetCache(SoratomoImageCache.cache(forStoragePath: sky.imagePaths.thumbnail))
            .placeholder {
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
            }
            .resizable()
            .scaledToFill()
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // VoiceOver の説明はキャプション、無ければ「{表示名}さんの空」（要件 16.5）
            .accessibilityElement()
            .accessibilityLabel(imageAccessibilityLabel)
            .accessibilityAddTraits(.isImage)
    }

    /// 投稿画像の VoiceOver の説明
    private var imageAccessibilityLabel: String {
        Self.imageAccessibilityLabel(caption: sky.caption, authorName: authorName)
    }

    /// 投稿画像の VoiceOver の説明を作る（14.3 の点検で直した・テストで固定する）
    ///
    /// 規則は投稿詳細（`SoratomoSkyDetailView.imageAccessibilityLabel`）と同じにする。
    /// キャプションは前後の空白を除かずに保存されうる（`sanitizeCaption` は改行だけを除く）ので、
    /// 空白だけのキャプションも「無い」として「{表示名}さんの空」にする（要件 16.5）。
    static func imageAccessibilityLabel(caption: String?, authorName: String) -> String {
        SoratomoSkyDetailView.imageAccessibilityLabel(caption: caption, displayName: authorName)
    }
}
