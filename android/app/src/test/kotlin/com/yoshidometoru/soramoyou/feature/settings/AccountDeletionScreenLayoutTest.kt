// ⭐️ アカウントの削除の画面で、失敗して戻ったときに理由と「再試行」が見える位置へ送ること・削除中のオフラインを案内することのソース検査（タスク 31.5・確かめる係の指摘・レビュー F19・要件 12.4・16.2・16.6）
package com.yoshidometoru.soramoyou.feature.settings

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * 画面の描画は JVM の単体テストでは確かめられない（文字サイズ 200% で失敗の表示と「再試行」が見えるかは端末で確かめる・33.x）。
 * そこで、失敗して戻ったときの縦送りの扱いを、書き方の構造として検査する（BannerAdSlotPlacementTest と同じ考え方）。
 *
 * - 削除中は説明と入力の塊（DeletionForm）を合成から外して削除中の表示に替えるので、縦送りの状態を塊の中で作ると、
 *   失敗して戻るたびに先頭から作り直される。失敗の表示と「再試行」は塊の末尾にあるので、説明の下に隠れる。
 *   そこで状態は画面（AccountDeletionScreen）で作って塊に渡す（削除中の表示は別の塊なので、自分の状態を持ってよい）。
 *   画面の中でも、削除中の表示と入れ替わる when の分岐の中で作ると同じく先頭に戻るので、分岐の外で作り、その名前を塊に渡す
 *   （レビュー 4 回目 Q25）
 * - 失敗が出たら、塊を並べ終えた後に末尾（失敗の表示と「再試行」）まで送る
 * - 削除中に通信が切れたら、削除中の表示に「接続が戻ると削除を続ける」案内を読み上げの領域で出す（レビュー F19。Firestore の削除は
 *   上限時間なしに接続を待つので、案内が無いと「〜を削除しています」のまま説明なく止まって見える。見え方は端末で確かめる・33.2）
 *
 * 見るのは文字列なので、コメントの中の一致も数える（AccountDeletionScreen.kt の説明には、丸括弧を付けた呼び出しの形を書かない）。
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`src/main/kotlin` を直接読む。
 */
class AccountDeletionScreenLayoutTest {

    private val screenSource = File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/settings/AccountDeletionScreen.kt")

    /** [source] のうち、[marker] の後に最初に現れる `{` から、対応する `}` までの塊（BannerAdSlotPlacementTest の同名の補助と同じ）。 */
    private fun blockAfter(source: String, marker: String): String {
        val markerAt = source.indexOf(marker)
        check(markerAt >= 0) { "$marker が見つからない" }
        val begin = source.indexOf('{', markerAt)
        check(begin >= 0) { "$marker の後に { が無い" }
        var depth = 0
        for (i in begin until source.length) {
            when (source[i]) {
                '{' -> depth++
                '}' -> if (--depth == 0) return source.substring(begin, i + 1)
            }
        }
        error("$marker の後の { に対応する } が無い")
    }

    private fun source(): String {
        assertTrue(screenSource.isFile, "AccountDeletionScreen.kt が見つからない: ${screenSource.absolutePath}")
        return screenSource.readText()
    }

    @Test
    fun `説明と入力の縦送りの状態は画面で作り、削除中の表示を挟んでも捨てない`() {
        val source = source()
        val screen = blockAfter(source, "fun AccountDeletionScreen(")
        val form = blockAfter(source, "private fun DeletionForm(")
        // 呼び出しの場所に寄せて when の else の中で作る形・分岐の中で同じ名前の状態を作り直す形も、削除中を挟むと先頭に戻る
        val branches = blockAfter(screen, "when {")
        val made = assertNotNull(
            Regex("""val (\w+) = rememberScrollState\(\)""").find(screen.replace(branches, "")),
            "AccountDeletionScreen の when の分岐の外で縦送りの状態を作っていない: $screen",
        )
        val passed = assertNotNull(Regex("""DeletionForm\(\s*state,\s*(\w+),""").find(branches), "when の分岐で DeletionForm を呼んでいない: $branches")

        assertEquals(made.groupValues[1], passed.groupValues[1], "DeletionForm に、画面で作った縦送りの状態でないものを渡している: $branches")
        assertFalse("remember" in branches || "ScrollState(" in branches, "when の分岐の中で状態を作っている（削除中に外れると先頭に戻る）: $branches")
        assertFalse("rememberScrollState(" in form,"DeletionForm の中で縦送りの状態を作っている（削除中に外れると先頭に戻る）: $form")
        assertTrue("verticalScroll(scrollState)" in form, "DeletionForm が渡された縦送りの状態を使っていない: $form")
    }

    @Test
    fun `失敗が出たら、並べ終えた後に末尾の失敗の表示と再試行まで送る`() {
        val form = blockAfter(source(), "private fun DeletionForm(")
        val effect = blockAfter(form, "LaunchedEffect(state.failure)")

        assertTrue("withFrameNanos" in effect, "並べ終えるのを待たずに送っている（新しい高さが分からない）: $effect")
        assertTrue("animateScrollTo(scrollState.maxValue)" in effect, "失敗が出ても末尾まで送っていない: $effect")
    }

    @Test
    fun `削除中にオフラインになったら、接続が戻ると削除を続けることを読み上げの領域で出す`() {
        val source = source()
        val screen = blockAfter(source, "fun AccountDeletionScreen(")
        val deleting = blockAfter(source, "private fun DeletingContent(")

        assertTrue("private fun DeletingContent(stage: DeletionStage?, isOnline: Boolean)" in source, "削除中の表示が接続の有無を受け取っていない")
        assertTrue("DeletingContent(stage, isOnline)" in screen, "画面が削除中の表示に接続の有無を渡していない: $screen")
        val offline = blockAfter(deleting, "if (!isOnline)")
        assertTrue("R.string.account_delete_deleting_offline" in offline, "オフラインの間に削除を続ける案内を出していない: $deleting")
        assertTrue("liveRegion = LiveRegionMode.Polite" in offline, "削除中のオフラインの案内が読み上げの領域になっていない: $offline")
    }
}
