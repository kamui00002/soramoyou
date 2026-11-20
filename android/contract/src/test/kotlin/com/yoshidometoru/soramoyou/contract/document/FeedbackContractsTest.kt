// ⭐️ フィードバックの書き込みの契約（FEEDBACK_CREATE）と組み立ての単体テスト（タスク 28・要件 13.2〜13.4）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.cps
import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * フィードバックは「自分の uid・本文・サーバー時刻の作成日時」の 3 項目に、値があるときだけ種別・アプリのバージョン・端末情報を
 * 足した文書を、ドキュメント ID＝UUID で `feedback` に作る（firestore.rules:383-397、Feedback.swift:60-86、FeedbackViewModel.swift:38-51）。
 * メールアドレスと表示名は付けない（要件 13.4）。
 *
 * 本文の判定は、rules（`message.size()`＝UTF-16 の単位で 1〜1000）に、空白だけの禁止（iOS の `trimmingCharacters(in: .whitespacesAndNewlines)`
 * と同じ集合。全角空白を含む）を足したもの。
 *
 * 陽性対照（先に赤を確かめたもの）：メールアドレスや表示名などの契約外のキーを含むフィードバックが違反になること、
 * 空白だけ（全角空白・ゼロ幅スペースを含む）の本文、UTF-16 で 1001 の本文（書記素では 501 の絵文字）が違反になること。
 */
class FeedbackContractsTest {

    private val uid = Uid("USER-UID-1")
    private val feedbackId = "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"
    private val appVersion = "1.0.0 (7)"
    private val deviceInfo = "Android 16 / Pixel 9"

    /** フィードバックの書き込み先。ドキュメント ID は UUID だが、契約は ID を縛らない。 */
    private val target = WriteTarget(documentId = feedbackId, authUid = uid)

    private fun validate(doc: FsDocument): List<Violation> =
        AllowListShapeValidator.validate(ShapeContracts.FEEDBACK_CREATE, doc, target)

    private val minimal: FsDocument = mapOf(
        "userId" to FsValue.Str(uid.value),
        "message" to FsValue.Str("使いやすいです"),
        "createdAt" to FsValue.ServerTime,
    )

    private fun withMessage(message: String): FsDocument = minimal + ("message" to FsValue.Str(message))

    @Test
    fun `契約のIDは正しい`() {
        assertEquals(ContractId.FEEDBACK_CREATE, ShapeContracts.FEEDBACK_CREATE.id)
    }

    // ---- 組み立て（DocumentBuilders.feedbackCreate） ----

    @Test
    fun `種別とバージョンと端末情報が全てあるフィードバックは6項目で組み立てる`() {
        val doc = DocumentBuilders.feedbackCreate(
            FeedbackInput(uid, "使いやすいです", FeedbackCategory.REQUEST, appVersion, deviceInfo),
        )
        assertEquals(
            mapOf(
                "userId" to FsValue.Str("USER-UID-1"),
                "message" to FsValue.Str("使いやすいです"),
                "createdAt" to FsValue.ServerTime,
                "category" to FsValue.Str("request"),
                "appVersion" to FsValue.Str(appVersion),
                "deviceInfo" to FsValue.Str(deviceInfo),
            ),
            doc,
        )
        assertEquals(emptyList(), validate(doc))
    }

    @Test
    fun `値の無い任意の項目はキーごと省略し、3項目だけになる`() {
        val doc = DocumentBuilders.feedbackCreate(FeedbackInput(uid, "使いやすいです", null, null, null))
        assertEquals(minimal, doc)
        assertEquals(setOf("userId", "message", "createdAt"), doc.keys)
        assertEquals(emptyList(), validate(doc))
    }

    @Test
    fun `任意の項目は1つずつでも書ける`() {
        val categoryOnly = DocumentBuilders.feedbackCreate(FeedbackInput(uid, "a", FeedbackCategory.BUG, null, null))
        assertEquals(setOf("userId", "message", "createdAt", "category"), categoryOnly.keys)
        val versionOnly = DocumentBuilders.feedbackCreate(FeedbackInput(uid, "a", null, appVersion, null))
        assertEquals(setOf("userId", "message", "createdAt", "appVersion"), versionOnly.keys)
        val deviceOnly = DocumentBuilders.feedbackCreate(FeedbackInput(uid, "a", null, null, deviceInfo))
        assertEquals(setOf("userId", "message", "createdAt", "deviceInfo"), deviceOnly.keys)
        listOf(categoryOnly, versionOnly, deviceOnly).forEach { assertEquals(emptyList(), validate(it)) }
    }

    @Test
    fun `空文字のバージョンと端末情報は値が無いものとして省略する`() {
        // 要件 13.2「値があるときだけ書き込む」。空文字は値ではない
        val doc = DocumentBuilders.feedbackCreate(FeedbackInput(uid, "a", null, "", ""))
        assertEquals(setOf("userId", "message", "createdAt"), doc.keys)
        assertEquals(emptyList(), validate(doc))
    }

    @Test
    fun `3種の種別はどれも組み立てたフィードバックが契約に合格し、種別はrawで書かれる`() {
        FeedbackCategory.entries.forEach { category ->
            val doc = DocumentBuilders.feedbackCreate(FeedbackInput(uid, "a", category, null, null))
            assertEquals(FsValue.Str(category.raw), doc["category"], category.name)
            assertEquals(emptyList(), validate(doc), category.name)
        }
    }

    @Test
    fun `組み立てたフィードバックはメールアドレスも表示名も出さない`() {
        val doc = DocumentBuilders.feedbackCreate(
            FeedbackInput(uid, "a", FeedbackCategory.OTHER, appVersion, deviceInfo),
        )
        // 要件 13.4。入力の型に持たせていないので、組み立てから出ることは無い
        listOf("email", "displayName", "photoURL", "username").forEach { key ->
            assertNull(doc[key], key)
        }
    }

    @Test
    fun `組み立ては本文を直さずそのまま出す（空白を取り除くのは呼び出し側）`() {
        // 前後の空白を取り除くのは入力の段階（TextLimits.trimWhitespace）。組み立ては黙って直さない（NewPost.caption と同じ方針）
        val padded = cps(0x3000, 0x20) + "本文" + cps(0x0A)
        val doc = DocumentBuilders.feedbackCreate(FeedbackInput(uid, padded, null, null, null))
        assertEquals(FsValue.Str(padded), doc["message"])
    }

    @Test
    fun `組み立ては空白だけの本文を直さず、契約が止める`() {
        val doc = DocumentBuilders.feedbackCreate(FeedbackInput(uid, cps(0x3000, 0x20), null, null, null))
        assertEquals(listOf("OutOfRange" to "message"), shapeOf(validate(doc)))
    }

    // ---- 契約外のキー（陽性対照） ----

    @Test
    fun `陽性対照：メールアドレスや表示名などの契約外のキーを含むフィードバックは違反になる`() {
        // 違反の並びは、契約外のキーのキー昇順（AllowListShapeValidator の規約）
        assertEquals(
            listOf("UnexpectedKey" to "displayName", "UnexpectedKey" to "email"),
            shapeOf(
                validate(
                    minimal + mapOf(
                        "email" to FsValue.Str("a@example.com"),
                        "displayName" to FsValue.Str("そら"),
                    ),
                ),
            ),
        )
    }

    @Test
    fun `陽性対照：契約外のキーは1つずつでも違反になる`() {
        listOf(
            "email" to FsValue.Str("a@example.com"),
            "displayName" to FsValue.Str("そら"),
            "photoURL" to FsValue.Str("https://example.com/a.jpg"),
            "updatedAt" to FsValue.Time(Instant.parse("2026-10-13T01:02:03Z")),
            "fcmToken" to FsValue.Str("token"),
        ).forEach { (key, value) ->
            assertEquals(listOf("UnexpectedKey" to key), shapeOf(validate(minimal + (key to value))), key)
        }
    }

    @Test
    fun `陽性対照：種別とバージョンと端末情報が揃っていても、契約外のキーがあれば違反になる`() {
        val full = DocumentBuilders.feedbackCreate(
            FeedbackInput(uid, "a", FeedbackCategory.BUG, appVersion, deviceInfo),
        )
        assertEquals(
            listOf("UnexpectedKey" to "email"),
            shapeOf(validate(full + ("email" to FsValue.Str("a@example.com")))),
        )
    }

    // ---- 必須・自分の uid・作成日時 ----

    @Test
    fun `3つの必須の項目のどれかが欠けると違反になる`() {
        listOf("userId", "message", "createdAt").forEach { key ->
            assertEquals(listOf("MissingKey" to key), shapeOf(validate(minimal - key)), key)
        }
    }

    @Test
    fun `他人のuidのフィードバックは違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "userId"),
            shapeOf(validate(minimal + ("userId" to FsValue.Str("OTHER-UID")))),
        )
    }

    @Test
    fun `作成日時が端末の時刻だと違反になる（フィードバックはサーバー時刻で書く）`() {
        assertEquals(
            listOf("WrongKind" to "createdAt"),
            shapeOf(validate(minimal + ("createdAt" to FsValue.Time(Instant.parse("2026-10-13T01:02:03Z"))))),
        )
    }

    // ---- 本文（トリム後に1文字以上・UTF-16 で1000以下） ----

    @Test
    fun `本文は1文字から1000文字まで合格し、1001文字で違反になる`() {
        assertEquals(emptyList(), validate(withMessage("あ")))
        assertEquals(emptyList(), validate(withMessage("あ".repeat(999))))
        assertEquals(emptyList(), validate(withMessage("あ".repeat(1000))))
        assertEquals(listOf("OutOfRange" to "message"), shapeOf(validate(withMessage("あ".repeat(1001)))))
    }

    @Test
    fun `陽性対照：空の本文は違反になる`() {
        assertEquals(listOf("OutOfRange" to "message"), shapeOf(validate(withMessage(""))))
    }

    @Test
    fun `陽性対照：半角空白と改行とタブだけの本文は違反になる`() {
        listOf(" ", "   ", "\n", "\t", " \n\t\r ").forEach { message ->
            assertEquals(listOf("OutOfRange" to "message"), shapeOf(validate(withMessage(message))), describe(message))
        }
    }

    @Test
    fun `陽性対照：全角空白だけの本文は違反になる`() {
        assertEquals(listOf("OutOfRange" to "message"), shapeOf(validate(withMessage(cps(0x3000)))))
        assertEquals(listOf("OutOfRange" to "message"), shapeOf(validate(withMessage(cps(0x3000, 0x3000, 0x3000)))))
    }

    @Test
    fun `iOSの空白の集合に入る文字だけの本文は違反になる（ゼロ幅スペース・NEL・NBSP・段落区切り）`() {
        listOf(0x200B, 0x0085, 0x00A0, 0x2028, 0x2029, 0x1680, 0x202F, 0x205F).forEach { codePoint ->
            assertEquals(
                listOf("OutOfRange" to "message"),
                shapeOf(validate(withMessage(cps(codePoint)))),
                "U+%04X".format(codePoint),
            )
        }
    }

    @Test
    fun `iOSの空白の集合に入らない文字だけの本文は違反にしない`() {
        // 情報区切り（U+001C）は Kotlin の isBlank だと空白になるが、iOS の集合には入らない。BOM も入らない。
        // iOS で送れる本文は、Android でも送れる
        assertEquals(emptyList(), validate(withMessage(cps(0x001C))))
        assertEquals(emptyList(), validate(withMessage(cps(0xFEFF))))
    }

    @Test
    fun `空白に挟まれた本文は合格する`() {
        // 取り除くのは入力の段階。契約は、空白だけでないことと長さを見る
        assertEquals(emptyList(), validate(withMessage(cps(0x3000) + "あ" + cps(0x3000))))
        assertEquals(emptyList(), validate(withMessage("空\n\n青")))
    }

    @Test
    fun `陽性対照：絵文字の本文は書記素でなくUTF16の長さで数える`() {
        // 😀 は UTF-16 で 2。500 個で 1000（合格）、501 個で 1002（rules の size() が断る長さ）。書記素では 501 個でも 501 で、iOS の count なら通ってしまう
        val emoji = cps(0x1F600)
        assertEquals(2, emoji.length)
        assertEquals(emptyList(), validate(withMessage(emoji.repeat(500))))
        assertEquals(listOf("OutOfRange" to "message"), shapeOf(validate(withMessage(emoji.repeat(501)))))
    }

    @Test
    fun `本文が文字列でないと種類の違反になる`() {
        assertEquals(
            listOf("WrongKind" to "message"),
            shapeOf(validate(minimal + ("message" to FsValue.Int64(1L)))),
        )
    }

    // ---- 種別・バージョン・端末情報 ----

    @Test
    fun `種別は3種のrawだけが合格する`() {
        FeedbackCategory.entries.forEach { category ->
            assertEquals(emptyList(), validate(minimal + ("category" to FsValue.Str(category.raw))), category.name)
        }
        listOf("Bug", "BUG", "question", " bug", "bug ", "").forEach { category ->
            assertEquals(
                listOf("OutOfRange" to "category"),
                shapeOf(validate(minimal + ("category" to FsValue.Str(category)))),
                "「$category」",
            )
        }
    }

    @Test
    fun `空文字のバージョンと端末情報は書かず、書けば違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "appVersion"),
            shapeOf(validate(minimal + ("appVersion" to FsValue.Str("")))),
        )
        assertEquals(
            listOf("OutOfRange" to "deviceInfo"),
            shapeOf(validate(minimal + ("deviceInfo" to FsValue.Str("")))),
        )
    }

    // ---- 本文の制約 NonBlankUtf16LengthAtMost を直接 ----

    private val constraint = ValueConstraint.NonBlankUtf16LengthAtMost(1000)

    private fun ValueConstraint.violation(value: FsValue): String? = check(value, target, minimal)

    @Test
    fun `NonBlankUtf16LengthAtMost は文字列でない値を通さない`() {
        val message = constraint.violation(FsValue.Int64(1L))
        assertTrue(message != null && "cannot be applied" in message, message)
    }

    @Test
    fun `NonBlankUtf16LengthAtMost の違反の説明は、空白だけと長すぎるを区別し、本文を含まない`() {
        val blank = assertNotNull(constraint.violation(FsValue.Str(cps(0x3000))))
        assertTrue("blank" in blank, blank)

        val secret = "SECRET-TEXT"
        val tooLong = assertNotNull(constraint.violation(FsValue.Str(secret + "あ".repeat(1000))))
        assertTrue("length 1011" in tooLong, tooLong)
        assertTrue("SECRET" !in tooLong && "SECRET" !in blank, "$blank / $tooLong")
        assertNull(constraint.violation(FsValue.Str(secret)))
    }

    /** 失敗メッセージ用。 */
    private fun describe(text: String): String = text.map { "<U+%04X>".format(it.code) }.joinToString("")
}
