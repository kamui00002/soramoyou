// ⭐️ バナー広告の枠が、いつ畳まれ、いつ高さを持つかの単体テスト（タスク 32.2・要件 14.4・14.5）
package com.yoshidometoru.soramoyou.feature.ads

import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import kotlin.math.ceil
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 枠の状態（[bannerSlotStateOf]）と高さ（[bannerFrameHeightPx]）の約束。描画（AndroidView の載せ方・文字を大きくしたときの見え方）は端末で確かめる。
 *
 * 約束は 3 つ。
 * - 広告の準備ができた後は枠を確保し、読み込みに失敗したら畳む。畳むだけで、他の操作は妨げない（要件 14.4）
 * - 枠の高さは広告の規格（広告 SDK が px に直した値）だけで決まり、文字の大きさに依らない。キーボードが出ているあいだは隠す（要件 14.5）
 * - 枠の高さの px を dp に直して Compose に渡しても、広告 SDK の px ちょうどに戻る（1px 欠けて広告 SDK が足りないと言わない）
 *
 * 広告の準備ができるまで（同意の取得・初期化・失敗・このビルドでは出さない）枠を持たないことは、ここでは確かめない。
 * 枠ごと描かないと決めているのは BannerAdSlot（広告の準備の状態が Ready でなければ何も描かない）で、[bannerSlotStateOf] には来ないため。
 */
class BannerSlotStateTest {

    @Test
    fun `広告の準備ができて、読み込み中のあいだは枠を確保する`() {
        // 読み込めたときに本文が押し下げられないよう、先に高さを確保する（失敗したら畳む）
        assertEquals(BannerSlotState.LOADING, bannerSlotStateOf(BannerLoad.Pending))
    }

    @Test
    fun `広告を読み込めたら表示する`() {
        assertEquals(BannerSlotState.SHOWN, bannerSlotStateOf(BannerLoad.Loaded))
    }

    @Test
    fun `広告の読み込みに失敗したら枠を畳む`() {
        assertEquals(BannerSlotState.COLLAPSED, bannerSlotStateOf(BannerLoad.Failed("no fill")))
    }

    @Test
    fun `畳んだ枠は高さを持たない`() {
        assertEquals(0, bannerFrameHeightPx(BannerSlotState.COLLAPSED, adHeightPx = 132, imeVisible = false))
    }

    @Test
    fun `確保した枠と表示中の枠は、広告の規格の高さを持つ`() {
        // 高さは広告 SDK が px に直した広告の規格で決まる（132 は、画面密度 2.625 の端末で 50dp を切り上げた値）。
        // 文字の大きさ（fontScale）は入力に無く、200% でも変わらない
        assertEquals(132, bannerFrameHeightPx(BannerSlotState.LOADING, adHeightPx = 132, imeVisible = false))
        assertEquals(237, bannerFrameHeightPx(BannerSlotState.SHOWN, adHeightPx = 237, imeVisible = false))
    }

    @Test
    fun `キーボードが出ているあいだは、枠の高さを持たない`() {
        // 入力欄のある画面（キャプション・プロフィール）で、広告が入力の邪魔にならないように隠す。広告は捨てず、閉じたら元の高さに戻す
        BannerSlotState.entries.forEach { slot ->
            assertEquals(0, bannerFrameHeightPx(slot, adHeightPx = 132, imeVisible = true), "slot=$slot")
        }
    }

    @Test
    fun `枠の高さのpxは、dpに直してComposeに渡しても同じpxに戻る`() {
        // 広告 SDK の AdSize の getHeightInPixels は、dp を px に直して切り上げる（1.5.0 のバイトコードで確かめた・2026-11-08）。
        // BannerAdSlot はその px を dp に直して枠の高さに渡し、Compose はそれを四捨五入で px に戻す。ここで同じ px に戻ることを確かめる。
        // 密度は Android の代表的な値（ldpi〜xxxhdpi と、Pixel 系の 420dpi＝2.625・440dpi＝2.75）
        val densities = listOf(0.75f, 1f, 1.5f, 2f, 2.625f, 2.75f, 3f, 3.5f, 4f)
        densities.forEach { density ->
            listOf(50, 90).forEach { adHeightDp ->
                val sdkPx = ceil(adHeightDp * density).toInt()
                val roundTrip = with(Density(density)) { sdkPx.toDp().roundToPx() }
                assertEquals(sdkPx, roundTrip, "density=$density adHeightDp=$adHeightDp")
            }
        }
    }

    @Test
    fun `dpの規格のまま渡すと、画面密度2_625では広告SDKのpxより1px欠ける`() {
        // 直す前の書き方（高さを 50dp のまま渡す）で、タスク 34 の Logcat の「411x49dp しか無い」が出ていた理由。
        // Compose は 131.25 を四捨五入して 131、広告 SDK は切り上げて 132 を求める。この差があるので、枠は px で決める
        val composePx = with(Density(2.625f)) { 50.dp.roundToPx() }
        val sdkPx = ceil(50 * 2.625f).toInt()
        assertEquals(131, composePx)
        assertEquals(132, sdkPx)
    }
}
