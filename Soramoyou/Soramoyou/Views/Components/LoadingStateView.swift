//
//  LoadingStateView.swift ☁️
//  Soramoyou
//
//  再利用可能なローディング状態コンポーネント
//  各画面で統一されたローディングUIを提供する
//

import SwiftUI

/// ローディングのタイプ
/// ローディングの種類に応じたメッセージを提供
enum LoadingType {
    case initial        // 初回読み込み
    case refreshing     // プルリフレッシュ
    case loadingMore    // 追加読み込み
    case uploading      // アップロード中
    case processing     // 処理中
    case custom(message: String)

    var message: String {
        switch self {
        case .initial: return "読み込み中..."
        case .refreshing: return "更新中..."
        case .loadingMore: return "追加読み込み中..."
        case .uploading: return "アップロード中..."
        case .processing: return "処理中..."
        case .custom(let message): return message
        }
    }
}

/// ローディング状態コンポーネント ☁️
/// アニメーション付きのローディング表示
struct LoadingStateView: View {
    let type: LoadingType
    var progress: Double? = nil  // 0.0 ~ 1.0（オプション）
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            // ローディングインジケーター
            ZStack {
                // 背景グロー
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                DesignTokens.Colors.skyBlue.opacity(0.2),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 50
                        )
                    )
                    .frame(width: 100, height: 100)
                    .blur(radius: 8)
                    .scaleEffect(isAnimating ? 1.2 : 1.0)

                if let progress = progress {
                    // プログレスリング
                    ZStack {
                        // 背景リング
                        Circle()
                            .stroke(
                                DesignTokens.Colors.glassTertiary,
                                lineWidth: 6
                            )
                            .frame(width: 60, height: 60)

                        // 進捗リング
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        DesignTokens.Colors.skyBlue,
                                        DesignTokens.Colors.selectionAccent
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round)
                            )
                            .frame(width: 60, height: 60)
                            .rotationEffect(.degrees(-90))
                            .animation(.easeInOut(duration: 0.3), value: progress)

                        // パーセンテージ表示
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textPrimary)
                    }
                } else {
                    // 標準のスピナー
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
            }

            // メッセージ
            Text(type.message)
                .font(.system(size: DesignTokens.Typography.bodySize, weight: .medium, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .padding(DesignTokens.Spacing.xl)
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

/// インラインローディングビュー（小さいスペース用）☁️
struct InlineLoadingView: View {
    let message: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(0.8)
            Text(message)
                .font(.system(size: DesignTokens.Typography.captionSize, weight: .medium, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .padding(.vertical, DesignTokens.Spacing.md)
    }
}

// MARK: - Preview ☁️

struct LoadingStateView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(
                colors: DesignTokens.Colors.daySkyGradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                LoadingStateView(type: .initial)
                LoadingStateView(type: .uploading, progress: 0.65)
            }
        }
    }
}
