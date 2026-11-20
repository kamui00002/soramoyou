// ⭐️ ログアウト・退会の完了時に、端末内のそのユーザーのデータを消す（タスク 8.2・要件 2.9・2.10・15.7）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/**
 * ログアウト・退会の後に、画面で共有している状態を捨てるための登録口。
 * フィード・投稿者の表示・プロフィール・いいねの状態を持つ部品（タスク 9.x 以降で作る）が、これを実装して [SessionManager.register] で登録する。
 */
fun interface SessionScopedState {
    /** そのユーザーのデータを捨てて、ログイン前と同じ状態に戻す。速く終わる同期の処理だけを書く（通信しない）。 */
    fun clearOnSignOut()
}

/** 画像のメモリとディスクのキャッシュを消す（本番は [CoilImageCacheCleaner]）。 */
fun interface ImageCacheCleaner {
    suspend fun clear()
}

/**
 * ログアウトと退会の完了時に、端末内のそのユーザーのデータを消す（設計書の部品 SessionManager・:953-963）。
 * 呼ぶのは AuthRepository の signOut（タスク 8.2）と、退会の処理（タスク 13.x）。
 */
interface SessionManager {
    /** ログアウトのときに捨てる状態を登録する。アプリの寿命と同じだけ生きる部品が、作られたときに 1 回呼ぶ。 */
    fun register(state: SessionScopedState)

    /**
     * 端末内のそのユーザーのデータを消す。例外を投げず、呼び出し元が取り消されても最後まで行う。
     * 途中の段が失敗しても残りの段は行い、失敗は記録する。
     */
    suspend fun clearLocalUserData()
}

/**
 * [SessionManager] の実装。消す順は次のとおり（設計書 :958-962）。
 * 1. 登録された状態（フィード・投稿者・プロフィール・いいね）を捨てる。画面に前のユーザーのものが残らないよう、最初に行う
 * 2. 画像のメモリとディスクのキャッシュを消す（非公開の投稿の画像を残さない）
 * 3. Firestore のインスタンスを停止してローカルのデータを消し、次の利用で作り直す（[resetFirestore]）
 * 4. 分析と Crashlytics のユーザーの識別を解除する。Crashlytics の解除は [AnalyticsFacade.setUserId] が行う（CrashReporter の約束）
 *
 * - 識別の解除を最後にするのは、1〜3 の失敗の記録にまだ uid が付くようにするため（どのユーザーで消し損ねたかを追える）。
 * - 失敗した段は `error_occurred`（`AppError.Unknown`＝system_error なので Crashlytics にも残る）で記録し、次の段へ進む。
 *   ログアウトを途中で止めると、前のユーザーのデータが端末に残ったままになるため。
 * - 全体を [NonCancellable] で行う。ログアウトを押した画面が閉じて呼び出し元が取り消されても、途中で止めない。
 * - プッシュ通知のトークンには触れない（要件 2.10。iOS はログアウト時に users から消すが、Android は登録しない）。
 *   この部品は書き込みの入口を持たない（SessionManagerTest がコンストラクタの引数で確かめる）。
 *
 * @param imageCache 画像のキャッシュの消去。
 * @param resetFirestore Firestore のインスタンスの停止と作り直し（AppContainer の `firestore.reset()`）。
 * @param analytics 失敗の記録と、ユーザーの識別の解除。
 */
class DefaultSessionManager(
    private val imageCache: ImageCacheCleaner,
    private val resetFirestore: suspend () -> Unit,
    private val analytics: AnalyticsFacade,
) : SessionManager {

    /** 登録された状態。登録と消去が別のスレッドから来ても壊れないよう、書き込み時に写す一覧にする。 */
    private val states = CopyOnWriteArrayList<SessionScopedState>()

    override fun register(state: SessionScopedState) {
        states += state
    }

    override suspend fun clearLocalUserData(): Unit = withContext(NonCancellable) {
        // 1 つの状態の失敗で、ほかの状態を捨て損ねないよう、1 つずつ守る
        states.forEach { state -> step("states") { state.clearOnSignOut() } }
        step("image_cache") { imageCache.clear() }
        step("firestore") { resetFirestore() }
        // 例外を投げない約束の窓口（AnalyticsFacade）なので、守らずに呼ぶ
        analytics.setUserId(null)
    }

    /** [block] を行い、失敗したら `SessionManager.clearLocalUserData.<name>` として記録して続ける。 */
    private inline fun step(name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            // 取り消し（CancellationException）もここで受ける。NonCancellable の中なので呼び出し元の取り消しでは来ず、
            // 来るのは段の中の処理が自分で投げたものだけで、それも 1 つの段の失敗として記録して続ける
            record(name, e)
        }
    }

    private fun record(name: String, e: Exception) {
        analytics.logError(AppError.Unknown(e.javaClass.simpleName), "SessionManager.clearLocalUserData.$name")
    }
}
