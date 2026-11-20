// ⭐️ M5（通報・ブロック・フィードバック・退会）の書き込みが、リポジトリの rules をそのまま通ることを、rules の拒否の陽性対照とあわせて確かめる結合テスト（タスク 33.1・要件 11.2・11.4・11.5・12.3・12.4・13.2）
package com.yoshidometoru.soramoyou.integration

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.storage.StorageException
import com.yoshidometoru.soramoyou.BuildConfig
import com.yoshidometoru.soramoyou.SoramoyouApplication
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.FeedbackInput
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.model.PostImageView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.repository.PostDraft
import com.yoshidometoru.soramoyou.data.repository.PostPhoto
import com.yoshidometoru.soramoyou.di.AppContainer
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 実行の前に、開発機で `android/tools/start-firebase-emulators.sh` を起動しておく（rules はリポジトリのまま）。
 * 実行は `./gradlew :app:connectedEmulatorDebugAndroidTest`（仮想端末が要る）。
 *
 * 書き込みはアプリの部品（[AppContainer] の moderationRepository・feedbackRepository・accountDeletionService など）で行い、
 * 結果はエミュレータの管理者の口（[EmulatorBackend]）で確かめる（読み取りの不具合と書き込みの不具合を混ぜない）。
 * 他人の投稿・いいね・コメント・フォロー・下書きなど、Android のアプリに書き手の無い文書は、管理者の口で置く。
 *
 * rules の陽性対照は 2 種類ある。
 * - テストの中：同じユーザーの ID トークンで、rules が断るもの（403）と通すもの（200）を対にして送る
 * - テストの外（タスク 33.1 の記録）：エミュレータが読む `firestore.rules` の写しの条件を厳しくすると、狙ったテストだけが赤になること
 */
@RunWith(AndroidJUnit4::class)
class M5EmulatorTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val container: AppContainer =
        ApplicationProvider.getApplicationContext<SoramoyouApplication>().container
    private val dir = File(context.cacheDir, "m5-emulator-test").apply { mkdirs() }

    /** テストが Storage に置いたかもしれないパスを、持ち主のメールアドレスごとに控える。終わったら持ち主としてログインして消す。 */
    private val touched = mutableMapOf<String, MutableList<StoragePath>>()

    @Before
    fun resetEmulator() = runBlocking {
        container.authRepository.signOut()
        EmulatorBackend.reset()
        EmulatorBackend.resetAuth()
    }

    @After
    fun cleanUp() = runBlocking {
        // Storage のエミュレータには一括で消す口が無いので、アプリの入口で 1 つずつ消す（無ければ NotFound で構わない）。
        // 退会したアカウントはログインできないので飛ばす（退会のテストが通っていれば、画像は退会が消している）
        for ((email, paths) in touched) {
            container.authRepository.signOut()
            if (container.authRepository.signIn(email, PASSWORD) !is AppResult.Ok) continue
            for (path in paths) container.storageGateway.delete(WriteCapability.ACCOUNT_DELETE, path)
        }
        container.authRepository.signOut()
        dir.deleteRecursively()
        Unit
    }

    // ── マイルストーン（レビュー F11 の申し送り） ──

    @Test
    fun 検証用ビルドのマイルストーンはM6で_M5の書き込みが全て有効() {
        // PostM4EmulatorTest は「M4 以上」へ緩めたので、マイルストーンの値自体をここで固定する。
        // タスク 34.1 で M6 にした（M6 の書き込みの集合は M5 と同じ。設計書「マイルストーンと有効化の範囲」）。
        // 写しの関数（writeCapabilitiesOf）で比べると同じ関数どうしの比較になるので、期待する集合はここに書き下す
        assertEquals("M6", BuildConfig.WRITE_MILESTONE)
        val m5 = setOf(
            WriteCapability.ACCOUNT_CREATE, WriteCapability.ACCOUNT_REPAIR, WriteCapability.PROFILE_EDIT,
            WriteCapability.LIKE,
            WriteCapability.POST_CREATE, WriteCapability.POSTS_COUNT_SYNC, WriteCapability.POST_DELETE,
            WriteCapability.REPORT, WriteCapability.BLOCK, WriteCapability.FEEDBACK, WriteCapability.ACCOUNT_DELETE,
        )
        assertEquals(m5, container.writeGate.enabled)
    }

    // ── 通報・ブロック・フィードバック ──

    @Test
    fun 通報とフィードバックの作成がrulesを通り_クライアントからは消せない() = runBlocking {
        val author = createAccount(EMAIL_B)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(author, EMAIL_B))
        EmulatorBackend.seed("posts", B_PUBLIC, seededPost(author, B_PUBLIC, "public", likes = 0, comments = 0))
        container.authRepository.signOut()
        val me = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(me, EMAIL_A))
        val token = idToken()

        // 通報：5 項目ちょうどの文書が 1 件だけできる（要件 11.2）
        assertEquals(AppResult.Ok(Unit), container.moderationRepository.report(postView(B_PUBLIC, author), ReportReason.SPAM))
        val (reportId, report) = EmulatorBackend.listDocuments("reports").single()
        assertEquals(setOf("postId", "reporterId", "reportedUserId", "reason", "createdAt"), report.keys().asSequence().toSet())
        assertEquals(B_PUBLIC, report.str("postId"))
        assertEquals(me.value, report.str("reporterId"))
        assertEquals(author.value, report.str("reportedUserId"))
        assertEquals("spam", report.str("reason"))
        assertTrue("作成日時はサーバー時刻", report.optJSONObject("createdAt")?.has("timestampValue") == true)

        // フィードバック：本文は前後の空白を取り除いて書く。メールアドレスと表示名は書かない（要件 13.2・13.4）
        val input = FeedbackInput(me, "  検証用のご意見です  ", FeedbackCategory.BUG, "1.0.0-emulator", "sdk_gphone64")
        assertEquals(AppResult.Ok(Unit), container.feedbackRepository.submit(input))
        val (feedbackId, feedback) = EmulatorBackend.listDocuments("feedback").single()
        assertEquals(
            setOf("userId", "message", "createdAt", "category", "appVersion", "deviceInfo"),
            feedback.keys().asSequence().toSet(),
        )
        assertEquals(me.value, feedback.str("userId"))
        assertEquals("検証用のご意見です", feedback.str("message"))
        assertEquals("bug", feedback.str("category"))

        // rules の陽性対照：同じトークンで、通報とフィードバックの削除は断られ（update, delete: if false）、文書は残る
        assertEquals(403, EmulatorBackend.deleteAsUser("reports", reportId, token))
        assertEquals(403, EmulatorBackend.deleteAsUser("feedback", feedbackId, token))
        assertEquals(1, EmulatorBackend.listDocuments("reports").size)
        assertEquals(1, EmulatorBackend.listDocuments("feedback").size)
        // 対：同じトークンで、自分の公開プロフィールの削除は通る（403 がトークンの不備でなく、rules の判定であることの確かめ）
        assertEquals(200, EmulatorBackend.deleteAsUser("publicProfiles", me.value, token))
    }

    @Test
    fun ブロックと解除は自分のユーザー文書のblockedUserIdsだけを1人ずつ変え_他人には変えられない() = runBlocking {
        val other = createAccount(EMAIL_B)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(other, EMAIL_B))
        container.authRepository.signOut()
        val me = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(me, EMAIL_A))
        val before = requireNotNull(EmulatorBackend.readFields("users", me.value))
        val third = Uid("third-user")

        assertEquals(AppResult.Ok(Unit), container.moderationRepository.block(other))
        assertEquals(listOf(other.value), blockedIdsOf(me))
        assertEquals(AppResult.Ok(Unit), container.moderationRepository.block(third))
        assertEquals("追加（arrayUnion）は並びの末尾に足す", listOf(other.value, third.value), blockedIdsOf(me))
        assertEquals(AppResult.Ok(setOf(other, third)), container.blockListRepository.blockedIds())

        assertEquals(AppResult.Ok(Unit), container.moderationRepository.unblock(other))
        assertEquals("解除（arrayRemove）はその 1 人だけを外す", listOf(third.value), blockedIdsOf(me))
        assertEquals(AppResult.Ok(setOf(third)), container.blockListRepository.blockedIds())
        val after = requireNotNull(EmulatorBackend.readFields("users", me.value))
        assertEquals(
            "blockedUserIds 以外は変わらない（更新日時も書かない）",
            canonical(JSONObject(before.toString()).apply { remove("blockedUserIds") }),
            canonical(JSONObject(after.toString()).apply { remove("blockedUserIds") }),
        )

        // rules の陽性対照：別のユーザーのトークンでは、自分（A）のブロック中の一覧を書き換えられない
        container.authRepository.signOut()
        assertEquals(AppResult.Ok(Unit), container.authRepository.signIn(EMAIL_B, PASSWORD))
        val otherToken = idToken()
        val forged = """"blockedUserIds":{"arrayValue":{"values":[]}}"""
        assertEquals(403, EmulatorBackend.patchAsUser("users", me.value, forged, listOf("blockedUserIds"), otherToken))
        assertEquals(listOf(third.value), blockedIdsOf(me))
        // 対：同じトークン・同じ書き込みで、自分（B）のユーザー文書なら通る
        assertEquals(200, EmulatorBackend.patchAsUser("users", other.value, forged, listOf("blockedUserIds"), otherToken))
    }

    // ── 退会 ──

    @Test
    fun resource_dataを見る削除の規則は_無い文書の削除を拒否し_パスだけで判定する規則は通す() = runBlocking {
        // 31.2 の注記（無い文書の削除が PermissionDenied になる）は rules の現物から読んだだけで未実測だった。ここで実測する
        val me = createAccount(EMAIL_A)
        val token = idToken()

        for (collection in listOf("follows", "posts", "drafts", "likes", "comments")) {
            assertEquals("$collection の無い文書の削除", 403, EmulatorBackend.deleteAsUser(collection, "MISSING-$collection", token))
        }
        // 対：同じトークンで、同じコレクションの自分の文書は消せる（403 が持ち主の判定でなく、文書が無いことによる拒否であることの確かめ）
        EmulatorBackend.seed("follows", "${me.value}_someone", follow(me, Uid("someone")))
        EmulatorBackend.seed("posts", "OWN-POST", seededPost(me, "OWN-POST", "private", likes = 0, comments = 0))
        EmulatorBackend.seed("drafts", "OWN-DRAFT", draft(me, "OWN-DRAFT"))
        EmulatorBackend.seed("likes", "${me.value}_OWN-POST", like(me, "OWN-POST"))
        EmulatorBackend.seed("comments", "OWN-COMMENT", comment(me, "OWN-POST"))
        for ((collection, id) in listOf(
            "follows" to "${me.value}_someone", "posts" to "OWN-POST", "drafts" to "OWN-DRAFT",
            "likes" to "${me.value}_OWN-POST", "comments" to "OWN-COMMENT",
        )) {
            assertEquals("$collection の自分の文書の削除", 200, EmulatorBackend.deleteAsUser(collection, id, token))
            assertNull(EmulatorBackend.readFields(collection, id))
        }

        // パスだけで判定する規則（isOwner(userId)）は、無い文書の削除を通す（退会の再試行で、消し終えた段階が止まらない）
        assertEquals(200, EmulatorBackend.deleteAsUser("publicProfiles", me.value, token))
        assertEquals(200, EmulatorBackend.deleteAsUser("users", me.value, token))
        assertEquals(200, EmulatorBackend.deleteAsUser("users/${me.value}/favorites", "MISSING-FAVORITE", token))

        // Storage の無いオブジェクトの削除は、rules を通った上で NotFound に写る（退会は消せたものとみなす）
        assertEquals(
            AppResult.Err(AppError.NotFound),
            container.storageGateway.delete(WriteCapability.ACCOUNT_DELETE, StoragePath.postImage(me, Visibility.PUBLIC, "MISSING")),
        )
    }

    @Test
    fun 退会の全段階がrulesを通り_他人の投稿のカウンタを自分の分だけ減らし_自分のデータと画像と認証のアカウントが残らない() = runBlocking {
        // 相手（B）。B の投稿・コメント・下書き・フォローは残ること
        val other = createAccount(EMAIL_B)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(other, EMAIL_B))
        container.authRepository.signOut()
        // 退会する本人（A）
        val me = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(me, EMAIL_A))

        // B の投稿（カウンタは、A のいいね・コメントと B 自身のコメントの分だけ持たせる）
        EmulatorBackend.seedMany(
            "posts",
            listOf(
                B_PUBLIC to seededPost(other, B_PUBLIC, "public", likes = 1, comments = 3),
                B_FOLLOWERS to seededPost(other, B_FOLLOWERS, "followers", likes = 1, comments = 0),
                B_PRIVATE to seededPost(other, B_PRIVATE, "private", likes = 1, comments = 1),
                // commentsCount の無い旧い投稿。非公開なので段 A で読めず、段 B は rules（isCountOnlyUpdate）が断り、段 C に落ちる
                B_PRIVATE_OLD to seededPost(other, B_PRIVATE_OLD, "private", likes = 0, comments = null),
            ),
        )
        // A のいいね（POST_GONE は、既に消えた投稿を指す）。段 A は公開、段 B はフォロワー限定と非公開、段 C は消えた投稿
        EmulatorBackend.seedMany(
            "likes",
            listOf(B_PUBLIC, B_FOLLOWERS, B_PRIVATE, POST_GONE).map { "${me.value}_$it" to like(me, it) },
        )
        // A のコメント（同じ投稿に 2 件・非公開・旧い投稿・消えた投稿・postId の無いもの）と、残る B のコメント
        EmulatorBackend.seedMany(
            "comments",
            listOf(
                "C-PUBLIC-1" to comment(me, B_PUBLIC),
                "C-PUBLIC-2" to comment(me, B_PUBLIC),
                "C-PRIVATE" to comment(me, B_PRIVATE),
                "C-OLD" to comment(me, B_PRIVATE_OLD),
                "C-GONE" to comment(me, POST_GONE),
                "C-NO-POST" to """"userId":${quoted(me.value)},"content":{"stringValue":"空"},"createdAt":{"timestampValue":"2026-10-14T00:00:00Z"}""",
                "C-OTHER" to comment(other, B_PUBLIC),
            ),
        )
        // フォロー（A がする側・される側の両向き）と、A に関係のない B のフォロー（残る）
        EmulatorBackend.seedMany(
            "follows",
            listOf(
                "${me.value}_${other.value}" to follow(me, other),
                "${other.value}_${me.value}" to follow(other, me),
                "${other.value}_someone" to follow(other, Uid("someone")),
            ),
        )
        EmulatorBackend.seedMany("drafts", listOf("D-1" to draft(me, "D-1"), "D-2" to draft(me, "D-2"), "D-OTHER" to draft(other, "D-OTHER")))
        EmulatorBackend.seedMany("users/${me.value}/favorites", listOf(B_PUBLIC to favorite(B_PUBLIC)))

        // A の投稿（アプリの入口で公開し、本体とサムネイルを Storage に置く）
        val published = Visibility.entries.map { publish(EMAIL_A, it) }
        val images = published.flatMap { requireNotNull(EmulatorBackend.readFields("posts", it.value)).imagePaths() }.map(::StoragePath)
        // 元画像つき・パスの無い旧データの画像も混じる投稿（PostM4EmulatorTest と同じ作り。退会の POST_IMAGES が URL から解決するか）
        val legacy = seedPostWithOriginals(me)
        // アイコン
        val icon = StoragePath.profileIcon(me)
        touched.getOrPut(EMAIL_A) { mutableListOf() } += icon
        assertTrue(container.storageGateway.uploadJpeg(WriteCapability.PROFILE_EDIT, icon, jpegBytes(), 0) is AppResult.Ok)
        val allImages = images + legacy + icon
        assertEquals(6 + 5 + 1, allImages.size)
        // 陽性対照：消す前に全部有る。有ったものが消えるので、後の「無い」は退会の結果である
        assertEquals(List(allImages.size) { true }, allImages.map { storageObject(it.value) != null })
        val oldPostBefore = requireNotNull(EmulatorBackend.readFields("posts", B_PRIVATE_OLD))

        val started = System.currentTimeMillis()
        assertEquals(AppResult.Ok(Unit), container.accountDeletionService.delete(PASSWORD))
        println("M5EmulatorTest 退会の所要時間: ${System.currentTimeMillis() - started} ms")
        assertNull("終わったら段階は null に戻る", container.accountDeletionService.stage.value)

        // 本人のデータが残らない（要件 12.3）
        assertNull(EmulatorBackend.readFields("users", me.value))
        assertNull(EmulatorBackend.readFields("publicProfiles", me.value))
        for (collection in listOf("posts", "likes", "comments", "drafts")) {
            assertEquals("$collection に A の文書が残っている", emptyList<String>(), idsOwnedBy(collection, me))
        }
        assertEquals(emptyList<Pair<String, JSONObject>>(), EmulatorBackend.listDocuments("users/${me.value}/favorites"))
        assertEquals(listOf("${other.value}_someone"), EmulatorBackend.listDocuments("follows").map { it.first })
        for (path in allImages) assertNull("消えているはず: ${path.value}", storageObject(path.value))
        assertFalse("認証のアカウントも消える", EmulatorBackend.authAccountExists(me.value))
        assertNull("端末はログイン前に戻る", FirebaseAuth.getInstance().currentUser)

        // 相手の投稿のカウンタは、A の分だけ減る（要件 12.4）。段 A：公開／段 B：フォロワー限定・非公開（フォローは先に消えて読めない）
        val publicPost = requireNotNull(EmulatorBackend.readFields("posts", B_PUBLIC))
        assertEquals("0", publicPost.int("likesCount"))
        assertEquals("B 自身のコメントの 1 件だけが残る", "1", publicPost.int("commentsCount"))
        assertEquals("0", EmulatorBackend.readFields("posts", B_FOLLOWERS)?.int("likesCount"))
        val privatePost = requireNotNull(EmulatorBackend.readFields("posts", B_PRIVATE))
        assertEquals("0", privatePost.int("likesCount"))
        assertEquals("0", privatePost.int("commentsCount"))
        // 段 C：コメントは消えたが、旧い投稿には commentsCount を足さない（文書は退会の前と同じ）
        assertEquals(canonical(oldPostBefore), canonical(requireNotNull(EmulatorBackend.readFields("posts", B_PRIVATE_OLD))))

        // 相手のデータは残る
        assertNotNull(EmulatorBackend.readFields("users", other.value))
        assertNotNull(EmulatorBackend.readFields("publicProfiles", other.value))
        assertEquals(listOf("C-OTHER"), EmulatorBackend.listDocuments("comments").map { it.first })
        assertEquals(listOf("D-OTHER"), EmulatorBackend.listDocuments("drafts").map { it.first })
        assertEquals(4, idsOwnedBy("posts", other).size)
        assertTrue(EmulatorBackend.authAccountExists(other.value))
    }

    @Test
    fun 退会は500件を超える投稿と50件を超えるフォローとコメントも消し切る() = runBlocking {
        // 一括削除の上限（500 件）での分割と、50 件ずつの取得の繰り返し（drainOwnDocuments）が、本物の rules と問い合わせで最後まで進むか
        val me = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(me, EMAIL_A))
        val author = Uid("post-author")
        EmulatorBackend.seed("posts", B_PUBLIC, seededPost(author, B_PUBLIC, "public", likes = 0, comments = MANY_REACTIONS.toLong()))
        EmulatorBackend.seedMany(
            "posts",
            (1..MANY_POSTS).map { "MANY-%03d".format(it) }.map { it to seededPost(me, it, "public", likes = 0, comments = 0) },
        )
        EmulatorBackend.seedMany(
            "follows",
            (1..MANY_FOLLOWS).flatMap { n ->
                val someone = Uid("someone-%02d".format(n))
                listOf("${me.value}_${someone.value}" to follow(me, someone), "${someone.value}_${me.value}" to follow(someone, me))
            },
        )
        EmulatorBackend.seedMany("comments", (1..MANY_REACTIONS).map { "C-%02d".format(it) to comment(me, B_PUBLIC) })
        assertEquals(MANY_POSTS, idsOwnedBy("posts", me).size)

        val started = System.currentTimeMillis()
        assertEquals(AppResult.Ok(Unit), container.accountDeletionService.delete(PASSWORD))
        println("M5EmulatorTest 退会（投稿 $MANY_POSTS・フォロー ${MANY_FOLLOWS * 2}・コメント $MANY_REACTIONS）の所要時間: ${System.currentTimeMillis() - started} ms")

        assertEquals(emptyList<String>(), idsOwnedBy("posts", me))
        assertEquals(emptyList<Pair<String, JSONObject>>(), EmulatorBackend.listDocuments("follows"))
        assertEquals(emptyList<Pair<String, JSONObject>>(), EmulatorBackend.listDocuments("comments"))
        assertEquals("コメントの分だけ 1 件ずつ減る", "0", EmulatorBackend.readFields("posts", B_PUBLIC)?.int("commentsCount"))
        assertFalse(EmulatorBackend.authAccountExists(me.value))
    }

    @Test
    fun 退会は文書の無い画像も自分のフォルダの一覧から拾って消し_他人の画像には触らない() = runBlocking {
        // タスク 31.6（レビュー F20）：投稿の文書から拾えない画像（自分の投稿の削除が文書だけ消して残したもの・パスを解決できないもの）を、
        // 段階 STORAGE_LEFTOVERS がフォルダの一覧から拾うか。画像はアプリの入口で上げ、文書は作らない
        val other = createAccount(EMAIL_B)
        val othersImage = StoragePath.postImage(other, Visibility.PUBLIC, "OTHER")
        touched.getOrPut(EMAIL_B) { mutableListOf() } += othersImage
        assertTrue(container.storageGateway.uploadJpeg(WriteCapability.POST_CREATE, othersImage, jpegBytes(), 0) is AppResult.Ok)
        container.authRepository.signOut()
        val me = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(me, EMAIL_A))
        val orphans = listOf(
            StoragePath.postImage(me, Visibility.PUBLIC, "ORPHAN-1"),
            StoragePath.postThumbnail(me, Visibility.FOLLOWERS, "ORPHAN-2"),
            StoragePath("originals/${me.value}/private/ORPHAN-3.jpg"),
            StoragePath("users/${me.value}/profile/old.jpg"),
        )
        uploadAll(EMAIL_A, orphans)
        // 陽性対照：消す前に全部有る
        assertEquals(List(orphans.size) { true }, orphans.map { storageObject(it.value) != null })

        assertEquals(AppResult.Ok(Unit), container.accountDeletionService.delete(PASSWORD))

        for (path in orphans) assertNull("消えているはず: ${path.value}", storageObject(path.value))
        assertNotNull("他人の画像は残る", storageObject(othersImage.value))
        assertFalse(EmulatorBackend.authAccountExists(me.value))
    }

    @Test
    fun 退会は数百の残った画像も一覧から消し切る_所要時間を測る() = runBlocking {
        // タスク 31.6 の「画像が数百件あるときの所要時間も見る」。文書の無い画像を公開と非公開の 2 つのフォルダに置く
        val me = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(me, EMAIL_A))
        val orphans = (1..MANY_LEFTOVERS).map { n ->
            val visibility = if (n % 2 == 0) Visibility.PUBLIC else Visibility.PRIVATE
            StoragePath.postImage(me, visibility, "MANY-%03d".format(n))
        }
        val uploadStarted = System.currentTimeMillis()
        uploadAll(EMAIL_A, orphans)
        println("M5EmulatorTest 残った画像 $MANY_LEFTOVERS 個のアップロード: ${System.currentTimeMillis() - uploadStarted} ms")
        // 有無は管理者の口の一覧（GET 1 回ずつ）で確かめる。1 つずつ読むと 600 回の GET でテストが数分延びる
        val folders = listOf("posts/${me.value}/public", "posts/${me.value}/private")
        // 陽性対照：消す前に全部有る（管理者の口の一覧が、置いた画像を数えられること）
        assertEquals(orphans.map { it.value }.sorted(), folders.flatMap { storageList(it) }.sorted())

        val started = System.currentTimeMillis()
        assertEquals(AppResult.Ok(Unit), container.accountDeletionService.delete(PASSWORD))
        println("M5EmulatorTest 退会（残った画像 $MANY_LEFTOVERS 個）の所要時間: ${System.currentTimeMillis() - started} ms")

        assertEquals(emptyList<String>(), folders.flatMap { storageList(it) })
    }

    // ── Storage のフォルダの一覧（タスク 31.6 の前提・レビュー F20） ──

    @Test
    fun 本人のStorageのフォルダの一覧がstorage_rulesを通るか() = runBlocking {
        // タスク 31.6（退会で、投稿の文書に頼らず本人のフォルダを一覧して残った画像を消す）の前提の測定。
        // storage.rules は `match /posts/{userId}/public/{imageId}` のように 1 区切りの画像 ID でだけ書かれていて、
        // `users/{userId}/` の直下（iOS の古いアイコン users/{uid}/profile.jpg）に当たる規則は無い。
        // 一覧（list）がどの規則で判定されるかは rules の現物から断定できないので、各フォルダの結果をまとめて比べる
        val owner = createAccount(EMAIL_A)
        val bytes = jpegBytes()
        val uploads = listOf(
            StoragePath.postImage(owner, Visibility.PUBLIC, "LIST-1"),
            StoragePath.postImage(owner, Visibility.PRIVATE, "LIST-2"),
            StoragePath.postThumbnail(owner, Visibility.PRIVATE, "LIST-2"),
            StoragePath("originals/${owner.value}/public/LIST-3.jpg"),
            StoragePath.profileIcon(owner),
        )
        touched.getOrPut(EMAIL_A) { mutableListOf() } += uploads
        for (path in uploads) {
            val cap = if (path.value.startsWith("users/")) WriteCapability.PROFILE_EDIT else WriteCapability.POST_CREATE
            val uploaded = container.storageGateway.uploadJpeg(cap, path, bytes, 0)
            check(uploaded is AppResult.Ok) { "上げられない: ${path.value} → $uploaded" }
        }

        val folders = listOf(
            "posts/${owner.value}/public",
            "posts/${owner.value}/private",
            "thumbnails/${owner.value}/private",
            "originals/${owner.value}/public",
            "users/${owner.value}/profile",
            "users/${owner.value}",
            "posts/${owner.value}",
        )
        val asOwner = folders.associateWith { listResult(it) }
        // iOS の古いアイコンの置き場（無いオブジェクト）の削除が、rules で断られるか（PermissionDenied）、通って不在になるか（NotFound）
        val legacyIcon = container.storageGateway.delete(WriteCapability.ACCOUNT_DELETE, StoragePath("users/${owner.value}/profile.jpg"))

        // 陽性対照：別のユーザーとして、持ち主だけが読める非公開のフォルダと、誰でも読める公開のフォルダを一覧する
        container.authRepository.signOut()
        createAccount(EMAIL_B)
        val asOther = listOf("posts/${owner.value}/private", "posts/${owner.value}/public").associateWith { listResult(it) }

        val measured = buildString {
            appendLine("本人:")
            asOwner.forEach { (folder, result) -> appendLine("  ${folder.replace(owner.value, "{A}")} → $result") }
            appendLine("古いアイコンの削除 → $legacyIcon")
            appendLine("別のユーザー:")
            asOther.forEach { (folder, result) -> appendLine("  ${folder.replace(owner.value, "{A}")} → $result") }
        }
        println("M5EmulatorTest 一覧の測定\n$measured")
        // 予測（rules の現物からの読み）：画像 ID の 1 区切りで書かれた規則は、その直上のフォルダの一覧も判定する。
        // users/{A} と posts/{A} の直下に当たる規則は無いので断られる。古いアイコンの削除も当たる規則が無く断られる
        val predicted = buildString {
            appendLine("本人:")
            appendLine("  posts/{A}/public → items=1")
            appendLine("  posts/{A}/private → items=1")
            appendLine("  thumbnails/{A}/private → items=1")
            appendLine("  originals/{A}/public → items=1")
            appendLine("  users/{A}/profile → items=1")
            appendLine("  users/{A} → denied")
            appendLine("  posts/{A} → denied")
            appendLine("古いアイコンの削除 → Err(error=PermissionDenied)")
            appendLine("別のユーザー:")
            appendLine("  posts/{A}/private → denied")
            appendLine("  posts/{A}/public → items=1")
        }
        assertEquals(predicted, measured)
    }

    // ── 下ごしらえ ──

    /** [folder] を一覧し、直下の画像の数（`items=n`。下のフォルダがあれば `prefixes=…` も）か、断られた理由を返す。 */
    private suspend fun listResult(folder: String): String =
        try {
            val result = container.storage.reference.child(folder).listAll().await()
            buildString {
                append("items=${result.items.size}")
                if (result.prefixes.isNotEmpty()) append(" prefixes=${result.prefixes.map { it.name }.sorted()}")
            }
        } catch (e: StorageException) {
            if (e.errorCode == StorageException.ERROR_NOT_AUTHORIZED || e.errorCode == StorageException.ERROR_NOT_AUTHENTICATED) {
                "denied"
            } else {
                "error(${e.errorCode}/${e.httpResultCode})"
            }
        }

    /** ログイン中のユーザー（[email]）として、写真 1 枚で [visibility] の投稿を公開し、その投稿 ID を返す。上げた画像は後で消すために控える。 */
    private suspend fun publish(email: String, visibility: Visibility): PostId {
        // 編集なし（今までの「フィルターなし」）。撮影日時は K0 の公開の部品が投稿の時に読むので、入力は null（形は Kiro android-edit-tools K0）
        val draft = PostDraft(
            photos = listOf(PostPhoto(jpeg("${visibility.raw}-0", 0), PhotoEdit.NONE)),
            caption = "空 #${visibility.raw}",
            visibility = visibility,
            firstPhotoCapturedAt = null,
        )
        val postId = when (val result = container.postPublisher.publish(draft)) {
            is AppResult.Ok -> result.value
            is AppResult.Err -> error("公開できない（${visibility.raw}）: ${result.error}")
        }
        val fields = requireNotNull(EmulatorBackend.readFields("posts", postId.value)) { "公開したはずの投稿が無い: ${postId.value}" }
        touched.getOrPut(email) { mutableListOf() } += fields.imagePaths().map(::StoragePath)
        return postId
    }

    /**
     * [uid] の、元画像つきで、2 枚目がパスの無い旧データの形の投稿を置き、その画像 5 つのパスを返す（PostM4EmulatorTest と同じ作り）。
     * 画像はアプリの入口で上げ、文書は管理者の口で作る（元画像は iOS だけが作る）。
     */
    private suspend fun seedPostWithOriginals(uid: Uid): List<StoragePath> {
        val body = StoragePath.postImage(uid, Visibility.PUBLIC, "ORIG-1")
        val thumb = StoragePath.postThumbnail(uid, Visibility.PUBLIC, "ORIG-1")
        val original = StoragePath("originals/${uid.value}/public/ORIG-1.jpg")
        val legacyBody = StoragePath.postImage(uid, Visibility.PUBLIC, "ORIG-2")
        val legacyThumb = StoragePath.postThumbnail(uid, Visibility.PUBLIC, "ORIG-2")
        val all = listOf(body, thumb, original, legacyBody, legacyThumb)
        touched.getOrPut(EMAIL_A) { mutableListOf() } += all
        val bytes = jpegBytes()
        val urls = all.associateWith { path ->
            when (val uploaded = container.storageGateway.uploadJpeg(WriteCapability.POST_CREATE, path, bytes, 0)) {
                is AppResult.Ok -> uploaded.value
                is AppResult.Err -> error("上げられない: ${path.value} → ${uploaded.error}")
            }
        }
        EmulatorBackend.seed(
            "posts", POST_WITH_ORIGINALS,
            """"postId":{"stringValue":"$POST_WITH_ORIGINALS"},"userId":{"stringValue":"${uid.value}"},""" +
                """"visibility":{"stringValue":"public"},"likesCount":{"integerValue":"0"},"commentsCount":{"integerValue":"0"},""" +
                """"createdAt":{"timestampValue":"2026-10-11T00:00:00Z"},"updatedAt":{"timestampValue":"2026-10-11T00:00:00Z"},""" +
                """"images":{"arrayValue":{"values":[""" +
                """{"mapValue":{"fields":{"url":${quoted(urls.getValue(body))},"thumbnail":${quoted(urls.getValue(thumb))},""" +
                """"storagePath":${quoted(body.value)},"thumbnailStoragePath":${quoted(thumb.value)},""" +
                """"width":{"integerValue":"300"},"height":{"integerValue":"200"},"order":{"integerValue":"0"}}}},""" +
                """{"mapValue":{"fields":{"url":${quoted(urls.getValue(legacyBody))},"thumbnail":${quoted(urls.getValue(legacyThumb))},""" +
                """"width":{"integerValue":"300"},"height":{"integerValue":"200"},"order":{"integerValue":"1"}}}}]}},""" +
                """"originalImages":{"arrayValue":{"values":[""" +
                """{"mapValue":{"fields":{"url":${quoted(urls.getValue(original))},"storagePath":${quoted(original.value)},""" +
                """"width":{"integerValue":"300"},"height":{"integerValue":"200"},"order":{"integerValue":"0"}}}}]}}""",
        )
        return all
    }

    /** ログイン中のユーザー（[email]）として、[paths] にアプリの入口で画像を上げる（同時に 8 本まで）。上げた画像は後で消すために控える。 */
    private suspend fun uploadAll(email: String, paths: List<StoragePath>) {
        touched.getOrPut(email) { mutableListOf() } += paths
        val bytes = jpegBytes()
        for (chunk in paths.chunked(8)) {
            coroutineScope {
                chunk.map { path ->
                    async {
                        val cap = if (path.value.startsWith("users/")) WriteCapability.PROFILE_EDIT else WriteCapability.POST_CREATE
                        val uploaded = container.storageGateway.uploadJpeg(cap, path, bytes, 0)
                        check(uploaded is AppResult.Ok) { "上げられない: ${path.value} → $uploaded" }
                    }
                }.awaitAll()
            }
        }
    }

    /** 認証のアカウントを作る（作成で SDK はそのままログイン状態になる）。 */
    private suspend fun createAccount(email: String): Uid {
        val result = container.authRepository.createEmailAccount(email, PASSWORD)
        return (result as? AppResult.Ok)?.value ?: error("アカウントを作れない: $result")
    }

    private suspend fun idToken(): String {
        val user = requireNotNull(FirebaseAuth.getInstance().currentUser) { "ログインしていない" }
        return requireNotNull(user.getIdToken(false).await().token) { "ID トークンが取れない" }
    }

    /** 通報の対象にする投稿の表示の型（通報が使うのは投稿 ID と投稿者だけ）。 */
    private fun postView(postId: String, author: Uid) = PostView(
        postId = PostId(postId),
        userId = author,
        images = listOf(PostImageView("https://example.com/$postId.jpg", null, 300, 200, 0)),
        caption = null,
        hashtags = null,
        visibility = Visibility.PUBLIC,
        likesCount = 0,
        createdAt = null,
        capturedAt = null,
        timeOfDay = null,
        skyType = null,
    )

    /** `users/{uid}` の `blockedUserIds` の並び（無ければ空）。 */
    private fun blockedIdsOf(uid: Uid): List<String> {
        val values = EmulatorBackend.readFields("users", uid.value)
            ?.optJSONObject("blockedUserIds")?.optJSONObject("arrayValue")?.optJSONArray("values") ?: return emptyList()
        return (0 until values.length()).map { values.getJSONObject(it).getString("stringValue") }
    }

    /** [collection] のうち、`userId` が [uid] の文書の ID。 */
    private fun idsOwnedBy(collection: String, uid: Uid): List<String> =
        EmulatorBackend.listDocuments(collection).filter { it.second.str("userId") == uid.value }.map { it.first }

    /** 管理者の口で置く投稿。[comments] が null なら `commentsCount` を持たない旧い投稿にする。 */
    private fun seededPost(uid: Uid, id: String, visibility: String, likes: Long, comments: Long?): String =
        """"postId":{"stringValue":"$id"},"userId":${quoted(uid.value)},"visibility":{"stringValue":"$visibility"},""" +
            """"likesCount":{"integerValue":"$likes"},""" +
            (comments?.let { """"commentsCount":{"integerValue":"$it"},""" } ?: "") +
            """"createdAt":{"timestampValue":"2026-10-14T00:00:00Z"},""" +
            """"images":{"arrayValue":{"values":[{"mapValue":{"fields":{"url":{"stringValue":"http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/$id.jpg"},"order":{"integerValue":"0"}}}}]}}"""

    private fun like(uid: Uid, postId: String): String =
        """"userId":${quoted(uid.value)},"postId":{"stringValue":"$postId"},"createdAt":{"timestampValue":"2026-10-14T00:00:00Z"}"""

    private fun comment(uid: Uid, postId: String): String =
        """"userId":${quoted(uid.value)},"postId":{"stringValue":"$postId"},"content":{"stringValue":"きれいな空"},""" +
            """"createdAt":{"timestampValue":"2026-10-14T00:00:00Z"}"""

    private fun follow(follower: Uid, followee: Uid): String =
        """"followerId":${quoted(follower.value)},"followeeId":${quoted(followee.value)},"createdAt":{"timestampValue":"2026-10-14T00:00:00Z"}"""

    private fun draft(uid: Uid, id: String): String =
        """"id":{"stringValue":"$id"},"userId":${quoted(uid.value)},"createdAt":{"timestampValue":"2026-10-14T00:00:00Z"}"""

    private fun favorite(postId: String): String =
        """"postId":{"stringValue":"$postId"},"createdAt":{"timestampValue":"2026-10-14T00:00:00Z"}"""

    /** [index] 枚目の写真にする一色の JPEG を書く。 */
    private fun jpeg(name: String, index: Int): PickedPhoto {
        val file = File(dir, "$name.jpg")
        file.writeBytes(jpegBytes())
        return PickedPhoto(Uri.fromFile(file).toString(), index)
    }

    private fun jpegBytes(width: Int = 300, height: Int = 200): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(120, 170, 230)) }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    private suspend fun storageObject(path: String) = withContext(Dispatchers.IO) { EmulatorBackend.storageObject(path) }

    private suspend fun storageList(folder: String) = withContext(Dispatchers.IO) { EmulatorBackend.storageList(folder) }

    /** 文書の `images` の本体とサムネイルのパス（画像ごとに本体 → サムネイルの順）。 */
    private fun JSONObject.imagePaths(): List<String> {
        val values = optJSONObject("images")?.optJSONObject("arrayValue")?.optJSONArray("values") ?: return emptyList()
        return (0 until values.length())
            .map { values.getJSONObject(it).getJSONObject("mapValue").getJSONObject("fields") }
            .flatMap { listOfNotNull(it.str("storagePath"), it.str("thumbnailStoragePath")) }
    }

    /** キーの並びを揃えた文字列。書き換えた文書は、中身が同じでもエミュレータが返すキーの順が変わる（LikeEmulatorTest と同じ）。 */
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { "\"$it\":${canonical(value.get(it))}" }
        is org.json.JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        else -> JSONObject.wrap(value).let { if (it is String) JSONObject.quote(it) else it?.toString() ?: "null" }
    }

    /** REST の文字列の値（`{"stringValue":"…"}`）。 */
    private fun quoted(value: String): String = """{"stringValue":${JSONObject.quote(value)}}"""

    private fun JSONObject.str(key: String): String? = optJSONObject(key)?.optString("stringValue")

    /** REST では整数は文字列で届く（例: `{"integerValue":"0"}`）。整数でなければ null。 */
    private fun JSONObject.int(key: String): String? = optJSONObject(key)?.takeIf { it.has("integerValue") }?.getString("integerValue")

    private companion object {
        const val EMAIL_A = "sora@example.com"
        const val EMAIL_B = "kumo@example.com"
        const val PASSWORD = "pass1234"
        const val B_PUBLIC = "B-PUBLIC"
        const val B_FOLLOWERS = "B-FOLLOWERS"
        const val B_PRIVATE = "B-PRIVATE"
        const val B_PRIVATE_OLD = "B-PRIVATE-OLD"
        const val POST_GONE = "POST-GONE"
        const val POST_WITH_ORIGINALS = "ORIG-POST"

        /** 一括削除の上限（500 件）を跨ぐ投稿の数。 */
        const val MANY_POSTS = 505

        /** 取得の 1 ページ（50 件）を跨ぐ、片方の向きのフォローの数。 */
        const val MANY_FOLLOWS = 55

        /** 取得の 1 ページ（50 件）を跨ぐコメントの数。 */
        const val MANY_REACTIONS = 55

        /** 退会で一覧から消す、文書の無い画像の数（タスク 31.6 の「数百件」）。 */
        const val MANY_LEFTOVERS = 300
    }
}
