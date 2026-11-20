// ⭐️☁️ 画面下部のバナー広告の枠（タスク 32.2・要件 14.1・14.4・14.5・16.6。設計書の部品 BannerAdSlot）
package com.yoshidometoru.soramoyou.feature.ads

import android.app.Activity
import android.util.Log
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.google.android.libraries.ads.mobile.sdk.banner.AdSize
import com.google.android.libraries.ads.mobile.sdk.banner.AdView
import com.google.android.libraries.ads.mobile.sdk.banner.BannerAd
import com.google.android.libraries.ads.mobile.sdk.banner.BannerAdRequest
import com.google.android.libraries.ads.mobile.sdk.common.AdLoadCallback
import com.google.android.libraries.ads.mobile.sdk.common.LoadAdError
import com.yoshidometoru.soramoyou.LOG_TAG
import com.yoshidometoru.soramoyou.platform.AdsController
import com.yoshidometoru.soramoyou.platform.AdsState

/**
 * 画面の下端に固定する、バナー広告の枠。いちばん外側の Scaffold の bottomBar に置く（SoramoyouApp）。
 * 出さない行き先（設定の画面など）は、SoramoyouApp.kt の ROUTES_WITHOUT_BANNER の 1 か所で決める。
 * Scaffold が枠の高さの分だけ本文の領域を縮めるので、投稿の画像や操作ボタンには重ならない（要件 14.5）。
 * 本文の側には広告を重ねる経路が無く、文字を大きくしても本文が伸びるだけで、枠の高さは変わらない（要件 16.6）。
 *
 * - 広告の準備（同意の取得と SDK の初期化。[AdsController]）ができるまでは何も描かず、広告 SDK にも触れない
 * - 準備ができたら、枠の高さを先に確保して読み込む。読み込めたら広告を載せ、失敗したら枠を畳む（要件 14.4）。
 *   失敗は Logcat に出すだけで、他の操作は妨げない。枠が画面にあるあいだは自動では再試行しない（広告の要求を重ねない）。
 *   ただし出さない行き先（設定など）へ移ると枠ごと捨てられるので、戻るたびに枠を作り直して要求し直す（失敗で畳んだ後も。
 *   往復の回数だけ要求が出ることは 2026-10-14 ユーザー判断で受け入れた。回数は端末の Logcat で確かめる・33.2）
 * - 広告の大きさは、iOS 版と同じ標準バナー（320x50。iOS の AdSizeBanner）。高さが固定なので、読み込みの前後で枠が動かない。
 *   枠の高さは、広告 SDK が求める px ちょうどにする（Compose の dp の丸めで 1px 欠けないように。[bannerFrameHeightPx]）
 * - キーボードが出ているあいだは枠を隠す（入力欄のある画面で、広告が入力の邪魔にならないように。広告は捨てず、閉じたら戻す）
 *
 * 広告の View の作り方・読み込み・破棄は、広告 SDK の公式の手順（developers.google.com/admob/android/next-gen/banner の
 * Compose の例・2026-10-13 に確認）に従う。SDK 1.5.0 で非推奨の BannerAd.load・getView・アダプティブバナーの大きさの関数は使わない。
 *
 * ボトムナビゲーションは、いまの画面にまだ無い（フィードの注記）。できたら、この枠はその上へ移す。
 * 単体テストの対象外（広告 SDK の View を載せるため）。状態の遷移は [bannerSlotStateOf]・[BannerLoadTracker] が持ち、
 * 置き方は BannerAdSlotPlacementTest が検査する。見え方は端末で確かめる。
 */
@Composable
fun BannerAdSlot(adsController: AdsController, modifier: Modifier = Modifier) {
    val ads by adsController.state.collectAsStateWithLifecycle()
    val ready = ads as? AdsState.Ready ?: return
    // 広告の View は Activity を要る。取れなければ枠を持たない
    val activity = LocalActivity.current ?: return
    ReadyBannerSlot(ready = ready, activity = activity, modifier = modifier)
}

/** 広告の準備ができたときの枠。[ready] のバナーの広告ユニット ID で、枠が画面にあるあいだ 1 回だけ読み込む。 */
@Composable
private fun ReadyBannerSlot(ready: AdsState.Ready, activity: Activity, modifier: Modifier) {
    // 広告ユニット ID が変わったら作り直す（古い方は dispose で破棄する）
    val tracker = remember(ready.bannerUnitId, activity) {
        BannerLoadTracker(
            view = AdView(activity),
            destroy = { it.destroy() },
            reportFailure = { Log.w(LOG_TAG, "バナー広告を出さない: $it") },
        )
    }
    DisposableEffect(tracker) {
        tracker.start { view, onLoaded, onFailed ->
            view.loadAd(
                BannerAdRequest.Builder(ready.bannerUnitId, BANNER_SIZE).build(),
                object : AdLoadCallback<BannerAd> {
                    override fun onAdLoaded(ad: BannerAd) = onLoaded()

                    override fun onAdFailedToLoad(adError: LoadAdError) =
                        onFailed("読み込みに失敗した: ${adError.code} ${adError.message}")
                },
            )
        }
        onDispose { tracker.dispose() }
    }

    val load by tracker.load.collectAsStateWithLifecycle()
    val slot = bannerSlotStateOf(load)
    // 枠の高さは、広告 SDK が求める px（AdSize の getHeightInPixels。dp を切り上げて px にする）で決めてから dp に戻す。
    // dp の規格のまま渡すと Compose が四捨五入で px にするので、密度によっては 1px 足りず、広告 SDK が足りないと言う
    // （画面密度 2.625 で 131.25px→131px。広告 SDK は 132px を求める。2026-11-08・タスク 32.2）。
    // px→dp→px は四捨五入で同じ px に戻るので、枠は広告 SDK の px ちょうどになる
    val frameHeightPx = bannerFrameHeightPx(slot, BANNER_SIZE.getHeightInPixels(activity), rememberImeVisible())
    val frameHeight = with(LocalDensity.current) { frameHeightPx.toDp() }
    // 枠は端末のナビゲーションバーの上に置く（エッジ・トゥ・エッジの画面なので、自分で避ける）。
    // 枠の外へは描かない（広告が本文へはみ出さない）。高さは広告の規格で、文字の大きさには依らない
    Box(
        modifier = modifier.fillMaxWidth().navigationBarsPadding().height(frameHeight).clipToBounds(),
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(factory = { tracker.view }, modifier = Modifier.wrapContentSize())
    }
}

/** 広告の大きさ。iOS 版と同じ標準バナー（320x50）。 */
private val BANNER_SIZE = AdSize.BANNER

/** キーボード（IME）が出ているか。出入りのときだけ描き直す（アニメーション中の毎フレームは描き直さない）。 */
@Composable
private fun rememberImeVisible(): Boolean {
    val ime = WindowInsets.ime
    val density = LocalDensity.current
    val visible by remember(ime, density) { derivedStateOf { ime.getBottom(density) > 0 } }
    return visible
}
