// ⭐️ 法的情報のリンクの検査が読む画面のソース（コメントを除いたもの）と、文言と開く URL の結びの判定（全体レビュー 4 回目 Q06・Q18）
package com.yoshidometoru.soramoyou.feature.settings

import java.io.File

/**
 * PrivacyPolicyLinkTest・TermsOfServiceLinkTest・ExternalPageOpenerTest が読む、設定と新規登録の画面のソース。
 *
 * - コメントを除いて返す（コメントの中の呼び出しを、本物の呼び出しとして数えないため）。除き方は StorageRetryLimitWiringTest と同じで、
 *   ブロックコメント（KDoc を含む）を先に、行コメントを後に消す。文字列の中の `//` も消すが、2 つの画面に URL の文字列は無い（URL は定数）
 * - 文言と開く URL は、空白を全部除いたソースで、項目（リンク）の呼び出し 1 つの中に並んでいることで見る（別々に contains で見ると、
 *   2 つの項目の URL を取り違えても通る：全体レビュー 4 回目 Q18）。空白を除くので、折り返しと最後のカンマは通す
 *
 * :app の単体テストの作業ディレクトリは android/app なので、`src/main` を直接読む。
 */
internal object LegalLinkSources {

    // 正規表現は、画面のソースより先に宣言する（object の初期化は宣言の順なので、後ろに置くと下の settings・signUp を作るときに null になる）

    /** ブロックコメント（KDoc を含む）。行コメントより先に消す（KDoc の中に `//` があると、行コメントとしてブロックの閉じまで消してしまうため）。 */
    private val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)

    /** 行コメント（`//` から行末まで）。 */
    private val LINE_COMMENT = Regex("""//[^\n]*""")

    /** 空白（改行を含む）。 */
    private val WHITESPACE = Regex("""\s+""")

    /** 設定の画面のソース（コメントを除いたもの）。 */
    val settings: String = code(File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/settings/SettingsScreen.kt").readText())

    /** 新規登録の画面のソース（コメントを除いたもの）。 */
    val signUp: String = code(File("src/main/kotlin/com/yoshidometoru/soramoyou/feature/auth/SignUpScreen.kt").readText())

    /** [source] からコメントを除く。 */
    fun code(source: String): String = source.replace(BLOCK_COMMENT, "").replace(LINE_COMMENT, "")

    /** 設定の画面の [code] に、[titleRes] の文言の項目を押すと [urlConst] を守り（openLegalPage）を通して開く呼び出しがあるか。 */
    fun hasSettingsItem(code: String, titleRes: String, urlConst: String): Boolean =
        Regex("""SettingsItem\(stringResource\(R\.string\.$titleRes\),onClick=\{openLegalPage\($urlConst\)\},?\)""")
            .containsMatchIn(code.replace(WHITESPACE, ""))

    /** 新規登録の画面の [code] に、[titleRes] の文言のリンクを押すと [urlConst] を守り（openLegalPage）を通して開く呼び出しがあるか。 */
    fun hasSignUpLink(code: String, titleRes: String, urlConst: String): Boolean =
        Regex("""TextButton\(onClick=\{openLegalPage\($urlConst\)\}[^{}]*\)\{Text\(stringResource\(R\.string\.$titleRes\)\)\}""")
            .containsMatchIn(code.replace(WHITESPACE, ""))
}
