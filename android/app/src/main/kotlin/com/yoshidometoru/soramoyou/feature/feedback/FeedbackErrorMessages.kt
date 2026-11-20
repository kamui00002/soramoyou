// ⭐️ フィードバックの送信の失敗から、画面に出す日本語の文言への対応（タスク 30・要件 13.3・13.6）
package com.yoshidometoru.soramoyou.feature.feedback

import androidx.annotation.StringRes
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes

/**
 * フィードバックを送れなかった理由として、入力欄の下に出す文言のリソース。
 * - 本文が空白だけ・1000 文字を超える（要件 13.3）：iOS の「1〜1000文字で入力してください」（FeedbackViewModel.swift:44）。
 *   iOS は 1 つの文言で両方を言うので、Android も同じ文言を 2 つの理由に使う（範囲を言うので、どちらにも当てはまる）
 * - それ以外（通信の失敗・権限の拒否・書き込みの無効・その他）：フィードの取得の失敗と同じ文言（[feedErrorMessageRes]）。
 *   こちらは失敗の見出し（[R.string.feedback_failed_title]）の下に出す。見出しを付けるかどうかは [isFeedbackInputProblem] で決める
 *
 * else を書かない網羅の when にしている。[AppError]・[ValidationReason] に種類を足したら、文言を決めるまでコンパイルが通らない。
 */
@StringRes
fun feedbackErrorMessageRes(error: AppError): Int = when (error) {
    is AppError.Validation -> when (error.reason) {
        ValidationReason.FEEDBACK_BLANK,
        ValidationReason.FEEDBACK_TOO_LONG,
        -> R.string.feedback_message_range
        // フィードバックでは起きない入力の不備（投稿・プロフィールの上限）。届くはずが無いので、汎用の失敗の文言にする
        ValidationReason.NO_IMAGES,
        ValidationReason.TOO_MANY_IMAGES,
        ValidationReason.CAPTION_TOO_LONG,
        ValidationReason.TOO_MANY_HASHTAGS,
        ValidationReason.PUBLISH_IN_PROGRESS,
        ValidationReason.DISPLAY_NAME_TOO_LONG,
        ValidationReason.BIO_TOO_LONG,
        -> R.string.state_error_title
    }
    AppError.Network,
    AppError.PermissionDenied,
    AppError.NotFound,
    is AppError.Auth,
    is AppError.WriteBlocked,
    is AppError.ShapeViolation,
    is AppError.ImageUnreadable,
    is AppError.ImageTooLarge,
    is AppError.StageFailed,
    is AppError.Unknown,
    -> feedErrorMessageRes(error)
}

/**
 * 送れなかった理由が、本文の入力の不備（空白だけ・1000 文字超過）か。そうなら文言だけを出し、そうでなければ
 * 「送信に失敗しました」の見出しを付けて出す（入力の不備は「失敗」ではなく、直せばそのまま送れるため）。
 */
fun isFeedbackInputProblem(error: AppError): Boolean =
    error is AppError.Validation &&
        (error.reason == ValidationReason.FEEDBACK_BLANK || error.reason == ValidationReason.FEEDBACK_TOO_LONG)
