// ⭐️ 写真の撮影日時の取得の単体テスト（タスク 22.2・要件 7.14・7.16）
package com.yoshidometoru.soramoyou.data.image

import java.io.FileNotFoundException
import java.io.IOException
import java.time.Instant
import java.time.ZoneId
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlinx.coroutines.runBlocking

/**
 * 「EXIF → 写真選択画面の撮影日時 → なし」の順と、各段の「無い」の判定を、窓口の偽物で確かめる。
 * EXIF の日時の解釈は本物の `ExifDateTimeParser`（タスク 20.2）を通すので、オフセットと端末のタイムゾーンの扱いもここで結合して見る。
 * 本物の ExifInterface・ContentResolver での読み取りは端末で確かめる（`AndroidPhotoMetadataSourceDeviceTest`）。
 */
class DefaultPhotoMetadataReaderTest {

    private val uri = "content://media/picker/0/com.android.providers.media.photopicker/media/1000000034"

    private val source = FakePhotoMetadataSource()
    private var zone: ZoneId = ZoneId.of("America/New_York")
    private val reader = DefaultPhotoMetadataReader(source, deviceZone = { zone })

    private fun capturedAt() = runBlocking { reader.capturedAt(PickedPhoto(uri, 0)) }

    // ── 1 段目：EXIF ──

    @Test
    fun `EXIFの撮影日時とオフセットがあれば、そのオフセットで解釈し、写真選択画面には問い合わせない`() {
        source.exif = ExifDateTime("2026:10:09 07:30:00", "+09:00")

        // 端末はニューヨークでも、撮影時のオフセット（+09:00）で解釈する
        assertEquals(CapturedAt(Instant.parse("2026-10-08T22:30:00Z"), CapturedAtSource.EXIF), capturedAt())
        assertEquals(listOf("readExifDateTime($uri)"), source.calls)
    }

    @Test
    fun `EXIFにオフセットが無ければ、呼んだ時点の端末のタイムゾーンで解釈する`() {
        source.exif = ExifDateTime("2026:10:09 07:30:00", null)

        zone = ZoneId.of("Asia/Tokyo")
        assertEquals(CapturedAt(Instant.parse("2026-10-08T22:30:00Z"), CapturedAtSource.EXIF), capturedAt())
        // 同じ読み手のまま端末のタイムゾーンが変わったら、次の呼び出しから新しいタイムゾーンを使う（ニューヨークは 10 月は夏時間の -04:00）
        zone = ZoneId.of("America/New_York")
        assertEquals(CapturedAt(Instant.parse("2026-10-09T11:30:00Z"), CapturedAtSource.EXIF), capturedAt())
    }

    @Test
    fun `読めないオフセットは端末のタイムゾーンに倒す（20_2の規則がそのまま効く）`() {
        source.exif = ExifDateTime("2026:10:09 07:30:00", "JST")
        zone = ZoneId.of("Asia/Tokyo")

        assertEquals(CapturedAt(Instant.parse("2026-10-08T22:30:00Z"), CapturedAtSource.EXIF), capturedAt())
    }

    // ── 2 段目：写真選択画面の撮影日時 ──

    @Test
    fun `EXIFに撮影日時の記録が無ければ、写真選択画面の撮影日時を使う`() {
        source.exif = ExifDateTime(null, null)
        source.dateTakenMillis = ASSET_INSTANT.toEpochMilli()

        assertEquals(CapturedAt(ASSET_INSTANT, CapturedAtSource.ASSET), capturedAt())
        assertEquals(listOf("readExifDateTime($uri)", "queryDateTakenMillis($uri)"), source.calls)
    }

    @Test
    fun `オフセットだけがあって撮影日時が無いEXIFも、写真選択画面の撮影日時へ進む`() {
        source.exif = ExifDateTime(null, "+09:00")
        source.dateTakenMillis = ASSET_INSTANT.toEpochMilli()

        assertEquals(CapturedAt(ASSET_INSTANT, CapturedAtSource.ASSET), capturedAt())
    }

    @Test
    fun `EXIFの撮影日時が読めても解釈できなければ、写真選択画面の撮影日時へ進む（iOSと同じ）`() {
        source.dateTakenMillis = ASSET_INSTANT.toEpochMilli()
        for (broken in listOf("2026:02:30 07:30:00", "0000:00:00 00:00:00", "2026-10-09 07:30:00", "")) {
            source.exif = ExifDateTime(broken, "+09:00")
            assertEquals(CapturedAt(ASSET_INSTANT, CapturedAtSource.ASSET), capturedAt(), "'$broken'")
        }
    }

    @Test
    fun `EXIFを読めない（写真を開けない・EXIFとして壊れている）ときも、写真選択画面の撮影日時へ進む`() {
        source.dateTakenMillis = ASSET_INSTANT.toEpochMilli()
        for (failure in listOf(IOException("EXIF が壊れている"), FileNotFoundException("写真を開けない"), SecurityException("権限が無い"))) {
            source.exifFailure = failure
            assertEquals(CapturedAt(ASSET_INSTANT, CapturedAtSource.ASSET), capturedAt(), "$failure")
        }
    }

    // ── 3 段目：なし ──

    @Test
    fun `どちらも無ければnull（出所はnone）`() {
        source.exif = ExifDateTime(null, null)
        source.dateTakenMillis = null

        assertNull(capturedAt())
        assertEquals(listOf("readExifDateTime($uri)", "queryDateTakenMillis($uri)"), source.calls)
    }

    @Test
    fun `写真選択画面の撮影日時が0以下なら、無いとみなす`() {
        source.exif = ExifDateTime(null, null)
        for (millis in listOf(0L, -1L)) {
            source.dateTakenMillis = millis
            assertNull(capturedAt(), "$millis")
        }
    }

    @Test
    fun `撮影日時の列を問い合わせられない提供元（列が無い・権限が無い）では、例外にせずnullにする`() {
        source.exifFailure = IOException("EXIF が壊れている")
        for (failure in listOf(IllegalArgumentException("Invalid column datetaken"), SecurityException("権限が無い"))) {
            source.queryFailure = failure
            assertNull(capturedAt(), "$failure")
        }
    }

    @Test
    fun `1ミリ秒の写真選択画面の撮影日時は有効（0との境目）`() {
        source.exif = ExifDateTime(null, null)
        source.dateTakenMillis = 1L

        assertEquals(CapturedAt(Instant.ofEpochMilli(1), CapturedAtSource.ASSET), capturedAt())
    }

    @Test
    fun `写真選択画面の撮影日時がTimestampの上限以上なら、無いとみなす`() {
        // Firestore の Timestamp の上限は 10000-01-01T00:00:00Z（含まない）。範囲の外のまま返すと、投稿の最後の保存で例外になる
        source.exif = ExifDateTime(null, null)
        for (millis in listOf(253402300800000L, Long.MAX_VALUE)) {
            source.dateTakenMillis = millis
            assertNull(capturedAt(), "$millis")
        }
        // 上限の 1 ミリ秒前は範囲の中なので使う（上限ちょうどとの境目）
        source.dateTakenMillis = 253402300799999L
        assertEquals(CapturedAt(Instant.ofEpochMilli(253402300799999L), CapturedAtSource.ASSET), capturedAt())
    }

    @Test
    fun `EXIFが範囲の外でnullになった写真は、写真選択画面の日時も範囲の外ならnull`() {
        // EXIF は 10000-01-01T00:00:59Z（ExifDateTimeParserTest の「上限を超える瞬間はnullにする」と同じ入力）で範囲の外なので、写真選択画面へ進む。
        // 写真選択画面も同じ瞬間を返す（同じ EXIF から日時を作る提供元を想定。端末では確かめていない）ので、どちらの段でも書かない
        source.exif = ExifDateTime("9999:12:31 23:59:59", "-00:01")
        source.dateTakenMillis = 253402300859000L

        assertNull(capturedAt())
        assertEquals(listOf("readExifDateTime($uri)", "queryDateTakenMillis($uri)"), source.calls)
    }

    // ── 取り消し ──

    @Test
    fun `コルーチンの取り消しは、どちらの段でも失敗に写さず、そのまま伝える`() {
        source.exifFailure = CancellationException("取り消し")
        assertFailsWith<CancellationException> { capturedAt() }

        source.exifFailure = null
        source.exif = ExifDateTime(null, null)
        source.queryFailure = CancellationException("取り消し")
        assertFailsWith<CancellationException> { capturedAt() }
    }

    @Test
    fun `出所のrawは、iOSのcaptured_at_sourceの値と同じ`() {
        assertEquals(listOf("exif", "asset", "none"), CapturedAtSource.entries.map { it.raw })
    }

    private class FakePhotoMetadataSource : PhotoMetadataSource {
        val calls = mutableListOf<String>()
        var exif = ExifDateTime(null, null)
        var exifFailure: Exception? = null
        var dateTakenMillis: Long? = null
        var queryFailure: Exception? = null

        override fun readExifDateTime(uri: String): ExifDateTime {
            calls += "readExifDateTime($uri)"
            exifFailure?.let { throw it }
            return exif
        }

        override fun queryDateTakenMillis(uri: String): Long? {
            calls += "queryDateTakenMillis($uri)"
            queryFailure?.let { throw it }
            return dateTakenMillis
        }
    }

    private companion object {
        /** 写真選択画面が返す撮影日時（ミリ秒まで持つ値。EXIF は秒までなので、どちらの段の値かを取り違えると一致しない）。 */
        val ASSET_INSTANT: Instant = Instant.parse("2026-10-09T01:23:45.678Z")
    }
}
