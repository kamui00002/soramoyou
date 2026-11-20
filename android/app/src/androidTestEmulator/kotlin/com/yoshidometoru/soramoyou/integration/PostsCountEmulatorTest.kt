// ⭐️ 投稿数の数え直し（サーバーでの集計と postsCount の更新）が、リポジトリの rules をそのまま通ることを、集計の拒否の陽性対照とあわせて確かめる結合テスト（タスク 23.1・要件 1.4・7.19・7.20）
package com.yoshidometoru.soramoyou.integration

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.SoramoyouApplication
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.remote.read.CountSpec
import com.yoshidometoru.soramoyou.di.AppContainer
import kotlinx.coroutines.runBlocking
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
 * 数え直しはアプリの部品（[AppContainer.postsCountSynchronizer]）で行い、結果はエミュレータの管理者の口（[EmulatorBackend.readFields]）で確かめる。
 * 投稿は管理者の口で用意する（集計は中身を読まないので、rules の read が見る `userId`・`visibility` と、並びの `createdAt` だけを持たせる）。
 */
@RunWith(AndroidJUnit4::class)
class PostsCountEmulatorTest {

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

    // ── 陽性対照：rules が集計を判定していること ──

    @Test
    fun 他人の全投稿数の集計はrulesに断られ_公開範囲で絞れば数えられる() = runBlocking {
        // 他人の投稿を公開範囲で絞らずに数えると、非公開の投稿を含みうるので rules（posts の read）が集計ごと拒否する。
        // 同じログインで公開投稿に絞れば通るので、拒否はログインの不備でなく rules の判定である
        createAccount(EMAIL)
        seedPost("O1", OTHER, "public")
        seedPost("O2", OTHER, "private")

        assertEquals(AppResult.Err(AppError.PermissionDenied), container.firestoreReader.count(CountSpec.OwnPosts(Uid(OTHER))))
        assertEquals(AppResult.Ok(1L), container.firestoreReader.count(CountSpec.OwnPublicPosts(Uid(OTHER))))
    }

    // ── 本人の数え直し ──

    @Test
    fun 自分の投稿を数え直し_usersに全投稿数を_publicProfilesに公開投稿数だけを書く() = runBlocking {
        assertTrue(container.writeGate.isEnabled(WriteCapability.POSTS_COUNT_SYNC))
        val uid = createAccount(EMAIL)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(uid, EMAIL))
        seedPost("P1", uid.value, "public")
        seedPost("P2", uid.value, "public")
        seedPost("P3", uid.value, "followers")
        seedPost("P4", uid.value, "private")
        seedPost("O1", OTHER, "public") // 他人の投稿は数えない
        val userBefore = requireNotNull(EmulatorBackend.readFields("users", uid.value))
        val profileBefore = requireNotNull(EmulatorBackend.readFields("publicProfiles", uid.value))

        assertEquals(AppResult.Ok(4L), container.postsCountSynchronizer.recount(uid))

        val user = requireNotNull(EmulatorBackend.readFields("users", uid.value))
        val profile = requireNotNull(EmulatorBackend.readFields("publicProfiles", uid.value))
        assertEquals("全投稿数（非公開・フォロワー限定を含む）", "4", user.int("postsCount"))
        assertEquals("公開投稿数だけ", "2", profile.int("postsCount"))
        assertEquals("users は postsCount 以外変わらない（updatedAt も書かない）", without(userBefore), without(user))
        assertEquals("publicProfiles は postsCount 以外変わらない", without(profileBefore), without(profile))
    }

    @Test
    fun publicProfilesが無いユーザーでも_usersに全投稿数を書いて成功を返す() = runBlocking {
        // iOS の移行前のユーザー：publicProfiles の更新は不在で失敗し、記録して続行する（iOS の recountPostsCount と同じ）
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("users", uid.value, """"id":{"stringValue":"${uid.value}"},"createdAt":{"timestampValue":"2026-10-10T00:00:00Z"}""")
        seedPost("P1", uid.value, "public")
        seedPost("P2", uid.value, "private")

        assertEquals(AppResult.Ok(2L), container.postsCountSynchronizer.recount(uid))

        assertEquals("2", EmulatorBackend.readFields("users", uid.value)?.int("postsCount"))
        assertNull("publicProfiles は作らない", EmulatorBackend.readFields("publicProfiles", uid.value))
    }

    // ── 下ごしらえ ──

    /** 認証のアカウントだけを作る（作成で SDK はそのままログイン状態になる）。 */
    private suspend fun createAccount(email: String): Uid {
        val result = container.authRepository.createEmailAccount(email, PASSWORD)
        return (result as? AppResult.Ok)?.value ?: error("アカウントを作れない: $result")
    }

    /** 投稿 [id] を、投稿者 [owner]・公開範囲 [visibility] で、rules を通さずに用意する。 */
    private fun seedPost(id: String, owner: String, visibility: String) {
        EmulatorBackend.seed(
            "posts", id,
            """"userId":{"stringValue":"$owner"},"visibility":{"stringValue":"$visibility"},""" +
                """"createdAt":{"timestampValue":"2026-10-10T00:00:00Z"}""",
        )
    }

    private fun without(fields: JSONObject): String = JSONObject(fields.toString()).apply { remove("postsCount") }.let(::canonical)

    /** キーの並びを揃えた文字列。書き換えた文書は、中身が同じでもエミュレータが返すキーの順が変わる（LikeEmulatorTest と同じ）。 */
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { "\"$it\":${canonical(value.get(it))}" }
        is org.json.JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
        // wrap は包めない値で null を返す（SDK の注釈で Any?）。null は "null" と書く（素の toString() は null の受け手でコンパイラが警告する）
        else -> JSONObject.wrap(value).let { if (it is String) JSONObject.quote(it) else it?.toString() ?: "null" }
    }

    /** REST では整数は文字列で届く（例: `{"integerValue":"0"}`）。整数でなければ null。 */
    private fun JSONObject.int(key: String): String? = optJSONObject(key)?.takeIf { it.has("integerValue") }?.getString("integerValue")

    private companion object {
        const val EMAIL = "sora@example.com"
        const val PASSWORD = "pass1234"
        const val OTHER = "u-other"
    }
}
