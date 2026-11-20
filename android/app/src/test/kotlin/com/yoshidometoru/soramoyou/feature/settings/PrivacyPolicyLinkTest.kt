// ⭐️ プライバシーポリシーへの導線（設定の項目・新規登録のリンク）の URL・文言・開き方の検査（レビュー R01）（全体レビュー 4 回目 Q18）
package com.yoshidometoru.soramoyou.feature.settings

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 画面の描画と、押したときにブラウザが開くことは JVM の単体テストでは確かめられない（Robolectric も Compose の UI テストも無い。
 * 端末での目視は設定→ポリシー→ブラウザ、登録画面→リンクの 2 本）。そこで、定数の値と、画面のソースの書き方を固定する
 * （AccountDeletionScreenLayoutTest と同じ考え方）。:app の単体テストの作業ディレクトリは android/app なので、`src/main` を直接読む。
 *
 * 画面のソースはコメントを除いて読み、文言と開く URL は項目（リンク）の呼び出し 1 つの中で結んで見る（LegalLinkSources。
 * 別々に見ると、2 つの項目の URL を取り違えても通る：全体レビュー 4 回目 Q18）。開くのは守り（openLegalPage）を通す（Q06）。
 */
class PrivacyPolicyLinkTest {

    private val stringsSource = File("src/main/res/values/strings.xml").readText()

    @Test
    fun `プライバシーポリシーのURLはiOSと同じhostingのprivacyのページ`() {
        assertEquals("https://soramoyou-ios.web.app/privacy/", PRIVACY_POLICY_URL)
    }

    @Test
    fun `設定は、プライバシーポリシーの文言の項目を押すと、その定数のURLを守りを通して外で開く`() {
        assertTrue(LegalLinkSources.settings.contains("LocalUriHandler.current"), "設定が LocalUriHandler を使っていない")
        assertTrue(
            LegalLinkSources.hasSettingsItem(LegalLinkSources.settings, "privacy_policy_title", "PRIVACY_POLICY_URL"),
            "設定のプライバシーポリシーの文言の項目が、PRIVACY_POLICY_URL を守り（openLegalPage）を通して開いていない",
        )
    }

    @Test
    fun `新規登録の画面も、プライバシーポリシーの文言のリンクを押すと、その定数のURLを守りを通して外で開く`() {
        assertTrue(LegalLinkSources.signUp.contains("LocalUriHandler.current"), "登録画面が LocalUriHandler を使っていない")
        assertTrue(
            LegalLinkSources.hasSignUpLink(LegalLinkSources.signUp, "privacy_policy_title", "PRIVACY_POLICY_URL"),
            "登録画面のプライバシーポリシーの文言のリンクが、PRIVACY_POLICY_URL を守り（openLegalPage）を通して開いていない",
        )
    }

    @Test
    fun `文言とURLの結びの検査は、取り違えとコメントの中の呼び出しを通さず、折り返しは通す（固定の写し）`() {
        // 設定の項目：1 行の形・折り返して最後のカンマを付けた形は通る
        val settingsItem = "SettingsItem(stringResource(R.string.privacy_policy_title), onClick = { openLegalPage(PRIVACY_POLICY_URL) })"
        val settingsFolded = """
            SettingsItem(
                stringResource(R.string.privacy_policy_title),
                onClick = { openLegalPage(PRIVACY_POLICY_URL) },
            )
        """.trimIndent()
        assertTrue(hasPrivacySettingsItem(settingsItem), "1 行の正しい項目を通さない")
        assertTrue(hasPrivacySettingsItem(settingsFolded), "折り返して最後のカンマを付けた項目を通さない")
        // 文言と URL の取り違え・行コメントとブロックコメントの中の項目は通らない
        assertFalse(hasPrivacySettingsItem(settingsItem.replace("PRIVACY_POLICY_URL", "TERMS_OF_SERVICE_URL")), "取り違えた項目を通した")
        assertFalse(hasPrivacySettingsItem("// $settingsItem"), "行コメントの中の項目を通した")
        assertFalse(hasPrivacySettingsItem("/* $settingsItem */"), "ブロックコメントの中の項目を通した")

        // 新規登録のリンク：1 行の形・引数を折り返して最後のカンマを付けた形は通る
        val signUpLink = """
            TextButton(onClick = { openLegalPage(PRIVACY_POLICY_URL) }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.privacy_policy_title))
            }
        """.trimIndent()
        val signUpFolded = """
            TextButton(
                onClick = { openLegalPage(PRIVACY_POLICY_URL) },
                modifier = Modifier.heightIn(min = 48.dp),
            ) {
                Text(stringResource(R.string.privacy_policy_title))
            }
        """.trimIndent()
        assertTrue(hasPrivacySignUpLink(signUpLink), "正しいリンクを通さない")
        assertTrue(hasPrivacySignUpLink(signUpFolded), "引数を折り返して最後のカンマを付けたリンクを通さない")
        assertFalse(hasPrivacySignUpLink(signUpLink.replace("PRIVACY_POLICY_URL", "TERMS_OF_SERVICE_URL")), "取り違えたリンクを通した")
        assertFalse(hasPrivacySignUpLink(signUpLink.lines().joinToString("\n") { "// $it" }), "行コメントの中のリンクを通した")
        assertFalse(hasPrivacySignUpLink("/* $signUpLink */"), "ブロックコメントの中のリンクを通した")
    }

    @Test
    fun `プライバシーポリシーの文言はiOSの設定の法的情報と同じ`() {
        // iOS: SettingsView.swift の legalSection `title: "プライバシーポリシー"`
        assertTrue(
            stringsSource.contains("""<string name="privacy_policy_title">プライバシーポリシー</string>"""),
            "strings.xml の privacy_policy_title が iOS の「プライバシーポリシー」と違う",
        )
    }

    /** 写し [source] のコメントを除いて、プライバシーポリシーの設定の項目があるかを見る。 */
    private fun hasPrivacySettingsItem(source: String): Boolean =
        LegalLinkSources.hasSettingsItem(LegalLinkSources.code(source), "privacy_policy_title", "PRIVACY_POLICY_URL")

    /** 写し [source] のコメントを除いて、プライバシーポリシーの登録画面のリンクがあるかを見る。 */
    private fun hasPrivacySignUpLink(source: String): Boolean =
        LegalLinkSources.hasSignUpLink(LegalLinkSources.code(source), "privacy_policy_title", "PRIVACY_POLICY_URL")
}
