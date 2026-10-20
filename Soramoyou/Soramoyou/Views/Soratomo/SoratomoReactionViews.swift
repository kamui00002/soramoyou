//
//  SoratomoReactionViews.swift
//  Soramoyou
//
//  そらともの投稿へのリアクションの部品の画面 ⭐️
//  （soratomo-reactions 8.1・design.md の「リアクションの部品の画面」の節・
//   要件 1.2, 2.1, 2.2, 2.3, 3.2, 3.3, 3.4, 3.7, 3.8, 8.7, 13.1, 13.2, 13.3, 13.5, 15.6）
//
//  - 数の表示（SoratomoReactionSummaryView）・リアクションのメニュー（SoratomoReactionMenuButton）・
//    押した人の一覧のシート（SoratomoReactorsSheet）の 3 つ
//  - 部品は ViewModel を持たない。数と一覧は `SoratomoReactionViewModel.summary(for:server:)` が作った
//    `SoratomoReactionSummary` を、送っている間かは `isSending(_:)` の値を、引数で受け取る。
//    絵文字を選んだことは `onChoose` で知らせるだけで、`choose` を呼ぶのは画面（8.2 のタイムライン・8.3 の詳細）
//  - 一覧の表示名とアイコンは `SoratomoProfileStore` から出す。未設定・未取得はメンバー一覧と同じ代替
//    （名前は「ユーザー」・アイコンは `UserAvatarView` のプレースホルダー）。uid から作った文字は使わない（3.3・3.4）
//  - ⚠️ 押した人の一覧は新しい画面にしない（ルーターの行き先と、画面名の計測 `logScreen` を足さない・15.6）。
//     開いたことの記録（`soratomo_reactions_viewed`）は、シートを出す詳細（8.3）が `didOpenReactors(count:)` で行う
//  - ⚠️ VoiceOver では絵文字の字そのものを読ませない。読み上げは日本語名（`spokenName`）で組み立てる（13.3）
//

import SwiftUI

// MARK: - 数の表示

/// リアクションの数の表示（絵文字と数のカプセルを、絵文字の並び順に並べる・押せない）
///
/// - 自分が付けた絵文字のカプセルは、色付きの枠と太字で見分けられるようにする（2.2）
/// - リアクションが 1 つも無ければ何も出さない（2.3）
/// - VoiceOver では `summary.accessibilityLabel` の 1 つの要素（13.2）
/// - タイムラインではカードのボタンのラベルの中に置く（押すと詳細へ進む・1.8）。この部品そのものは操作を持たない
struct SoratomoReactionSummaryView: View {
    // MARK: - Properties

    /// 画面に出す数と一覧（`SoratomoReactionViewModel.summary(for:server:)` の値）
    let summary: SoratomoReactionSummary

    /// 自分の絵文字の枠の色（グループのアイコンの濃い青と同じ。空の上でもカードの上でも見える濃さ）
    static let myKindColor = Color(red: 0.16, green: 0.33, blue: 0.72)

    // MARK: - Body

    var body: some View {
        if summary.total > 0 {
            // 7 つ並んでも、文字を大きくする設定でも、はみ出さずに折り返す（既存のハッシュタグと同じ FlowLayout）
            FlowLayout(spacing: 6) {
                ForEach(summary.counts, id: \.kind) { count in
                    capsule(count, isMine: count.kind == summary.myKind)
                }
            }
            // 絵文字の字を読ませず、「リアクション、夕焼け3人…」の 1 つの文で読む
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.accessibilityLabel)
        }
    }

    // MARK: - 部品

    /// 絵文字 1 つ分のカプセル（絵文字と数）
    /// - Parameters:
    ///   - count: 絵文字と数
    ///   - isMine: 自分が付けた絵文字か
    private func capsule(_ count: SoratomoReactionSummary.Count, isMine: Bool) -> some View {
        HStack(spacing: 4) {
            Text(count.kind.emoji)
            Text("\(count.count)")
                .monospacedDigit()
                // 色だけに頼らず、太さでも自分の分を見分けられるようにする
                .fontWeight(isMine ? .bold : .regular)
        }
        .font(.subheadline)
        .foregroundStyle(Color.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(isMine ? Self.myKindColor.opacity(0.14) : Color.black.opacity(0.06))
        )
        .overlay(
            Capsule().stroke(isMine ? Self.myKindColor : Color.clear, lineWidth: 1.5)
        )
    }
}

// MARK: - リアクションのメニュー

/// リアクションを付ける・外す・選び直すメニュー（7 つの絵文字から選ぶ）
///
/// - 項目は「{絵文字} {日本語名}」。いまの自分の絵文字に `checkmark` を付ける（1.2）
/// - ボタンの見た目は、付けていなければ `face.smiling` の記号、付けていればその絵文字。押せる範囲は 44pt 四方以上
/// - 送っている間は無効にする（1.10）
/// - 同じ絵文字を選び直すと外れるかどうかは、受け取った側（ViewModel の `choose`）が決める。この部品は選んだ絵文字を渡すだけ
/// - ⚠️ 自分の投稿に出さない判定（`canReact(to:)`・1.6）は、置く側の画面が行う
struct SoratomoReactionMenuButton: View {
    // MARK: - Properties

    /// 画面に出す数と一覧（いまの自分の絵文字 `myKind` を使う）
    let summary: SoratomoReactionSummary
    /// この投稿の要求を送っている間か（`SoratomoReactionViewModel.isSending(_:)` の値）
    let isSending: Bool
    /// 絵文字を選んだときに呼ぶ（呼び出し側が `Task` の中で `choose` を呼ぶ）
    let onChoose: (SoratomoReactionKind) -> Void

    /// 押せる範囲の一辺の最小（pt・HIG の 44pt）
    private static let minTapSize: CGFloat = 44

    // MARK: - Body

    var body: some View {
        Menu {
            // 並びは絵文字の並び順（7 つ）。enum は Identifiable でないので、値そのものを ID にする
            ForEach(SoratomoReactionKind.allCases, id: \.self) { kind in
                menuItem(kind)
            }
        } label: {
            menuLabel
                .frame(minWidth: Self.minTapSize, minHeight: Self.minTapSize)
                // 記号の外の余白も押せるようにする（タイムラインでは、カードの右下に重ねて置くため）
                .contentShape(Rectangle())
                // 送っている間は押せないことが見た目でも分かるようにする（絵文字は自分の色で描かれるので、
                // `.disabled` の灰色にならない。濃さはフォロー一覧のボタン `FollowActionButton` と同じ 0.5）
                .opacity(isSending ? 0.5 : 1)
        }
        .disabled(isSending)
        .accessibilityLabel(Self.accessibilityLabel(myKind: summary.myKind))
        .accessibilityHint("同じ絵文字をもう一度選ぶと外れます")
    }

    // MARK: - 部品

    /// ボタンの見た目（付けていなければ `face.smiling`、付けていればその絵文字）
    @ViewBuilder
    private var menuLabel: some View {
        if let myKind = summary.myKind {
            Text(myKind.emoji)
                .font(.title3)
        } else {
            Image(systemName: "face.smiling")
                .font(.title3)
                .foregroundStyle(.soratomoSecondary)
        }
    }

    /// メニューの 1 項目（「{絵文字} {日本語名}」・いまの絵文字に `checkmark`）
    /// - Parameter kind: 項目の絵文字
    private func menuItem(_ kind: SoratomoReactionKind) -> some View {
        let isCurrent = kind == summary.myKind
        // 文字列の値として渡す（翻訳の鍵にしない・絵文字と日本語名をそのまま出す）
        let title = "\(kind.emoji) \(kind.spokenName)"
        return Button {
            onChoose(kind)
        } label: {
            if isCurrent {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        // VoiceOver では絵文字の字を読ませず、日本語名で読む。いまの絵文字は「選択中」と読む（13.1・13.3）
        .accessibilityLabel(kind.spokenName)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: - 純関数

    /// メニューのボタンの VoiceOver のラベル（13.1）
    /// - Parameter myKind: いまの自分の絵文字（付けていなければ nil）
    /// - Returns: 「リアクションを付ける」か「リアクションを変える。いまは{日本語名}」
    static func accessibilityLabel(myKind: SoratomoReactionKind?) -> String {
        guard let myKind else { return "リアクションを付ける" }
        return "リアクションを変える。いまは\(myKind.spokenName)"
    }
}

// MARK: - 押した人の一覧

/// 押した人の一覧のシート（3.1）
///
/// - 行はアイコン・表示名・その人の絵文字。表示名とアイコンは `SoratomoProfileStore` から出し、
///   未設定・未取得はメンバー一覧と同じ代替にする（3.2〜3.4）。開いたとき（一覧の人が変わったときも）に `prefetch` する
/// - ほかの人の分を外す・変える操作は置かない（表示だけ・3.7）
/// - 中身は呼び出し側（詳細）が持っているリアクション（監視の最新か、タイムラインの覚え）から作った行を受け取る。
///   通信できなくても、以前に読み込んだ分を出す
/// - 出し分け: 開いている間に投稿が消えた・グループから外れた（`isUnavailable`）→「この投稿は表示できなくなりました」（8.7）、
///   行が 1 件も無い →「リアクションを読み込めませんでした」（3.8）、それ以外 → 一覧
/// - ⚠️ この引数の形では「0 件」と「読めていない」を見分けられない。詳細は 1 人以上のときだけ一覧の入口を出す
///    （design.md）ので、開いた後に行が 0 件なのは「読めていない」として扱う
/// - ⚠️ 新しい画面にしない（ルーターの行き先・画面名の計測を足さない・15.6）。閉じるのは右上の「閉じる」と下へのスワイプ
struct SoratomoReactorsSheet: View {
    // MARK: - Properties

    /// 一覧の行（`SoratomoReactionSummary.reactors`・新しい順）
    let entries: [SoratomoReactorEntry]
    /// 開いている間に投稿が消えた・グループから外れたか
    let isUnavailable: Bool

    /// 表示名とアイコンの保持（取れた時点で行を描き直すため監視する）
    @ObservedObject private var profileStore: SoratomoProfileStore
    /// シートを閉じる
    @Environment(\.dismiss) private var dismiss

    // MARK: - Init

    /// - Parameters:
    ///   - entries: 一覧の行（`SoratomoReactionSummary.reactors`）
    ///   - isUnavailable: 開いている間に投稿が消えた・グループから外れたか
    ///   - profileStore: 表示名とアイコンの保持（本番は `SoratomoDependencies.profileStore`）
    init(entries: [SoratomoReactorEntry], isUnavailable: Bool, profileStore: SoratomoProfileStore) {
        self.entries = entries
        self.isUnavailable = isUnavailable
        _profileStore = ObservedObject(wrappedValue: profileStore)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            content
                .soratomoSkyBackground()
                .navigationTitle(Self.title(entryCount: entries.count, isShowingList: isShowingList))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // 右上（iOS 16 でも使える置き場所。投稿詳細の「…」と同じ書き方）
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("閉じる") {
                            dismiss()
                        }
                        .accessibilityLabel("リアクションの一覧を閉じる")
                    }
                }
        }
        // 行の人の表示名とアイコンを取りに行く（取得済みの uid は取りに行かないので、人が変わるたびに呼んでよい）
        .task(id: reactorUids) {
            guard isShowingList else { return }
            await profileStore.prefetch(uids: reactorUids)
        }
    }

    // MARK: - 中身

    /// 一覧を出すか（投稿を表示できて、行が 1 件以上ある）
    private var isShowingList: Bool {
        !isUnavailable && !entries.isEmpty
    }

    /// 行の人の uid の集合
    private var reactorUids: Set<String> {
        Set(entries.map(\.id))
    }

    /// 状態ごとの中身
    @ViewBuilder
    private var content: some View {
        if isUnavailable {
            // 開いている間に消えた・グループから外れた（8.7）。消えた投稿のリアクションは出さない（8.6）
            messageView("この投稿は表示できなくなりました", systemImage: "photo")
        } else if entries.isEmpty {
            // 監視の最新もタイムラインの覚えも無い（3.8）
            messageView("リアクションを読み込めませんでした", systemImage: "exclamationmark.circle")
        } else {
            List(entries) { entry in
                reactorRow(entry)
                    .soratomoClearRowBackground()
            }
            .listStyle(.plain)
        }
    }

    /// 1 人分の行（アイコン・表示名・絵文字。メンバー一覧の行と同じ部品）
    /// - Parameter entry: 一覧の 1 行
    private func reactorRow(_ entry: SoratomoReactorEntry) -> some View {
        let displayName = profileStore.displayName(for: entry.id)
        return HStack(spacing: 12) {
            // アイコン（写真が無い・取れていない間はプレースホルダー）
            UserAvatarView(photoURL: profileStore.photoURL(for: entry.id)?.absoluteString)
                .accessibilityHidden(true)

            Text(displayName)
                .font(.body)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(entry.kind.emoji)
                .font(.title3)
        }
        .padding(.vertical, 4)
        // メンバー一覧は `.combine` だが、ここでは絵文字の字を読ませないよう、日本語名で 1 つの文にする（13.5）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.rowAccessibilityLabel(displayName: displayName, kind: entry.kind))
    }

    /// 一覧の代わりに出す文（投稿詳細の「表示できません」と同じ形）
    /// - Parameters:
    ///   - message: 出す文
    ///   - systemImage: 文の上の記号
    private func messageView(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.soratomoSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 純関数

    /// シートの題
    ///
    /// 一覧を出しているときは「リアクション（{人数}人）」。一覧の代わりの文を出しているときは人数を出さない
    /// （消えた投稿の数を出さない・8.6。読めていないのに「0人」と言い切らない・3.8）
    /// - Parameters:
    ///   - entryCount: 一覧の人数
    ///   - isShowingList: 一覧を出しているか
    /// - Returns: シートの題
    static func title(entryCount: Int, isShowingList: Bool) -> String {
        isShowingList ? "リアクション（\(entryCount)人）" : "リアクション"
    }

    /// 一覧の行の VoiceOver の読み上げ（13.5）
    /// - Parameters:
    ///   - displayName: 表示名（`SoratomoProfileStore.displayName(for:)` の値・未設定と未取得は「ユーザー」）
    ///   - kind: その人の絵文字
    /// - Returns: 「{表示名}、{日本語名}」
    static func rowAccessibilityLabel(displayName: String, kind: SoratomoReactionKind) -> String {
        "\(displayName)、\(kind.spokenName)"
    }
}

// MARK: - プレビュー

/// プレビュー用の公開プロフィールの取得口（通信しない）
///
/// - `preview-sora`: 表示名だけある（写真は無い）→「そら」とプレースホルダー
/// - `preview-blank`: 表示名が空白だけ → 未設定の代替（「ユーザー」とプレースホルダー）
/// - それ以外: 取れない（投げる）→ 未取得の代替（「ユーザー」とプレースホルダー）
private struct SoratomoReactionPreviewFetcher: SoratomoProfileFetcher {
    func fetchPublicProfile(userId: String) async throws -> PublicProfile {
        switch userId {
        case "preview-sora":
            PublicProfile(id: userId, displayName: "そら")
        case "preview-blank":
            PublicProfile(id: userId, displayName: "   ")
        default:
            throw SoratomoError.unknown
        }
    }
}

/// プレビュー用のリアクション（自分は夕焼け・ほか 3 人）
private let soratomoReactionPreviewReactions = SoratomoReactions(byUser: [
    "preview-me": SoratomoReaction(kind: .sunset, reactedAt: Date(timeIntervalSince1970: 1_790_000_300)),
    "preview-sora": SoratomoReaction(kind: .sunset, reactedAt: Date(timeIntervalSince1970: 1_790_000_200)),
    "preview-blank": SoratomoReaction(kind: .rainbow, reactedAt: Date(timeIntervalSince1970: 1_790_000_100)),
    "preview-missing": SoratomoReaction(kind: .blueHeart, reactedAt: nil),
])

#Preview("0件") {
    // 数は何も出さず、付ける操作（face.smiling）だけが出る（2.3）
    let summary = SoratomoReactionSummary.make(
        reactions: .empty,
        myUid: "preview-me",
        myOverride: nil,
        blockedUserIds: []
    )
    HStack {
        SoratomoReactionSummaryView(summary: summary)
        Spacer()
        SoratomoReactionMenuButton(summary: summary, isSending: false, onChoose: { _ in })
    }
    .padding()
    .soratomoCard()
    .padding()
    .soratomoSkyBackground()
}

#Preview("自分の印あり") {
    // 自分の夕焼けのカプセルが、色付きの枠と太字になる（2.2）。下の行は送っている間（無効）
    let summary = SoratomoReactionSummary.make(
        reactions: soratomoReactionPreviewReactions,
        myUid: "preview-me",
        myOverride: nil,
        blockedUserIds: []
    )
    VStack(spacing: 16) {
        HStack(alignment: .bottom) {
            SoratomoReactionSummaryView(summary: summary)
            SoratomoReactionMenuButton(summary: summary, isSending: false, onChoose: { _ in })
        }
        HStack(alignment: .bottom) {
            SoratomoReactionSummaryView(summary: summary)
            SoratomoReactionMenuButton(summary: summary, isSending: true, onChoose: { _ in })
        }
    }
    .padding()
    .soratomoCard()
    .padding()
    .soratomoSkyBackground()
}

#Preview("一覧の代替表示") {
    // 「そら」は名前だけ、空白だけの人と取れない人は「ユーザー」とプレースホルダー（3.4）
    let summary = SoratomoReactionSummary.make(
        reactions: soratomoReactionPreviewReactions,
        myUid: "preview-me",
        myOverride: nil,
        blockedUserIds: []
    )
    SoratomoReactorsSheet(
        entries: summary.reactors,
        isUnavailable: false,
        profileStore: SoratomoProfileStore(fetcher: SoratomoReactionPreviewFetcher())
    )
}

#Preview("一覧（読み込めない）") {
    SoratomoReactorsSheet(
        entries: [],
        isUnavailable: false,
        profileStore: SoratomoProfileStore(fetcher: SoratomoReactionPreviewFetcher())
    )
}

#Preview("一覧（表示できない）") {
    SoratomoReactorsSheet(
        entries: [SoratomoReactorEntry(id: "preview-sora", kind: .cloud, reactedAt: nil)],
        isUnavailable: true,
        profileStore: SoratomoProfileStore(fetcher: SoratomoReactionPreviewFetcher())
    )
}
