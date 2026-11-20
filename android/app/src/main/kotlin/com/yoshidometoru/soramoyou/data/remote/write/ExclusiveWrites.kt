// ⭐️ 書き込みの入口が「この区間は決めた 1 種類の書き込みだけを通す」ための印（タスク 31.2 の確かめる係の指摘の直し・要件 12.3）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.contract.WriteCapability

/**
 * 書き込みの入口（[DefaultFirestoreWriteGateway]・[DefaultStorageGateway]）が 1 つずつ持つ、「いまは [WriteCapability] の 1 種類だけを通す」区間の印。
 *
 * 使うのは退会（ACCOUNT_DELETE。タスク 31.2）。退会は画面を離れても最後まで続く（NonCancellable）ので、その間は、補完
 * （AccountDocumentRepairer）・プロフィールの保存・投稿・いいねなど退会以外の書き込みを、全ての書き込みが通る入口で断る。
 *
 * - 入れ子と同時の区間は、同じ種類なら数えて、最後の区間が終わったときに外す（退会は同時に 2 回呼ばない約束だが、呼ばれても印が先に外れない）
 * - 別の種類の区間の中で区間に入ろうとするのは呼び出しの誤りとして、[IllegalStateException] で止める（いま使うのは退会だけ）
 * - 認証の状態の通知や画面の操作は別のスレッドから来うるので、読み書きは同期の中だけで行う
 */
internal class ExclusiveWrites {

    /** いま通している 1 種類（区間の外なら null）。 */
    private var holder: WriteCapability? = null

    /** 入っている区間の数。0 になったら [holder] を外す。 */
    private var depth = 0

    /** [cap] だけを通す区間で [block] を実行する。[block] が終われば（成功・失敗・例外・取り消しのどれでも）区間を出る。 */
    suspend fun <T> run(cap: WriteCapability, block: suspend () -> T): T {
        enter(cap)
        try {
            return block()
        } finally {
            exit()
        }
    }

    /** [cap] の書き込みを、いまの区間が断るなら、その区間の種類を返す（断らないなら null）。 */
    @Synchronized
    fun refusing(cap: WriteCapability): WriteCapability? = holder?.takeIf { it != cap }

    @Synchronized
    private fun enter(cap: WriteCapability) {
        check(holder == null || holder == cap) { "別の種類の区間の中で区間に入ろうとした: ${holder?.name} の中で ${cap.name}" }
        holder = cap
        depth++
    }

    @Synchronized
    private fun exit() {
        depth--
        if (depth == 0) holder = null
    }
}
