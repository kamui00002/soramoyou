//
//  Haptics.swift ⭐️
//  Soramoyou
//
//  触覚（指に返る「コツッ」という手ごたえ）の共通部品
//  1.18.0 の UI 刷新 PR-U「土台 1」（計画書 ~/.claude/plans/profile-visibility-toggles.md）
//

import UIKit

/// 触覚を「場面の名前」で鳴らす共通部品
///
/// これまでは画面ごとに `UIImpactFeedbackGenerator(style: .light)` などを直書きしていたため、
/// 「どの場面でどの強さを鳴らすか」がそろっていなかった。この部品は場面の名前（`Kind`）で呼び、
/// 中身（強さ・種類）の対応表を 1 か所にまとめる。
///
/// ## 使い方
/// ```swift
/// // いいねを付けたとき
/// Haptics.play(.likeOn)
/// // 投稿が完了したとき
/// Haptics.play(.success)
/// ```
///
/// ## 作り
/// - 「場面 → 中身」の対応表は `Kind.pattern`。UIKit を使わない**純粋な値**なので単体テストで固定できる
///   （`HapticsTests`）。
/// - 実際に端末を震わせるのは `play(_:)` だけ。対応表の値を見て UIKit の生成器を叩く。
/// - 生成器は鳴らすたびにその場で作る（`prepare()` で事前に温めることはしない）。
///   ボタンを押したときの手ごたえでは、作ってすぐ鳴らしても体感の遅れは小さいため。
///
/// ## 端末の設定との関係
/// 端末の「設定 > サウンドと触覚 > システムの触覚」を OFF にしたとき鳴るかは**未確認**。
/// ⚠️ 2026-10-24 に Apple の文書（`UIFeedbackGenerator`・HIG「Playing haptics」）を読んだが、
///    「システムの触覚が OFF なら鳴らない」という記述は無かった。HIG は逆に
///    "Make haptics optional. Let people turn off or mute haptics" と勧めている。
///    実機で OFF にして確かめ、鳴るならアプリの設定に「触覚」のスイッチを足す（利用者の決定・計画書）。
///    スイッチを足すときは、この `play(_:)` の入口 1 か所で止めればよい。
///
/// ## 既存の直書きの扱い
/// 既存の直書きは、1.18.0 で触る画面だけこの部品へ移す（一斉置換はしない）。
/// `.medium` の直書きを「いいね以外」の場面で使っている所は、`likeOn` の名前を借りると意味が嘘になるので移さない。
enum Haptics {
    // MARK: - 場面

    /// 触覚を鳴らす場面
    ///
    /// ⚠️ 場面を足したら、`pattern` の対応表と `HapticsTests` の期待値も一緒に足すこと
    ///    （`HapticsTests` は場面の数も数えているので、足し忘れると赤になる）。
    enum Kind: CaseIterable {
        /// いいねを付けた（ボタン・写真の 2 回タップ）
        case likeOn
        /// 軽いタップ（いいねを外した・🔖・入口ボタン・カードを開く）
        case tap
        /// うまくいった（フォローした・投稿完了）
        case success
        /// 切り替えた（すべて⇄あなた向け・編集画面のスイッチ）
        case selection
        /// 失敗した
        case error

        /// この場面で鳴らす中身（場面 → 中身の対応表）
        var pattern: Pattern {
            switch self {
            case .likeOn:
                // いいねは「付けた」ことをはっきり伝えたいので、軽いタップより一段強くする
                .impact(.medium)
            case .tap:
                // 今までの直書きと同じ強さ（impact light）
                .impact(.light)
            case .success:
                .notification(.success)
            case .selection:
                .selection
            case .error:
                .notification(.error)
            }
        }
    }

    // MARK: - 中身

    /// 鳴らす触覚の中身
    ///
    /// UIKit の型を使わない自前の値にしているのは、テストで「場面 → 中身」を比べるため（Equatable）。
    /// ⚠️ 名前を `Feedback` にしないのは、ご意見の型 `Feedback`（Models/Feedback.swift）と紛らわしいため。
    enum Pattern: Equatable {
        /// 物がぶつかったような手ごたえ（UIImpactFeedbackGenerator）
        case impact(ImpactStrength)
        /// 結果を知らせる手ごたえ（UINotificationFeedbackGenerator）
        case notification(NotificationResult)
        /// 選んでいるものが変わった手ごたえ（UISelectionFeedbackGenerator）
        case selection
    }

    /// impact の強さ（使う 2 段階だけ）
    enum ImpactStrength: Equatable {
        case light
        case medium
    }

    /// notification の結果（使う 2 種類だけ）
    enum NotificationResult: Equatable {
        case success
        case error
    }

    // MARK: - 鳴らす

    /// 場面に合った触覚を 1 回鳴らす
    ///
    /// UIKit の触覚の生成器（UIFeedbackGenerator の仲間）はメインスレッド専用なので `@MainActor`。
    /// View のボタンの処理や `.task` の中から呼ぶ分には、そのまま呼べる。
    /// - Parameter kind: 鳴らす場面
    @MainActor
    static func play(_ kind: Kind) {
        switch kind.pattern {
        case let .impact(strength):
            let style: UIImpactFeedbackGenerator.FeedbackStyle = switch strength {
            case .light:
                .light
            case .medium:
                .medium
            }
            UIImpactFeedbackGenerator(style: style).impactOccurred()

        case let .notification(result):
            let type: UINotificationFeedbackGenerator.FeedbackType = switch result {
            case .success:
                .success
            case .error:
                .error
            }
            UINotificationFeedbackGenerator().notificationOccurred(type)

        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
}
