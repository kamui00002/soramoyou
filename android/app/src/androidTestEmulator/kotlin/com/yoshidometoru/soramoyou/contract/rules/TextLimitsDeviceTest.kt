// ⭐️ 書記素の数え方（TextLimits.graphemeCount）を、端末の ICU で確かめる（全体レビュー 4 回目 R21・要件 10.10）
package com.yoshidometoru.soramoyou.contract.rules

import android.icu.lang.UCharacter
import android.icu.util.VersionInfo
import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.yoshidometoru.soramoyou.data.repository.exceedsProfileTextLimit
import com.yoshidometoru.soramoyou.feature.profile.ProfileEditLoad
import com.yoshidometoru.soramoyou.feature.profile.ProfileEditUiState
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * [TextLimits.graphemeCount] は JDK の `java.text.BreakIterator` で数える。Android の実行環境では、これは端末の ICU を土台にした
 * 実装になるので、数え方は端末の ICU（OS の版）しだいになる。:contract の [TextLimitsTest] は開発機の JDK で流れるので、
 * 端末の数え方は確かめられない。ここでは同じ黄金ベクタ（Swift 6.4 の `String.count` の実測値）を端末で数える。
 *
 * - ベクタの並び（`val vectors = listOf(` の塊）と、その中で名前で呼ぶ値の定義は、[TextLimitsTest] の写しである。
 *   :app の単体テスト TextLimitsDeviceVectorsSourceTest が、2 つのファイルで文字どおり同じかを確かめる（片方だけ直すと赤）。
 * - 食い違いは最初の 1 件で止めず、全部集めてから 1 回で比べる（どのベクタがずれたかを 1 回の実行で読むため）。
 * - 端末の版（SDK_INT）・ICU と Unicode の版をログと失敗の文に出す（ずれの範囲を決める材料）。
 * - [TextLimitsTest] の JDK の版の確かめ（`Runtime.version()`）は使わない。`Runtime.version()` は古い版の Android に無い見込みで、
 *   ここで確かめたいのは JDK ではなく端末の ICU なので要らない。
 *
 * ## 古い規則の端末（2026-11-08 に API 26 で測った）
 * Unicode 11 より前の規則の ICU では、iOS より多く数えるベクタがある。API 26（ICU 58.2・Unicode 9.0）で測ると、29 個のうち
 * 虹の旗と燃えるハートの 2 個だけが 1 → 2 になった（[TextLimits.isLegacyGraphemeBreaking] の KDoc）。利用者の決定で、その端末では
 * 表示名・自己紹介の上限で保存を止めない（:app の `exceedsProfileTextLimit`）。ここでは、端末の Unicode の版で古い規則かどうかを決め
 * （数えて決める [TextLimits.isLegacyGraphemeBreaking] とは別の道）、次を確かめる：
 * - 古い規則の端末では、ずれが測った 2 個とちょうど同じ（ずれが増えた・減ったら赤＝範囲が変わったので測り直す）。新しい端末では 0 個
 * - 数えて決める判定が、版で決めた答えと合う
 * - 本番と同じ既定の値で呼ぶと、古い規則の端末でだけ上限で止めない（判断の関数と編集画面の状態。保存の部品〔ProfileEditor〕は
 *   同じ関数を同じ形で呼ぶが、ここでは作っていない）
 *
 * 版の境い目（Unicode 11）のまわりで測ったのは API 26（古い）だけで、API 27・28（Unicode 10 の見込み）は測っていない。
 * 新しい側は API 36（ICU 76.1・Unicode 16.0）で流し、29 個とも iOS と一致して 3 本とも緑だった（2026-11-08）。
 *
 * Firebase のエミュレータは使わない。実行は
 * `./gradlew :app:connectedEmulatorDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.yoshidometoru.soramoyou.contract.rules.TextLimitsDeviceTest`
 * （仮想端末が要る。終わると検証用のアプリ〔.emulator〕は端末から消える。本番用のアプリには触れない）。
 */
@RunWith(AndroidJUnit4::class)
class TextLimitsDeviceTest {

    /** コードポイントの並びから文字列を作る（[TextLimitsTest] と同じ）。 */
    private fun cps(vararg codePoints: Int): String = buildString { codePoints.forEach { appendCodePoint(it) } }

    private val thumbsUpWithSkinTone = cps(0x1F44D, 0x1F3FD)                                     // 肌色の修飾つきの親指（UTF-16 で 4 文字・書記素 1）
    private val familyZwj = cps(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0x200D, 0x1F466)       // ZWJ で連結した家族（UTF-16 で 11・書記素 1）
    private val flagJapan = cps(0x1F1EF, 0x1F1F5)                                                  // 国旗（UTF-16 で 4・書記素 1）
    private val eAcuteDecomposed = cps(0x65, 0x301)                                                // e + 結合アクセント（UTF-16 で 2・書記素 1）

    /** 失敗メッセージ用（[TextLimitsTest] と同じ）。 */
    private fun describe(text: String): String = text.map { "<U+%04X>".format(it.code) }.joinToString("")

    /** 食い違いの 1 件の文。 */
    private fun mismatch(text: String, expected: Int, actual: Int): String = "${describe(text)}（期待=$expected・端末=$actual）"

    /** 端末の版（ログと失敗の文に出す）。 */
    private val versions: String =
        "SDK ${Build.VERSION.SDK_INT}・ICU ${VersionInfo.ICU_VERSION}・Unicode ${UCharacter.getUnicodeVersion()}"

    /**
     * 端末の ICU が古い規則（Unicode 11 より前）か。Unicode の版の番号で決める。Unicode 11 で、拡張書記素クラスタの ZWJ の規則が
     * 「決まった一覧の絵文字の前だけつなぐ」から「絵文字の性質〔Extended_Pictographic〕を持てばつなぐ」に変わった。
     */
    private val legacyByVersion: Boolean = UCharacter.getUnicodeVersion().major < 11

    /** 古い規則の端末で、iOS と食い違うと分かっている（API 26 で測った）ベクタの食い違いの文。並びはベクタの順。 */
    private val knownLegacyMismatches: List<String> = listOf(
        mismatch(cps(0x1F3F3, 0xFE0F, 0x200D, 0x1F308), expected = 1, actual = 2), // 虹の旗
        mismatch(cps(0x2764, 0xFE0F, 0x200D, 0x1F525), expected = 1, actual = 2),  // 燃えるハート
    )

    @Test
    fun 書記素の数はSwiftのStringのcountと一致し_古い規則の端末では測った2個だけがずれる() {
        Log.i(TAG, "端末の版: $versions・版で決めた古い規則=$legacyByVersion")
        // （文字列, 期待する書記素の数）。期待値は Swift 6.4 の String.count の実測（TextLimitsTest の写し）
        val vectors = listOf(
            "" to 0,
            "abc" to 3,
            "あいう" to 3,
            "空の😀写真" to 5,
            eAcuteDecomposed to 1,                                       // 結合文字
            cps(0x304B, 0x3099) to 1,                                    // か + 濁点（結合）
            cps(0x61, 0x300, 0x301) to 1,                                // 結合文字が 2 つ続く
            cps(0x1F44D) to 1,                                           // 親指
            thumbsUpWithSkinTone to 1,                                   // 肌色の修飾
            familyZwj to 1,                                              // ZWJ で連結した家族
            cps(0x1F469, 0x1F3FD, 0x200D, 0x1F4BB) to 1,                 // 肌色の修飾 + ZWJ（女性技術者）
            cps(0x1F3F3, 0xFE0F, 0x200D, 0x1F308) to 1,                  // 異体字セレクタ + ZWJ（虹の旗）
            cps(0x2764, 0xFE0F, 0x200D, 0x1F525) to 1,                   // 燃えるハート
            cps(0x1F91D, 0x200D, 0x1F91D) to 1,                          // ZWJ で絵文字どうしを連結
            cps(0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F) to 1, // タグ列の国旗（イングランド）
            flagJapan to 1,                                              // 国旗（地域指示子 2 つ）
            flagJapan + cps(0x1F1FA, 0x1F1F8) to 2,                      // 国旗 2 つ
            flagJapan + cps(0x1F1FA) to 2,                               // 国旗 + 対にならない地域指示子 1 つ
            cps(0x1F1EF, 0x1F1F5, 0x1F1FA, 0x1F1F8, 0x61) to 3,          // 国旗 2 つ + a
            cps(0x31, 0xFE0F, 0x20E3) to 1,                              // キーキャップ
            "\r\n" to 1,                                                 // CRLF は 1 つ
            "\n\r" to 2,                                                 // LF CR は 2 つ
            cps(0x1112, 0x1161, 0x11AB) to 1,                            // ハングルの字母（L V T）
            cps(0xAC00, 0x11A8) to 1,                                    // ハングルの音節 + 終声
            cps(0x0E01, 0x0E33) to 1,                                    // タイ文字（SARA AM は広がる結合記号）
            cps(0x61, 0x200D) to 1,                                      // 末尾の ZWJ は直前に付く
            cps(0x61, 0x200D, 0x62) to 2,                                // 文字どうしの間の ZWJ は連結しない
            cps(0x200B) to 1,                                            // ゼロ幅スペース
            cps(0x0600, 0x31) to 1,                                      // 前置される記号（アラビアの数字記号）
        )
        val mismatches = mutableListOf<String>()
        for ((text, expected) in vectors) {
            val actual = TextLimits.graphemeCount(text)
            Log.i(TAG, "${describe(text)} 期待=$expected 端末=$actual")
            if (actual != expected) mismatches += mismatch(text, expected, actual)
        }
        val allowed = if (legacyByVersion) knownLegacyMismatches else emptyList()
        assertEquals(
            "端末の書記素の数が iOS（Swift の String.count）と食い違うベクタが、版から見込んだものと違う（$versions・版で決めた古い規則=$legacyByVersion）",
            allowed,
            mismatches,
        )
    }

    @Test
    fun 数えて決める古い数え方の判定は端末のUnicodeの版で決めた答えと合う() {
        Log.i(TAG, "端末の版: $versions・版で決めた古い規則=$legacyByVersion・数えて決めた判定=${TextLimits.isLegacyGraphemeBreaking}")
        assertEquals("TextLimits.isLegacyGraphemeBreaking が端末の版と合わない（$versions）", legacyByVersion, TextLimits.isLegacyGraphemeBreaking)
    }

    @Test
    fun 本番と同じ既定の値では古い規則の端末でだけ上限で止めない() {
        val overName = "あ".repeat(TextLimits.DISPLAY_NAME_MAX + 1)
        val overBio = "い".repeat(TextLimits.BIO_MAX + 1)
        val enforced = !legacyByVersion
        Log.i(TAG, "端末の版: $versions・上限で止める見込み=$enforced")

        // 判断の関数（保存の部品と編集画面が使う）を、本番と同じく enforce を渡さずに呼ぶ
        assertEquals("変えた表示名の上限（$versions）", enforced, exceedsProfileTextLimit(overName, "そら", TextLimits::isDisplayNameWithinLimit))
        assertEquals("変えた自己紹介の上限（$versions）", enforced, exceedsProfileTextLimit(overBio, "空が好き", TextLimits::isBioWithinLimit))

        // 編集画面の状態（読んだ値から変えた上限超えの表示名）。古い規則の端末でだけ保存を押せる
        val state = ProfileEditUiState(load = ProfileEditLoad.Ready, displayName = overName, loadedDisplayName = "そら")
        assertEquals("編集画面の表示名の赤い枠（$versions）", enforced, state.displayNameOverLimit)
        assertEquals("編集画面の保存のボタン（$versions）", !enforced, state.canSave)
    }

    private companion object {
        const val TAG = "TextLimitsDeviceTest"
    }
}
