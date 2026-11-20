// ⭐️ アカウントの削除の文言を iOS 版と突き合わせ、消えるもの・残るもの・取り消せないことを言っていることの単体テスト（タスク 31.5・要件 12.1・12.2・12.5・16.1）
package com.yoshidometoru.soramoyou.feature.settings

import com.yoshidometoru.soramoyou.ui.UiTextSources
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * iOS 版に同じ場面がある短い文言は、iOS の SettingsView の書き方の中にそのまま現れることを確かめる
 * （FeedbackStringsTest と同じ考え方。期待値は strings.xml から取る）。
 * iOS の確認文（「すべての投稿・下書き・プロフィール情報が完全に削除されます」）は、iOS の実態とも Android の範囲とも合わないので
 * 写していない（strings.xml の注記）。代わりに Android の説明が、消えるもの・残るもの・取り消せないことを言っていることを確かめる。
 */
class AccountDeletionStringsTest {

    private val strings = UiTextSources.readStrings()

    private fun string(name: String): String = assertNotNull(strings[name], "strings.xml に $name が無い")

    /** リソース名 → 文言を %s に置いた iOS の書き方（Views/SettingsView.swift）。 */
    private val iosExpectations = listOf(
        // 設定の項目
        "account_delete_title" to "title: \"%s\",",
        // 確認のアラート
        "account_delete_title" to ".alert(\"%s\", isPresented: \$showingDeleteAccountConfirmation)",
        "action_delete_account" to "Button(\"%s\", role: .destructive)",
        // パスワードのアラート
        "account_delete_password_title" to ".alert(\"%s\", isPresented: \$viewModel.showingReauthentication)",
        "login_password_placeholder" to "SecureField(\"%s\", text: \$reauthPassword)",
        "action_confirm_delete_account" to "Button(\"%s\") {",
        "account_delete_password_message" to "Text(\"%s\")",
        // 削除中の覆い
        "account_deleting" to "Text(\"%s\")",
    )

    @Test
    fun `iOSに同じ場面がある文言は、iOSのSettingsViewと同じ`() {
        UiTextSources.assertIosHasStrings(iosExpectations, "Views/SettingsView.swift")
    }

    @Test
    fun `消えるデータに、投稿の写真とアイコン画像を含めて全て挙げる`() {
        val removed = string("account_delete_removed_items")
        // Android の退会は投稿の写真とアイコン画像も消す（タスク 26 の判断②）。そらとも（iOS 版の機能）のデータは
        // AccountDeletionService の段階には無いが、Auth のアカウントが消えた人の分をサーバーの定期の後始末が消すので挙げる
        // （削除の受付ページの 3. と同じ。strings.xml の注記）。それ以外は AccountDeletionService の段階と同じ範囲
        listOf(
            "投稿", "写真", "アイコン画像", "プロフィール", "いいね", "コメント", "フォロー", "フォロワー", "下書き", "お気に入り", "アカウント",
            "そらとも", "グループへの参加",
        )
            .forEach { word -> assertTrue(word in removed, "消えるデータに「$word」が無い: $removed") }
    }

    @Test
    fun `残るデータに、通報の記録とご意見・ご要望を挙げる`() {
        val kept = string("account_delete_kept_items")
        // rules でアプリから消せない（firestore.rules の reports と feedback）。削除の受付ページの 4・5 と同じ
        listOf("通報", "ご意見・ご要望").forEach { word -> assertTrue(word in kept, "残るデータに「$word」が無い: $kept") }
        assertTrue("削除しても残る" in string("account_delete_kept_title"))
    }

    @Test
    fun `取り消せないことを、説明と確認の両方で言う`() {
        assertTrue("取り消せません" in string("account_delete_irreversible"))
        assertTrue("取り消せません" in string("account_delete_confirm_message"))
    }

    @Test
    fun `段階の名前を入れる文言は、名前の差し込み口を持つ`() {
        listOf("account_delete_progress", "account_delete_failed_stage_title").forEach { name ->
            assertTrue("%1\$s" in string(name), "$name に %1\$s が無い")
        }
        assertTrue("%1\$s" in string("account_delete_request_page_open_failed"), "開けなかったときの文言にアドレスの差し込み口が無い")
    }

    @Test
    fun `最近のログインが必要のときは、パスワードを入れ直すと完了すると言う`() {
        val text = string("account_delete_requires_recent_login")
        assertTrue("パスワード" in text && "完了" in text, text)
    }

    @Test
    fun `削除中のオフラインの案内は、接続が戻ると削除を続けると言う`() {
        // フィードバックの送信中のオフライン（feedback_sending_offline「接続が戻ると送信します」）と同じ言い方。iOS に同じ場面は無い（レビュー F19）
        val text = string("account_delete_deleting_offline")
        assertTrue("接続が戻ると" in text && "削除を続け" in text, text)
    }
}
