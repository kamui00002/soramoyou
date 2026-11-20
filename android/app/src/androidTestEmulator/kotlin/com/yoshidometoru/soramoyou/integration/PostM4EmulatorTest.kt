// ⭐️ M4（投稿・画像・自分の投稿の削除）の書き込みが、リポジトリの rules をそのまま通ることを、rules の拒否の陽性対照とあわせて確かめる結合テスト（タスク 25.1・要件 7.3・7.10・7.11・9.3・10.11）
package com.yoshidometoru.soramoyou.integration

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.firebase.auth.FirebaseAuth
import com.yoshidometoru.soramoyou.SoramoyouApplication
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.repository.FeedPage
import com.yoshidometoru.soramoyou.data.repository.PostDraft
import com.yoshidometoru.soramoyou.data.repository.PostPhoto
import com.yoshidometoru.soramoyou.di.AppContainer
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
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
 * 投稿・いいね・削除はアプリの部品（[AppContainer] の postPublisher・likeRepository・postDeleter・storageGateway）で行い、
 * 結果はエミュレータの管理者の口（[EmulatorBackend]）で確かめる（読み取りの不具合と書き込みの不具合を混ぜない）。
 *
 * rules の陽性対照は 2 種類ある。
 * - テストの中：別のユーザーとして、他人のパスへ上げる・他人の画像と投稿を消すと断られること（断られた直後に、自分のものなら通る対も見る）
 * - テストの外（タスク 25.1 の記録）：エミュレータが読む `storage.rules` の写しの形式・大きさの条件を厳しくすると、
 *   アップロードを含むテストが赤になること。アプリの入口は形式を `image/jpeg` に固定し、5MB 以上を送る前に断るので、入口からは作れない
 */
@RunWith(AndroidJUnit4::class)
class PostM4EmulatorTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val container: AppContainer =
        ApplicationProvider.getApplicationContext<SoramoyouApplication>().container
    private val dir = File(context.cacheDir, "post-m4-emulator-test").apply { mkdirs() }

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
        // Storage のエミュレータには一括で消す口が無いので、アプリの入口で 1 つずつ消す（無ければ NotFound で構わない）
        for ((email, paths) in touched) {
            container.authRepository.signOut()
            if (container.authRepository.signIn(email, PASSWORD) !is AppResult.Ok) continue
            for (path in paths) container.storageGateway.delete(WriteCapability.POST_CREATE, path)
        }
        container.authRepository.signOut()
        dir.deleteRecursively()
        Unit
    }

    // ── マイルストーン ──

    @Test
    fun 検証用ビルドはM4以上で_M4までの書き込みが有効() {
        // タスク 29.1 で検証用も M5 に上げたので、ここでは M4 までの書き込みを含むことだけを見る（M5 の導線の確認はタスク 29.2 以降）。
        // 写しの関数（writeCapabilitiesOf）で比べると同じ関数どうしの比較になるので、期待する集合はここに書き下す
        val m4 = setOf(
            WriteCapability.ACCOUNT_CREATE, WriteCapability.ACCOUNT_REPAIR, WriteCapability.PROFILE_EDIT,
            WriteCapability.LIKE,
            WriteCapability.POST_CREATE, WriteCapability.POSTS_COUNT_SYNC, WriteCapability.POST_DELETE,
        )
        assertTrue(container.writeGate.enabled.containsAll(m4))
    }

    // ── 投稿の作成と画像のアップロード ──

    @Test
    fun 公開_フォロワーのみ_非公開の投稿がrulesを通り_画像は公開範囲のフォルダにJPEGで5MB未満で置かれる() = runBlocking {
        val uid = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(uid, EMAIL_A))

        for (visibility in Visibility.entries) {
            val postId = publish(EMAIL_A, visibility, photos = 1)
            val fields = requireNotNull(EmulatorBackend.readFields("posts", postId.value)) { "${visibility.raw} の投稿が無い" }
            assertEquals(visibility.raw, fields.str("visibility"))
            assertEquals(uid.value, fields.str("userId"))
            val image = fields.images().single()
            assertEquals("posts/${uid.value}/${visibility.raw}/", image.str("storagePath")?.substringBeforeLast('/') + "/")
            assertEquals("thumbnails/${uid.value}/${visibility.raw}/", image.str("thumbnailStoragePath")?.substringBeforeLast('/') + "/")
            for (path in listOfNotNull(image.str("storagePath"), image.str("thumbnailStoragePath"))) {
                val meta = requireNotNull(storageObject(path)) { "上げたはずのオブジェクトが無い: $path" }
                assertEquals(path, "image/jpeg", meta.getString("contentType"))
                val size = meta.getString("size").toLong()
                assertTrue("$path の大きさ $size が 0 か 5MB 以上", size in 1 until 5L * 1024 * 1024)
            }
        }
        // 全投稿数は 3、公開投稿数は公開の 1 件だけ
        assertEquals("3", EmulatorBackend.readFields("users", uid.value)?.int("postsCount"))
        assertEquals("1", EmulatorBackend.readFields("publicProfiles", uid.value)?.int("postsCount"))
    }

    @Test
    fun 他人のフォルダへの画像のアップロードはstorage_rulesに断られ_自分のフォルダなら通る() = runBlocking {
        val owner = createAccount(EMAIL_A)
        container.authRepository.signOut()
        val intruder = createAccount(EMAIL_B)
        val bytes = jpegBytes()

        val others = StoragePath.postImage(owner, Visibility.PUBLIC, "INTRUDER")
        assertEquals(
            AppResult.Err(AppError.PermissionDenied),
            container.storageGateway.uploadJpeg(WriteCapability.POST_CREATE, others, bytes, 0),
        )
        assertNull(storageObject(others.value))

        // 対：同じユーザー・同じ入口・同じバイト列で、自分のフォルダなら通る（断られたのが入口やトークンの不備でなく rules の判定であることの確かめ）
        val own = StoragePath.postImage(intruder, Visibility.PUBLIC, "OWN")
        touched.getOrPut(EMAIL_B) { mutableListOf() } += own
        assertTrue(container.storageGateway.uploadJpeg(WriteCapability.POST_CREATE, own, bytes, 0) is AppResult.Ok)
        assertNotNull(storageObject(own.value))
    }

    // ── 別のユーザーのいいね ──

    @Test
    fun 別のユーザーとして_Androidで作った公開の投稿にいいねでき_フォロワーのみの投稿には断られる() = runBlocking {
        val owner = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(owner, EMAIL_A))
        val publicPost = publish(EMAIL_A, Visibility.PUBLIC, photos = 1)
        val followersPost = publish(EMAIL_A, Visibility.FOLLOWERS, photos = 1)
        val before = requireNotNull(EmulatorBackend.readFields("posts", publicPost.value))
        container.authRepository.signOut()
        val liker = createAccount(EMAIL_B)

        assertEquals(AppResult.Ok(1L), container.likeRepository.setLike(publicPost, desired = true))
        val liked = requireNotNull(EmulatorBackend.readFields("posts", publicPost.value))
        assertEquals("1", liked.int("likesCount"))
        assertEquals("いいね数以外は変わらない（updatedAt を含む）", withoutLikesCount(before), withoutLikesCount(liked))
        val like = requireNotNull(EmulatorBackend.readFields("likes", "${liker.value}_${publicPost.value}"))
        assertEquals(setOf("userId", "postId", "createdAt"), like.keys().asSequence().toSet())

        // フォローしていない人のフォロワーのみの投稿は、読めないので何も書かない（要件 9.8）
        assertEquals(AppResult.Err(AppError.PermissionDenied), container.likeRepository.setLike(followersPost, desired = true))
        assertNull(EmulatorBackend.readFields("likes", "${liker.value}_${followersPost.value}"))
        assertEquals("0", EmulatorBackend.readFields("posts", followersPost.value)?.int("likesCount"))

        assertEquals(AppResult.Ok(0L), container.likeRepository.setLike(publicPost, desired = false))
        assertNull(EmulatorBackend.readFields("likes", "${liker.value}_${publicPost.value}"))
        assertEquals("取り消すと元の文書に戻る", canonical(before), canonical(requireNotNull(EmulatorBackend.readFields("posts", publicPost.value))))
    }

    // ── 自分の投稿の削除 ──

    @Test
    fun 自分の投稿を消すと文書と本体とサムネイルが消えて投稿数が数え直され_他人には消せない() = runBlocking {
        val owner = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(owner, EMAIL_A))
        val postId = publish(EMAIL_A, Visibility.FOLLOWERS, photos = 2)
        val paths = requireNotNull(EmulatorBackend.readFields("posts", postId.value)).imagePaths()
        assertEquals(4, paths.size)
        // 陽性対照：消す前に 4 つとも有る。有ったものが消えるので、後の「無い」は削除の結果である
        assertEquals(listOf(true, true, true, true), paths.map { storageObject(it) != null })
        assertEquals("1", EmulatorBackend.readFields("users", owner.value)?.int("postsCount"))

        // rules の陽性対照：別のユーザーは、文書も画像も消せない
        container.authRepository.signOut()
        val other = createAccount(EMAIL_B)
        val token = idToken()
        assertEquals("他人の投稿の文書の削除は rules が拒否する", 403, EmulatorBackend.deleteAsUser("posts", postId.value, token))
        assertEquals(
            AppResult.Err(AppError.PermissionDenied),
            container.storageGateway.delete(WriteCapability.POST_DELETE, StoragePath(paths[0])),
        )
        assertNotNull(EmulatorBackend.readFields("posts", postId.value))
        assertNotNull(storageObject(paths[0]))
        // 対：同じトークンで、自分の投稿なら消せる（403 がトークンの不備でなく、持ち主かどうかの判定であることの確かめ）
        EmulatorBackend.seed("posts", OTHERS_OWN_POST, feedPost(other, OTHERS_OWN_POST, minute = 0))
        assertEquals("自分の投稿の文書の削除は通る", 200, EmulatorBackend.deleteAsUser("posts", OTHERS_OWN_POST, token))
        assertNull(EmulatorBackend.readFields("posts", OTHERS_OWN_POST))

        container.authRepository.signOut()
        assertEquals(AppResult.Ok(Unit), container.authRepository.signIn(EMAIL_A, PASSWORD))
        // 知らせ（DeletedPosts）は後から集め始めると届かないので、削除の前に集め始めておく。
        // 待つ時間の上限は削除が終わってから数える（削除そのものは、画像 1 つにつき最長 30 秒かかりうる）
        val notified = async(start = CoroutineStart.UNDISPATCHED) { container.deletedPosts.events.first() }
        assertEquals(AppResult.Ok(Unit), container.postDeleter.delete(postId))

        assertEquals(postId, withTimeout(5_000) { notified.await() })
        assertNull(EmulatorBackend.readFields("posts", postId.value))
        for (path in paths) assertNull("消えているはず: $path", storageObject(path))
        assertEquals("0", EmulatorBackend.readFields("users", owner.value)?.int("postsCount"))
        assertEquals("0", EmulatorBackend.readFields("publicProfiles", owner.value)?.int("postsCount"))
    }

    @Test
    fun 元画像つきでパスの無い旧データも混じる投稿を消すと_元画像とURLから解決した画像も消える() = runBlocking {
        // タスク 24 の未確認（元画像つきの投稿の削除）。元画像は iOS だけが作るので、画像はアプリの入口で上げ、文書は管理者の口で作る。
        // 2 枚目は storagePath・thumbnailStoragePath の無い旧データの形で、エミュレータのダウンロード URL（http://10.0.2.2:9199/v0/b/…/o/…）から解決させる
        val uid = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(uid, EMAIL_A))
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
        // 陽性対照：消す前に 5 つとも有る
        assertEquals(List(all.size) { true }, all.map { storageObject(it.value) != null })

        assertEquals(AppResult.Ok(Unit), container.postDeleter.delete(PostId(POST_WITH_ORIGINALS)))

        assertNull(EmulatorBackend.readFields("posts", POST_WITH_ORIGINALS))
        for (path in all) assertNull("消えているはず: ${path.value}", storageObject(path.value))
    }

    @Test
    fun フィードの続きの起点だった投稿を消しても_続きが読める() = runBlocking {
        // タスク 24 の未確認（消した投稿が一覧の続きの起点だった場合）。続きの起点は読んだ文書のスナップショットで、
        // Firestore はその並びの値（createdAt と文書 ID）から続きを読むので、文書が消えても続きは読めるはず＝それを実測する
        val uid = createAccount(EMAIL_A)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(uid, EMAIL_A))
        val ids = (1..21).map { "CURSOR-%02d".format(it) } // 01 が最新、21 が最古
        ids.forEachIndexed { index, id ->
            EmulatorBackend.seed("posts", id, feedPost(uid, id, minute = 59 - index))
        }

        val first = loadFeed(null)
        assertEquals(ids.take(20), first.posts.map { it.postId.value })
        assertFalse(first.reachedEnd)

        // 1 ページ目の最後（＝続きの起点）を消す
        assertEquals(AppResult.Ok(Unit), container.postDeleter.delete(PostId(ids[19])))
        assertNull(EmulatorBackend.readFields("posts", ids[19]))

        val second = loadFeed(first.next)
        assertEquals(listOf(ids[20]), second.posts.map { it.postId.value })
        assertTrue(second.reachedEnd)
    }

    // ── 下ごしらえ ──

    /** ログイン中のユーザー（[email]）として、[photos] 枚の写真で [visibility] の投稿を公開し、その投稿 ID を返す。上げた画像は後で消すために控える。 */
    private suspend fun publish(email: String, visibility: Visibility, photos: Int): PostId {
        // 編集なし（今までの「フィルターなし」）。撮影日時は入力の値から使う（A2）ので、撮影日時の無い写真として null（形は Kiro android-edit-tools K0）
        val draft = PostDraft(
            photos = (0 until photos).map { PostPhoto(jpeg("${visibility.raw}-$it", 300, 200, it), PhotoEdit.NONE) },
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

    private suspend fun loadFeed(after: com.yoshidometoru.soramoyou.data.remote.read.RawCursor?): FeedPage =
        when (val result = container.feedRepository.loadPage(after)) {
            is AppResult.Ok -> result.value
            is AppResult.Err -> error("フィードが読めない: ${result.error}")
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

    /** [width]×[height] の一色の JPEG を書き、[index] 枚目の写真にする。 */
    private fun jpeg(name: String, width: Int, height: Int, index: Int): PickedPhoto {
        val file = File(dir, "$name.jpg")
        file.writeBytes(jpegBytes(width, height))
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

    /** フィードが読める最小の公開投稿（画像の URL は、検証用のビルドの読み取りの部品が通すエミュレータの Storage の形。Storage には何も無い）。 */
    private fun feedPost(uid: Uid, id: String, minute: Int): String =
        """"postId":{"stringValue":"$id"},"userId":{"stringValue":"${uid.value}"},"visibility":{"stringValue":"public"},""" +
            """"likesCount":{"integerValue":"0"},"commentsCount":{"integerValue":"0"},""" +
            """"createdAt":{"timestampValue":"2026-10-11T00:%02d:00Z"},""".format(minute) +
            """"images":{"arrayValue":{"values":[{"mapValue":{"fields":{"url":{"stringValue":"http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/$id.jpg"},"order":{"integerValue":"0"}}}}]}}"""

    /** 文書の `images` の各要素の `fields`。 */
    private fun JSONObject.images(): List<JSONObject> {
        val values = optJSONObject("images")?.optJSONObject("arrayValue")?.optJSONArray("values") ?: return emptyList()
        return (0 until values.length()).map { values.getJSONObject(it).getJSONObject("mapValue").getJSONObject("fields") }
    }

    /** 文書の `images` の本体とサムネイルのパス（画像ごとに本体 → サムネイルの順）。 */
    private fun JSONObject.imagePaths(): List<String> =
        images().flatMap { listOfNotNull(it.str("storagePath"), it.str("thumbnailStoragePath")) }

    private fun withoutLikesCount(fields: JSONObject): String =
        canonical(JSONObject(fields.toString()).apply { remove("likesCount") })

    /** キーの並びを揃えた文字列。書き換えた文書は、中身が同じでもエミュレータが返すキーの順が変わる（LikeEmulatorTest と同じ）。 */
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { "\"$it\":${canonical(value.get(it))}" }
        is org.json.JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        else -> JSONObject.wrap(value).let { if (it is String) JSONObject.quote(it) else it.toString() }
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
        const val POST_WITH_ORIGINALS = "ORIG-POST"
        const val OTHERS_OWN_POST = "OTHERS-OWN"
    }
}
