// ⭐️ 投稿の失敗から、画面に出す日本語の文言への対応（タスク 23.5・要件 7.21・7.22）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.annotation.StringRes
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes

/**
 * 投稿（PostPublisher.publish）に失敗したときに、投稿ボタンの上に出す文言のリソース。
 * - 前の投稿の処理中（`PUBLISH_IN_PROGRESS`）：保存中に画面を離れ、戻ってもう一度押したとき。Android だけの文言
 * - キャプション・ハッシュタグの上限の超過：画面が先に投稿ボタンを止めるので、届くのは念のため。入力欄の下の案内と同じ文言
 * - 写真の枚数（0 枚・11 枚以上）：画面が先に止めるので、届くのは念のため。iOS の `PostError.noImages`（PostViewModel.swift:1134）
 * - 5MB 以上の画像：iOS の `StorageServiceError.imageTooLarge`（StorageService.swift:405）。プロフィール編集と同じ文言を使う
 * - 読み込めない写真：Android だけの文言（iOS はピッカーの側で選べない）。プロフィール編集と同じ文言を使う
 * - それ以外（通信の失敗・権限の拒否・未ログイン〔`PermissionDenied`〕・その他）：フィードの取得の失敗と同じ文言（[feedErrorMessageRes]）
 *
 * else を書かない網羅の when にしている。[AppError]・[ValidationReason] に種類を足したら、文言を決めるまでコンパイルが通らない。
 */
@StringRes
fun postErrorMessageRes(error: AppError): Int = when (error) {
    is AppError.Validation -> when (error.reason) {
        ValidationReason.PUBLISH_IN_PROGRESS -> R.string.compose_error_publish_in_progress
        ValidationReason.CAPTION_TOO_LONG -> R.string.compose_caption_too_long
        ValidationReason.TOO_MANY_HASHTAGS -> R.string.compose_hashtags_too_many
        ValidationReason.NO_IMAGES,
        ValidationReason.TOO_MANY_IMAGES,
        -> R.string.compose_error_no_images
        // 投稿では起きない入力の不備（プロフィール・フィードバックの上限）
        ValidationReason.DISPLAY_NAME_TOO_LONG,
        ValidationReason.BIO_TOO_LONG,
        ValidationReason.FEEDBACK_BLANK,
        ValidationReason.FEEDBACK_TOO_LONG,
        -> R.string.state_error_title
    }
    is AppError.ImageTooLarge -> R.string.profile_edit_image_too_large
    is AppError.ImageUnreadable -> R.string.profile_edit_image_unreadable
    AppError.Network,
    AppError.PermissionDenied,
    AppError.NotFound,
    is AppError.Auth,
    is AppError.WriteBlocked,
    is AppError.ShapeViolation,
    is AppError.StageFailed,
    is AppError.Unknown,
    -> feedErrorMessageRes(error)
}

/**
 * 画面に出す失敗の文言。[args] は文言の %1$d などに入れる値（無ければ空）
 * （Kiro android-edit-tools タスク 2.3・K0・design.md:621-622。画面は `stringResource(text.res, *text.args.toTypedArray())` で出す）。
 */
data class PostErrorText(@StringRes val res: Int, val args: List<Any> = emptyList())

/**
 * 投稿の失敗から、画面に出す文言と値を決める（design.md:623-624。Kiro android-edit-tools タスク 7・A2）。
 * - `ImageUnreadable`：`compose_error_image_unreadable_at` と「何枚目か」（0 から数える [AppError.ImageUnreadable.index] に 1 を足した値）
 * - それ以外：[postErrorMessageRes] の文言で、値は空
 * 画面（PostComposerScreen の投稿の失敗のダイアログ）は、この関数で文言を決める（design.md:894）。
 */
fun postErrorText(error: AppError): PostErrorText = when (error) {
    is AppError.ImageUnreadable -> PostErrorText(R.string.compose_error_image_unreadable_at, listOf(error.index + 1))
    else -> PostErrorText(postErrorMessageRes(error))
}
