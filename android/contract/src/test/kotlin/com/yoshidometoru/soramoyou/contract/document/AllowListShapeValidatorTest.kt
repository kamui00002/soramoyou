// ⭐️ 許可リスト方式の形の検証（AllowListShapeValidator）の単体テスト（タスク 3.3・要件 3.5・7.12）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.Uid
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 検証器の振る舞いを、テスト用の契約で確かめる。個々のコレクションの本物の契約（POST_CREATE の中身など）は、
 * M2 以降のタスクで足す（このタスクの対象外）。ここで使う [ContractId] は、どれもテスト用に借りた名前である。
 *
 * 陽性対照：検出系のテスト（必須キーの欠落・契約外のキー・値の種類の違い・値の範囲・入れ子）は、
 * 検証器が常に「合格」を返す仮実装では必ず落ちる（先に赤を確かめてから実装した）。
 */
class AllowListShapeValidatorTest {

    private val target = WriteTarget(documentId = "POST-DOC-ID", authUid = Uid("auth-uid-1"))

    // ---- テスト用の契約（実際の投稿の契約の写しではない。検証器の振る舞いを見るための最小限） ----

    /** テスト用: 画像 1 枚の契約（POST_IMAGE を借りている）。 */
    private val imageContract = ShapeContract(
        id = ContractId.POST_IMAGE,
        fields = listOf(
            FieldRule("url", setOf(ValueKind.STR), required = true, basis = Basis.IOS_READER_REQUIRED),
            FieldRule("thumbnail", setOf(ValueKind.STR), required = false, basis = Basis.OPTIONAL),
            FieldRule("width", setOf(ValueKind.INT64), true, Basis.IOS_READER_REQUIRED, ValueConstraint.IntIn(1L..Long.MAX_VALUE)),
            FieldRule("height", setOf(ValueKind.INT64), true, Basis.IOS_READER_REQUIRED, ValueConstraint.IntIn(1L..Long.MAX_VALUE)),
            FieldRule("order", setOf(ValueKind.INT64), true, Basis.IOS_READER_REQUIRED, ValueConstraint.IntIn(0L..Long.MAX_VALUE)),
        ),
    )

    /** テスト用: 投稿の契約（POST_CREATE を借りている）。宣言順が違反の並びの基準になる。 */
    private val postContract = ShapeContract(
        id = ContractId.POST_CREATE,
        fields = listOf(
            FieldRule("postId", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.EqualsDocumentId),
            FieldRule("userId", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.EqualsAuthUid),
            FieldRule("images", setOf(ValueKind.MAP_LIST), true, Basis.RULES_HAS_ALL, ValueConstraint.CountIn(1..10)),
            FieldRule("visibility", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.OneOf(setOf("public", "followers", "private"))),
            FieldRule("likesCount", setOf(ValueKind.INT64), true, Basis.RULES_VALUE, ValueConstraint.IntIn(0L..0L)),
            FieldRule("createdAt", setOf(ValueKind.TIME), true, Basis.RULES_HAS_ALL),
            FieldRule("caption", setOf(ValueKind.STR), false, Basis.OPTIONAL, ValueConstraint.Utf16LengthIn(1..2000)),
            FieldRule("hashtags", setOf(ValueKind.STR_LIST), false, Basis.OPTIONAL, ValueConstraint.CountIn(1..30)),
        ),
        nested = mapOf("images" to imageContract),
    )

    private val requiredPostKeys = listOf("postId", "userId", "images", "visibility", "likesCount", "createdAt")

    private fun validImage(order: Long = 0L, withThumbnail: Boolean = false): Map<String, FsValue> = buildMap {
        put("url", FsValue.Str("https://example.invalid/$order.jpg"))
        if (withThumbnail) put("thumbnail", FsValue.Str("https://example.invalid/$order-thumb.jpg"))
        put("width", FsValue.Int64(1024L))
        put("height", FsValue.Int64(768L))
        put("order", FsValue.Int64(order))
    }

    /** 必須キーだけの、合格する投稿。 */
    private fun minimalPost(): Map<String, FsValue> = linkedMapOf(
        "postId" to FsValue.Str("POST-DOC-ID"),
        "userId" to FsValue.Str("auth-uid-1"),
        "images" to FsValue.MapList(listOf(validImage())),
        "visibility" to FsValue.Str("public"),
        "likesCount" to FsValue.Int64(0L),
        "createdAt" to FsValue.Time(Instant.parse("2026-10-02T00:00:00Z")),
    )

    /** 任意のキーも全て入った、合格する投稿。 */
    private fun fullPost(): Map<String, FsValue> = minimalPost() + mapOf(
        "images" to FsValue.MapList(listOf(validImage(0L, withThumbnail = true), validImage(1L, withThumbnail = true))),
        "caption" to FsValue.Str("夕焼け"),
        "hashtags" to FsValue.StrList(listOf("空", "sunset")),
    )

    private fun validate(doc: FsDocument, contract: ShapeContract = postContract): List<Violation> =
        AllowListShapeValidator.validate(contract, doc, target)

    /** 違反を「種類:キー」の短い文字列にする（detail の細かい文言には依存せずに並びとキーを見るため）。 */
    private fun Violation.sig(): String = when (this) {
        is Violation.MissingKey -> "Missing:$key"
        is Violation.UnexpectedKey -> "Unexpected:$key"
        is Violation.WrongKind -> "WrongKind:$key:$actual"
        is Violation.OutOfRange -> "OutOfRange:$key"
    }

    private fun sigs(doc: FsDocument, contract: ShapeContract = postContract): List<String> =
        validate(doc, contract).map { it.sig() }

    // ---- 合格 ----

    @Test
    fun `必須キーだけの文書は合格して違反が空になる`() {
        assertEquals(emptyList(), validate(minimalPost()))
    }

    @Test
    fun `必須キーと任意のキーが全部入りの文書は合格する`() {
        assertEquals(emptyList(), validate(fullPost()))
    }

    @Test
    fun `任意のキーが無い文書は合格する（キーを入れないことで任意を表す）`() {
        val optionalKeys = listOf("caption", "hashtags")
        optionalKeys.forEach { key ->
            assertEquals(emptyList(), validate(fullPost() - key), "任意の $key が無いだけで違反になった")
        }
        // 入れ子の中の任意のキー（thumbnail）も、無くてよい
        assertEquals(emptyList(), validate(minimalPost()), "thumbnail の無い画像は合格のはず")
    }

    // ---- 必須キーの欠落・契約外のキー・値の種類 ----

    @Test
    fun `必須キーが無いとMissingKeyになる`() {
        requiredPostKeys.forEach { key ->
            assertEquals(
                listOf<Violation>(Violation.MissingKey(key)),
                validate(minimalPost() - key),
                "必須の $key を抜いたときの違反",
            )
        }
    }

    @Test
    fun `契約に無いキーはUnexpectedKeyになる`() {
        // 要件 2.10・7.12・7.17・8.1 で「書かない」と決めたキーの代表
        listOf("fcmToken", "editSettings", "editRecipeV1", "skyType", "externalEditInfo", "originalImages", "updatedAt").forEach { key ->
            assertEquals(
                listOf<Violation>(Violation.UnexpectedKey(key)),
                validate(minimalPost() + (key to FsValue.Str("x"))),
                "契約外の $key を足したときの違反",
            )
        }
    }

    @Test
    fun `値の種類が違うとWrongKindになり実際の種類が付く`() {
        assertEquals(
            listOf<Violation>(Violation.WrongKind("likesCount", ValueKind.STR)),
            validate(minimalPost() + ("likesCount" to FsValue.Str("0"))),
        )
        assertEquals(
            listOf<Violation>(Violation.WrongKind("visibility", ValueKind.BOOL)),
            validate(minimalPost() + ("visibility" to FsValue.Bool(true))),
        )
        assertEquals(
            listOf<Violation>(Violation.WrongKind("createdAt", ValueKind.SERVER_TIME)),
            validate(minimalPost() + ("createdAt" to FsValue.ServerTime)),
            "契約が TIME だけなら、サーバー時刻は違反",
        )
        assertEquals(
            listOf<Violation>(Violation.WrongKind("images", ValueKind.STR_LIST)),
            validate(minimalPost() + ("images" to FsValue.StrList(listOf("a")))),
            "images は MAP_LIST。文字列のリストは違反",
        )
    }

    @Test
    fun `種類が違うときは制約の違反を重ねて出さない`() {
        // caption は Utf16LengthIn(1..2000)。Int64 を入れても OutOfRange は出さず WrongKind だけにする
        assertEquals(
            listOf<Violation>(Violation.WrongKind("caption", ValueKind.INT64)),
            validate(minimalPost() + ("caption" to FsValue.Int64(0L))),
        )
        // postId は EqualsDocumentId。Int64 でも同じ
        assertEquals(
            listOf<Violation>(Violation.WrongKind("postId", ValueKind.INT64)),
            validate(minimalPost() + ("postId" to FsValue.Int64(1L))),
        )
        // hashtags は CountIn。Str を入れても WrongKind だけ
        assertEquals(
            listOf<Violation>(Violation.WrongKind("hashtags", ValueKind.STR)),
            validate(minimalPost() + ("hashtags" to FsValue.Str(""))),
        )
    }

    @Test
    fun `種類が合って範囲だけ外れるとOutOfRangeだけが出る`() {
        val violations = validate(minimalPost() + ("caption" to FsValue.Str("")))
        assertEquals(1, violations.size)
        val violation = violations.single()
        assertTrue(violation is Violation.OutOfRange && violation.key == "caption", "違反: $violation")
    }

    // ---- 値の範囲（検証器を通した結果） ----

    @Test
    fun `キャプションは2000文字までで2001文字からOutOfRangeになる`() {
        assertEquals(emptyList(), validate(minimalPost() + ("caption" to FsValue.Str("a".repeat(2000)))))
        assertEquals(listOf("OutOfRange:caption"), sigs(minimalPost() + ("caption" to FsValue.Str("a".repeat(2001)))))
        // 絵文字は UTF-16 で 2 と数える（1001 個 = 2002）
        assertEquals(listOf("OutOfRange:caption"), sigs(minimalPost() + ("caption" to FsValue.Str("😀".repeat(1001)))))
    }

    @Test
    fun `ハッシュタグは1件から30件まで`() {
        fun tags(n: Int) = FsValue.StrList(List(n) { "t$it" })
        assertEquals(listOf("OutOfRange:hashtags"), sigs(minimalPost() + ("hashtags" to tags(0))), "空の配列は書かない（キーごと省略する）")
        assertEquals(emptyList(), validate(minimalPost() + ("hashtags" to tags(1))))
        assertEquals(emptyList(), validate(minimalPost() + ("hashtags" to tags(30))))
        assertEquals(listOf("OutOfRange:hashtags"), sigs(minimalPost() + ("hashtags" to tags(31))))
    }

    @Test
    fun `postIdがドキュメントIDと違う、userIdが認証ユーザーと違うとOutOfRangeになる`() {
        assertEquals(listOf("OutOfRange:postId"), sigs(minimalPost() + ("postId" to FsValue.Str("OTHER-ID"))))
        assertEquals(listOf("OutOfRange:userId"), sigs(minimalPost() + ("userId" to FsValue.Str("someone-else"))))
    }

    @Test
    fun `列挙値は許可した文字列だけで大文字違いはOutOfRangeになる`() {
        assertEquals(emptyList(), validate(minimalPost() + ("visibility" to FsValue.Str("followers"))))
        assertEquals(listOf("OutOfRange:visibility"), sigs(minimalPost() + ("visibility" to FsValue.Str("Public"))))
    }

    @Test
    fun `制約が想定しないkindが契約のkindsに含まれていて当たったときはOutOfRangeになる`() {
        // 契約の書き間違い（STR の制約を INT64 も許す field に付けた）を、黙って通さない（fail-closed）
        val contract = ShapeContract(
            id = ContractId.USER_CREATE, // テスト用
            fields = listOf(
                FieldRule("v", setOf(ValueKind.STR, ValueKind.INT64), true, Basis.OPTIONAL, ValueConstraint.OneOf(setOf("a"))),
            ),
        )
        assertEquals(emptyList(), validate(mapOf("v" to FsValue.Str("a")), contract))
        assertEquals(listOf("OutOfRange:v"), sigs(mapOf("v" to FsValue.Int64(1L)), contract))
    }

    @Test
    fun `違反の説明に値やIDが含まれない`() {
        val caption = "秘密の本文SECRET-CAPTION" + "x".repeat(2000)
        val details = validate(
            minimalPost() + mapOf(
                "caption" to FsValue.Str(caption),
                "postId" to FsValue.Str("LEAK-POST-ID"),
                "userId" to FsValue.Str("LEAK-USER-ID"),
                "visibility" to FsValue.Str("LEAK-VISIBILITY"),
            ),
        ).filterIsInstance<Violation.OutOfRange>().map { it.detail }
        assertEquals(4, details.size, "4 件の OutOfRange のはず: $details")
        val forbidden = listOf("SECRET-CAPTION", "LEAK-POST-ID", "LEAK-USER-ID", "LEAK-VISIBILITY", target.documentId, target.authUid.value)
        details.forEach { detail ->
            forbidden.forEach { word -> assertFalse(detail.contains(word), "説明に値が混ざった: '$word' in '$detail'") }
        }
    }

    // ---- 加算・DeleteField ----

    /** テスト用: いいねのカウンタ更新（POST_LIKE_COUNTER を借りている）。likesCount の ±1 だけを許す。 */
    private val counterContract = ShapeContract(
        id = ContractId.POST_LIKE_COUNTER,
        fields = listOf(
            FieldRule("likesCount", setOf(ValueKind.INCREMENT), true, Basis.COUNT_ONLY_UPDATE, ValueConstraint.IncrementIn(setOf(1L, -1L))),
        ),
    )

    @Test
    fun `加算は プラス1とマイナス1だけを通し 他のキーは契約外になる`() {
        assertEquals(emptyList(), validate(mapOf("likesCount" to FsValue.Increment(1L)), counterContract))
        assertEquals(emptyList(), validate(mapOf("likesCount" to FsValue.Increment(-1L)), counterContract))
        assertEquals(listOf("OutOfRange:likesCount"), sigs(mapOf("likesCount" to FsValue.Increment(2L)), counterContract))
        assertEquals(listOf("OutOfRange:likesCount"), sigs(mapOf("likesCount" to FsValue.Increment(0L)), counterContract))
        assertEquals(
            listOf("WrongKind:likesCount:INT64"),
            sigs(mapOf("likesCount" to FsValue.Int64(1L)), counterContract),
            "加算の代わりに整数の上書きは違反",
        )
        // 要件 9.5: いいね時の updatedAt は書かない
        assertEquals(
            listOf("Unexpected:updatedAt"),
            sigs(mapOf("likesCount" to FsValue.Increment(1L), "updatedAt" to FsValue.ServerTime), counterContract),
        )
    }

    @Test
    fun `DeleteFieldはkindsにDELETEが無ければWrongKindになる`() {
        assertEquals(
            listOf<Violation>(Violation.WrongKind("caption", ValueKind.DELETE)),
            validate(minimalPost() + ("caption" to FsValue.DeleteField)),
            "DeleteField を特別扱いして通してはいけない",
        )
    }

    @Test
    fun `DeleteFieldはkindsにDELETEがあれば合格する`() {
        // 制約を付けない field（制約が DeleteField を想定しない件は、制約側の想定外の kind の扱い）
        val contract = ShapeContract(
            id = ContractId.USER_PROFILE_UPDATE, // テスト用
            fields = listOf(FieldRule("bio", setOf(ValueKind.STR, ValueKind.DELETE), false, Basis.OPTIONAL)),
        )
        assertEquals(emptyList(), validate(mapOf("bio" to FsValue.DeleteField), contract))
        assertEquals(emptyList(), validate(mapOf("bio" to FsValue.Str("こんにちは")), contract))
    }

    @Test
    fun `DeleteFieldは制約の付いた項目でもkindsにDELETEがあれば制約を見ずに合格し、文字列には制約を当てる`() {
        // 2026-10-05 ユーザー判断（タスク 13.3）：制約は DELETE を対象外にする。「入れるなら 1〜10 文字・消すのは可」を 1 つの項目で書ける
        val contract = ShapeContract(
            id = ContractId.USER_PROFILE_UPDATE, // テスト用
            fields = listOf(
                FieldRule("bio", setOf(ValueKind.STR, ValueKind.DELETE), false, Basis.OPTIONAL, ValueConstraint.Utf16LengthIn(1..10)),
            ),
        )
        assertEquals(emptyList(), validate(mapOf("bio" to FsValue.DeleteField), contract))
        assertEquals(1, validate(mapOf("bio" to FsValue.Str("")), contract).size, "削除でない値には、これまでどおり制約を当てる")
        assertEquals(
            listOf<Violation>(Violation.WrongKind("bio", ValueKind.DELETE)),
            validate(
                mapOf("bio" to FsValue.DeleteField),
                ShapeContract(
                    id = ContractId.USER_PROFILE_UPDATE,
                    fields = listOf(FieldRule("bio", setOf(ValueKind.STR), false, Basis.OPTIONAL, ValueConstraint.Utf16LengthIn(1..10))),
                ),
            ),
            "kinds に DELETE が無ければ、制約より前に種類で違反にする（これまでどおり）",
        )
    }

    // ---- 入れ子（MapList の各要素） ----

    @Test
    fun `入れ子の要素の必須キーの欠落はキーに添字を付けて報告する`() {
        val images = FsValue.MapList(listOf(validImage(0L), validImage(1L) - "width"))
        assertEquals(listOf("Missing:images[1].width"), sigs(minimalPost() + ("images" to images)))
    }

    @Test
    fun `入れ子の要素の契約外のキーはキーに添字を付けて報告する`() {
        val images = FsValue.MapList(listOf(validImage(0L) + ("externalEditInfo" to FsValue.Str("x")), validImage(1L)))
        assertEquals(listOf("Unexpected:images[0].externalEditInfo"), sigs(minimalPost() + ("images" to images)))
    }

    @Test
    fun `入れ子の要素の値の種類の違いはキーに添字を付けて報告する`() {
        // width に文字列（小数は型として持てないため、種類の違いで検出する）
        val images = FsValue.MapList(listOf(validImage(0L), validImage(1L) + ("width" to FsValue.Str("1024"))))
        assertEquals(listOf("WrongKind:images[1].width:STR"), sigs(minimalPost() + ("images" to images)))
    }

    @Test
    fun `入れ子の要素の値の範囲の外れはキーに添字を付けて報告する`() {
        val images = FsValue.MapList(listOf(validImage(0L) + ("width" to FsValue.Int64(0L))))
        assertEquals(listOf("OutOfRange:images[0].width"), sigs(minimalPost() + ("images" to images)))
    }

    @Test
    fun `CountInはMapListの要素数に効く`() {
        fun images(n: Int) = FsValue.MapList(List(n) { validImage(it.toLong()) })
        assertEquals(listOf("OutOfRange:images"), sigs(minimalPost() + ("images" to images(0))))
        assertEquals(emptyList(), validate(minimalPost() + ("images" to images(1))))
        assertEquals(emptyList(), validate(minimalPost() + ("images" to images(10))))
        assertEquals(listOf("OutOfRange:images"), sigs(minimalPost() + ("images" to images(11))))
    }

    @Test
    fun `要素数が範囲外でも各要素の中身の検証は続ける`() {
        val elements = List(11) { validImage(it.toLong()) }.toMutableList()
        elements[3] = elements[3] - "url"
        assertEquals(
            listOf("OutOfRange:images", "Missing:images[3].url"),
            sigs(minimalPost() + ("images" to FsValue.MapList(elements))),
        )
    }

    @Test
    fun `入れ子は2段以上でも再帰して検証し、キーは親から順につながる`() {
        // テスト用の 3 段の契約
        val leaf = ShapeContract(
            id = ContractId.POST_IMAGE, // テスト用
            fields = listOf(FieldRule("n", setOf(ValueKind.INT64), true, Basis.OPTIONAL, ValueConstraint.IntIn(0L..9L))),
        )
        val mid = ShapeContract(
            id = ContractId.POST_IMAGE, // テスト用
            fields = listOf(FieldRule("leaves", setOf(ValueKind.MAP_LIST), true, Basis.OPTIONAL)),
            nested = mapOf("leaves" to leaf),
        )
        val top = ShapeContract(
            id = ContractId.POST_CREATE, // テスト用
            fields = listOf(FieldRule("mids", setOf(ValueKind.MAP_LIST), true, Basis.OPTIONAL)),
            nested = mapOf("mids" to mid),
        )
        val doc = mapOf(
            "mids" to FsValue.MapList(
                listOf(
                    mapOf("leaves" to FsValue.MapList(listOf(mapOf("n" to FsValue.Int64(1L)), mapOf("n" to FsValue.Str("x"))))),
                    mapOf(
                        "leaves" to FsValue.MapList(
                            listOf(
                                emptyMap(),
                                mapOf("n" to FsValue.Int64(10L), "extra" to FsValue.Bool(true)),
                            ),
                        ),
                    ),
                ),
            ),
        )
        assertEquals(
            listOf(
                "WrongKind:mids[0].leaves[1].n:STR",
                "Missing:mids[1].leaves[0].n",
                "OutOfRange:mids[1].leaves[1].n",
                "Unexpected:mids[1].leaves[1].extra",
            ),
            sigs(doc, top),
        )
    }

    // ---- 違反の順序 ----

    @Test
    fun `空の文書は必須キーの欠落を契約の宣言順に全て報告する`() {
        assertEquals(requiredPostKeys.map { "Missing:$it" }, sigs(emptyMap()))
    }

    /** 全種類の違反が混ざった文書。並びの検証に使う。 */
    private fun messyPost(): LinkedHashMap<String, FsValue> {
        val image0 = linkedMapOf<String, FsValue>(
            "url" to FsValue.Str("u0"), "width" to FsValue.Int64(0L), "height" to FsValue.Int64(1L), "order" to FsValue.Int64(0L),
            "zebra" to FsValue.Bool(true), "apple" to FsValue.Bool(true),
        )
        val image1 = linkedMapOf<String, FsValue>(
            "width" to FsValue.Int64(1L), "height" to FsValue.Int64(1L), "order" to FsValue.Int64(1L), "mango" to FsValue.Bool(true),
        )
        return linkedMapOf(
            "zzz" to FsValue.Bool(true),
            "postId" to FsValue.Str("WRONG"),
            // userId は欠落
            "images" to FsValue.MapList(listOf(image0, image1)),
            "visibility" to FsValue.Bool(true),
            "likesCount" to FsValue.Int64(0L),
            "createdAt" to FsValue.Time(Instant.EPOCH),
            "caption" to FsValue.Str(""),
            "fcmToken" to FsValue.Str("x"),
            "aaaKey" to FsValue.Bool(false),
        )
    }

    @Test
    fun `違反は契約の宣言順に並び、契約外のキーは最後にキーの昇順で並ぶ`() {
        assertEquals(
            listOf(
                "OutOfRange:postId", // 宣言順 1 番目
                "Missing:userId", // 2 番目
                // 3 番目の images の枠の中に、要素の違反が入る（要素の契約外のキーは、その要素の最後に昇順で）
                "OutOfRange:images[0].width",
                "Unexpected:images[0].apple",
                "Unexpected:images[0].zebra",
                "Missing:images[1].url",
                "Unexpected:images[1].mango",
                "WrongKind:visibility:BOOL", // 4 番目
                "OutOfRange:caption", // 7 番目
                // 最後に、トップレベルの契約外のキーを昇順で（入れ子の契約外のキーは混ざらない）
                "Unexpected:aaaKey",
                "Unexpected:fcmToken",
                "Unexpected:zzz",
            ),
            sigs(messyPost()),
        )
    }

    @Test
    fun `同じ内容なら文書のキーの並びが違っても違反の並びは同じである`() {
        val forward = messyPost()
        // 外側のキーの並びを逆にし、要素の中のキーの並びも逆にした、同じ内容の文書
        val reversed = LinkedHashMap<String, FsValue>()
        forward.entries.reversed().forEach { (key, value) ->
            reversed[key] = if (value is FsValue.MapList) {
                FsValue.MapList(
                    value.values.map { element ->
                        LinkedHashMap<String, FsValue>().also { copy -> element.entries.reversed().forEach { copy[it.key] = it.value } }
                    },
                )
            } else {
                value
            }
        }
        assertEquals(forward, reversed, "前提: 内容は同じ")
        assertEquals(forward.keys.toList().reversed(), reversed.keys.toList(), "前提: 並びは逆")
        assertTrue(validate(forward).size > 5, "前提: 比べる違反が実際に出ている（空同士の比較にしない）")
        assertEquals(validate(forward), validate(reversed), "並びが違っても違反の一覧は同じ（detail まで）")
        assertEquals(validate(forward), validate(forward), "同じ入力なら毎回同じ")
    }

    // ---- 契約が空 ----

    @Test
    fun `fieldsが空の契約では空の文書だけが合格し他は全て契約外になる`() {
        val empty = ShapeContract(ContractId.FEEDBACK_CREATE, emptyList()) // テスト用
        assertEquals(emptyList(), validate(emptyMap(), empty))
        assertEquals(listOf("Unexpected:a", "Unexpected:b"), sigs(mapOf("b" to FsValue.Bool(true), "a" to FsValue.Bool(true)), empty))
    }
}
