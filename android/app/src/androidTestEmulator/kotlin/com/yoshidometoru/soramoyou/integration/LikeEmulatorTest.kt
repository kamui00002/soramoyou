// ⭐️ M3 のいいねの書き込みが、リポジトリの rules をそのまま通ることを、rules の拒否の陽性対照とあわせて確かめる結合テスト（タスク 19.1・要件 9.3〜9.5・9.8）
package com.yoshidometoru.soramoyou.integration

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.firebase.auth.FirebaseAuth
import com.yoshidometoru.soramoyou.SoramoyouApplication
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.write.BuildConfigWriteGate
import com.yoshidometoru.soramoyou.di.AppContainer
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.tasks.await
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 実行の前に、開発機で `android/tools/start-firebase-emulators.sh` を起動しておく（rules はリポジトリのまま）。
 * 実行は `./gradlew :app:connectedEmulatorDebugAndroidTest`（仮想端末が要る）。
 *
 * いいねはアプリの部品（[AppContainer.likeRepository]）で書き、結果はエミュレータの管理者の口（[EmulatorBackend.readFields]）で確かめる。
 * 投稿は iOS 版が書く形（Post.swift の toFirestoreData の全項目）で、別のユーザー（[IOS_OWNER]）の持ち物として用意する。
 */
@RunWith(AndroidJUnit4::class)
class LikeEmulatorTest {

    private val container: AppContainer =
        ApplicationProvider.getApplicationContext<SoramoyouApplication>().container

    @Before
    fun resetEmulator() = runBlocking {
        container.authRepository.signOut()
        EmulatorBackend.reset()
        EmulatorBackend.resetAuth()
    }

    @After
    fun signOut() = runBlocking {
        container.authRepository.signOut()
        Unit
    }

    // ── マイルストーン ──

    @Test
    fun 検証用ビルドはM3以上で_いいねまでが有効() {
        // タスク 21.1 で検証用も M4 に上げたので、ここでは M3 までの書き込みを含むことだけを見る（M4 の導線の確認はタスク 25.1）
        val m3 = setOf(
            WriteCapability.ACCOUNT_CREATE, WriteCapability.ACCOUNT_REPAIR, WriteCapability.PROFILE_EDIT,
            WriteCapability.LIKE,
        )
        assertTrue(BuildConfigWriteGate.enabled.containsAll(m3))
        // 画面の導線（いいねボタン・投稿など）は、この writeGate の isEnabled で出し分ける
        assertEquals(BuildConfigWriteGate.enabled, container.writeGate.enabled)
        assertTrue(container.writeGate.isEnabled(WriteCapability.LIKE))
    }

    // ── 陽性対照：rules の拒否を見分けられること ──

    @Test
    fun いいね数と同時に更新日時を書く更新はrulesに断られ_いいね数だけなら通る() = runBlocking {
        // アプリの経路は契約（POST_LIKE_COUNTER）が更新日時を止めるので、ここでは契約を通さず、ログイン中のユーザーとして REST で直接書く
        createAccount(EMAIL)
        EmulatorBackend.seed("posts", POST_ID, iosPost(likesCount = 3))
        val token = idToken()

        val withUpdatedAt = EmulatorBackend.patchAsUser(
            "posts", POST_ID,
            """"likesCount":{"integerValue":"4"},"updatedAt":{"timestampValue":"2026-10-09T00:00:00Z"}""",
            listOf("likesCount", "updatedAt"), token,
        )
        assertEquals("更新日時を含む更新は rules が拒否する", 403, withUpdatedAt)
        assertEquals("3", EmulatorBackend.readFields("posts", POST_ID)?.int("likesCount"))

        // 対：同じトークン・同じ投稿で、いいね数の +1 だけなら通る（403 がトークンの不備でなく rules の判定であることの確かめ）
        val countOnly = EmulatorBackend.patchAsUser("posts", POST_ID, """"likesCount":{"integerValue":"4"}""", listOf("likesCount"), token)
        assertEquals("いいね数の +1 だけの更新は通る", 200, countOnly)
        assertEquals("4", EmulatorBackend.readFields("posts", POST_ID)?.int("likesCount"))
    }

    // ── 別のユーザーとしてのいいねと取り消し ──

    @Test
    fun iOS版の投稿へのいいねと取り消しがrulesを通り_投稿はいいね数しか変わらない() = runBlocking {
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("posts", POST_ID, iosPost(likesCount = 3))
        val before = requireNotNull(EmulatorBackend.readFields("posts", POST_ID))

        assertEquals(AppResult.Ok(4L), container.likeRepository.setLike(PostId(POST_ID), desired = true))
        val liked = requireNotNull(EmulatorBackend.readFields("posts", POST_ID))
        assertEquals("4", liked.int("likesCount"))
        assertEquals("いいね数以外は変わらない（updatedAt を含む）", withoutLikesCount(before), withoutLikesCount(liked))
        assertTrue(EmulatorBackend.readFields("likes", likeId(uid)) != null)
        assertEquals(AppResult.Ok(setOf(PostId(POST_ID))), container.likeRepository.likedAmong(listOf(PostId(POST_ID))))

        assertEquals(AppResult.Ok(3L), container.likeRepository.setLike(PostId(POST_ID), desired = false))
        val unliked = requireNotNull(EmulatorBackend.readFields("posts", POST_ID))
        assertEquals("取り消すと元の文書に戻る", canonical(before), canonical(unliked))
        assertNull(EmulatorBackend.readFields("likes", likeId(uid)))
        assertEquals(AppResult.Ok(emptySet<PostId>()), container.likeRepository.likedAmong(listOf(PostId(POST_ID))))
    }

    @Test
    fun いいね文書はuid_投稿IDの文書IDで_3項目だけで作られる() = runBlocking {
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("posts", POST_ID, iosPost(likesCount = 0))

        assertEquals(AppResult.Ok(1L), container.likeRepository.setLike(PostId(POST_ID), desired = true))

        val like = requireNotNull(EmulatorBackend.readFields("likes", likeId(uid))) { "likes/${likeId(uid)} が作られていない" }
        assertEquals(setOf("userId", "postId", "createdAt"), like.keys().asSequence().toSet())
        assertEquals(uid.value, like.str("userId"))
        assertEquals(POST_ID, like.str("postId"))
        assertTrue("createdAt は日時", like.optJSONObject("createdAt")?.has("timestampValue") == true)
    }

    @Test
    fun 既にいいね済みなら何も書かずに今の数を返す() = runBlocking {
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("posts", POST_ID, iosPost(likesCount = 3))
        assertEquals(AppResult.Ok(4L), container.likeRepository.setLike(PostId(POST_ID), desired = true))
        val like = EmulatorBackend.readFields("likes", likeId(uid)).toString()

        assertEquals(AppResult.Ok(4L), container.likeRepository.setLike(PostId(POST_ID), desired = true))

        assertEquals("4", EmulatorBackend.readFields("posts", POST_ID)?.int("likesCount"))
        assertEquals("いいね文書を作り直さない", like, EmulatorBackend.readFields("likes", likeId(uid)).toString())
    }

    @Test
    fun 読めないフォロワー限定の投稿へのいいねは権限拒否になり_何も書かない() = runBlocking {
        // 要件 9.8：フォローしていないので、投稿の読み取りで rules に断られる
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("posts", POST_ID, iosPost(likesCount = 3, visibility = "followers"))

        assertEquals(AppResult.Err(AppError.PermissionDenied), container.likeRepository.setLike(PostId(POST_ID), desired = true))

        assertEquals("3", EmulatorBackend.readFields("posts", POST_ID)?.int("likesCount"))
        assertNull(EmulatorBackend.readFields("likes", likeId(uid)))
    }

    // ── 下ごしらえ ──

    /** 認証のアカウントだけを作る（作成で SDK はそのままログイン状態になる）。いいねする側のユーザー。 */
    private suspend fun createAccount(email: String): Uid {
        val result = container.authRepository.createEmailAccount(email, PASSWORD)
        return (result as? AppResult.Ok)?.value ?: error("アカウントを作れない: $result")
    }

    /** ログイン中のユーザーの ID トークン（読み取りだけ。アプリの FirebaseAuth と同じインスタンスで、エミュレータの接続は済んでいる）。 */
    private suspend fun idToken(): String {
        val user = requireNotNull(FirebaseAuth.getInstance().currentUser) { "ログインしていない" }
        return requireNotNull(user.getIdToken(false).await().token) { "ID トークンが取れない" }
    }

    private fun likeId(uid: Uid) = "${uid.value}_$POST_ID"

    private fun withoutLikesCount(fields: JSONObject): String =
        canonical(JSONObject(fields.toString()).apply { remove("likesCount") })

    /** キーの並びを揃えた文字列。書き換えた文書は、中身が同じでもエミュレータが返すキーの順が変わる（2026-10-09 実測）。 */
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { "\"$it\":${canonical(value.get(it))}" }
        is org.json.JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        else -> JSONObject.wrap(value).let { if (it is String) JSONObject.quote(it) else it.toString() }
    }

    private fun JSONObject.str(key: String): String? = optJSONObject(key)?.optString("stringValue")

    /** REST では整数は文字列で届く（例: `{"integerValue":"0"}`）。整数でなければ null。 */
    private fun JSONObject.int(key: String): String? = optJSONObject(key)?.takeIf { it.has("integerValue") }?.getString("integerValue")

    private companion object {
        const val EMAIL = "sora@example.com"
        const val PASSWORD = "pass1234"
        const val POST_ID = "IOS-POST"
        const val IOS_OWNER = "u-ios"

        /**
         * iOS 版が書く投稿の全項目（出典は PostDocumentReaderTest の「iOS版だけが持つ項目」と同じ：Post.swift:118-205 の toFirestoreData、
         * ImageInfo・ExternalEditInfo・Location・EditRecipe の toFirestoreData）。rules の isCountOnlyUpdate は commentsCount も読むので必ず含める。
         */
        fun iosPost(likesCount: Int, visibility: String = "public"): String {
            val externalEditInfo =
                """{"mapValue":{"fields":{"hasAdjustments":{"booleanValue":true},"isHDR":{"booleanValue":false},""" +
                    """"isLivePhoto":{"booleanValue":true},"isPanorama":{"booleanValue":false},""" +
                    """"formatIdentifier":{"stringValue":"com.apple.photo"},"exifCapturedAt":{"timestampValue":"2025-08-31T17:06:40Z"}}}}"""
            val imageFields =
                """"url":{"stringValue":"http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/ios.jpg"},"thumbnail":{"stringValue":"http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/ios_thumb.jpg"},""" +
                    """"width":{"integerValue":"3024"},"height":{"integerValue":"4032"},"order":{"integerValue":"0"},""" +
                    """"storagePath":{"stringValue":"posts/$IOS_OWNER/public/IMG.jpg"},""" +
                    """"thumbnailStoragePath":{"stringValue":"thumbnails/$IOS_OWNER/public/IMG_thumb.jpg"}"""
            val image = """{"mapValue":{"fields":{$imageFields,"externalEditInfo":$externalEditInfo}}}"""
            val originalImage = """{"mapValue":{"fields":{$imageFields}}}"""
            return """"postId":{"stringValue":"$POST_ID"},"userId":{"stringValue":"$IOS_OWNER"},""" +
                """"images":{"arrayValue":{"values":[$image]}},"visibility":{"stringValue":"$visibility"},""" +
                """"likesCount":{"integerValue":"$likesCount"},"commentsCount":{"integerValue":"1"},""" +
                """"createdAt":{"timestampValue":"2025-09-01T04:26:40Z"},"updatedAt":{"timestampValue":"2025-09-01T04:26:40Z"},""" +
                """"caption":{"stringValue":"iOS から"},"hashtags":{"arrayValue":{"values":[{"stringValue":"空"}]}},""" +
                """"mood":{"stringValue":"wistful"},"frameId":{"stringValue":"frame-01"},"frameCaption":{"stringValue":"ある日の空"},""" +
                """"frameTextColorHex":{"stringValue":"#FFFFFF"},"frameFontStyle":{"stringValue":"serif"},""" +
                """"postKind":{"stringValue":"collage"},"collageLayout":{"stringValue":"grid2x2"},""" +
                """"panelLabels":{"arrayValue":{"values":[{"stringValue":"朝"},{"stringValue":"昼"},{"stringValue":"夜"},{"stringValue":"雨"}]}},""" +
                """"location":{"mapValue":{"fields":{"latitude":{"doubleValue":35.68},"longitude":{"doubleValue":139.76},""" +
                """"city":{"stringValue":"千代田区"},"prefecture":{"stringValue":"東京都"}}}},""" +
                """"skyColors":{"arrayValue":{"values":[{"stringValue":"#87CEEB"},{"stringValue":"#FFA07A"}]}},""" +
                """"colorTemperature":{"integerValue":"5600"},"timeOfDay":{"stringValue":"morning"},"skyType":{"stringValue":"clear"},""" +
                """"capturedAt":{"timestampValue":"2025-08-31T17:06:40Z"},"originalImages":{"arrayValue":{"values":[$originalImage]}},""" +
                """"editSettings":{"mapValue":{"fields":{"appliedFilter":{"stringValue":"warm"},"brightness":{"doubleValue":0.1}}}},""" +
                """"editRecipeV1":{"mapValue":{"fields":{"schemaVersion":{"integerValue":"1"},"appliedFilter":{"stringValue":"warm"}}}}"""
        }
    }
}
