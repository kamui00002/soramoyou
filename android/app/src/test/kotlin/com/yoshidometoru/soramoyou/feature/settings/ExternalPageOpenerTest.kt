// ⭐️ 外のブラウザでページを開く守り（tryOpenUri）と、設定・新規登録の画面がそれを通して開くことの検査（全体レビュー 4 回目 Q06）
package com.yoshidometoru.soramoyou.feature.settings

import android.content.ActivityNotFoundException
import androidx.compose.ui.platform.UriHandler
import com.yoshidometoru.soramoyou.ui.UiTextSources
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * 開けるアプリが無い端末では、Compose の窓口は IllegalArgumentException（中身は ActivityNotFoundException）を投げる。
 * 守りがそれを受け止めて false を返すことを、投げる偽物の窓口で確かめる（ブラウザの無い端末は JVM の単体テストでは作れない）。
 * 画面が守りを通してだけ開くことと、開けなかったアドレスを出すことは、コメントを除いた画面のソースで確かめる（LegalLinkSources）。
 */
class ExternalPageOpenerTest {

    /** 開こうとした URL を記録し、[error] があればそれを投げる偽物の窓口。 */
    private class FakeUriHandler(private val error: RuntimeException? = null) : UriHandler {
        val opened = mutableListOf<String>()

        override fun openUri(uri: String) {
            opened += uri
            error?.let { throw it }
        }
    }

    @Test
    fun `開けたらtrueを返し、渡したURLを1回だけ開く`() {
        val handler = FakeUriHandler()

        assertTrue(handler.tryOpenUri(PRIVACY_POLICY_URL), "開けたのに false を返した")
        assertEquals(listOf(PRIVACY_POLICY_URL), handler.opened)
    }

    @Test
    fun `開けるアプリが無くてIllegalArgumentExceptionが来ても、外へ投げずにfalseを返す`() {
        // Compose の窓口が、開けるアプリが無いときに投げる形（中身に ActivityNotFoundException を持つ）
        val handler = FakeUriHandler(IllegalArgumentException("開けるアプリが無い", ActivityNotFoundException()))

        assertFalse(handler.tryOpenUri(TERMS_OF_SERVICE_URL), "開けなかったのに true を返した")
        assertEquals(listOf(TERMS_OF_SERVICE_URL), handler.opened)
    }

    @Test
    fun `ActivityNotFoundExceptionが来ても、外へ投げずにfalseを返す`() {
        // 窓口が包み直さずにそのまま投げる場合（AccountDeletionScreen の受付ページと同じく、こちらも受け止める）
        val handler = FakeUriHandler(ActivityNotFoundException())

        assertFalse(handler.tryOpenUri(PRIVACY_POLICY_URL), "開けなかったのに true を返した")
        assertEquals(listOf(PRIVACY_POLICY_URL), handler.opened)
    }

    @Test
    fun `設定と新規登録の画面は、守りを通してだけページを開き、開けなかったアドレスを出す`() {
        mapOf("設定" to LegalLinkSources.settings, "新規登録" to LegalLinkSources.signUp).forEach { (screen, code) ->
            assertEquals(0, OPEN_URI.findAll(code).count(), "${screen}の画面が、守りを通さずにページを開いている")
            assertEquals(1, TRY_OPEN_URI.findAll(code).count(), "${screen}の画面が、守りを 1 か所（法的情報のページを開く窓口）で呼んでいない")
            assertEquals(1, UNOPENED_ADDRESS.findAll(code).count(), "${screen}の画面が、開けなかったアドレスを 1 か所で出していない")
        }
    }

    @Test
    fun `開けなかったときの文言は退会の受付ページと同じで、アドレスの差し込み口がある`() {
        val strings = UiTextSources.readStrings()
        val message = assertNotNull(strings["external_page_open_failed"], "strings.xml に external_page_open_failed が無い")

        assertEquals(strings["account_delete_request_page_open_failed"], message, "退会の受付ページを開けなかったときの文言と違う")
        assertTrue("%1\$s" in message, "アドレスの差し込み口（%1\$s）が無い")
    }

    private companion object {
        /** 素の窓口の呼び出し（守りの tryOpenUri は大文字の O なので数えない）。 */
        val OPEN_URI = Regex("""\bopenUri\s*\(""")

        /** 守りの呼び出し。 */
        val TRY_OPEN_URI = Regex("""\.tryOpenUri\s*\(""")

        /** 開けなかったアドレスの表示。 */
        val UNOPENED_ADDRESS = Regex("""\bUnopenedPageAddress\s*\(""")
    }
}
