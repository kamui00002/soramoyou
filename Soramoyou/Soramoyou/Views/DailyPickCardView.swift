//
//  DailyPickCardView.swift
//  Soramoyou
//
//  ⭐️ 今日のおすすめのそらもよう: ホーム上部に「今日の 1 枚」を出すカード。
//  おすすめが無い（まだ決まっていない・全候補が見せられない）ときは何も描かない。
//  タップすると、ホーム側が投稿の詳細を開く。
//  ※「私のおすすめの空」（publicProfiles.recommendedPostIds）とは別物。
//

import SwiftUI

struct DailyPickCardView: View {
    /// ホーム（HomeView）が所有する VM を共有する。
    /// 読み込み（load）は HomeView 側の onAppear / refreshable が担う。
    /// おすすめが無い時にこの View はサイズゼロになり、LazyVStack の中ではサイズゼロの View の
    /// task / onAppear の発火が保証されないため、このカード自身では読み込まない
    /// （OnThisDayCardView と同じ理由）。
    @ObservedObject var viewModel: DailyPickViewModel
    /// カードがタップされたときに呼ぶ（ホームが投稿の詳細を開く）
    let onTap: (Post) -> Void

    /// カードの濃いそらいろ。見出し・説明・名前の文字と、「そらに出会う」の帯（白い文字の下地）に使う
    ///
    /// 白は背景（昼の空の上のすりガラス）とのコントラスト比が約 1.4、DesignTokens の skyBlue でも約 2.1 で薄い。
    /// そらともの丸（SoratomoGroupIcon）の濃い方と同じ青で約 4.9（小さい文字の目安 4.5 を越える）。
    /// 背景の色はスクショから見積もった目安（2026-10-27・利用者判断で「文字は濃いそらいろ」）
    private static let textColor = Color(red: 0.16, green: 0.33, blue: 0.72)

    var body: some View {
        Group {
            if let item = viewModel.item {
                cardButton(item)
            }
        }
    }

    private func cardButton(_ item: DailyPickItem) -> some View {
        Button {
            onTap(item.post)
        } label: {
            // 写真は出さず、見出し・名前・説明・「そらに出会う」を中央に出す。空を見るかどうかは利用者に任せる
            // （2026-10-27 利用者判断。押すと投稿の詳細が開き、そこで写真が見える）
            VStack(spacing: DesignTokens.Spacing.sm) {
                // 見出しは 1 行（2026-10-27 利用者判断）。収まらないとき（大きな文字の設定・小さい iPhone）だけ、
                // 「そらもよう」の途中で折れないよう名前の前で 2 行にする（What's New の見出しと同じ区切り）。
                // 入る形を上から順に試す（SoratomoGroupListView の actionButtons と同じ）
                ViewThatFits(in: .horizontal) {
                    titleLabel("今日のおすすめのそらもよう")
                    titleLabel("""
                    今日のおすすめの
                    そらもよう
                    """)
                }
                .multilineTextAlignment(.center)

                // 名前（アイコンつき）を上、説明を下に出す。説明の白い帯はやめて、文字を一段大きくした（2026-10-27 利用者判断）
                VStack(spacing: 4) {
                    // 投稿者のアイコンと名前。取れないとき（ゲストはいつもこちら）は人の形の印と "ユーザー"
                    // （HomeView の投稿者欄と同じ扱い）。アイコンの大きさと名前の文字は SoratomoTimelineRow の投稿者欄と同じ
                    HStack(spacing: 6) {
                        UserAvatarView(photoURL: item.authorPhotoURL, size: 24)
                            .accessibilityHidden(true)
                        Text(item.authorName ?? "ユーザー")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }

                    if let caption = item.post.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.subheadline)
                            .lineLimit(2)
                    }
                }
                .foregroundColor(Self.textColor)
                .multilineTextAlignment(.center)

                // 「そらに出会う」はボタンに見える形だけ（押せるのはカード全体＝押す所を 1 つにする。
                // ボタンの中にボタンを入れると押し分けが不安定になるため、ここは Button にしない）
                HStack(spacing: 4) {
                    Text("そらに出会う")
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(Capsule().fill(Self.textColor))
            }
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.Spacing.md)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.xl))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .stroke(DesignTokens.Colors.glassBorderSecondary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("今日のおすすめのそらもようを見る")
        .accessibilityIdentifier("DailyPickCard")
    }

    /// 見出し（✨＋文字）
    /// - Parameter text: 見出しの文字（1 行の形と 2 行の形を ViewThatFits に渡す）
    private func titleLabel(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.headline.weight(.bold))
        .foregroundColor(Self.textColor)
    }
}
