// ⭐️ 編集のツール・スライダーの値・回転と切り抜きの型（Kiro android-edit-tools タスク 2.2・K0・design.md:370-417）
package com.yoshidometoru.soramoyou.contract.edit

/**
 * 本仕様で出すツール。並びは iOS の EditTool.allCases の順（EditTool.swift:12-38）から、範囲外の 16 個を抜いたもの。
 * 色温度の系統の 4 個（暖かみ・色合い・色温度・ホワイトバランス）を入れる（要件 3.2 の確定・tasks.md 1.5）ので 11 個。
 */
enum class EditTool(val raw: String, val displayName: String, val isSlider: Boolean = true) {
    EXPOSURE("exposure", "露出"),
    BRIGHTNESS("brightness", "明るさ"),
    CONTRAST("contrast", "コントラスト"),
    BLACK_POINT("blackPoint", "ブラックポイント"),
    SATURATION("saturation", "彩度"),
    WARMTH("warmth", "暖かみ"),
    TINT("tint", "色合い"),
    COLOR_TEMPERATURE("colorTemperature", "色温度"),
    WHITE_BALANCE("whiteBalance", "ホワイトバランス"),
    FADE("fade", "フェード"),
    CROP_AND_ROTATE("cropAndRotate", "トリミング・回転", isSlider = false);

    companion object {
        /** 文字列値からツールを引く。完全一致。知らない名前・null は null */
        fun fromRaw(raw: String?): EditTool? = entries.firstOrNull { it.raw == raw }

        const val MIN = -100            // スライダーの下限（百分の 1。iOS の −1.0）
        const val MAX = 100
    }
}

/** スライダーのツールの値。百分の 1 の整数で持ち（等しいかを正確に比べるため）、0 の値は持たない */
class ToolValues private constructor(private val values: Map<EditTool, Int>) {
    /** 無ければ 0 */
    operator fun get(tool: EditTool): Int = values[tool] ?: 0

    /** get / 100.0 */
    fun normalized(tool: EditTool): Double = get(tool) / 100.0

    /** MIN〜MAX に切り詰める。0 は消す。isSlider でないツールは IllegalArgumentException */
    fun with(tool: EditTool, value: Int): ToolValues {
        require(tool.isSlider) { "スライダーのツールではありません: ${tool.raw}" }
        val clamped = value.coerceIn(EditTool.MIN, EditTool.MAX)
        val next = values.toMutableMap()
        if (clamped == 0) next.remove(tool) else next[tool] = clamped
        return ToolValues(next)
    }

    /** 0 でないツール */
    val adjusted: Set<EditTool> get() = values.keys

    override fun equals(other: Any?): Boolean = other is ToolValues && other.values == values

    override fun hashCode(): Int = values.hashCode()

    override fun toString(): String = "ToolValues($values)"

    companion object {
        val NONE: ToolValues = ToolValues(emptyMap())
    }
}

/** 回転後の絵に対する割合の範囲（左上が原点・0〜1）。iOS の cropRectNorm と同じ向き（EditRecipe.swift:187-191） */
data class NormalizedRect(val left: Double, val top: Double, val right: Double, val bottom: Double) {
    val width: Double get() = right - left
    val height: Double get() = bottom - top

    companion object {
        val FULL = NormalizedRect(0.0, 0.0, 1.0, 1.0)
    }
}

/** 回転と切り抜き。回転は EXIF の向きを直した後の絵を、時計回りに quarterTurns×90 度。切り抜きは回転後の絵に対する */
data class EditGeometry(val quarterTurns: Int = 0, val crop: NormalizedRect = NormalizedRect.FULL) {
    /**
     * 向きを +1（4 で割った余り）。範囲は絵と一緒に回す（同じ中身が選ばれたままになる）。
     * 範囲 (l, t, r, b) → (1−b, l, 1−t, r)。点 (x, y) が時計回りに (1−y, x) へ動くことから、
     * 左上 (l, t) → (1−t, l)、右下 (r, b) → (1−b, r) で求めた。
     * iOS は回転しても範囲の数字を変えない（利用者の判断 U6）が、Android は中身に合わせて回す。
     */
    fun rotatedClockwise(): EditGeometry = EditGeometry(
        quarterTurns = Math.floorMod(quarterTurns + 1, 4),
        crop = NormalizedRect(1.0 - crop.bottom, crop.left, 1.0 - crop.top, crop.right),
    )

    /** [rotatedClockwise] の逆。向きを −1（4 で割った余り）、範囲は (l, t, r, b) → (t, 1−r, b, 1−l) */
    fun rotatedCounterClockwise(): EditGeometry = EditGeometry(
        quarterTurns = Math.floorMod(quarterTurns - 1, 4),
        crop = NormalizedRect(crop.top, 1.0 - crop.right, crop.bottom, 1.0 - crop.left),
    )

    companion object {
        val NONE = EditGeometry()
    }
}
