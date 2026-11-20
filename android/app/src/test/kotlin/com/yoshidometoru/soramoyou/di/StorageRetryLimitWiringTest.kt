// ⭐️ AppContainer が Storage の再試行の上限を短くする結線の検査（レビュー R06）
package com.yoshidometoru.soramoyou.di

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Storage の SDK は、電波が切れたとき既定でアップロードと削除を約 10 分、URL の取得を約 2 分再試行し続ける。
 * 投稿の画面はアップロード中に離れられない（決定②）ので、その間ずっと出られなくなる。
 * AppContainer が Storage のインスタンスを作る `val storage ... by lazy { }` の中で、3 つの上限を同じ定数（60 秒）にしていることを確かめる。
 * 本物の Storage は作れないので、ソースの文字列で確かめる（検査の範囲は lazy のブロックの中に限り、
 * ファイルのほかの場所に同じ行があっても通さない）。
 *
 * 探す前にコメント（ブロックコメントと、行コメントの `//` から行末まで）を除く。代入をコメントにして SDK の既定へ戻しても
 * 緑にならないようにするため。文字列の中の `//` やブロックコメントの開きの記号もコメントとして消し、入れ子のブロックコメントも
 * 扱わないので、そういう文字列・コメントを Storage の lazy とその手前に書くと切り出しを誤る（いまの AppContainer には無い）。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class StorageRetryLimitWiringTest {

    private val appContainer = File("src/main/kotlin", FirebaseInstanceCreationScanner.ALLOWED_PATH)

    private fun appContainerSource(): String {
        assertTrue(appContainer.isFile, "AppContainer が見つからない: ${appContainer.absolutePath}")
        return appContainer.readText()
    }

    /**
     * [source] の、`val storage: FirebaseStorage by lazy {` から対応する閉じ括弧までの中身（コメントを除いたもの）。
     * 見つからなければ失敗にする（空振りで通らないように）。
     */
    private fun storageBlock(source: String): String {
        val code = withoutComments(source)
        val head = "val storage: FirebaseStorage by lazy {"
        val start = code.indexOf(head)
        assertTrue(start >= 0, "AppContainer に Storage のインスタンス（$head）が見つからない")
        var depth = 0
        var i = start + head.length - 1 // 開き括弧の位置
        while (i < code.length) {
            when (code[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return code.substring(start, i + 1)
                }
            }
            i++
        }
        error("Storage のインスタンスの lazy の閉じ括弧が見つからない")
    }

    private fun setsLimit(source: String, property: String): Boolean =
        Regex("""\bit\.$property\s*=\s*STORAGE_RETRY_LIMIT_MILLIS\b""").containsMatchIn(storageBlock(source))

    private fun assertSetsLimit(property: String) {
        assertTrue(
            setsLimit(appContainerSource(), property),
            "Storage のインスタンスの lazy の中で $property に STORAGE_RETRY_LIMIT_MILLIS を入れていない",
        )
    }

    /**
     * 陽性対照の写しで、[line] を [replacement] にしたもの。[line] がちょうど 1 か所あることも確かめる（置き換えの空振りで緑にならないように）。
     * 写しは本物の AppContainer に頼らない（本物の別の行が壊れたとき、陽性対照まで道連れで赤にならないように）。
     */
    private fun fixtureWith(line: String, replacement: String): String {
        assertEquals(1, Regex.fromLiteral(line).findAll(FIXTURE).count(), "陽性対照の写しに「$line」が 1 か所ではない")
        return FIXTURE.replace(line, replacement)
    }

    @Test
    fun `Storageのインスタンスは、アップロードの再試行の上限を短くする`() {
        assertSetsLimit("maxUploadRetryTimeMillis")
    }

    @Test
    fun `Storageのインスタンスは、削除の再試行の上限を短くする`() {
        assertSetsLimit("maxDownloadRetryTimeMillis")
    }

    @Test
    fun `Storageのインスタンスは、URL取得の再試行の上限を短くする`() {
        assertSetsLimit("maxOperationRetryTimeMillis")
    }

    @Test
    fun `陽性対照：上限の代入を行コメントにすると検出する`() {
        // 写しのままなら見つかる（下の false が、コメントにしたことによるものだと言えるように）
        assertTrue(setsLimit(FIXTURE, "maxUploadRetryTimeMillis"))
        val line = "it.maxUploadRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS"
        val source = fixtureWith(line, "// $line")

        assertFalse(setsLimit(source, "maxUploadRetryTimeMillis"))
        // 切り出しは崩れていない（ほかの代入は見つかる）
        assertTrue(setsLimit(source, "maxDownloadRetryTimeMillis"))
    }

    @Test
    fun `陽性対照：上限の代入をブロックコメントにすると検出する`() {
        assertTrue(setsLimit(FIXTURE, "maxDownloadRetryTimeMillis"))
        val line = "it.maxDownloadRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS"
        val source = fixtureWith(line, "/* $line */")

        assertFalse(setsLimit(source, "maxDownloadRetryTimeMillis"))
        assertTrue(setsLimit(source, "maxOperationRetryTimeMillis"))
    }

    @Test
    fun `再試行の上限の定数は60秒である`() {
        val match = Regex("""const val STORAGE_RETRY_LIMIT_MILLIS\s*=\s*([0-9_]+)L""")
            .find(appContainer.readText())
        val value = assertNotNull(match, "AppContainer に STORAGE_RETRY_LIMIT_MILLIS の定義が見つからない")
            .groupValues[1].replace("_", "").toLong()
        assertTrue(value == 60_000L, "STORAGE_RETRY_LIMIT_MILLIS が 60 秒（60000）でない: $value")
    }

    private companion object {
        /** 陽性対照の写し（本物の Storage の lazy と同じ形。手前の KDoc も含める）。 */
        val FIXTURE = """
            /** Storage のインスタンス。 */
            val storage: FirebaseStorage by lazy {
                FirebaseStorage.getInstance(firebaseApp).also {
                    it.maxUploadRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS
                    it.maxDownloadRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS
                    it.maxOperationRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS
                    if (BuildConfig.USE_FIREBASE_EMULATOR) it.useEmulator(FirebaseEmulator.HOST, FirebaseEmulator.STORAGE_PORT)
                }
            }
        """.trimIndent()

        /** ブロックコメント（KDoc を含む）。行コメントより先に消す（KDoc の中に `//` があると、行コメントとしてブロックの閉じまで消してしまうため）。 */
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

        /** 行コメント（`//` から行末まで）。 */
        val LINE_COMMENT = Regex("""//[^\n]*""")

        fun withoutComments(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")
    }
}
