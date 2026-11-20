// ⭐️ ログアウトで破棄して作り直せるインスタンスの入れ物（タスク 5.1・要件 2.9）
package com.yoshidometoru.soramoyou.di

/**
 * 1 つのインスタンスを持ち、[reset] で停止して手放し、次の [current] で新しく作り直す入れ物。
 * Firestore のインスタンスを、ログアウトのたびに破棄して作り直すために使う（設計書 SessionManager・要件 2.9）。
 * Firebase を直接は呼ばない（本物の組み立ては [AppContainer]）。JVM の単体テストで偽物に差し替えるため。
 *
 * 使う側は、得たインスタンスを持ち続けず、操作のたびに [current] から得る（[reset] の後も古いものを使い続けないため）。
 *
 * 守っている 2 つのこと（Firestore の振る舞いは firebase-firestore 26.6.0 のバイトコードで確認。2026-10-04）:
 * - **作るたびに設定を当てる**：Firestore の getInstance は、停止（terminate）の後に呼ぶと、SDK の既定の設定
 *   （ディスクに永続化する）で新しいインスタンスを作る。[configure] を作り直しのたびにも当てないと、
 *   最初のログアウトから黙ってディスクのキャッシュが有効になる。
 * - **手放すのと「登録簿から外す」を、同じロックの中で行う**：terminate は、登録簿から外す（同期）→停止の Task を返す、の順で動く。
 *   手放してから terminate を呼ぶまでの間にロックを放すと、その間の [current] が getInstance で古いもの（まだ登録簿にある）を拾い、
 *   停止済みのインスタンスを次の [reset] まで持ち続ける。そこで [release] を「同期で始める部分」と「完了を待つ部分」に分け、
 *   前者だけをロックの中で呼ぶ（待つ部分はロックの外。待っている間の [current] は、新しいインスタンスを作って返す）。
 *
 * [reset] は同時に 2 回呼ぶことを想定していない（ログアウトと退会の完了時に 1 回ずつ。SessionManager・タスク 8.2）。
 *
 * @param create インスタンスを得る（Firestore では getInstance）。
 * @param configure 得た直後に必ず当てる設定。作り直したものにも当てる。
 * @param release 古いインスタンスの停止を始め（同期。[current] と同じロックの中で呼ぶ）、完了を待つ中断関数を返す（ロックの外で待つ）。
 */
class ResettableInstance<T : Any>(
    private val create: () -> T,
    private val configure: (T) -> Unit,
    private val release: (T) -> (suspend () -> Unit),
) {
    /** [instance] を、[current] と [reset] の間で守る。 */
    private val lock = Any()

    /** いま使っているインスタンス。まだ作っていないか、[reset] で手放した後は null。 */
    private var instance: T? = null

    /** いまのインスタンスを返す。無ければ作って設定を当てる（初回と、[reset] の後）。 */
    fun current(): T = synchronized(lock) {
        instance ?: create().also {
            // 設定は、ほかのどの呼び出しよりも前に当てる（Firestore は使い始めた後に設定を変えると例外になる）
            configure(it)
            instance = it
        }
    }

    /**
     * いまのインスタンスを停止して手放す。停止の完了を待ってから戻る。一度も作っていなければ何もしない。
     * 停止に失敗したら例外をそのまま伝える（扱いは呼び出し側が決める。タスク 8.2 の SessionManager）。
     * 失敗しても、古いインスタンスは既に手放しているので、次の [current] は作り直しを試みる。
     */
    suspend fun reset() {
        val awaitShutdown = synchronized(lock) {
            val old = instance ?: return
            // 先に手放してから停止を始める。停止の開始が例外を投げても、古いものを持ち続けない
            instance = null
            release(old)
        }
        awaitShutdown()
    }
}
