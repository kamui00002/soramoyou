//
//  SoratomoGroupListView.swift
//  Soramoyou
//
//  そらとものグループ一覧 ⭐️
//  （tasks 13.1・design.md の SoratomoGroupListView・ViewModel・要件 5.1〜5.6・14.5・16.4）
//
//  - 所属グループを最新の活動の新しい順に並べ、各行にグループ名とメンバー数を出す。選ぶとタイムラインへ進む
//  - 「グループを作る」と「招待コードで参加」の 2 つの操作を常に出す。グループが無い間は、始め方の案内を出す
//  - 作成と参加のフォーム（13.2・13.3 の担当の `SoratomoGroupFormView`）は、ここからシートで出す
//

import SwiftUI

/// そらとものグループ一覧
struct SoratomoGroupListView: View {
    // MARK: - Properties

    /// そらともへの遷移を決めるルーター
    @ObservedObject var router: SoratomoRouter
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    /// 一覧の ViewModel
    @StateObject private var viewModel: SoratomoGroupListViewModel

    /// 出しているフォーム（作成か参加。nil なら出していない）
    @State private var formMode: SoratomoGroupFormMode?

    /// 文字の大きさの設定（大きな文字のときはカードの中の並べ方を変える）
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // MARK: - Init

    /// - Parameters:
    ///   - router: そらともへの遷移を決めるルーター
    ///   - dependencies: サービスの容れ物
    init(router: SoratomoRouter, dependencies: SoratomoDependencies) {
        self.router = router
        self.dependencies = dependencies
        _viewModel = StateObject(
            wrappedValue: SoratomoGroupListViewModel(
                groupService: dependencies.groupService,
                currentUid: dependencies.currentUid,
                // パスが空 = 入口から開いた。通知から開いたとき（パスにタイムラインがある）は soratomo_opened を記録しない
                logsOpened: router.path.isEmpty
            )
        )
    }

    // MARK: - Body

    var body: some View {
        content
            .navigationTitle("そらとも")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        router.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("そらともを閉じる")
                }
            }
            // 作成と参加の 2 つの操作は、一覧の状態に関わらず常に下に出す（要件 5.5）
            .modifier(SoratomoBottomActionBar(bar: actionButtons))
            .sheet(item: $formMode) { mode in
                SoratomoGroupFormView(
                    mode: mode,
                    dependencies: dependencies,
                    onCompleted: { newPath in
                        // フォームが決めた行き先へ進む（作成 → タイムラインの上に招待、参加 → タイムライン）
                        formMode = nil
                        router.path = newPath
                        Task { await viewModel.load() }
                    },
                    onCancel: {
                        formMode = nil
                    }
                )
            }
            .task {
                await viewModel.load()
            }
            // タイムラインなどから一覧へ戻ったら読み直す（活動の順とメンバー数が変わっているかもしれないため）
            .onChange(of: router.path.isEmpty) { isEmpty in
                guard isEmpty else { return }
                Task { await viewModel.load() }
            }
            // 画面名の記録は根の画面（SoratomoRootView）がパスの変化で 1 回だけ行う（14.3 の点検で集約）
    }

    // MARK: - 中身

    /// 読み込みの状態ごとの中身
    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(groups) where groups.isEmpty:
            emptyGuide
        case let .loaded(groups):
            groupList(groups)
        case .error:
            errorView
        }
    }

    /// グループの一覧（1 グループ = 1 枚のガラスのカード。選ぶとタイムラインへ進む）
    private func groupList(_ groups: [SoratomoGroup]) -> some View {
        List(groups) { group in
            groupCard(group)
                .soratomoCardRow()
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.load()
        }
    }

    /// グループ 1 つのカード（頭文字のアイコン・グループ名・メンバー数・最後に空が届いた時刻）
    ///
    /// `NavigationLink` でなく `Button` にしている: List の中の NavigationLink は「>」を行の外側（カードの外）に描くため。
    /// 行き先はルーターのパスに足す（タイムラインの投稿の行と同じ形）。「>」はカードの中に自分で描く
    private func groupCard(_ group: SoratomoGroup) -> some View {
        Button {
            router.path.append(.timeline(groupId: group.id))
        } label: {
            HStack(spacing: 12) {
                SoratomoGroupIcon(name: group.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Text("\(group.memberCount)人")
                        .font(.caption)
                        .foregroundStyle(.soratomoSecondary)
                    // 大きな文字の設定では右に置くと名前も時刻も切れるので、名前の下に回す（2026-10-05 のスクショ）
                    if dynamicTypeSize.isAccessibilitySize {
                        lastSkyLabel(for: group)
                    }
                }
                Spacer(minLength: 8)
                if !dynamicTypeSize.isAccessibilitySize {
                    lastSkyLabel(for: group)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.soratomoSecondary)
            }
            .padding(16)
            // カードの余白をタップしても開けるように、カード全体を押せる範囲にする
            .contentShape(SoratomoCardSurface.shape)
        }
        .buttonStyle(.plain)
        .soratomoCard()
        // VoiceOver では「グループ名、N人、最後の空は5分前」と読む（アイコンと「>」は飾りなので読まない）
        .accessibilityLabel(Self.cardAccessibilityLabel(for: group))
        .accessibilityHint("タイムラインを開きます")
    }

    /// 「最後に空が届いた時刻」の文字（例「5分前」「まだ空なし」）
    private func lastSkyLabel(for group: SoratomoGroup) -> some View {
        Text(Self.lastSkyText(for: group))
            .font(.caption)
            .foregroundStyle(.soratomoSecondary)
            .lineLimit(1)
    }

    /// グループが無い間の案内（要件 5.4）
    private var emptyGuide: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("まだグループがありません")
                .font(.headline)
            Text("グループを作るか、招待コードで参加して始めましょう")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 読み込みの失敗（固定の文言と、読み直しの操作）
    private var errorView: some View {
        VStack(spacing: 12) {
            Text(viewModel.errorMessage ?? SoratomoError.unknown.userMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("もう一度読み込む") {
                Task { await viewModel.load() }
            }
            .accessibilityHint("グループの一覧を読み直します")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 「グループを作る」と「招待コードで参加」の 2 つの操作
    ///
    /// 「招待コードで参加」はアイコンつきで横に並べると幅が足りず、2 行に折れていた（2026-10-05 のスクショ）。
    /// 文言は変えずに、入る形を上から順に試す: アイコンつきで横並び → 文字だけで横並び → 縦並び（大きな文字の設定など）
    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            actionButtonRow(vertical: false, showsIcon: true)
            actionButtonRow(vertical: false, showsIcon: false)
            actionButtonRow(vertical: true, showsIcon: true)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 2 つの操作を 1 列（横か縦）に並べる
    /// - Parameters:
    ///   - vertical: 縦に並べるか
    ///   - showsIcon: アイコンを付けるか
    private func actionButtonRow(vertical: Bool, showsIcon: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Button {
                formMode = .create
            } label: {
                actionLabel("グループを作る", systemImage: "plus", showsIcon: showsIcon, wraps: vertical)
            }
            .modifier(SoratomoActionButtonStyle(isProminent: true))
            .accessibilityLabel("グループを作る")

            Button {
                formMode = .join
            } label: {
                actionLabel("招待コードで参加", systemImage: "ticket", showsIcon: showsIcon, wraps: vertical)
            }
            .modifier(SoratomoActionButtonStyle(isProminent: false))
            .accessibilityLabel("招待コードで参加")
        }
    }

    /// 操作のボタンの文字（横並びのときは 1 行に収める。縦並びのときだけ折り返してよい）
    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String, showsIcon: Bool, wraps: Bool) -> some View {
        Group {
            if showsIcon {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .lineLimit(wraps ? nil : 1)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 補助

    /// 一度でも空が投稿されたグループか
    ///
    /// 作成のときは `createdAt` と `lastActivityAt` に同じサーバーの時刻が入り、投稿のトリガーだけが
    /// `lastActivityAt` を投稿の時刻へ進める（functions/soratomoStore.js・soratomo.js）。
    /// ⚠️ 削除しても `lastActivityAt` は戻らないので、全部消したグループも「投稿あり」になる（既知・許容）
    static func hasSky(_ group: SoratomoGroup) -> Bool {
        group.lastActivityAt > group.createdAt
    }

    /// カードの右に出す「最後に空が届いた時刻」の文字（例「5分前」「昨日」。投稿が無ければ「まだ空なし」）
    ///
    /// 一覧を読み直したとき（開いたとき・戻ったとき・引き下げたとき）にだけ作り直す（時計に合わせて動かしはしない）
    /// - Parameters:
    ///   - group: グループ
    ///   - now: いまの時刻（テストで固定するため）
    ///   - locale: 言語と地域（既定は日本語。テストで固定するため）
    ///
    /// ⚠️ 既定を `.current` にしてはいけない。アプリは日本語のローカライズを持たない
    /// （pbxproj の developmentRegion = en・.lproj / String Catalog なし）ので、`Locale.current` の言語は
    /// 端末を日本語にしても英語になり「8 hours ago」と出る（2026-10-06）。
    /// 日付の文字を作るほかの画面（PostInfoView・DraftsView・ShareCardView）と同じく ja_JP を明示する
    static func lastSkyText(for group: SoratomoGroup, now: Date = Date(), locale: Locale = Locale(identifier: "ja_JP")) -> String {
        guard hasSky(group) else { return "まだ空なし" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        // 「1日前」でなく「昨日」のように言う
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: group.lastActivityAt, relativeTo: now)
    }

    /// カードの VoiceOver の読み上げ（例「空、2人、最後の空は5分前」「空、2人、まだ空なし」）
    /// - Parameters:
    ///   - group: グループ
    ///   - now: いまの時刻（テストで固定するため）
    ///   - locale: 言語と地域（既定は日本語。理由は `lastSkyText` の注記。テストで固定するため）
    static func cardAccessibilityLabel(for group: SoratomoGroup, now: Date = Date(), locale: Locale = Locale(identifier: "ja_JP")) -> String {
        let lastSky = lastSkyText(for: group, now: now, locale: locale)
        let activity = hasSky(group) ? "最後の空は\(lastSky)" : lastSky
        return "\(group.name)、\(group.memberCount)人、\(activity)"
    }
}

// MARK: - 下の操作の置き方

/// 「グループを作る」「招待コードで参加」のボタンの見た目
/// （iOS 26 以上は本物のガラスのボタン、それより前は今までの普通のボタン）
private struct SoratomoActionButtonStyle: ViewModifier {
    /// 目立たせる方（作る）か
    let isProminent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if isProminent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// 下の操作を画面の下に置く
///
/// - iOS 26 以上: 帯を付けずにガラスのボタンだけを置く。下に潜るカードは画面の端でぼかす（`safeAreaBar`）
/// - iOS 26 未満: 今までどおり、帯（`.bar`）の上にボタンを置く
private struct SoratomoBottomActionBar<Bar: View>: ViewModifier {
    /// 下に置くもの
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) {
                bar
            }
        } else {
            content.safeAreaInset(edge: .bottom) {
                bar.background(.bar)
            }
        }
    }
}
