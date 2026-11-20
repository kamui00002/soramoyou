// ⭐️ 撮影日時の読み取りの本番の窓口（AndroidPhotoMetadataSource）を、端末の本物の ExifInterface・ContentResolver で確かめる（タスク 22.2・要件 7.14・7.16）
package com.yoshidometoru.soramoyou.data.image

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.provider.MediaStore
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import java.io.File
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * JVM の単体テストでは ExifInterface・ContentResolver が動かないので、窓口の本番の実装を端末で確かめる。
 * Firebase のエミュレータは使わない。実行は
 * `./gradlew :app:connectedEmulatorDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yoshidometoru.soramoyou.data.image.AndroidPhotoMetadataSourceDeviceTest`
 * （仮想端末が要る。終わると検証用のアプリ〔.emulator〕は端末から消える。本番用のアプリには触れない）。
 *
 * 1. EXIF の撮影日時とオフセットを書いた JPEG から、2 つのタグを文字列のまま読める。読み手を通すと出所は EXIF
 * 1b. `DateTime`（変更日時）しか無い EXIF では、撮影日時のタグは null（iOS も `DateTimeOriginal` だけを見る）
 * 2. EXIF のまったく無い JPEG では、2 つのタグがどちらも null（例外にならない）。file の URI には列を問い合わせられず null。読み手を通すと null（none）
 * 3. 撮影日時の列を持つ提供元（MediaStore）に、渡した URI そのものへ列を問い合わせると、エポックからのミリ秒が返る
 *    （写真選択画面の URI はテストから作れないので、同じ列名を持つ MediaStore で問い合わせの道筋を確かめる。写真選択画面そのものは AVD で手で確かめた）。
 *    EXIF のオフセットは端末の時差と違う値にし、違うことを先に確かめる（同じだと、端末の時差で解釈しても同じ瞬間になって区別できない）
 */
@RunWith(AndroidJUnit4::class)
class AndroidPhotoMetadataSourceDeviceTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val source = AndroidPhotoMetadataSource(context.contentResolver)
    private val dir = File(context.cacheDir, "photo-metadata-device-test").apply { mkdirs() }
    private val insertedMedia = mutableListOf<Uri>()

    @After
    fun deletePhotos() {
        dir.deleteRecursively()
        insertedMedia.forEach { context.contentResolver.delete(it, null, null) }
    }

    @Test
    fun EXIFの撮影日時とオフセットを文字列のまま読み_読み手を通すと出所はEXIF() = runBlocking {
        val file = writeJpeg("with-exif") { exif ->
            exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:10:09 07:30:00")
            exif.setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, "+09:00")
            // 撮影日時とは別の値の DateTime（ファイルを変更した日時）も書く。書かないと ExifInterface が DateTime を
            // DateTimeOriginal の値で埋めて返すので、2 つのタグを取り違えてもこのテストが通ってしまう（2026-10-09 に陽性対照で発見）
            exif.setAttribute(ExifInterface.TAG_DATETIME, "2026:10:10 12:00:00")
        }
        val uri = Uri.fromFile(file).toString()

        assertEquals(ExifDateTime("2026:10:09 07:30:00", "+09:00"), source.readExifDateTime(uri))
        // 端末のタイムゾーンをニューヨークにしても、オフセット（+09:00）で解釈される
        val reader = DefaultPhotoMetadataReader(source, deviceZone = { ZoneId.of("America/New_York") })
        assertEquals(CapturedAt(Instant.parse("2026-10-08T22:30:00Z"), CapturedAtSource.EXIF), reader.capturedAt(PickedPhoto(uri, 0)))
    }

    @Test
    fun DateTimeだけのEXIFでは撮影日時のタグはnull_iOSと同じくDateTimeでは補わない() = runBlocking {
        val file = writeJpeg("datetime-only") { exif -> exif.setAttribute(ExifInterface.TAG_DATETIME, "2026:10:10 12:00:00") }
        val uri = Uri.fromFile(file).toString()

        assertEquals(ExifDateTime(null, null), source.readExifDateTime(uri))
        assertNull(DefaultPhotoMetadataReader(source).capturedAt(PickedPhoto(uri, 0)))
    }

    @Test
    fun EXIFのまったく無いJPEGでは2つのタグがnullで_fileのURIには列が無く_読み手を通すとnull() = runBlocking {
        val file = writeJpeg("no-exif", exif = null)
        val uri = Uri.fromFile(file).toString()
        // 前提の確認：本当に EXIF の区画が無い（Bitmap.compress は EXIF を書かない）
        assertEquals("EXIF の区画が無い", false, hasExifSegment(file.readBytes()))

        assertEquals(ExifDateTime(null, null), source.readExifDateTime(uri))
        val dateTaken = source.queryDateTakenMillis(uri)
        Log.i(TAG, "file の URI への撮影日時の列の問い合わせ: $dateTaken")
        assertNull("file の URI には撮影日時の列が無い", dateTaken)
        assertNull(DefaultPhotoMetadataReader(source).capturedAt(PickedPhoto(uri, 0)))
    }

    // RELATIVE_PATH・IS_PENDING・VOLUME_EXTERNAL_PRIMARY は API 29 から（AVD は API 36）
    @SdkSuppress(minSdkVersion = 29)
    @Test
    fun 撮影日時の列を持つ提供元では_渡したURIそのものへの問い合わせでミリ秒が返る() {
        // EXIF のオフセットは、端末の時差と違う値にする。同じ値だと、MediaStore がオフセットで解釈しても端末の時差で解釈しても
        // 同じ瞬間になり、下の assertEquals が「オフセットで解釈した」ことを確かめられない（全体レビュー 4 回目 Q41。AVD は東京）
        val offset = "-05:00"
        val local = LocalDateTime.of(2026, 10, 9, 7, 30)
        val byOffset = local.atOffset(ZoneOffset.of(offset)).toInstant()          // オフセットで解釈した瞬間（2026-10-09T12:30:00Z）
        val byDeviceZone = local.atZone(ZoneId.systemDefault()).toInstant()        // 端末の時差で解釈した瞬間（MediaStore と同じ端末の設定）
        Log.i(TAG, "端末のタイムゾーン: ${ZoneId.systemDefault()}（オフセットで解釈=$byOffset・端末の時差で解釈=$byDeviceZone）")
        assertNotEquals("端末の時差が EXIF のオフセット（$offset）と同じで、2 つの解釈を区別できない（オフセットを端末と違う値にする）", byOffset, byDeviceZone)

        // オフセットつきの EXIF を書いた JPEG を、このアプリの持ち物として MediaStore に入れる（自分の写真なので権限は要らない）
        val bytes = writeJpeg("media-store") { exif ->
            exif.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, "2026:10:09 07:30:00")
            exif.setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, offset)
        }.readBytes()
        val resolver = context.contentResolver
        val uri = resolver.insert(
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
            ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, "soramoyou-22.2-device-test.jpg")
                put(MediaStore.MediaColumns.MIME_TYPE, "image/jpeg")
                put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/soramoyou-22.2-device-test")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            },
        )
        assertNotNull("MediaStore に入れられる", uri)
        insertedMedia += uri!!
        resolver.openOutputStream(uri)!!.use { it.write(bytes) }
        // 書き終えたら公開する（このとき MediaStore がファイルを読み、EXIF から撮影日時の列を埋める）
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)

        val dateTaken = source.queryDateTakenMillis(uri.toString())
        Log.i(TAG, "MediaStore の撮影日時の列: $dateTaken（${dateTaken?.let(Instant::ofEpochMilli)}）")
        // MediaStore は EXIF の日時をオフセットで解釈した瞬間を入れる（端末の時差で解釈した瞬間とは違うことを上で確かめてある）
        assertEquals(byOffset.toEpochMilli(), dateTaken)
    }

    // ── 道具 ──

    /** 単色の 64×48 の JPEG を書き、[exif] があれば EXIF を足して保存する（22.1 の端末テストと同じ作り方）。 */
    private fun writeJpeg(name: String, exif: ((ExifInterface) -> Unit)?): File {
        val file = File(dir, "$name.jpg")
        val bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.CYAN) }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        bitmap.recycle()
        if (exif != null) ExifInterface(file).apply { exif(this); saveAttributes() }
        return file
    }

    /** JPEG の画素の始まり（SOS）より前に、EXIF の区画（APP1 で "Exif\u0000\u0000" で始まる）があるか（22.1 の端末テストと同じ検査）。 */
    private fun hasExifSegment(jpeg: ByteArray): Boolean {
        var i = 2
        while (i + 4 <= jpeg.size && jpeg[i] == 0xFF.toByte()) {
            val marker = jpeg[i + 1].toInt() and 0xFF
            if (marker == 0xDA) return false
            val length = ((jpeg[i + 2].toInt() and 0xFF) shl 8) or (jpeg[i + 3].toInt() and 0xFF)
            if (marker == 0xE1 && i + 10 <= jpeg.size && String(jpeg, i + 4, 6, Charsets.ISO_8859_1) == "Exif\u0000\u0000") return true
            i += 2 + length
        }
        return false
    }

    private companion object {
        const val TAG = "PhotoMetadataDeviceTest"
    }
}
