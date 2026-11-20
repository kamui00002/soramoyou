// ⭐️ 分析に送る値の浄化（AnalyticsSanitizer）の黄金ベクタ（タスク 4.1・要件 15.5）
package com.yoshidometoru.soramoyou.platform

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * iOS 版の浄化と同じ結果になることを、入力と期待値の組（黄金ベクタ）で固定する。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Services/LoggingService.swift:230-258（`sanitizeContext`：メール → パスワード → トークンの順の置換）
 * - Soramoyou/Soramoyou/Services/LoggingService.swift:266-289（`sanitizeParameters`：キー名の伏せ字と、文字列の値の置換）
 *
 * 空白の扱い：iOS の NSRegularExpression（ICU）の `\s` は `[\t\n\f\r\p{Z}]` で、全角空白 U+3000 と
 * NBSP U+00A0 を含む。JVM の `\s` は ASCII の空白だけなので、実装は空白の文字クラスを明示している。
 * 全角空白・NBSP のベクタは「区切りとして扱う（`[:=]` の前後に置ける）」と「値の連続を止める」の両方向で置いた。
 * 陽性対照：実装の文字クラスを `\s`／`[^\s]` に置き換えると、全角空白・NBSP の 4 つのベクタだけが落ちることを確かめた（2026-10-03）。
 */
class AnalyticsSanitizerTest {

    // ---- 文字列の値の置換（sanitizeContext 相当） ----

    @Test
    fun `メールアドレスはEMAIL_REDACTEDに置き換わる`() {
        assertEquals(
            "連絡先 [EMAIL_REDACTED] まで",
            AnalyticsSanitizer.sanitizeText("連絡先 user.name+tag@example.co.jp まで"),
        )
    }

    @Test
    fun `パスワードらしき部分は値の終わりの空白の手前までが置き換わる`() {
        assertEquals("[PASSWORD_REDACTED] next", AnalyticsSanitizer.sanitizeText("password: hunter2 next"))
    }

    @Test
    fun `パスワードの規則は大文字小文字を区別しない`() {
        assertEquals("[PASSWORD_REDACTED]", AnalyticsSanitizer.sanitizeText("PWD=abc"))
        assertEquals("[PASSWORD_REDACTED]", AnalyticsSanitizer.sanitizeText("Passwd:abc"))
    }

    @Test
    fun `トークンらしき部分はapi-keyやapikeyやSecretの形でも置き換わる`() {
        assertEquals("[TOKEN_REDACTED] rest", AnalyticsSanitizer.sanitizeText("api-key = XYZ rest"))
        assertEquals("[TOKEN_REDACTED]", AnalyticsSanitizer.sanitizeText("apikey:1"))
        assertEquals("[TOKEN_REDACTED]", AnalyticsSanitizer.sanitizeText("Secret=s"))
        assertEquals("[TOKEN_REDACTED]", AnalyticsSanitizer.sanitizeText("API_KEY=abc"))
    }

    @Test
    fun `全角空白はコロンの前後の区切りとして扱われる`() {
        // iOS の \s は U+3000 を含むので、「password　:　abc」も規則に掛かる（JVM の \s では掛からない）
        assertEquals("[PASSWORD_REDACTED]", AnalyticsSanitizer.sanitizeText("password　:　abc"))
    }

    @Test
    fun `全角空白は値の連続を止める`() {
        // 値は空白の手前まで。U+3000 の後ろの文は残る（JVM の \s では後ろまで飲み込まれる）
        assertEquals("[PASSWORD_REDACTED]　次の文", AnalyticsSanitizer.sanitizeText("pwd=abc　次の文"))
    }

    @Test
    fun `NBSPは等号の前後の区切りとして扱われる`() {
        assertEquals("[TOKEN_REDACTED]", AnalyticsSanitizer.sanitizeText("token = abc"))
    }

    @Test
    fun `NBSPは値の連続を止める`() {
        assertEquals("[TOKEN_REDACTED] rest", AnalyticsSanitizer.sanitizeText("token=abc rest"))
    }

    @Test
    fun `メールが先に置き換わり、その後でトークンの規則に掛かる`() {
        // 1 段目で「token=[EMAIL_REDACTED]」になり、3 段目で全体が [TOKEN_REDACTED] になる（iOS と同じ順）
        assertEquals("[TOKEN_REDACTED]", AnalyticsSanitizer.sanitizeText("token=abc@example.com"))
    }

    @Test
    fun `日本語だけの文は変わらない`() {
        val text = "夕焼けがきれいだった。パスワードもトークンも書いていない"
        assertEquals(text, AnalyticsSanitizer.sanitizeText(text))
    }

    // ---- パラメータの浄化（sanitizeParameters 相当） ----

    @Test
    fun `秘密情報らしいキー名は大文字混じりでも値が伏せ字の文字列になる`() {
        val result = AnalyticsSanitizer.sanitizeParams(
            mapOf(
                "Auth_Method" to ParamValue.S("email"),
                "access_TOKEN" to ParamValue.S("abc"),
                "userPassword" to ParamValue.S("x"),
                "client_secret" to ParamValue.S("y"),
                "API_KEY" to ParamValue.S("z"),
            ),
        )
        assertEquals(
            mapOf(
                "Auth_Method" to ParamValue.S("[REDACTED]"),
                "access_TOKEN" to ParamValue.S("[REDACTED]"),
                "userPassword" to ParamValue.S("[REDACTED]"),
                "client_secret" to ParamValue.S("[REDACTED]"),
                "API_KEY" to ParamValue.S("[REDACTED]"),
            ),
            result,
        )
    }

    @Test
    fun `authorもauthを含むので伏せ字になる（iOSと同じ）`() {
        // iOS の lowerKey.contains("auth")（LoggingService.swift:278）は author にも一致する。揃えるため同じにしている
        assertEquals(
            mapOf("author" to ParamValue.S("[REDACTED]")),
            AnalyticsSanitizer.sanitizeParams(mapOf("author" to ParamValue.S("そら"))),
        )
    }

    @Test
    fun `秘密情報らしいキー名なら数値や真偽値でも伏せ字の文字列になる`() {
        assertEquals(
            mapOf(
                "token_count" to ParamValue.S("[REDACTED]"),
                "has_auth" to ParamValue.S("[REDACTED]"),
                "secret_ratio" to ParamValue.S("[REDACTED]"),
            ),
            AnalyticsSanitizer.sanitizeParams(
                mapOf(
                    "token_count" to ParamValue.L(3L),
                    "has_auth" to ParamValue.B(true),
                    "secret_ratio" to ParamValue.D(0.5),
                ),
            ),
        )
    }

    @Test
    fun `キー名がapikeyなら伏せ字にはならず値の浄化だけが掛かる（iOSと同じ）`() {
        // iOS のキー名の規則は "api_key"（下線つき）だけを見る（LoggingService.swift:277）
        assertEquals(
            mapOf("apikey" to ParamValue.S("abc"), "api-key" to ParamValue.S("[EMAIL_REDACTED]")),
            AnalyticsSanitizer.sanitizeParams(
                mapOf("apikey" to ParamValue.S("abc"), "api-key" to ParamValue.S("a@example.com")),
            ),
        )
    }

    @Test
    fun `普通のキーの文字列の値には文字列の置換が掛かる`() {
        assertEquals(
            mapOf("error_description" to ParamValue.S("送信先 [EMAIL_REDACTED] で失敗")),
            AnalyticsSanitizer.sanitizeParams(
                mapOf("error_description" to ParamValue.S("送信先 a.b@example.com で失敗")),
            ),
        )
    }

    @Test
    fun `普通のキーの数値と真偽値と小数はそのまま`() {
        val params = mapOf(
            "image_count" to ParamValue.L(3L),
            "is_reedit" to ParamValue.B(false),
            "sky_ratio" to ParamValue.D(0.25),
            "visibility" to ParamValue.S("public"),
        )
        assertEquals(params, AnalyticsSanitizer.sanitizeParams(params))
    }
}
