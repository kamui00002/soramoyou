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
    case initial // 初回読み込み
    case refreshing // プルリフレッシュ
    case loadingMore // 追加読み込み
    case uploading // アップロード中
    case processing // 処理中
    case custom(message: String)

    var message: String {
        switch self {
        case .initial: "読み込み中..."
        case .refreshing: "更新中..."
        case .loadingMore: "追加読み込み中..."
        case .uploading: "アップロード中..."
        case .processing: "処理中..."
        case let .custom(message): message
        }
    }
}

/// ローディング状態コンポーネント ☁️
/// アニメーション付きのローディング表示
struct LoadingStateView: View {
    let type: LoadingType
    var progress: Double? // 0.0 ~ 1.0（オプション）
    /// ⭐️ PR-H 後ろの光を脈打たせてよいか（呼び出し側からの許可。既定は true＝今までの呼び出しは何も変わらない）。
    /// ホームは TabView の page 形式で 2 ページが両方生きているので、選ばれていない側に出ている
    /// この表示の光が裏で回り続けないよう、ホームは「選ばれているときだけ true」を渡す。
    var pulses: Bool = true
    @State private var isAnimating = false
    /// 端末の「視差効果を減らす」。ON のときは後ろの光を脈打たせない（等倍＝始点で止めた絵にする）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// ⭐️ PR-H 光を脈打たせてよいか＝呼び出し側の許可（`pulses`）かつ「視差効果を減らす」が OFF。
    /// 止める理由が 2 つあるので 1 つの Bool にまとめ、`.id`・onAppear・onChange はすべてこの値を見る
    /// （片方だけを見ると、もう片方の理由では止まらないのにビルドは通ってしまう）。
    private var shouldPulse: Bool {
        pulses && !reduceMotion
    }

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
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 50
                        )
                    )
                    .frame(width: 100, height: 100)
                    .blur(radius: 8)
                    .scaleEffect(isAnimating ? 1.2 : 1.0)
                    // 「視差効果を減らす」の切り替えや、選ばれていないページになったときに光を作り直し、
                    // 走っている繰り返しの動きを確実に捨てる（キーは止める理由をまとめた `shouldPulse`）
                    // （SwiftUI は値を始点へ戻しただけでは repeatForever の動きを捨てないことがあるため）
                    .id(shouldPulse)

                if let progress {
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
                                        DesignTokens.Colors.selectionAccent,
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
            // 「視差効果を減らす」ON、または選ばれていないページのときは光を脈打たせない
            // （始点＝等倍のまま止めた絵。画面に出た最初の絵と同じ）
            if shouldPulse {
                startGlowPulse()
            }
        }
        .onChange(of: shouldPulse) { pulse in
            // 途中で設定やページの選択が変わったとき: 脈打ってよい → 脈打ち始める／ダメ → 始点に戻して止める
            if pulse {
                startGlowPulse()
            } else {
                isAnimating = false
            }
        }
    }

    // MARK: - Private Methods

    /// 後ろの光をゆっくり大きく・小さくし続ける（ずっと動く）
    /// 「視差効果を減らす」ON のときと、選ばれていないページ（`pulses` が false）のときは呼ばない
    private func startGlowPulse() {
        withAnimation(Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            isAnimating = true
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
