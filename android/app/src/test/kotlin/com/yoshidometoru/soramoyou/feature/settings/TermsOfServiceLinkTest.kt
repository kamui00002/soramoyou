// ⭐️ 利用規約への導線（設定の項目・新規登録のリンク）の URL・文言・開き方の検査（レビュー R02）（全体レビュー 4 回目 Q18）
package com.yoshidometoru.soramoyou.feature.settings

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * PrivacyPolicyLinkTest と同じ考え方（画面の描画とブラウザが開くことは JVM の単体テストでは確かめられないので、定数の値と画面のソースの
 * 書き方を固定する。端末での目視は設定→利用規約→ブラウザ、登録画面→リンクの 2 本）。:app の単体テストの作業ディレクトリは android/app。
 *
 * 画面のソースはコメントを除いて読み、文言と開く URL は項目（リンク）の呼び出し 1 つの中で結んで見る（LegalLinkSources。
 * 判定の陽性対照は PrivacyPolicyLinkTest の固定の写しのテスト：全体レビュー 4 回目 Q18）。
 */
class TermsOfServiceLinkTest {

    private val stringsSource = File("src/main/res/values/strings.xml").readText()

    @Test
    fun `利用規約のURLはiOSの本文から作ったhostingのtermsのページ`() {
        // 2026-11-02 に公開（PR #240 のマージの後に deploy・/terms/ が 200）。末尾のスラッシュつき（無いと 301 で転送される）
        assertEquals("https://soramoyou-ios.web.app/terms/", TERMS_OF_SERVICE_URL)
    }

    @Test
    fun `設定は、利用規約の文言の項目を押すと、その定数のURLを守りを通して外で開く`() {
        assertTrue(
            LegalLinkSources.hasSettingsItem(LegalLinkSources.settings, "terms_of_service_title", "TERMS_OF_SERVICE_URL"),
            "設定の利用規約の文言の項目が、TERMS_OF_SERVICE_URL を守り（openLegalPage）を通して開いていない",
        )
    }

    @Test
    fun `新規登録の画面も、利用規約の文言のリンクを押すと、その定数のURLを守りを通して外で開く`() {
        assertTrue(
            LegalLinkSources.hasSignUpLink(LegalLinkSources.signUp, "terms_of_service_title", "TERMS_OF_SERVICE_URL"),
            "登録画面の利用規約の文言のリンクが、TERMS_OF_SERVICE_URL を守り（openLegalPage）を通して開いていない",
        )
    }

    @Test
    fun `利用規約の文言はiOSの設定の法的情報と同じ`() {
        // iOS: SettingsView.swift の legalSection `title: "利用規約"`
        assertTrue(
            stringsSource.contains("""<string name="terms_of_service_title">利用規約</string>"""),
            "strings.xml の terms_of_service_title が iOS の「利用規約」と違う",
        )
    }
}
