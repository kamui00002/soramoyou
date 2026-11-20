// ⭐️ 欠けているアカウント文書の補完の単体テスト（タスク 14.3・要件 2.2・2.11・3.7）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.UserProfileFields
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.write.FakeFirestoreWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteFailure
import com.yoshidometoru.soramoyou.data.remote.write.RecordingAnalytics
import java.io.File
import java.io.IOException
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlin.coroutines.cancellation.CancellationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking

/**
 * 補完が、`users`・`publicProfiles` のうち**欠けている文書だけ**を、1 つのトランザクションの中で読んでから作ることを確かめる
 * （設計書 :752・要件 3.7）。本物の書き込みの入口と本物の契約の上で動かし、偽物にするのは Firestore の SDK への継ぎ目と、
 * 認証のアカウントの確かめの口（verifyAccount。AppContainer が渡す reload の配線は、ソースの書き方で別に確かめる）だけ。
 */
class AccountDocumentRepairerTest {

    private val uid = Uid("UID-1")
    private val email = "sora@example.com"
    private val now: Instant = Instant.parse("2026-10-05T04:05:06Z")
    private val analytics = RecordingAnalytics()
    private val outcomes = mutableListOf<RepairOutcome>()

    private val userPath = "users/UID-1"
    private val profilePath = "publicProfiles/UID-1"

    /** `users` にあるアイコンの URL。本番の Storage のダウンロード URL の形（書き込みの契約は、この形の画像 URL だけを通す）。 */
    private val photoUrl =
        "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/users%2FUID-1%2Fprofile%2Fprofile.jpg?alt=media&token=t"

    /** `users` にある値。公開してはならない値（fcmToken など）も混ぜて、写されないことを確かめる。 */
    private val userData: Map<String, Any?> = mapOf(
        "id" to "UID-1",
        "email" to email,
        "displayName" to "空見",
        "photoURL" to photoUrl,
        "bio" to "空が好き",
        "followersCount" to 5L,
        "followingCount" to 3L,
        "postsCount" to 12L,
        "fcmToken" to "SECRET-TOKEN",
        "fcmTokenUpdatedAt" to "2026-01-01",
        "blockedUserIds" to listOf("X"),
        "followedTags" to listOf("夕焼け"),
        "notifyReactions" to true,
    )

    private fun existingUser(data: Map<String, Any?> = userData) = mapOf(userPath to RawDocument("UID-1", data))

    private fun existingProfile() = mapOf(profilePath to RawDocument("UID-1", mapOf("id" to "UID-1")))

    /** 認証のアカウントの確かめ（verifyAccount）が呼ばれた回数。 */
    private var verifyCalls = 0

    /** @param accountExists 認証のアカウントがサーバーに残っていると確かめられるか（確かめの口が返す値）。 */
    private fun repairer(
        client: FakeFirestoreWriteClient,
        enabled: Set<WriteCapability> = ALL_WRITES_ENABLED,
        signedIn: SessionState.SignedIn? = SessionState.SignedIn(uid, email, isAnonymous = false),
        accountExists: Boolean = true,
    ) = DefaultAccountDocumentRepairer(
        gateway = realWriteGateway(client, analytics, enabled, signedInUid = signedIn?.uid),
        analytics = analytics,
        currentUser = { signedIn },
        clock = Clock.fixed(now, ZoneOffset.UTC),
        recordOutcome = { outcomes += it },
        verifyAccount = {
            verifyCalls++
            accountExists
        },
    )

    /** 書き込み（tx.set）が行われた先のパスを順に。 */
    private fun FakeFirestoreWriteClient.writtenPaths(): List<String> =
        calls.filter { it.operation == "tx.set" }.map { it.paths.single() }

    private fun FakeFirestoreWriteClient.writtenDoc(path: String) =
        calls.single { it.operation == "tx.set" && it.paths == listOf(path) }.data.orEmpty()

    // ── 結果の 4 通り：欠けている文書だけを作る ──

    @Test
    fun `どちらもあれば、何も書かずALREADY_PRESENTを返す`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existingUser() + existingProfile())

        val result = repairer(client).ensureAccountDocuments()

        assertEquals(AppResult.Ok(RepairOutcome.ALREADY_PRESENT), result)
        assertEquals(emptyList(), client.writtenPaths())
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `usersだけが無ければ、usersだけを作りCREATED_USERを返す（emailは認証の状態から）`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existingProfile())

        val result = repairer(client).ensureAccountDocuments()

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_USER), result)
        assertEquals(listOf(userPath), client.writtenPaths())
        assertEquals(DocumentBuilders.userCreate(uid, email, now), client.writtenDoc(userPath))
    }

    @Test
    fun `publicProfilesだけが無ければ、publicProfilesだけを作りCREATED_PUBLIC_PROFILEを返す`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existingUser())

        val result = repairer(client).ensureAccountDocuments()

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_PUBLIC_PROFILE), result)
        assertEquals(listOf(profilePath), client.writtenPaths())
    }

    @Test
    fun `どちらも無ければ、usersとpublicProfilesを作りCREATED_BOTHを返す（公開プロフィールは新規の形）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repairer(client).ensureAccountDocuments()

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_BOTH), result)
        assertEquals(listOf(userPath, profilePath), client.writtenPaths())
        assertEquals(DocumentBuilders.userCreate(uid, email, now), client.writtenDoc(userPath))
        // 作ったばかりの users は表示名などを持たず、カウンタは 0。写す元が無いのと同じ形になる
        assertEquals(DocumentBuilders.publicProfileCreate(uid, source = null, now = now), client.writtenDoc(profilePath))
    }

    // ── 公開プロフィールを補うとき、users の値を写す ──

    @Test
    fun `公開プロフィールを補うとき、usersの表示名・アイコン・自己紹介・カウンタを写す`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existingUser())

        repairer(client).ensureAccountDocuments()

        val expected = DocumentBuilders.publicProfileCreate(
            uid,
            UserProfileFields("空見", photoUrl, "空が好き", followersCount = 5, followingCount = 3, postsCount = 12),
            now,
        )
        assertEquals(expected, client.writtenDoc(profilePath))
    }

    @Test
    fun `写すカウンタは、負の値と数値でない値を0に直し、小数で保存された数値は整数にする（補完が契約違反で止まり続けない）`() = runBlocking {
        val odd = mapOf<String, Any?>("id" to "UID-1", "followersCount" to -3L, "followingCount" to "abc", "postsCount" to 7.0)
        val client = FakeFirestoreWriteClient(documents = existingUser(odd))

        val result = repairer(client).ensureAccountDocuments()

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_PUBLIC_PROFILE), result)
        assertEquals(
            DocumentBuilders.publicProfileCreate(uid, UserProfileFields(null, null, null, 0, 0, 7), now),
            client.writtenDoc(profilePath),
        )
    }

    @Test
    fun `公開プロフィールに、fcmTokenなどの非公開の値を写さず、更新や削除もしない`() = runBlocking {
        val client = FakeFirestoreWriteClient(documents = existingUser())

        repairer(client).ensureAccountDocuments()

        val keys = client.writtenDoc(profilePath).keys
        assertTrue(keys.none { it.startsWith("fcmToken") || it == "blockedUserIds" || it == "email" }, "非公開の値を写した: $keys")
        assertTrue(client.calls.none { it.operation == "tx.update" || it.operation == "tx.delete" })
    }

    // ── 1 つのトランザクション：読み取りは書き込みより前 ──

    @Test
    fun `1つのトランザクションで、2つの文書を読んでから、欠けているものを書く`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        repairer(client).ensureAccountDocuments()

        assertEquals(
            listOf("runTransaction", "tx.get", "tx.get", "tx.set", "tx.set"),
            client.calls.map { it.operation },
        )
        assertEquals(listOf(userPath, profilePath), client.calls.filter { it.operation == "tx.get" }.map { it.paths.single() })
    }

    // ── 補完の結果の記録 ──

    @Test
    fun `成功した結果を、4通りとも記録の口へ渡す`() = runBlocking {
        val cases = listOf(
            existingUser() + existingProfile() to RepairOutcome.ALREADY_PRESENT,
            existingProfile() to RepairOutcome.CREATED_USER,
            existingUser() to RepairOutcome.CREATED_PUBLIC_PROFILE,
            emptyMap<String, RawDocument>() to RepairOutcome.CREATED_BOTH,
        )

        cases.forEach { (documents, _) -> repairer(FakeFirestoreWriteClient(documents)).ensureAccountDocuments() }

        assertEquals(cases.map { it.second }, outcomes)
    }

    // ── 失敗：返して記録する。結果は記録しない ──

    @Test
    fun `書き込みに失敗したら、失敗を返して発生箇所つきで記録し、結果は記録しない`() = runBlocking {
        val client = FakeFirestoreWriteClient().apply {
            failOn = "tx.set"
            failAfter = 0
            failure = FirestoreWriteFailure(AppError.Network, RuntimeException("偽物の通信断"))
        }

        val result = repairer(client).ensureAccountDocuments()

        assertEquals(AppResult.Err(AppError.Network), result)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.Network, "AccountDocumentRepairer.ensureAccountDocuments")),
            analytics.errors,
        )
        assertEquals(emptyList(), outcomes)
    }

    @Test
    fun `入口が断った形の違反は入口が記録済みなので、ここでは記録し直さない`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        // 空のメールアドレスで users を作ろうとすると、契約の長さの検査（1〜254）が止める
        val result = repairer(client, signedIn = SessionState.SignedIn(uid, "", isAnonymous = false)).ensureAccountDocuments()

        val error = assertIs<AppResult.Err>(result).error
        assertIs<AppError.ShapeViolation>(error)
        assertEquals(emptyList(), client.writtenPaths())
        assertEquals(listOf(RecordingAnalytics.LoggedError(error, "FirestoreWriteGateway.transaction")), analytics.errors)
    }

    @Test
    fun `ログインしていなければ、Firebaseに届かずPermissionDeniedを返して記録する`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repairer(client, signedIn = null).ensureAccountDocuments()

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(emptyList(), client.calls)
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "AccountDocumentRepairer.ensureAccountDocuments")),
            analytics.errors,
        )
    }

    // ── 書き込みの可否：補完（ACCOUNT_REPAIR）で判定する ──

    @Test
    fun `ACCOUNT_REPAIRだけが有効でも補える（補完の可否はACCOUNT_REPAIR）`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repairer(client, enabled = setOf(WriteCapability.ACCOUNT_REPAIR)).ensureAccountDocuments()

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_BOTH), result)
    }

    @Test
    fun `ACCOUNT_REPAIRが無効なら、Firebaseに届かずWriteBlockedを返し、記録は入口の1件だけ（M1の保証）`() = runBlocking {
        val client = FakeFirestoreWriteClient()
        val others = ALL_WRITES_ENABLED - WriteCapability.ACCOUNT_REPAIR

        val result = repairer(client, enabled = others).ensureAccountDocuments()

        val blocked = AppError.WriteBlocked(WriteCapability.ACCOUNT_REPAIR)
        assertEquals(AppResult.Err(blocked), result)
        assertEquals(emptyList(), client.calls, "可否が無効なのに Firebase に届いた")
        assertEquals(listOf(RecordingAnalytics.LoggedError(blocked, "FirestoreWriteGateway.transaction")), analytics.errors)
    }

    // ── 両方とも無いときだけ、認証のアカウントを確かめてから作る（レビュー R10） ──

    @Test
    fun `どちらも無く、認証のアカウントがサーバーに残っていると確かめられなければ、どちらも作らずPermissionDeniedを返して記録する`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repairer(client, accountExists = false).ensureAccountDocuments()

        assertEquals(AppResult.Err(AppError.PermissionDenied), result)
        assertEquals(1, verifyCalls)
        // 2 つを読んでから確かめて断った（何も書いていない）
        assertEquals(listOf("runTransaction", "tx.get", "tx.get"), client.calls.map { it.operation })
        // 記録はログインしていないときと同じ道（発生箇所はこの部品）。結果は記録しない
        assertEquals(
            listOf(RecordingAnalytics.LoggedError(AppError.PermissionDenied, "AccountDocumentRepairer.ensureAccountDocuments")),
            analytics.errors,
        )
        assertEquals(emptyList(), outcomes)
    }

    @Test
    fun `どちらも無く、認証のアカウントが残っていると確かめられれば、今どおり両方作る`() = runBlocking {
        val client = FakeFirestoreWriteClient()

        val result = repairer(client, accountExists = true).ensureAccountDocuments()

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_BOTH), result)
        assertEquals(1, verifyCalls)
        assertEquals(listOf(userPath, profilePath), client.writtenPaths())
        assertEquals(listOf(RepairOutcome.CREATED_BOTH), outcomes)
        assertEquals(emptyList(), analytics.errors)
    }

    @Test
    fun `片方だけ無いときと両方あるときは、認証のアカウントの確かめを呼ばない`() = runBlocking {
        val cases = listOf(
            existingProfile() to RepairOutcome.CREATED_USER,
            existingUser() to RepairOutcome.CREATED_PUBLIC_PROFILE,
            existingUser() + existingProfile() to RepairOutcome.ALREADY_PRESENT,
        )

        // 確かめが「通らない」を返しても、呼ばなければ今どおり補える
        val results = cases.map { (documents, _) ->
            repairer(FakeFirestoreWriteClient(documents), accountExists = false).ensureAccountDocuments()
        }

        assertEquals(0, verifyCalls)
        assertEquals(cases.map { AppResult.Ok(it.second) }, results)
    }

    // ── 確かめの口の中身（accountExistsOnServer）：失敗は全て「通らない」に倒し、取り消しだけはそのまま伝える（全体レビュー 4 回目 Q14） ──

    @Test
    fun `確かめの中身は、ログインしていなければreloadを呼ばずに通さない`() = runBlocking {
        var reloads = 0

        assertFalse(accountExistsOnServer<String>(null) { reloads++ })
        assertEquals(0, reloads)
    }

    @Test
    fun `確かめの中身は、ログイン中のユーザーをreloadして戻れば通す`() = runBlocking {
        val reloaded = mutableListOf<String>()

        assertTrue(accountExistsOnServer("UID-1") { reloaded += it })
        assertEquals(listOf("UID-1"), reloaded)
    }

    @Test
    fun `確かめの中身は、reloadが失敗すれば通さない（消されたアカウント・通信の失敗）`() = runBlocking {
        assertFalse(accountExistsOnServer("UID-1") { throw IllegalStateException("消されたアカウントの代わり") })
        assertFalse(accountExistsOnServer("UID-1") { throw IOException("通信の失敗の代わり") })
    }

    @Test
    fun `確かめの中身は、コルーチンの取り消しを「通らない」に変えず、そのまま伝える`() = runBlocking {
        val cancelled = CancellationException("取り消し")

        val thrown = assertFailsWith<CancellationException> { accountExistsOnServer("UID-1") { throw cancelled } }
        assertSame(cancelled, thrown)
    }

    @Test
    fun `AppContainerは、補完に認証のSDKのreloadで確かめる口を渡す`() {
        // 本物の FirebaseAuth は JVM の単体テストで作れないので、配線はソースの書き方で固定する（:app の単体テストの作業ディレクトリは android/app）。
        // 判断の中身（accountExistsOnServer）は上の 4 本で確かめる。ここで見るのは、口を渡していることと、渡す処理が SDK の reload を待つことだけ
        val file = File("src/main/kotlin/com/yoshidometoru/soramoyou/di/AppContainer.kt")
        assertTrue(file.isFile, "AppContainer.kt が見つからない: ${file.absolutePath}")
        val arguments = assertNotNull(
            callArguments(file.readText(), "DefaultAccountDocumentRepairer("),
            "AppContainer に DefaultAccountDocumentRepairer を作る呼び出しが見つからない",
        )
        // 行のコメントを除いてから探す（コメントにした reload を「待っている」と数えない）
        val code = arguments.lines().joinToString("\n") { it.substringBefore("//") }

        assertTrue("verifyAccount = {" in code, "補完に確かめの口（verifyAccount）を渡していない（既定の「確かめずに true」になる）")
        assertTrue("accountExistsOnServer(" in code, "確かめの口が、単体テストで確かめた判断（accountExistsOnServer）を通っていない")
        assertTrue(".reload().await()" in code, "確かめの口が認証の SDK の reload を待っていない")
    }

    /**
     * [source] の中の最初の [opening]（`名前(` の形）から、対応する閉じ括弧までの中身を返す。見つからなければ null。
     * 引数のラムダの中にも括弧があるので、行で探さずに括弧の深さを数える（文字列・コメントの中の半角の括弧も数える。
     * いまの引数には、半角の括弧を含む文字列・コメントは無い）。
     */
    private fun callArguments(source: String, opening: String): String? {
        val start = source.indexOf(opening)
        if (start < 0) return null
        val bodyStart = start + opening.length
        var depth = 1
        for (i in bodyStart until source.length) {
            when (source[i]) {
                '(' -> depth++
                ')' -> if (--depth == 0) return source.substring(bodyStart, i)
            }
        }
        return null
    }
}
