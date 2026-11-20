// ⭐️ 画面に出すいいね数の単体テスト（タスク 18.4・要件 9.1）
package com.yoshidometoru.soramoyou.feature.feed

import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.data.repository.LikeCountOverride
import kotlin.test.Test
import kotlin.test.assertEquals

/** 画面が LikeStateStore の押した結果の数を、投稿の likesCount と組み合わせて出すことを確かめる（規則そのものは DefaultLikeStateStoreTest）。 */
class LikeDisplayTest {

    private val display = LikeDisplay(
        liked = setOf(PostId("A")),
        countOverrides = mapOf(PostId("A") to LikeCountOverride(baseCount = 5, count = 6, isLiked = true)),
        canLike = true,
    )

    @Test
    fun `押した結果の数は同じ基準の投稿にだけ使い、ほかは投稿の値を0未満なら0にして出す`() {
        // (投稿, 出す数)
        val rows = listOf(
            post("A").copy(likesCount = 5) to 6L, // 押したときと同じ基準：押した結果
            post("A").copy(likesCount = 9) to 9L, // 読み直して最新値が届いた：投稿の値
            post("B").copy(likesCount = -2) to 0L, // 押していない投稿の 0 未満：0
        )
        for ((post, expected) in rows) assertEquals(expected, display.countOf(post), "${post.postId} likesCount=${post.likesCount}")
    }
}
