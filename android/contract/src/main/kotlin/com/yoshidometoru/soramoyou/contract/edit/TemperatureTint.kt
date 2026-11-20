// ⭐️ 色温度の部品（Kiro android-edit-tools タスク 2.2・K0・タスク 3・K1②・design.md:498-501）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.math.floor

/**
 * 色温度の部品。線形の sRGB に掛ける 3×3（9 要素・行優先）。
 *
 * 中身は実測 M1（iOS の `CITemperatureAndTint`。基準 ＝ 6500K・色合い 0）の表 [TemperatureTintData] を、
 * 色温度と色合いの 2 方向に直線でつないだもの（双一次）。
 * 範囲の外（色温度 4500〜8500K・色合い −250〜250 の外）は、端に切り詰めてから引く。
 * 刻みの真ん中で、つないだ行列と実測の差は最大 0.4863 階調（1.0 階調以内。出どころは [TemperatureTintData]）。
 */
object TemperatureTint {
    /**
     * [target] の行き先の 3×3 の行列（m00, m01, m02, m10, m11, m12, m20, m21, m22）を、呼ぶたびに新しい配列で返す
     * （呼んだ側が書き換えても、表は変わらない）。基準（6500K・色合い 0）は単位行列（表の値で 1e-8 以内）。
     */
    fun matrix(target: TemperatureTarget): DoubleArray {
        // 表の範囲に切り詰める（範囲の外の行き先は端の行き先と同じ）
        val kelvin = target.kelvin.coerceIn(
            TemperatureTintData.KELVIN_MIN,
            TemperatureTintData.KELVIN_MIN + TemperatureTintData.KELVIN_STEP * (TemperatureTintData.KELVIN_COUNT - 1),
        )
        val tint = target.tint.coerceIn(
            TemperatureTintData.TINT_MIN,
            TemperatureTintData.TINT_MIN + TemperatureTintData.TINT_STEP * (TemperatureTintData.TINT_COUNT - 1),
        )

        // 表の中の位置（小数）。整数部＝左下の節点の番号、小数部＝そこから次の節点までの割合
        val kPos = (kelvin - TemperatureTintData.KELVIN_MIN) / TemperatureTintData.KELVIN_STEP
        val tPos = (tint - TemperatureTintData.TINT_MIN) / TemperatureTintData.TINT_STEP
        // 最後の節点（8500K・色合い 250）のときも、1 つ手前の升の端として引く（隣の節点が表の外に出ないように）
        val k0 = floor(kPos).toInt().coerceAtMost(TemperatureTintData.KELVIN_COUNT - 2)
        val t0 = floor(tPos).toInt().coerceAtMost(TemperatureTintData.TINT_COUNT - 2)
        val fk = kPos - k0
        val ft = tPos - t0

        val size = TemperatureTintData.MATRIX_SIZE
        val rowLow = TemperatureTintData.ROWS[k0]
        val rowHigh = TemperatureTintData.ROWS[k0 + 1]
        val result = DoubleArray(size)
        for (j in 0 until size) {
            // 色合いの方向に直線でつなぐ（色温度が低い側の行・高い側の行のそれぞれ）
            val low = rowLow[t0 * size + j] * (1.0 - ft) + rowLow[(t0 + 1) * size + j] * ft
            val high = rowHigh[t0 * size + j] * (1.0 - ft) + rowHigh[(t0 + 1) * size + j] * ft
            // 色温度の方向に直線でつなぐ
            result[j] = low * (1.0 - fk) + high * fk
        }
        return result
    }
}
