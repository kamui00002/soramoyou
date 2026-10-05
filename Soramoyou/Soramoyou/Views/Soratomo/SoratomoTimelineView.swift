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
    /// 投稿者の表示名とアイコン（容れ物越しには変化が伝わらないので、別に持つ）
    @ObservedObject private var profileStore: SoratomoProfileStore
    /// 通信の有無（オフラインの表示に使う）
    @ObservedObject private var network: NetworkStatusMonitor

    /// 投稿画面のシートを出しているか
    @State private var isComposing = false
    /// 削除の確認を出している投稿（nil なら出していない）
    @State private var skyPendingDeletion: SoratomoSky?

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

        // ViewModel には容れ物を渡さず、中身（protocol とクロージャ）を取り出して渡す
        let network = dependencies.network
        let skyLookup = dependencies.skyLookup
        _viewModel = StateObject(
            wrappedValue: SoratomoTimelineViewModel(
                groupId: groupId,
                groupService: dependencies.groupService,
                skyService: dependencies.skyService,
                imageStore: dependencies.imageStore,
                currentUid: dependencies.currentUid,
                isOnline: { network.isOnline },
                reportAccessible: { [weak router] id in router?.reportAccessible(groupId: id) },
                reportNotAccessible: { [weak router] id in router?.reportNotAccessible(groupId: id) },
                rememberSkies: { skies in skyLookup.remember(skies) },
                forgetSky: { groupId, skyId in skyLookup.forget(groupId: groupId, skyId: skyId) }
            )
        )
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
            .navigationTitle(viewModel.group?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    membersButton
                    inviteButton
                    composeButton
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
            .task {
                viewModel.start()
            }
            // 投稿者の表示名とアイコンを、まだ持っていない分だけ取りに行く
            .task(id: authorIds) {
                await profileStore.prefetch(uids: authorIds)
            }
            // 画面名の記録は根の画面（SoratomoRootView）がパスの変化で 1 回だけ行う（14.3 の点検で集約）
    }

    // MARK: - 中身

    /// 読み込みの状態ごとの中身
    @ViewBuilder
    private var content: some View {
        if !viewModel.skies.isEmpty {
            timelineList
        } else if viewModel.hasLoadedTimeline {
            emptyGuide
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
        // 削除の操作は投稿者本人にだけ出す（要件 8.15）。VoiceOver ではアクションとして読める
        .contextMenu {
            if viewModel.canDelete(sky) {
                Button(role: .destructive) {
                    skyPendingDeletion = sky
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .accessibilityLabel("この投稿を削除")
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

    /// 削除の失敗を出しているか（閉じたら文言を消す）
    private var isShowingDeleteError: Binding<Bool> {
        Binding(
            get: { viewModel.deleteErrorMessage != nil },
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
    /// ⚠️ `.targetCache(SoratomoImageCache.shared)` を必ず付け、processor は付けない
    ///    （付けると鍵が変わり、削除やサインアウトのときに消せなくなる）
    private var thumbnail: some View {
        KFImage(source: .provider(SoratomoStorageImageProvider(storagePath: sky.imagePaths.thumbnail)))
            .targetCache(SoratomoImageCache.shared)
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
