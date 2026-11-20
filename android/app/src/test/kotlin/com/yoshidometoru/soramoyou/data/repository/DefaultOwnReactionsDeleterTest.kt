// ⭐️ 退会で自分のいいね・コメントを消し、相手の投稿のカウンタを減らす部品の単体テスト：3 段の分岐・止まる失敗・記録（タスク 31.3・要件 12.3・12.4）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.AllowListShapeValidator
import com.yoshidometoru.soramoyou.data.remote.read.DrainTarget
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DefaultFirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.DefaultStorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.FixedWriteGate
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics.LoggedError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * [DefaultOwnReactionsDeleter] の単体テスト。書き込みは本物の入口（可否 → 形の検証 → 実行）を、サーバーの代わりの記憶域
 * [DeletionBackend] の上で動かす（トランザクションは、溜めた書き込みを 1 回のコミットで全てか無しかで適用する）。
 *
 * rules の振る舞いは記憶域への差し込みで再現する：
 * - 他人の非公開・フォロワー限定の投稿＝投稿は有るが、トランザクションの中の読み取りが権限拒否（`txReadFailure`）
 * - 消えた投稿＝投稿が無く、読み取りも権限拒否（iOS の注記：rules が `resource.data` を参照するので、無い投稿の get は拒否になる）。
 *   読まずに書く段 B の加算は、存在しない文書の更新として不在（NotFound）になる
 *
 * いいねとコメントは同じ 3 段で消すので、どの確かめも [KINDS] の 2 種類の両方で行う（失敗の表示に種類の名前を入れる）。
 */
class DefaultOwnReactionsDeleterTest {

    private val uid = Uid("UID-1")

    /** 反応の種類と、そのコレクション名・減らすカウンタ・もう一方のカウンタ・記録の発生箇所の名前。 */
    private data class Kind(
        val kind: ReactionKind,
        val collection: String,
        val counter: String,
        val otherCounter: String,
        val label: String,
    )

    /** テストごとに作り直す一式。 */
    private class Fixture(enabled: Set<WriteCapability> = ALL_WRITES_ENABLED) {
        val backend = DeletionBackend()
        val analytics = RecordingAnalytics()
        val deleter = DefaultOwnReactionsDeleter(
            reader = backend.reader,
            gateway = DefaultFirestoreWriteGateway(FixedWriteGate(enabled), AllowListShapeValidator, backend.firestore, analytics) { Uid("UID-1") },
            analytics = analytics,
        )

        fun whats(): List<String> = backend.events.map { it.what }

        /** 他人 X の投稿 [postId] を入れる。2 つのカウンタは [likes]・[comments]（null ならフィールドごと無い旧データ）。 */
        fun post(postId: String, likes: Long?, comments: Long?) {
            backend.documents["posts/$postId"] = buildMap {
                put("userId", "X")
                put("visibility", "public")
                likes?.let { put("likesCount", it) }
                comments?.let { put("commentsCount", it) }
            }
        }

        /** [k] の種類の反応 [id] を入れる（持ち主は [owner]、対象は [postId]。null なら postId のキーが無い）。 */
        fun reaction(k: Kind, id: String, postId: Any?, owner: String = "UID-1") {
            backend.documents["${k.collection}/$id"] = buildMap {
                put("userId", owner)
                if (postId != null) put("postId", postId)
                if (k.kind == ReactionKind.COMMENT) put("content", "きれいな空")
            }
        }

        fun counterOf(postId: String, field: String): Any? = backend.documents.getValue("posts/$postId")[field]
    }

    // ── 段 A ──

    @Test
    fun `段A：投稿が読めてカウンタが1以上なら、1つのトランザクションで1減らして反応を消す`() = forEachKind { k ->
        val f = Fixture()
        f.post("P1", likes = 2L, comments = 2L)
        f.reaction(k, "R1", "P1")

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        assertEquals(
            listOf(
                "read DrainByField.${drainOf(k)}",
                "tx.get posts/P1",
                "firestore.commit update posts/P1 ${k.counter}-1;delete ${k.collection}/R1",
            ),
            f.whats(),
            k.label,
        )
        assertEquals(1L, f.counterOf("P1", k.counter), k.label)
        // もう一方のカウンタは触らない（契約がそれぞれのカウンタだけを許す）
        assertEquals(2L, f.counterOf("P1", k.otherCounter), k.label)
        assertFalse("${k.collection}/R1" in f.backend.documents, k.label)
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    @Test
    fun `段A：カウンタが0、またはフィールドの無い旧データなら、減らさずに反応だけを消す`() = forEachKind { k ->
        val f = Fixture()
        f.post("P0", likes = 0L, comments = 0L)
        f.post("PNONE", likes = null, comments = null)
        f.reaction(k, "R1", "P0")
        f.reaction(k, "R2", "PNONE")

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        // 投稿は読むが、加算は書かない（負にしない）
        assertEquals(
            listOf("firestore.commit delete ${k.collection}/R1", "firestore.commit delete ${k.collection}/R2"),
            f.whats().filter { it.startsWith("firestore.") },
            k.label,
        )
        assertEquals(0L, f.counterOf("P0", k.counter), k.label)
        assertFalse(k.counter in f.backend.documents.getValue("posts/PNONE"), k.label)
        assertFalse("${k.collection}/R1" in f.backend.documents || "${k.collection}/R2" in f.backend.documents, k.label)
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    @Test
    fun `段A：投稿を読めて、それが無ければ、減らさずに反応だけを消して段Bへ進まない`() = forEachKind { k ->
        val f = Fixture()
        f.reaction(k, "R1", "GONE")

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        assertEquals(
            listOf("tx.get posts/GONE", "firestore.commit delete ${k.collection}/R1"),
            f.whats().drop(1),
            k.label,
        )
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    // ── 段 A → 段 B ──

    @Test
    fun `段Aで投稿の読み取りが権限拒否・不在なら、段Bで読まずに削除と1減らす加算を1回のコミットで書く`() = forEachKind { k ->
        listOf(AppError.PermissionDenied, AppError.NotFound).forEach { refusal ->
            val f = Fixture()
            // 他人の非公開の投稿（存在するが読めない）
            f.post("PRIVATE", likes = 3L, comments = 3L)
            f.reaction(k, "R1", "PRIVATE")
            f.backend.txReadFailure = { path -> refusal.takeIf { path == "posts/PRIVATE" } }

            val result = f.deleter.deleteAll(k.kind, uid)

            assertEquals(AppResult.Ok(Unit), result, "${k.label} $refusal")
            // 読むのは段 A の 1 回だけ。段 B は読まずに、削除と加算を 1 回で書く
            assertEquals(
                listOf("tx.get posts/PRIVATE", "firestore.commit delete ${k.collection}/R1;update posts/PRIVATE ${k.counter}-1"),
                f.whats().drop(1),
                "${k.label} $refusal",
            )
            assertEquals(2L, f.counterOf("PRIVATE", k.counter), "${k.label} $refusal")
            assertEquals(3L, f.counterOf("PRIVATE", k.otherCounter), "${k.label} $refusal")
            assertFalse("${k.collection}/R1" in f.backend.documents, "${k.label} $refusal")
            // 段 A から B への移り変わりは記録しない（非公開の投稿で普通に起きる）
            assertEquals(emptyList(), f.analytics.errors, "${k.label} $refusal")
        }
    }

    @Test
    fun `段Aのコミットが権限拒否でも、段Bへ進む`() = forEachKind { k ->
        val f = Fixture()
        f.post("P1", likes = 1L, comments = 1L)
        f.reaction(k, "R1", "P1")
        // 1 回目のコミット（段 A）だけを拒否する
        var commits = 0
        f.backend.writeFailure = { operation, _ -> AppError.PermissionDenied.takeIf { operation == "commit" && ++commits == 1 } }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        assertEquals(
            listOf(
                "tx.get posts/P1",
                "firestore.commit update posts/P1 ${k.counter}-1;delete ${k.collection}/R1",
                "firestore.commit delete ${k.collection}/R1;update posts/P1 ${k.counter}-1",
            ),
            f.whats().drop(1),
            k.label,
        )
        assertEquals(0L, f.counterOf("P1", k.counter), k.label)
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    // ── 段 A → 段 B → 段 C ──

    @Test
    fun `消えた投稿は、段Aが権限拒否・段Bが不在で、段Cで反応だけを消して記録する`() = forEachKind { k ->
        val f = Fixture()
        f.reaction(k, "R1", "DELETED")
        f.backend.txReadFailure = { path -> AppError.PermissionDenied.takeIf { path == "posts/DELETED" } }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        assertEquals(
            listOf(
                "tx.get posts/DELETED",
                "firestore.commit delete ${k.collection}/R1;update posts/DELETED ${k.counter}-1",
                "firestore.delete ${k.collection}/R1",
            ),
            f.whats().drop(1),
            k.label,
        )
        assertFalse("${k.collection}/R1" in f.backend.documents, k.label)
        // 投稿を作り直していない（存在しない文書の更新は書かれない）
        assertFalse("posts/DELETED" in f.backend.documents, k.label)
        // カウンタを直せなかったことだけを、段 B の原因で記録する（user_error なので error_occurred だけに行く）
        assertEquals(listOf(LoggedError(AppError.NotFound, "OwnReactionsDeleter.deleteAll.${k.label}.counter_skipped")), f.analytics.errors, k.label)
    }

    @Test
    fun `段Bも権限拒否なら、段Cで反応だけを消し、カウンタはそのままにして記録する`() = forEachKind { k ->
        val f = Fixture()
        f.post("P1", likes = 4L, comments = 4L)
        f.reaction(k, "R1", "P1")
        f.backend.txReadFailure = { AppError.PermissionDenied }
        f.backend.writeFailure = { operation, _ -> AppError.PermissionDenied.takeIf { operation == "commit" } }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        assertEquals("firestore.delete ${k.collection}/R1", f.whats().last(), k.label)
        assertEquals(4L, f.counterOf("P1", k.counter), k.label)
        assertFalse("${k.collection}/R1" in f.backend.documents, k.label)
        assertEquals(
            listOf(LoggedError(AppError.PermissionDenied, "OwnReactionsDeleter.deleteAll.${k.label}.counter_skipped")),
            f.analytics.errors,
            k.label,
        )
    }

    @Test
    fun `段Cに落ちたことの記録は、1回の呼び出しで1回だけにする`() = forEachKind { k ->
        val f = Fixture()
        f.reaction(k, "R1", "DELETED1")
        f.reaction(k, "R2", "DELETED2")
        f.reaction(k, "R3", "DELETED3")
        f.backend.txReadFailure = { AppError.PermissionDenied }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        assertEquals(3, f.whats().count { it.startsWith("firestore.delete ") }, k.label)
        assertEquals(listOf(LoggedError(AppError.NotFound, "OwnReactionsDeleter.deleteAll.${k.label}.counter_skipped")), f.analytics.errors, k.label)
    }

    @Test
    fun `postIdが無い・空・文字列でない・スラッシュを含む反応は、投稿に触れずに削除だけを行い、1回だけ記録する`() = forEachKind { k ->
        val f = Fixture()
        f.reaction(k, "R1", postId = null)
        f.reaction(k, "R2", postId = "")
        f.reaction(k, "R3", postId = 123L)
        f.reaction(k, "R4", postId = "P1/x")

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        // 投稿を読まず、トランザクションも撃たない
        assertEquals(
            listOf("R1", "R2", "R3", "R4").map { "firestore.delete ${k.collection}/$it" },
            f.whats().drop(1),
            k.label,
        )
        assertEquals(
            listOf(LoggedError(AppError.Unknown("ReactionWithoutPostId"), "OwnReactionsDeleter.deleteAll.${k.label}.post_id_missing")),
            f.analytics.errors,
            k.label,
        )
    }

    // ── 退会を止める失敗 ──

    @Test
    fun `段Aが通信の断絶なら、段Bへ進まずにその失敗を返し、残りの反応には触れない`() = forEachKind { k ->
        // 読み取りの断絶とコミットの断絶の両方
        val injections: List<Pair<String, (Fixture) -> Unit>> = listOf(
            "読み取り" to { f -> f.backend.txReadFailure = { path -> AppError.Network.takeIf { path == "posts/P1" } } },
            "コミット" to { f -> f.backend.writeFailure = { operation, _ -> AppError.Network.takeIf { operation == "commit" } } },
        )
        injections.forEach { (where, inject) ->
            val f = Fixture()
            f.post("P1", likes = 5L, comments = 5L)
            f.post("P2", likes = 5L, comments = 5L)
            f.reaction(k, "R1", "P1")
            f.reaction(k, "R2", "P2")
            inject(f)

            val result = f.deleter.deleteAll(k.kind, uid)

            assertEquals(AppResult.Err(AppError.Network), result, "${k.label} $where")
            // R1 の段 A で止まる。段 B・C も R2 も無い
            assertEquals(1, f.whats().count { it.startsWith("tx.get ") }, "${k.label} $where")
            assertFalse(f.whats().any { it.startsWith("firestore.delete ") }, "${k.label} $where")
            assertTrue("${k.collection}/R1" in f.backend.documents && "${k.collection}/R2" in f.backend.documents, "${k.label} $where")
            assertEquals(5L, f.counterOf("P1", k.counter), "${k.label} $where")
            // 返す失敗は記録しない（手順の本体が段階名つきで記録する）
            assertEquals(emptyList(), f.analytics.errors, "${k.label} $where")
        }
    }

    @Test
    fun `段Bが通信の断絶なら、段Cへ進まずにその失敗を返す`() = forEachKind { k ->
        val f = Fixture()
        f.post("PRIVATE", likes = 2L, comments = 2L)
        f.reaction(k, "R1", "PRIVATE")
        f.backend.txReadFailure = { AppError.PermissionDenied }
        f.backend.writeFailure = { operation, _ -> AppError.Network.takeIf { operation == "commit" } }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Err(AppError.Network), result, k.label)
        // カウンタを直さないまま削除だけ進めない
        assertFalse(f.whats().any { it.startsWith("firestore.delete ") }, k.label)
        assertTrue("${k.collection}/R1" in f.backend.documents, k.label)
        assertEquals(2L, f.counterOf("PRIVATE", k.counter), k.label)
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    @Test
    fun `段Cの削除自体の失敗は、権限拒否でも退会を止め、カウンタを直せなかった記録も残さない`() = forEachKind { k ->
        val f = Fixture()
        f.reaction(k, "R1", "DELETED")
        f.reaction(k, "R2", "DELETED")
        f.backend.txReadFailure = { AppError.PermissionDenied }
        f.backend.writeFailure = { operation, _ -> AppError.PermissionDenied.takeIf { operation == "delete" } }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result, k.label)
        assertEquals(1, f.whats().count { it.startsWith("firestore.delete ") }, k.label)
        assertTrue("${k.collection}/R2" in f.backend.documents, k.label)
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    @Test
    fun `postIdの無い反応の削除が失敗したら、退会を止めて記録しない`() = forEachKind { k ->
        val f = Fixture()
        f.reaction(k, "R1", postId = null)
        f.backend.writeFailure = { operation, _ -> AppError.Network.takeIf { operation == "delete" } }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Err(AppError.Network), result, k.label)
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    @Test
    fun `書き込みが無効なビルドでは、段Bへ進まずにWriteBlockedを返し、記録は入口の1回だけ`() = forEachKind { k ->
        val f = Fixture(enabled = ALL_WRITES_ENABLED - WriteCapability.ACCOUNT_DELETE)
        f.post("P1", likes = 1L, comments = 1L)
        f.reaction(k, "R1", "P1")

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Err(AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE)), result, k.label)
        // 取得はしたが、Firebase への書き込みは 1 つも無い（入口が手前で断る）
        assertEquals(listOf("read DrainByField.${drainOf(k)}"), f.whats(), k.label)
        assertEquals(
            listOf(LoggedError(AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE), "FirestoreWriteGateway.transaction")),
            f.analytics.errors,
            k.label,
        )
    }

    @Test
    fun `取得の失敗は、そのまま返す`() = forEachKind { k ->
        val f = Fixture()
        f.reaction(k, "R1", "P1")
        f.backend.queryFailure = { AppError.Network }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Err(AppError.Network), result, k.label)
        assertEquals(listOf("read DrainByField.${drainOf(k)}"), f.whats(), k.label)
        assertEquals(emptyList(), f.analytics.errors, k.label)
    }

    // ── 取得と順序 ──

    @Test
    fun `同じ投稿への反応2件は、1件ずつ別のコミットで1ずつ減らす`() = forEachKind { k ->
        val f = Fixture()
        f.post("P1", likes = 2L, comments = 2L)
        f.reaction(k, "R1", "P1")
        f.reaction(k, "R2", "P1")

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        // -2 をまとめて書くと isCountOnlyUpdate に拒否されるので、-1 ずつ 2 回（契約も -1 しか通さない）
        assertEquals(
            listOf("R1", "R2").map { "firestore.commit update posts/P1 ${k.counter}-1;delete ${k.collection}/$it" },
            f.whats().filter { it.startsWith("firestore.") },
            k.label,
        )
        assertEquals(0L, f.counterOf("P1", k.counter), k.label)
    }

    @Test
    fun `50件を超えると、消してから先頭を取り直し、全てを消し切る。取得はサーバーから`() = forEachKind { k ->
        val f = Fixture()
        f.post("P1", likes = 60L, comments = 60L)
        repeat(51) { f.reaction(k, "R%02d".format(it), "P1") }

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        // 50 件のページの後に、残りの 1 件のページ（上限未満なので、空を確かめる 3 回目は撃たない）
        val drain: Pair<QuerySpec, ReadSource> = QuerySpec.DrainByField(drainOf(k), uid) to ReadSource.SERVER
        assertEquals(listOf(drain, drain), f.backend.queries.toList(), k.label)
        assertEquals(51, f.whats().count { it.startsWith("firestore.commit ") }, k.label)
        assertEquals(9L, f.counterOf("P1", k.counter), k.label)
        assertFalse(f.backend.documents.keys.any { it.startsWith("${k.collection}/") }, k.label)
    }

    @Test
    fun `他人の反応と、もう一方の種類の自分の反応には触れない`() = forEachKind { k ->
        val other = KINDS.single { it != k }
        val f = Fixture()
        f.post("P1", likes = 5L, comments = 5L)
        f.reaction(k, "MINE", "P1")
        f.reaction(k, "THEIRS", "P1", owner = "X")
        f.reaction(other, "MINE-OTHER-KIND", "P1")

        val result = f.deleter.deleteAll(k.kind, uid)

        assertEquals(AppResult.Ok(Unit), result, k.label)
        assertFalse("${k.collection}/MINE" in f.backend.documents, k.label)
        assertTrue("${k.collection}/THEIRS" in f.backend.documents, k.label)
        assertTrue("${other.collection}/MINE-OTHER-KIND" in f.backend.documents, k.label)
        assertEquals(4L, f.counterOf("P1", k.counter), k.label)
        assertEquals(5L, f.counterOf("P1", other.counter), k.label)
    }

    // ── 手順の本体に組み込んだとき ──

    @Test
    fun `手順の本体に組み込むと、段階LIKES・COMMENTSで自分の反応を消して相手のカウンタを減らす`() = runBlocking {
        val s = ServiceFixture()
        s.f.post("P1", likes = 2L, comments = 3L)
        s.f.post("PRIVATE", likes = 1L, comments = 1L)
        s.f.reaction(KINDS[0], "L1", "P1")
        s.f.reaction(KINDS[0], "L2", "PRIVATE")
        s.f.reaction(KINDS[1], "C1", "P1")
        s.f.reaction(KINDS[1], "C2", "P1")
        s.f.reaction(KINDS[1], "C3", "DELETED")
        s.f.backend.txReadFailure = { path -> AppError.PermissionDenied.takeIf { path == "posts/PRIVATE" || path == "posts/DELETED" } }

        val result = s.service.delete("pw-31.3")

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(setOf("posts/P1", "posts/PRIVATE"), s.f.backend.documents.keys)
        assertEquals(1L, s.f.counterOf("P1", "likesCount"))
        assertEquals(1L, s.f.counterOf("P1", "commentsCount"))
        assertEquals(0L, s.f.counterOf("PRIVATE", "likesCount"))
        // 反応の書き込みは、それぞれの段階が立っている間に行う
        val stageOfReactionWrite = s.f.backend.events
            .filter { it.what.startsWith("firestore.commit") || it.what.matches(Regex("firestore\\.delete (likes|comments)/.*")) }
            .map { it.stage }
            .distinct()
        assertEquals(listOf(DeletionStage.LIKES, DeletionStage.COMMENTS), stageOfReactionWrite)
        // 消えた投稿へのコメントで段 C に落ちたことだけが、部品の発生箇所で記録される
        assertEquals(listOf(LoggedError(AppError.NotFound, "OwnReactionsDeleter.deleteAll.comments.counter_skipped")), s.f.analytics.errors)
    }

    @Test
    fun `手順の本体に組み込むと、部品が返した失敗はLIKESの段階の失敗として1回だけ記録され、以降の段階に進まない`() = runBlocking {
        val s = ServiceFixture()
        s.f.post("P1", likes = 1L, comments = 1L)
        s.f.reaction(KINDS[0], "L1", "P1")
        s.f.reaction(KINDS[1], "C1", "P1")
        s.f.backend.writeFailure = { operation, _ -> AppError.Network.takeIf { operation == "commit" } }

        val result = s.service.delete("pw-31.3")

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.LIKES, AppError.Network)), result)
        assertEquals(
            listOf(LoggedError(AppError.StageFailed(DeletionStage.LIKES, AppError.Network), "AccountDeletionService.delete.likes")),
            s.f.analytics.errors,
        )
        assertFalse(s.f.whats().any { it.startsWith("read DrainByField.COMMENTS") || it == "auth.deleteAuthAccount" })
        assertTrue("likes/L1" in s.f.backend.documents && "comments/C1" in s.f.backend.documents)
    }

    /** 本物の部品を組み込んだ退会の手順の本体（認証・端末のデータの消去は偽物）。記憶域・記録は [f] と共有する。 */
    private class ServiceFixture {
        val f = Fixture()
        val service = DefaultAccountDeletionService(
            auth = DeletionAuthRepository(f.backend),
            reader = f.backend.reader,
            gateway = DefaultFirestoreWriteGateway(FixedWriteGate(ALL_WRITES_ENABLED), AllowListShapeValidator, f.backend.firestore, f.analytics) {
                Uid("UID-1")
            },
            storage = DefaultStorageGateway(FixedWriteGate(ALL_WRITES_ENABLED), f.backend.storage, f.analytics, wait = {}),
            reactions = f.deleter,
            sessionManager = DeletionSessionManager(f.backend),
            analytics = f.analytics,
            currentUid = { Uid("UID-1") },
        )

        init {
            f.backend.stageNow = { service.stage.value }
        }
    }

    /** [block] を [KINDS] の両方で、種類ごとに作り直して実行する。 */
    private fun forEachKind(block: suspend (Kind) -> Unit) = runBlocking {
        KINDS.forEach { block(it) }
    }

    private fun drainOf(k: Kind): DrainTarget = when (k.kind) {
        ReactionKind.LIKE -> DrainTarget.LIKES
        ReactionKind.COMMENT -> DrainTarget.COMMENTS
    }

    private companion object {
        val KINDS = listOf(
            Kind(ReactionKind.LIKE, collection = "likes", counter = "likesCount", otherCounter = "commentsCount", label = "likes"),
            Kind(ReactionKind.COMMENT, collection = "comments", counter = "commentsCount", otherCounter = "likesCount", label = "comments"),
        )
    }
}
