// ⭐️ 編集の内容の色の部分（物理の値）（Kiro android-edit-tools タスク 2.2・K0／タスク 4・C1・design.md:459-479）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId

/**
 * 編集の内容の色の部分を、物理の値にしたもの。プレビューと焼き込みは、これだけを ColorKernel に渡す。
 * [of] がフィルターとツールの値を写す（スライダーの値から物理の値への式は [ToolMapping] の 1 か所）。
 */
data class ColorRecipe(
    val filter: FilterId?,
    val exposureEv: Double,               // 0 で中立
    val saturation: Double,               // 1 で中立（この 4 つの並びは掛ける順ではない。掛ける順は ColorKernel の 1 か所）
    val contrast: Double,                 // 1 で中立
    val brightness: Double,               // 0 で中立
    val blackPointBias: Double,           // 0 で中立
    val warmTint: TemperatureTarget?,     // 暖かみと色合いが共に 0 なら null
    val colorTemperature: TemperatureTarget?,
    val whiteBalance: TemperatureTarget?,
    val fadeGain: Double,                 // 1 で中立
    val fadeBias: Double,                 // 0 で中立
) {
    /** ツールが全部中立か（フィルターは見ない） */
    private val toolsNeutral: Boolean
        get() = exposureEv == 0.0 && saturation == 1.0 && contrast == 1.0 && brightness == 0.0 &&
            blackPointBias == 0.0 && warmTint == null && colorTemperature == null && whiteBalance == null &&
            fadeGain == 1.0 && fadeBias == 0.0

    /** フィルターが null か NATURAL で、ツールが全部中立 */
    val isIdentity: Boolean get() = (filter == null || filter == FilterId.NATURAL) && toolsNeutral

    /** フィルターが今の 6 種のどれかで、ツールが全部中立のときだけ、そのフィルター */
    val legacyMatrixOnly: FilterId? get() = if (toolsNeutral && filter?.legacyMatrix() != null) filter else null

    companion object {
        val IDENTITY = ColorRecipe(
            filter = null,
            exposureEv = 0.0,
            saturation = 1.0,
            contrast = 1.0,
            brightness = 0.0,
            blackPointBias = 0.0,
            warmTint = null,
            colorTemperature = null,
            whiteBalance = null,
            fadeGain = 1.0,
            fadeBias = 0.0,
        )

        /**
         * 編集の内容から色の部分を作る。回転と切り抜き（[PhotoEdit.geometry]）は見ない。
         * 装備（Loadout）も見ない：装備から外れたツールでも、値が残っていれば掛ける（design.md D-5・利用者の判断 U9）。
         *
         * 中立の値（0）は、[ToolMapping] を通しても中立の物理の値（露出 0・彩度 1・コントラスト 1・明るさ 0・
         * ブラックポイント 0・フェードの傾き 1・持ち上げ 0）になる。色温度の系統は、iOS が値 0 の段を飛ばすのに合わせて
         * null にする（色温度・ホワイトバランス：iOS FilterGraphBuilder.swift:208, 213 の `v != 0`）。
         * 暖かみと色合いは 1 つの段なので、どちらかが 0 でなければ行き先を作り、共に 0 なら null（iOS :198-205 は
         * どちらかの値が有れば段を通す。Android は 0 を持たないので「0 でない」で同じことを表す）。
         */
        fun of(edit: PhotoEdit): ColorRecipe {
            val tools = edit.tools
            val warmth = tools.normalized(EditTool.WARMTH)
            val tint = tools.normalized(EditTool.TINT)
            val colorTemperature = tools.normalized(EditTool.COLOR_TEMPERATURE)
            val whiteBalance = tools.normalized(EditTool.WHITE_BALANCE)
            val fade = tools.normalized(EditTool.FADE)
            return ColorRecipe(
                filter = edit.filter,
                exposureEv = ToolMapping.exposureEv(tools.normalized(EditTool.EXPOSURE)),
                saturation = ToolMapping.saturation(tools.normalized(EditTool.SATURATION)),
                contrast = ToolMapping.contrast(tools.normalized(EditTool.CONTRAST)),
                brightness = ToolMapping.brightness(tools.normalized(EditTool.BRIGHTNESS)),
                blackPointBias = ToolMapping.blackPointBias(tools.normalized(EditTool.BLACK_POINT)),
                warmTint = if (warmth == 0.0 && tint == 0.0) null else ToolMapping.warmTintTarget(warmth, tint),
                colorTemperature = if (colorTemperature == 0.0) null else ToolMapping.colorTemperatureTarget(colorTemperature),
                whiteBalance = if (whiteBalance == 0.0) null else ToolMapping.whiteBalanceTarget(whiteBalance),
                fadeGain = ToolMapping.fadeGain(fade),
                fadeBias = ToolMapping.fadeBias(fade),
            )
        }
    }
}
