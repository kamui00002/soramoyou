// ⭐️ オフラインの表示で、再試行を有効にするかと案内の文言を決める純関数の単体テスト（タスク 5.2・要件 16.3）
package com.yoshidometoru.soramoyou.ui.component

import com.yoshidometoru.soramoyou.R
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 要件 16.3「ネットワークに接続できない場合は、接続できない旨を表示し、接続が戻ったら再試行できるようにする」のうち、
 * 接続の有無（NetworkMonitor.isOnline）から表示を決める部分。描画は端末で確かめる（タスク 11.3）。
 */
class OfflineRetryStateTest {

    @Test
    fun `オフラインのあいだは接続できない旨を出し、再試行を無効にする`() {
        assertEquals(
            OfflineRetryState(
                titleRes = R.string.offline_title,
                messageRes = R.string.offline_message,
                retryEnabled = false,
            ),
            offlineRetryState(isOnline = false),
        )
    }

    @Test
    fun `接続が戻ったら、戻った旨を出し、再試行を有効にする`() {
        // 「接続できません」のまま押せるボタンを出さない（文言とボタンの状態を食い違わせない）
        assertEquals(
            OfflineRetryState(
                titleRes = R.string.reconnected_title,
                messageRes = R.string.reconnected_message,
                retryEnabled = true,
            ),
            offlineRetryState(isOnline = true),
        )
    }
}
