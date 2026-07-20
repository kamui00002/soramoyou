//
//  SkyCalendarDiaryView.swift
//  Soramoyou
//
//  空カレンダー日記: 月表示カレンダーの日セルに投稿サムネイルを表示し、
//  「空白の日を埋めたい」動機と振り返り習慣を作る（継続利用の本丸）。
//  プロフィール画面の「空図鑑を見る」導線の直下から開く。
//
//  グリッドレイアウト・日付計算は MonthCalendarGridView を共有し、
//  ストリークカレンダー（SkyStreakCalendarView）と重複実装しない ⭐️。
//

import SwiftUI
import Kingfisher

/// 背景グラデーション（アプリ本体・空図鑑と同じ空の配色）。
/// SkyCalendarDiaryView と DayPostsListView の両方から使う（重複定義しない ⭐️）。
private let skyGradient = LinearGradient(
    colors: [
        Color(red: 0.68, green: 0.85, blue: 0.90),
        Color(red: 0.53, green: 0.81, blue: 0.98),
        Color(red: 0.39, green: 0.58, blue: 0.93)
    ],
    startPoint: .top,
    endPoint: .bottom
)

struct SkyCalendarDiaryView: View {
    let userId: String

    @StateObject private var viewModel = CalendarDiaryViewModel()
    @Environment(\.dismiss) private var dismiss

    /// いま表示中の月（空状態の判定に使う。MonthCalendarGridView の onMonthChange から更新）
    @State private var displayedMonth = Date()

    /// サムネイル用日セルの高さ（ストリークカレンダーの点マーク(30)より大きめに）
    private let cellHeight: CGFloat = 44

    var body: some View {
        NavigationView {
            ZStack {
                skyGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("空カレンダー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .alert("エラー", isPresented: Binding(errorMessage: $viewModel.errorMessage)) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .task {
            // 計装: sheet 表示時に1回（読み込み完了を待たず、表示された事実を記録する）
            LoggingService.shared.logEvent("sky_calendar_viewed")
            await viewModel.load(userId: userId)
        }
    }

    /// ガラスカードの共通スタイル（SkyZukanView と同じ .ultraThinMaterial）
    @ViewBuilder
    private func glassCard<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(DesignTokens.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
            )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .tint(.white)
        } else {
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.lg) {
                    introSection
                    glassCard {
                        MonthCalendarGridView(cellHeight: cellHeight, onMonthChange: { displayedMonth = $0 }) { day, monthStart, calendar in
                            dayCell(day: day, monthStart: monthStart, calendar: calendar)
                        }
                    }
                    if isDisplayedMonthEmpty {
                        emptyMonthSection
                    }
                }
                .padding(DesignTokens.Spacing.screenMargin)
            }
        }
    }

    // MARK: - 使い方ガイド

    @ViewBuilder
    private var introSection: some View {
        glassCard {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundColor(DesignTokens.Colors.sunsetOrange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("空の日記")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                    Text("投稿した空が、撮った日のマスに写真で並びます。日付をタップするとその日の投稿を振り返れます。")
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 月が空のときの前向きな空状態

    @ViewBuilder
    private var emptyMonthSection: some View {
        glassCard {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "cloud.sun")
                    .font(.largeTitle)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                Text("この月はまだ空がありません")
                    .font(.headline)
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                Text("今日の空を投稿してみましょう。")
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// いま表示中の月に投稿が1件も無いか
    /// - Note: グリッド描画・グルーピングと同じグレゴリオ暦で年/月を抽出する。`Calendar.current` を
    ///   使うと和暦端末で年がズレ、投稿があるのに空バナーが出ない矛盾を起こす（バグ修正の回帰防止）。
    private var isDisplayedMonthEmpty: Bool {
        let comps = Calendar.soramoyouGregorian.dateComponents([.year, .month], from: displayedMonth)
        guard let year = comps.year, let month = comps.month else { return true }
        return !viewModel.hasPosts(year: year, month: month)
    }

    // MARK: - 日セル（投稿サムネイル表示）

    @ViewBuilder
    private func dayCell(day: Int, monthStart: Date, calendar: Calendar) -> some View {
        let comps = calendar.dateComponents([.year, .month], from: monthStart)
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        let key = SkyStreakDay(year: year, month: month, day: day)
        let postsForDay = viewModel.posts(on: key)
        let today = calendar.isSameDayAsToday(day: day, monthStart: monthStart)

        if postsForDay.isEmpty {
            dayCellBody(day: day, postsForDay: postsForDay, today: today)
        } else {
            NavigationLink {
                DayPostsListView(day: key, posts: postsForDay)
            } label: {
                dayCellBody(day: day, postsForDay: postsForDay, today: today)
            }
            .buttonStyle(.plain)
        }
    }

    /// 日セルの見た目（投稿があればサムネイル、無ければ薄い枠＋日付のみ）
    private func dayCellBody(day: Int, postsForDay: [Post], today: Bool) -> some View {
        let thumbnailURL = postsForDay.first.flatMap { post -> URL? in
            guard let urlString = post.images.first?.thumbnail ?? post.images.first?.url else { return nil }
            return URL(string: urlString)
        }

        return ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .fill(Color.white.opacity(thumbnailURL == nil ? 0.10 : 0.0))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                        .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: thumbnailURL == nil ? 1 : 0)
                )

            if let url = thumbnailURL {
                KFImage(url)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Text("\(day)")
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
        }
        .frame(height: cellHeight)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))
        .overlay(alignment: .topLeading) {
            if thumbnailURL != nil {
                Text("\(day)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if postsForDay.count > 1 {
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.4)))
                    .padding(2)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.sm)
                .stroke(DesignTokens.Colors.textPrimary, lineWidth: today ? 1.5 : 0)
        )
        // 「今日」は輪郭リングで示すため、VoiceOver にも明示する（色/形だけに頼らない）
        .accessibilityLabel("\(day)日\(today ? "、今日" : "")\(postsForDay.isEmpty ? "" : "、投稿\(postsForDay.count)件")")
    }
}

// MARK: - その日の投稿一覧（シンプルなリスト）

/// 日セルタップで開く、その日の投稿一覧。既存の投稿詳細（PostDetailView）への
/// 遷移パターン（.sheet(item:) → PostDetailView）を流用する。
private struct DayPostsListView: View {
    let day: SkyStreakDay
    let posts: [Post]

    @EnvironmentObject private var likeManager: LikeManager
    @State private var selectedPost: Post?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(posts) { post in
                    Button {
                        selectedPost = post
                    } label: {
                        postRow(post)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(DesignTokens.Spacing.screenMargin)
        }
        .background(skyGradient.ignoresSafeArea())
        // ⚠️ Text/.navigationTitle の文字列補間に Int を直接埋め込むと、SwiftUI が
        // LocalizedStringKey 経由で桁区切り（例: 2026 → "2,026"）を自動適用してしまう。
        // 事前に String 変数へ組み立ててから渡すことで、この自動フォーマットを回避する。
        .navigationTitle(dayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPost) { post in
            PostDetailView(post: post)
                .environmentObject(likeManager)
        }
    }

    /// 「2026年7月20日」形式のタイトル（String として組み立ててから渡す。理由は body 内コメント参照）
    private var dayTitle: String {
        "\(day.year)年\(day.month)月\(day.day)日"
    }

    private func postRow(_ post: Post) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Group {
                if let urlString = post.images.first?.thumbnail ?? post.images.first?.url,
                   let url = URL(string: urlString) {
                    KFImage(url)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(Image(systemName: "photo").foregroundColor(.gray))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm))

            VStack(alignment: .leading, spacing: 4) {
                if let caption = post.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundColor(DesignTokens.Colors.textPrimary)
                } else {
                    Text("キャプションなし")
                        .font(.subheadline)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                Text(post.images.count > 1 ? "\(post.images.count)枚の投稿" : "1枚の投稿")
                    .font(.caption2)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(DesignTokens.Colors.textTertiary)
        }
        .padding(DesignTokens.Spacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.lg))
    }
}
