// ⭐️ Crashlytics まわりの記録用の偽物（タスク 4.2 のテストで共有する）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.Uid
import java.util.concurrent.CopyOnWriteArrayList

/**
 * [CrashReporter] の記録用の偽物。呼ばれた内容を呼ばれた順に残す。
 * 窓口（[DefaultAnalyticsFacade]）の setUserId は別スレッドから来うるので、記録には並行に安全なリストを使う。
 *
 * @param failing true なら、記録したあとで例外を投げる（握りつぶしの確認用）
 */
class FakeCrashReporter(private val failing: Boolean = false) : CrashReporter {
    /** recordNonFatal の 1 回分。 */
    data class NonFatal(val error: AppError, val context: String, val extra: Map<String, String>)

    val nonFatals = CopyOnWriteArrayList<NonFatal>()
    val userIds = CopyOnWriteArrayList<Uid?>()

    override fun recordNonFatal(error: AppError, context: String, extra: Map<String, String>) {
        nonFatals += NonFatal(error, context, extra)
        if (failing) throw IllegalStateException("CrashReporter の偽物の失敗")
    }

    override fun setUserId(uid: Uid?) {
        userIds += uid
        if (failing) throw IllegalStateException("CrashReporter の偽物の失敗")
    }
}

/**
 * [CrashlyticsClient] の記録用の偽物。SDK に渡るはずの例外・キー・ユーザー ID を残す。
 *
 * @param failing true なら、記録したあとで例外を投げる（握りつぶしの確認用）
 */
class FakeCrashlyticsClient(private val failing: Boolean = false) : CrashlyticsClient {
    /** recordException の 1 回分。 */
    data class Recorded(val throwable: Throwable, val keys: Map<String, String>)

    val recorded = mutableListOf<Recorded>()
    val userIds = mutableListOf<String>()

    override fun recordException(throwable: Throwable, keys: Map<String, String>) {
        recorded += Recorded(throwable, keys)
        if (failing) throw IllegalStateException("Crashlytics の偽物の失敗")
    }

    override fun setUserId(id: String) {
        userIds += id
        if (failing) throw IllegalStateException("Crashlytics の偽物の失敗")
    }
}
