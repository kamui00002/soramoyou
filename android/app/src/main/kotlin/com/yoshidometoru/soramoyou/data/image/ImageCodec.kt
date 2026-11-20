// ⭐️ 写真の変換と Android の画像 API の間の継ぎ目（タスク 16.1・22.1。単体テストで偽物に差し替える）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.model.FilterId

/** 画像の画素の寸法。 */
internal data class ImageSize(val width: Int, val height: Int)

/**
 * 画素を持つ画像（本番では Bitmap を包む）。[width]・[height] は画素の寸法。
 * [ImageCodec.decode] が返したものは EXIF の向きを直す前、[ImageCodec.transform] が返したものは正立に直した後の寸法。
 */
internal interface DecodedImage {
    val width: Int
    val height: Int
}

/** JPEG にした結果。[width]・[height] は圧縮した画素の寸法。ByteArray を持つため data class にしない。 */
internal class EncodedJpeg(val bytes: ByteArray, val width: Int, val height: Int)

/**
 * Android の画像 API（BitmapFactory・ExifInterface・Canvas・Bitmap.compress）を呼ぶ部分だけを切り出した継ぎ目。
 * 間引きの倍率・向き・縮小後の大きさ・5MB の判定・作る順序と解放の時機は持たない（それは [DefaultImagePipeline]）。
 * 本番の実装は [AndroidImageCodec]、単体テストでは呼ばれた順と引数を記録する偽物を使う。
 *
 * どのメソッドも、読めないときは null を返すか例外を投げる。どちらも入口が `ImageUnreadable` に写す。
 * この package の外から使わせないため internal にしている。
 */
internal interface ImageCodec {

    /** 画素を復号せずに、画像の寸法（EXIF の向きを直す前）だけを読む。読めなければ null。 */
    fun readSize(uri: String): ImageSize?

    /** EXIF の向き（`Orientation` の値。1〜8、無ければ 0）を読む。 */
    fun readExifOrientation(uri: String): Int

    /** 縦横を 1/[sampleSize] に間引いて復号する（[sampleSize] は 2 の冪）。読めなければ null。 */
    fun decode(uri: String, sampleSize: Int): DecodedImage?

    /**
     * [image] を [fix] のとおりに回転・反転し、回した後の絵の [crop] の範囲を、ちょうど [size]（正立に直した後の向き）に描き、
     * [legacyFilter] があればその色の変換（[FilterId.legacyMatrix]）を描画の中で掛けた、新しい画像を返す
     * （タスク 22.1。形は Kiro android-edit-tools タスク 2.3・K0・design.md:578-579）。
     * [legacyFilter] の行列が null（ナチュラル・ウォーム・クール・ビンテージ）なら、行列は掛けない。
     * 回転・反転・色の変換は最後の 1 回の描画で行う。大きく縮めるときは、モアレを防ぐため縮小だけの途中の画像を作ることがあり、
     * それは中で解放する（タスク 25.4）。[image] 自体は解放しない（解放は [release]）。
     *
     * K0 の時点では、[crop] は全体（[NormalizedRect.FULL]）のときだけ正しく描けばよい（切り抜きの描画は A1 が入れる。
     * K0 から A1 までの間、全体でない [crop] で呼ぶ所は無い：design.md:361）。
     */
    fun transform(image: DecodedImage, fix: OrientationFix, crop: NormalizedRect, size: ImageSize, legacyFilter: FilterId?): DecodedImage

    /**
     * [image] の画素に [recipe] をその場で掛ける（帯ごと）。[frame]・[fullAspect] は `ColorKernel.render` と同じ意味
     * （Kiro android-edit-tools design.md:580-581）。K0 では中身を入れず、K0 の本体はこれを呼ばない（中身は A1 が入れる）。
     */
    fun applyColor(image: DecodedImage, recipe: ColorRecipe, frame: NormalizedRect, fullAspect: Double)

    /**
     * [image] の画素を、不透明の ARGB（sRGB）・行優先で読む（幅×高さ個）。[image] は変えない。プレビューが使う
     * （Kiro android-edit-tools design.md:582-583。K0 が本物を入れる：design.md:358）。
     */
    fun readPixels(image: DecodedImage): IntArray

    /** [image] をそのままの寸法で、品質 [quality] の JPEG にする。出力に EXIF を書かない。[image] 自体は解放しない。 */
    fun encodeJpeg(image: DecodedImage, quality: Int): EncodedJpeg

    /** [image] の画素のメモリを解放する。 */
    fun release(image: DecodedImage)
}
