// ⭐️ 値の範囲の制約（ValueConstraint）の単体テスト（タスク 3.3・要件 7.12・7.13）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.rules.StorageDownloadUrl
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * 各制約の「合格する値」と「外れる値」を、範囲の端と端の外で固定する。
 * 制約は [ValueConstraint.check] で直接呼ぶ（null なら範囲内、文字列なら「何が範囲外か」）。
 * 検証器を通した結果（OutOfRange になること）は AllowListShapeValidatorTest 側で確かめる。
 */
class ValueConstraintTest {

    private val target = WriteTarget(documentId = "POST-DOC-ID", authUid = Uid("auth-uid-1"))
    private val root: FsDocument = emptyMap()

    private fun ValueConstraint.violation(value: FsValue): String? = check(value, target, root)

    // ---- Utf16LengthIn ----

    @Test
    fun `Utf16LengthIn は範囲の端と端の外で判定する`() {
        val c = ValueConstraint.Utf16LengthIn(1..2000)
        assertNotNull(c.violation(FsValue.Str("")), "空文字は 1..2000 の外")
        assertNull(c.violation(FsValue.Str("a")), "下端 1 は範囲内")
        assertNull(c.violation(FsValue.Str("a".repeat(1999))), "上端 -1 は範囲内")
        assertNull(c.violation(FsValue.Str("a".repeat(2000))), "上端 2000 は範囲内")
        assertNotNull(c.violation(FsValue.Str("a".repeat(2001))), "上端 +1 は範囲外")
    }

    @Test
    fun `Utf16LengthIn は 0 を含む範囲では空文字を許す`() {
        val c = ValueConstraint.Utf16LengthIn(0..3)
        assertNull(c.violation(FsValue.Str("")))
        assertNull(c.violation(FsValue.Str("abc")))
        assertNotNull(c.violation(FsValue.Str("abcd")))
    }

    @Test
    fun `絵文字1個はUTF16で2と数える`() {
        // rules の size() に対して緩くならないよう、コードポイント数ではなく UTF-16 の長さで数える（設計書 :619）
        val emoji = "😀"
        assertEquals(2, emoji.length, "前提: 😀 は UTF-16 で 2 コード単位")
        assertEquals(1, emoji.codePointCount(0, emoji.length), "前提: コードポイントでは 1")
        assertNotNull(ValueConstraint.Utf16LengthIn(1..1).violation(FsValue.Str(emoji)), "1..1 は絵文字 1 個でも外")
        assertNull(ValueConstraint.Utf16LengthIn(1..2).violation(FsValue.Str(emoji)))
        assertNull(ValueConstraint.Utf16LengthIn(2..2).violation(FsValue.Str(emoji)))
    }

    @Test
    fun `絵文字だけの文字列は上限をUTF16の長さで超える`() {
        val c = ValueConstraint.Utf16LengthIn(1..2000)
        assertNull(c.violation(FsValue.Str("😀".repeat(1000))), "1000 個 = 2000 で上端")
        assertNotNull(c.violation(FsValue.Str("😀".repeat(1001))), "1001 個 = 2002 で範囲外")
    }

    @Test
    fun `日本語のBMP文字は1文字を1と数える`() {
        val c = ValueConstraint.Utf16LengthIn(1..3)
        assertNull(c.violation(FsValue.Str("空もよ")), "3 文字は上端")
        assertNotNull(c.violation(FsValue.Str("空もよう")), "4 文字は範囲外")
    }

    @Test
    fun `Utf16LengthInの違反の説明には長さと範囲の数字が入る`() {
        val detail = ValueConstraint.Utf16LengthIn(1..2000).violation(FsValue.Str("a".repeat(2001)))
        assertEquals("length 2001 not in 1..2000", detail)
    }

    // ---- CountIn ----

    @Test
    fun `CountIn は4種類のリストの要素数を範囲の端と端の外で判定する`() {
        val c = ValueConstraint.CountIn(1..10)
        fun strs(n: Int) = List(n) { "t$it" }
        fun maps(n: Int) = List(n) { mapOf("k" to FsValue.Str("v")) }
        val builders: Map<String, (Int) -> FsValue> = mapOf(
            "StrList" to { n -> FsValue.StrList(strs(n)) },
            "MapList" to { n -> FsValue.MapList(maps(n)) },
            "ArrayUnion" to { n -> FsValue.ArrayUnion(strs(n)) },
            "ArrayRemove" to { n -> FsValue.ArrayRemove(strs(n)) },
        )
        builders.forEach { (name, build) ->
            assertNotNull(c.violation(build(0)), "$name 0 件は範囲外")
            assertNull(c.violation(build(1)), "$name 1 件は範囲内（下端）")
            assertNull(c.violation(build(10)), "$name 10 件は範囲内（上端）")
            assertNotNull(c.violation(build(11)), "$name 11 件は範囲外")
        }
    }

    @Test
    fun `CountInの違反の説明には件数と範囲の数字が入る`() {
        assertEquals("count 31 not in 1..30", ValueConstraint.CountIn(1..30).violation(FsValue.StrList(List(31) { "t$it" })))
    }

    // ---- IntIn ----

    @Test
    fun `IntIn は0固定の範囲を判定する`() {
        val c = ValueConstraint.IntIn(0L..0L)
        assertNull(c.violation(FsValue.Int64(0L)))
        assertNotNull(c.violation(FsValue.Int64(1L)))
        assertNotNull(c.violation(FsValue.Int64(-1L)))
    }

    @Test
    fun `IntIn は正の整数の範囲を判定する`() {
        val c = ValueConstraint.IntIn(1L..Long.MAX_VALUE)
        assertNotNull(c.violation(FsValue.Int64(0L)))
        assertNull(c.violation(FsValue.Int64(1L)))
        assertNull(c.violation(FsValue.Int64(Long.MAX_VALUE)))
        assertNotNull(c.violation(FsValue.Int64(Long.MIN_VALUE)))
    }

    // ---- BoolIs ----

    @Test
    fun `BoolIs は期待した真偽値だけを通す`() {
        // 通知設定の既定値（true／true／false）を契約で固定するための制約（タスク 13.2・要件 3.2）
        assertNull(ValueConstraint.BoolIs(true).violation(FsValue.Bool(true)))
        assertNotNull(ValueConstraint.BoolIs(true).violation(FsValue.Bool(false)))
        assertNull(ValueConstraint.BoolIs(false).violation(FsValue.Bool(false)))
        assertNotNull(ValueConstraint.BoolIs(false).violation(FsValue.Bool(true)))
    }

    @Test
    fun `BoolIs の説明は期待する真偽値を含み実際の値は含まない`() {
        // 期待値は契約の定数なので入れてよい。入力の値は入れない（他の制約と同じ規約）
        assertEquals("value is not the expected boolean true", ValueConstraint.BoolIs(true).violation(FsValue.Bool(false)))
        assertEquals("value is not the expected boolean false", ValueConstraint.BoolIs(false).violation(FsValue.Bool(true)))
    }

    // ---- IncrementIn ----

    @Test
    fun `IncrementIn は プラス1とマイナス1だけを許す`() {
        val c = ValueConstraint.IncrementIn(setOf(1L, -1L))
        assertNull(c.violation(FsValue.Increment(1L)))
        assertNull(c.violation(FsValue.Increment(-1L)))
        assertNotNull(c.violation(FsValue.Increment(2L)))
        assertNotNull(c.violation(FsValue.Increment(0L)))
        assertNotNull(c.violation(FsValue.Increment(-2L)))
        assertNotNull(c.violation(FsValue.Increment(Long.MAX_VALUE)))
    }

    // ---- OneOf ----

    @Test
    fun `OneOf は許した文字列と完全に一致するものだけを通す`() {
        val c = ValueConstraint.OneOf(setOf("public", "followers", "private"))
        assertNull(c.violation(FsValue.Str("public")))
        assertNull(c.violation(FsValue.Str("followers")))
        assertNull(c.violation(FsValue.Str("private")))
        assertNotNull(c.violation(FsValue.Str("Public")), "大文字違いは別の値")
        assertNotNull(c.violation(FsValue.Str("PUBLIC")))
        assertNotNull(c.violation(FsValue.Str("public ")), "前後の空白は除かない")
        assertNotNull(c.violation(FsValue.Str("")))
        assertNotNull(c.violation(FsValue.Str("unknown")))
        assertNotNull(c.violation(FsValue.Str("公開")), "表示名は raw ではない")
    }

    // ---- EqualsDocumentId / EqualsAuthUid ----

    @Test
    fun `EqualsDocumentId は書き込み先のドキュメントIDとの一致だけを通す`() {
        assertNull(ValueConstraint.EqualsDocumentId.violation(FsValue.Str("POST-DOC-ID")))
        assertNotNull(ValueConstraint.EqualsDocumentId.violation(FsValue.Str("OTHER")))
        assertNotNull(ValueConstraint.EqualsDocumentId.violation(FsValue.Str("post-doc-id")), "大文字小文字は区別する")
        assertNotNull(ValueConstraint.EqualsDocumentId.violation(FsValue.Str("")))
        assertNotNull(ValueConstraint.EqualsDocumentId.violation(FsValue.Str("auth-uid-1")), "uid はドキュメント ID ではない")
    }

    @Test
    fun `EqualsAuthUid は認証済みユーザーのuidとの一致だけを通す`() {
        assertNull(ValueConstraint.EqualsAuthUid.violation(FsValue.Str("auth-uid-1")))
        assertNotNull(ValueConstraint.EqualsAuthUid.violation(FsValue.Str("someone-else")), "他人の uid での書き込みを止める")
        assertNotNull(ValueConstraint.EqualsAuthUid.violation(FsValue.Str("AUTH-UID-1")))
        assertNotNull(ValueConstraint.EqualsAuthUid.violation(FsValue.Str("")))
        assertNotNull(ValueConstraint.EqualsAuthUid.violation(FsValue.Str("POST-DOC-ID")), "ドキュメント ID は uid ではない")
    }

    // ---- MatchesAnyPattern（画像の URL の形：レビュー R14） ----

    /** 契約の画像の URL と同じ形（本番とエミュレータの Storage のダウンロード URL）。 */
    private val imageUrl = ValueConstraint.MatchesAnyPattern(
        listOf(StorageDownloadUrl.PRODUCTION_PATTERN, StorageDownloadUrl.EMULATOR_PATTERN),
    )
    private val prodBase = "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/"
    private val emuBase = "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/"

    /** Storage の名前（パスの `/` は `%2F` に符号化される）。 */
    private val name = "posts%2FUID-1%2Fpublic%2FIMG-0.jpg"

    @Test
    fun `MatchesAnyPattern は本番とエミュレータのStorageのダウンロードURLの形を通す`() {
        listOf(
            "$prodBase$name?alt=media&token=abc-123",
            "$prodBase$name",
            "https://firebasestorage.googleapis.com:443/v0/b/soramoyou-ios.firebasestorage.app/o/$name?alt=media&token=abc-123",
            "$prodBase$name?", // クエリは空でもよい（rules と同じ）
            "$emuBase$name?alt=media&token=abc-123",
            "$emuBase$name",
        ).forEach { assertNull(imageUrl.violation(FsValue.Str(it)), it) }
    }

    @Test
    fun `MatchesAnyPattern はStorageのダウンロードURLでない文字列を外す`() {
        listOf(
            "" to "空文字",
            "https://example.com/a.jpg" to "別のホスト",
            "http://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "http の本番のホスト",
            "https://firebasestorage.googleapis.com:8443/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "別のポート",
            "https://firebasestorageXgoogleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "[.] は . だけを通す",
            "https://firebasestorage.googleapis.com/v0/b/other-bucket.firebasestorage.app/o/$name" to "別のバケット",
            "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.appspot.com/o/$name" to "appspot.com のバケット",
            "${prodBase}posts/UID-1/IMG-0.jpg" to "名前に / がある",
            prodBase to "名前が空",
            "$prodBase$name?alt=media&token=a b" to "クエリに空白",
            " $prodBase$name" to "前に余計な文字（一部の一致では通さない）",
            "$prodBase$name#frag" to "後ろに余計な文字",
            "https://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/$name" to "https のエミュレータ",
            "http://127.0.0.1:9199/v0/b/demo-soramoyou.appspot.com/o/$name" to "別の住所のエミュレータ",
            "http://10.0.2.2:9199/v0/b/soramoyou-ios.firebasestorage.app/o/$name" to "エミュレータの住所に本番のバケット",
        ).forEach { (value, why) -> assertNotNull(imageUrl.violation(FsValue.Str(value)), why) }
    }

    @Test
    fun `MatchesAnyPattern は形が空なら作れない`() {
        assertFailsWith<IllegalArgumentException> { ValueConstraint.MatchesAnyPattern(emptyList()) }
    }

    // ---- 想定外の kind（fail-closed） ----

    @Test
    fun `制約が想定していないkindの値は黙って通さず違反にする`() {
        val cases: List<Pair<ValueConstraint, FsValue>> = listOf(
            ValueConstraint.OneOf(setOf("a")) to FsValue.Int64(1L),
            ValueConstraint.Utf16LengthIn(0..10) to FsValue.StrList(emptyList()),
            ValueConstraint.IntIn(0L..10L) to FsValue.Str("1"),
            ValueConstraint.CountIn(0..10) to FsValue.Str("abc"),
            ValueConstraint.IncrementIn(setOf(1L)) to FsValue.Int64(1L),
            ValueConstraint.EqualsDocumentId to FsValue.Int64(1L),
            ValueConstraint.EqualsAuthUid to FsValue.Bool(true),
            ValueConstraint.BoolIs(true) to FsValue.Str("true"),
            ValueConstraint.DocumentIdIsAuthUidAndValue to FsValue.Int64(1L),
            ValueConstraint.StoragePathUnder("posts", ".jpg") to FsValue.Int64(1L),
            ValueConstraint.NonBlankUtf16LengthAtMost(10) to FsValue.StrList(emptyList()),
            ValueConstraint.MatchesAnyPattern(listOf("a")) to FsValue.Int64(1L),
        )
        // 制約の種類を足したら、ここにも並べる。並べ忘れを、sealed の種類の一覧（JVM の PermittedSubclasses）との突き合わせで止める
        assertEquals(
            ValueConstraint::class.java.permittedSubclasses.orEmpty().map { it.name }.toSortedSet(),
            cases.map { it.first::class.java.name }.toSortedSet(),
            "fail-closed の検査に並べていない制約がある",
        )
        cases.forEach { (constraint, value) ->
            assertNotNull(constraint.violation(value), "想定外の kind を通した: $constraint に ${value.kind}")
        }
    }

    @Test
    fun `想定外のkindの説明にはkind名だけが入り値は入らない`() {
        val detail = ValueConstraint.OneOf(setOf("a")).violation(FsValue.Int64(987654321L))
        assertNotNull(detail)
        assertTrue(detail.contains("INT64"), detail)
        assertFalse(detail.contains("987654321"), detail)
    }

    // ---- 違反の説明に値そのものを入れない ----

    @Test
    fun `違反の説明に値そのものやIDが含まれない`() {
        val caption = "秘密の本文SECRET-CAPTION"
        val leakProbe = "LEAK-PROBE-VALUE"
        val details = listOf(
            // 利用者の文章（キャプション）：長すぎて外れる
            ValueConstraint.Utf16LengthIn(1..3).violation(FsValue.Str(caption)) to listOf(caption, "SECRET-CAPTION"),
            // 列挙値：許可に無い文字列
            ValueConstraint.OneOf(setOf("public", "private")).violation(FsValue.Str(leakProbe)) to listOf(leakProbe),
            // ドキュメント ID との不一致：実際の値と期待する ID のどちらも出さない
            ValueConstraint.EqualsDocumentId.violation(FsValue.Str(leakProbe)) to listOf(leakProbe, target.documentId),
            // uid との不一致：実際の値と期待する uid のどちらも出さない
            ValueConstraint.EqualsAuthUid.violation(FsValue.Str(leakProbe)) to listOf(leakProbe, target.authUid.value),
            // 整数・加算の値
            ValueConstraint.IntIn(0L..0L).violation(FsValue.Int64(987654321L)) to listOf("987654321"),
            ValueConstraint.IncrementIn(setOf(1L, -1L)).violation(FsValue.Increment(987654321L)) to listOf("987654321"),
            // 画像の URL：パスの uid とクエリのダウンロードの token を出さない
            imageUrl.violation(FsValue.Str("https://example.com/o/LEAK-UID%2Fx.jpg?token=LEAK-TOKEN-1")) to
                listOf("LEAK-UID", "LEAK-TOKEN-1", "example.com"),
        )
        details.forEach { (detail, forbidden) ->
            assertNotNull(detail, "違反になるはずの値が通った")
            forbidden.forEach { word -> assertFalse(detail.contains(word), "説明に値が混ざった: '$word' in '$detail'") }
        }
    }
}
