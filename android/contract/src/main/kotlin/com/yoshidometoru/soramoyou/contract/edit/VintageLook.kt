// ⭐️ ビンテージ（セピアと周辺減光）（Kiro android-edit-tools タスク 2.2・K0・タスク 3・K1②・design.md:503-507）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.math.hypot

/**
 * ビンテージ。セピアは実測 M2、周辺減光は実測 M3 の表（[VintageLookData]）を直線でつないで返す。
 * どちらも `ColorKernel` は通さない（この部品だけで完結する）。
 */
object VintageLook {
    /** セピアの強さ。出力 ＝ (1−t)×入力 ＋ t×S(Y) の t（iOS のビンテージは 0.5） */
    private const val SEPIA_INTENSITY = 0.5

    /** 輝度 Y の重み（Rec.709。線形の sRGB に掛ける） */
    private const val LUMA_R = 0.2126
    private const val LUMA_G = 0.7152
    private const val LUMA_B = 0.0722

    /**
     * rgb＝線形の sRGB の 1 色（3 要素）をその場で書き換える。行列ではない（実測 M2）：
     * 出力＝0.5×入力＋0.5×S(Y)、Y＝0.2126R＋0.7152G＋0.0722B、S は輝度だけで決まる 3 本の曲線。
     *
     * S の引き方：Y を 0〜1 に切り詰め、`SrgbTransfer.toEncoded` でガンマ付きの輝度 e にして、
     * 表（e を 256 等分した 257 点）を直線でつなぐ。横軸を線形の輝度にしないのは、暗い側で曲線が急に立って
     * 1 階調に入らないため（出どころは [VintageLookData]）。入力が 0〜1 の外のときの形は測っていない
     * （ビンテージは最初の段なので、入るのは元の写真の 0〜1 の値）。
     */
    fun sepia(rgb: DoubleArray) {
        // 書き換える前の値から輝度を出す（先に 1 つ書き換えると、輝度がずれる）
        val y = (LUMA_R * rgb[0] + LUMA_G * rgb[1] + LUMA_B * rgb[2]).coerceIn(0.0, 1.0)
        val e = SrgbTransfer.toEncoded(y)
        val position = (e * VintageLookData.SEGMENTS).coerceIn(0.0, VintageLookData.SEGMENTS.toDouble())
        // 最後の点（e＝1）のときは 1 つ手前の区間の端として引く
        val i = position.toInt().coerceAtMost(VintageLookData.SEGMENTS - 1)
        val f = position - i

        val curves = arrayOf(VintageLookData.SEPIA_S_R, VintageLookData.SEPIA_S_G, VintageLookData.SEPIA_S_B)
        // 3 本とも、書き換える前の rgb[c] だけを使うので、チャンネルごとに順に書き換えてよい
        for (c in 0 until 3) {
            val s = curves[c][i] * (1.0 - f) + curves[c][i + 1] * f
            rgb[c] = (1.0 - SEPIA_INTENSITY) * rgb[c] + SEPIA_INTENSITY * s
        }
    }

    /**
     * 周辺減光の倍率（線形の値に掛ける）。nx・ny は「回転後の全体の絵」の中の位置の割合（0〜1・左上が (0,0)）、
     * fullAspect ＝ 回転後の全体の絵の 幅÷高さ。切り抜きや縮小で変わらない（位置と縦横比だけで決まる）。
     *
     * 中心からの距離 d ＝ 短辺で正規化した距離（短辺の半分が 1）：
     * 横長（fullAspect ≥ 1）なら 2×hypot(dx×fullAspect, dy)、縦長なら 2×hypot(dx, dy÷fullAspect)（dx＝nx−0.5、dy＝ny−0.5）。
     * 倍率は d の表（0〜D_MAX を 256 等分）を直線でつなぎ、D_MAX を超えたら端の値。
     */
    fun vignetteGain(nx: Double, ny: Double, fullAspect: Double): Double {
        val dx = nx - 0.5
        val dy = ny - 0.5
        val d = if (fullAspect >= 1.0) 2.0 * hypot(dx * fullAspect, dy) else 2.0 * hypot(dx, dy / fullAspect)
        val position = (d / VintageLookData.VIGNETTE_D_MAX * VintageLookData.SEGMENTS)
            .coerceIn(0.0, VintageLookData.SEGMENTS.toDouble())
        val i = position.toInt().coerceAtMost(VintageLookData.SEGMENTS - 1)
        val f = position - i
        return VintageLookData.VIGNETTE_GAIN[i] * (1.0 - f) + VintageLookData.VIGNETTE_GAIN[i + 1] * f
    }
}
