// ⭐️ 写真の撮影日時を、EXIF → 写真選択画面の撮影日時 → なし の順で取得する（設計書の部品 PhotoMetadataReader。タスク 22.2・要件 7.14・7.16）
package com.yoshidometoru.soramoyou.data.image

import com.yoshidometoru.soramoyou.contract.rules.ExifDateTimeParser
import java.time.Instant
import java.time.ZoneId
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 投稿の撮影日時（`capturedAt`）の出所。[raw] はそのまま `post_completed` の `captured_at_source` の値になる
 * （iOS の `CapturedAtSource`：ExternalEditInfo.swift:177-186。iOS の `preserved` は再編集の計装専用なので Android には無い）。
 */
enum class CapturedAtSource(val raw: String) {
    /** 元ファイルの EXIF `DateTimeOriginal`。 */
    EXIF("exif"),

    /** 写真選択画面が提供する撮影日時（iOS の `PHAsset.creationDate` に当たる）。 */
    ASSET("asset"),

    /** どちらも無い（`capturedAt`・`timeOfDay` のキーを書かない）。 */
    NONE("none"),
}

/** 撮影の瞬間と、その出所。出所が [CapturedAtSource.NONE] のときは、この値自体を作らずに null で表す。 */
data class CapturedAt(val instant: Instant, val source: CapturedAtSource)

/**
 * 写真の撮影日時を取得する（設計書「ImagePipeline・PhotoMetadataReader」の撮影日時の段落）。
 * 投稿では先頭の写真だけを渡す（どの写真を代表にするかと、時間帯の判定は呼び出し側＝タスク 23.2 の仕事）。
 */
interface PhotoMetadataReader {

    /**
     * [photo] の撮影日時。次の順で探し、最初に見つかったものを返す（iOS の `resolvedCapturedAt`：ExternalEditInfo.swift:78-86 と同じ優先順位）。
     *
     * 1. 元ファイルの EXIF の `DateTimeOriginal`（と `OffsetTimeOriginal`）を [ExifDateTimeParser] の規則で解釈した値（[CapturedAtSource.EXIF]）
     * 2. 写真選択画面が提供する撮影日時の列（[CapturedAtSource.ASSET]）
     * 3. どちらも無ければ null（出所は [CapturedAtSource.NONE]）
     */
    suspend fun capturedAt(photo: PickedPhoto): CapturedAt?
}

/**
 * EXIF から読んだ 2 つの文字列（解釈する前の生の値）。記録が無ければそれぞれ null。
 *
 * @param dateTimeOriginal `DateTimeOriginal`（`"2026:10:09 07:30:00"` の形の壁時計）
 * @param offsetTimeOriginal `OffsetTimeOriginal`（`"+09:00"` の形。EXIF 2.31 から）
 */
internal data class ExifDateTime(val dateTimeOriginal: String?, val offsetTimeOriginal: String?)

/**
 * 撮影日時の読み取りの継ぎ目。ExifInterface と ContentResolver は Android の API なので、この向こうに置く
 * （JVM の単体テストでは偽物に差し替える。本番の実装は [AndroidPhotoMetadataSource]）。
 * 画素の変換の継ぎ目（[ImageCodec]）とは分けてある：こちらは画素を復号しない。
 */
internal interface PhotoMetadataSource {

    /** [uri] の写真の EXIF から撮影日時の 2 つのタグを読む。開けない・EXIF として読めなければ例外。 */
    fun readExifDateTime(uri: String): ExifDateTime

    /**
     * [uri] そのものに撮影日時の列を問い合わせ、エポックからのミリ秒を返す。列が無い・値が無ければ null。
     * 写真選択画面の URI 以外（列を持たない提供元）では null か例外になる。
     */
    fun queryDateTakenMillis(uri: String): Long?
}

/**
 * [PhotoMetadataReader] の実装。判断だけを行い、Android の API には触らない。
 *
 * - EXIF は `DateTimeOriginal` だけを見る（iOS も同じ：ImageService.swift:1004。`DateTime`・`DateTimeDigitized` への補完はしない）
 * - EXIF の日時が**読めても解釈できない**とき（`2026:02:30 …`・`0000:00:00 00:00:00` など）も次の段へ進む。
 *   iOS も解釈に失敗すると `exifCapturedAt` が nil になり、写真ライブラリの作成日時へ進む
 * - 写真選択画面の撮影日時が 0 以下なら「無い」とみなす。列は整数なので、値の無い印として 0 が入っていても、
 *   1970 年 1 月 1 日の撮影日時として書かないための備え（iOS の `PHAsset.creationDate` には同じ検査が無い）
 * - 写真選択画面の撮影日時が Firestore の `Timestamp` の範囲の外（10000-01-01T00:00:00Z 以降）でも「無い」とみなす。
 *   EXIF の段と同じ判定（[ExifDateTimeParser.Default.isWithinTimestampRange]）で見る。範囲の外のまま返すと、
 *   投稿の最後の文書の保存で `Timestamp(instant)` が例外になり、やり直しても同じ失敗になるため
 * - 窓口の例外（写真を開けない・権限が無い・列を問い合わせられない）は、その段を「無い」として次へ進む（投稿は止めない）。
 *   コルーチンの取り消しは失敗に写さずにそのまま伝える（[DefaultPhotoProbe] と同じ）
 *
 * @param deviceZone オフセットの無い EXIF の日時を解釈するタイムゾーン。呼んだ時点の端末のタイムゾーンを毎回読む
 * @param dispatcher 読み取りを行うスレッド。画面のスレッドでファイルを読まないよう、既定は IO
 */
class DefaultPhotoMetadataReader internal constructor(
    private val source: PhotoMetadataSource,
    private val parser: ExifDateTimeParser = ExifDateTimeParser,
    private val deviceZone: () -> ZoneId = ZoneId::systemDefault,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) : PhotoMetadataReader {

    override suspend fun capturedAt(photo: PickedPhoto): CapturedAt? = withContext(dispatcher) {
        fromExif(photo.uri)?.let { CapturedAt(it, CapturedAtSource.EXIF) }
            ?: fromPicker(photo.uri)?.let { CapturedAt(it, CapturedAtSource.ASSET) }
    }

    /** EXIF の撮影日時を解釈した瞬間。記録が無い・解釈できない・読めなければ null。 */
    private fun fromExif(uri: String): Instant? {
        val exif = orNullOnFailure { source.readExifDateTime(uri) } ?: return null
        val original = exif.dateTimeOriginal ?: return null
        return parser.parse(original, exif.offsetTimeOriginal, deviceZone())
    }

    /** 写真選択画面が提供する撮影日時。列が無い・0 以下・Firestore の `Timestamp` の範囲の外・問い合わせられなければ null。 */
    private fun fromPicker(uri: String): Instant? {
        val millis = orNullOnFailure { source.queryDateTakenMillis(uri) } ?: return null
        if (millis <= 0) return null
        val instant = Instant.ofEpochMilli(millis)
        return if (ExifDateTimeParser.isWithinTimestampRange(instant)) instant else null
    }

    /** [read] の例外を null にする。コルーチンの取り消しだけはそのまま投げ直す。 */
    private inline fun <T> orNullOnFailure(read: () -> T?): T? = try {
        read()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }
}
