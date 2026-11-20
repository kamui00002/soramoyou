// ⭐️ 投稿の公開のアップロードと後片付けが、リポジトリの storage.rules をそのまま通ることを、消す前に有ることを見る陽性対照とあわせて確かめ、アプリの配線どおりの公開で iOS が読める文書と投稿数ができることを確かめる結合テスト（タスク 23.2・23.3・要件 7.3・7.10・7.11・7.18・7.19）
package com.yoshidometoru.soramoyou.integration

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.SoramoyouApplication
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.IosPostReadResult
import com.yoshidometoru.soramoyou.contract.document.IosPostReaderContract
import com.yoshidometoru.soramoyou.contract.document.UploadedImage
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.data.image.ImagePipeline
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.image.PreparedPostImage
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.repository.DefaultPostPublisher
import com.yoshidometoru.soramoyou.data.repository.PostDocumentSaver
import com.yoshidometoru.soramoyou.data.repository.PostDraft
import com.yoshidometoru.soramoyou.data.repository.PostPhoto
import com.yoshidometoru.soramoyou.data.repository.PublishState
import com.yoshidometoru.soramoyou.di.AppContainer
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 実行の前に、開発機で `android/tools/start-firebase-emulators.sh` を起動しておく（rules はリポジトリのまま）。
 * 実行は `./gradlew :app:connectedEmulatorDebugAndroidTest`（仮想端末が要る）。
 *
 * アップロードと後片付けのテストは、アプリの部品（Storage の入口・写真の変換）で組んだ [DefaultPostPublisher] で行い、
 * 文書の保存の継ぎ目だけをテストの偽物にする。文書の保存（タスク 23.3）のテストは、AppContainer の postPublisher をそのまま使う。Storage の結果はエミュレータの管理者の口（[EmulatorBackend.storageObject]）で確かめる。
 * 画像の ID は決まった並び（E2E-1, E2E-2, …）にして、確かめるパスを先に知っておく。
 */
@RunWith(AndroidJUnit4::class)
class PostPublisherEmulatorTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val container: AppContainer = ApplicationProvider.getApplicationContext<SoramoyouApplication>().container
    private val dir = File(context.cacheDir, "post-publisher-emulator-test").apply { mkdirs() }

    /** テストが上げたかもしれないパス。終わったらアプリの入口で消す（Storage のエミュレータには一括で消す口が無い）。 */
    private val touched = mutableListOf<StoragePath>()

    @Before
    fun resetEmulator() = runBlocking {
        container.authRepository.signOut()
        EmulatorBackend.reset()
        EmulatorBackend.resetAuth()
    }

    @After
    fun cleanUp() = runBlocking {
        for (path in touched) container.storageGateway.delete(WriteCapability.POST_CREATE, path) // 無ければ NotFound（構わない）
        container.authRepository.signOut()
        dir.deleteRecursively()
        Unit
    }

    @Test
    fun 写真を上げると_本体とサムネイルがJPEGとして公開範囲のフォルダに置かれ_保存の継ぎ目に実際の寸法が渡る() = runBlocking {
        val uid = createAccount()
        var saved: List<UploadedImage> = emptyList()
        val publisher = publisher(uid) { _, images -> saved = images; AppResult.Ok(Unit) }

        val result = publisher.publish(draft(listOf(jpeg("a", 300, 200, 0), jpeg("b", 120, 400, 1)), "", Visibility.FOLLOWERS))

        assertEquals(AppResult.Ok(PostId("E2E-1")), result)
        val paths = listOf(
            "posts/${uid.value}/followers/E2E-2.jpg", "thumbnails/${uid.value}/followers/E2E-2_thumb.jpg",
            "posts/${uid.value}/followers/E2E-3.jpg", "thumbnails/${uid.value}/followers/E2E-3_thumb.jpg",
        )
        for (path in paths) {
            val meta = requireNotNull(storageObject(path)) { "上げたはずのオブジェクトが無い: $path" }
            assertEquals(path, "image/jpeg", meta.getString("contentType"))
        }
        assertEquals(listOf(300 to 200, 120 to 400), saved.map { it.widthPx to it.heightPx })
        assertEquals(listOf(paths[0], paths[2]), saved.map { it.storagePath.value })
        assertEquals(listOf(paths[1], paths[3]), saved.map { it.thumbnailStoragePath.value })
    }

    @Test
    fun 文書の保存に失敗すると_上げた本体とサムネイルがStorageから消える() = runBlocking {
        // 陽性対照：保存の継ぎ目の中（後片付けの直前）で 4 つとも有ることを確かめる。有ったものが消えるので、「無い」は後片付けの結果である
        val uid = createAccount()
        val paths = listOf(
            "posts/${uid.value}/public/E2E-2.jpg", "thumbnails/${uid.value}/public/E2E-2_thumb.jpg",
            "posts/${uid.value}/public/E2E-3.jpg", "thumbnails/${uid.value}/public/E2E-3_thumb.jpg",
        )
        var existedBeforeRollback = emptyList<Boolean>()
        val publisher = publisher(uid) { _, _ ->
            existedBeforeRollback = paths.map { storageObject(it) != null }
            AppResult.Err(AppError.Unknown("テストの保存の失敗"))
        }

        val result = publisher.publish(draft(listOf(jpeg("a", 300, 200, 0), jpeg("b", 300, 200, 1)), ""))

        assertEquals(AppResult.Err(AppError.Unknown("テストの保存の失敗")), result)
        assertEquals(listOf(true, true, true, true), existedBeforeRollback)
        for (path in paths) assertNull("後片付けで消えているはず: $path", storageObject(path))
    }

    @Test
    fun 読めない写真で止まると_それまでに上げた画像が消える() = runBlocking {
        // 陽性対照：2 枚目（読めない写真）の変換の直前に、1 枚目の本体とサムネイルが有ることを確かめる。有ったものが消えるので、
        // 「無い」は後片付けの結果である（兄弟の「文書の保存に失敗すると…」と同じ形。全体レビュー 4 回目 Q40）
        val uid = createAccount()
        val paths = listOf("posts/${uid.value}/public/E2E-2.jpg", "thumbnails/${uid.value}/public/E2E-2_thumb.jpg")
        val broken = File(dir, "broken.jpg").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        var existedBeforeFailure = emptyList<Boolean>()
        val pipeline = object : ImagePipeline by container.imagePipeline {
            override suspend fun preparePost(photo: PickedPhoto, edit: PhotoEdit): AppResult<PreparedPostImage> {
                if (photo.index == 1) existedBeforeFailure = paths.map { storageObject(it) != null }
                return container.imagePipeline.preparePost(photo, edit)
            }
        }
        val publisher = publisher(uid, pipeline) { _, _ -> error("保存まで進まないはず") }

        val result = publisher.publish(
            draft(listOf(jpeg("a", 300, 200, 0), PickedPhoto(Uri.fromFile(broken).toString(), 1)), ""),
        )

        assertEquals(AppResult.Err(AppError.ImageUnreadable(1)), result)
        for (path in paths) assertNull("後片付けで消えているはず: $path", storageObject(path))
        assertEquals("2 枚目の変換の前に、1 枚目の本体とサムネイルが上がっていた", listOf(true, true), existedBeforeFailure)
    }

    @Test
    fun アプリの配線どおりに公開すると_iOSが読める投稿の文書ができ_投稿数が数え直される() = runBlocking {
        // タスク 23.3：保存の継ぎ目も本物（AppContainer の postPublisher）。投稿数は 0 で作っておき、1 になることで数え直しを確かめる。
        // 作った投稿の知らせ（CreatedPosts）は、ここでは確かめない。知らせは単体テスト（DefaultPostDocumentSaverTest・本物の読み取りの部品）で
        // 確かめる（全体レビュー 4 回目 R11）
        val uid = createAccount()
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(uid, EMAIL))
        assertEquals("0", EmulatorBackend.readFields("users", uid.value)?.int("postsCount"))
        assertEquals("0", EmulatorBackend.readFields("publicProfiles", uid.value)?.int("postsCount"))
        val result = container.postPublisher.publish(
            draft(listOf(jpeg("a", 300, 200, 0), jpeg("b", 120, 400, 1)), "  夕焼け #空  "),
        )

        val postId = (result as? AppResult.Ok)?.value ?: error("公開できない: $result")
        val raw = requireNotNull((container.firestoreReader.get(DocRef.post(postId), ReadSource.SERVER) as AppResult.Ok).value)
        @Suppress("UNCHECKED_CAST")
        val images = raw.data["images"] as List<Map<String, Any?>>
        for (image in images) touched += listOf(StoragePath(image["storagePath"] as String), StoragePath(image["thumbnailStoragePath"] as String))

        assertEquals(IosPostReadResult.Readable(emptyList()), IosPostReaderContract.judge(raw.data))
        assertEquals(postId.value, raw.data["postId"])
        assertEquals(uid.value, raw.data["userId"])
        assertEquals("public", raw.data["visibility"])
        assertEquals("前後の空白を取り除いて書く", "夕焼け #空", raw.data["caption"])
        assertEquals(listOf("空"), raw.data["hashtags"])
        assertEquals(0L, raw.data["likesCount"])
        assertNull("撮影日時の無い写真なのでキーごと書かない", raw.data["capturedAt"])
        assertEquals(listOf(300L to 200L, 120L to 400L), images.map { it["width"] to it["height"] })
        assertEquals("1", EmulatorBackend.readFields("users", uid.value)?.int("postsCount"))
        assertEquals("1", EmulatorBackend.readFields("publicProfiles", uid.value)?.int("postsCount"))
        assertEquals(PublishState.Succeeded(postId), container.postPublisher.state.value)
    }

    // ── 下ごしらえ ──

    /**
     * アプリの部品で組んだ公開の部品。画像の ID は E2E-1（投稿）, E2E-2, … の順。上げうるパスは後で消すために控える。
     * [pipeline] は写真の変換（既定はアプリの部品。変換の前に Storage を覗くテストだけが包んだものを渡す）。
     */
    private fun publisher(uid: Uid, pipeline: ImagePipeline = container.imagePipeline, saver: PostDocumentSaver): DefaultPostPublisher {
        var last = 0
        return DefaultPostPublisher(
            storage = container.storageGateway,
            pipeline = pipeline,
            saver = saver,
            analytics = container.analytics,
            currentUid = { uid },
            newId = {
                val id = "E2E-${++last}"
                for (visibility in Visibility.entries) {
                    touched += StoragePath.postImage(uid, visibility, id)
                    touched += StoragePath.postThumbnail(uid, visibility, id)
                }
                id
            },
        )
    }

    /** 認証のアカウントを作る（作成で SDK はそのままログイン状態になる）。 */
    private suspend fun createAccount(): Uid {
        val result = container.authRepository.createEmailAccount(EMAIL, "pass1234")
        return (result as? AppResult.Ok)?.value ?: error("アカウントを作れない: $result")
    }

    /**
     * [photos] を編集なし（[PhotoEdit.NONE]。今までの「フィルターなし」と同じ）で投稿する入力（形は Kiro android-edit-tools K0：design.md:609-615）。
     * 撮影日時は入力の値（[PostDraft.firstPhotoCapturedAt]）から使うので、撮影日時の無い写真として null にしておく（A2）。
     */
    private fun draft(photos: List<PickedPhoto>, caption: String, visibility: Visibility = Visibility.PUBLIC) =
        PostDraft(photos = photos.map { PostPhoto(it, PhotoEdit.NONE) }, caption = caption, visibility = visibility, firstPhotoCapturedAt = null)

    /** [width]×[height] の一色の JPEG を書き、[index] 枚目の写真にする。 */
    private fun jpeg(name: String, width: Int, height: Int, index: Int): PickedPhoto {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(120, 170, 230)) }
        val file = File(dir, "$name.jpg")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        bitmap.recycle()
        return PickedPhoto(Uri.fromFile(file).toString(), index)
    }

    private suspend fun storageObject(path: String) = withContext(Dispatchers.IO) { EmulatorBackend.storageObject(path) }

    /** REST では整数は文字列で届く（例: `{"integerValue":"0"}`）。整数でなければ null（PostsCountEmulatorTest と同じ）。 */
    private fun JSONObject.int(key: String): String? = optJSONObject(key)?.takeIf { it.has("integerValue") }?.getString("integerValue")

    private companion object {
        const val EMAIL = "sora@example.com"
    }
}
