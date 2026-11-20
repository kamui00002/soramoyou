// ⭐️ sRGB の伝達関数（Kiro android-edit-tools タスク 4・C1・design.md:493-496, 853）
package com.yoshidometoru.soramoyou.contract.edit

import kotlin.math.pow

/**
 * sRGB の伝達関数（ガンマ付きの値 ⇄ 線形の光の量）。
 *
 * iOS の編集は線形の sRGB で計算する（作業色空間＝`CGColorSpace.linearSRGB`：iOS CIContextPool.swift:50）。
 * ツールの式を iOS と同じ場所（線形）で掛けるために、ここで行き来する（research.md「色の計算は1つの関数に集め…」）。
 * 式は sRGB の規格（IEC 61966-2-1）の区分の式で、iOS の Core Image が linearSRGB と sRGB の間で使う形と同じ。
 *
 * 0〜1 の外の値も、そのまま同じ式に通す（切り詰めない）。切り詰めるのは呼ぶ側（ColorKernel の手順 2 と 6）である。
 */
object SrgbTransfer {
    /** 区分の境目（ガンマ付きの側）。これ以下は直線（IEC 61966-2-1） */
    private const val ENCODED_KNEE = 0.04045

    /** 区分の境目（線形の側）。0.04045 ÷ 12.92 ≈ 0.0031308（IEC 61966-2-1） */
    private const val LINEAR_KNEE = 0.0031308

    /** 直線の部分の傾き（IEC 61966-2-1） */
    private const val SLOPE = 12.92

    /** 曲線の部分の 1.055・0.055・2.4（IEC 61966-2-1） */
    private const val SCALE = 1.055
    private const val OFFSET = 0.055
    private const val GAMMA = 2.4

    /** sRGB の区分の式：c ≤ 0.04045 なら c ÷ 12.92、それより上は ((c ＋ 0.055) ÷ 1.055)^2.4 */
    fun toLinear(encoded: Double): Double =
        if (encoded <= ENCODED_KNEE) encoded / SLOPE else ((encoded + OFFSET) / SCALE).pow(GAMMA)

    /** [toLinear] の逆：l ≤ 0.0031308 なら l × 12.92、それより上は 1.055 × l^(1/2.4) − 0.055 */
    fun toEncoded(linear: Double): Double =
        if (linear <= LINEAR_KNEE) linear * SLOPE else SCALE * linear.pow(1.0 / GAMMA) - OFFSET

    /**
     * 8 ビットの値（0〜255）を線形にする表（速さのため。design.md:853）。
     * 中身は `toLinear(k / 255.0)` そのもので、同じ式の値を前もって計算しただけ（[ColorKernel.render] が
     * [ColorKernel.renderColor] と同じ値を出すため、近似の表にしない）。
     */
    private val BYTE_TO_LINEAR = DoubleArray(256) { toLinear(it / 255.0) }

    /** 8 ビットの値（0〜255）を線形にする。`toLinear(byte / 255.0)` と同じ値を表から返す */
    internal fun toLinearByte(byte: Int): Double = BYTE_TO_LINEAR[byte]
}
