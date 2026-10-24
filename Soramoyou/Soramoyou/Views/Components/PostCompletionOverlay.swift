//
//  PostCompletionOverlay.swift ⭐️
//  Soramoyou
//
//  投稿完了の演出（チェックマークが描かれる重ね表示）
//  1.18.0 の UI 刷新 PR-U「(b) 投稿完了の演出」（計画書 ~/.claude/plans/profile-visibility-toggles.md）
//  以前は `.alert("投稿完了")` を出して OK を押させていた（PostInfoView）。
//

import SwiftUI
import UIKit

/// 投稿（または再編集の更新）が終わったときに、画面全体に重ねて出す完了の表示
///
/// - 半透明の幕＋丸の中にチェックマークが**描かれる**動き＋文言
/// - 出た瞬間に成功の触覚（`Haptics.play(.success)`）を 1 回鳴らし、VoiceOver 向けに文言を読み上げる
/// - 約 1.2 秒で自動で閉じ、`onFinish` を **1 回だけ** 呼ぶ（呼び出し側が画面を閉じる）
/// - 表示中は幕が当たり判定を持つので、下の画面のボタンは押せない
/// - 「視差効果を減らす」ON のときは、チェックを描かずに最初から出す（触覚と文言は同じ）
///
/// ## 置き場所の注意
/// 呼び出し側の `NavigationView` の**外側**に `.overlay` で重ねること。
/// 内側に置くとナビゲーションバー（「キャンセル」など）が幕の外に残り、表示中に押せてしまう。
struct PostCompletionOverlay: View {
    // MARK: - Properties

    /// 表示する文言（新規「投稿が完了しました」／再編集「投稿を更新しました」）
    let message: String
    /// 閉じる時間が来たときに 1 回だけ呼ばれる（呼び出し側で dismiss する）
    let onFinish: () -> Void

    /// 端末の「視差効果を減らす」。ON のときはチェックを描かず、幕もフェードさせずに一瞬で出す
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// チェックマークの描けた割合（0 ＝ まだ何も無い → 1 ＝ 描き終わり）
    @State private var checkProgress: CGFloat = 0
    /// 幕がフェードインし終わったか（OFF のときだけ使う。ON は最初から見せる）
    @State private var isShown = false
    /// 触覚・読み上げ・動きを始めたか（`.task` が走り直しても 1 回だけにするため）
    @State private var hasStarted = false
    /// `onFinish` を呼んだか（閉じるのを 1 回だけにするため）
    @State private var hasFinished = false

    /// 自動で閉じるまでの時間（秒）
    /// 計画書の値。短すぎると何が起きたか分からず、長すぎると待たされる、の間を取った約 1.2 秒。
    private static let displaySeconds: Double = 1.2

    /// VoiceOver が動いているときに閉じるまでの時間（秒）
    /// 閉じると画面が切り替わり、読み上げの途中で次の画面の読み上げに替わりうる。
    /// 「投稿が完了しました」程度の短い一文は、標準の読み上げの速さでおよそ 1.5〜2 秒かかる見込み
    /// （⚠️ 実測していない）なので、読み始めまでの間も足して 2.5 秒にした。
    private static let voiceOverDisplaySeconds: Double = 2.5

    // MARK: - Body

    var body: some View {
        ZStack {
            // 半透明の幕（下の画面を少し暗くし、触れないようにする）
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // 丸の中のチェックマーク＋文言
            VStack(spacing: DesignTokens.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(DesignTokens.Colors.success)

                    CheckmarkShape()
                        // 「視差効果を減らす」ON のときは描き終わりの絵を最初から出す
                        .trim(from: 0, to: reduceMotion ? 1 : checkProgress)
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                        .padding(24)
                }
                .frame(width: 88, height: 88)
                .shadow(DesignTokens.Shadow.soft)

                Text(message)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.vertical, DesignTokens.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.xl)
                    .fill(.ultraThinMaterial)
            )
            // 下の画面が明るい空色でも白い文字が読めるよう、すりガラスは暗い色で固定する
            .environment(\.colorScheme, .dark)
        }
        // 「視差効果を減らす」ON のときは最初のフレームから見せる（フェードしない）
        .opacity(reduceMotion || isShown ? 1 : 0)
        // 幕全体で指を受け止め、下の画面のボタンやスクロールに通さない
        .contentShape(Rectangle())
        // 読み上げ（VoiceOver）: 幕全体を 1 つの要素にして文言を読ませ、
        // isModal で下の画面の要素へ移れない（＝押せない）ようにする
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isModal)
        // ⚠️ `.task` は表示が消えると SwiftUI が自動で取り消し、中の Task.sleep が投げて抜ける。
        //    なので onDisappear で手動で cancel する必要は無い（取り消されたら onFinish は呼ばない）。
        .task {
            await run()
        }
    }

    // MARK: - Private Methods

    /// 出た瞬間の処理（触覚・読み上げ・動き）と、時間が来たら閉じる処理
    private func run() async {
        // `.task` は表示が出直すと再び走りうるので、触覚・読み上げ・動きは 1 回だけにする
        if !hasStarted {
            hasStarted = true

            // 成功の触覚を 1 回
            Haptics.play(.success)

            // ダイアログが無くなったので、VoiceOver 向けに文言を読み上げる
            // （上の accessibilityLabel にも同じ文言があるので、読み上げが途切れても要素側で読める）
            UIAccessibility.post(notification: .announcement, argument: message)

            // 幕をふわっと出す（ON のときは nil ＝ 一瞬）
            withAnimation(Motion.animation(.easeOut(duration: 0.2), reduceMotion: reduceMotion)) {
                isShown = true
            }
            // チェックマークを描く（幕が出始めてから少し後に描き始める。ON のときは描き終わりの絵が最初から出ている）
            withAnimation(Motion.animation(.easeOut(duration: 0.45).delay(0.15), reduceMotion: reduceMotion)) {
                checkProgress = 1
            }
        }

        // VoiceOver の動作中は、読み上げ終わる前に閉じないよう長めに待つ
        let seconds = UIAccessibility.isVoiceOverRunning ? Self.voiceOverDisplaySeconds : Self.displaySeconds
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } catch {
            // 表示が消えて `.task` が取り消された（＝もう閉じる必要が無い）
            return
        }
        finishOnce()
    }

    /// 呼び出し側の「閉じる」処理を 1 回だけ呼ぶ
    private func finishOnce() {
        guard !hasFinished else { return }
        hasFinished = true
        onFinish()
    }
}

// MARK: - Checkmark Shape

/// チェックマーク（✓）の線
///
/// `trim(from:to:)` で先頭から少しずつ描けるよう、左の短い線 → 右上へ伸びる長い線の順に 1 本の線でつなぐ。
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 左の短い線の始まり
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        // 一番下の折れ目
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.82))
        // 右上へ伸びる長い線の終わり
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.2))
        return path
    }
}

// MARK: - Preview

struct PostCompletionOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            LinearGradient(
                colors: DesignTokens.Colors.daySkyGradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            PostCompletionOverlay(message: "投稿が完了しました") {
                // no-op: プレビューでは閉じない
            }
        }
    }
}
