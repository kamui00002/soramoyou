// ⭐️ 検証用ビルドから開発機の Firestore エミュレータを、リポジトリの rules のまま読む結合テスト（タスク 11.1・要件 1.3）
package com.yoshidometoru.soramoyou.integration

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.BuildConfig
import com.yoshidometoru.soramoyou.SoramoyouApplication
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.data.repository.PostLookup
import com.yoshidometoru.soramoyou.di.AppContainer
import com.yoshidometoru.soramoyou.di.FirebaseEmulator
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 実行の前に、開発機で `android/tools/start-firebase-emulators.sh` を起動しておく（rules はリポジトリのまま。Java が要る）。
 * 実行は `./gradlew :app:connectedEmulatorDebugAndroidTest`（仮想端末が要る）。
 *
 * 2026-10-08 に仮想端末（soramoyou_api36・Android 16）で初めて流し、このクラスの 4 本は緑だった（タスク 17.1）。
 */
@RunWith(AndroidJUnit4::class)
class FirestoreEmulatorReadTest {

    private val container: AppContainer =
        ApplicationProvider.getApplicationContext<SoramoyouApplication>().container

    @Before
    fun resetEmulator() {
        // 前のテストのデータを残さない
        EmulatorBackend.reset()
    }

    @Test
    fun 検証用ビルドはdemoのプロジェクトのエミュレータに繋がっている() {
        assertTrue(BuildConfig.USE_FIREBASE_EMULATOR)
        assertEquals(FirebaseEmulator.PROJECT_ID, container.firebaseProjectId)
    }

    @Test
    fun 公開の投稿はフィードで読めて初期化の後は0件になる() = runBlocking {
        EmulatorBackend.seed("posts", "PUB", PUBLIC_POST)

        val page = (container.feedRepository.loadPage(null) as AppResult.Ok).value
        assertEquals(listOf("PUB"), page.posts.map { it.postId.value })

        EmulatorBackend.reset()
        val empty = (container.feedRepository.loadPage(null) as AppResult.Ok).value
        assertEquals(0, empty.posts.size)
        assertTrue(empty.reachedEnd)
    }

    @Test
    fun 非公開の投稿はリポジトリのrulesにより権限なしになる() = runBlocking {
        EmulatorBackend.seed("posts", "PRIV", PRIVATE_POST)

        assertEquals(AppResult.Ok(PostLookup.NoPermission), container.postReadRepository.fetch(PostId("PRIV")))
    }

    @Test
    fun 無い投稿は削除済みでなく権限なしとして届く() = runBlocking {
        // 投稿の読み取りのルールが resource.data を見るため（PostLookup.Deleted の注記の確かめ）。
        // エミュレータの REST では 2026-10-05 に確かめ済み（認証なしで 403・管理者で 404）。ここではアプリの経路で確かめる
        assertEquals(AppResult.Ok(PostLookup.NoPermission), container.postReadRepository.fetch(PostId("NOPE")))
    }

    private companion object {
        const val PUBLIC_POST =
            """"userId":{"stringValue":"u1"},"visibility":{"stringValue":"public"},""" +
                """"createdAt":{"timestampValue":"2026-10-05T00:00:00Z"},""" +
                """"images":{"arrayValue":{"values":[{"mapValue":{"fields":{"url":{"stringValue":"http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/a.jpg"},"order":{"integerValue":"0"}}}}]}}"""
        const val PRIVATE_POST =
            """"userId":{"stringValue":"u1"},"visibility":{"stringValue":"private"},""" +
                """"createdAt":{"timestampValue":"2026-10-05T00:00:00Z"},""" +
                """"images":{"arrayValue":{"values":[{"mapValue":{"fields":{"url":{"stringValue":"http://10.0.2.2:9199/v0/b/demo-soramoyou.appspot.com/o/b.jpg"},"order":{"integerValue":"0"}}}}]}}"""
    }
}
