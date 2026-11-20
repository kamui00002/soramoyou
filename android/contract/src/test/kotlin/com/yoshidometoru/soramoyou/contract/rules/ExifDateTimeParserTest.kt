// ⭐️ EXIF の撮影日時の解釈の単体テスト（タスク 20.2・要件 7.14・7.16）
package com.yoshidometoru.soramoyou.contract.rules

import java.net.URLClassLoader
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [ExifDateTimeParser] が、iOS 版の `parseEXIFDateTime`（ImageService.swift:1037-1072）と同じ瞬間を返すことを確かめる。
 *
 * 期待値の作り方：同じ入力を、iOS のコードの写しで Swift 6.4（macOS 27）に流して実測した epoch 秒である（計算し直していない）。
 * 端末のタイムゾーンは `TZ=Asia/Tokyo` と `TZ=America/New_York` の 2 通り。
 * 実測の結果と使ったコード（手元・git の外）：`20.2-exif.swift`・`20.2-exif_tokyo.tsv`・`20.2-exif_ny.tsv`。
 *
 * 例外：Firestore の Timestamp の範囲の端（下限・上限の前後）と、西暦 1 年のユリウス暦との 2 日の差は iOS の実測値でなく計算した値
 * （西暦 1 年のニューヨークは実測 -62135751838 に 2 日を足した）。範囲の外は null にする。
 *
 * iOS が寛容に「別の日時」として通す入力は、Android では null にする（理由は [ExifDateTimeParser] の「iOS との差」）。
 * そのテストには、iOS の実測値をコメントで残してある。
 */
class ExifDateTimeParserTest {

    private val parser: ExifDateTimeParser = ExifDateTimeParser.Default
    private val tokyo: ZoneId = ZoneId.of("Asia/Tokyo")
    private val newYork: ZoneId = ZoneId.of("America/New_York")

    private fun epoch(seconds: Long): Instant = Instant.ofEpochSecond(seconds)

    /** 東京とニューヨークの端末で解釈した結果が、それぞれ iOS の実測値と一致することを確かめる。 */
    private fun assertBoth(value: String, offset: String?, tokyoEpoch: Long, newYorkEpoch: Long) {
        assertEquals(epoch(tokyoEpoch), parser.parse(value, offset, tokyo), "東京の端末: $value / $offset")
        assertEquals(epoch(newYorkEpoch), parser.parse(value, offset, newYork), "ニューヨークの端末: $value / $offset")
    }

    private fun assertNullBoth(value: String, offset: String? = null) {
        assertNull(parser.parse(value, offset, tokyo), "東京の端末: $value / $offset")
        assertNull(parser.parse(value, offset, newYork), "ニューヨークの端末: $value / $offset")
    }

    // ---- オフセット ----

    @Test
    fun `オフセットが無ければ端末のタイムゾーンで解釈する`() {
        assertBoth("2026:10:09 12:34:56", null, 1791516896, 1791563696)
    }

    @Test
    fun `オフセットがあれば端末に関係なくそのオフセットで解釈する`() {
        assertBoth("2026:10:09 12:34:56", "+09:00", 1791516896, 1791516896)
        assertBoth("2026:10:09 12:34:56", "-05:30", 1791569096, 1791569096)
        assertBoth("2026:10:09 12:34:56", "+00:00", 1791549296, 1791549296)
        assertBoth("2026:10:09 12:34:56", "-00:00", 1791549296, 1791549296)
        assertBoth("2026:10:09 12:34:56", "+14:00", 1791498896, 1791498896)
        assertBoth("2026:10:09 12:34:56", "+18:00", 1791484496, 1791484496)   // iOS が作れる上限
    }

    @Test
    fun `読めないオフセットは端末のタイムゾーンに倒す`() {
        val unreadable = listOf(
            "+19:00",        // ±18 時間を超える（iOS の TimeZone(secondsFromGMT:) が nil）
            "+23:59",
            "+24:00",        // 時が 0〜23 の外
            "+09:60",        // 分が 0〜59 の外
            "JST",
            "+0900",         // コロンが無い
            "",
            "   ",
            "+-1:00",
            "+０９:００",     // 全角数字
            "Z",
            "+09:00" + Char(0), // 末尾の NUL で 7 文字
        )
        for (offset in unreadable) {
            assertBoth("2026:10:09 12:34:56", offset, 1791516896, 1791563696)
        }
    }

    // ---- 夏時間 ----

    @Test
    fun `夏時間で同じ時刻が2回あるときは遅い方のオフセット（標準時）で解釈する`() {
        // ニューヨーク 2026-11-01 01:30 は EDT と EST の 2 回ある。iOS は EST（06:30Z）。java.time の既定は EDT（05:30Z）
        assertBoth("2026:11:01 01:30:00", null, 1793464200, 1793514600)
    }

    @Test
    fun `夏時間で存在しない時刻は1時間進めた時刻と同じ瞬間になる`() {
        // ニューヨーク 2026-03-08 02:30 は存在しない。iOS も java.time も 07:30Z
        assertBoth("2026:03:08 02:30:00", null, 1772904600, 1772955000)
    }

    // ---- 日付 ----

    @Test
    fun `閏年の2月29日と、年の端を解釈する`() {
        assertBoth("2024:02:29 12:00:00", null, 1709175600, 1709226000)
        assertBoth("1900:01:01 00:00:00", null, -2209021200, -2208970800)
    }

    @Test
    fun `9999年末は東京の端末では範囲の中なので解釈する`() {
        // iOS の実測値（東京 253402268399）。ニューヨークは上限以上になるので別のテストで null を確かめる
        assertEquals(epoch(253402268399), parser.parse("9999:12:31 23:59:59", null, tokyo))
    }

    @Test
    fun `西暦1年はiOSと2日ずれる（意図した差）`() {
        // iOS のグレゴリオ暦は 1582 年より前をユリウス暦で数えるので、2 日早い瞬間になる（ニューヨーク -62135751838）。
        // java.time は先発グレゴリオ暦。1582 年より前の写真は存在しないので揃えない。
        // 東京の端末は古い時差（+9:18:59）で下限を下回って null になる（別のテスト）ので、ここでは範囲の中に収まるニューヨークで見る
        assertEquals(epoch(-62135751838 + 2 * 86400), parser.parse("0001:01:01 00:00:00", null, newYork))
    }

    // ---- Firestore の Timestamp の範囲（0001-01-01T00:00:00Z 以上・10000-01-01T00:00:00Z 未満）----

    @Test
    fun `西暦1年は東京の端末では下限の外なのでnullにする`() {
        // 東京の古い時差（LMT +9:18:59）で解釈すると -62135803139（iOS の実測）より 2 日遅い -62135630339 で、下限 -62135596800 より小さい
        assertNull(parser.parse("0001:01:01 00:00:00", null, tokyo))
    }

    @Test
    fun `9999年末はニューヨークの端末では上限以上なのでnullにする`() {
        // iOS は 253402318799 を返す（実測）が、上限 253402300800 以上で Timestamp にできない
        assertNull(parser.parse("9999:12:31 23:59:59", null, newYork))
    }

    @Test
    fun `西暦0年はnullにする`() {
        // uuuu は STRICT でも 0 年を読むが、下限（西暦 1 年 1 月 1 日）より前
        assertNullBoth("0000:01:01 00:00:00")
        assertNullBoth("0000:01:01 00:00:00", "+00:00")
    }

    @Test
    fun `下限ちょうどの瞬間は値を返す`() {
        assertBoth("0001:01:01 00:00:00", "+00:00", -62135596800, -62135596800)
    }

    @Test
    fun `下限の1秒前はnullにする`() {
        assertNullBoth("0000:12:31 23:59:59", "+00:00")
    }

    @Test
    fun `上限の1秒前の瞬間は値を返す`() {
        assertBoth("9999:12:31 23:59:59", "+00:00", 253402300799, 253402300799)
    }

    @Test
    fun `上限ちょうどの瞬間はnullにする（上限は含まない）`() {
        // 9999-12-31T23:59:00 が -00:01 なら 10000-01-01T00:00:00Z ちょうど（253402300800。Python の datetime で計算した）
        assertNullBoth("9999:12:31 23:59:00", "-00:01")
    }

    @Test
    fun `上限を超える瞬間はnullにする`() {
        // 9999-12-31T23:59:59 が -00:01 なら 10000-01-01T00:00:59Z（253402300859）
        assertNullBoth("9999:12:31 23:59:59", "-00:01")
    }

    @Test
    fun `Timestampの範囲の判定は下限を含み上限を含まない`() {
        // :app の写真選択画面の撮影日時（DefaultPhotoMetadataReader）も、この判定で範囲の外を「無い」とみなす。端はナノ秒の単位で見る
        val min = epoch(-62135596800)
        val maxExclusive = epoch(253402300800)
        assertTrue(ExifDateTimeParser.isWithinTimestampRange(min), "下限ちょうど")
        assertFalse(ExifDateTimeParser.isWithinTimestampRange(min.minusNanos(1)), "下限の1ナノ秒前")
        assertTrue(ExifDateTimeParser.isWithinTimestampRange(maxExclusive.minusNanos(1)), "上限の1ナノ秒前")
        assertFalse(ExifDateTimeParser.isWithinTimestampRange(maxExclusive), "上限ちょうど")
    }

    @Test
    fun `解釈器を読み込む前から端末のロケールが和暦やタイ仏暦でも年がずれない`() {
        // 本物の端末は、アプリが解釈器を読み込む（FORMATTER を作る）前から既定のロケールが和暦・タイ仏暦になっている。
        // このクラスの parser（ExifDateTimeParser.Default）はもう読み込み済みで、後から Locale.setDefault しても FORMATTER に届かないので、
        // 既定のロケールを変えた後に、別のクラスローダーで解釈器を読み込み直して確かめる。
        // 和暦は uuuu（先発の年）では年がずれないので、暦をロケールに頼る FORMATTER で赤になるのはタイ仏暦の回（和暦はずれない例として残す）
        for (tag in listOf("ja-JP-u-ca-japanese", "th-TH-u-ca-buddhist")) {
            val locale = Locale.forLanguageTag(tag)
            assertEquals(epoch(1791516896), parseLoadedUnder(locale, "2026:10:09 12:34:56", tokyo), "既定のロケール $tag・東京の端末")
            assertEquals(epoch(1791563696), parseLoadedUnder(locale, "2026:10:09 12:34:56", newYork), "既定のロケール $tag・ニューヨークの端末")
        }
    }

    /**
     * 既定のロケールを [locale] にしてから [ExifDateTimeParser] を別のクラスローダーで初めて読み込み（＝FORMATTER をそこで作り）、
     * その解釈器で [value] をオフセット無し・[zone] の端末として解釈する。既定のロケールは最後に戻す。
     * 親は platform のクラスローダーにして、:contract のクラスをこのテストの JVM の読み込み済みのものに任せない。
     */
    private fun parseLoadedUnder(locale: Locale, value: String, zone: ZoneId): Instant? {
        val original = Locale.getDefault()
        Locale.setDefault(locale)
        try {
            val urls = arrayOf(
                ExifDateTimeParser::class.java.protectionDomain.codeSource.location, // :contract の本体のクラス
                Unit::class.java.protectionDomain.codeSource.location, // Kotlin の標準ライブラリ
            )
            URLClassLoader(urls, ClassLoader.getPlatformClassLoader()).use { loader ->
                // 初期化（FORMATTER を作る）は、既定のロケールを変えた後のここで起きる
                val type = Class.forName(ExifDateTimeParser::class.java.name, true, loader)
                // 読み込み済みのクラスが返ってきたら、確かめたいこと（後から作った FORMATTER）を見ていない
                assertNotSame(ExifDateTimeParser::class.java, type, "解釈器を読み込み直せていない")
                val default = type.getField("Default").get(null)
                val parse = default.javaClass.getMethod("parse", String::class.java, String::class.java, ZoneId::class.java)
                return parse.invoke(default, value, null, zone) as Instant?
            }
        } finally {
            Locale.setDefault(original)
        }
    }

    // ---- iOS も null にする入力 ----

    @Test
    fun `書式の外はiOSと同じくnullにする`() {
        assertNullBoth("2026-10-09 12:34:56")
        assertNullBoth("0000:00:00 00:00:00")
        assertNullBoth("                   ")
        assertNullBoth("")
        assertNullBoth("2026:13:01 12:00:00")
        assertNullBoth("2026:10:09 12:34:60")
        assertNullBoth("2026:10:09 12:34:56" + Char(0))
        assertNullBoth("2026:10:09 12:34:56abc")
        assertNullBoth("2026:10:09 12:34:56.123")
        assertNullBoth("2026:10:09 12:34")
        assertNullBoth("2026:10:09T12:34:56")
    }

    // ---- iOS が別の日時として通す入力（意図して null にする） ----

    @Test
    fun `存在しない日付は繰り上げずにnullにする`() {
        assertNullBoth("2026:02:30 12:00:00")   // iOS は 3 月 2 日（東京 1772420400）
        assertNullBoth("2026:02:29 12:00:00")   // iOS は 3 月 1 日（東京 1772334000）
        assertNullBoth("2026:10:09 24:00:00")   // iOS は翌日の 0 時（東京 1791558000）
    }

    @Test
    fun `桁数の違う数字はnullにする`() {
        assertNullBoth("2026:1:9 12:34:56")      // iOS は通す（東京 1767929696）
        assertNullBoth("2026:10:09 1:02:03")     // iOS は通す（東京 1791475323）
        assertNullBoth("26:10:09 12:34:56")      // iOS は西暦 26 年（東京 -61322561043）
        assertNullBoth("20260:10:09 12:34:56")   // iOS は西暦 20260 年（東京 577201001696）
    }

    @Test
    fun `ASCII以外の数字と余分な空白はnullにする`() {
        assertNullBoth("２０２６:10:09 12:34:56")                              // iOS は通す（東京 1791516896）
        val arabicYear = intArrayOf(0x0662, 0x0660, 0x0662, 0x0666).joinToString("") { String(Character.toChars(it)) }
        assertNullBoth("$arabicYear:10:09 12:34:56")                          // アラビア・インド数字の 2026。iOS は通す
        assertNullBoth(" 2026:10:09 12:34:56")                               // iOS は通す
        assertNullBoth("2026:10:09 12:34:56 ")                               // iOS は通す
        assertNullBoth("2026:10:09  12:34:56")                               // iOS は通す
    }

    @Test
    fun `オフセットの時の桁に符号があれば読まない`() {
        // iOS は Int("+1") を 1 と読み、+01:00 で解釈する（東京・ニューヨークとも 1791545696）
        assertBoth("2026:10:09 12:34:56", "++1:00", 1791516896, 1791563696)
    }
}
