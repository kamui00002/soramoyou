// ⭐️ 本番の Firebase プロジェクトに繋がっているかの判定の単体テスト（タスク 5.1・要件 1.2）
package com.yoshidometoru.soramoyou.di

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 起動時に、接続先のプロジェクト ID（google-services.json から作られる FirebaseOptions.projectId）が
 * 本番（iOS 版と同じ `soramoyou-ios`）かどうかを判定する。判定の結果は起動時に Logcat へ出す（SoramoyouApplication）。
 */
class FirebaseProjectCheckTest {

    @Test
    fun `本番のプロジェクトIDはsoramoyou-ios`() {
        // iOS 版と同じバックエンド（要件 1.2）。.firebaserc が空なので、docs/pre-release-checklist.md の deploy も --project soramoyou-ios を明示している
        assertEquals("soramoyou-ios", FirebaseProjectCheck.PRODUCTION_PROJECT_ID)
    }

    @Test
    fun `本番のプロジェクトIDなら本番と判定する`() {
        assertTrue(FirebaseProjectCheck.isProduction("soramoyou-ios"))
    }

    @Test
    fun `別のプロジェクトIDなら本番ではない`() {
        assertFalse(FirebaseProjectCheck.isProduction("soramoyou-ios-dev"))
    }

    @Test
    fun `大文字と小文字が違えば別のプロジェクトとして扱う`() {
        // Firebase のプロジェクト ID は小文字だけで作られる。違う表記は別物（設定の取り違え）として扱う
        assertFalse(FirebaseProjectCheck.isProduction("Soramoyou-ios"))
    }

    @Test
    fun `プロジェクトIDが無いか空なら本番ではない`() {
        assertFalse(FirebaseProjectCheck.isProduction(null))
        assertFalse(FirebaseProjectCheck.isProduction(""))
    }
}
