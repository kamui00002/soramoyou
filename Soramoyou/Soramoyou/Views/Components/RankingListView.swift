//
//  RankingListView.swift ⭐️
//  Soramoyou
//
//  ギャラリーの週間 / 月間ランキングの表示。
//  - 1 件目: 横幅いっぱいの大きなカード（王冠つきのメダル・金の枠とほのかなグロー）
//  - 2・3 件目: 2 列の正方形カード（銀・銅のメダル）
//  - 4 件目以降: 1 行 1 投稿の縦リスト（順位の数字・サムネ・投稿者・いいね数）
//
//  以前は通常と同じ 3 列グリッドに小さな順位バッジ（旧 RankingBadge）を重ねるだけで、
//  「画像が横並びで見づらい・上位が目立たない」という声があったため、専用の表示に作り直した。
//
//  ⚠️ メダルの色は「表示位置」ではなく `RankedPost.rank` で決める。
//     順位は競技方式（1, 2, 2, 4）なので、2 件目が同数 1 位なら金、4 件目が同数 3 位なら銅になる。
//  ⚠️ Xcode 27 は大きな body の型チェックが終わらなくなる前例（#123 / GalleryDetailView）があるため、
//     カード・行・メダル・写真を別 struct に分けて、1 つの body を小さく保つ。
//

import Kingfisher
import SwiftUI

// MARK: - RankingListView

/// ランキングの一覧（表彰台 ＋ 縦リスト）
///
/// 表示するデータ（順位・投稿者）は呼び出し側（GalleryView ← GalleryViewModel）から受け取るだけで、
/// この部品は通信しない。タップ・保存も呼び出し側のクロージャに任せる。
struct RankingListView: View {
    // MARK: - Properties

    /// 表示する順位付き投稿（`GalleryViewModel.rankingDisplayEntries`＝posts に残っている分だけ・順位順）
    let entries: [RankedPost]
    /// 投稿者（userId → 公開プロフィール）。取れていない人は「ユーザー」表示にする
    let authorsByUserId: [String: PublicProfile]
    /// タップしたとき（投稿詳細を開く）
    let onSelect: (Post) -> Void
    /// 長押しメニューの「写真に保存」
    let onSave: (Post) -> Void

    /// 表示幅の上限
    ///
    /// iPad では 1 件目のカードが横幅いっぱい × 4:3 だと画面を占領するほど大きくなるため、
    /// 一覧全体の幅に上限を付けて中央に寄せる（iPhone の幅では効かない）。
    private static let maxContentWidth: CGFloat = 640

    // MARK: - Body

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            // 1 件目: 大きなカード
            if let champion = entries.first {
                championSection(champion)
            }

            // 2・3 件目: 2 列の正方形カード
            if entries.count > 1 {
                runnerUpSection
            }

            // 4 件目以降: 縦リスト
            if entries.count > 3 {
                listSection
            }
        }
        .frame(maxWidth: Self.maxContentWidth)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.xs)
        // 幅の上限より画面が広いとき（iPad）は中央に置く
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    /// 1 件目のカード
    private func championSection(_ entry: RankedPost) -> some View {
        entryButton(entry) {
            RankingChampionCard(entry: entry, author: author(of: entry))
        }
    }

    /// 2・3 件目のカード（2 列）
    private var runnerUpSection: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            ForEach(entries.dropFirst().prefix(2)) { entry in
                entryButton(entry) {
                    RankingRunnerUpCard(entry: entry, author: author(of: entry))
                }
                .frame(maxWidth: .infinity)
            }

            // 2 件しかないときは右側を空けておく。
            // 空けないと 2 件目のカードが横幅いっぱいに広がり、1 件目より大きく見えてしまう。
            if entries.count == 2 {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    /// 4 件目以降の縦リスト
    ///
    /// 最大 30 件なので件数は多くないが、サムネイルの読み込みを画面に入ったものからにするため Lazy にする。
    private var listSection: some View {
        LazyVStack(spacing: DesignTokens.Spacing.sm) {
            ForEach(entries.dropFirst(3)) { entry in
                entryButton(entry) {
                    RankingListRow(entry: entry, author: author(of: entry))
                }
            }
        }
    }

    // MARK: - Helpers

    /// カード・行の共通の包み（タップで詳細・長押しで保存）
    ///
    /// 既存のギャラリーのセル（GalleryView.galleryCell）と同じ操作にそろえる。
    /// - タップ: `onSelect`（詳細シートを開く）
    /// - 長押し: 「写真に保存」メニュー
    /// - 見た目: `CardButtonStyle`（ScrollView 内でもスクロールと競合しない押し込みアニメーション）
    private func entryButton(
        _ entry: RankedPost,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Button {
            onSelect(entry.post)
        } label: {
            content()
                // VoiceOver では中の文字を 1 つずつ読ませず、「N位 名前 期間中のいいねn件」とまとめて読む
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    RankingDisplayText.accessibilityLabel(entry: entry, author: author(of: entry))
                )
        }
        .buttonStyle(CardButtonStyle())
        .contextMenu {
            Button {
                onSave(entry.post)
            } label: {
                Label("写真に保存", systemImage: "square.and.arrow.down")
            }
        }
    }

    /// 投稿者の公開プロフィール（未取得・取得失敗なら nil）
    private func author(of entry: RankedPost) -> PublicProfile? {
        authorsByUserId[entry.post.userId]
    }
}

// MARK: - 1 件目のカード

/// 1 件目の大きなカード（4:3・金の枠とグロー・王冠つきメダル）
struct RankingChampionCard: View {
    // MARK: - Properties

    let entry: RankedPost
    let author: PublicProfile?

    /// 順位に応じたメダル（1〜3 位以外は nil）
    private var medal: RankingMedal? { RankingMedal(rank: entry.rank) }

    // MARK: - Body

    var body: some View {
        // 横幅いっぱいに大きく出すので、サムネイル（最大 512px）ではなく原寸画像を使う
        // ⚠️ 枠（Color.clear）で先に 4:3 の大きさを決め、写真は overlay で重ねる。
        //    写真に直接 .aspectRatio を付けると、.fill で枠からはみ出した写真の大きさが
        //    そのままカードの大きさになり、画面より横に広がってヘッダーまで押し広げる（実機で発生）。
        Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                RankingPhoto(post: entry.post, prefersFullResolution: true)
            }
            .clipped()
            .overlay(alignment: .bottom) {
                bottomInfo
            }
            .overlay(alignment: .topLeading) {
                // 王冠は「1 位」の印なので rank == 1 のときだけ出す
                // （削除・ブロックで先頭が 2 位になった場合でも、王冠付きの金メダルにしない）
                RankingMedalBadge(rank: entry.rank, diameter: 56, showsCrown: entry.rank == 1)
                    .padding(DesignTokens.Spacing.md)
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
            .overlay(border)
            // 金（メダル色）のほのかなグロー。メダルが無い順位はふつうのカードの影にする
            .shadow(
                color: medal?.color.opacity(0.55) ?? DesignTokens.Shadow.card.color,
                radius: medal == nil ? DesignTokens.Shadow.card.radius : 16,
                x: 0,
                y: medal == nil ? DesignTokens.Shadow.card.y : 0
            )
    }

    // MARK: - Subviews

    /// 下部の情報（投稿者・場所 or キャプション・いいね数）
    ///
    /// 写真の明るさに関係なく白文字が読めるよう、黒→透明のグラデーションを敷く。
    private var bottomInfo: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.sm) {
            UserAvatarView(photoURL: author?.photoURL, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(RankingDisplayText.authorName(author))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    // 長い名前・大きな文字サイズでもレイアウトが崩れないよう 1 行に収める
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let subtitle = RankingDisplayText.subtitle(for: entry.post) {
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            RankingLikeLabel(
                count: entry.likeCount,
                font: .system(.title2, design: .rounded, weight: .heavy)
            )
        }
        .shadow(DesignTokens.Shadow.text)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, DesignTokens.Spacing.xl)
        .padding(.bottom, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(RankingDisplayText.bottomScrim)
    }

    /// 枠線（メダル色のグラデーション。メダルが無い順位はガラス風の細い線）
    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
        if let medal {
            shape.strokeBorder(medal.gradient, lineWidth: 3)
        } else {
            shape.strokeBorder(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
        }
    }
}

// MARK: - 2・3 件目のカード

/// 2・3 件目の正方形カード（銀・銅のメダル）
struct RankingRunnerUpCard: View {
    // MARK: - Properties

    let entry: RankedPost
    let author: PublicProfile?

    /// 順位に応じたメダル（同数で 1 位なら金になる）
    private var medal: RankingMedal? { RankingMedal(rank: entry.rank) }

    // MARK: - Body

    var body: some View {
        // 画面幅の半分弱なので、サムネイル（最大 512px）で足りる
        // 1 件目と同じ理由で、枠を先に正方形に決めてから写真を重ねる
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RankingPhoto(post: entry.post, prefersFullResolution: false)
            }
            .clipped()
            .overlay(alignment: .bottom) {
                bottomInfo
            }
            .overlay(alignment: .topLeading) {
                RankingMedalBadge(rank: entry.rank, diameter: 36)
                    .padding(DesignTokens.Spacing.sm)
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
            .overlay(border)
            .shadow(DesignTokens.Shadow.card)
    }

    // MARK: - Subviews

    /// 下部の情報（投稿者名・いいね数）
    private var bottomInfo: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text(RankingDisplayText.authorName(author))
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundColor(DesignTokens.Colors.textPrimary)
                // カード幅が狭いので、名前の方を縮めて・省略して いいね数 を必ず見せる
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)

            RankingLikeLabel(
                count: entry.likeCount,
                font: .system(.subheadline, design: .rounded, weight: .heavy)
            )
        }
        .shadow(DesignTokens.Shadow.text)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity)
        .background(RankingDisplayText.bottomScrim)
    }

    /// 枠線（メダル色のグラデーション）
    @ViewBuilder
    private var border: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
        if let medal {
            shape.strokeBorder(medal.gradient, lineWidth: 2)
        } else {
            shape.strokeBorder(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
        }
    }
}

// MARK: - 4 件目以降の行

/// 4 件目以降の 1 行（順位の数字・サムネ・投稿者・副題・いいね数）
struct RankingListRow: View {
    // MARK: - Properties

    let entry: RankedPost
    let author: PublicProfile?

    /// サムネイルの一辺
    private static let thumbnailSize: CGFloat = 72
    /// 順位の数字の幅（2 桁でも行ごとにサムネの位置がずれないよう固定する）
    private static let rankColumnWidth: CGFloat = 36

    // MARK: - Body

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            rankNumber

            RankingPhoto(post: entry.post, prefersFullResolution: false)
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md))

            texts

            likePill
        }
        .padding(DesignTokens.Spacing.sm)
        // 既存の一覧行（FollowListView など）と同じ、半透明のガラス風カードで 1 行ずつ区切る
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                .fill(.ultraThinMaterial.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.lg)
                .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
        )
    }

    // MARK: - Subviews

    /// 順位の数字
    ///
    /// 同数で 3 位以内の投稿が 4 件目以降に来た場合（例: 3 位が 3 件並ぶ）は、数字をメダル色にして
    /// 「表彰台と同じ順位」だと分かるようにする。
    @ViewBuilder
    private var rankNumber: some View {
        let text = Text("\(entry.rank)")
            .font(.system(.title2, design: .rounded, weight: .heavy))
        Group {
            if let medal = RankingMedal(rank: entry.rank) {
                text.foregroundStyle(medal.gradient)
            } else {
                text.foregroundColor(DesignTokens.Colors.textPrimary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(width: Self.rankColumnWidth)
        .shadow(DesignTokens.Shadow.text)
    }

    /// 投稿者名と副題（場所 or キャプション）
    private var texts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RankingDisplayText.authorName(author))
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundColor(DesignTokens.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if let subtitle = RankingDisplayText.subtitle(for: entry.post) {
                Text(subtitle)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        // 右端のいいね数ピルを押し出さないよう、残りの幅を名前側で使う
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 右端の「♥ n」ピル
    private var likePill: some View {
        RankingLikeLabel(
            count: entry.likeCount,
            font: .system(.subheadline, design: .rounded, weight: .bold)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.25)))
    }
}

// MARK: - 共通部品: 写真

/// ランキングのカード・行で使う写真（`.fill` で枠いっぱいに敷いて、はみ出しを切る）
///
/// 書き方は GalleryView の既存セル（GalleryGridItem / GalleryMosaicItem）にそろえている。
/// 大きさ・縦横比は呼び出し側の `.aspectRatio` / `.frame` で決める。
struct RankingPhoto: View {
    // MARK: - Properties

    let post: Post
    /// 原寸画像を使うか
    ///
    /// サムネイルは最大 512px（StorageService）なので、画面幅いっぱいのカードに出すとぼやける。
    /// 大きく出すカード（1 件目）だけ原寸を使い、読み込み中はサムネイルを先に見せる。
    var prefersFullResolution = false

    // MARK: - Body

    var body: some View {
        if let firstImage = post.images.first, let url = displayURL(for: firstImage) {
            KFImage(url)
                .placeholder {
                    placeholder(for: firstImage)
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            // 画像情報が無い・URL が壊れている投稿（旧データ等）は既存セルと同じ灰色の枠にする
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.gray)
                )
        }
    }

    // MARK: - Private

    /// 表示に使う URL（原寸 or サムネイル。サムネイルが無い・壊れている旧投稿は原寸に落とす）
    private func displayURL(for image: ImageInfo) -> URL? {
        if !prefersFullResolution, let thumbnail = image.thumbnail, let url = URL(string: thumbnail) {
            return url
        }
        return URL(string: image.url)
    }

    /// 読み込み中の表示
    ///
    /// 原寸を読むときは、ギャラリーで既にキャッシュされていることが多いサムネイルを先に出して
    /// 「灰色の大きな枠がしばらく続く」状態を避ける。
    @ViewBuilder
    private func placeholder(for image: ImageInfo) -> some View {
        if prefersFullResolution, let thumbnail = image.thumbnail, let url = URL(string: thumbnail) {
            KFImage(url)
                .placeholder {
                    loadingPlaceholder
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            loadingPlaceholder
        }
    }

    /// 既存セルと同じ「灰色の枠 ＋ くるくる」
    private var loadingPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .overlay(
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            )
    }
}

// MARK: - 共通部品: いいね数

/// 「♥ n」の表示（期間中に付いたいいね数。全期間の累計 likesCount ではない）
struct RankingLikeLabel: View {
    let count: Int
    let font: Font

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .foregroundColor(DesignTokens.Colors.softPink)
            Text("\(count)")
                .foregroundColor(DesignTokens.Colors.textPrimary)
        }
        .font(font)
        .lineLimit(1)
        // 名前より先に縮んだり省略されたりしないよう、いいね数は常に本来の大きさで出す
        .fixedSize()
    }
}

// MARK: - 共通部品: メダル

/// 順位のメダル（丸の中に順位。1 位のカードでは王冠も入れる）
struct RankingMedalBadge: View {
    // MARK: - Properties

    /// 順位（色はこの値で決める＝表示位置ではない）
    let rank: Int
    /// メダルの直径
    let diameter: CGFloat
    /// 王冠を入れるか（1 件目のカードで 1 位のときだけ）
    var showsCrown = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Circle()
                .fill(fillGradient)
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)

            VStack(spacing: 0) {
                if showsCrown {
                    Image(systemName: "crown.fill")
                        .font(.system(size: diameter * 0.28, weight: .bold))
                }
                Text("\(rank)")
                    .font(.system(size: diameter * (showsCrown ? 0.36 : 0.46), weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
            .padding(diameter * 0.12)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
        // 順位はカード全体の読み上げ（「N位 …」）に含めているので、メダル単体は読ませない
        .accessibilityHidden(true)
    }

    // MARK: - Private

    /// 1〜3 位は金・銀・銅、それ以外は半透明の黒（旧 RankingBadge と同じ扱い）
    private var fillGradient: LinearGradient {
        RankingMedal(rank: rank)?.gradient
            ?? LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
    }
}

// MARK: - メダルの色

/// 金・銀・銅（旧 RankingBadge の 3 色をそのまま移した）
enum RankingMedal {
    case gold
    case silver
    case bronze

    /// 順位からメダルを決める（1〜3 位以外は nil）
    ///
    /// ⚠️ 表示位置ではなく順位で決める。同数の 1 位が 2 件あれば 2 件とも金。
    init?(rank: Int) {
        switch rank {
        case 1: self = .gold
        case 2: self = .silver
        case 3: self = .bronze
        default: return nil
        }
    }

    /// 基本色
    var color: Color {
        switch self {
        case .gold: Color(red: 0.95, green: 0.75, blue: 0.20)
        case .silver: Color(red: 0.66, green: 0.70, blue: 0.76)
        case .bronze: Color(red: 0.80, green: 0.52, blue: 0.30)
        }
    }

    /// 明るい側の色（グラデーションの始点。金属の照り返しに見せるため）
    var highlightColor: Color {
        switch self {
        case .gold: Color(red: 1.00, green: 0.90, blue: 0.55)
        case .silver: Color(red: 0.90, green: 0.92, blue: 0.95)
        case .bronze: Color(red: 0.95, green: 0.72, blue: 0.52)
        }
    }

    /// メダル・枠線・順位の数字に使うグラデーション
    var gradient: LinearGradient {
        LinearGradient(
            colors: [highlightColor, color],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 表示用の文言

/// ランキング表示で使う文言・共通の見た目
enum RankingDisplayText {
    /// 投稿者名（未取得・取得失敗・空の名前は「ユーザー」）
    ///
    /// 他の画面（HomeView / FollowListView / CommentSection 等）と同じフォールバック文言にそろえる。
    static func authorName(_ profile: PublicProfile?) -> String {
        let name = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "ユーザー" : name
    }

    /// 副題（場所 → キャプションの順で、最初にあるもの）
    ///
    /// 場所は ランドマーク → 市区町村 → 都道府県 の順で、いちばん具体的なものを 1 つだけ出す。
    /// キャプションは改行をまたぐと 1 行表示で途中が切れて読みにくいため、改行を空白に置き換える。
    static func subtitle(for post: Post) -> String? {
        let placeCandidates = [post.location?.landmark, post.location?.city, post.location?.prefecture]
        if let place = placeCandidates.compactMap({ nonEmpty($0) }).first {
            return place
        }
        if let caption = nonEmpty(post.caption) {
            return caption.components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: " ")
        }
        return nil
    }

    /// VoiceOver の読み上げ（例: 「1位 そらさん 期間中のいいね17件」）
    static func accessibilityLabel(entry: RankedPost, author: PublicProfile?) -> String {
        "\(entry.rank)位 \(authorName(author)) 期間中のいいね\(entry.likeCount)件"
    }

    /// 写真の下部に敷く 黒→透明 のグラデーション（白文字を読めるようにする）
    static let bottomScrim = LinearGradient(
        colors: [Color.black.opacity(0), Color.black.opacity(0.65)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 前後の空白・改行を除いて、空なら nil
    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
