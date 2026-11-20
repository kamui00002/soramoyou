// ⭐️ いいねの書き込みの契約（LIKE_CREATE・POST_LIKE_COUNTER）と組み立ての単体テスト（タスク 18.1・要件 9.3・9.4・9.5）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * いいね文書は「押した人の uid・投稿 ID・作成日時」の 3 項目だけで、ドキュメント ID は `{uid}_{postId}`（firestore.rules:320-323）。
 * 投稿側は `likesCount` の ±1 の加算だけ（firestore.rules:85-104 の isCountOnlyUpdate。`updatedAt` を同時に書くと拒否される）。
 *
 * 陽性対照（先に赤を確かめたもの）：更新日時を同時に含むいいね数の更新、±1 以外の増減、
 * 他人の uid・ドキュメント ID と食い違う投稿 ID・4 項目目のキーを持ついいね文書が違反になること。
 */
class LikeContractsTest {

    private val uid = Uid("USER-UID-1")
    private val postId = PostId("POST-ID-1")
    private val now = Instant.parse("2026-10-08T01:02:03Z")

    /** いいね文書の書き込み先。ドキュメント ID は `{uid}_{postId}`（DocRef.like と同じ形）。 */
    private val likeTarget = WriteTarget(documentId = "${uid.value}_${postId.value}", authUid = uid)

    /** 投稿のカウンタの更新先。書き手（uid）は投稿者でなくてよい。 */
    private val postTarget = WriteTarget(documentId = postId.value, authUid = uid)

    private fun validateLike(doc: FsDocument, target: WriteTarget = likeTarget): List<Violation> =
        AllowListShapeValidator.validate(ShapeContracts.LIKE_CREATE, doc, target)

    private fun validateCounter(doc: FsDocument): List<Violation> =
        AllowListShapeValidator.validate(ShapeContracts.POST_LIKE_COUNTER, doc, postTarget)

    private val validLike: FsDocument = mapOf(
        "userId" to FsValue.Str(uid.value),
        "postId" to FsValue.Str(postId.value),
        "createdAt" to FsValue.Time(now),
    )

    /** 違反の（種類, キー）。 */
    private fun shapeOf(violations: List<Violation>): List<Pair<String, String>> = violations.map {
        when (it) {
            is Violation.MissingKey -> "MissingKey" to it.key
            is Violation.UnexpectedKey -> "UnexpectedKey" to it.key
            is Violation.WrongKind -> "WrongKind" to it.key
            is Violation.OutOfRange -> "OutOfRange" to it.key
        }
    }

    @Test
    fun `契約のIDは操作ごとに正しい`() {
        assertEquals(ContractId.LIKE_CREATE, ShapeContracts.LIKE_CREATE.id)
        assertEquals(ContractId.POST_LIKE_COUNTER, ShapeContracts.POST_LIKE_COUNTER.id)
    }

    // ---- いいね文書（LIKE_CREATE） ----

    @Test
    fun `組み立てたいいね文書は3項目だけで、契約に合格する`() {
        val doc = DocumentBuilders.likeCreate(uid, postId, now)
        assertEquals(validLike, doc)
        assertEquals(emptyList(), validateLike(doc))
    }

    @Test
    fun `4項目目のキーを持ついいね文書は違反になる`() {
        assertEquals(
            listOf("UnexpectedKey" to "updatedAt"),
            shapeOf(validateLike(validLike + ("updatedAt" to FsValue.Time(now)))),
        )
    }

    @Test
    fun `3項目のどれかが欠けると違反になる`() {
        listOf("userId", "postId", "createdAt").forEach { key ->
            assertEquals(listOf("MissingKey" to key), shapeOf(validateLike(validLike - key)), key)
        }
    }

    @Test
    fun `他人のuidのいいね文書は違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "userId"),
            shapeOf(validateLike(validLike + ("userId" to FsValue.Str("OTHER-UID")))),
        )
    }

    @Test
    fun `ドキュメントIDが uid_投稿ID と食い違ういいね文書は違反になる`() {
        // 投稿 ID の値だけを変える（ドキュメント ID は元の投稿のまま）
        assertEquals(
            listOf("OutOfRange" to "postId"),
            shapeOf(validateLike(validLike + ("postId" to FsValue.Str("POST-ID-2")))),
        )
        // ドキュメント ID の側が別の形（uid を付けていない）
        assertEquals(
            listOf("OutOfRange" to "postId"),
            shapeOf(validateLike(validLike, WriteTarget(documentId = postId.value, authUid = uid))),
        )
    }

    @Test
    fun `空の投稿IDは、ドキュメントIDが uid_ でも違反になる`() {
        assertEquals(
            listOf("OutOfRange" to "postId"),
            shapeOf(
                validateLike(
                    validLike + ("postId" to FsValue.Str("")),
                    WriteTarget(documentId = "${uid.value}_", authUid = uid),
                ),
            ),
        )
    }

    @Test
    fun `作成日時がサーバー時刻だと違反になる（端末の時刻で書く）`() {
        assertEquals(
            listOf("WrongKind" to "createdAt"),
            shapeOf(validateLike(validLike + ("createdAt" to FsValue.ServerTime))),
        )
    }

    @Test
    fun `ドキュメントIDの制約は、文字列でない値を通さない`() {
        val message = ValueConstraint.DocumentIdIsAuthUidAndValue.check(FsValue.Int64(1L), likeTarget, validLike)
        assertTrue(message != null && "cannot be applied" in message, message)
    }

    // ---- 投稿のいいね数（POST_LIKE_COUNTER） ----

    @Test
    fun `組み立てたいいね数の更新は、増やすときも減らすときも契約に合格する`() {
        assertEquals(mapOf("likesCount" to FsValue.Increment(1L)), DocumentBuilders.likeCounter(1))
        assertEquals(mapOf("likesCount" to FsValue.Increment(-1L)), DocumentBuilders.likeCounter(-1))
        assertEquals(emptyList(), validateCounter(DocumentBuilders.likeCounter(1)))
        assertEquals(emptyList(), validateCounter(DocumentBuilders.likeCounter(-1)))
    }

    @Test
    fun `更新日時を同時に含むいいね数の更新は違反になる`() {
        assertEquals(
            listOf("UnexpectedKey" to "updatedAt"),
            shapeOf(validateCounter(DocumentBuilders.likeCounter(1) + ("updatedAt" to FsValue.Time(now)))),
        )
    }

    @Test
    fun `±1以外の増減は違反になる`() {
        listOf(0, 2, -2).forEach { delta ->
            assertEquals(listOf("OutOfRange" to "likesCount"), shapeOf(validateCounter(DocumentBuilders.likeCounter(delta))), "$delta")
        }
    }

    @Test
    fun `いいね数を加算でなく値で書くと違反になる`() {
        assertEquals(
            listOf("WrongKind" to "likesCount"),
            shapeOf(validateCounter(mapOf("likesCount" to FsValue.Int64(5L)))),
        )
    }

    @Test
    fun `いいね数の無い更新と、コメント数を同時に書く更新は違反になる`() {
        assertEquals(listOf("MissingKey" to "likesCount"), shapeOf(validateCounter(emptyMap())))
        assertEquals(
            listOf("UnexpectedKey" to "commentsCount"),
            shapeOf(validateCounter(DocumentBuilders.likeCounter(1) + ("commentsCount" to FsValue.Increment(1L)))),
        )
    }
}
