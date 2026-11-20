// ⭐️ 色の確かめに使う試す色と ColorRecipe の作り方（Kiro android-edit-tools タスク 2.2・K0・design.md:775）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId

/** 後の波のテストが共通で使う土台。色は全て、ガンマ付きの sRGB の 0〜1 */
object ColorFixtures {
    /**
     * 試す色：黒・白・灰 0.5・(200,100,50)・原色 3 つ・(0.25,0.5,0.75)。
     * 読むたびに新しい配列を返す。`VintageLook.sepia(rgb)` は渡した配列をその場で書き換えるので、
     * 共有の配列だと、先に流れたテストが後のテストの色を変えてしまう
     */
    val COLORS: List<DoubleArray> get() = listOf(
        doubleArrayOf(0.0, 0.0, 0.0),
        doubleArrayOf(1.0, 1.0, 1.0),
        doubleArrayOf(0.5, 0.5, 0.5),
        doubleArrayOf(200.0 / 255.0, 100.0 / 255.0, 50.0 / 255.0),
        doubleArrayOf(1.0, 0.0, 0.0),
        doubleArrayOf(0.0, 1.0, 0.0),
        doubleArrayOf(0.0, 0.0, 1.0),
        doubleArrayOf(0.25, 0.5, 0.75),
    )

    /** ColorRecipe を作る短い関数。引数を省くと中立（ColorRecipe.IDENTITY と同じ値） */
    fun recipe(
        filter: FilterId? = null,
        exposureEv: Double = 0.0,
        saturation: Double = 1.0,
        contrast: Double = 1.0,
        brightness: Double = 0.0,
        blackPointBias: Double = 0.0,
        warmTint: TemperatureTarget? = null,
        colorTemperature: TemperatureTarget? = null,
        whiteBalance: TemperatureTarget? = null,
        fadeGain: Double = 1.0,
        fadeBias: Double = 0.0,
    ): ColorRecipe = ColorRecipe(
        filter = filter,
        exposureEv = exposureEv,
        saturation = saturation,
        contrast = contrast,
        brightness = brightness,
        blackPointBias = blackPointBias,
        warmTint = warmTint,
        colorTemperature = colorTemperature,
        whiteBalance = whiteBalance,
        fadeGain = fadeGain,
        fadeBias = fadeBias,
    )
}
