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
    case posts           // 投稿がない
    case drafts          // 下書きがない
    case searchResults   // 検索結果がない
    case notifications   // 通知がない
    case followers       // フォロワーがいない
    case following       // フォロー中のユーザーがいない
    case userPosts       // ユーザーの投稿がない
    case custom(icon: String, title: String, description: String, actionTitle: String?)

    var icon: String {
        switch self {
        case .posts: return "photo.on.rectangle.angled"
        case .drafts: return "doc.text"
        case .searchResults: return "magnifyingglass"
        case .notifications: return "bell.badge"
        case .followers: return "person.2"
        case .following: return "heart"
        case .userPosts: return "camera"
        case .custom(let icon, _, _, _): return icon
        }
    }

    var title: String {
        switch self {
        case .posts: return "投稿がありません"
        case .drafts: return "下書きがありません"
        case .searchResults: return "検索結果がありません"
        case .notifications: return "通知はありません"
        case .followers: return "まだフォロワーがいません"
        case .following: return "フォロー中のユーザーはいません"
        case .userPosts: return "まだ投稿がありません"
        case .custom(_, let title, _, _): return title
        }
    }

    var description: String {
        switch self {
        case .posts: return "素敵な空の写真を投稿してみましょう"
        case .drafts: return "編集中の投稿を下書きとして保存できます"
        case .searchResults: return "検索条件を変更してみてください"
        case .notifications: return "新しい通知があるとここに表示されます"
        case .followers: return "投稿を続けると見つけてもらえます"
        case .following: return "気になるユーザーをフォローしましょう"
        case .userPosts: return "空の写真を投稿してみましょう"
        case .custom(_, _, let description, _): return description
        }
    }

    var actionTitle: String? {
        switch self {
        case .posts: return "投稿する"
        case .drafts: return nil
        case .searchResults: return "条件をクリア"
        case .notifications: return nil
        case .followers: return nil
        case .following: return "検索する"
        case .userPosts: return "投稿する"
        case .custom(_, _, _, let actionTitle): return actionTitle
        }
    }
}

/// Empty Stateコンポーネント ☁️
/// 統一されたデザインで空の状態を表示する
struct EmptyStateView: View {
    let type: EmptyStateType
    var action: (() -> Void)? = nil
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
                                Color.clear
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
                                DesignTokens.Colors.textTertiary
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
            if let actionTitle = type.actionTitle, let action = action {
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
                                        DesignTokens.Colors.selectionAccent
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
                print("Action tapped")
            }
        }
    }
}
