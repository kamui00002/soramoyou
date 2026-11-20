// ⭐️ 広告の ID とビルドの種類の対応の検査の単体テスト（タスク 32.1・要件 14.2・14.3）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.data.remote.write.Milestone
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * [adsConfigProblem] の表：
 * - 開発用（DEVELOPMENT）とクローズドテスト（CLOSED_TEST）は、Google のテスト用の ID だけを受け入れる（要件 14.3）
 * - 本番トラック（PRODUCTION_TRACK）は、テスト用でない、形の正しい ID だけを受け入れる（未設定の空・テスト用の ID は誤り）
 * - 種類が分からない（BuildConfig の名前が [AdsBuildKind] のどれでもない）設定は誤り
 *
 * 本番の ID の例は、形だけを合わせた架空の値（どのアカウントのものでもない）。
 */
class AdsConfigTest {

    /** 形の正しい、テスト用でない ID（架空）。 */
    private val someAppId = "ca-app-pub-1111111111111111~2222222222"
    private val someBannerUnitId = "ca-app-pub-1111111111111111/3333333333"

    private fun problem(kind: AdsBuildKind?, appId: String, bannerUnitId: String) =
        adsConfigProblem(AdsConfig(kind, appId, bannerUnitId))

    @Test
    fun `Googleのテスト用のIDは公表されている値である`() {
        // 出典：developers.google.com/admob/android/next-gen/quick-start（サンプルのアプリ ID）・next-gen/test-ads（Fixed Size Banner。
        // 枠が標準バナー 320x50 なので、固定サイズのデモ）。定数を書き換えたらここで気づけるよう、表を使わず書き下す
        assertEquals("ca-app-pub-3940256099942544~3347511713", GoogleTestAdIds.APP_ID)
        assertEquals("ca-app-pub-3940256099942544/6300978111", GoogleTestAdIds.BANNER_UNIT_ID)
    }

    @Test
    fun `開発用とクローズドテストは、Googleのテスト用のIDを受け入れる`() {
        for (kind in listOf(AdsBuildKind.DEVELOPMENT, AdsBuildKind.CLOSED_TEST)) {
            assertNull(problem(kind, GoogleTestAdIds.APP_ID, GoogleTestAdIds.BANNER_UNIT_ID), "$kind でテスト用の ID を誤りとした")
        }
    }

    @Test
    fun `開発用とクローズドテストは、テスト用でないIDを誤りとする（本番の広告を出さない）`() {
        for (kind in listOf(AdsBuildKind.DEVELOPMENT, AdsBuildKind.CLOSED_TEST)) {
            assertNotNull(problem(kind, someAppId, GoogleTestAdIds.BANNER_UNIT_ID), "$kind でテスト用でないアプリ ID を受け入れた")
            assertNotNull(problem(kind, GoogleTestAdIds.APP_ID, someBannerUnitId), "$kind でテスト用でない広告ユニットを受け入れた")
        }
    }

    @Test
    fun `本番トラックは、テスト用でない形の正しいIDを受け入れる`() {
        assertNull(problem(AdsBuildKind.PRODUCTION_TRACK, someAppId, someBannerUnitId))
    }

    @Test
    fun `本番トラックは、未設定（空）のIDを誤りとする`() {
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, "", ""))
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, someAppId, ""))
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, "", someBannerUnitId))
    }

    @Test
    fun `本番トラックは、Googleのテスト用のIDを誤りとする（本番でテスト用の広告を出さない）`() {
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, GoogleTestAdIds.APP_ID, someBannerUnitId))
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, someAppId, GoogleTestAdIds.BANNER_UNIT_ID))
    }

    @Test
    fun `本番トラックは、Googleのテスト用の発行元のIDを、定数と違うデモでも誤りとする（完全一致でなく前置きで断る）`() {
        // 公式の表（next-gen/test-ads・2026-10-14 に確認）のデモの広告ユニット。どれも広告ユニット ID の形の検査は通る。
        // 固定サイズのバナーのデモはいまの定数そのもの。アダプティブのバナーとインタースティシャルのデモは定数と違う番号なので、
        // 定数との完全一致だけを見る検査では通ってしまう（陽性対照：前置きの検査を完全一致に戻すと、この 2 つが受け入れた一覧に出て赤になる）。
        // 1 つ目の誤りで止めず全ての値を確かめるため、受け入れてしまった値を集めてから比べる
        val demoBannerUnits = listOf(
            "ca-app-pub-3940256099942544/6300978111", // Fixed Size Banner（固定サイズのバナー）
            "ca-app-pub-3940256099942544/9214589741", // Anchored / Inline Adaptive Banner（アダプティブのバナー）
            "ca-app-pub-3940256099942544/1033173712", // Interstitial（インタースティシャル）
        )
        val acceptedUnits = demoBannerUnits.filter { unitId -> problem(AdsBuildKind.PRODUCTION_TRACK, someAppId, unitId) == null }
        assertEquals(emptyList(), acceptedUnits, "本番トラックでテスト用の発行元の広告ユニットを受け入れた")
        // アプリ ID も同じ。発行元だけがテスト用の、架空のアプリ番号
        val testPublisherAppId = "ca-app-pub-3940256099942544~1111111111"
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, testPublisherAppId, someBannerUnitId), "本番トラックでテスト用の発行元のアプリ ID を受け入れた")
    }

    @Test
    fun `本番トラックで断るのはテスト用の発行元そのものだけで、番号が続く別の発行元は断らない`() {
        // 前置きは区切り（~ と /）まで見るので、発行元の番号の頭がたまたま同じ別の発行元は、テスト用として扱わない
        assertNull(problem(AdsBuildKind.PRODUCTION_TRACK, "ca-app-pub-39402560999425441~2222222222", "ca-app-pub-39402560999425441/3333333333"))
    }

    @Test
    fun `アプリIDと広告ユニットIDの区切りを取り違えた値を誤りとする`() {
        // アプリ ID は「~」、広告ユニット ID は「/」で区切る。取り違えると SDK が受け付けない
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, someBannerUnitId, someAppId))
        assertNotNull(problem(AdsBuildKind.PRODUCTION_TRACK, "ca-app-pub-1111111111111111", someBannerUnitId))
    }

    @Test
    fun `種類が分からない設定は誤りとする`() {
        assertNotNull(problem(null, GoogleTestAdIds.APP_ID, GoogleTestAdIds.BANNER_UNIT_ID))
    }

    @Test
    fun `誤りの理由にIDの値を含めない`() {
        val message = assertNotNull(problem(AdsBuildKind.DEVELOPMENT, someAppId, someBannerUnitId))
        assertFalse(someAppId in message || someBannerUnitId in message, "理由に ID の値が入っている")
    }

    @Test
    fun `BuildConfigの名前から種類を読み、知らない名前は種類なしにする`() {
        assertEquals(
            AdsConfig(AdsBuildKind.CLOSED_TEST, "a", "b"),
            AdsConfig.fromBuildConfig("CLOSED_TEST", "a", "b"),
        )
        AdsBuildKind.entries.forEach { assertEquals(it, AdsConfig.fromBuildConfig(it.name, "a", "b").kind) }
        assertNull(AdsConfig.fromBuildConfig("RELEASE", "a", "b").kind)
    }

    @Test
    fun `広告を出すのはマイルストーンM5以降（設計書の表で、広告はM5の機能）`() {
        assertEquals(
            mapOf(
                Milestone.M1 to false,
                Milestone.M2 to false,
                Milestone.M3 to false,
                Milestone.M4 to false,
                Milestone.M5 to true,
                Milestone.M6 to true,
            ),
            Milestone.entries.associateWith { adsEnabledAt(it) },
        )
    }
}
