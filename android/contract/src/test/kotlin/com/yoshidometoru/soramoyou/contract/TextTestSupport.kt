// ⭐️ 文字列を扱う単体テストで共有する部品（M5 レビュー F03）
package com.yoshidometoru.soramoyou.contract

/**
 * コードポイントの並びから文字列を作る。空白に似た文字（全角空白・ゼロ幅スペースなど）は、ソースに直書きせず番号で書いて、
 * 取り違えを防ぐ。
 *
 * テストのファイルごとに同じ 1 行を写していたものを、ここ 1 か所にまとめた。いま使っているのはフィードバックの契約のテスト
 * （FeedbackContractsTest。別のパッケージなので import して使う）。前からある rules/ のテスト（HashtagExtractorTest・
 * TextLimitsTest・EmailValidatorTest）は、それぞれのファイルに同じ中身の private な写しを持っている。rules/ のテストは
 * 別のパッケージ（contract.rules）なので、import しない限りこの関数は見えず、写しとぶつからない。
 */
internal fun cps(vararg codePoints: Int): String = buildString { codePoints.forEach { appendCodePoint(it) } }
