// ⭐️ AppContainer が Firestore の入れ物にメモリだけの設定を当てる結線の検査（タスク 5.1・要件 2.2・2.9）
package com.yoshidometoru.soramoyou.di

import java.io.File
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Firestore のローカルキャッシュをメモリだけにする仕組みは、3 つのつながりでできている。
 * memoryOnly の中身（FirestoreSettingsFactoryTest）、作るたびに configure を当てること（ResettableInstanceTest）、
 * そして AppContainer が Firestore の入れ物の configure に memoryOnly の設定を渡す結線（この検査）。
 * 結線は本物の Firestore を作らないと動かして確かめられないので、ソースの文字列で確かめる
 * （この検査が無いと、configure を何もしない形にしてもほかのテストは全て通り、黙ってディスクのキャッシュが有効になる）。
 *
 * 停止の手順（terminate の後に clearPersistence。設計書 SessionManager）も、同じ入れ物の release の中のソースの並びで確かめる。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class FirestoreMemoryCacheWiringTest {

    private val appContainer = File("src/main/kotlin", FirebaseInstanceCreationScanner.ALLOWED_PATH)

    /** 陽性対照のための一時的なソースの置き場。テストごとに消す。 */
    private val fixtureRoot: File = createTempDirectory("firestore-wiring").toFile()

    @AfterTest
    fun deleteFixtures() {
        fixtureRoot.deleteRecursively()
    }

    private fun fixture(source: String): File =
        File(fixtureRoot, "AppContainer.kt").apply { writeText(source) }

    /** 本物の AppContainer の Firestore の入れ物を読む。見つからなければ失敗にする（空振りで通らないように）。 */
    private fun realWiring(): FirestoreMemoryCacheWiringScanner.Wiring {
        assertTrue(appContainer.isFile, "AppContainer が見つからない: ${appContainer.absolutePath}")
        return assertNotNull(
            FirestoreMemoryCacheWiringScanner.inspect(appContainer),
            "AppContainer に Firestore の入れ物（ResettableInstance<FirebaseFirestore> を作る呼び出し）が見つからない",
        )
    }

    @Test
    fun `本物のAppContainerのFirestoreの入れ物は、作るたびにmemoryOnlyの設定を当てる`() {
        assertTrue(
            realWiring().configuresMemoryOnly,
            "Firestore の入れ物の configure が FirestoreSettingsFactory.memoryOnly() の設定を当てていない",
        )
    }

    @Test
    fun `本物のAppContainerのFirestoreの入れ物は、停止でterminateの後にclearPersistenceを呼ぶ`() {
        assertTrue(
            realWiring().terminatesBeforeClearPersistence,
            "Firestore の入れ物の release で、terminate が clearPersistence より前に書かれていない",
        )
    }

    @Test
    fun `陽性対照：configureが何もしなければ検出する`() {
        val wiring = FirestoreMemoryCacheWiringScanner.inspect(
            fixture(
                """
                val firestore: ResettableInstance<FirebaseFirestore> = ResettableInstance(
                    create = { make() },
                    configure = {},
                    release = { old -> val t = old.terminate(); suspend { old.clearPersistence() } },
                )
                """.trimIndent(),
            ),
        )

        assertFalse(assertNotNull(wiring).configuresMemoryOnly)
    }

    @Test
    fun `陽性対照：memoryOnlyがFirestoreの入れ物の外にしか無ければ検出する`() {
        // 読む範囲が Firestore の入れ物の丸括弧の中に限られていること（別の入れ物・コメント・別の値は数えない）
        val wiring = FirestoreMemoryCacheWiringScanner.inspect(
            fixture(
                """
                val other: ResettableInstance<Other> = ResettableInstance(
                    create = { Other() },
                    configure = { it.firestoreSettings = FirestoreSettingsFactory.memoryOnly() },
                    release = { suspend {} },
                )
                // configure = { it.firestoreSettings = FirestoreSettingsFactory.memoryOnly() }
                val settings = FirestoreSettingsFactory.memoryOnly()
                val firestore = ResettableInstance<FirebaseFirestore>(
                    create = { make() },
                    configure = { it.firestoreSettings = settingsOf(it) },
                    release = { suspend {} },
                )
                """.trimIndent(),
            ),
        )

        assertFalse(assertNotNull(wiring).configuresMemoryOnly)
    }

    @Test
    fun `陽性対照：clearPersistenceをterminateより先に書けば検出する`() {
        val wiring = FirestoreMemoryCacheWiringScanner.inspect(
            fixture(
                """
                val firestore: ResettableInstance<FirebaseFirestore> = ResettableInstance(
                    create = { make() },
                    configure = { it.firestoreSettings = FirestoreSettingsFactory.memoryOnly() },
                    release = { old ->
                        val cleared = old.clearPersistence()
                        suspend { cleared.await(); old.terminate().await() }
                    },
                )
                """.trimIndent(),
            ),
        )

        assertFalse(assertNotNull(wiring).terminatesBeforeClearPersistence)
    }

    @Test
    fun `Firestoreの入れ物が無ければ読めないことを返す`() {
        // 本物のソースの検査が「入れ物が見つからないまま」通らないこと（realWiring は null を失敗にする）
        val wiring = FirestoreMemoryCacheWiringScanner.inspect(
            fixture(
                """
                val storage: ResettableInstance<FirebaseStorage> = ResettableInstance(
                    create = { make() },
                    configure = { it.firestoreSettings = FirestoreSettingsFactory.memoryOnly() },
                    release = { old -> old.terminate(); suspend { old.clearPersistence() } },
                )
                """.trimIndent(),
            ),
        )

        assertNull(wiring)
    }

    @Test
    fun `空白と改行を挟んだ書き方と、名前を付けた引数の書き方も読める`() {
        val wiring = FirestoreMemoryCacheWiringScanner.inspect(
            fixture(
                """
                val firestore = ResettableInstance <
                    FirebaseFirestore > (
                    create = { make() },
                    configure = { db ->
                        db
                            .setFirestoreSettings(
                                FirestoreSettingsFactory
                                    .memoryOnly( )
                            )
                    },
                    release = { old ->
                        val terminated = old
                            .terminate()
                        suspend { terminated.await(); old . clearPersistence ( ).await() }
                    },
                )
                """.trimIndent(),
            ),
        )

        val read = assertNotNull(wiring, "Firestore の入れ物が見つからなかった")
        assertTrue(read.configuresMemoryOnly, "memoryOnly を当てていると読めなかった")
        assertTrue(read.terminatesBeforeClearPersistence, "terminate の後に clearPersistence と読めなかった")
    }
}
