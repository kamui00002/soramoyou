// ⭐️ キャプションからハッシュタグを抽出する（タスク 20.1・要件 7.7）
package com.yoshidometoru.soramoyou.contract.rules

/**
 * キャプションからハッシュタグを抽出する。iOS 版と同じ結果を返す。
 *
 * ## iOS 版の規則（Soramoyou/Soramoyou/ViewModels/PostViewModel.swift:194-207）
 * `#(\w+)` を NSRegularExpression（ICU）で評価し、1 番目の捕獲（`#` を除いた部分）を出現順に配列にする。ここから次が決まる。
 * - タグの始まりは ASCII の `#`（U+0023）だけ。全角の `＃` は始まりにならない
 * - `#` の直後に単語文字が 1 つも無ければ何も取らない（`##abc` は 2 つ目の `#` から `abc`、末尾の `#` は何も取らない）
 * - 単語境界の条件は無い（`abc#def` からも `def` を取る）
 * - 単語文字が続く限り伸ばし、それ以外の文字で止まる（`#夕焼け#朝焼け` は 2 つ）
 * - 重複を除かず、小文字化や Unicode の正規化もしない（元の文字列のまま返す）
 *
 * ## 単語文字の定義（正規表現の `\w` は使わない）
 * ICU の `\w` は `[\p{Alphabetic}\p{Mark}\p{Decimal_Number}\p{Connector_Punctuation}‌‍]` である。
 * JDK の `\w` は既定で ASCII だけなので、ひらがなが取れない（陽性対照で 12 件が赤になるのを確認した）。
 * さらに Android の `java.util.regex` は ICU、JVM の単体テストは JDK 独自の実装で、`\p{…}` の綴りも挙動も揃っている保証が無い。
 * そこで正規表現を使わず、[Character] の文字の性質で 1 コードポイントずつ判定する（[isWordCodePoint]）。
 *
 * ## iOS との一致の確認
 * - 0〜0x10FFFF の全コードポイントについて、macOS 27 の ICU の `\w`（Swift 6.4 の NSRegularExpression で 1 文字ずつ実測）と、
 *   JDK 25.0.3（Android Studio 同梱の JBR）での [isWordCodePoint] を比べた。JDK だけが単語文字と見なすものは 0 件。
 *   ICU だけが単語文字と見なすものは 4,773 件で、内訳は次の 2 つだけだった（手元（git の外）の `20.1-*`）。
 *   - 4,699 件：JDK 25 の Unicode の版ではまだ割り当てられていない文字（macOS 27 の ICU の方が新しい版）。
 *     文字の性質で判定しているので、実行環境の Unicode の版が上がれば同じ結果に追いつく
 *   - 74 件：Apple 独自の私用領域（U+F870〜F8D6）。通常の入力では打てない
 * - 49 件の黄金ベクタ（日本語・全角・絵文字・区切り・BMP の外の漢字）の期待値は、iOS と同じコードを Swift 6.4 で実行して作った
 * - ⚠️ Android の端末の [Character] は端末の ICU のデータを使う。端末での一致は**未確認**で、本番での突き合わせはタスク 25.3（要件 17.5）で行う
 *
 * 個数の上限（30 個）の判定は [TextLimits.isHashtagCountWithinLimit]。
 *
 * インターフェースにしてあるのは、画面側のテストが差し替えられるようにするため（設計書 :609）。
 * 本番の実装は [Default] で、`HashtagExtractor.extract(...)` のように直接呼べる。
 */
interface HashtagExtractor {

    /** キャプションのハッシュタグを、`#` を除いた元の文字列のまま、出現順・重複込みで返す。無ければ空の配列。 */
    fun extract(caption: String): List<String>

    companion object Default : HashtagExtractor {

        override fun extract(caption: String): List<String> {
            val tags = mutableListOf<String>()
            var index = 0
            while (index < caption.length) {
                if (caption[index] != '#') {
                    index++
                    continue
                }
                // `#` の次から、単語文字が続く限り進める。代用対（絵文字・BMP の外の漢字など）は 1 コードポイントとして進める
                val start = index + 1
                var end = start
                while (end < caption.length) {
                    val codePoint = caption.codePointAt(end)
                    if (!isWordCodePoint(codePoint)) break
                    end += Character.charCount(codePoint)
                }
                if (end > start) tags.add(caption.substring(start, end))
                // 正規表現と同じく、一致した所の次から探し直す。一致しなかったときは `#` の次から探す（`##abc` の 2 つ目の `#` を拾うため）
                index = end
            }
            return tags
        }

        /**
         * ICU の `\w` と同じ単語文字なら true。
         * Alphabetic・Mark（3 種）・Decimal_Number・Connector_Punctuation と、ゼロ幅非接合子・ゼロ幅接合子。
         */
        private fun isWordCodePoint(codePoint: Int): Boolean {
            if (Character.isAlphabetic(codePoint)) return true
            return when (Character.getType(codePoint).toByte()) {
                Character.NON_SPACING_MARK,
                Character.ENCLOSING_MARK,
                Character.COMBINING_SPACING_MARK,
                Character.DECIMAL_DIGIT_NUMBER,
                Character.CONNECTOR_PUNCTUATION,
                -> true
                else -> codePoint == ZERO_WIDTH_NON_JOINER || codePoint == ZERO_WIDTH_JOINER
            }
        }

        private const val ZERO_WIDTH_NON_JOINER = 0x200C
        private const val ZERO_WIDTH_JOINER = 0x200D
    }
}
