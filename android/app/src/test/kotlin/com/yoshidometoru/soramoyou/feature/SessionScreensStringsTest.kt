// ⭐️ ログイン画面・新規登録の画面・設定画面・フィード・プロフィール・投稿の作成の文言を iOS 版と 1 文字も違えないことの単体テスト（タスク 8.3・14.4・15.2・16.3・21.2・23.5・要件 16.1）
package com.yoshidometoru.soramoyou.feature

import com.yoshidometoru.soramoyou.ui.UiTextSources
import kotlin.test.Test
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * iOS 版に同じ場面がある文言は、iOS のソースの書き方（`Text("…")` など）の中にその文言がそのまま現れることを確かめる。
 * 期待値はテストに直書きせず strings.xml から取り、iOS のソースを毎回読む（UiStringsTest と同じ考え方）。
 * switch の分岐の `case .x: return "…"` と、return を省いた `case .x: "…"` は同じに読む（書き方と iOS のソースの両方を
 * [UiTextSources.withoutCaseReturns] に通してから比べる。下の書き方は return のある形のままでよい）。
 */
class SessionScreensStringsTest {

    private val strings = UiTextSources.readStrings()

    /** リソース名 → （iOS のファイル, 文言を %s に置いた書き方）。 */
    private val expectations = listOf(
        Triple("login_title", "Views/LoginView.swift", """Text("%s")"""),
        Triple("login_email_placeholder", "Views/LoginView.swift", """placeholder: "%s","""),
        Triple("login_password_placeholder", "Views/LoginView.swift", """placeholder: "%s","""),
        Triple("action_sign_in", "Views/LoginView.swift", """Text("%s")"""),
        Triple("settings_title", "Views/SettingsView.swift", """.navigationTitle("%s")"""),
        Triple("action_sign_out", "Views/SettingsView.swift", """Button("%s", role: .destructive)"""),
        Triple("sign_out_confirm_title", "Views/SettingsView.swift", """.alert("%s", isPresented: ${'$'}showingLogoutConfirmation)"""),
        Triple("sign_out_confirm_message", "Views/SettingsView.swift", """Text("%s")"""),
        Triple("action_cancel", "Views/SettingsView.swift", """Button("%s", role: .cancel)"""),
        Triple("feed_title", "Views/MainTabView.swift", """case .home: return "%s""""),
        // フィード（タスク 9.4）
        Triple("feed_empty_title", "Views/Components/EmptyStateView.swift", """case .posts: return "%s""""),
        Triple("state_error_permission", "Views/Components/ErrorStateView.swift", """case .permission: return "%s""""),
        Triple("feed_reached_end", "Views/HomeView.swift", """Text("%s")"""),
        // 新規登録（タスク 14.4）
        Triple("action_sign_up", "Views/WelcomeView.swift", """Text("%s")"""),
        Triple("signup_title", "Views/SignUpView.swift", """Text("%s")"""),
        Triple("signup_subtitle", "Views/SignUpView.swift", """Text("%s")"""),
        Triple("login_email_placeholder", "Views/SignUpView.swift", """placeholder: "%s","""),
        Triple("signup_password_placeholder", "Views/SignUpView.swift", """placeholder: "%s","""),
        Triple("signup_confirm_password_placeholder", "Views/SignUpView.swift", """placeholder: "%s","""),
        Triple("signup_passwords_match", "Views/SignUpView.swift", """Text(passwordsMatch ? "%s" :"""),
        Triple("signup_passwords_mismatch", "Views/SignUpView.swift", """ : "%s")"""),
        Triple("action_create_account", "Views/SignUpView.swift", """Text("%s")"""),
        Triple("signup_terms_notice", "Views/SignUpView.swift", """Text("%s")"""),
        // プロフィール（タスク 15.2）
        Triple("profile_title", "Views/MainTabView.swift", """case .profile: return "%s""""),
        Triple("profile_posts_label", "Views/UserProfileView.swift", """label: "%s")"""),
        // プロフィール編集（タスク 16.3）
        Triple("action_edit_profile", "Views/ProfileView.swift", """Label("%s", systemImage: "pencil")"""),
        Triple("profile_edit_title", "Views/ProfileEditView.swift", """.navigationTitle("%s")"""),
        Triple("profile_edit_display_name", "Views/ProfileEditView.swift", """TextField("%s", text: ${'$'}viewModel.editingDisplayName)"""),
        Triple("profile_edit_display_name", "Views/ProfileEditView.swift", """Text("%s")"""),
        Triple("profile_edit_bio", "Views/ProfileEditView.swift", """Text("%s")"""),
        Triple("action_change_image", "Views/ProfileEditView.swift", """Text("%s")"""),
        Triple("action_save", "Views/ProfileEditView.swift", """Button("%s") {"""),
        Triple("action_cancel", "Views/ProfileEditView.swift", """Button("%s") {"""),
        Triple("profile_edit_too_long", "Views/ProfileEditView.swift", """Text("%s")"""),
        Triple("profile_edit_image_too_large", "Services/StorageService.swift", """case .imageTooLarge:
            return "%s""""),
        // 投稿の作成（タスク 21.1・21.2）
        Triple("compose_title", "Views/MainTabView.swift", """case .post: return "%s""""),
        Triple("compose_pick_photos", "Views/PostView.swift", """Text("%s")"""),
        Triple("compose_edit_title", "Views/EditView.swift", """.navigationTitle("%s")"""),
        Triple("compose_filter_label", "Models/EditTab.swift", """case filter = "%s""""),
        Triple("compose_filter_none", "Views/EditView.swift", """displayName: "%s","""),
        // 投稿情報の段と送信（タスク 23.5）
        Triple("action_next", "Views/EditView.swift", """Text("%s")"""),
        Triple("compose_info_title", "Views/PostInfoView.swift", """.navigationTitle("%s")"""),
        Triple("compose_caption_label", "Views/PostInfoView.swift", """Text("%s")"""),
        Triple("compose_hashtag_hint", "Views/PostInfoView.swift", """Text("%s")"""),
        Triple("compose_hashtags_label", "Views/PostInfoView.swift", """Text("%s")"""),
        Triple("compose_hashtags_none", "Views/PostInfoView.swift", """Text("%s")"""),
        Triple("compose_visibility_label", "Views/PostInfoView.swift", """Text("%s")"""),
        Triple("compose_publish", "Views/PostInfoView.swift", """return editing ? "更新する" : "%s""""),
        Triple("compose_publishing", "Views/PostInfoView.swift", """return editing ? "更新中..." : "%s" }"""),
        // 投稿完了：iOS は見出し付きの alert をやめ、見出しの無い重ね表示（PostCompletionOverlay(message: …)）に替えた。
        // Android も見出しを外した（2026-11-06 の利用者の決定。見出しが無いことは PostPublishedDialogSourceTest が見る）。
        // 文言は前の alert の message と同じで、後ろの文字だけが `)` から `,` に変わったので、閉じの `"` までを見る
        Triple("compose_published_message", "Views/PostInfoView.swift", """ ? "投稿を更新しました" : "%s""""),
        Triple("action_ok", "Views/PostInfoView.swift", """Button("%s") {"""),
        // 投稿の失敗のダイアログ（全体レビュー 4 回目 Q07）
        Triple("compose_publish_failed_title", "Views/PostInfoView.swift", """.alert("%s", isPresented: Binding(errorMessage:"""),
        Triple("compose_error_no_images", "ViewModels/PostViewModel.swift", """case .noImages:
            "%s""""),
    )

    @Test
    fun `ログイン・新規登録・設定・フィードの文言はiOSの同じ場面の文言と一致する`() {
        expectations.forEach { (name, path, form) ->
            val value = assertNotNull(strings[name], "strings.xml に $name が無い")
            val expected = UiTextSources.withoutCaseReturns(form.format(value))
            val ios = UiTextSources.withoutCaseReturns(UiTextSources.iosSource(path))
            assertTrue(expected in ios, "iOS の $path に「$expected」が無い（$name の文言が iOS と違う）")
        }
    }
}
