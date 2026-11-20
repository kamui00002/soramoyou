// ⭐️ 入力の上限と、文字数・空白だけの判定（タスク 13.1・23.2・要件 2.6・7.6・10.10）
package com.yoshidometoru.soramoyou.contract.rules

import java.text.BreakIterator
import java.util.Locale

/**
 * 入力の上限の定数と、文字数・空白だけかどうかの判定。数え方は、iOS 版と同じ値になるように合わせてある。
 *
 * ## 定数の根拠（読んだ現物）
 * - [PASSWORD_MIN]：Soramoyou/Soramoyou/Services/AuthService.swift:51（`password.count >= 6`）
 * - [DISPLAY_NAME_MAX]・[BIO_MAX]：Soramoyou/Soramoyou/ViewModels/ProfileViewModel.swift:743-744
 *   （`editingDisplayName.count <= 50`・`editingBio.count <= 200`）
 * - [CAPTION_MAX]：firestore.rules:31（`caption.size() <= 2000`）
 * - [HASHTAGS_MAX]：firestore.rules:36（`hashtags.size() <= 30`）
 * - [FEEDBACK_MAX]：firestore.rules:394（`message.size() <= 1000`）、Soramoyou/Soramoyou/Models/Feedback.swift:62
 * - [IMAGES_MIN]・[IMAGES_MAX]：firestore.rules:61-62（`images.size() >= 1`・`<= 10`）
 *
 * このうち、判定の関数があるのは、パスワード・表示名・自己紹介（13.1）、ハッシュタグの数（[isHashtagCountWithinLimit]）、
 * キャプションの長さ（[isCaptionWithinLimit]）、フィードバックの本文の長さ（[isFeedbackWithinLimit]・タスク 28）である。
 * 判定の関数が無いのは画像の枚数だけで、定数を使う側が直接比べる（投稿の確定の前の検査 PostPublisher・写真の選択の上限・
 * 契約の画像の数の範囲 ShapeContracts）。
 */
object TextLimits {
    const val PASSWORD_MIN = 6
    const val CAPTION_MAX = 2000
    const val HASHTAGS_MAX = 30
    const val FEEDBACK_MAX = 1000
    const val DISPLAY_NAME_MAX = 50
    const val BIO_MAX = 200
    const val IMAGES_MIN = 1
    const val IMAGES_MAX = 10

    /**
     * iOS の `CharacterSet.whitespacesAndNewlines` に含まれるコードポイントの全範囲。
     *
     * Swift 6.4（macOS 27）で、0〜0x10FFFF の全スカラー値を 1 つずつ `contains` に当てて実測した（推測や仕様書の転記ではない）。
     * 内訳は、制御文字の空白（水平タブ〜復帰）・半角空白・NEL・NBSP・オガム文字の空白・U+2000〜U+200B
     * （en/em 空白の各種とゼロ幅スペース）・行区切りと段落区切り・狭い NBSP・数式用の中空白・全角空白である。
     *
     * 使い分けの注意：
     * - Kotlin の `Char.isWhitespace()`・`String.isBlank()` は使わない。U+0085 とゼロ幅スペースを含まず、
     *   iOS が空白と見なさない U+001C〜U+001F を含むため、iOS と集合が食い違う。
     * - Unicode の White_Space プロパティとも 1 点違う。U+200B は White_Space には無いが、Apple の集合には入っている
     *   （ゼロ幅スペースだけの表示名を「空」と扱う、という iOS の挙動をそのまま写す）。
     * - 全て BMP の範囲なので、UTF-16 の 1 文字（Char）ずつ見れば足りる（代用対はどの範囲にも入らない）。
     */
    private val WHITESPACE_RANGES: List<IntRange> = listOf(
        0x0009..0x000D,
        0x0020..0x0020,
        0x0085..0x0085,
        0x00A0..0x00A0,
        0x1680..0x1680,
        0x2000..0x200B,
        0x2028..0x2029,
        0x202F..0x202F,
        0x205F..0x205F,
        0x3000..0x3000,
    )

    /**
     * 見た目の 1 文字（書記素クラスタ）の数。iOS の `String.count` と同じ数え方である。
     * 結合文字・肌色の修飾・ZWJ で連結した絵文字・国旗は 1 つに数える。UTF-16 の長さ（`length`）とは一致しない。
     *
     * ## 設計書からの置き換え
     * 設計書（:623）は `android.icu.text.BreakIterator` と書くが、`:contract` は Android に依存しない純 Kotlin なので使えない。
     * JDK の `java.text.BreakIterator` で数える。Android の実行環境では、これは ICU を土台にした実装になる
     * （設計書の `android.icu` と同じ系統）。端末では TextLimitsDeviceTest で確かめた（2026-11-08）：API 36（ICU 76.1・Unicode 16.0）では
     * 29 個の黄金ベクタが iOS と全件一致し、API 26（ICU 58.2・Unicode 9.0）では 2 個だけ多く数えた（[isLegacyGraphemeBreaking]）。
     *
     * ## 一致の確認
     * 30 件の黄金ベクタ（結合文字・肌色・ZWJ・国旗・CRLF・ハングル・タイ文字・キーキャップ・タグ列の旗など）で、
     * Swift 6.4（macOS 27）の `String.count` と JDK 25.0.3（Android Studio 同梱の JBR）の本関数が全件一致した。
     * ⚠️ JDK の `BreakIterator` が拡張書記素クラスタ（UAX #29）に対応したのは JDK 20 以降。`:contract` はテストの JDK を固定していないので、
     * JDK 19 以前では、ZWJ・肌色・国旗のベクタを含むテストを守り（TextLimitsTest）が「JDK 20 以上で流すこと」で落とす
     * （JDK 17〜19 では流していない＝推定）。これはテストの JVM の話で、本番（端末の ICU）の数え方については何も言わない。
     * 同じ理由で、Unicode のバージョンで結果が変わりうるインド系文字の合成（Devanagari の子音連結など）は、ベクタに入れていない。
     *
     * 対にならない代用対（IME・貼り付けで作れてしまう）でも例外は投げず、1 個として数える（JDK 25 で実測）。
     *
     * `BreakIterator` はスレッドセーフでないので、共有せず呼び出しごとに作る。
     * 地域による差が出ないよう [Locale.ROOT] を指定する。
     */
    fun graphemeCount(text: String): Int {
        if (text.isEmpty()) return 0
        val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
        iterator.setText(text)
        var count = 0
        iterator.first()
        while (iterator.next() != BreakIterator.DONE) count++
        return count
    }

    /**
     * この実行環境の書記素の数え方が古い規則（Unicode 11 より前の拡張書記素クラスタの規則）なら true。
     * 古い規則では、ZWJ（U+200D）の後ろの絵文字が決まった一覧（Glue_After_Zwj）に無いと、そこで切れる。そのため [graphemeCount] が
     * iOS の `String.count` より**多く**数える並びがある（全体レビュー 4 回目 R21）。
     *
     * ## 測った値（端末テスト TextLimitsDeviceTest・2026-11-08）
     * API 26（Android 8.0・ICU 58.2・Unicode 9.0）では、29 個の黄金ベクタのうち次の 2 個だけが、iOS の 1 に対して 2 になった。
     * どちらも「異体字セレクタ（U+FE0F）＋ZWJ」の後ろで切れた：
     * - 虹の旗（U+1F3F3 U+FE0F U+200D U+1F308）
     * - 燃えるハート（U+2764 U+FE0F U+200D U+1F525）
     *
     * API 36（Android 16・ICU 76.1・Unicode 16.0）では 29 個とも iOS と一致し、この判定は false だった。
     * API 27・28 は測っていない。29 個に無い並び（Unicode 9 より後に足された絵文字と肌色の組など）も、多く数える見込み（未測）。
     *
     * ## 判定のしかた
     * 版の番号では分けず、燃えるハートを実際に [graphemeCount] で数えて、1 にならなければ古いとみなす。`:contract` は Android に
     * 依存しないので、`Build.VERSION` も ICU の版も読めないため。燃えるハートの炎（U+1F525）は古い規則の一覧に無いので、古い規則では
     * ZWJ の後ろで切れ、新しい規則（ZWJ の後ろが絵文字の性質〔Extended_Pictographic〕を持てばつなぐ）では 1 つになる
     * （一覧に無いことは推定。測ったのは API 26 の 2 と、API 36 と開発機の JDK 25 の 1）。
     *
     * ## 使い道（利用者の決定・2026-11-08）
     * true の端末では、表示名・自己紹介の上限（[DISPLAY_NAME_MAX]・[BIO_MAX]）で保存を止めない（iOS では通る値を止めてしまうため）。
     * 止めるかどうかを決めるのは :app のプロフィールの保存の部品と編集画面で、この値はその判断の材料である。
     * パスワードの下限（[isPasswordLongEnough]）には使わない。多く数えると緩い側に倒れ、誰も止まらないため。
     *
     * 1 回だけ数えて覚える（実行環境の ICU は、動いている間に変わらない）。
     */
    val isLegacyGraphemeBreaking: Boolean by lazy { detectsLegacyGraphemeBreaking(::graphemeCount) }

    /**
     * [isLegacyGraphemeBreaking] の判定の本体。数え方 [count] で燃えるハートが 1 にならなければ true。
     * 単体テストで数え方を差し替えるため、覚える部分と分けた（開発機の JDK 20 以上では、本物の数え方で false になる）。
     */
    internal fun detectsLegacyGraphemeBreaking(count: (String) -> Int): Boolean = count(LEGACY_PROBE) != 1

    /** 燃えるハート（U+2764 U+FE0F U+200D U+1F525）。iOS の `String.count` は 1（TextLimitsTest の黄金ベクタ）。 */
    private val LEGACY_PROBE: String = String(intArrayOf(0x2764, 0xFE0F, 0x200D, 0x1F525), 0, 4)

    /**
     * 空、または空白（全角空白を含む Unicode の空白）だけの文字列なら true。
     * iOS が「空白だけ」を判定する `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`
     * （Feedback.swift:62、PostViewModel.swift:859）と同じ集合で判定する（集合の詳細は [WHITESPACE_RANGES]）。
     *
     * 表示名・自己紹介の iOS 版（ProfileViewModel.swift:534-535）は `isEmpty` だけで、空白だけの値も「空でない」として保存する。
     * 空白だけの判定をどこに使うかは、設計書（:623）に従う呼び出し側（プロフィール編集）の決定である。
     */
    fun isBlank(text: String): Boolean =
        text.all { char -> WHITESPACE_RANGES.any { range -> char.code in range } }

    /**
     * パスワードが [PASSWORD_MIN] 文字以上なら true（要件 2.6）。
     * iOS（AuthService.swift:51）の `password.count` は書記素クラスタの数なので、同じく書記素で数える。
     * 前後の空白は取り除かない（iOS も取り除かない）。
     */
    fun isPasswordLongEnough(password: String): Boolean = graphemeCount(password) >= PASSWORD_MIN

    /** 表示名が [DISPLAY_NAME_MAX]（50）個以下の書記素なら true（要件 10.10）。空は true（iOS も空を通す）。 */
    fun isDisplayNameWithinLimit(displayName: String): Boolean = graphemeCount(displayName) <= DISPLAY_NAME_MAX

    /** 自己紹介が [BIO_MAX]（200）個以下の書記素なら true（要件 10.10）。空は true（iOS も空を通す）。 */
    fun isBioWithinLimit(bio: String): Boolean = graphemeCount(bio) <= BIO_MAX

    /**
     * 投稿のハッシュタグが [HASHTAGS_MAX]（30）個以下なら true（要件 7.8）。31 個以上なら投稿を確定させない。
     * rules（firestore.rules:35-37）の `hashtags.size() <= 30` と同じく、配列の長さ（重複も 1 個ずつ）で数える。
     * 0 個は true（0 個のときは `hashtags` のキー自体を書かない）。
     * iOS 版には投稿前のこの判定が無く、31 個以上は rules の拒否で初めて失敗する。Android は送る前に止める。
     */
    fun isHashtagCountWithinLimit(hashtags: List<String>): Boolean = hashtags.size <= HASHTAGS_MAX

    /**
     * 前後の空白（[WHITESPACE_RANGES]）を取り除いた文字列。中の空白・改行はそのまま残す。
     * iOS がキャプションを保存する前に行う `trimmingCharacters(in: .whitespacesAndNewlines)`（PostViewModel.swift:859）と同じ集合で取り除く
     * （Kotlin の `String.trim()` は集合が違うので使わない。理由は [WHITESPACE_RANGES]）。
     */
    fun trimWhitespace(text: String): String =
        text.trim { char -> WHITESPACE_RANGES.any { range -> char.code in range } }

    /**
     * 前後の空白を取り除いた後のキャプション [trimmedCaption] が [CAPTION_MAX]（2000）以下なら true（要件 7.6）。
     * rules（firestore.rules:31）の `caption.size() <= 2000` と同じく **UTF-16 の単位**で数える（絵文字の多くは 1 つで 2。
     * 書記素で数える表示名・自己紹介の上限とは数え方が違う）。保存するのは取り除いた後の値なので、取り除いた後で判定する。
     * iOS 版には投稿前のこの判定が無く、超えると rules の拒否で初めて失敗する。Android は送る前に止める。
     */
    fun isCaptionWithinLimit(trimmedCaption: String): Boolean = trimmedCaption.length <= CAPTION_MAX

    /**
     * 前後の空白を取り除いた後のフィードバックの本文 [trimmedMessage] が [FEEDBACK_MAX]（1000）以下なら true（要件 13.3）。
     * rules（firestore.rules:393-394）の `message.size() <= 1000` と同じく **UTF-16 の単位**で数える（絵文字の多くは 1 つで 2）。
     * iOS（FeedbackViewModel.swift:42-43）は書記素（`trimmed.count <= 1000`）で数えるので、絵文字の多い本文は iOS では通っても
     * rules が断る。Android は送る前に rules と同じ数え方で止める。保存するのは取り除いた後の値なので、取り除いた後で判定する。
     * 空白だけかどうか（要件 13.3）は別で、[isBlank] で判定する。
     */
    fun isFeedbackWithinLimit(trimmedMessage: String): Boolean = trimmedMessage.length <= FEEDBACK_MAX
}
