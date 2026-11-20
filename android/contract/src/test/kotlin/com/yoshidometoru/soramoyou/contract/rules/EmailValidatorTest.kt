// ⭐️ 新規登録のメールアドレス検証の単体テスト（タスク 13.1・要件 2.5）
package com.yoshidometoru.soramoyou.contract.rules

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [EmailValidator] が、`firestore.rules` の `isValidEmail` と iOS 版の両方を満たすときだけ通すことを確かめる。
 *
 * 根拠（読んだ現物）:
 * - Firestore Security Rules：firestore.rules の `isValidEmail`（`size() > 0`・`size() <= 254`・
 *   `matches('[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}')`。`matches` は文字列全体の一致）
 * - iOS 版：Soramoyou/Soramoyou/Services/AuthService.swift:137-141
 *   （`[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,64}` を `NSPredicate` の `SELF MATCHES` で評価。長さの上限は無い）
 *
 * 期待値の作り方：iOS の列は、同じ入力を Swift 6.4（macOS 27）の `NSPredicate(format: "SELF MATCHES %@")` へ流して実測した。
 * 実測で分かった iOS の緩さ（下の「全角」のテスト参照）は、Android では真似ずに rules に揃える（要件 2.5「同等以上に厳しい」）。
 *
 * 全角文字・NBSP などは、読みやすさと取り違えの防止のため、ソースに直書きせずコードポイント（[cps]）で組み立てる。
 */
class EmailValidatorTest {

    private val validator: EmailValidator = EmailValidator.Default

    /** コードポイントの並びから文字列を作る。 */
    private fun cps(vararg codePoints: Int): String = buildString { codePoints.forEach { appendCodePoint(it) } }

    /** 失敗メッセージ用。制御文字・非 ASCII を `U+XXXX` に直し、長い入力は先頭と長さだけにする。 */
    private fun describe(email: String): String {
        val shown = email.map { if (it.code in 0x21..0x7E) it.toString() else "<U+%04X>".format(it.code) }.joinToString("")
        return if (shown.length > 90) "${shown.take(40)}…（長さ ${email.length}）" else shown
    }

    private fun assertAccepted(email: String) =
        assertTrue(validator.isValidForSignUp(email), "通るはずが弾かれた: ${describe(email)}")

    private fun assertRejected(email: String) =
        assertFalse(validator.isValidForSignUp(email), "弾くはずが通った: ${describe(email)}")

    /** `local` + `@` + `domain` の全体が [totalLength] 文字になるよう、ローカル部を `a` で埋める。 */
    private fun padLocalPart(domainWithAt: String, totalLength: Int): String =
        "a".repeat(totalLength - domainWithAt.length) + domainWithAt

    // ---- rules の正規表現に一致する例・一致しない例 ----

    @Test
    fun `rulesの正規表現に一致する例は通る`() {
        assertAccepted("user@example.com")
        assertAccepted("user+tag@example.co.jp")        // + とサブドメイン
        assertAccepted("a.b_c%d+e-f@g-h.com")           // ローカル部の記号 . _ % + - とドメインのハイフン
        assertAccepted("a@b.co")                         // TLD は最短の 2 文字
        assertAccepted("A@B.COM")                        // 大文字（クラスは a-z と A-Z の両方）
        assertAccepted("123@456.com")                    // 数字だけのローカル部とドメイン
        // 以下は「形としては正規表現に一致する」だけの例。rules も iOS も弾かないので、ここでも弾かない
        assertAccepted("a@-b.com")                       // ドメインの先頭のハイフン
        assertAccepted("a@b..com")                       // 連続したドット
        assertAccepted(".@b.com")                        // ドットだけのローカル部
    }

    @Test
    fun `rulesの正規表現に一致しない例は通らない`() {
        assertRejected("")                               // 空
        assertRejected("a")                              // @ が無い
        assertRejected("ab.com")                         // @ が無い
        assertRejected("@b.com")                         // ローカル部が空
        assertRejected("a@")                             // ドメインが空
        assertRejected("a@b")                            // ドットが無い
        assertRejected("a@bcom")                         // ドットが無い
        assertRejected("a@.com")                         // ドメインが無い（ドットの前が空）
        assertRejected("a@b.c")                          // TLD が 1 文字
        assertRejected("a@b.c0m")                        // TLD に数字（TLD は英字だけ）
        assertRejected("a@b.com1")                       // TLD の末尾に数字
        assertRejected("a@b.com.")                       // 末尾のドット（TLD が空）
        assertRejected("a@b_c.com")                      // ドメインのアンダースコア（ドメインのクラスに _ は無い）
        assertRejected("a b@c.com")                      // 空白
        assertRejected("a,b@c.com")                      // ローカル部に使えない記号
        assertRejected("a@b@c.com")                      // @ が 2 つ
        assertRejected(cps(0x3042) + "@b.com")           // 非 ASCII（あ）
    }

    @Test
    fun `rulesのTLDの下限2文字はTLD1文字を弾き2文字を通す`() {
        // rules は `{2,}`、iOS は `{2,64}`。下限はどちらも 2
        assertRejected("a@b.c")
        assertAccepted("a@b.jp")
    }

    // ---- 文字列全体の一致 ----

    @Test
    fun `前後の空白や改行があると通らない（文字列全体の一致）`() {
        assertRejected("a@b.com\n")                      // 末尾の改行（行末の $ で判定する実装だと通ってしまう）
        assertRejected("\na@b.com")
        assertRejected(" a@b.com")
        assertRejected("a@b.com ")
        assertRejected("a@b.com" + cps(0xA0))            // 末尾の NBSP
        assertRejected("a@b.com\nc@d.com")               // 1 行目だけが形に合う複数行
        assertRejected("x a@b.com")                      // 一部だけ一致する（containsMatchIn だと通る）
        assertRejected("a@b.com extra")
    }

    // ---- 長さ ----

    @Test
    fun `長さ254は通り255は通らない`() {
        // "@example.com" は 12 文字。ローカル部を a で埋めて全体を 254 / 255 文字にする（TLD は 3 文字）
        val length254 = padLocalPart("@example.com", 254)
        val length255 = padLocalPart("@example.com", 255)
        assertEquals(254, length254.length)
        assertEquals(255, length255.length)
        assertAccepted(length254)
        assertRejected(length255)                        // 形は正規表現に一致するが、rules の size() <= 254 を超える
    }

    @Test
    fun `長さの上限はTLDが上限ちょうどでも効く`() {
        // TLD 64 文字（iOS の上限ちょうど）で、全体を 254 / 255 文字にする。長さだけが通否を分ける
        val domain = "@example." + "a".repeat(64)
        val length254 = padLocalPart(domain, 254)
        val length255 = padLocalPart(domain, 255)
        assertAccepted(length254)
        assertRejected(length255)
    }

    @Test
    fun `長さが1でも空でも通らない`() {
        assertRejected("")
        assertRejected("a")
    }

    // ---- TLD の上限（iOS） ----

    @Test
    fun `TLDは64文字まで通り65文字は通らない`() {
        // iOS の `[A-Za-z]{2,64}`（AuthService.swift:138）。rules は上限が無いので、これは iOS 側だけの条件
        assertAccepted("x@example." + "a".repeat(63))
        assertAccepted("x@example." + "a".repeat(64))
        assertRejected("x@example." + "a".repeat(65))
        assertRejected("x@example." + "a".repeat(100))
    }

    @Test
    fun `サブドメインがあってもTLDの上限は最後のラベルで判定する`() {
        assertAccepted("a@foo.bar." + "a".repeat(64))
        assertRejected("a@foo.bar." + "a".repeat(65))
        // 最後のラベル以外が 64 文字を超えていても、TLD の上限とは無関係（rules にも iOS にもラベル長の制限は無い）
        assertAccepted("a@" + "b".repeat(100) + ".com")
    }

    @Test
    fun `TLDが65文字のアドレスはrulesの正規表現では通るがiOSの上限で弾く`() {
        // 弾く理由が「正規表現」でなく「iOS の上限 64」であることを固定する。rules の正規表現（firestore.rules の `isValidEmail`）を
        // このテストの中に写して、同じ入力が rules 側では通ることを確かめる
        val rulesPattern = Regex("[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}")
        val tld65 = "x@example." + "a".repeat(65)
        assertTrue(rulesPattern.matches(tld65), "前提：rules の正規表現は TLD 65 文字を通す")
        assertTrue(tld65.length <= 254, "前提：長さの上限には掛からない")
        assertRejected(tld65)
    }

    // ---- iOS の緩さを真似ない ----

    @Test
    fun `全角や互換文字は通らない（iOSのNSPredicateは通すが、rulesは通さない）`() {
        // Swift 6.4（macOS 27）の NSPredicate は、次の 6 件をすべて true と判定した（実測）。
        // NSPredicate の MATCHES は大文字小文字・全角半角を区別しないため。rules の `matches` は ASCII の範囲だけを通す。
        // 通すと Firebase Authentication のアカウントだけ作られ、users の作成が rules で拒否される（要件 2.5・2.11）ので、弾く
        assertRejected(cps(0xFF41) + "@b.com")           // 全角 a
        assertRejected("a@" + cps(0xFF42) + ".com")      // ドメインの全角 b
        assertRejected("a@b." + cps(0xFF43) + "om")      // TLD の全角 c
        assertRejected("a" + cps(0xFF20) + "b.com")      // 全角 @
        assertRejected(cps(0x212A) + "@b.com")           // ケルビン記号。大文字小文字を畳むと k になる
        assertRejected(cps(0x17F) + "@b.com")            // 長い s。同じく s になる
    }

    @Test
    fun `iOSが弾く入力もrulesと同様に弾く`() {
        // Swift 6.4 の NSPredicate が false と判定した入力（実測）。Android でも当然 false
        assertRejected("a@b.c0m")
        assertRejected("a@b_c.com")
        assertRejected(cps(0x663) + "@b.com")            // アラビア・インド数字
        assertRejected(cps(0xE9) + "@b.com")             // é
    }
}
