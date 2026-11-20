// ⭐️ 点ごとの色の計算（色の定義の 1 か所）（Kiro android-edit-tools タスク 4・C1・design.md:481-491, 799-853）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * 点ごとの色の計算。色の定義はここだけ（要件 10.3・11.5。プレビューも焼き込みもこれを呼ぶ）。
 *
 * ## 1 画素の手順（design.md:806-813。この順を変えない）
 * 1. 画素をガンマ付きの 0〜1 の 3 つの値にする
 * 2. フィルターが今の 6 種なら、`legacyMatrix()` をガンマ付きの値に掛け（5 列目は 255 で割る）、0〜1 に切り詰める（今の描画と同じ）
 * 3. 線形の段が 1 つも無ければ 7 へ。あれば [SrgbTransfer.toLinear] で線形にする
 * 4. フィルターがウォーム・クールなら [TemperatureTint.matrix]（行き先 5500K・7500K）。
 *    ビンテージなら [VintageLook.sepia] で色を書き換えたあとに [VintageLook.vignetteGain] を掛ける
 * 5. ツール：[TOOL_ORDER] の順に掛ける。中立のツールは飛ばす。**段の間では切り詰めも丸めもしない**
 *    （iOS の作業の形式は半精度の浮動小数：iOS CIContextPool.swift:59。Metal のカーネルも切り詰めない：iOS ExposureContrast.metal:52-56。
 *    `CIColorMatrix` も途中で切り詰めない：実測 M6）
 * 6. 0〜1 に切り詰め、[SrgbTransfer.toEncoded] でガンマ付きに戻す
 * 7. 255 を掛けて四捨五入し、不透明の画素に戻す（[render] だけ。[renderColor] は 6 の値を返す）
 *
 * ## 不変の決まり（design.md:815-818）
 * - `recipe.isIdentity` なら画素を 1 つも変えない
 * - [render] と [renderColor] は同じ式を通る。[render] は 8 ビットの入力を表から線形にするが、表の中身は
 *   `SrgbTransfer.toLinear(k / 255.0)` そのものなので、[renderColor] を四捨五入した値と一致する
 * - 位置を使うのはビンテージの周辺減光だけ。位置は「回転後の全体の絵」の中の割合で、切り抜きや縮小で変わらない
 *
 * ## 画素の位置（[render]）
 * 画素 (x, y) の位置は、その画素の**中心**を全体の絵の割合で表したもの：
 * nx＝frame.left＋(x＋0.5)÷width×frame.width、ny＝frame.top＋(y＋0.5)÷height×frame.height。
 * 帯ごとに呼んでも（design.md:890）、帯の frame が全体の frame の中のその帯の範囲なら、全体を 1 回で呼んだのと同じ位置になる。
 *
 * ## 差し替えの口（design.md:1172）
 * 色温度の行列・セピア・周辺減光の倍率は [Parts] から取る。公開の [render]・[renderColor] は本物（[Parts.REAL]）を渡すだけ。
 * テストは `internal` の [renderWith]・[renderColorWith] に偽物を渡して、実測の中身（K1②）に頼らずに
 * 「呼んだ結果を掛けている」ことを確かめる。全体の変数を書き換える形にしないのは、戻し忘れが後のテスト
 * （本物を通す MeasuredFiltersTest）を黙って変えないようにするため。
 */
object ColorKernel {
    /**
     * pixels：不透明の ARGB（sRGB）を行優先で並べたもの。その場で書き換える。
     * frame：この画素の並びが、回転後の全体の絵のどこに当たるか。fullAspect：回転後の全体の絵の 幅÷高さ（周辺減光の位置に使う）
     */
    fun render(pixels: IntArray, width: Int, height: Int, recipe: ColorRecipe, frame: NormalizedRect, fullAspect: Double): Unit =
        renderWith(Parts.REAL, pixels, width, height, recipe, frame, fullAspect)

    /** 1 色（ガンマ付きの 0〜1）を計算して返す。丸める前の値（テスト用）。nx・ny は回転後の全体の絵の中の位置 */
    fun renderColor(
        r: Double,
        g: Double,
        b: Double,
        recipe: ColorRecipe,
        nx: Double = 0.5,
        ny: Double = 0.5,
        fullAspect: Double = 1.0,
    ): DoubleArray = renderColorWith(Parts.REAL, r, g, b, recipe, nx, ny, fullAspect)

    /**
     * 色温度の行列・セピア・周辺減光の倍率の出どころ（差し替えの口。design.md:1172）。
     * - temperatureMatrix：行き先から、線形の sRGB に掛ける 3×3（9 要素・行優先）
     * - sepia：線形の 1 色（3 要素）をその場で書き換える（行列ではない：design.md:505）
     * - vignetteGain：(nx, ny, fullAspect) から、線形の値に掛ける倍率
     */
    internal class Parts(
        val temperatureMatrix: (TemperatureTarget) -> DoubleArray,
        val sepia: (DoubleArray) -> Unit,
        val vignetteGain: (Double, Double, Double) -> Double,
    ) {
        companion object {
            /** 本物（[TemperatureTint]・[VintageLook]）。呼ぶたびにその時の中身を使う */
            val REAL = Parts(
                temperatureMatrix = { target -> TemperatureTint.matrix(target) },
                sepia = { rgb -> VintageLook.sepia(rgb) },
                vignetteGain = { nx, ny, fullAspect -> VintageLook.vignetteGain(nx, ny, fullAspect) },
            )
        }
    }

    /** [render] の中身。[parts] を差し替えられる（テスト用の口） */
    internal fun renderWith(
        parts: Parts,
        pixels: IntArray,
        width: Int,
        height: Int,
        recipe: ColorRecipe,
        frame: NormalizedRect,
        fullAspect: Double,
    ) {
        // 掛けるのは先頭の 幅×高さ 個だけ（帯ごとに同じ配列を使い回しても、短い最後の帯で落ちないように）
        require(width >= 0 && height >= 0 && pixels.size >= width * height) {
            "画素の数が 幅×高さ に足りません: size=${pixels.size} width=$width height=$height"
        }
        // 不変の決まり：中立なら画素を 1 つも変えない（design.md:816）
        if (recipe.isIdentity) return
        val plan = Plan(recipe, parts)
        val c = DoubleArray(3)
        for (y in 0 until height) {
            // 画素の中心の位置（回転後の全体の絵の割合）。使うのはビンテージの周辺減光だけ
            val ny = frame.top + (y + 0.5) / height * frame.height
            for (x in 0 until width) {
                val index = y * width + x
                val pixel = pixels[index]
                // 手順 1：ARGB の 8 ビットの値
                val r8 = (pixel ushr 16) and 0xFF
                val g8 = (pixel ushr 8) and 0xFF
                val b8 = pixel and 0xFF
                if (plan.legacy != null) {
                    // 手順 2：ガンマ付きの値に今の 6 種の行列
                    c[0] = r8 / 255.0
                    c[1] = g8 / 255.0
                    c[2] = b8 / 255.0
                    plan.applyLegacy(c)
                    // 手順 3：行列の後の値は 8 ビットの格子に乗らないので、表でなく式で線形にする
                    if (plan.hasLinear) {
                        c[0] = SrgbTransfer.toLinear(c[0])
                        c[1] = SrgbTransfer.toLinear(c[1])
                        c[2] = SrgbTransfer.toLinear(c[2])
                    }
                } else if (plan.hasLinear) {
                    // 手順 3：8 ビットの入力は表で線形にする（表の中身は toLinear(k / 255.0) と同じ値）
                    c[0] = SrgbTransfer.toLinearByte(r8)
                    c[1] = SrgbTransfer.toLinearByte(g8)
                    c[2] = SrgbTransfer.toLinearByte(b8)
                } else {
                    c[0] = r8 / 255.0
                    c[1] = g8 / 255.0
                    c[2] = b8 / 255.0
                }
                if (plan.hasLinear) {
                    val nx = frame.left + (x + 0.5) / width * frame.width
                    // 手順 4〜6
                    plan.applyLinear(c, nx, ny, fullAspect)
                }
                // 手順 7：255 を掛けて四捨五入し、不透明の画素に戻す
                pixels[index] = (0xFF shl 24) or (to8Bit(c[0]) shl 16) or (to8Bit(c[1]) shl 8) or to8Bit(c[2])
            }
        }
    }

    /** [renderColor] の中身。[parts] を差し替えられる（テスト用の口） */
    internal fun renderColorWith(
        parts: Parts,
        r: Double,
        g: Double,
        b: Double,
        recipe: ColorRecipe,
        nx: Double = 0.5,
        ny: Double = 0.5,
        fullAspect: Double = 1.0,
    ): DoubleArray {
        // 手順 1：ガンマ付きの 0〜1 の 3 つの値
        val c = doubleArrayOf(r, g, b)
        // 不変の決まり：中立なら色を変えない（design.md:816）
        if (recipe.isIdentity) return c
        val plan = Plan(recipe, parts)
        // 手順 2
        if (plan.legacy != null) plan.applyLegacy(c)
        // 手順 3：線形の段が無ければ、ここで終わり（手順 7 へ）
        if (!plan.hasLinear) return c
        c[0] = SrgbTransfer.toLinear(c[0])
        c[1] = SrgbTransfer.toLinear(c[1])
        c[2] = SrgbTransfer.toLinear(c[2])
        // 手順 4〜6
        plan.applyLinear(c, nx, ny, fullAspect)
        return c
    }

    /** ツールの段の名前。掛ける順は [TOOL_ORDER] の 1 か所だけが決める */
    private enum class ToolStage {
        EXPOSURE, BRIGHTNESS, CONTRAST, SATURATION, BLACK_POINT, WARM_TINT, COLOR_TEMPERATURE, WHITE_BALANCE, FADE,
    }

    /**
     * ツールを掛ける順（design.md:811。この順をほかの所に書かない）。
     * - 4 つ組は 露出→明るさ→コントラスト→彩度（iOS ExposureContrast.metal:38-50 の順。利用者の判断 U2）。
     *   明るさはコントラストの**前**（iOS の代わりの道 FilterGraphBuilder.swift:133-144 の「後」は写さない：design.md:848）
     * - その後は ブラックポイント→暖かみ・色合い→色温度→ホワイトバランス→フェード
     *   （iOS FilterGraphBuilder.swift:187-190, 197-205, 207-210, 212-215, 242-245 の並び。間の段は本仕様の範囲外）
     */
    private val TOOL_ORDER: Array<ToolStage> = arrayOf(
        ToolStage.EXPOSURE,
        ToolStage.BRIGHTNESS,
        ToolStage.CONTRAST,
        ToolStage.SATURATION,
        ToolStage.BLACK_POINT,
        ToolStage.WARM_TINT,
        ToolStage.COLOR_TEMPERATURE,
        ToolStage.WHITE_BALANCE,
        ToolStage.FADE,
    )

    /** 彩度の輝度の重み（ITU-R BT.709。iOS ExposureContrast.metal:49。利用者の判断 U2）。ほかの所に書かない */
    private const val LUMA_R = 0.2126
    private const val LUMA_G = 0.7152
    private const val LUMA_B = 0.0722

    /** ウォームの行き先 5500K・色合い 0（基準 6500K・0 から：iOS FilterGraphBuilder.swift:517-522） */
    private val WARM_TARGET = TemperatureTarget(5500.0, 0.0)

    /** クールの行き先 7500K・色合い 0（基準 6500K・0 から：iOS FilterGraphBuilder.swift:524-529） */
    private val COOL_TARGET = TemperatureTarget(7500.0, 0.0)

    /** 0〜1 に切り詰める。NaN は 0（四捨五入で落ちないように） */
    private fun clamp01(v: Double): Double = if (v > 0.0) (if (v < 1.0) v else 1.0) else 0.0

    /** ガンマ付きの 0〜1 を 0〜255 の整数にする（四捨五入） */
    private fun to8Bit(v: Double): Int = (clamp01(v) * 255.0).roundToInt()

    /** 3×3（9 要素・行優先）を線形の 1 色に掛ける：out_i＝m[3i]·r＋m[3i+1]·g＋m[3i+2]·b */
    private fun multiply3x3(m: DoubleArray, c: DoubleArray) {
        val r = c[0]
        val g = c[1]
        val b = c[2]
        c[0] = m[0] * r + m[1] * g + m[2] * b
        c[1] = m[3] * r + m[4] * g + m[5] * b
        c[2] = m[6] * r + m[7] * g + m[8] * b
    }

    /** 色温度の部品が返した行列の形を確かめる（9 要素でなければ、黙って違う色を出さずに落とす） */
    private fun checkedMatrix(m: DoubleArray): DoubleArray {
        require(m.size == 9) { "色温度の行列は 9 要素（3×3・行優先）が要ります: size=${m.size}" }
        return m
    }

    /**
     * 1 つのレシピを掛ける準備（画素ごとに変わらない値を前もって計算する）。
     * [render] と [renderColor] はどちらもこれを通る（同じ式を 2 つ書かない）。
     */
    private class Plan(recipe: ColorRecipe, private val parts: Parts) {
        /** 手順 2 の行列（今の 6 種のときだけ。Double に直した 20 要素・行優先・5 列目は 0〜255 の尺度） */
        val legacy: DoubleArray? = recipe.filter?.legacyMatrix()?.let { m -> DoubleArray(m.size) { m[it].toDouble() } }

        /** 手順 4 の色温度の行列（ウォーム・クールのときだけ） */
        private val filterMatrix: DoubleArray? = when (recipe.filter) {
            FilterId.WARM -> checkedMatrix(parts.temperatureMatrix(WARM_TARGET))
            FilterId.COOL -> checkedMatrix(parts.temperatureMatrix(COOL_TARGET))
            else -> null
        }

        /** 手順 4 のビンテージ（セピア→周辺減光。iOS FilterGraphBuilder.swift:531-541 の順） */
        private val vintage: Boolean = recipe.filter == FilterId.VINTAGE

        /** 掛けるツールの段（[TOOL_ORDER] の順から、中立の段を抜いたもの） */
        private val stages: Array<ToolStage> = TOOL_ORDER.filter { !isNeutral(it, recipe) }.toTypedArray()

        /** 露出の倍率 2^EV（iOS ExposureContrast.metal:38） */
        private val exposureGain: Double = 2.0.pow(recipe.exposureEv)
        private val brightness: Double = recipe.brightness
        private val contrast: Double = recipe.contrast
        private val saturation: Double = recipe.saturation
        private val blackPointBias: Double = recipe.blackPointBias
        private val fadeGain: Double = recipe.fadeGain
        private val fadeBias: Double = recipe.fadeBias

        /** 色温度の系統の 3 段の行列（null の段は掛けない）。行き先は [ToolMapping] が作ったもの */
        private val warmTintMatrix: DoubleArray? = recipe.warmTint?.let { checkedMatrix(parts.temperatureMatrix(it)) }
        private val colorTemperatureMatrix: DoubleArray? = recipe.colorTemperature?.let { checkedMatrix(parts.temperatureMatrix(it)) }
        private val whiteBalanceMatrix: DoubleArray? = recipe.whiteBalance?.let { checkedMatrix(parts.temperatureMatrix(it)) }

        /** 線形の段（手順 4・5）が 1 つでもあるか。無ければ手順 3〜6 を飛ばす */
        val hasLinear: Boolean = filterMatrix != null || vintage || stages.isNotEmpty()

        /**
         * 手順 2：ガンマ付きの値 c に今の 6 種の行列を掛け、0〜1 に切り詰める（今の描画と同じ。FilterId.legacyMatrix の説明）。
         * R'＝a·R＋b·G＋c·B＋d·A＋e。0〜1 の尺度では A＝1（不透明）、e は 0〜255 の尺度なので 255 で割る。
         */
        fun applyLegacy(c: DoubleArray) {
            val m = legacy ?: return
            val r = c[0]
            val g = c[1]
            val b = c[2]
            for (row in 0 until 3) {
                val base = row * 5
                c[row] = clamp01(m[base] * r + m[base + 1] * g + m[base + 2] * b + m[base + 3] * 1.0 + m[base + 4] / 255.0)
            }
        }

        /** 手順 4〜6：線形の値 c に、フィルター（新しい 3 種）とツールを掛け、切り詰めてガンマ付きに戻す（c をその場で書き換える） */
        fun applyLinear(c: DoubleArray, nx: Double, ny: Double, fullAspect: Double) {
            // 手順 4：フィルター（ウォーム・クールは 3×3、ビンテージはセピアの後に周辺減光）
            if (filterMatrix != null) multiply3x3(filterMatrix, c)
            if (vintage) {
                parts.sepia(c)                                              // 実測 M2（design.md:505）
                val gain = parts.vignetteGain(nx, ny, fullAspect)           // 実測 M3（位置ごとの倍率）
                c[0] *= gain
                c[1] *= gain
                c[2] *= gain
            }
            // 手順 5：ツール（段の間で切り詰めない）
            for (stage in stages) {
                when (stage) {
                    // 露出：c×2^EV（iOS ExposureContrast.metal:38-39）
                    ToolStage.EXPOSURE -> {
                        c[0] *= exposureGain
                        c[1] *= exposureGain
                        c[2] *= exposureGain
                    }
                    // 明るさ：c＋b（iOS ExposureContrast.metal:42）
                    ToolStage.BRIGHTNESS -> {
                        c[0] += brightness
                        c[1] += brightness
                        c[2] += brightness
                    }
                    // コントラスト：(c−0.5)k＋0.5（iOS ExposureContrast.metal:46）
                    ToolStage.CONTRAST -> {
                        c[0] = (c[0] - 0.5) * contrast + 0.5
                        c[1] = (c[1] - 0.5) * contrast + 0.5
                        c[2] = (c[2] - 0.5) * contrast + 0.5
                    }
                    // 彩度：L＋s(c−L)、L＝0.2126R＋0.7152G＋0.0722B（iOS ExposureContrast.metal:49-50 の mix(L, c, s)）
                    ToolStage.SATURATION -> {
                        val luma = LUMA_R * c[0] + LUMA_G * c[1] + LUMA_B * c[2]
                        c[0] = luma + saturation * (c[0] - luma)
                        c[1] = luma + saturation * (c[1] - luma)
                        c[2] = luma + saturation * (c[2] - luma)
                    }
                    // ブラックポイント：c＋bias（単位行列＋bias の CIColorMatrix：iOS FilterGraphBuilder.swift:873-883）
                    ToolStage.BLACK_POINT -> {
                        c[0] += blackPointBias
                        c[1] += blackPointBias
                        c[2] += blackPointBias
                    }
                    // 暖かみ・色合い：CITemperatureAndTint（iOS FilterGraphBuilder.swift:898-911）＝3×3（実測 M1）
                    ToolStage.WARM_TINT -> multiply3x3(checkNotNull(warmTintMatrix), c)
                    // 色温度：同上（iOS FilterGraphBuilder.swift:926-928）
                    ToolStage.COLOR_TEMPERATURE -> multiply3x3(checkNotNull(colorTemperatureMatrix), c)
                    // ホワイトバランス：同上（iOS FilterGraphBuilder.swift:935-937）
                    ToolStage.WHITE_BALANCE -> multiply3x3(checkNotNull(whiteBalanceMatrix), c)
                    // フェード：c×gain＋bias（対角が gain・bias の CIColorMatrix：iOS FilterGraphBuilder.swift:1100-1111）
                    ToolStage.FADE -> {
                        c[0] = c[0] * fadeGain + fadeBias
                        c[1] = c[1] * fadeGain + fadeBias
                        c[2] = c[2] * fadeGain + fadeBias
                    }
                }
            }
            // 手順 6：0〜1 に切り詰め、ガンマ付きに戻す
            c[0] = SrgbTransfer.toEncoded(clamp01(c[0]))
            c[1] = SrgbTransfer.toEncoded(clamp01(c[1]))
            c[2] = SrgbTransfer.toEncoded(clamp01(c[2]))
        }

        private companion object {
            /** 中立の段は飛ばす（iOS も中立の段を通さない：FilterGraphBuilder.swift:119-123, 188, 198, 208, 213, 243） */
            fun isNeutral(stage: ToolStage, recipe: ColorRecipe): Boolean = when (stage) {
                ToolStage.EXPOSURE -> recipe.exposureEv == 0.0
                ToolStage.BRIGHTNESS -> recipe.brightness == 0.0
                ToolStage.CONTRAST -> recipe.contrast == 1.0
                ToolStage.SATURATION -> recipe.saturation == 1.0
                ToolStage.BLACK_POINT -> recipe.blackPointBias == 0.0
                ToolStage.WARM_TINT -> recipe.warmTint == null
                ToolStage.COLOR_TEMPERATURE -> recipe.colorTemperature == null
                ToolStage.WHITE_BALANCE -> recipe.whiteBalance == null
                ToolStage.FADE -> recipe.fadeGain == 1.0 && recipe.fadeBias == 0.0
            }
        }
    }
}
