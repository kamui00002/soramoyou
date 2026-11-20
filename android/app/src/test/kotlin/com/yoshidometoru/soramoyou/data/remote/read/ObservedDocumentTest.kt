// ⭐️ 文書の監視が、オフラインでキャッシュに無い文書を「無い」でなく通信の失敗として閉じることの検査（レビュー R17）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * SDK のスナップショット（DocumentSnapshot）は JVM の単体テストで作れない（Robolectric も無い）。そこで、判定を切り出した純関数
 * [observedDocumentOf] を確かめ、監視（FirebaseFirestoreReadClient の observe）がそれを通して流す・閉じることは、ソースの書き方で固定する
 * （PrivacyPolicyLinkTest と同じ考え方。:app の単体テストの作業ディレクトリは android/app なので、`src/main` を直接読む）。
 * ソースは observe の本体だけを、コメントの行（`//` で始まる行）と空行を除いて見る。直しの行をコメントにして元へ戻しても緑にならないように。
 *
 * 閉じた後は、読み取りの入口（DefaultFirestoreReader の observe）が `Err(Network)` を 1 回流して終わる（DefaultFirestoreReaderTest が確かめる写し）。
 */
class ObservedDocumentTest {

    private val document = RawDocument(id = "me", data = mapOf("displayName" to "そら"))

    @Test
    fun `オフラインでキャッシュに無い文書は「無い」でなくNetworkの失敗にする`() {
        assertEquals(AppResult.Err(AppError.Network), observedDocumentOf(null, isFromCache = true))
    }

    @Test
    fun `サーバーが無いと答えた文書は今どおり中身なしで流す`() {
        assertEquals(AppResult.Ok(null), observedDocumentOf(null, isFromCache = false))
    }

    @Test
    fun `ある文書はキャッシュからでもサーバーからでもそのまま流す`() {
        assertEquals(AppResult.Ok(document), observedDocumentOf(document, isFromCache = true))
        assertEquals(AppResult.Ok(document), observedDocumentOf(document, isFromCache = false))
    }

    /**
     * FirebaseFirestoreReadClient の observe の本体（`override fun observe(` から `awaitClose` まで）の行。
     * 前後の空白を落とし、コメントの行と空行を除く。見つからなければ失敗にする（空振りで通らないように）。
     */
    private fun observeCodeLines(): List<String> {
        val file = File("src/main/kotlin/com/yoshidometoru/soramoyou/data/remote/read/FirebaseFirestoreReadClient.kt")
        assertTrue(file.isFile, "FirebaseFirestoreReadClient.kt が見つからない: ${file.absolutePath}")
        val lines = file.readLines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("//") }
        val start = lines.indexOfFirst { it.startsWith("override fun observe(") }
        assertTrue(start >= 0, "FirebaseFirestoreReadClient に observe が見つからない")
        val end = assertNotNull((start until lines.size).firstOrNull { lines[it].startsWith("awaitClose") }, "observe の awaitClose が見つからない")
        return lines.subList(start, end + 1)
    }

    @Test
    fun `監視は届いた中身とキャッシュからかをこの判定に通し、失敗なら写した種類で流れを閉じる`() {
        val lines = observeCodeLines()

        assertTrue(
            lines.any { "observedDocumentOf(snapshot.toRawDocument(), snapshot.metadata.isFromCache)" in it },
            "監視が届いた中身を、キャッシュからかと一緒に判定へ通していない",
        )
        assertTrue(lines.any { "close(FirestoreReadFailure(observed.error," in it }, "判定の失敗で、写した種類のまま流れを閉じていない")
    }

    @Test
    fun `監視が流すのは判定のOkの値だけで、判定を通らない送信をしない`() {
        // 判定の前に届いた中身をそのまま流すと、キャッシュの「無い」を 1 回流してから閉じる。Ok の枝で流さないと、画面は読み込み中のまま
        val sends = observeCodeLines().filter { "trySend(" in it }

        assertEquals(listOf("is AppResult.Ok -> trySend(observed.value)"), sends, "監視が判定の Ok の値だけを流していない")
    }
}
