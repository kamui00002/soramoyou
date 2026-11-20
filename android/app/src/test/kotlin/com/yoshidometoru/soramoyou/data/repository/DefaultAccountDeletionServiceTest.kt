// ⭐️ 退会の手順の本体の単体テスト：順序・各段階の失敗で止まること・記録・冪等・打ち切り・取り消し（タスク 31.2・要件 12.3〜12.5・12.7）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.AllowListShapeValidator
import com.yoshidometoru.soramoyou.contract.document.Violation
import com.yoshidometoru.soramoyou.data.edit.SessionEndReason
import com.yoshidometoru.soramoyou.data.edit.UserEditDataPurger
import com.yoshidometoru.soramoyou.data.remote.read.DrainTarget
import com.yoshidometoru.soramoyou.data.remote.read.OwnedCollection
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
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * [DefaultAccountDeletionService] の単体テスト。
 * 書き込みは本物の入口（Firestore・Storage）の上で動かし、偽物にするのは SDK への継ぎ目（サーバーの代わりの記憶域 [DeletionBackend]）・
 * 認証・タスク 31.3 の部品（いいね・コメント）・端末のデータの消去だけ。
 */
class DefaultAccountDeletionServiceTest {

    private val uid = Uid("UID-1")

    /** テストごとに作り直す一式（段階ごとに失敗させるテストは、1 つのテストの中で何度も作る）。 */
    private class Fixture(
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        signedIn: Uid? = Uid("UID-1"),
        imageDeleteTimeout: Duration = 30.seconds,
        /** true なら、端末の編集のデータの後始末の偽物を渡す（呼ばれた順は backend の記録に残る）。false は既定の何もしない部品 */
        withPurger: Boolean = false,
    ) {
        val backend = DeletionBackend()

        /** 後始末に渡された uid と理由 */
        val purged = mutableListOf<Pair<Uid, SessionEndReason>>()
        val analytics = RecordingAnalytics()
        val auth = DeletionAuthRepository(backend)
        val reactions = DeletionReactions(backend)

        /** 書き込みの入口（本物）。退会の途中に他の画面の書き込みを呼ぶテストは、同じこの入口を通す（アプリでも入口は 1 つずつ）。 */
        val gateway = DefaultFirestoreWriteGateway(FixedWriteGate(enabled), AllowListShapeValidator, backend.firestore, analytics) { signedIn }
        val storage = DefaultStorageGateway(FixedWriteGate(enabled), backend.storage, analytics, wait = {})
        val service = DefaultAccountDeletionService(
            auth = auth,
            reader = backend.reader,
            gateway = gateway,
            storage = storage,
            reactions = reactions,
            sessionManager = DeletionSessionManager(backend),
            analytics = analytics,
            currentUid = { signedIn },
            imageDeleteTimeout = imageDeleteTimeout,
            purger = if (withPurger) {
                UserEditDataPurger { uid, reason ->
                    purged += uid to reason
                    backend.record("purge ${uid.value} $reason")
                }
            } else {
                UserEditDataPurger.NONE
            },
        )

        init {
            backend.stageNow = { service.stage.value }
        }

        /** 記録の段階を、続けて同じものを 1 つにまとめた並び（段階が行ったり来たりしていないことを見る）。 */
        fun stageSequence(): List<DeletionStage?> =
            backend.events.map { it.stage }.fold(mutableListOf()) { acc, stage -> acc.apply { if (lastOrNull() != stage) add(stage) } }

        /** 段階ごとの仕事（並列に消す画像の順に左右されないよう、段階の中では並べ替える）。 */
        fun workByStage(): Map<DeletionStage?, List<String>> =
            backend.events.groupBy({ it.stage }, { it.what }).mapValues { it.value.sorted() }

        fun whats(): List<String> = backend.events.map { it.what }

        /** 欠けたアカウント文書の補完の本物（プロフィール画面を開くたびに呼ばれる）。退会と同じ入口を通す。 */
        val repairer = DefaultAccountDocumentRepairer(
            gateway = gateway,
            analytics = analytics,
            currentUser = { signedIn?.let { SessionState.SignedIn(it, "a@example.com", isAnonymous = false) } },
        )
    }

    /**
     * 退会するユーザー UID-1 のデータ一式と、消してはいけない他人のデータを入れる。
     * 投稿 P1 はパスあり（本体・サムネイル・元画像）、P2 はパスの無い旧データ（URL から解決する）。
     */
    private fun DeletionBackend.seedAccount() {
        documents["publicProfiles/UID-1"] = mapOf("displayName" to "そら")
        documents["users/UID-1"] = mapOf("email" to "a@example.com")
        documents["follows/UID-1_A"] = mapOf("followerId" to "UID-1", "followeeId" to "A")
        documents["follows/B_UID-1"] = mapOf("followerId" to "B", "followeeId" to "UID-1")
        documents["follows/C_D"] = mapOf("followerId" to "C", "followeeId" to "D")
        documents["posts/P1"] = mapOf(
            "userId" to "UID-1",
            "images" to listOf(
                mapOf(
                    "url" to "https://example.com/i1.jpg",
                    "storagePath" to "posts/UID-1/public/i1.jpg",
                    "thumbnailStoragePath" to "thumbnails/UID-1/public/i1_thumb.jpg",
                ),
            ),
            "originalImages" to listOf(mapOf("storagePath" to "originals/UID-1/public/o1.jpg")),
        )
        documents["posts/P2"] = mapOf(
            "userId" to "UID-1",
            "images" to listOf(
                mapOf(
                    "url" to downloadUrl("posts%2FUID-1%2Fprivate%2Fi2.jpg"),
                    "thumbnail" to downloadUrl("thumbnails%2FUID-1%2Fprivate%2Fi2_thumb.jpg"),
                ),
            ),
        )
        documents["posts/OTHER"] = mapOf("userId" to "X", "images" to listOf(mapOf("storagePath" to "posts/X/public/x.jpg")))
        documents["drafts/D1"] = mapOf("userId" to "UID-1", "images" to listOf(mapOf("url" to "")))
        documents["drafts/D2"] = mapOf("userId" to "X")
        documents["users/UID-1/favorites/P9"] = mapOf("postId" to "P9")
        documents["users/X/favorites/P9"] = mapOf("postId" to "P9")
        objects += OWN_POST_IMAGES
        objects += "users/UID-1/profile/profile.jpg"
        objects += "posts/X/public/x.jpg"
        objects += "users/X/profile/profile.jpg"
    }

    private fun downloadUrl(encoded: String) = "https://firebasestorage.googleapis.com/v0/b/bucket/o/$encoded?alt=media&token=t"

    // ── 成功 ──

    @Test
    fun `再認証から認証のアカウントの削除まで、iOSの順序に画像の3段階を足した順に進み、端末のデータを消してOkを返す`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), result)
        // 段階は宣言の順（設計書の 0〜9 に POST_IMAGES・PROFILE_IMAGE・STORAGE_LEFTOVERS を足した並び）に 1 回ずつ。行ったり来たりしない
        assertEquals(EXPECTED_ORDER, f.stageSequence())
        assertEquals(DeletionStage.entries.toList(), EXPECTED_ORDER)
        // 各段階の仕事。全ての仕事は、その段階が立ってから行う
        assertEquals(
            mapOf<DeletionStage?, List<String>>(
                DeletionStage.REAUTH to listOf("auth.reauthenticate"),
                DeletionStage.PUBLIC_PROFILE to listOf("firestore.delete publicProfiles/UID-1"),
                // 1 件だけ（上限の 50 件未満）なので、空を確かめるための 2 回目の取得はしない
                DeletionStage.FOLLOWS_AS_FOLLOWER to listOf("firestore.deleteAll follows/UID-1_A", "read DrainByField.FOLLOWS_AS_FOLLOWER"),
                DeletionStage.FOLLOWS_AS_FOLLOWEE to listOf("firestore.deleteAll follows/B_UID-1", "read DrainByField.FOLLOWS_AS_FOLLOWEE"),
                DeletionStage.LIKES to listOf("reactions.LIKE UID-1"),
                DeletionStage.COMMENTS to listOf("reactions.COMMENT UID-1"),
                DeletionStage.POST_IMAGES to (listOf("read AllOwned.POSTS") + OWN_POST_IMAGES.map { "storage.delete $it" }).sorted(),
                // 投稿は画像の段階とは別に、サーバーから取り直す
                DeletionStage.POSTS to listOf("firestore.deleteAll posts/P1,posts/P2", "read AllOwned.POSTS"),
                DeletionStage.DRAFTS to listOf("firestore.deleteAll drafts/D1", "read AllOwned.DRAFTS"),
                DeletionStage.FAVORITES to listOf("firestore.deleteAll users/UID-1/favorites/P9", "read AllOwned.FAVORITES"),
                DeletionStage.PROFILE_IMAGE to listOf("storage.delete users/UID-1/profile/profile.jpg"),
                // 自分の画像のフォルダ 10 個を一覧する。文書から拾った画像は消し終えているので、消すものは無い
                DeletionStage.STORAGE_LEFTOVERS to OWN_IMAGE_FOLDERS.map { "storage.list $it" }.sorted(),
                DeletionStage.USER to listOf("firestore.delete users/UID-1"),
                DeletionStage.AUTH to listOf("auth.deleteAuthAccount", "session.clearLocalUserData"),
            ),
            f.workByStage(),
        )
        // 端末のデータの消去は、認証のアカウントを消した後の最後の 1 回
        assertEquals("session.clearLocalUserData", f.whats().last())
        assertEquals(listOf(PASSWORD), f.auth.passwords)
        // 残るのは他人のデータだけ
        assertEquals(setOf("follows/C_D", "posts/OTHER", "drafts/D2", "users/X/favorites/P9"), f.backend.documents.keys)
        assertEquals(setOf("posts/X/public/x.jpg", "users/X/profile/profile.jpg"), f.backend.objects)
        assertEquals(emptyList(), f.analytics.errors)
        assertEquals(null, f.service.stage.value)
    }

    @Test
    fun `stageは各段階の仕事の前に立ち、終わるとnullに戻る`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val seen = mutableListOf<DeletionStage?>()
        val collector = launch(Dispatchers.Unconfined) { f.service.stage.collect { seen += it } }

        f.service.delete(PASSWORD)
        collector.cancel()

        // 実行していない間は null → 再認証から認証のアカウントの削除まで順に → 終わったら null
        assertEquals(listOf<DeletionStage?>(null) + EXPECTED_ORDER + listOf(null), seen)
        assertEquals(null, f.service.stage.value)
    }

    @Test
    fun `取得は全てサーバーから行う`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()

        f.service.delete(PASSWORD)

        assertTrue(f.backend.queries.isNotEmpty())
        assertEquals(listOf(ReadSource.SERVER), f.backend.queries.map { it.second }.distinct())
        assertEquals(
            listOf(
                QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWER, uid),
                QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWEE, uid),
                QuerySpec.AllOwned(OwnedCollection.POSTS, uid),
                QuerySpec.AllOwned(OwnedCollection.POSTS, uid),
                QuerySpec.AllOwned(OwnedCollection.DRAFTS, uid),
                QuerySpec.AllOwned(OwnedCollection.FAVORITES, uid),
            ),
            f.backend.queries.map { it.first },
        )
    }

    // ── 再認証・未ログイン ──

    @Test
    fun `再認証に失敗したら、データの削除を一切始めず、REAUTHの失敗として記録して返す`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val before = f.backend.documents.toMap() to f.backend.objects.toSet()
        val cause = AppError.Auth(AuthErrorKind.WRONG_PASSWORD)
        f.auth.reauthResult = AppResult.Err(cause)

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.REAUTH, cause)), result)
        // 再認証だけで、取得も Firestore・Storage・認証のアカウントの削除・端末のデータの消去も無い
        assertEquals(listOf("auth.reauthenticate"), f.whats())
        assertEquals(before, f.backend.documents.toMap() to f.backend.objects.toSet())
        assertEquals(listOf(LoggedError(AppError.StageFailed(DeletionStage.REAUTH, cause), "AccountDeletionService.delete.reauth")), f.analytics.errors)
        assertEquals(null, f.service.stage.value)
    }

    @Test
    fun `ログインしていなければ、再認証もせずにPermissionDeniedを記録して返す`() = runBlocking {
        val f = Fixture(signedIn = null)
        f.backend.seedAccount()

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(emptyList(), f.backend.events)
        assertEquals(listOf(LoggedError(AppError.PermissionDenied, "AccountDeletionService.delete")), f.analytics.errors)
    }

    // ── 端末の編集のデータの後始末（タスク 17・design.md:963）──

    @Test
    fun `全ての段階と端末のデータの消去が終わった後に、退会として後始末を呼ぶ`() = runBlocking {
        val f = Fixture(withPurger = true)
        f.backend.seedAccount()

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(uid to SessionEndReason.ACCOUNT_DELETED), f.purged)
        // 認証のアカウントの削除（最後の段階）→ 端末内のデータの消去 → 編集のデータの後始末、の順。後始末が最後
        assertEquals(listOf("auth.deleteAuthAccount", "session.clearLocalUserData", "purge UID-1 ACCOUNT_DELETED"), f.whats().takeLast(3))
        assertEquals(emptyList(), f.analytics.errors)
    }

    @Test
    fun `どの段階が失敗しても、後始末は呼ばない（アカウントが残っているのに下書きを消さない）`() = runBlocking {
        val injections: List<Pair<DeletionStage, (Fixture) -> Unit>> = listOf(
            DeletionStage.REAUTH to { f: Fixture -> f.auth.reauthResult = AppResult.Err(AppError.Auth(AuthErrorKind.WRONG_PASSWORD)) },
            DeletionStage.POSTS to { f: Fixture -> f.backend.writeFailure = { _, paths -> AppError.Network.takeIf { "posts/P1" in paths } } },
            DeletionStage.AUTH to { f: Fixture -> f.auth.deleteResult = AppResult.Err(AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN)) },
        )

        injections.forEach { (stage, inject) ->
            val f = Fixture(withPurger = true)
            f.backend.seedAccount()
            inject(f)

            val result = f.service.delete(PASSWORD)

            assertTrue(result is AppResult.Err, "$stage")
            assertEquals(emptyList(), f.purged, "$stage")
            assertFalse(f.whats().any { it.startsWith("purge ") }, "$stage")
        }
    }

    @Test
    fun `ログインしていなければ、後始末も呼ばない`() = runBlocking {
        val f = Fixture(signedIn = null, withPurger = true)

        f.service.delete(PASSWORD)

        assertEquals(emptyList(), f.purged)
    }

    // ── 各段階の失敗 ──

    @Test
    fun `どの段階で失敗しても、以降の段階と認証のアカウントの削除を行わず、段階名つきで1回だけ記録して返す`() = runBlocking {
        // 段階ごとに、その段階の仕事だけを失敗させる差し込み（原因は段階ごとに変えて、取り違えを見分ける）
        val injections: List<Triple<DeletionStage, AppError, (Fixture) -> Unit>> = listOf(
            Triple(DeletionStage.PUBLIC_PROFILE, AppError.Network) { f ->
                f.backend.writeFailure = { _, paths -> AppError.Network.takeIf { "publicProfiles/UID-1" in paths } }
            },
            Triple(DeletionStage.FOLLOWS_AS_FOLLOWER, AppError.Network) { f ->
                f.backend.queryFailure = { spec -> AppError.Network.takeIf { spec == QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWER, uid) } }
            },
            Triple(DeletionStage.FOLLOWS_AS_FOLLOWEE, AppError.PermissionDenied) { f ->
                f.backend.writeFailure = { _, paths -> AppError.PermissionDenied.takeIf { "follows/B_UID-1" in paths } }
            },
            Triple(DeletionStage.LIKES, AppError.Network) { f -> f.reactions.results = mapOf(ReactionKind.LIKE to AppResult.Err(AppError.Network)) },
            Triple(DeletionStage.COMMENTS, AppError.Unknown("x")) { f ->
                f.reactions.results = mapOf(ReactionKind.COMMENT to AppResult.Err(AppError.Unknown("x")))
            },
            Triple(DeletionStage.POST_IMAGES, AppError.PermissionDenied) { f ->
                f.backend.storageFailure = { path -> AppError.PermissionDenied.takeIf { path == "posts/UID-1/public/i1.jpg" } }
            },
            Triple(DeletionStage.POSTS, AppError.Network) { f ->
                f.backend.writeFailure = { _, paths -> AppError.Network.takeIf { "posts/P1" in paths } }
            },
            Triple(DeletionStage.DRAFTS, AppError.Network) { f ->
                f.backend.queryFailure = { spec -> AppError.Network.takeIf { spec == QuerySpec.AllOwned(OwnedCollection.DRAFTS, uid) } }
            },
            Triple(DeletionStage.FAVORITES, AppError.Unknown("y")) { f ->
                f.backend.writeFailure = { _, paths -> AppError.Unknown("y").takeIf { "users/UID-1/favorites/P9" in paths } }
            },
            Triple(DeletionStage.PROFILE_IMAGE, AppError.Network) { f ->
                f.backend.storageFailure = { path -> AppError.Network.takeIf { path == "users/UID-1/profile/profile.jpg" } }
            },
            Triple(DeletionStage.STORAGE_LEFTOVERS, AppError.PermissionDenied) { f ->
                f.backend.listFailure = { folder -> AppError.PermissionDenied.takeIf { folder == "posts/UID-1/private" } }
            },
            Triple(DeletionStage.USER, AppError.Network) { f ->
                f.backend.writeFailure = { _, paths -> AppError.Network.takeIf { "users/UID-1" in paths } }
            },
            Triple(DeletionStage.AUTH, AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN)) { f ->
                f.auth.deleteResult = AppResult.Err(AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN))
            },
        )
        // 再認証の後の全ての段階を、漏れなく試している
        assertEquals(DeletionStage.entries.drop(1), injections.map { it.first })

        injections.forEach { (stage, cause, inject) ->
            val f = Fixture()
            f.backend.seedAccount()
            inject(f)

            val result = f.service.delete(PASSWORD)

            assertEquals(AppResult.Err(AppError.StageFailed(stage, cause)), result, "$stage")
            // その段階までは順に進み、以降の段階は 1 つも立っていない
            assertEquals(EXPECTED_ORDER.take(EXPECTED_ORDER.indexOf(stage) + 1), f.stageSequence(), "$stage")
            if (stage != DeletionStage.AUTH) assertFalse("auth.deleteAuthAccount" in f.whats(), "$stage")
            assertFalse("session.clearLocalUserData" in f.whats(), "$stage")
            assertEquals(
                listOf(LoggedError(AppError.StageFailed(stage, cause), "AccountDeletionService.delete.${stage.name.lowercase()}")),
                f.analytics.errors,
                "$stage",
            )
            assertEquals(null, f.service.stage.value, "$stage")
        }
    }

    // ── 認証のアカウントの削除の呼び直し（レビュー F11）──
    // 再認証は最初の 1 回だけなので、データの多いアカウントではデータの段階の間に「最近のログイン」の窓を過ぎ、
    // 最後の AUTH が REQUIRES_RECENT_LOGIN で断られうる。そのときは手元のパスワードで 1 回だけ再認証して呼び直す

    /** AUTH の段階の中で起きた仕事を、起きた順に（段階の中の順を見るので並べ替えない）。 */
    private fun Fixture.authStageWork(): List<String> = backend.events.filter { it.stage == DeletionStage.AUTH }.map { it.what }

    @Test
    fun `認証のアカウントの削除が最近のログインを求めたら、手元のパスワードで1回だけ再認証して呼び直し、1回のdeleteでOkにする`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        f.auth.deleteResults += AppResult.Err(AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN))

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), result)
        // 呼び直しは AUTH の段階の中で行い、段階は行ったり来たりしない（REAUTH に戻らない）
        assertEquals(EXPECTED_ORDER, f.stageSequence())
        assertEquals(
            listOf("auth.deleteAuthAccount", "auth.reauthenticate", "auth.deleteAuthAccount", "session.clearLocalUserData"),
            f.authStageWork(),
        )
        // 最初の再認証と同じ、delete に渡されたパスワードで再認証する
        assertEquals(listOf(PASSWORD, PASSWORD), f.auth.passwords)
        // 呼び直して成功したので、失敗の記録は増えない
        assertEquals(emptyList(), f.analytics.errors)
        assertEquals(null, f.service.stage.value)
    }

    @Test
    fun `呼び直す前の再認証に失敗したら、その失敗をAUTHの失敗として返し、端末のデータは消さない`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val cause = AppError.Auth(AuthErrorKind.NETWORK)
        f.auth.deleteResults += AppResult.Err(AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN))
        // 最初の再認証（REAUTH の段階）は通り、呼び直す前の 2 回目だけが失敗する
        f.auth.reauthResults += AppResult.Ok(Unit)
        f.auth.reauthResults += AppResult.Err(cause)

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.AUTH, cause)), result)
        // 再認証に失敗したら、認証のアカウントの削除は呼び直さない
        assertEquals(listOf("auth.deleteAuthAccount", "auth.reauthenticate"), f.authStageWork())
        assertFalse("session.clearLocalUserData" in f.whats())
        assertEquals(listOf(LoggedError(AppError.StageFailed(DeletionStage.AUTH, cause), "AccountDeletionService.delete.auth")), f.analytics.errors)
        assertEquals(null, f.service.stage.value)
    }

    @Test
    fun `呼び直しても最近のログインを求められたら、それ以上は繰り返さずにAUTHの失敗として返す`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val cause = AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN)
        f.auth.deleteResult = AppResult.Err(cause)

        val result = f.service.delete(PASSWORD)

        // 退会の画面は、この失敗に「もう一度パスワードを入れて再試行」の案内を出す（AccountDeletionMessages）
        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.AUTH, cause)), result)
        assertEquals(listOf("auth.deleteAuthAccount", "auth.reauthenticate", "auth.deleteAuthAccount"), f.authStageWork())
        assertFalse("session.clearLocalUserData" in f.whats())
        assertEquals(listOf(LoggedError(AppError.StageFailed(DeletionStage.AUTH, cause), "AccountDeletionService.delete.auth")), f.analytics.errors)
    }

    @Test
    fun `画像の削除は1つ失敗しても残りを試してから、POST_IMAGESの失敗にする`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        f.backend.storageFailure = { path -> AppError.PermissionDenied.takeIf { path == "posts/UID-1/public/i1.jpg" } }

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.POST_IMAGES, AppError.PermissionDenied)), result)
        // 5 つとも試し、失敗した 1 つ以外は消えている（再試行で消す数を減らす）
        assertEquals(OWN_POST_IMAGES.map { "storage.delete $it" }.sorted(), f.whats().filter { it.startsWith("storage.") }.sorted())
        assertEquals(setOf("posts/UID-1/public/i1.jpg"), f.backend.objects.intersect(OWN_POST_IMAGES.toSet()))
        // 投稿の文書は消していない（画像のパスを失わない）
        assertTrue("posts/P1" in f.backend.documents && "posts/P2" in f.backend.documents)
    }

    @Test
    fun `返事の無い画像の削除は上限で打ち切り、NetworkでPOST_IMAGESの失敗にする`() = runBlocking {
        val f = Fixture(imageDeleteTimeout = 50.milliseconds)
        f.backend.seedAccount()
        val gate = CompletableDeferred<Unit>()
        f.backend.storageHang = { path -> gate.takeIf { path == "thumbnails/UID-1/public/i1_thumb.jpg" } }
        // 見張り：上限が効かない改変を当てても、5 秒で待ちを外してテストを赤で終わらせる（消し始めた後は取り消さないので外からは止められない）
        val watchdog = launch {
            delay(5.seconds)
            gate.complete(Unit)
        }
        try {
            val result = f.service.delete(PASSWORD)

            assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.POST_IMAGES, AppError.Network)), result)
            assertEquals(
                listOf(LoggedError(AppError.StageFailed(DeletionStage.POST_IMAGES, AppError.Network), "AccountDeletionService.delete.post_images")),
                f.analytics.errors,
            )
            assertFalse("auth.deleteAuthAccount" in f.whats())
        } finally {
            watchdog.cancel()
            gate.complete(Unit)
        }
    }

    // ── 残っている画像（タスク 31.6・レビュー F20）──

    @Test
    fun `文書から拾えなかった画像は、自分の画像のフォルダを一覧して消し、他人の画像と下のフォルダには触らない`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        // 文書の無い画像・パスを解決できなかった画像・アイコンのフォルダの別名
        val orphans = listOf(
            "posts/UID-1/followers/orphan.jpg",
            "thumbnails/UID-1/private/orphan_thumb.jpg",
            "originals/UID-1/followers/o2.jpg",
            "users/UID-1/profile/old.jpg",
        )
        f.backend.objects += orphans
        // 他人の同じ形のフォルダの画像と、一覧の対象でない場所は残る
        f.backend.objects += "posts/X/followers/x2.jpg"
        f.backend.objects += "users/UID-1/profile.jpg"

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(
            (OWN_IMAGE_FOLDERS.map { "storage.list $it" } + orphans.map { "storage.delete $it" }).sorted(),
            f.workByStage()[DeletionStage.STORAGE_LEFTOVERS],
        )
        assertEquals(
            setOf("posts/X/public/x.jpg", "users/X/profile/profile.jpg", "posts/X/followers/x2.jpg", "users/UID-1/profile.jpg"),
            f.backend.objects,
        )
        assertEquals(emptyList(), f.analytics.errors)
    }

    @Test
    fun `返事の無いフォルダの一覧は上限で打ち切り、NetworkでSTORAGE_LEFTOVERSの失敗にして、アカウントを消さない`() = runBlocking {
        val f = Fixture(imageDeleteTimeout = 50.milliseconds)
        f.backend.seedAccount()
        f.backend.objects += "posts/UID-1/followers/orphan.jpg"
        val gate = CompletableDeferred<Unit>()
        f.backend.listHang = { folder -> gate.takeIf { folder == "originals/UID-1/public" } }
        // 見張り：上限が効かない改変を当てても、5 秒で待ちを外してテストを赤で終わらせる（消し始めた後は取り消さないので外からは止められない）
        val watchdog = launch {
            delay(5.seconds)
            gate.complete(Unit)
        }
        try {
            val result = f.service.delete(PASSWORD)

            assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.STORAGE_LEFTOVERS, AppError.Network)), result)
            assertEquals(
                listOf(
                    LoggedError(AppError.StageFailed(DeletionStage.STORAGE_LEFTOVERS, AppError.Network), "AccountDeletionService.delete.storage_leftovers"),
                ),
                f.analytics.errors,
            )
            // 一覧しきれないうちは消さない（取りこぼしたまま認証のアカウントまで消さない）
            assertTrue("posts/UID-1/followers/orphan.jpg" in f.backend.objects)
            assertTrue("users/UID-1" in f.backend.documents)
            assertFalse("auth.deleteAuthAccount" in f.whats())
        } finally {
            watchdog.cancel()
            gate.complete(Unit)
        }
    }

    @Test
    fun `部品が約束を破って例外を投げても、アプリを落とさずにその段階の失敗にする`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        f.reactions.throwOn = ReactionKind.LIKE

        val result = f.service.delete(PASSWORD)

        val failure = AppError.StageFailed(DeletionStage.LIKES, AppError.Unknown("IllegalStateException"))
        assertEquals(AppResult.Err(failure), result)
        assertEquals(listOf(LoggedError(failure, "AccountDeletionService.delete.likes")), f.analytics.errors)
        assertFalse("reactions.COMMENT UID-1" in f.whats())
    }

    @Test
    fun `書き込みの入口が断って記録済みのWriteBlockedは、記録し直さずに段階の失敗として返す`() = runBlocking {
        val f = Fixture(enabled = ALL_WRITES_ENABLED - WriteCapability.ACCOUNT_DELETE)
        f.backend.seedAccount()

        val result = f.service.delete(PASSWORD)

        val blocked = AppError.WriteBlocked(WriteCapability.ACCOUNT_DELETE)
        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.PUBLIC_PROFILE, blocked)), result)
        // 入口が自分で記録した 1 件だけ（リリースを止める根拠になる件数を二重にしない）
        assertEquals(listOf(LoggedError(blocked, "FirestoreWriteGateway.delete")), f.analytics.errors)
        assertFalse(f.whats().any { it.startsWith("firestore.") || it.startsWith("storage.") })
    }

    @Test
    fun `入口が断って記録済みのShapeViolationも、記録し直さずに段階の失敗として返す`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        // いいねの部品が、カウンタの書き込みを入口に形の違反で断られた（本物なら入口がその場で記録済み。偽物の部品なので、ここに入口の記録は出ない）。
        // 退会の書き込みの形は決まっている（-1 だけ）ので普段は起きない、防御のための枝
        val violation = AppError.ShapeViolation(listOf(Violation.UnexpectedKey("commentsCount")))
        f.reactions.results = mapOf(ReactionKind.LIKE to AppResult.Err(violation))

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.LIKES, violation)), result)
        // 手順の本体は記録しない（入口の 1 件だけにして、リリースを止める根拠になる件数を二重にしない）
        assertEquals(emptyList(), f.analytics.errors)
        assertFalse(f.whats().any { it == "reactions.COMMENT UID-1" || it == "auth.deleteAuthAccount" })
    }

    // ── フォローの繰り返しと打ち切り・投稿の 500 件ずつ ──

    @Test
    fun `フォローは50件ずつ消し、上限未満のページで取り直さずに終える`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        repeat(119) { i -> f.backend.documents["follows/UID-1_F$i"] = mapOf("followerId" to "UID-1", "followeeId" to "F$i") }

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), result)
        // 自分がフォローした 120 件（もとの 1 件＋ 119 件）は 50・50・20 の 3 回で消え、4 回目の取得はしない
        val followerReads = f.backend.queries.count { it.first == QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWER, uid) }
        assertEquals(3, followerReads)
        assertEquals(listOf(50, 50, 20, 1), f.backend.batches.filter { batch -> batch.all { it.startsWith("follows/") } }.map { it.size })
        assertEquals(setOf("follows/C_D"), f.backend.documents.keys.filter { it.startsWith("follows/") }.toSet())
    }

    @Test
    fun `フォローが200ページで空にならなければ打ち切って失敗とし、以降の段階に進まない`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        repeat(49) { i -> f.backend.documents["follows/UID-1_F$i"] = mapOf("followerId" to "UID-1", "followeeId" to "F$i") }
        // 削除が黙って効かない（毎回同じ 50 件が返る）
        f.backend.frozen = true

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.FOLLOWS_AS_FOLLOWER, DRAIN_EXCEEDED)), result)
        assertEquals(200, f.backend.queries.count { it.first == QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWER, uid) })
        assertEquals(200, f.backend.batches.size)
        assertFalse(f.backend.queries.any { it.first == QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWEE, uid) })
        assertFalse("auth.deleteAuthAccount" in f.whats())
        assertEquals(
            listOf(LoggedError(AppError.StageFailed(DeletionStage.FOLLOWS_AS_FOLLOWER, DRAIN_EXCEEDED), "AccountDeletionService.delete.follows_as_follower")),
            f.analytics.errors,
        )
    }

    @Test
    fun `フォローされた側も200ページで空にならなければ打ち切って失敗とし、以降の段階に進まない`() = runBlocking {
        val f = Fixture()
        // 自分がフォローした側（followerId）は 0 件、フォローされた側（followeeId）だけが上限ちょうどの 50 件。
        // 上のテストは、フォローした側が先に打ち切られて 2 つ目の向きに届かない（frozen は記憶域全体に効く）ので、
        // 2 つ目の向きの打ち切りと、その段階名（FOLLOWS_AS_FOLLOWEE）はここで確かめる
        repeat(50) { i -> f.backend.documents["follows/Y${i}_UID-1"] = mapOf("followerId" to "Y$i", "followeeId" to "UID-1") }
        // 削除が黙って効かない（毎回同じ 50 件が返る）
        f.backend.frozen = true

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.FOLLOWS_AS_FOLLOWEE, DRAIN_EXCEEDED)), result)
        // フォローした側は 0 件を 1 回確かめて終え、フォローされた側が 200 回取って 200 回消そうとした
        assertEquals(1, f.backend.queries.count { it.first == QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWER, uid) })
        assertEquals(200, f.backend.queries.count { it.first == QuerySpec.DrainByField(DrainTarget.FOLLOWS_AS_FOLLOWEE, uid) })
        assertEquals(200, f.backend.batches.size)
        // 次の段階（いいね）以降は始めず、認証のアカウントの削除も端末のデータの消去もしない
        assertEquals(
            listOf(DeletionStage.REAUTH, DeletionStage.PUBLIC_PROFILE, DeletionStage.FOLLOWS_AS_FOLLOWER, DeletionStage.FOLLOWS_AS_FOLLOWEE),
            f.stageSequence(),
        )
        assertFalse(f.backend.queries.any { it.first == QuerySpec.DrainByField(DrainTarget.LIKES, uid) })
        assertFalse(f.whats().any { it.startsWith("reactions.") || it == "auth.deleteAuthAccount" || it == "session.clearLocalUserData" })
        assertEquals(
            listOf(LoggedError(AppError.StageFailed(DeletionStage.FOLLOWS_AS_FOLLOWEE, DRAIN_EXCEEDED), "AccountDeletionService.delete.follows_as_followee")),
            f.analytics.errors,
        )
    }

    @Test
    fun `投稿は500件ずつの一括削除で消す`() = runBlocking {
        val f = Fixture()
        repeat(1201) { i -> f.backend.documents["posts/P$i"] = mapOf("userId" to "UID-1") }

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(listOf(500, 500, 201), f.backend.batches.filter { batch -> batch.all { it.startsWith("posts/") } }.map { it.size })
        assertEquals(emptySet(), f.backend.documents.keys)
    }

    // ── 冪等（再試行で続きから） ──

    @Test
    fun `既に何も無いアカウントでも全ての段階を通ってOkを返す（無いものの削除は成功）`() = runBlocking {
        val f = Fixture()

        val result = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), result)
        assertEquals(EXPECTED_ORDER, f.stageSequence())
        // アイコンは無くても消しに行き、不在は成功とみなす
        assertTrue("storage.delete users/UID-1/profile/profile.jpg" in f.whats())
        // 消すものが無いコレクションには一括削除を送らない
        assertEquals(emptyList(), f.backend.batches)
        assertEquals(emptyList(), f.analytics.errors)
    }

    @Test
    fun `途中で失敗した後の再試行は、残りを消して終える`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        f.backend.writeFailure = { _, paths -> AppError.Network.takeIf { "drafts/D1" in paths } }
        val first = f.service.delete(PASSWORD)
        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.DRAFTS, AppError.Network)), first)
        // 1 回目で画像も投稿も消えている。2 回目は無い画像・無い文書の削除を成功とみなして進む
        f.backend.writeFailure = { _, _ -> null }
        f.backend.events.clear()

        val second = f.service.delete(PASSWORD)

        assertEquals(AppResult.Ok(Unit), second)
        assertEquals(EXPECTED_ORDER, f.stageSequence())
        assertEquals(setOf("follows/C_D", "posts/OTHER", "drafts/D2", "users/X/favorites/P9"), f.backend.documents.keys)
        assertEquals(setOf("posts/X/public/x.jpg", "users/X/profile/profile.jpg"), f.backend.objects)
        // 記録は 1 回目の失敗の 1 件だけ
        assertEquals(1, f.analytics.errors.size)
    }

    // ── 取り消し ──

    @Test
    fun `再認証の後で取り消されても、最後まで消して端末のデータを消す`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val gate = CompletableDeferred<Unit>()
        f.reactions.likesGate = gate
        val job = launch(Dispatchers.Unconfined) { f.service.delete(PASSWORD) }
        try {
            // いいねの段階で止まっている（公開プロフィールとフォローは消した）
            assertEquals(DeletionStage.LIKES, f.service.stage.value)
            job.cancel()
        } finally {
            // 上の確かめが失敗しても待ちを外す（消し始めた後は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            gate.complete(Unit)
        }
        job.join()

        assertEquals(EXPECTED_ORDER, f.stageSequence())
        assertEquals("session.clearLocalUserData", f.whats().last())
        assertEquals(null, f.service.stage.value)
    }

    @Test
    fun `再認証の間に取り消されたら、データには触れずに止まる`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val gate = CompletableDeferred<Unit>()
        f.auth.reauthGate = gate
        // 見張り：取り消せない範囲が再認証まで広がる改変を当てても、5 秒で待ちを外してテストを赤で終わらせる
        // （外さないと、取り消しで再認証の待ちが外れず join が戻らないので、赤でなく止まりになる。外れると退会が進み、下の確かめが赤になる）
        val watchdog = launch {
            delay(5.seconds)
            gate.complete(Unit)
        }
        try {
            val job = launch(Dispatchers.Unconfined) { f.service.delete(PASSWORD) }
            assertEquals(DeletionStage.REAUTH, f.service.stage.value)

            job.cancel()
            job.join()

            assertEquals(listOf("auth.reauthenticate"), f.whats())
            assertEquals(emptyList(), f.analytics.errors)
            assertEquals(null, f.service.stage.value)
        } finally {
            // 上の確かめが取り消しの前に失敗しても待ちを外す（外さないと runBlocking が子を待ち続けて止まる）
            watchdog.cancel()
            gate.complete(Unit)
        }
    }

    // ── 退会の途中の、他の画面からの書き込み（確かめる係の指摘の直し） ──

    @Test
    fun `退会の途中（いいねの段階）に補完を呼んでも、消した公開プロフィールを作り直さず、最後にはどちらも残らない`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val gate = CompletableDeferred<Unit>()
        f.reactions.likesGate = gate
        val deletion = launch(Dispatchers.Unconfined) { assertEquals(AppResult.Ok(Unit), f.service.delete(PASSWORD)) }
        val repaired = try {
            // いいねの段階で止まっている（公開プロフィールは消し、users はまだある）。利用者が自分のプロフィールを開いた
            assertEquals(DeletionStage.LIKES, f.service.stage.value)
            assertFalse("publicProfiles/UID-1" in f.backend.documents)
            f.repairer.ensureAccountDocuments()
        } finally {
            // 上の確かめが失敗しても待ちを外す（消し始めた後は取り消さないので、外さないと runBlocking が子を待ち続けて止まる）
            gate.complete(Unit)
        }
        deletion.join()

        // 入口が Firebase に届けずに断った（トランザクションを始めていない）
        assertEquals(AppResult.Err(AppError.PermissionDenied), repaired)
        assertFalse(f.whats().any { it.startsWith("firestore.commit") || it.startsWith("firestore.set") })
        assertTrue(LoggedError(AppError.PermissionDenied, "FirestoreWriteGateway.transaction.during_account_delete") in f.analytics.errors)
        // 退会は最後まで進み、公開プロフィールも users も残っていない
        assertEquals(EXPECTED_ORDER, f.stageSequence())
        assertFalse("publicProfiles/UID-1" in f.backend.documents)
        assertFalse("users/UID-1" in f.backend.documents)
    }

    @Test
    fun `退会の途中（認証のアカウントを消す直前）に補完を呼んでも、メールアドレス入りのusersも公開プロフィールも作らない`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val gate = CompletableDeferred<Unit>()
        f.auth.deleteGate = gate
        val deletion = launch(Dispatchers.Unconfined) { assertEquals(AppResult.Ok(Unit), f.service.delete(PASSWORD)) }
        val repaired = try {
            // users まで消し終え、認証のアカウントの削除を待っている
            assertEquals(DeletionStage.AUTH, f.service.stage.value)
            assertFalse("users/UID-1" in f.backend.documents)
            f.repairer.ensureAccountDocuments()
        } finally {
            gate.complete(Unit)
        }
        deletion.join()

        assertEquals(AppResult.Err(AppError.PermissionDenied), repaired)
        assertFalse("users/UID-1" in f.backend.documents)
        assertFalse("publicProfiles/UID-1" in f.backend.documents)
        assertEquals("session.clearLocalUserData", f.whats().last())
    }

    @Test
    fun `退会の途中は投稿の画像のアップロードを断り、消す書き込みは通す`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        val gate = CompletableDeferred<Unit>()
        f.reactions.likesGate = gate
        val newImage = StoragePath("posts/UID-1/public/new.jpg")
        f.backend.objects += "posts/UID-1/public/rollback.jpg"
        val deletion = launch(Dispatchers.Unconfined) { assertEquals(AppResult.Ok(Unit), f.service.delete(PASSWORD)) }
        val (uploaded, rolledBack) = try {
            assertEquals(DeletionStage.LIKES, f.service.stage.value)
            // 投稿の画面で送信中だった投稿が、次の画像を上げようとした。続けて、投稿の後片付け（上げた画像を消す。可否は投稿の作成と同じ）
            f.storage.uploadJpeg(WriteCapability.POST_CREATE, newImage, ByteArray(16), index = 0) to
                f.storage.delete(WriteCapability.POST_CREATE, StoragePath("posts/UID-1/public/rollback.jpg"))
        } finally {
            gate.complete(Unit)
        }
        deletion.join()

        assertEquals(AppResult.Err(AppError.PermissionDenied), uploaded)
        assertFalse(f.whats().any { it.startsWith("storage.put") }, "断ったのに Storage に届いた")
        assertFalse(newImage.value in f.backend.objects)
        assertTrue(LoggedError(AppError.PermissionDenied, "StorageGateway.uploadJpeg.during_account_delete") in f.analytics.errors)
        assertEquals(AppResult.Ok(Unit), rolledBack)
        assertFalse("posts/UID-1/public/rollback.jpg" in f.backend.objects)
    }

    @Test
    fun `失敗で終わった退会の後は、他の書き込みを断らない（アカウントは残っているので使い続けられる）`() = runBlocking {
        val f = Fixture()
        f.backend.seedAccount()
        f.reactions.results = mapOf(ReactionKind.LIKE to AppResult.Err(AppError.Network))

        val failed = f.service.delete(PASSWORD)
        val repaired = f.repairer.ensureAccountDocuments()

        assertEquals(AppResult.Err(AppError.StageFailed(DeletionStage.LIKES, AppError.Network)), failed)
        // 消した公開プロフィールを補完が作り直せる（区間を出ている）
        assertEquals(AppResult.Ok(RepairOutcome.CREATED_PUBLIC_PROFILE), repaired)
        assertTrue("publicProfiles/UID-1" in f.backend.documents)
        assertFalse(f.analytics.errors.any { it.context.contains(".during_") })
    }

    private companion object {
        const val PASSWORD = "pw-31.2"

        /** 設計書の手順 0〜9 に、投稿の画像（5 の前）とアイコン画像・残っている画像（8 の前。残っている画像はタスク 31.6）を足した順。 */
        val EXPECTED_ORDER: List<DeletionStage?> = listOf(
            DeletionStage.REAUTH,
            DeletionStage.PUBLIC_PROFILE,
            DeletionStage.FOLLOWS_AS_FOLLOWER,
            DeletionStage.FOLLOWS_AS_FOLLOWEE,
            DeletionStage.LIKES,
            DeletionStage.COMMENTS,
            DeletionStage.POST_IMAGES,
            DeletionStage.POSTS,
            DeletionStage.DRAFTS,
            DeletionStage.FAVORITES,
            DeletionStage.PROFILE_IMAGE,
            DeletionStage.STORAGE_LEFTOVERS,
            DeletionStage.USER,
            DeletionStage.AUTH,
        )

        /**
         * 段階 STORAGE_LEFTOVERS が一覧する UID-1 の画像のフォルダ（投稿の画像の 9 つとアイコンの 1 つ）。
         * 写しの関数（ownImageFolders）で作ると同じ関数どうしの比較になるので、ここに書き下す。
         */
        val OWN_IMAGE_FOLDERS = listOf(
            "posts/UID-1/public", "posts/UID-1/followers", "posts/UID-1/private",
            "thumbnails/UID-1/public", "thumbnails/UID-1/followers", "thumbnails/UID-1/private",
            "originals/UID-1/public", "originals/UID-1/followers", "originals/UID-1/private",
            "users/UID-1/profile",
        )

        /** UID-1 の投稿の画像（P1 の本体・サムネイル・元画像と、P2 の URL から解決する本体・サムネイル）。 */
        val OWN_POST_IMAGES = listOf(
            "posts/UID-1/public/i1.jpg",
            "thumbnails/UID-1/public/i1_thumb.jpg",
            "originals/UID-1/public/o1.jpg",
            "posts/UID-1/private/i2.jpg",
            "thumbnails/UID-1/private/i2_thumb.jpg",
        )
    }
}
