// ⭐️ スライダーの値から物理の値への写し（Kiro android-edit-tools タスク 4・C1・design.md:439-457, 820-835）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.math.pow

/**
 * スライダーの値（−1〜1）から物理の値へ。式は design.md「色の式」の表（822-834）。
 * 出典はどれも iOS origin/main 9bed5a4a。行番号は各関数の説明に書いた。
 *
 * 露出・明るさ・コントラスト・彩度・ブラックポイントは iOS の `EditRecipe.init(from:)`（EditRecipe.swift:351-388）が
 * スライダーの値を Core Image の物理の値にする式、暖かみ〜ホワイトバランスとフェードは FilterGraphBuilder.swift が
 * スライダーの値から直接フィルターの引数を作る式を写した。
 */
object ToolMapping {
    /**
     * 正と負で別の曲線を使う写し。結果＝sign(n)×|n|^p×scale（iOS EditRecipe.swift:292-310）。
     * - n が NaN・無限なら 0（:298）
     * - n＞0 なら scalePos×n^pPos、n＜0 なら −scaleNeg×(−n)^pNeg、n＝0 なら 0（:300-306）
     * - 結果が NaN・無限なら 0（:309）
     */
    fun asymmetricForward(n: Double, pNeg: Double, scaleNeg: Double, pPos: Double, scalePos: Double): Double {
        if (!n.isFinite()) return 0.0                                         // EditRecipe.swift:298
        val result = when {
            n > 0.0 -> scalePos * n.pow(pPos)                                 // EditRecipe.swift:300-301
            n < 0.0 -> -scaleNeg * (-n).pow(pNeg)                             // EditRecipe.swift:302-303
            else -> 0.0                                                       // EditRecipe.swift:304-305
        }
        return if (result.isFinite()) result else 0.0                         // EditRecipe.swift:309
    }

    /** 露出：EV＝2.0v（iOS EditRecipe.swift:353） */
    fun exposureEv(v: Double): Double = v * 2.0

    /** 明るさ：負の側だけ指数 1.5。b＝(v≥0 ? 0.5v : −0.5(−v)^1.5)（iOS EditRecipe.swift:356-360） */
    fun brightness(v: Double): Double =
        asymmetricForward(v, pNeg = 1.5, scaleNeg = 0.5, pPos = 1.0, scalePos = 0.5)

    /** コントラスト：負の側だけ指数 2.0。k＝1＋(v≥0 ? 0.5v : −0.5(−v)^2)（iOS EditRecipe.swift:364-368） */
    fun contrast(v: Double): Double =
        1.0 + asymmetricForward(v, pNeg = 2.0, scaleNeg = 0.5, pPos = 1.0, scalePos = 0.5)

    /** 彩度：正の側だけ指数 0.7・倍率 1.5。s＝1＋(v≥0 ? 1.5×v^0.7 : −(−v))（iOS EditRecipe.swift:384-388） */
    fun saturation(v: Double): Double =
        1.0 + asymmetricForward(v, pNeg = 1.0, scaleNeg = 1.0, pPos = 0.7, scalePos = 1.5)

    /** ブラックポイント：bias＝0.15v（iOS EditRecipe.swift:380） */
    fun blackPointBias(v: Double): Double = v * 0.15

    /**
     * 暖かみ・色合い：行き先＝(6500−1500w, 250t)。基準は (6500, 0)
     * （iOS FilterGraphBuilder.swift:905-909。暖かみと色合いは同じ 1 つのフィルターで掛ける：:197-205）
     */
    fun warmTintTarget(warmth: Double, tint: Double): TemperatureTarget =
        TemperatureTarget(kelvin = 6500.0 - warmth * 1500.0, tint = tint * 250.0)

    /** 色温度：行き先＝(6500＋1500v, 0)（iOS FilterGraphBuilder.swift:926-928 が :920-921 を scale 1500 で呼ぶ） */
    fun colorTemperatureTarget(v: Double): TemperatureTarget =
        TemperatureTarget(kelvin = 6500.0 + v * 1500.0, tint = 0.0)

    /** ホワイトバランス：行き先＝(6500＋2000v, 0)（iOS FilterGraphBuilder.swift:935-937 が :920-921 を scale 2000 で呼ぶ） */
    fun whiteBalanceTarget(v: Double): TemperatureTarget =
        TemperatureTarget(kelvin = 6500.0 + v * 2000.0, tint = 0.0)

    /** フェードの傾き：gain＝1−0.15v（iOS FilterGraphBuilder.swift:1104） */
    fun fadeGain(v: Double): Double = 1.0 - v * 0.15

    /** フェードの持ち上げ：bias＝0.2v（iOS FilterGraphBuilder.swift:1103） */
    fun fadeBias(v: Double): Double = v * 0.2
}

/** CITemperatureAndTint の行き先（基準は常に 6500K・色合い 0） */
data class TemperatureTarget(val kelvin: Double, val tint: Double) {
    companion object {
        val NEUTRAL = TemperatureTarget(6500.0, 0.0)
    }
}
