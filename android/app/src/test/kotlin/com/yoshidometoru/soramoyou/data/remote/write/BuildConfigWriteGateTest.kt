// ⭐️ ビルド時に焼き込んだマイルストーンと、アプリが使う書き込みのゲートの単体テスト（タスク 6.1・要件 2.2）
package com.yoshidometoru.soramoyou.data.remote.write

import com.yoshidometoru.soramoyou.BuildConfig
import com.yoshidometoru.soramoyou.contract.WriteCapability
import java.io.File
import java.util.Properties
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * gradle.properties の `soramoyou.milestone` → app/build.gradle.kts → `BuildConfig.WRITE_MILESTONE` → [BuildConfigWriteGate]
 * の流れが繋がっていることと、今の設定が M1（書き込みゼロ）であることを確かめる。
 *
 * :app の単体テストの作業ディレクトリはモジュール直下（android/app）なので、`../gradle.properties` を直接読む。
 */
class BuildConfigWriteGateTest {

    private val gradleProperties = File("../gradle.properties")

    /** gradle.properties に書いてあるマイルストーン（コマンドラインの -P などで上書きされる前の値）。 */
    private fun configuredMilestone(): String {
        assertTrue(gradleProperties.isFile, "gradle.properties が見つからない: ${gradleProperties.absolutePath}")
        val properties = Properties().apply { gradleProperties.reader(Charsets.UTF_8).use { load(it) } }
        return assertNotNull(properties.getProperty("soramoyou.milestone"), "gradle.properties に soramoyou.milestone が無い")
    }

    @Test
    fun `BuildConfigに焼き込んだマイルストーンはgradle_propertiesの設定と同じ`() {
        // ビルドの設定が値を焼き込んでいない・別の値を焼き込んでいると失敗する。
        // コマンドラインの -Psoramoyou.milestone=… でファイルと違う値を渡したビルドでも失敗する（設定の正本はファイル）
        assertEquals(configuredMilestone(), BuildConfig.WRITE_MILESTONE)
    }

    @Test
    fun `ゲートの集合は、焼き込んだマイルストーンの表の集合と同じで、変更できない`() {
        assertEquals(Milestone.valueOf(BuildConfig.WRITE_MILESTONE), BuildConfigWriteGate.milestone)
        assertEquals(writeCapabilitiesOf(BuildConfigWriteGate.milestone), BuildConfigWriteGate.enabled)
        assertUnmodifiable(BuildConfigWriteGate.enabled, "BuildConfigWriteGate.enabled")
    }

    @Test
    fun `検証用の変種のマイルストーンは別の設定にあり、本番向けの段階以上`() {
        // 2026-10-05 ユーザー判断（タスク 14）：検証用（emulator・demo- のプロジェクト）だけ先に M2 にした。2026-10-09 に本番向けも M2 にした。
        // 本番向けの値（上の soramoyou.milestone）に検証用の値が混ざらないことは、BuildConfig との一致のテストが確かめる
        val properties = Properties().apply { gradleProperties.reader(Charsets.UTF_8).use { load(it) } }
        val emulator = assertNotNull(properties.getProperty("soramoyou.emulatorMilestone"), "gradle.properties に soramoyou.emulatorMilestone が無い")
        assertTrue(
            Milestone.valueOf(emulator) >= Milestone.valueOf(configuredMilestone()),
            "検証用の変種のマイルストーン（$emulator）が本番向け（${configuredMilestone()}）より低い",
        )
    }

    @Test
    fun `今のマイルストーンはM6で、M4までの書き込みに加えて通報・ブロック・フィードバック・退会の書き込みが有効`() {
        // 2026-10-09 ユーザー判断：11.3 の完了後に本番向けも M2 に上げる（M1 の書き込みゼロ保証は 11.2 で確認済み）。
        // 同日、タスク 18.2（いいねの書き込み）で M3 に、タスク 21.1（投稿の導線）で M4 に上げた。
        // タスク 29.1（通報・ブロックの書き込み）で M5 に上げた：通報・ブロック・フィードバック・退会の 4 つの書き込みが有効になる
        // （導線は 29.2・30・31.x で足すので、29.1 の時点では導線の無い書き込みの入口だけが開く）。
        // タスク 34.1（リリースビルド）で M6 に上げた：書き込みの集合は M5 と同じ（設計書「マイルストーンと有効化の範囲」）。
        // 期待する集合は表（writeCapabilitiesOf）を使わず書き下す（表が変わったら、ここで気づけるように）。
        // マイルストーンを上げるタスクで、このテストも意識して書き換える
        val expected = setOf(
            WriteCapability.ACCOUNT_CREATE,
            WriteCapability.ACCOUNT_REPAIR,
            WriteCapability.PROFILE_EDIT,
            WriteCapability.LIKE,
            WriteCapability.POST_CREATE,
            WriteCapability.POSTS_COUNT_SYNC,
            WriteCapability.POST_DELETE,
            WriteCapability.REPORT,
            WriteCapability.BLOCK,
            WriteCapability.FEEDBACK,
            WriteCapability.ACCOUNT_DELETE,
        )
        assertEquals(Milestone.M6, BuildConfigWriteGate.milestone)
        assertEquals(expected, BuildConfigWriteGate.enabled)
        for (capability in WriteCapability.entries) {
            assertEquals(capability in expected, BuildConfigWriteGate.isEnabled(capability), "M6 での $capability の可否が違う")
        }
    }
}
