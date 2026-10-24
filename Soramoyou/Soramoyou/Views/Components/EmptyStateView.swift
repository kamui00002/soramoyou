//
//  EmptyStateView.swift ☁️
//  Soramoyou
//
//  再利用可能なEmpty State（空の状態）コンポーネント
//  各画面でデータがない場合に統一されたデザインで表示する
//

import SwiftUI
import UIKit

/// Empty Stateのタイプ
/// 各画面に応じた適切なアイコンとメッセージを提供する
enum EmptyStateType {
    case posts // 投稿がない
    case drafts // 下書きがない
    case searchResults // 検索結果がない
    case notifications // 通知がない
    case followers // フォロワーがいない
    case following // フォロー中のユーザーがいない
    case userPosts // ユーザーの投稿がない
    case custom(icon: String, title: String, description: String, actionTitle: String?)

    var icon: String {
        switch self {
        case .posts: "photo.on.rectangle.angled"
        case .drafts: "doc.text"
        case .searchResults: "magnifyingglass"
        case .notifications: "bell.badge"
        case .followers: "person.2"
        case .following: "heart"
        case .userPosts: "camera"
        case let .custom(icon, _, _, _): icon
        }
    }

    var title: String {
        switch self {
        case .posts: "投稿がありません"
        case .drafts: "下書きがありません"
        case .searchResults: "検索結果がありません"
        case .notifications: "通知はありません"
        case .followers: "まだフォロワーがいません"
        case .following: "フォロー中のユーザーはいません"
        case .userPosts: "まだ投稿がありません"
        case let .custom(_, title, _, _): title
        }
    }

    var description: String {
        switch self {
        case .posts: "素敵な空の写真を投稿してみましょう"
        case .drafts: "編集中の投稿を下書きとして保存できます"
        case .searchResults: "検索条件を変更してみてください"
        case .notifications: "新しい通知があるとここに表示されます"
        case .followers: "投稿を続けると見つけてもらえます"
        case .following: "気になるユーザーをフォローしましょう"
        case .userPosts: "空の写真を投稿してみましょう"
        case let .custom(_, _, description, _): description
        }
    }

    var actionTitle: String? {
        switch self {
        case .posts: "投稿する"
        case .drafts: nil
        case .searchResults: "条件をクリア"
        case .notifications: nil
        case .followers: nil
        case .following: "検索する"
        case .userPosts: "投稿する"
        case let .custom(_, _, _, actionTitle): actionTitle
        }
    }
}

/// Empty Stateコンポーネント ☁️
/// 統一されたデザインで空の状態を表示する
struct EmptyStateView: View {
    let type: EmptyStateType
    var action: (() -> Void)?
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            // アイコン（アニメーション付き）
            ZStack {
                // 背景グロー
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                DesignTokens.Colors.skyBlue.opacity(0.3),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .blur(radius: 10)
                    .opacity(isAnimating ? 1 : 0.5)

                // アイコン
                Image(systemName: type.icon)
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                DesignTokens.Colors.textSecondary,
                                DesignTokens.Colors.textTertiary,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .scaleEffect(isAnimating ? 1.05 : 1.0)
            }
            .animation(
                Animation.easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                value: isAnimating
            )

            // タイトル
            Text(type.title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textPrimary)
                .shadow(DesignTokens.Shadow.text)

            // 説明文
            Text(type.description)
                .font(.system(size: DesignTokens.Typography.bodySize, weight: .regular, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, DesignTokens.Spacing.xl)

            // アクションボタン
            if let actionTitle = type.actionTitle, let action {
                Button(action: {
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                    action()
                }) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Text(actionTitle)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.vertical, DesignTokens.Spacing.md)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        DesignTokens.Colors.skyBlue,
                                        DesignTokens.Colors.selectionAccent,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .shadow(DesignTokens.Shadow.soft)
                }
                .padding(.top, DesignTokens.Spacing.sm)
            }
        }
        .padding(DesignTokens.Spacing.xl)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Preview ☁️

struct EmptyStateView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(
                colors: DesignTokens.Colors.daySkyGradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            EmptyStateView(type: .posts) {
                // no-op: action tapped (preview placeholder)
            }
        }
    }
}
