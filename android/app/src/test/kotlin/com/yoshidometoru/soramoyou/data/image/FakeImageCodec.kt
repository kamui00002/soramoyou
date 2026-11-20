// ⭐️ 写真の変換の継ぎ目（ImageCodec）の偽物。変換の入口と、読めるかの確認のテストで共有する（タスク 16.1・21.2・22.1。形は Kiro android-edit-tools タスク 2.4・K0）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.model.FilterId

/**
 * 呼ばれた順と引数を [calls] に記録する偽物。既定は 1000 × 750・向き 1・JPEG 1KB で、どれも成功する。
 *
 * - 復号した画像は「読んだ寸法 / 倍率」の寸法で、記録では `1000x750` のように書く
 * - [transform] が返す画像は、頼まれた寸法で、記録では呼ばれた順の番号を付けて `t1:2048x1536` のように書く
 *   （同じ寸法の画像を取り違えずに、どの画像を解放したかを見分けるため）
 * - [transform] の記録は、切り抜きが全体（[NormalizedRect.FULL]）なら `transform(画像, 向き, 寸法, フィルター)` で、
 *   Kiro android-edit-tools の K0 より前と 1 文字も同じ（今の完全一致の確かめを変えずに緑のままにするため：design.md:776）。
 *   全体でないときだけ、末尾に切り抜きを足して `transform(画像, 向き, 寸法, フィルター, NormalizedRect(left=…, top=…, right=…, bottom=…))` と書く。
 *   フィルターは [FilterId.raw]（無ければ `null`）
 * - [applyColor] は `applyColor(画像, レシピ, 範囲, 全体の縦横比)` と記録し、引数を型のまま [colorCalls] にも控える
 * - [readPixels] は `readPixels(画像)` と記録し、幅 × 高さ個の、どれも [pixelColor] の配列を返す
 * - [encodeJpeg] は、[jpegBytesQueue] に残りがあれば先頭から 1 つずつ返し、空なら [jpegBytes] を返す
 * - 失敗の切り替え（[transformFailure]・[encodeFailure]・[applyColorFailure]・[readPixelsFailure]）は、どれも
 *   「何回目の呼び出しで（1 始まり）、どの例外を投げるか」。その回の呼び出しも記録してから投げる
 * - 解放されていない画像を [live] に持ち、同時に持った枚数の最大を [peakLive] に記録する。
 *   持っていない画像の解放（二重の解放）は AssertionError にする（入口は Exception だけを写すので、テストまで届く）
 */
internal class FakeImageCodec : ImageCodec {
    val calls = mutableListOf<String>()
    var size: ImageSize? = ImageSize(1000, 750)
    var sizeFailure: Exception? = null
    var orientation = 1
    var orientationFailure: Exception? = null
    var decodeReturnsNull = false
    /** 何回目の [transform] で失敗するか（1 始まり）と、その例外。 */
    var transformFailure: Pair<Int, Exception>? = null
    /** 何回目の [encodeJpeg] で失敗するか（1 始まり）と、その例外。 */
    var encodeFailure: Pair<Int, Exception>? = null
    /** 何回目の [applyColor] で失敗するか（1 始まり）と、その例外。 */
    var applyColorFailure: Pair<Int, Exception>? = null
    /** 何回目の [readPixels] で失敗するか（1 始まり）と、その例外。 */
    var readPixelsFailure: Pair<Int, Exception>? = null
    var jpegBytes = ByteArray(1024) { it.toByte() }
    val jpegBytesQueue = ArrayDeque<ByteArray>()
    /** [readPixels] が返す配列の、どの画素にも入れる色（不透明の ARGB）。既定は灰 128。 */
    var pixelColor: Int = 0xFF808080.toInt()

    /** [applyColor] に渡された引数（呼ばれた順）。 */
    val colorCalls = mutableListOf<ColorCall>()

    /** [applyColor] の 1 回の呼び出しの引数。 */
    data class ColorCall(val image: DecodedImage, val recipe: ColorRecipe, val frame: NormalizedRect, val fullAspect: Double)

    /** まだ解放されていない画像（復号した画像と、[transform] が返した画像）。 */
    val live = mutableSetOf<DecodedImage>()
    var peakLive = 0
        private set

    private var transforms = 0
    private var encodes = 0
    private var colorApplies = 0
    private var pixelReads = 0

    private fun hold(image: DecodedImage): DecodedImage {
        live += image
        peakLive = maxOf(peakLive, live.size)
        return image
    }

    private class Decoded(override val width: Int, override val height: Int, private val label: String = "") : DecodedImage {
        override fun toString() = "$label${width}x$height"
    }

    override fun readSize(uri: String): ImageSize? {
        calls += "readSize($uri)"
        sizeFailure?.let { throw it }
        return size
    }

    override fun readExifOrientation(uri: String): Int {
        calls += "readExifOrientation($uri)"
        orientationFailure?.let { throw it }
        return orientation
    }

    override fun decode(uri: String, sampleSize: Int): DecodedImage? {
        calls += "decode($uri, $sampleSize)"
        if (decodeReturnsNull) return null
        val s = checkNotNull(size)
        return hold(Decoded(s.width / sampleSize, s.height / sampleSize))
    }

    override fun transform(image: DecodedImage, fix: OrientationFix, crop: NormalizedRect, size: ImageSize, legacyFilter: FilterId?): DecodedImage {
        transforms++
        // 全体の切り抜きは書かない（K0 より前の記録と 1 文字も同じにする）。全体でないときだけ末尾に足す
        val cropPart = if (crop == NormalizedRect.FULL) "" else ", $crop"
        calls += "transform($image, $fix, $size, ${legacyFilter?.raw}$cropPart)"
        transformFailure?.let { (at, e) -> if (at == transforms) throw e }
        return hold(Decoded(size.width, size.height, label = "t$transforms:"))
    }

    override fun applyColor(image: DecodedImage, recipe: ColorRecipe, frame: NormalizedRect, fullAspect: Double) {
        colorApplies++
        calls += "applyColor($image, $recipe, $frame, $fullAspect)"
        colorCalls += ColorCall(image, recipe, frame, fullAspect)
        applyColorFailure?.let { (at, e) -> if (at == colorApplies) throw e }
    }

    override fun readPixels(image: DecodedImage): IntArray {
        pixelReads++
        calls += "readPixels($image)"
        readPixelsFailure?.let { (at, e) -> if (at == pixelReads) throw e }
        return IntArray(image.width * image.height) { pixelColor }
    }

    override fun encodeJpeg(image: DecodedImage, quality: Int): EncodedJpeg {
        encodes++
        calls += "encodeJpeg($image, $quality)"
        encodeFailure?.let { (at, e) -> if (at == encodes) throw e }
        return EncodedJpeg(jpegBytesQueue.removeFirstOrNull() ?: jpegBytes, image.width, image.height)
    }

    override fun release(image: DecodedImage) {
        calls += "release($image)"
        if (!live.remove(image)) throw AssertionError("持っていない画像を解放した: $image")
    }
}
