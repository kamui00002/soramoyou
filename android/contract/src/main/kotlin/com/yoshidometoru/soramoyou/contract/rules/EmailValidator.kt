// ⭐️ 新規登録のメールアドレス検証（タスク 13.1・要件 2.5）
package com.yoshidometoru.soramoyou.contract.rules

/**
 * 新規登録で入力されたメールアドレスを、Firebase Authentication のアカウントを作る前に検証する。
 *
 * 通す条件は、次の 3 つを**すべて**満たすことである（`firestore.rules` の `isValidEmail` と iOS 版の、両方を満たす）。
 * 1. 長さが 1〜254（`firestore.rules:49-50` の `size() > 0` と `size() <= 254`）
 * 2. rules の正規表現に、文字列全体で一致する（`firestore.rules:51`。`matches` は全体一致）
 * 3. 最後のドット以降（トップレベルドメイン。以下 TLD）が 64 文字以下（iOS 版の `[A-Za-z]{2,64}`。
 *    Soramoyou/Soramoyou/Services/AuthService.swift:138）
 *
 * 通らないものでアカウントを作ると、Firebase Authentication のアカウントだけが作られて、`users/{uid}` の作成が
 * rules に拒否される（要件 2.5・2.11）。だから Android は、rules より緩くしない。
 *
 * ## iOS との差（意図して、iOS より厳しくしてある）
 * - 長さの上限：iOS は無い（実測で 255 文字を通す）。rules は 254 まで
 * - 全角・互換文字：iOS の `NSPredicate` の `MATCHES` は大文字小文字・全角半角を区別せず、全角の `ａ`・`＠`・ケルビン記号などを
 *   通す（Swift 6.4・macOS 27 で実測）。rules の `matches` は ASCII の範囲だけを通すので、Android は rules に揃えて弾く
 *
 * ## 3 つに分けて書く理由
 * iOS の正規表現は、rules の正規表現の TLD の上限を `{2,}` → `{2,64}` に狭めただけの部分集合である。
 * 1 本にまとめると、どこまでが rules でどこからが iOS かが読めなくなる。そこで rules の正規表現は写したまま残し、
 * iOS 側の条件は「TLD の長さ」の 1 行にして、それぞれを根拠の行と 1 対 1 に対応させる。
 * （rules を通った文字列の「最後のドット以降」は、必ず英字だけの TLD 全体になる。ドットは TLD の外にしか無いため）
 *
 * 長さの判定を正規表現より先に置くのは、正規表現に渡す入力の長さを 254 以下に抑えるためである。
 * 通る文字列は ASCII だけなので、UTF-16 の長さは rules の `size()` と同じ値になる。
 *
 * インターフェースにしてあるのは、画面側のテストが差し替えられるようにするため（設計書 :610）。
 * 本番の実装は [Default] で、`EmailValidator.isValidForSignUp(...)` のように直接呼べる。
 */
interface EmailValidator {

    /** 新規登録に使えるメールアドレスなら true。前後の空白は取り除かない（取り除いた値を渡すのは呼び出し側の責任）。 */
    fun isValidForSignUp(email: String): Boolean

    companion object Default : EmailValidator {

        /** rules の長さの上限（firestore.rules:50）。 */
        private const val LENGTH_MAX = 254

        /** iOS の TLD の上限（AuthService.swift:138 の `{2,64}`）。 */
        private const val TLD_LENGTH_MAX = 64

        /**
         * rules の正規表現そのもの（firestore.rules:51）。Kotlin の `Regex.matches` は全体一致なので、
         * `containsMatchIn`（一部一致）や `IGNORE_CASE` は使わない。使うと「前後に余計な文字がある」「全角が通る」が起きる。
         */
        private val RULES_PATTERN = Regex("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}")

        override fun isValidForSignUp(email: String): Boolean {
            if (email.length !in 1..LENGTH_MAX) return false
            if (!RULES_PATTERN.matches(email)) return false
            return email.substringAfterLast('.').length <= TLD_LENGTH_MAX
        }
    }
}
