// ⭐️ 写真の変換の計算（間引きの倍率・EXIF の向き・縮小後の大きさ）。Android の API に依存しない（タスク 16.1）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import kotlin.math.roundToInt

/**
 * EXIF の向きを直すための操作。**時計回りに [rotationDegrees] 度回してから、[mirror] なら左右に反転する**（この順序で意味が決まる）。
 * 本番の [AndroidImageCodec] は `Matrix.postRotate` → `postScale(-1, 1)` の順で同じことをする。
 */
internal data class OrientationFix(val rotationDegrees: Int, val mirror: Boolean) {

    /** 90 度・270 度の回転では、正立に直した後の幅と高さが入れ替わる。 */
    val swapsAxes: Boolean get() = rotationDegrees % 180 != 0

    companion object {
        /** 何もしない（向き 1・向きが無い・未知の値）。 */
        val NONE = OrientationFix(rotationDegrees = 0, mirror = false)
    }
}

/**
 * EXIF の向き（`Orientation` の値）を、正立に直す操作にする。
 *
 * | 値 | 保存された画素の見え方 | 直し方 |
 * |---|---|---|
 * | 1 | そのまま | なし |
 * | 2 | 左右反転 | 左右に反転 |
 * | 3 | 180 度 | 180 度回す |
 * | 4 | 上下反転 | 180 度回してから左右に反転（＝上下反転） |
 * | 5 | transpose | 時計回りに 90 度回してから左右に反転 |
 * | 6 | 反時計回りに 90 度倒れている | 時計回りに 90 度回す |
 * | 7 | transverse | 時計回りに 270 度回してから左右に反転 |
 * | 8 | 時計回りに 90 度倒れている | 時計回りに 270 度回す |
 *
 * 0（向きの記録が無い）や未知の値は、写真を読めないとはみなさず、そのままにする。
 */
internal fun orientationFixOf(exifOrientation: Int): OrientationFix = when (exifOrientation) {
    2 -> OrientationFix(0, mirror = true)
    3 -> OrientationFix(180, mirror = false)
    4 -> OrientationFix(180, mirror = true)
    5 -> OrientationFix(90, mirror = true)
    6 -> OrientationFix(90, mirror = false)
    7 -> OrientationFix(270, mirror = true)
    8 -> OrientationFix(270, mirror = false)
    else -> OrientationFix.NONE
}

/**
 * 復号するときの間引きの倍率（`BitmapFactory.Options.inSampleSize`）。
 * 長辺を倍率で割っても [targetLongEdge] を下回らない、最大の 2 の冪にする（下回ると、縮小でなく拡大になって粗くなる）。
 * 長辺は回転で変わらないので、EXIF の向きを直す前の寸法で決めてよい。
 */
internal fun sampleSizeFor(width: Int, height: Int, targetLongEdge: Int): Int {
    val longEdge = maxOf(width, height)
    var sample = 1
    while (longEdge / (sample * 2) >= targetLongEdge) sample *= 2
    return sample
}

/**
 * 長辺を [maxLongEdge] 以下にした寸法。比率を保ち、短辺は四捨五入して 1 以上にする。
 * 長辺が [maxLongEdge] 以下なら、拡大せずにそのまま返す。
 */
internal fun fittedSize(width: Int, height: Int, maxLongEdge: Int): ImageSize {
    val longEdge = maxOf(width, height)
    if (longEdge <= maxLongEdge) return ImageSize(width, height)
    fun scaled(v: Int) = maxOf(1, (v.toDouble() * maxLongEdge / longEdge).roundToInt())
    return if (width >= height) ImageSize(maxLongEdge, scaled(height)) else ImageSize(scaled(width), maxLongEdge)
}

/**
 * EXIF の向きの直し（この操作）のあとに、利用者の回転（時計回りに [quarterTurns]×90 度）を足した 1 つの操作
 * （Kiro android-edit-tools タスク 2.3・K0・design.md:587。焼き込み〔A1〕とプレビュー〔A3〕の両方がこれで向きを合成する：要件 10.3）。
 *
 * この操作は「回してから左右に反転」の順で意味が決まる（[OrientationFix]）。反転の後に時計回りに q 回すのは、
 * 反転の前に反時計回りに q 回すのと同じなので（左右の反転は回転の向きを逆にする）、
 * - 反転が無いとき：回転の角度に 90q を足す
 * - 反転があるとき：回転の角度から 90q を引く（反転はそのまま「最後」に残る）
 * 角度は 0・90・180・270 に収める。[quarterTurns] は負の値や 4 以上でもよい（4 で割った余りとして扱う）。
 */
internal fun OrientationFix.thenQuarterTurns(quarterTurns: Int): OrientationFix {
    val userDegrees = Math.floorMod(quarterTurns, 4) * 90
    val combined = if (mirror) rotationDegrees - userDegrees else rotationDegrees + userDegrees
    return OrientationFix(rotationDegrees = Math.floorMod(combined, 360), mirror = mirror)
}

/**
 * 回した後の絵（[uprightWidth]×[uprightHeight]）のうち、[crop] の範囲の画素の寸法（Kiro android-edit-tools タスク 2.3・K0・design.md:588）。
 * 各辺は「回した後の辺の長さ × 範囲の割合」を四捨五入し、1 以上にする。範囲が全体（FULL）なら、回した後の寸法そのまま。
 * 焼き込みは、この寸法を [fittedSize] で長辺 2048 以下にしたものを出力の寸法にする（拡大しない：要件 10.2・design.md:875）。
 */
internal fun cropPixelSize(uprightWidth: Int, uprightHeight: Int, crop: NormalizedRect): ImageSize = ImageSize(
    width = maxOf(1, (uprightWidth * crop.width).roundToInt()),
    height = maxOf(1, (uprightHeight * crop.height).roundToInt()),
)
