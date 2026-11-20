// ⭐️ アカウントの削除の段階と失敗から、画面に出す日本語の文言への対応（タスク 31.5・要件 12.4・12.5・16.2）
package com.yoshidometoru.soramoyou.feature.settings

import androidx.annotation.StringRes
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.feature.auth.authErrorMessageRes

/**
 * 画面に出す 1 つの文言。[res] が `%1$s` を持つときは、[arg] の文言（段階の名前）を入れる。
 * 文言そのものでなくリソースで持つのは、JVM の単体テストで「どの文言を選んだか」を確かめられるようにするため（他の画面の `…MessageRes` と同じ）。
 */
data class DeletionText(@param:StringRes val res: Int, @param:StringRes val arg: Int? = null)

/**
 * 削除の失敗の表示。見出し [title]、原因の一言 [reason]（言えることが無ければ null）、その後どうなっているかとどうすればよいか [detail]。
 */
data class DeletionFailureText(val title: DeletionText, @param:StringRes val reason: Int?, @param:StringRes val detail: Int)

/**
 * [stage] の名前（「〜を削除しています」「〜の削除で止まりました」の〜）。利用者に見える言い方にするので、内部の段階名とは 1 対 1 でない
 * （`USER` は「アカウントの情報」、`AUTH` は「アカウント」）。
 *
 * else を書かない網羅の when にしている。[DeletionStage] に段階を足したら、名前を決めるまでコンパイルが通らない。
 */
@StringRes
fun deletionStageNameRes(stage: DeletionStage): Int = when (stage) {
    DeletionStage.REAUTH -> R.string.account_delete_stage_reauth
    DeletionStage.PUBLIC_PROFILE -> R.string.account_delete_stage_public_profile
    DeletionStage.FOLLOWS_AS_FOLLOWER -> R.string.account_delete_stage_follows_as_follower
    DeletionStage.FOLLOWS_AS_FOLLOWEE -> R.string.account_delete_stage_follows_as_followee
    DeletionStage.LIKES -> R.string.account_delete_stage_likes
    DeletionStage.COMMENTS -> R.string.account_delete_stage_comments
    DeletionStage.POST_IMAGES -> R.string.account_delete_stage_post_images
    DeletionStage.POSTS -> R.string.account_delete_stage_posts
    DeletionStage.DRAFTS -> R.string.account_delete_stage_drafts
    DeletionStage.FAVORITES -> R.string.account_delete_stage_favorites
    DeletionStage.PROFILE_IMAGE -> R.string.account_delete_stage_profile_image
    DeletionStage.STORAGE_LEFTOVERS -> R.string.account_delete_stage_storage_leftovers
    DeletionStage.USER -> R.string.account_delete_stage_user
    DeletionStage.AUTH -> R.string.account_delete_stage_auth
}

/**
 * 削除中に出す、いまの段階の文言（AccountDeletionService.stage から。要件 16.2）。
 * - 段階がまだ立っていない（押した直後。部品が最初の段階を立てるまでの一瞬）：iOS と同じ「アカウントを削除中...」
 * - 再認証：「本人確認をしています」（データにはまだ触れていない）
 * - それ以外：「〜を削除しています」
 */
fun deletionProgressText(stage: DeletionStage?): DeletionText = when (stage) {
    null -> DeletionText(R.string.account_deleting)
    DeletionStage.REAUTH -> DeletionText(R.string.account_delete_progress_reauth)
    else -> DeletionText(R.string.account_delete_progress, deletionStageNameRes(stage))
}

/**
 * 削除の失敗 [error]（AccountDeletionService.delete の Err。`StageFailed` か、未ログインの `PermissionDenied`）の表示。
 * どれも「再試行」で、もう一度最初（再認証）からやり直せる（部品の約束）。
 *
 * - 再認証で止まった：「本人確認に失敗しました」＋原因＋「アカウントとデータは、まだ削除していません」。
 *   パスワードの誤りは「パスワードが正しくありません」（Android はメールアドレスを入力させないので、iOS の「メールアドレスまたは…」は使わない）。
 *   ほかの認証の失敗（通信・試行回数の超過など）は、ログインと同じ iOS の文言（[authErrorMessageRes]）
 * - 認証のアカウントの削除が「最近のログインが必要」で止まった：データは消え終わっている。「もう一度パスワードを入れて再試行すると完了します」
 *   （再試行は再認証からやり直し、データの段階は 0 件で通り過ぎて、アカウントの削除に着く）
 * - それ以外の段階で止まった：「〜の削除で止まりました」＋（通信の断絶なら）原因＋「それより前は削除済み・アカウントは残っている・再試行で残りを削除」。
 *   権限の拒否・不在は原因を言わない。取ってから消すまでの間に別の操作で消えた文書でも起き（AccountDeletionService の注記）、
 *   再試行で取り直せば通るので、「権限がありません」と言い切ると誤りになる
 * - 段階の無い失敗（未ログイン）：「アカウントを削除できませんでした」＋もう一度の案内
 */
fun deletionFailureText(error: AppError): DeletionFailureText {
    if (error !is AppError.StageFailed) {
        return DeletionFailureText(DeletionText(R.string.account_delete_failed_title), null, R.string.auth_error_unknown)
    }
    val cause = error.cause
    return when {
        error.stage == DeletionStage.REAUTH -> DeletionFailureText(
            title = DeletionText(R.string.account_delete_failed_reauth_title),
            reason = reauthReasonRes(cause),
            detail = R.string.account_delete_failed_reauth_message,
        )
        cause == AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN) -> DeletionFailureText(
            title = stageFailedTitle(error.stage),
            reason = null,
            detail = R.string.account_delete_requires_recent_login,
        )
        else -> DeletionFailureText(
            title = stageFailedTitle(error.stage),
            reason = if (isConnectionFailure(cause)) R.string.offline_title else null,
            detail = R.string.account_delete_failed_stage_message,
        )
    }
}

/**
 * [error] の後、パスワードを入れ直してもらうか（入力欄を空にする）。パスワードそのものが原因の失敗
 * （誤り・空・最近のログインが必要＝入れ直して再認証すれば通る）だけ。通信の断絶などでは、入れたパスワードのまま「再試行」を押せるよう残す。
 */
fun needsPasswordAgain(error: AppError): Boolean {
    val cause = (error as? AppError.StageFailed)?.cause ?: error
    return cause is AppError.Auth && cause.kind in PASSWORD_KINDS
}

/** パスワードを入れ直してもらう認証の失敗の種類。 */
private val PASSWORD_KINDS = setOf(AuthErrorKind.WRONG_PASSWORD, AuthErrorKind.INVALID_INPUT, AuthErrorKind.REQUIRES_RECENT_LOGIN)

/** 「〜の削除で止まりました」。 */
private fun stageFailedTitle(stage: DeletionStage) = DeletionText(R.string.account_delete_failed_stage_title, deletionStageNameRes(stage))

/** 再認証の失敗の原因の一言。認証の失敗でなければ（部品が例外を Unknown にしたときなど）言わない。 */
@StringRes
private fun reauthReasonRes(cause: AppError): Int? = when (cause) {
    is AppError.Auth -> when (cause.kind) {
        AuthErrorKind.WRONG_PASSWORD -> R.string.account_delete_wrong_password
        AuthErrorKind.INVALID_INPUT -> R.string.account_delete_password_required
        else -> authErrorMessageRes(cause.kind)
    }
    else -> null
}

/** 通信の断絶か（Firestore・Storage の `Network` と、認証の `NETWORK`）。 */
private fun isConnectionFailure(cause: AppError): Boolean =
    cause == AppError.Network || cause == AppError.Auth(AuthErrorKind.NETWORK)
