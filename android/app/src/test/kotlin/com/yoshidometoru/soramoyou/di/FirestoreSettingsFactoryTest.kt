// ⭐️ Firestore のローカルキャッシュをメモリだけにする設定の単体テスト（タスク 5.1・要件 2.2・2.9）
package com.yoshidometoru.soramoyou.di

import com.google.firebase.firestore.FirebaseFirestoreSettings
import com.google.firebase.firestore.MemoryCacheSettings
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * Firestore のキャッシュをディスクに永続化しない（設計書「M1の書き込みゼロ保証」6・research.md の判断）。
 * オフラインの書き込みの待ち行列も、ログアウトした人の読み取り結果も、端末に残さないため。
 *
 * FirebaseFirestoreSettings.Builder・MemoryCacheSettings は Android に依存しない Java のクラスなので、JVM の単体テストで作れる。
 */
class FirestoreSettingsFactoryTest {

    // isPersistenceEnabled は非推奨だが、cacheSettings が null（既定）のときに SDK が実際に使う値を読めるのはこれだけなので使う
    @Suppress("DEPRECATION")
    @Test
    fun `陽性対照：SDKの既定の設定はディスクに永続化する（下の検査はこれを見分けられる）`() {
        // firebase-firestore 26.6.0 の Builder の既定は persistenceEnabled = true（javap で確認）。
        // 設定を当て忘れたインスタンスはこの状態になる
        val defaults = FirebaseFirestoreSettings.Builder().build()

        assertTrue(defaults.isPersistenceEnabled)
        assertFalse(defaults.cacheSettings is MemoryCacheSettings)
    }

    @Suppress("DEPRECATION")
    @Test
    fun `ローカルキャッシュはメモリだけで、ディスクに永続化しない`() {
        val settings = FirestoreSettingsFactory.memoryOnly()

        assertIs<MemoryCacheSettings>(settings.cacheSettings)
        assertFalse(settings.isPersistenceEnabled)
    }

    @Test
    fun `接続先のホストとSSLはSDKの既定のまま（本番のFirestoreへ向く）`() {
        val settings = FirestoreSettingsFactory.memoryOnly()
        val defaults = FirebaseFirestoreSettings.Builder().build()

        assertEquals(defaults.host, settings.host)
        assertEquals(defaults.isSslEnabled, settings.isSslEnabled)
    }
}
