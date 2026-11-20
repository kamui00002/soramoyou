// ⭐️ M2 の書き込み（アカウント文書の作成・補完・プロフィールの更新）が、リポジトリの rules をそのまま通ることを確かめる結合テスト（タスク 17.1・要件 3.1〜3.4・3.7・10.6・10.9）
package com.yoshidometoru.soramoyou.integration

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.SoramoyouApplication
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.remote.write.BuildConfigWriteGate
import com.yoshidometoru.soramoyou.data.repository.ProfileEdit
import com.yoshidometoru.soramoyou.data.repository.RepairOutcome
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.di.AppContainer
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
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
 * 実行の前に、開発機で `android/tools/start-firebase-emulators.sh` を起動しておく（Auth・Firestore・Storage。rules はリポジトリのまま）。
 * 実行は `./gradlew :app:connectedEmulatorDebugAndroidTest`（仮想端末が要る）。
 *
 * 書き込みはアプリの部品（AppContainer の入口）で行い、結果はアプリの読み取りでなく、エミュレータの管理者の口
 * （[EmulatorBackend.readFields]）で確かめる。rules に断られた書き込みは `AppError.PermissionDenied` で返る。
 */
@RunWith(AndroidJUnit4::class)
class AccountProfileEmulatorTest {

    private val container: AppContainer =
        ApplicationProvider.getApplicationContext<SoramoyouApplication>().container

    @Before
    fun resetEmulator() = runBlocking {
        // 前のテストのログインとデータを残さない（ログアウトは、ログインしていなくても失敗しない前提で結果を見ない）
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
    fun 検証用ビルドはM2以上で_M2の書き込みが有効() {
        // タスク 18.2 で検証用も M3 に、タスク 21.1 で M4 に上げたので、ここでは M2 の書き込みを含むことだけを見る
        // （M3 の導線の確認はタスク 19.1、M4 の導線の確認はタスク 25.1）
        val m2 = setOf(WriteCapability.ACCOUNT_CREATE, WriteCapability.ACCOUNT_REPAIR, WriteCapability.PROFILE_EDIT)
        assertTrue(BuildConfigWriteGate.enabled.containsAll(m2))
        // 画面の導線（新規登録・プロフィール編集・いいね・投稿）は、この writeGate の isEnabled で出し分ける
        assertEquals(BuildConfigWriteGate.enabled, container.writeGate.enabled)
    }

    // ── 新規登録 ──

    @Test
    fun 新規登録で作ったユーザー文書と公開プロフィールがrulesを通る() = runBlocking {
        val uid = createAccount(EMAIL)

        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(uid, EMAIL))

        val user = requireNotNull(EmulatorBackend.readFields("users", uid.value)) { "users が作られていない" }
        assertEquals(uid.value, user.str("id"))
        assertEquals(EMAIL, user.str("email"))
        for (key in COUNTERS) assertEquals("$key は整数の 0", "0", user.int(key))
        assertTrue(user.has("createdAt") && user.has("updatedAt"))
        // 要件 2.10：通知のトークンは Android が書かない
        assertFalse(user.has("fcmToken"))
        assertFalse(user.has("fcmTokenUpdatedAt"))

        val profile = requireNotNull(EmulatorBackend.readFields("publicProfiles", uid.value)) { "publicProfiles が作られていない" }
        assertEquals(uid.value, profile.str("id"))
        for (key in COUNTERS) assertEquals("$key は整数の 0", "0", profile.int(key))
        // 公開プロフィールは誰でも読めるので、メールアドレスを入れない
        assertFalse(profile.has("email"))
    }

    @Test
    fun 他人のuidの文書はrulesに断られる() = runBlocking {
        // この結合テストが rules の拒否を見分けられることの確かめ（陽性対照）。ログイン中の本人と違う uid で作る
        createAccount(EMAIL)

        assertEquals(AppResult.Err(AppError.PermissionDenied), container.accountBootstrapper.bootstrap(Uid("someone-else"), EMAIL))
        assertNull(EmulatorBackend.readFields("users", "someone-else"))
    }

    // ── 補完（要件 3.7） ──

    @Test
    fun 公開プロフィールだけが欠けていれば_それだけを作りusersは書き換えない() = runBlocking {
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("users", uid.value, existingUser(uid))
        val before = requireNotNull(EmulatorBackend.readFields("users", uid.value))
        awaitSignedIn(uid)

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_PUBLIC_PROFILE), container.accountDocumentRepairer.ensureAccountDocuments())

        assertEquals("users は 1 文字も変わらない", before.toString(), EmulatorBackend.readFields("users", uid.value).toString())
        val profile = requireNotNull(EmulatorBackend.readFields("publicProfiles", uid.value))
        // users の値を写す
        assertEquals("空太", profile.str("displayName"))
        assertEquals("3", profile.int("postsCount"))
        assertEquals("5", profile.int("followersCount"))
        // 機密は写さない
        assertFalse(profile.has("fcmToken"))
        assertFalse(profile.has("email"))
    }

    @Test
    fun 両方あれば何も書かない() = runBlocking {
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("users", uid.value, existingUser(uid))
        EmulatorBackend.seed("publicProfiles", uid.value, existingPublicProfile(uid))
        val users = EmulatorBackend.readFields("users", uid.value).toString()
        val profiles = EmulatorBackend.readFields("publicProfiles", uid.value).toString()
        awaitSignedIn(uid)

        assertEquals(AppResult.Ok(RepairOutcome.ALREADY_PRESENT), container.accountDocumentRepairer.ensureAccountDocuments())

        assertEquals(users, EmulatorBackend.readFields("users", uid.value).toString())
        assertEquals(profiles, EmulatorBackend.readFields("publicProfiles", uid.value).toString())
    }

    @Test
    fun 両方欠けていれば両方作る() = runBlocking {
        val uid = createAccount(EMAIL)
        awaitSignedIn(uid)

        assertEquals(AppResult.Ok(RepairOutcome.CREATED_BOTH), container.accountDocumentRepairer.ensureAccountDocuments())

        assertEquals(EMAIL, EmulatorBackend.readFields("users", uid.value)?.str("email"))
        assertNotNull(EmulatorBackend.readFields("publicProfiles", uid.value))
    }

    @Test
    fun 両方欠けていても_認証のアカウントがサーバーで消されていれば_どちらも作らない() = runBlocking {
        // 端末はログインしたまま、Auth のエミュレータからアカウントだけを消す（レビュー R10・全体レビュー 4 回目 Q14）
        val uid = createAccount(EMAIL)
        awaitSignedIn(uid)
        assertTrue("消す前はサーバーにアカウントがある", EmulatorBackend.authAccountExists(uid.value))
        EmulatorBackend.resetAuth()
        assertFalse("サーバーからアカウントが消えている", EmulatorBackend.authAccountExists(uid.value))

        assertEquals(AppResult.Err(AppError.PermissionDenied), container.accountDocumentRepairer.ensureAccountDocuments())

        assertNull("users を作り直していない", EmulatorBackend.readFields("users", uid.value))
        assertNull("publicProfiles を作り直していない", EmulatorBackend.readFields("publicProfiles", uid.value))
    }

    // ── プロフィールの更新（要件 10.6・10.9） ──

    @Test
    fun プロフィールの部分更新とキーの削除がrulesを通る() = runBlocking {
        val uid = createAccount(EMAIL)
        assertEquals(AppResult.Ok(Unit), container.accountBootstrapper.bootstrap(uid, EMAIL))
        val createdAt = EmulatorBackend.readFields("users", uid.value)?.optJSONObject("createdAt").toString()

        // 1 回目：表示名と自己紹介を足す
        val blank = OwnProfile(uid, displayName = null, photoUrl = null, bio = null, postsCount = 0)
        assertEquals(AppResult.Ok(Unit), container.profileEditor.save(ProfileEdit("空太", "よろしく", null), blank))
        for (collection in PROFILE_COLLECTIONS) {
            val doc = requireNotNull(EmulatorBackend.readFields(collection, uid.value))
            assertEquals(collection, "空太", doc.str("displayName"))
            assertEquals(collection, "よろしく", doc.str("bio"))
        }

        // 2 回目：表示名を空にする → キーを消す。自己紹介は変えていないので残る
        val named = OwnProfile(uid, displayName = "空太", photoUrl = null, bio = "よろしく", postsCount = 0)
        assertEquals(AppResult.Ok(Unit), container.profileEditor.save(ProfileEdit("", "よろしく", null), named))
        for (collection in PROFILE_COLLECTIONS) {
            val doc = requireNotNull(EmulatorBackend.readFields(collection, uid.value))
            assertFalse("$collection の displayName が消えていない", doc.has("displayName"))
            assertEquals(collection, "よろしく", doc.str("bio"))
        }

        // 部分更新なので、触っていない項目は変わらない
        val user = requireNotNull(EmulatorBackend.readFields("users", uid.value))
        assertEquals(createdAt, user.optJSONObject("createdAt").toString())
        assertEquals(EMAIL, user.str("email"))
        assertEquals("0", user.int("postsCount"))
    }

    @Test
    fun 公開プロフィールが無ければ補ってから更新する() = runBlocking {
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("users", uid.value, existingUser(uid))
        awaitSignedIn(uid)

        val current = OwnProfile(uid, displayName = "空太", photoUrl = null, bio = null, postsCount = 3)
        assertEquals(AppResult.Ok(Unit), container.profileEditor.save(ProfileEdit("空子", "", null), current))

        val profile = requireNotNull(EmulatorBackend.readFields("publicProfiles", uid.value)) { "補完されていない" }
        assertEquals("空子", profile.str("displayName"))
        assertEquals("3", profile.int("postsCount"))
        assertEquals("空子", EmulatorBackend.readFields("users", uid.value)?.str("displayName"))
    }

    // ── 画像の URL の形の配線（全体レビュー 4 回目 R11） ──

    @Test
    fun 検証用のビルドの投稿者の表示とプロフィールは_エミュレータのStorageの形のアイコンだけを使う() = runBlocking {
        // AppContainer が投稿者の表示（authorProfileCache）とプロフィール（profileRepository）に、検証用のビルドの形（エミュレータの Storage）を
        // 渡していることを、本物の部品で確かめる。エミュレータの形を使う（本番の形を渡していない）ことと、本番の形を使わない
        // （どちらの形も通す扱いにしていない）ことの両方を見る。形の判定そのものは単体テスト（RemoteImageUrlTest など）で確かめる
        val uid = createAccount(EMAIL)
        EmulatorBackend.seed("users", uid.value, existingUser(uid) + ""","photoURL":{"stringValue":"$EMULATOR_ICON"}""")
        EmulatorBackend.seed("publicProfiles", OTHER_EMULATOR_ICON, otherProfile(OTHER_EMULATOR_ICON, EMULATOR_ICON))
        EmulatorBackend.seed("publicProfiles", OTHER_PRODUCTION_ICON, otherProfile(OTHER_PRODUCTION_ICON, PRODUCTION_ICON))
        awaitSignedIn(uid)

        container.authorProfileCache.ensure(setOf(Uid(OTHER_EMULATOR_ICON), Uid(OTHER_PRODUCTION_ICON)))
        val authors = container.authorProfileCache.authors.value
        assertEquals(AuthorDisplay.Named("空子", EMULATOR_ICON), authors[Uid(OTHER_EMULATOR_ICON)])
        assertEquals("本番の形のアイコンは使わない", AuthorDisplay.Named("空子", null), authors[Uid(OTHER_PRODUCTION_ICON)])

        val other = container.profileRepository.fetchPublic(Uid(OTHER_EMULATOR_ICON))
        assertEquals(EMULATOR_ICON, (other as AppResult.Ok).value.author.photoUrl)
        val otherProduction = container.profileRepository.fetchPublic(Uid(OTHER_PRODUCTION_ICON))
        assertNull("本番の形のアイコンは使わない", (otherProduction as AppResult.Ok).value.author.photoUrl)
        // 自分の users は購読で届く（最初に届くのがキャッシュの「無い」でも、読めた 1 件を待つ）
        val own = withTimeout(10_000) { container.profileRepository.observeOwn().first { it is AppResult.Ok } }
        assertEquals(EMULATOR_ICON, (own as AppResult.Ok).value.photoUrl)
    }

    // ── 下ごしらえ ──

    /** 認証のアカウントだけを作る（文書は作らない）。作成で SDK はそのままログイン状態になる。 */
    private suspend fun createAccount(email: String): Uid {
        val result = container.authRepository.createEmailAccount(email, PASSWORD)
        return (result as? AppResult.Ok)?.value ?: error("アカウントを作れない: $result")
    }

    /** 補完は認証状態（session）から uid を得るので、通知が届いて SignedIn になるまで待つ。 */
    private suspend fun awaitSignedIn(uid: Uid) {
        withTimeout(10_000) {
            container.authRepository.session.first { it is SessionState.SignedIn && it.uid == uid }
        }
    }

    private fun JSONObject.str(key: String): String? = optJSONObject(key)?.optString("stringValue")

    /** REST では整数は文字列で届く（例: `{"integerValue":"0"}`）。整数でなければ null。 */
    private fun JSONObject.int(key: String): String? = optJSONObject(key)?.takeIf { it.has("integerValue") }?.getString("integerValue")

    private companion object {
        const val EMAIL = "sora@example.com"
        const val PASSWORD = "pass1234"
        val COUNTERS = listOf("followersCount", "followingCount", "postsCount")
        val PROFILE_COLLECTIONS = listOf("users", "publicProfiles")

        /** iOS で作られた既存のユーザー文書（表示名・カウンタ・通知のトークンあり）。 */
        fun existingUser(uid: Uid) =
            """"id":{"stringValue":"${uid.value}"},"email":{"stringValue":"$EMAIL"},""" +
                """"createdAt":{"timestampValue":"2026-01-01T00:00:00Z"},"updatedAt":{"timestampValue":"2026-01-01T00:00:00Z"},""" +
                """"displayName":{"stringValue":"空太"},"fcmToken":{"stringValue":"ios-token"},""" +
                """"followersCount":{"integerValue":"5"},"followingCount":{"integerValue":"2"},"postsCount":{"integerValue":"3"}"""

        /** 他人の公開プロフィールの文書 ID（アイコンの URL の形ごとに 1 人）。 */
        const val OTHER_EMULATOR_ICON = "other-emulator-icon"
        const val OTHER_PRODUCTION_ICON = "other-production-icon"

        /** エミュレータの Storage のダウンロード URL の形のアイコン（仮想端末から見た開発機・検証用のバケット）。 */
        const val EMULATOR_ICON = "http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/users%2Fother%2Fprofile%2Fprofile.jpg?alt=media&token=t"

        /** 本番の Storage のダウンロード URL の形のアイコン。検証用のビルドの読み取りは使わない。 */
        const val PRODUCTION_ICON =
            "https://firebasestorage.googleapis.com/v0/b/soramoyou-ios.firebasestorage.app/o/users%2Fother%2Fprofile%2Fprofile.jpg?alt=media&token=t"

        /** 表示名とアイコンだけを持つ他人の公開プロフィール。 */
        fun otherProfile(id: String, photoUrl: String) =
            """"id":{"stringValue":"$id"},"displayName":{"stringValue":"空子"},"photoURL":{"stringValue":"$photoUrl"}"""

        fun existingPublicProfile(uid: Uid) =
            """"id":{"stringValue":"${uid.value}"},""" +
                """"createdAt":{"timestampValue":"2026-01-01T00:00:00Z"},"updatedAt":{"timestampValue":"2026-01-01T00:00:00Z"},""" +
                """"displayName":{"stringValue":"空太"},""" +
                """"followersCount":{"integerValue":"5"},"followingCount":{"integerValue":"2"},"postsCount":{"integerValue":"3"}"""
    }
}
