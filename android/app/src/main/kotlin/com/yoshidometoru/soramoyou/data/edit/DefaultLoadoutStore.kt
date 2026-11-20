// ⭐️ 編集ツールの装備を端末に保存する（Kiro android-edit-tools タスク 14.2・A4・design.md:947, 671-674・要件 7.2・7.3・7.9・7.10）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.edit.EditDocumentCodec
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * [LoadoutStore] の実装。装備は `edit/loadout.properties`（利用者のフォルダの外・端末で共通。ログアウトや退会で消さない：7.9）。
 *
 * - 作った時に [scope] で 1 回だけ読み、[loadout] で配る。読み終わるまでは [Loadout.DEFAULT]
 * - 読めなければ [Loadout.DEFAULT] にして `LoadoutStore.load` で記録する（編集はできる：7.10）。
 *   「読めない」＝ファイルを読めない・文書の書き方が壊れている（例外）か、文書は読めたが中身が 1 つも使えず既定に戻った（版が新しすぎる・
 *   知らない名前だけなど）。まだ一度も保存していない（ファイルが無い）ときは既定で、記録しない
 * - 知らない名前と重複は捨てる（[EditDocumentCodec.decodeLoadout] が [Loadout.sanitized] を通す）
 * - 保存に失敗したら `Err` を返して `LoadoutStore.save` で記録し、配る装備は変えない
 * - 読み込みと保存は [EditFileStore.locked] の中で配る値まで決める（最初の読み込みが、先に終わった保存を古い値で上書きしない）
 * - 端末の中だけ。サーバーの読み書きの入口を持たない（`users`・`publicProfiles` を読み書きしない：7.3）
 *
 * @param scope 最初の読み込みを走らせるスコープ（本番はアプリの寿命のスコープ）
 */
class DefaultLoadoutStore(
    private val files: EditFileStore,
    private val analytics: AnalyticsFacade,
    scope: CoroutineScope,
) : LoadoutStore {

    private val state = MutableStateFlow(Loadout.DEFAULT)
    override val loadout: StateFlow<Loadout> = state.asStateFlow()

    /** 最初の 1 回の読み込み。テストは [awaitLoaded] で待ち、失敗があればそのまま受け取る */
    private val loading: Deferred<Unit> = scope.async { loadOnce() }

    /** 最初の読み込みが終わるまで待つ（テスト用） */
    internal suspend fun awaitLoaded() = loading.await()

    override suspend fun save(loadout: Loadout): AppResult<Unit> {
        val failure: Exception? = try {
            files.locked {
                files.writeDocument(files.loadoutFile, EditDocumentCodec.encodeLoadout(loadout))
                // 書けた後だけ配る（失敗したら今の装備のまま）
                state.value = loadout
            }
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            e
        }
        if (failure == null) return AppResult.Ok(Unit)
        val error = AppError.Unknown(failure.javaClass.simpleName)
        analytics.logError(error, CONTEXT_SAVE)
        return AppResult.Err(error)
    }

    private suspend fun loadOnce() {
        var failure: Exception? = null
        files.locked {
            state.value = try {
                readSaved()
            } catch (e: Exception) {
                failure = e
                Loadout.DEFAULT
            }
        }
        failure?.let { analytics.logError(AppError.Unknown(it.javaClass.simpleName), CONTEXT_LOAD) }
    }

    /** 保存してある装備。まだ無ければ既定。読めなければ例外（中身が 1 つも使えず既定に戻ったときは [BrokenEditDocumentException]） */
    private fun readSaved(): Loadout {
        val map = files.readDocument(files.loadoutFile) ?: return Loadout.DEFAULT
        val decoded = EditDocumentCodec.decodeLoadout(map)
        // 既定の装備をそのまま保存した文書でないのに既定になった＝読めなかった（版が新しすぎる・鍵が無い・知らない名前だけ）
        if (decoded == Loadout.DEFAULT && map != EditDocumentCodec.encodeLoadout(Loadout.DEFAULT)) throw BrokenEditDocumentException()
        return decoded
    }

    private companion object {
        const val CONTEXT_LOAD = "LoadoutStore.load"
        const val CONTEXT_SAVE = "LoadoutStore.save"
    }
}
