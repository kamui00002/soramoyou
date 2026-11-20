// ⭐️ 分析のイベント名・画面名を iOS 版の文字列に固定する単体テスト（タスク 4.1・要件 15.2・15.4）
package com.yoshidometoru.soramoyou.platform

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * イベント名と画面名は、PostHog・Firebase Analytics 上で iOS 版と同じ行に並ぶ文字列である。
 * 1 文字でも違うと両 OS を同じ物差しで比べられなくなる。また、iOS 版に無いイベントを新設しない（タスク 4.1）ため、
 * 名前の集合は閉じている（コンストラクタが private で、ここに挙げた定数しか作れない）。
 *
 * 根拠（読んだ現物）:
 * - `post_completed`：Soramoyou/Soramoyou/ViewModels/PostViewModel.swift:653
 * - `error_occurred`：Soramoyou/Soramoyou/Services/LoggingService.swift:149
 * - `retry_operation`：Soramoyou/Soramoyou/Services/LoggingService.swift:166
 * - `post_decode_failed`：origin/main の Soramoyou/Soramoyou/Services/PostDocumentDecoder.swift:83（iOS PR #150）
 * - 「ホーム」「投稿」「プロフィール」：Soramoyou/Soramoyou/Views/MainTabView.swift:29, 30, 33（Tab.title）
 * - 「編集」：Soramoyou/Soramoyou/Views/EditView.swift:347
 */
class AnalyticsNamesTest {

    @Test
    fun `イベント名はiOS版の4つの文字列と一致する`() {
        assertEquals("post_completed", EventName.POST_COMPLETED.value)
        assertEquals("error_occurred", EventName.ERROR_OCCURRED.value)
        assertEquals("retry_operation", EventName.RETRY_OPERATION.value)
        assertEquals("post_decode_failed", EventName.POST_DECODE_FAILED.value)
    }

    @Test
    fun `イベント名は4つだけで重複しない`() {
        // 増やすときは、iOS 版と同時に名前を決める（設計書の分析イベント一覧の注記）。増減したらここで気づく
        assertEquals(
            setOf("post_completed", "error_occurred", "retry_operation", "post_decode_failed"),
            EventName.entries.map { it.value }.toSet(),
        )
        assertEquals(4, EventName.entries.size)
    }

    @Test
    fun `画面名はiOS版の4つの文字列と一致する`() {
        assertEquals("ホーム", ScreenName.HOME.value)
        assertEquals("投稿", ScreenName.POST.value)
        assertEquals("編集", ScreenName.EDIT.value)
        assertEquals("プロフィール", ScreenName.PROFILE.value)
    }

    @Test
    fun `画面名は4つだけで重複しない`() {
        assertEquals(setOf("ホーム", "投稿", "編集", "プロフィール"), ScreenName.entries.map { it.value }.toSet())
        assertEquals(4, ScreenName.entries.size)
    }
}
