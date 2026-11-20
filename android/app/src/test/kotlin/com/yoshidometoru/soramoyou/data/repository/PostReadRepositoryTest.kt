// ⭐️ 投稿 1 件の取得の単体テスト（タスク 10.1・要件 5.1・5.5）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class PostReadRepositoryTest {

    private fun repository(result: AppResult<com.yoshidometoru.soramoyou.data.remote.RawDocument?>?) =
        FakeFirestoreReader(documents = if (result == null) emptyMap() else mapOf("posts/P1" to result)).let { reader ->
            reader to DefaultPostReadRepository(reader, DefaultPostDocumentReader(RemoteImageUrlPolicy.PRODUCTION))
        }

    @Test
    fun `投稿IDの文書を読み、フィードと同じ規則で表示用に変換する`() = runBlocking {
        val (reader, repository) = repository(AppResult.Ok(postDocument("P1", author = "alice")))

        val found = assertIs<PostLookup.Found>(assertIs<AppResult.Ok<PostLookup>>(repository.fetch(PostId("P1"))).value)

        assertEquals("alice", found.post.userId.value)
        assertEquals(listOf(DocRef.post(PostId("P1")) to ReadSource.DEFAULT), reader.gets)
    }

    @Test
    fun `文書が無ければ削除済み、権限が無ければ権限なし、と区別して返す`() = runBlocking {
        assertEquals(AppResult.Ok(PostLookup.Deleted), repository(null).second.fetch(PostId("P1")))
        assertEquals(AppResult.Ok(PostLookup.Deleted), repository(AppResult.Err(AppError.NotFound)).second.fetch(PostId("P1")))
        assertEquals(AppResult.Ok(PostLookup.NoPermission), repository(AppResult.Err(AppError.PermissionDenied)).second.fetch(PostId("P1")))
    }

    @Test
    fun `変換できない投稿は理由を付けて返し、ここでは記録しない`() = runBlocking {
        val (_, repository) = repository(AppResult.Ok(brokenPostDocument("P1")))

        assertEquals(
            AppResult.Ok(PostLookup.Unreadable(DefaultPostDocumentReader.REASON_MISSING_REQUIRED_FIELDS)),
            repository.fetch(PostId("P1")),
        )
    }

    @Test
    fun `通信の失敗などはそのまま失敗として返す`() = runBlocking {
        assertEquals(AppResult.Err(AppError.Network), repository(AppResult.Err(AppError.Network)).second.fetch(PostId("P1")))
    }

    @Test
    fun `文書IDに使えない投稿IDは読まずに削除済みとして返す`() = runBlocking {
        val (reader, repository) = repository(null)

        assertEquals(AppResult.Ok(PostLookup.Deleted), repository.fetch(PostId("a/b")))
        assertEquals(emptyList(), reader.gets)
    }
}
