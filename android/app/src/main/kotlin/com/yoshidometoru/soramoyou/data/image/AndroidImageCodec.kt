// ☁️ 写真の変換の継ぎ目の本番の実装：BitmapFactory・ExifInterface・Canvas・Bitmap.compress を呼ぶ（タスク 16.1・22.1）
package com.yoshidometoru.soramoyou.data.image

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.ColorMatrixColorFilter
import android.graphics.ColorSpace
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import com.yoshidometoru.soramoyou.contract.edit.ColorKernel
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.NormalizedRect
import com.yoshidometoru.soramoyou.contract.model.FilterId
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream

/**
 * [ImageCodec] の本番の実装。写真は [resolver] から content URI で開く（フォトピッカーの URI は読み取りの権限つきで渡される）。
 *
 * - 復号は sRGB・ARGB_8888 にそろえる（広い色域の写真も sRGB へ変換してから JPEG にする。設計書「sRGB の品質 90 の JPEG」）
 * - `Bitmap.compress` は EXIF を書かないため、撮影位置を含むメタデータは出力に残らない（要件 7.2）
 * - 回転・反転・切り抜き・縮小は 1 つの `Matrix` にまとめ、今の 6 種のフィルターの色の変換（`ColorMatrixColorFilter`）と合わせて
 *   `Canvas` の最後の 1 回の描画で行う（タスク 22.1。切り抜きは Kiro android-edit-tools タスク 12・A1：design.md:888）。
 *   色の変換は sRGB のガンマ付きの値に掛かり、プレビュー（Compose の `ColorFilter.colorMatrix`）と同じ
 * - ただし切り抜いた範囲が目標の 2 倍を超えて縮むとき（サムネイル）は、細い模様がモアレにならないよう、その前に縮小だけの途中の画像を作る
 *   （[shrinkForFinalDraw]・タスク 25.4）
 * - 新しいフィルターとツールの色（`ColorRecipe`）は、描いた後の画像に [applyColor] で帯ごとに掛ける（色の定義は `ColorKernel` の 1 か所：要件 11.5）
 *
 * ⚠️ JVM の単体テストでは Android の画像 API が動かないため、このクラスは単体テストの対象外。
 * 色の変換の尺度・向き・寸法・出力に EXIF が無いこと・切り抜きの位置と端・帯ごとの色は、端末で動かす
 * `AndroidImageCodecDeviceTest`（androidTestEmulator）で確かめる。
 */
internal class AndroidImageCodec(private val resolver: ContentResolver) : ImageCodec {

    override fun readSize(uri: String): ImageSize? {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        open(uri).use { BitmapFactory.decodeStream(it, null, options) }
        // 読めない形式のときは outWidth・outHeight が -1 のまま
        return if (options.outWidth > 0 && options.outHeight > 0) ImageSize(options.outWidth, options.outHeight) else null
    }

    override fun readExifOrientation(uri: String): Int =
        open(uri).use { ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED) }

    override fun decode(uri: String, sampleSize: Int): DecodedImage? {
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)
        }
        val bitmap = open(uri).use { BitmapFactory.decodeStream(it, null, options) } ?: return null
        return BitmapImage(bitmap)
    }

    /**
     * [fix] のとおりに回し、回した後の絵の [crop] の範囲を、ちょうど [size] に描く（Kiro android-edit-tools タスク 12・A1・design.md:888-889）。
     * [crop] が全体（[NormalizedRect.FULL]）なら、行列も途中の縮小の判定も今と同じになる。[legacyFilter] の行列が null なら行列を掛けない。
     */
    override fun transform(
        image: DecodedImage,
        fix: OrientationFix,
        crop: NormalizedRect,
        size: ImageSize,
        legacyFilter: FilterId?,
    ): DecodedImage {
        val decoded = (image as BitmapImage).bitmap
        // 途中の画像は回転前の向きで作るので、目標の寸法と、切り抜く範囲の幅・高さの割合も回転前の向きにして渡す
        // （90 度・270 度の回転では、回した後の幅が回す前の高さに当たる）
        val shrunk = if (fix.swapsAxes) {
            shrinkForFinalDraw(decoded, ImageSize(size.height, size.width), cropWidthFraction = crop.height, cropHeightFraction = crop.width)
        } else {
            shrinkForFinalDraw(decoded, size, cropWidthFraction = crop.width, cropHeightFraction = crop.height)
        }
        try {
            return BitmapImage(drawUpright(shrunk, fix, crop, size, legacyFilter))
        } finally {
            // 途中の画像はここで解放する。復号した画像（[image]）は解放しない
            if (shrunk !== decoded) shrunk.recycle()
        }
    }

    /**
     * [image] の画素に [recipe] をその場で掛ける（Kiro android-edit-tools タスク 12・A1・design.md:885・890）。
     * 帯（[BAND_ROWS] 行 × 幅の `IntArray` を 1 つだけ）ごとに `getPixels` → `ColorKernel.render` → `setPixels` を行い、
     * 画像全体の画素の配列は作らない（同時に持つ画像を増やさない）。
     *
     * 帯ごとの frame は、全体の [frame] の中の、その帯の範囲（左右は全体のまま、上下は帯の行の割合）。
     * こうすると `ColorKernel.render` の画素の位置（画素の中心の割合）が、全体を 1 回で掛けたときと同じになり、
     * 位置で決まる周辺減光（ビンテージ）に帯の境目の線が出ない（ColorKernel の「画素の位置」の説明）。
     *
     * [image] は [transform] が返したもの（書き換えられる Bitmap）にだけ掛けられる。[decode] が返す画像は書き換えられない。
     * `getPixels`・`setPixels` は sRGB の ARGB の値で読み書きする（この窓口の画像は sRGB なので、変換は入らない）。
     */
    override fun applyColor(image: DecodedImage, recipe: ColorRecipe, frame: NormalizedRect, fullAspect: Double) {
        val bitmap = (image as BitmapImage).bitmap
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return
        // 帯の配列は 1 つだけ。最後の短い帯でも同じ配列を使う（ColorKernel.render は先頭の 幅×行数 個だけを掛ける）
        val band = IntArray(width * minOf(BAND_ROWS, height))
        var top = 0
        while (top < height) {
            val rows = minOf(BAND_ROWS, height - top)
            bitmap.getPixels(band, 0, width, 0, top, width, rows)
            // この帯が、全体の frame の中で占める上下の範囲（行の割合を frame の高さに掛ける）
            val bandFrame = NormalizedRect(
                left = frame.left,
                top = frame.top + frame.height * top / height,
                right = frame.right,
                bottom = frame.top + frame.height * (top + rows) / height,
            )
            ColorKernel.render(band, width, rows, recipe, bandFrame, fullAspect)
            bitmap.setPixels(band, 0, width, 0, top, width, rows)
            top += rows
        }
    }

    /**
     * 画素を、不透明の ARGB（sRGB）・行優先で読む（K0 が本物を入れる：design.md:358）。[image] は変えない。
     * `Bitmap.getPixels` は sRGB の ARGB の値で返す。この窓口が作る画像は、復号も描画の出力も sRGB・ARGB_8888 で、
     * 描画の出力は不透明の指定（[drawUpright] の `hasAlpha = false`）で作る。読んだ値の透明度は書き換えずにそのまま返す。
     */
    override fun readPixels(image: DecodedImage): IntArray {
        val bitmap = (image as BitmapImage).bitmap
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return pixels
    }

    /**
     * 切り抜いた範囲が目標の 2 倍を超えている間は、回転前の向きのまま 0.5 倍の段を重ねた途中の画像を作る（タスク 25.4。
     * 「切り抜いた範囲が」への読み替えは Kiro android-edit-tools タスク 12・A1・design.md:889）。
     * [target] は回転前の向きにした目標の寸法。[cropWidthFraction]・[cropHeightFraction] は、切り抜く範囲の幅・高さの割合を
     * 回転前の向きにしたもの（全体なら 1 と 1 で、判定は読み替える前と同じ）。途中の画像が要らなければ [source] をそのまま返す。
     * 切り抜く範囲は割合で決まるので、途中の画像を縮めても、最後の描画が同じ割合で同じ中身を切り抜く。
     *
     * 切り抜く前の寸法で判定すると、小さく切り抜いたときに、切り抜いた範囲が目標より小さくなるまで縮めてしまい、
     * 最後の描画で拡大することになって粗くなる。
     *
     * 双線形の 1 回の描画で大きく縮めると、近くの 2×2 画素の外を混ぜずに飛ばすので、細い模様が元に無い模様（モアレ）になる。
     * ちょうど 0.5 倍の双線形は 2×2 画素の平均になって飛ばさないので、段を重ねてから最後の描画で残りを縮める
     * （サムネイル：2048→1024 のあと、最後の描画で 512）。
     *
     * 本体（間引いて復号した 4000×3000 などを 2048 へ。0.5 倍より緩い縮小）は段が入らず、これまでどおり 1 回の双線形で縮める。
     * 目標のちょうど 2 倍（4096×3072）へ描き直してから 0.5 倍にすると本体のモアレも減る（D01 で誤差 14.99→8.85）が、
     * 48MP 相当 10 枚の投稿でメモリのピークが変更前より約 97MB 増え（2026-10-11・AVD・同じ条件で新旧を測定）、
     * 決めた上限 +60MB を超えたので採らなかった（ユーザー判断）。
     * 復号の時点で縮める `ImageDecoder.setTargetSize` は誤差 27.91 で悪化し、`Bitmap.setHasMipMap` はソフトウェアの Canvas では効かなかった。
     * 回転・反転・フィルターは途中で掛けない（丸めが重なる）。最後の描画で 1 回だけ掛ける
     */
    private fun shrinkForFinalDraw(source: Bitmap, target: ImageSize, cropWidthFraction: Double, cropHeightFraction: Double): Bitmap {
        val doubleWidth = target.width * 2
        val doubleHeight = target.height * 2
        var current = source
        // 途中の画像を作り直したら、前の途中の画像はすぐ解放する（同時に持つ途中の画像は 1 枚まで）
        fun replaceWith(width: Int, height: Int) {
            val next = scaledCopy(current, width, height)
            if (current !== source) current.recycle()
            current = next
        }
        try {
            // 今の途中の画像の中で、切り抜いた範囲が占める幅・高さ（画素）で判定する
            while (current.width * cropWidthFraction > doubleWidth && current.height * cropHeightFraction > doubleHeight) {
                replaceWith(current.width / 2, current.height / 2)
            }
            return current
        } catch (e: Throwable) {
            if (current !== source) current.recycle()
            throw e
        }
    }

    /** [source] を回さずに、ちょうど [width]×[height] へ双線形で描いた新しい画像（途中の画像。色の変換は掛けない）。 */
    private fun scaledCopy(source: Bitmap, width: Int, height: Int): Bitmap {
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888, false, ColorSpace.get(ColorSpace.Named.SRGB))
        try {
            val matrix = Matrix().apply { setScale(width.toFloat() / source.width, height.toFloat() / source.height) }
            Canvas(output).drawBitmap(source, matrix, Paint(Paint.FILTER_BITMAP_FLAG))
        } catch (e: Throwable) {
            output.recycle()
            throw e
        }
        return output
    }

    /**
     * [source] を [fix] のとおりに回転・反転し、回した後の絵の [crop] の範囲をちょうど [size] へ縮め、[legacyFilter] の色の変換を掛けた
     * 新しい画像を、1 回の描画で作る（切り抜きは Kiro android-edit-tools タスク 12・A1・design.md:888）。
     * [legacyFilter] の行列が null（ナチュラル・ウォーム・クール・ビンテージ）なら行列を掛けない（design.md:360）。
     *
     * 切り抜く範囲は画素の単位でも小数のまま使い、範囲の左上を (0, 0) へ寄せてから、範囲の幅・高さが [size] にちょうど
     * 重なる倍率で縮める。出力の寸法（[size]）は呼ぶ側が `cropPixelSize` の四捨五入で決めているので、倍率は四捨五入の分だけ
     * わずかに伸び縮みするが、範囲が出力の全面を覆うので、端に余白や黒い線はできない（design.md:893）。
     * 範囲が全体なら、寄せる量は 0、倍率は「正立後の寸法 → 目標の寸法」で、行列は切り抜きを入れる前と同じになる。
     */
    private fun drawUpright(source: Bitmap, fix: OrientationFix, crop: NormalizedRect, size: ImageSize, legacyFilter: FilterId?): Bitmap {
        val uprightWidth = if (fix.swapsAxes) source.height else source.width
        val uprightHeight = if (fix.swapsAxes) source.width else source.height
        val matrix = Matrix().apply {
            // 回してから反転する（OrientationFix の順序）
            postRotate(fix.rotationDegrees.toFloat())
            if (fix.mirror) postScale(-1f, 1f)
            // 回転・反転で座標が負になった分を、左上が (0, 0) に来るよう戻す。
            // createBitmap(…, matrix, …) はこれを自動でするが、Canvas の描画はしないので、戻さないと画面の外に描いて真っ黒になる
            val bounds = RectF(0f, 0f, source.width.toFloat(), source.height.toFloat()).also { mapRect(it) }
            postTranslate(-bounds.left, -bounds.top)
            // 回した後の絵の中の、切り抜く範囲の左上を (0, 0) へ寄せる（全体なら 0 だけ動かす＝何もしない）
            postTranslate(-(uprightWidth * crop.left).toFloat(), -(uprightHeight * crop.top).toFloat())
            // 最後に、切り抜く範囲の寸法から目標の寸法へ縮小する（全体なら 正立後の寸法 → 目標の寸法 で、前と同じ値）
            postScale(size.width.toFloat() / (uprightWidth * crop.width).toFloat(), size.height.toFloat() / (uprightHeight * crop.height).toFloat())
        }
        // 出力はちょうど目標の寸法・sRGB・不透明（JPEG にするので透明度は要らない）
        val output = Bitmap.createBitmap(size.width, size.height, Bitmap.Config.ARGB_8888, false, ColorSpace.get(ColorSpace.Named.SRGB))
        try {
            // 縮小は双線形（createBitmap(…, filter = true) と同じ）。回転は 90 度の倍数で縁が画素に揃うので、縁の滑らかさ（anti-alias）は要らない
            val paint = Paint(Paint.FILTER_BITMAP_FLAG).apply {
                legacyFilter?.legacyMatrix()?.let { colorFilter = ColorMatrixColorFilter(it) }
            }
            Canvas(output).drawBitmap(source, matrix, paint)
        } catch (e: Throwable) {
            output.recycle()
            throw e
        }
        return output
    }

    override fun encodeJpeg(image: DecodedImage, quality: Int): EncodedJpeg {
        val bitmap = (image as BitmapImage).bitmap
        val bytes = ByteArrayOutputStream().use { out ->
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) throw IOException("JPEG に圧縮できない")
            out.toByteArray()
        }
        return EncodedJpeg(bytes, bitmap.width, bitmap.height)
    }

    override fun release(image: DecodedImage) {
        (image as BitmapImage).bitmap.recycle()
    }

    private fun open(uri: String): InputStream =
        resolver.openInputStream(Uri.parse(uri)) ?: throw IOException("写真を開けない")

    private class BitmapImage(val bitmap: Bitmap) : DecodedImage {
        override val width: Int get() = bitmap.width
        override val height: Int get() = bitmap.height
    }

    private companion object {
        /** [applyColor] の帯の行数（64 行×幅の `IntArray` を 1 つだけ持つ：design.md:885） */
        const val BAND_ROWS = 64
    }
}
