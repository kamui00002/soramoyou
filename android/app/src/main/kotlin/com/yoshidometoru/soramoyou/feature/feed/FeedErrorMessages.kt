// ⭐️ フィードの取得の失敗から、画面に出す日本語の文言への対応（タスク 9.4・要件 4.12）
package com.yoshidometoru.soramoyou.feature.feed

import androidx.annotation.StringRes
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError

/**
 * フィードの取得に失敗したとき（オンラインのまま失敗したとき）に出す見出しのリソース。
 * 文言は iOS の `ErrorStateView` の `ErrorType.title`（ErrorStateView.swift:39-45）から、失敗の種類に合うものを写す。
 * - 通信の失敗：`.network`「ネットワークに接続できません」
 * - 権限の拒否（ルールで読めない・インデックスなど）：`.permission`「アクセス権限がありません」
 * - それ以外：`.unknown`「エラーが発生しました」
 *
 * 失敗した時点でオフラインだったときは、この文言でなく OfflineContent を出す（画面の側が決める）。
 * else を書かない網羅の when にしている。[AppError] に種類を足したら、文言を決めるまでコンパイルが通らない。
 */
@StringRes
fun feedErrorMessageRes(error: AppError): Int = when (error) {
    AppError.Network -> R.string.offline_title
    AppError.PermissionDenied -> R.string.state_error_permission
    is AppError.Auth,
    AppError.NotFound,
    is AppError.WriteBlocked,
    is AppError.ShapeViolation,
    is AppError.Validation,
    is AppError.ImageUnreadable,
    is AppError.ImageTooLarge,
    is AppError.StageFailed,
    is AppError.Unknown,
    -> R.string.state_error_title
}
