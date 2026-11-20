// ⭐️ 退会でコメントを消すときの、投稿のコメント数の減算の契約（POST_COMMENT_COUNTER）と組み立ての単体テスト（タスク 31.3・要件 12.3）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 投稿側は `commentsCount` の -1 の加算だけ（Android の MVP はコメントを作らないので、契約は -1 だけ）。
 * `updatedAt` を同時に書くと rules が拒否する。
 *
 * いいねの契約のテスト（LikeContractsTest）とは別のファイルにした。いいねの契約を変えずに、退会（タスク 31.3）で足した契約だけを確かめるため。
 */
class CommentCounterContractTest {

    private val uid = Uid("USER-UID-1")
    private val postId = PostId("POST-ID-1")
    private val now = Instant.parse("2026-10-14T01:02:03Z")

    /** 投稿のカウンタの更新先。書き手（uid）は投稿者でなくてよい（退会者が他人の投稿のコメント数を減らす）。 */
    private val postTarget = WriteTarget(documentId = postId.value, authUid = uid)

    private fun validate(doc: FsDocument): List<Violation> =
        AllowListShapeValidator.validate(ShapeContracts.POST_COMMENT_COUNTER, doc, postTarget)

    @Test
    fun `契約のIDはコメント数の減算`() {
        assertEquals(ContractId.POST_COMMENT_COUNTER, ShapeContracts.POST_COMMENT_COUNTER.id)
    }

    @Test
    fun `組み立てたコメント数の減算は、commentsCountの-1の加算だけで、契約に合格する`() {
        assertEquals(mapOf("commentsCount" to FsValue.Increment(-1L)), DocumentBuilders.commentCounter(-1))
        assertEquals(emptyList(), validate(DocumentBuilders.commentCounter(-1)))
    }

    @Test
    fun `-1以外の増減は、増やす向きも含めて違反になる`() {
        // +1 は rules では通るが、Android にはコメントを作る経路が無いので契約で止める
        listOf(1, 0, 2, -2).forEach { delta ->
            assertEquals(listOf("OutOfRange" to "commentsCount"), shapeOf(validate(DocumentBuilders.commentCounter(delta))), "$delta")
        }
    }

    @Test
    fun `更新日時を同時に含むコメント数の減算は違反になる`() {
        assertEquals(
            listOf("UnexpectedKey" to "updatedAt"),
            shapeOf(validate(DocumentBuilders.commentCounter(-1) + ("updatedAt" to FsValue.Time(now)))),
        )
    }

    @Test
    fun `コメント数を加算でなく値で書くと違反になる`() {
        assertEquals(listOf("WrongKind" to "commentsCount"), shapeOf(validate(mapOf("commentsCount" to FsValue.Int64(0L)))))
    }

    @Test
    fun `コメント数の無い更新と、いいね数を同時に書く更新は違反になる`() {
        assertEquals(listOf("MissingKey" to "commentsCount"), shapeOf(validate(emptyMap())))
        assertEquals(
            listOf("UnexpectedKey" to "likesCount"),
            shapeOf(validate(DocumentBuilders.commentCounter(-1) + DocumentBuilders.likeCounter(-1))),
        )
    }
}
