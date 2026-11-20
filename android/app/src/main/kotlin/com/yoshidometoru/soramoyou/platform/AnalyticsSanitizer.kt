// ⭐️ 分析に送る値の浄化（タスク 4.1・要件 15.5）
package com.yoshidometoru.soramoyou.platform

/**
 * 分析に送る前に、秘密情報や個人情報らしい部分を取り除く。iOS 版の規則をそのまま移した純粋関数である。
 *
 * 根拠（読んだ現物）:
 * - Soramoyou/Soramoyou/Services/LoggingService.swift:230-258（`sanitizeContext`）
 * - Soramoyou/Soramoyou/Services/LoggingService.swift:266-289（`sanitizeParameters`）
 *
 * ⚠️ 空白は `\s` を使わず、文字クラスを明示している（[WS]・[NON_WS]）。
 *    iOS の NSRegularExpression（ICU）の `\s` は `[\t\n\f\r\p{Z}]` で、全角空白 U+3000 と NBSP U+00A0 を含む。
 *    一方、JVM の `\s` は ASCII の空白だけで、Android 端末の java.util.regex は ICU 実装である。
 *    `\s` のままだと「JVM の単体テストと端末とで結果が違う」ことになるので、明示して両方を iOS に揃える
 *    （設計書のハッシュタグの抽出と同じ方針）。
 */
object AnalyticsSanitizer {

    /** キー名の伏せ字に使う値（iOS: LoggingService.swift:280）。 */
    private const val REDACTED = "[REDACTED]"

    /** キー名を小文字にしてこれらのどれかを含めば、値の型にかかわらず伏せ字にする（iOS: LoggingService.swift:273-278）。 */
    private val SENSITIVE_KEY_PARTS = listOf("password", "token", "secret", "api_key", "auth")

    /** ICU の `\s` と同じ空白の文字クラス。 */
    private const val WS = """[\t\n\f\r\p{Z}]"""

    /** ICU の `[^\s]` と同じ、空白以外の文字クラス。 */
    private const val NON_WS = """[^\t\n\f\r\p{Z}]"""

    // 置換の順は iOS と同じ（メール → パスワード → トークン）。置換文字列に `$` と `\` は入れない（Regex.replace の特殊文字）。
    private val EMAIL = Regex("""[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}""")
    private val PASSWORD = Regex("""(password|passwd|pwd)$WS*[:=]$WS*$NON_WS+""", RegexOption.IGNORE_CASE)
    private val TOKEN = Regex("""(token|api[_-]?key|secret)$WS*[:=]$WS*$NON_WS+""", RegexOption.IGNORE_CASE)

    /**
     * 文字列の中のメールアドレス・パスワードらしき部分・トークンらしき部分を置き換える（iOS の `sanitizeContext`）。
     * タスク 4.2 のエラーの説明・発生箇所の浄化にも使う。
     */
    fun sanitizeText(text: String): String =
        text
            .replace(EMAIL, "[EMAIL_REDACTED]")
            .replace(PASSWORD, "[PASSWORD_REDACTED]")
            .replace(TOKEN, "[TOKEN_REDACTED]")

    /**
     * パラメータを浄化する（iOS の `sanitizeParameters`）。キーはそのまま残す。
     * - 秘密情報らしいキー名 → 値の型にかかわらず文字列の `[REDACTED]`
     *   （`author` も `auth` を含むので伏せ字になる。iOS と同じ結果にするため、そのままにしている）
     * - それ以外の文字列の値 → [sanitizeText]
     * - それ以外の数値・真偽値・小数 → そのまま
     */
    fun sanitizeParams(params: Map<String, ParamValue>): Map<String, ParamValue> =
        params.mapValues { (key, value) ->
            val lowerKey = key.lowercase()
            when {
                SENSITIVE_KEY_PARTS.any { lowerKey.contains(it) } -> ParamValue.S(REDACTED)
                value is ParamValue.S -> ParamValue.S(sanitizeText(value.v))
                else -> value
            }
        }
}
