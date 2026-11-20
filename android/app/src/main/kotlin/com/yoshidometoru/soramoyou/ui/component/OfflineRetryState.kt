// ⭐️ オフラインの表示で、案内の文言と再試行の可否を決める（タスク 5.2・要件 16.3）
package com.yoshidometoru.soramoyou.ui.component

import androidx.annotation.StringRes
import com.yoshidometoru.soramoyou.R

/**
 * オフラインの表示（[OfflineContent]）に出す見出し・案内と、再試行のボタンを押せるか。
 *
 * @property titleRes 見出しの文字列リソース
 * @property messageRes 案内の文字列リソース
 * @property retryEnabled 再試行のボタンを押せるか
 */
data class OfflineRetryState(
    @param:StringRes val titleRes: Int,
    @param:StringRes val messageRes: Int,
    val retryEnabled: Boolean,
)

/**
 * 接続の有無（NetworkMonitor.isOnline の値）から、オフラインの表示の中身を決める。描画から切り離した純関数にして、JVM の単体テストで確かめる。
 *
 * - オフラインのあいだは「ネットワークに接続できません」（iOS の ErrorStateView の見出しと同じ）と出し、再試行を押せなくする。
 *   押しても失敗するだけなので、押せる見た目にしない。
 * - 接続が戻ったら「接続が戻りました」と出し、再試行を押せるようにする（要件 16.3「接続が戻ったら再試行できるようにする」）。
 *   「接続できません」のまま押せるボタンを出すと、文言とボタンが食い違うため、見出しも切り替える。
 *
 * 接続が戻ったときに自動では再試行しない（再試行はユーザーが押したときだけ。設計書は自動の再試行を決めていない）。
 *
 * [isOnline] が true のときの中身（「接続が戻りました」）は、オフラインで出した表示が、接続の回復を受けて切り替わった後にだけ使う。
 * オフラインの表示を出すのは、失敗した時点で `!isOnline` だったときだけで、オンラインのまま失敗したら ErrorContent を出す
 * （呼び出し側の契約。NetworkMonitor の fail-open との関係も含めて [OfflineContent] を参照）。
 */
fun offlineRetryState(isOnline: Boolean): OfflineRetryState =
    if (isOnline) {
        OfflineRetryState(
            titleRes = R.string.reconnected_title,
            messageRes = R.string.reconnected_message,
            retryEnabled = true,
        )
    } else {
        OfflineRetryState(
            titleRes = R.string.offline_title,
            messageRes = R.string.offline_message,
            retryEnabled = false,
        )
    }
