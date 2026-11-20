// ⭐️ プロフィール編集の保存の失敗から、画面に出す日本語の文言への対応（タスク 16.3・要件 10.8・10.10）
package com.yoshidometoru.soramoyou.feature.profile

import androidx.annotation.StringRes
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.feature.feed.feedErrorMessageRes

/**
 * プロフィールの保存に失敗したときに、入力欄の下に出す文言のリソース。
 * - 入力の上限の超過：iOS の上限の案内（ProfileEditView.swift:80）。画面が先に保存を止めるので、届くのは念のため
 * - 5MB 以上の画像：iOS の `StorageServiceError.imageTooLarge`（StorageService.swift:405）
 * - 読み込めない写真：Android だけの文言
 * - それ以外（通信・権限・その他）：フィードの取得の失敗と同じ文言（[feedErrorMessageRes]）
 *
 * else を書かない網羅の when にしている。[AppError] に種類を足したら、文言を決めるまでコンパイルが通らない。
 */
@StringRes
fun profileEditErrorMessageRes(error: AppError): Int = when (error) {
    is AppError.Validation -> R.string.profile_edit_too_long
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
