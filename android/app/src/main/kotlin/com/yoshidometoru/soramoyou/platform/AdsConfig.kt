// ⭐️☁️ 広告のアプリ ID・広告ユニット ID と、ビルドの種類の対応の検査（タスク 32.1・要件 14.2・14.3・設計書 Q9）
package com.yoshidometoru.soramoyou.platform

import com.yoshidometoru.soramoyou.data.remote.write.Milestone

/**
 * 広告を出すビルドの種類。app/build.gradle.kts が `BuildConfig.ADS_BUILD_KIND` に名前を焼き込む。
 * - [DEVELOPMENT]：debug ビルド（検証用の変種 emulator を含む）。Google のテスト用の広告
 * - [CLOSED_TEST]：クローズドテストのリリースビルド（gradle.properties の `soramoyou.adsTrack=CLOSED_TEST`）。Google のテスト用の広告
 * - [PRODUCTION_TRACK]：本番トラック用のリリースビルド（`soramoyou.adsTrack=PRODUCTION_TRACK`）。Android 用に新規発行した本番の広告
 */
enum class AdsBuildKind { DEVELOPMENT, CLOSED_TEST, PRODUCTION_TRACK }

/**
 * このビルドの広告の設定。値は app/build.gradle.kts がビルドの種類から選んで BuildConfig に焼き込んだもので、
 * アプリの側では選ばない（同じ値をマニフェストの UMP 用のアプリ ID にも流しているので、二か所で選ぶと食い違いうる）。
 *
 * @property kind ビルドの種類。BuildConfig の名前が [AdsBuildKind] のどれでもなければ null（ふつうは Gradle がビルドを止める）。
 * @property appId AdMob のアプリ ID（`ca-app-pub-…~…`）。SDK の初期化に渡す。
 * @property bannerUnitId バナーの広告ユニット ID（`ca-app-pub-…/…`）。バナーの枠（タスク 32.2）が使う。
 */
data class AdsConfig(val kind: AdsBuildKind?, val appId: String, val bannerUnitId: String) {
    companion object {
        /** BuildConfig の 3 つの値から作る。種類の名前が分からなくても例外にせず、[adsConfigProblem] で広告を止める。 */
        fun fromBuildConfig(kindName: String, appId: String, bannerUnitId: String): AdsConfig =
            AdsConfig(AdsBuildKind.entries.firstOrNull { it.name == kindName }, appId, bannerUnitId)
    }
}

/** Google が公表しているテスト用の ID（出典は app/build.gradle.kts の注記。どのアカウントにも紐づかない）。 */
object GoogleTestAdIds {
    /**
     * Google のテスト用の発行元（`ca-app-pub-<発行元の番号>`）。公表されているテスト用の ID は、アプリ ID も広告ユニット ID も
     * 全てこの発行元の下にある（next-gen/test-ads の表）。本番トラックでは、この発行元の ID を前置きで断る（[adsConfigProblem]）。
     */
    const val PUBLISHER = "ca-app-pub-3940256099942544"

    /** サンプルのアプリ ID（developers.google.com/admob/android/next-gen/quick-start）。 */
    const val APP_ID = "ca-app-pub-3940256099942544~3347511713"

    /**
     * Fixed Size Banner（固定サイズのバナー）のデモの広告ユニット（developers.google.com/admob/android/next-gen/test-ads の表・
     * 2026-10-14 に確認）。枠は標準バナー（320x50。AdSize.BANNER）で読み込むので、アダプティブのデモ（…/9214589741）でなく、これを使う。
     */
    const val BANNER_UNIT_ID = "ca-app-pub-3940256099942544/6300978111"
}

/** アプリ ID の形（`ca-app-pub-<発行元の番号>~<アプリの番号>`）。 */
private val APP_ID_PATTERN = Regex("""ca-app-pub-\d+~\d+""")

/** 広告ユニット ID の形（`ca-app-pub-<発行元の番号>/<ユニットの番号>`）。 */
private val AD_UNIT_ID_PATTERN = Regex("""ca-app-pub-\d+/\d+""")

/**
 * [config] の ID が、そのビルドの種類に合っているかを確かめる。合っていれば null、合っていなければ理由を返す（ID の値は含めない）。
 * 合っていない設定では、広告の同意も初期化も行わない（[DefaultAdsController]）。
 *
 * - 開発用・クローズドテスト：Google のテスト用の ID だけ（要件 14.3。テスターや開発者が押しても無効なトラフィックにならない）
 * - 本番トラック：形の正しい、テスト用でない ID。空（タスク 27 の前の未設定）とテスト用の ID は誤り。
 *   テスト用かどうかは、公表されたデモの 1 つとの完全一致でなく、Google のテスト用の発行元（[GoogleTestAdIds.PUBLISHER]）の
 *   前置き（アプリ ID は `~`、広告ユニット ID は `/` まで）で見る。デモの広告ユニットは形式ごとにいくつもあり、どれも形の検査を通るため
 *   （ふつうは app/build.gradle.kts が、本番の ID が未設定・テスト用の発行元のまま本番トラック用にするとビルドを止めるので、ここは二重の守り）
 *
 * iOS 版の ID と共用しないこと（要件 14.2）は、iOS のソースを読む単体テスト（AdsBuildConfigTest）で確かめる。
 * 実行時に iOS の ID を持たないのは、iOS の本番の ID を Android のバイナリに入れないため。
 */
fun adsConfigProblem(config: AdsConfig): String? = when (config.kind) {
    null -> "ビルドの種類が分からない（BuildConfig.ADS_BUILD_KIND が AdsBuildKind のどれでもない）"
    AdsBuildKind.DEVELOPMENT, AdsBuildKind.CLOSED_TEST ->
        if (config.appId == GoogleTestAdIds.APP_ID && config.bannerUnitId == GoogleTestAdIds.BANNER_UNIT_ID) {
            null
        } else {
            "${config.kind} のビルドが、Google のテスト用でない ID を持っている（開発用とクローズドテストはテスト用の広告だけを出す）"
        }
    AdsBuildKind.PRODUCTION_TRACK -> when {
        config.appId.isEmpty() || config.bannerUnitId.isEmpty() ->
            "本番トラック用のビルドなのに、本番の ID が未設定（タスク 27 で Android 用に発行し、gradle.properties に入れる）"
        !APP_ID_PATTERN.matches(config.appId) -> "本番のアプリ ID の形が違う（ca-app-pub-…~… の形でない）"
        !AD_UNIT_ID_PATTERN.matches(config.bannerUnitId) -> "本番の広告ユニット ID の形が違う（ca-app-pub-…/… の形でない）"
        config.appId.startsWith("${GoogleTestAdIds.PUBLISHER}~") ||
            config.bannerUnitId.startsWith("${GoogleTestAdIds.PUBLISHER}/") ->
            "本番トラック用のビルドが、Google のテスト用の発行元の ID を持っている（本番でテスト用の広告を出さない）"
        else -> null
    }
}

/**
 * マイルストーン [milestone] のビルドで広告を出すか。設計書「マイルストーンと有効化の範囲」の表で、広告は M5 の機能なので M5 以降。
 * それより前のビルド（いまの M4 など）では、同意の取得も SDK の初期化も行わない（書き込みのゲートと同じく、ビルド時に決まる）。
 */
fun adsEnabledAt(milestone: Milestone): Boolean = milestone >= Milestone.M5
