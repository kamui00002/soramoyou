//
//  ErrorStateView.swift ☁️
//  Soramoyou
//
//  再利用可能なエラー表示コンポーネント
//  リトライボタン付きでユーザーフレンドリーなエラー表示を提供
//

import SwiftUI
import UIKit

/// エラーのタイプ
/// エラーの種類に応じた適切なアイコンとメッセージを提供
enum ErrorType {
    case network           // ネットワークエラー
    case server            // サーバーエラー
    case authentication    // 認証エラー
    case permission        // 権限エラー
    case notFound          // データが見つからない
    case timeout           // タイムアウト
    case unknown           // 不明なエラー
    case custom(icon: String, title: String)

    var icon: String {
        switch self {
        case .network: return "wifi.exclamationmark"
        case .server: return "exclamationmark.icloud"
        case .authentication: return "person.badge.key"
        case .permission: return "lock.shield"
        case .notFound: return "questionmark.folder"
        case .timeout: return "clock.badge.exclamationmark"
        case .unknown: return "exclamationmark.triangle"
        case .custom(let icon, _): return icon
        }
    }

    var title: String {
        switch self {
        case .network: return "ネットワークに接続できません"
        case .server: return "サーバーエラーが発生しました"
        case .authentication: return "ログインが必要です"
        case .permission: return "アクセス権限がありません"
        case .notFound: return "データが見つかりません"
        case .timeout: return "接続がタイムアウトしました"
        case .unknown: return "エラーが発生しました"
        case .custom(_, let title): return title
        }
    }

    var isRetryable: Bool {
        switch self {
        case .network, .server, .timeout, .unknown:
            return true
        case .authentication, .permission, .notFound:
            return false
        case .custom:
            return true
        }
    }

    /// エラーからErrorTypeを推定
    static func from(error: Error) -> ErrorType {
        // NSErrorの場合
        if let nsError = error as NSError? {
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                    return .network
                case NSURLErrorTimedOut:
                    return .timeout
                default:
                    return .network
                }
            }
        }

        // カスタムエラーの場合
        let category = ErrorHandler.categorize(error)
        switch category {
        case .userError:
            return .authentication
        case .systemError:
            return .server
        case .businessError:
            return .unknown
        }
    }
}

/// エラー表示コンポーネント ☁️
/// リトライ機能付きでエラー状態を表示する
struct ErrorStateView: View {
    let errorType: ErrorType
    let message: String?
    var retryAction: (() async -> Void)? = nil
    var secondaryAction: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil

    @State private var isRetrying = false
    @State private var shakeAnimation = false

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            // エラーアイコン
            ZStack {
                // 背景グロー（警告色）
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.red.opacity(0.2),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .blur(radius: 10)

                // アイコン
                Image(systemName: errorType.icon)
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                DesignTokens.Colors.error,
                                DesignTokens.Colors.error.opacity(0.7)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .offset(x: shakeAnimation ? -5 : 0)
            }
            .onAppear {
                // シェイクアニメーション
                withAnimation(.default.repeatCount(3, autoreverses: true).speed(4)) {
                    shakeAnimation = true
                }
            }

            // エラータイトル
            Text(errorType.title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(DesignTokens.Colors.textPrimary)
                .shadow(DesignTokens.Shadow.text)

            // エラーメッセージ（詳細）
            if let message = message {
                Text(message)
                    .font(.system(size: DesignTokens.Typography.bodySize, weight: .regular, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
            }

            // アクションボタン
            VStack(spacing: DesignTokens.Spacing.md) {
                // リトライボタン
                if errorType.isRetryable, let retryAction = retryAction {
                    Button(action: {
                        Task {
                            let impact = UIImpactFeedbackGenerator(style: .medium)
                            impact.impactOccurred()

                            isRetrying = true
                            await retryAction()
                            isRetrying = false
                        }
                    }) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            if isRetrying {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            Text(isRetrying ? "読み込み中..." : "再試行")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
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
                    .disabled(isRetrying)
                }

                // セカンダリアクション
                if let secondaryAction = secondaryAction, let title = secondaryActionTitle {
                    Button(action: {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        secondaryAction()
                    }) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                }
            }
            .padding(.top, DesignTokens.Spacing.sm)
        }
        .padding(DesignTokens.Spacing.xl)
    }
}

// MARK: - Convenience Initializer ☁️

extension ErrorStateView {
    /// エラーオブジェクトから自動的にErrorTypeを推定して初期化
    init(
        error: Error,
        retryAction: (() async -> Void)? = nil,
        secondaryAction: (() -> Void)? = nil,
        secondaryActionTitle: String? = nil
    ) {
        self.errorType = ErrorType.from(error: error)
        self.message = error.userFriendlyMessage
        self.retryAction = retryAction
        self.secondaryAction = secondaryAction
        self.secondaryActionTitle = secondaryActionTitle
    }
}

// MARK: - Preview ☁️

struct ErrorStateView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(
                colors: DesignTokens.Colors.daySkyGradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ErrorStateView(
                errorType: .network,
                message: "インターネット接続を確認してください",
                retryAction: {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                },
                secondaryAction: {
                    print("Secondary action")
                },
                secondaryActionTitle: "設定を開く"
            )
        }
    }
}
