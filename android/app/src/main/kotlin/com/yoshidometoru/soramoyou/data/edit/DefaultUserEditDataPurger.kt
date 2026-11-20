// ⭐️ ログアウト・退会のときに、端末の中の編集の途中と下書きを消す（Kiro android-edit-tools タスク 17・A5・design.md:952-966・要件 7.9・8.12〜8.14・12.5）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlin.coroutines.cancellation.CancellationException

/**
 * [UserEditDataPurger] の実装。理由ごとに消すものは次の表のとおり（design.md:954-958）。
 *
 * | 理由 | 編集の途中（session） | 下書き（drafts） | 装備 |
 * |---|---|---|---|
 * | `SIGN_OUT`（匿名でない） | 消す | 残す | 触れない |
 * | `SIGN_OUT_ANONYMOUS` | 消す | 消す | 触れない |
 * | `ACCOUNT_DELETED` | 消す | 消す | 触れない |
 *
 * - 消すのは [uid] のフォルダだけ。別の uid のフォルダと、装備（利用者のフォルダの外）には触れない
 * - 表の対象を消した後、[uid] のフォルダそのものが空になっていれば、それも消す（空でなければ触れない）
 * - 消すのは [EditFileStore.locked] の鍵の中の 1 回。鍵の中から、ほかのストアの suspend 関数は呼ばない（同じ鍵を二重に取って止まるため）
 * - 例外を投げない（契約）。失敗は `AppError.Unknown(例外のクラス名)` にして `UserEditDataPurger.purge` で記録する（場所・本文を入れない：14.5）。
 *   最初の対象が消せなくても、残りの対象は試す（退会で下書きだけでも消えるように）。取り消しだけはそのまま伝える
 */
class DefaultUserEditDataPurger(
    private val files: EditFileStore,
    private val analytics: AnalyticsFacade,
) : UserEditDataPurger {

    override suspend fun purge(uid: Uid, reason: SessionEndReason) {
        val failure: Exception? = try {
            files.locked {
                // 理由ごとの表。ログアウト（匿名でない）だけが、下書きを残す
                val targets = if (reason == SessionEndReason.SIGN_OUT) listOf(files.sessionDir(uid)) else listOf(files.sessionDir(uid), files.draftsDir(uid))
                var first: Exception? = null
                targets.forEach { target ->
                    try {
                        files.deleteTree(target)
                    } catch (e: Exception) {
                        // 1 つ目が消せなくても 2 つ目は試す。記録するのは最初の失敗
                        if (first == null) first = e
                    }
                }
                // 消した結果、利用者のフォルダ（users/<uid>/）が空になったら、それも消す（退会の後に空のフォルダを残さない：
                // タスク 20.6）。中身が残っていれば（下書きを残すログアウト・消せなかった対象）何もしない
                try {
                    files.deleteDirIfEmpty(files.userDir(uid))
                } catch (e: Exception) {
                    if (first == null) first = e
                }
                first
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // 利用者のフォルダの名前が決められない（空の uid）などで、鍵の中に入る前後で失敗した場合
            e
        }
        if (failure != null) analytics.logError(AppError.Unknown(failure.javaClass.simpleName), CONTEXT)
    }

    private companion object {
        const val CONTEXT = "UserEditDataPurger.purge"
    }
}
