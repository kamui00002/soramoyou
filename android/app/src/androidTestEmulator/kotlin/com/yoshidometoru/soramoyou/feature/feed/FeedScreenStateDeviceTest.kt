// ⭐️ フィード画面の状態ごとの表示を、端末で画面を組み立てて確かめる（タスク 9.5・受け入れ基準 4.12・4.13・16.2・16.3）
package com.yoshidometoru.soramoyou.feature.feed

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
// v2 を使う（v1 の createComposeRule は ui-test-junit4 1.12.1 で非推奨。v2 は StandardTestDispatcher で、
// 予約した処理を順番に流す。このテストは状態を変えた後に必ず assert か runOnIdle で画面と同期するので、違いは出ない）
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.feature.moderation.ModerationHandlers
import com.yoshidometoru.soramoyou.feature.moderation.ModerationUiState
import com.yoshidometoru.soramoyou.ui.theme.SoramoyouTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * [FeedScreen] に状態を直接渡して画面を組み立て、読み込み中・0 件・取得の失敗と再試行・オフラインの各状態で、所定の表示が出ることを確かめる。
 *
 * - どの表示を出すかの判定（[feedContentOf]）は JVM の単体テスト（FeedContentTest）が確かめる。ここで確かめるのは、その判定の結果として
 *   実際に画面に出る文言と、再試行のボタンが押せるか・押すと更新が呼ばれるか（判定と描画のつなぎ目）。
 * - 11.3 の端末確認では「0 件」と「オンラインのままの失敗」を本番のフィードで作れず、単体テストで確かめた扱いにしていた（2026-10-09 のユーザー判断）。
 *   この 2 つの描画は、ここで初めて自動で確かめる。
 * - 文言は strings.xml から読む（端末の言語の設定に左右されない）。文言の中身が正しいかは、ここでは確かめない（出る場所だけを確かめる）。
 * - FeedScreen は状態を受け取って描くだけなので、ViewModel・Firebase・分析の窓口を作らない。Firebase のエミュレータは使わない。
 *   検証用の変種（emulator）は、PostHog を初期化せず（AppContainer）、Firebase Analytics と Crashlytics の収集を切っている（src/emulator/AndroidManifest.xml）。
 *
 * 実行は
 * `./gradlew :app:connectedEmulatorDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yoshidometoru.soramoyou.feature.feed.FeedScreenStateDeviceTest`
 * （仮想端末が要る。終わると検証用のアプリ〔.emulator〕は端末から消える。本番用のアプリには触れない）。
 */
@RunWith(AndroidJUnit4::class)
class FeedScreenStateDeviceTest {

    @get:Rule
    val rule = createComposeRule()

    private val context = InstrumentationRegistry.getInstrumentation().targetContext

    /** 画面に出る文言（strings.xml の値）。 */
    private fun text(id: Int): String = context.getString(id)

    /** 画面に渡す接続の有無。テストの途中で変えると、画面が描き直される（Compose の状態）。 */
    private var online by mutableStateOf(true)

    /** 再試行・引っ張って更新で呼ばれた回数（画面の onRefresh）。 */
    private var refreshCount = 0

    /** 通報・ブロックの操作は、このテストでは使わない（どれも何もしない）。 */
    private val noModeration = ModerationHandlers(
        onRequestReport = {},
        onRequestBlock = {},
        onSubmitReport = {},
        onCancelReport = {},
        onConfirmBlock = {},
        onCancelBlock = {},
        onDismissReported = {},
        onDismissFailure = {},
    )

    /** 本番と同じテーマで、[state] を渡したフィード画面を出す。投稿は 0 件なので、投稿者・いいね・通報の中身は空でよい。 */
    private fun showFeed(state: FeedUiState) {
        rule.setContent {
            SoramoyouTheme {
                FeedScreen(
                    state = state,
                    authors = emptyMap(),
                    isOnline = online,
                    likes = LikeDisplay(liked = emptySet(), countOverrides = emptyMap(), canLike = false),
                    onRefresh = { refreshCount++ },
                    onLoadMore = {},
                    onToggleLike = {},
                    onOpenProfile = {},
                    onOpenSettings = {},
                    onOpenPost = {},
                    moderation = ModerationUiState(),
                    moderationActionsFor = { emptySet() },
                    moderationHandlers = noModeration,
                )
            }
        }
    }

    @Test
    fun 読み込み中は読み込み中の文言を出し_再試行は出さない() {
        showFeed(FeedUiState(isRefreshing = true))

        rule.onNodeWithText(text(R.string.state_loading)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.action_retry)).assertDoesNotExist()
        rule.onNodeWithText(text(R.string.feed_empty_title)).assertDoesNotExist()
    }

    @Test
    fun 続きが無い0件は投稿がありませんを出し_再試行は出さない() {
        showFeed(FeedUiState(reachedEnd = true))

        rule.onNodeWithText(text(R.string.feed_empty_title)).assertIsDisplayed()
        // 0 件の表示には再試行のボタンが無い（引っ張って更新で読み直す：タスク 11.4）
        rule.onNodeWithText(text(R.string.action_retry)).assertDoesNotExist()
        rule.onNodeWithText(text(R.string.state_loading)).assertDoesNotExist()
    }

    @Test
    fun オンラインのままの失敗は失敗の文言と押せる再試行を出し_押すと更新を1回呼ぶ() {
        // 権限の拒否は、フィードに固有の文言（「アクセス権限がありません」）を出す（FeedErrorMessages.kt）
        showFeed(FeedUiState(error = AppError.PermissionDenied, failedWhileOffline = false))

        rule.onNodeWithText(text(R.string.state_error_permission)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.action_retry)).assertIsDisplayed().assertIsEnabled().performClick()
        rule.runOnIdle { assertEquals("再試行を押して更新が呼ばれた回数", 1, refreshCount) }
    }

    @Test
    fun オフラインで失敗したら接続できない文言を出し_再試行は押せない() {
        online = false
        showFeed(FeedUiState(error = AppError.Network, failedWhileOffline = true))

        rule.onNodeWithText(text(R.string.offline_title)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.offline_message)).assertIsDisplayed()
        // 押せない再試行は、押しても更新を呼ばない
        rule.onNodeWithText(text(R.string.action_retry)).assertIsDisplayed().assertIsNotEnabled().performClick()
        rule.runOnIdle { assertEquals("押せない再試行を押して更新が呼ばれた回数", 0, refreshCount) }
    }

    @Test
    fun オフラインの表示は接続が戻ると見出しが変わり再試行を押せるようになる() {
        online = false
        showFeed(FeedUiState(error = AppError.Network, failedWhileOffline = true))
        rule.onNodeWithText(text(R.string.action_retry)).assertIsNotEnabled()

        // 接続が戻る（画面は isOnline を受け取り直して描き直す。自動では再試行しない）
        online = true

        rule.onNodeWithText(text(R.string.reconnected_title)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.offline_title)).assertDoesNotExist()
        rule.runOnIdle { assertEquals("接続が戻っただけで更新が呼ばれた回数", 0, refreshCount) }
        rule.onNodeWithText(text(R.string.action_retry)).assertIsEnabled().performClick()
        rule.runOnIdle { assertEquals("接続が戻った後に再試行を押して更新が呼ばれた回数", 1, refreshCount) }
    }
}
