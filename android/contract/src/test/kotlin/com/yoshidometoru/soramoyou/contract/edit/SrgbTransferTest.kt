// ⭐️ sRGB の伝達関数の単体テスト（Kiro android-edit-tools タスク 4・C1・design.md:1123 の⑥）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [SrgbTransfer] が sRGB の区分の式（IEC 61966-2-1）の値を出すこと、256 階調が線形との往復で変わらないことを確かめる。
 *
 * 往復だけだと「互いに逆の関数の組」なら何でも通るので、式の値そのもの（区分の境目の両側と曲線の上の点）も
 * 手で計算した数字で固定する。途中の計算は各行の横に書いた。
 */
class SrgbTransferTest {

    @Test
    fun `線形にする式は区分の式の値になる`() {
        // 境目（0.04045）以下は直線 c÷12.92
        assertEquals(0.0, SrgbTransfer.toLinear(0.0), 1e-11)
        assertEquals(0.001547987616, SrgbTransfer.toLinear(0.02), 1e-11)        // 0.02÷12.92
        assertEquals(0.003130804954, SrgbTransfer.toLinear(0.04045), 1e-11)     // 0.04045÷12.92（境目の上の式でも同じ値に続く）
        // 境目より上は ((c＋0.055)÷1.055)^2.4
        assertEquals(0.214041140482, SrgbTransfer.toLinear(0.5), 1e-11)         // (0.555÷1.055)^2.4＝0.526066350711^2.4
        assertEquals(0.215860500114, SrgbTransfer.toLinear(128.0 / 255.0), 1e-11) // 灰 128（design.md:846 の線形 0.2158）
        assertEquals(0.522521553968, SrgbTransfer.toLinear(0.75), 1e-11)        // (0.805÷1.055)^2.4
        assertEquals(1.0, SrgbTransfer.toLinear(1.0), 1e-11)
    }

    @Test
    fun `ガンマ付きに戻す式は区分の式の値になる`() {
        // 境目（0.0031308）以下は直線 l×12.92
        assertEquals(0.0, SrgbTransfer.toEncoded(0.0), 1e-11)
        assertEquals(0.01292, SrgbTransfer.toEncoded(0.001), 1e-11)             // 0.001×12.92
        assertEquals(0.040449936, SrgbTransfer.toEncoded(0.0031308), 1e-11)     // 0.0031308×12.92
        // 境目より上は 1.055×l^(1/2.4)−0.055
        assertEquals(0.735356983052, SrgbTransfer.toEncoded(0.5), 1e-11)        // 0.5^(1/2.4)＝0.749153538438 → ×1.055−0.055
        assertEquals(0.880825021090, SrgbTransfer.toEncoded(0.75), 1e-11)       // 0.75^(1/2.4)＝0.887037934683 → ×1.055−0.055
        assertEquals(1.0, SrgbTransfer.toEncoded(1.0), 1e-11)
    }

    @Test
    fun `256階調はどれも線形との往復で同じ階調に戻る`() {
        for (k in 0..255) {
            val encoded = k / 255.0
            val back = SrgbTransfer.toEncoded(SrgbTransfer.toLinear(encoded))
            assertEquals(k, (back * 255.0).roundToInt(), "階調 $k")
            assertEquals(encoded, back, 1e-9, "階調 $k の往復の値")
        }
    }

    @Test
    fun `256階調の線形の値は0から1へ単調に増える`() {
        var previous = -1.0
        for (k in 0..255) {
            val linear = SrgbTransfer.toLinear(k / 255.0)
            assertTrue(linear > previous, "階調 $k：$linear は前の $previous より大きいはず")
            previous = linear
        }
        assertEquals(1.0, previous, 1e-11)
    }

    @Test
    fun `8ビットの表はtoLinearと同じ値を返す`() {
        // ColorKernel.render は 8 ビットの入力を表で線形にする。renderColor と同じ値になるよう、近似でなく同じ値であること
        for (k in 0..255) {
            assertEquals(SrgbTransfer.toLinear(k / 255.0), SrgbTransfer.toLinearByte(k), "階調 $k")
        }
    }
}
