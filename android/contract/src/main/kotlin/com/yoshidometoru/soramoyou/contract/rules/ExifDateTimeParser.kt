// ⭐️ EXIF の撮影日時を解釈する（タスク 20.2・要件 7.14・7.16）
package com.yoshidometoru.soramoyou.contract.rules

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.chrono.IsoChronology
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.format.ResolverStyle
import java.util.Locale

/**
 * EXIF の `DateTimeOriginal`（`"yyyy:MM:dd HH:mm:ss"`）と `OffsetTimeOriginal`（`"+09:00"`）を、撮影の瞬間（[Instant]）に直す。
 *
 * ## iOS 版の規則（Soramoyou/Soramoyou/Services/ImageService.swift:1039-1072 の `parseEXIFDateTime`）
 * - 書式は `yyyy:MM:dd HH:mm:ss`。暦はグレゴリオ暦、ロケールは `en_US_POSIX` に固定する（端末が和暦でも年がずれない）
 * - EXIF の日時はタイムゾーンを持たない「壁時計」の値。オフセットが読めればそのオフセットで、読めなければ端末のタイムゾーンで解釈する
 * - オフセットが読めるのは、6 文字（符号＋時 2 桁＋`:`＋分 2 桁）で、時が 0〜23・分が 0〜59 のときだけ。
 *   さらに iOS の `TimeZone(secondsFromGMT:)` は ±18 時間を超えると作れないので、`+19:00`〜`+23:59` も端末のタイムゾーンに倒れる。
 *   `JST`・`+0900`・`Z`・空文字なども端末のタイムゾーンに倒れる（例外にしない）
 * - 解釈できなければ null（投稿は続ける。`capturedAt`・`timeOfDay` のキーを書かない：PostViewModel.swift:293-300）
 * - Android は、解釈した瞬間が Firestore の `Timestamp` の範囲（0001-01-01T00:00:00Z 以上・10000-01-01T00:00:00Z 未満）の外でも null にする
 *   （下の「iOS との差」）
 *
 * ## iOS と同じ結果になることの確認
 * 49 個の入力を、iOS と同じコードの写しで Swift 6.4（macOS 27）に流し、端末のタイムゾーンを東京とニューヨークにして実測した
 * （手元（git の外）の `20.2-exif.swift`・`20.2-exif_tokyo.tsv`・`20.2-exif_ny.tsv`）。テストの期待値はその epoch 秒である。
 * - 夏時間で同じ壁時計が 2 回ある時刻（ニューヨークの 11 月の 1:30 など）は、iOS は**遅い方のオフセット（標準時）**で解釈する。
 *   java.time の既定は早い方なので、[java.time.ZonedDateTime.withLaterOffsetAtOverlap] で揃える。
 *   夏時間で存在しない時刻（3 月の 2:30）は、iOS も java.time も 1 時間進めた時刻になり、同じ瞬間になる
 *
 * ## iOS との差（意図して、iOS より厳しくしてある）
 * iOS の `DateFormatter` は寛容で、次の入力を「別の日時」として通してしまう。Android は同じ値を作らず、null にする
 * （iOS の実測値は右側）。どれも正規の EXIF の書式ではなく、通しても正しい撮影日時にならない。
 * - 存在しない日：`2026:02:30` → 3 月 2 日、閏年でない `2026:02:29` → 3 月 1 日、`24:00:00` → 翌日の 0 時
 * - 桁数の違い：1 桁の月・日・時（`2026:1:9`・`1:02:03`）、2 桁の年（`26` → 西暦 26 年）、5 桁の年（`20260` → 西暦 20260 年）
 * - ASCII 以外の数字：全角数字・アラビア数字の年
 * - 空白：前後の空白、日付と時刻の間の空白 2 つ
 *
 * オフセットにも 1 つ差がある。`++1:00` を iOS は +01:00 と読む（`Int("+1")` が 1 になるため）。
 * Android は時の桁に符号を許さず、読めないオフセットとして**端末のタイムゾーンに倒す**（null にはしない）。
 *
 * 1582 年より前の日付も 1 つ差がある。iOS のグレゴリオ暦はそれより前をユリウス暦で数えるので、西暦 1 年 1 月 1 日が 2 日早い瞬間になる。
 * java.time は先発グレゴリオ暦のまま。その時代の写真は無いので揃えない。
 *
 * 解釈した瞬間が Firestore の `Timestamp` の範囲の外になる入力も、Android は null にする（`0000:01:01`、端末のタイムゾーンの古い時差で下限を下回る `0001:01:01`、
 * 上限を超える `9999:12:31 23:59:59` など。時差の分だけ端の日付は範囲の内外が端末で変わる）。
 * 範囲の外のまま返すと、投稿の最後の文書の保存で `Timestamp(instant)` が IllegalArgumentException になり、やり直しても同じ失敗になるため。
 *
 * 一方、iOS が null にするもの（`-` 区切り・全部 0・13 月・60 秒・末尾の NUL や文字・小数秒・秒なし・`T` 区切り）は、Android も null にする。
 *
 * ## 端末での未確認事項（タスク 25.2 で確かめる）
 * - Android の `ExifInterface.getAttribute` が、末尾の NUL や空白を落とした文字列を返すかどうか。落とさない場合、
 *   iOS では読める写真が Android では null になる（その場合は呼び出し側で落とす）
 *
 * インターフェースにしてあるのは、画面側のテストが差し替えられるようにするため（設計書 :612）。
 * 本番の実装は [Default] で、`ExifDateTimeParser.parse(...)` のように直接呼べる。
 */
interface ExifDateTimeParser {

    /**
     * [dateTimeOriginal] を、[offsetTimeOriginal] のオフセット（読めなければ [deviceZone]）の壁時計として解釈する。
     * 解釈できなければ null。解釈した瞬間が Firestore の `Timestamp` の範囲（0001-01-01T00:00:00Z 以上・10000-01-01T00:00:00Z 未満）の外でも null
     * （範囲の判定は [Default.isWithinTimestampRange]）。
     */
    fun parse(dateTimeOriginal: String, offsetTimeOriginal: String?, deviceZone: ZoneId): Instant?

    companion object Default : ExifDateTimeParser {

        /**
         * 書式の形と値の範囲の両方を弾く解釈器。[ResolverStyle.STRICT] で、次を null（例外）にすることをテストで確かめてある。
         * 桁数の違う数字（1 桁の月・2 桁や 5 桁の年）・ASCII 以外の数字・前後や余分な空白・末尾の NUL や文字・
         * 存在しない日（13 月・2 月 30 日・24 時・60 秒）。
         * - `uuuu`（西暦の年）を使う。`yyyy` は「年号の中の年」で、[ResolverStyle.STRICT] では年号が無いと解決に失敗する
         * - 暦は ISO（＝グレゴリオ暦）に固定し、ロケールは [Locale.ROOT] にする（端末が和暦でも年がずれない）
         */
        private val FORMATTER: DateTimeFormatter = DateTimeFormatter
            .ofPattern("uuuu:MM:dd HH:mm:ss", Locale.ROOT)
            .withChronology(IsoChronology.INSTANCE)
            .withResolverStyle(ResolverStyle.STRICT)

        /** iOS の `TimeZone(secondsFromGMT:)` が作れる上限（±18 時間）。java.time の [ZoneOffset] の上限と同じ。 */
        private const val OFFSET_SECONDS_MAX = 18 * 3600

        /**
         * Firestore の `Timestamp` が受け付ける瞬間の下限（0001-01-01T00:00:00Z・含む）。
         * 値の出どころは firebase-common 22.2.1 の `Timestamp.validateRange`（秒が -62135596800 以上・253402300800 未満）。
         * :contract は Firebase に依存しない純粋な JVM なので、範囲は定数で持つ。
         */
        private val TIMESTAMP_MIN: Instant = Instant.ofEpochSecond(-62135596800L)

        /** Firestore の `Timestamp` の上限（10000-01-01T00:00:00Z・**含まない**）。出どころは [TIMESTAMP_MIN] と同じ。 */
        private val TIMESTAMP_MAX_EXCLUSIVE: Instant = Instant.ofEpochSecond(253402300800L)

        /**
         * [instant] が Firestore の `Timestamp` にできる瞬間か（[TIMESTAMP_MIN] 以上・[TIMESTAMP_MAX_EXCLUSIVE] 未満）。
         * 範囲の判定はここ 1 か所に置く：EXIF の解釈（[parse]）と、:app の写真選択画面の撮影日時（`DefaultPhotoMetadataReader`）が同じ判定で見る。
         * 範囲の外の瞬間を投稿の文書に書くと、最後の保存で `Timestamp(instant)` が IllegalArgumentException になり、やり直しても同じ失敗になる。
         */
        fun isWithinTimestampRange(instant: Instant): Boolean = instant >= TIMESTAMP_MIN && instant < TIMESTAMP_MAX_EXCLUSIVE

        override fun parse(dateTimeOriginal: String, offsetTimeOriginal: String?, deviceZone: ZoneId): Instant? {
            val wallClock = try {
                LocalDateTime.parse(dateTimeOriginal, FORMATTER)
            } catch (e: DateTimeParseException) {
                return null
            }
            val zone: ZoneId = offsetTimeOriginal?.let(::offsetOrNull) ?: deviceZone
            val instant = wallClock.atZone(zone).withLaterOffsetAtOverlap().toInstant()
            // Firestore の Timestamp にできない瞬間は、読めない日時と同じく null にする（範囲外のまま返すと、投稿の最後の保存で例外になる）
            if (!isWithinTimestampRange(instant)) return null
            return instant
        }

        /**
         * `"+09:00"`・`"-05:30"` の形のオフセットを読む。iOS の `timeZone(fromEXIFOffset:)`（ImageService.swift:1058-1072）と同じ条件で、
         * 読めなければ null（呼び出し側が端末のタイムゾーンに倒す）。
         * iOS と違い、時・分の桁は ASCII の数字だけを通す（`++1:00` を +01:00 と読まない）。
         */
        private fun offsetOrNull(offset: String): ZoneOffset? {
            if (offset.length != 6) return null
            val sign = when (offset[0]) {
                '+' -> 1
                '-' -> -1
                else -> return null
            }
            if (offset[3] != ':') return null
            val hours = twoAsciiDigits(offset, 1) ?: return null
            val minutes = twoAsciiDigits(offset, 4) ?: return null
            if (hours !in 0..23 || minutes !in 0..59) return null
            val totalSeconds = sign * (hours * 3600 + minutes * 60)
            if (totalSeconds !in -OFFSET_SECONDS_MAX..OFFSET_SECONDS_MAX) return null
            return ZoneOffset.ofTotalSeconds(totalSeconds)
        }

        /** [text] の [start] から 2 文字が ASCII の数字なら、その値。 */
        private fun twoAsciiDigits(text: String, start: Int): Int? {
            val tens = text[start]
            val ones = text[start + 1]
            if (tens !in '0'..'9' || ones !in '0'..'9') return null
            return (tens - '0') * 10 + (ones - '0')
        }
    }
}
