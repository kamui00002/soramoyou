// ⭐️ バナー広告の枠の状態遷移（タスク 32.2・要件 14.1・14.4・14.5。設計書の部品 BannerAdSlot の、描画を除いた部分）
package com.yoshidometoru.soramoyou.feature.ads

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** 1 回の広告の読み込みの結果。 */
sealed interface BannerLoad {
    /** 結果がまだ届いていない。 */
    data object Pending : BannerLoad

    /** 広告を読み込めた。広告は広告 SDK の View が自分で描く。 */
    data object Loaded : BannerLoad

    /** 読み込めなかった（理由は [reason]。枠を畳む）。 */
    data class Failed(val reason: String) : BannerLoad
}

/** バナーの枠の状態。 */
enum class BannerSlotState {
    /** 枠を持たない（高さ 0）。読み込みに失敗した（画面から外れたときも含む）。広告の準備ができていないときは、枠ごと描かない。 */
    COLLAPSED,

    /** 広告の読み込み中。読み込めたときに本文が押し下げられないよう、枠の高さだけ先に確保する。 */
    LOADING,

    /** 広告を載せている。 */
    SHOWN,
}

/**
 * 広告の準備ができた後の [load]（読み込みの結果）から、枠の状態を決める。
 * 読み込み中は枠を確保し、読み込めたら載せ、読み込めなかったら畳む（要件 14.4：畳むだけで、他の操作は妨げない）。
 *
 * 広告の準備ができるまで（同意の取得・初期化・失敗・このビルドでは出さない）は、ここへは来ない。
 * 呼び出し側の BannerAdSlot が、広告の準備の状態が Ready でなければ枠ごと描かない（広告 SDK にも触れない）ため。
 */
fun bannerSlotStateOf(load: BannerLoad): BannerSlotState = when (load) {
    BannerLoad.Pending -> BannerSlotState.LOADING
    BannerLoad.Loaded -> BannerSlotState.SHOWN
    is BannerLoad.Failed -> BannerSlotState.COLLAPSED
}

/**
 * 枠の高さ（px）。[adHeightPx] は広告の規格の高さを、広告 SDK が px に直した値（標準バナー 320x50 の 50dp を、
 * AdSize の getHeightInPixels で切り上げた px。画面密度 2.625 の端末なら 131.25 を切り上げて 132）。
 *
 * px で受けるのは、広告 SDK が求める高さと 1px もずれないようにするため。dp の 50 のまま Compose に渡すと、Compose は
 * 四捨五入で px に直す（131.25 なら 131）ので、広告 SDK から見ると 49.9dp しか無く「Not enough space to show the full ad」になる
 * （タスク 34 の Logcat の 411x49dp。2026-11-08 に原因を確かめた）。
 *
 * 高さは広告の規格だけで決まり、端末の文字の大きさ（fontScale）には依らない。文字を大きくしても枠は伸び縮みせず、
 * 本文の領域が縮むだけなので、広告と主要な操作ボタンは重ならない（要件 16.6）。
 * [imeVisible]（キーボードが出ている）あいだは 0 にして隠す。入力欄のある画面で、広告が入力の邪魔にならないようにするため。
 * 広告そのものは捨てず、閉じたら元の高さに戻す（広告を要求し直さない）。
 */
fun bannerFrameHeightPx(slot: BannerSlotState, adHeightPx: Int, imeVisible: Boolean): Int = when {
    imeVisible -> 0
    slot == BannerSlotState.COLLAPSED -> 0
    else -> adHeightPx.coerceAtLeast(0)
}

/**
 * 1 つの枠の広告の View（本物は広告 SDK の AdView）と、その読み込みの結果を持つ。
 * View は枠を作るときに先に作り、読み込みの要求は [start] に渡す（本物は BannerAdSlot）。結果は [load] に流す。
 *
 * - 最初の結果だけを採る。成功の後の失敗も、失敗の後の成功も無視する
 * - [dispose]（画面から外れた）で View を 1 回だけ破棄する。読み込みは非同期なので、外れた後に結果が届きうるが、それは無視する
 *   （破棄した View への結果で、状態を変えない・失敗を記録しない）
 * - 失敗（読み込みの失敗・要求の例外・破棄の例外）は外へ投げず、[reportFailure] に渡して枠を畳むだけにする（要件 14.4）。
 *   差し込み口自体の失敗も外へ出さない
 *
 * 結果は広告 SDK のスレッドから届くことがあるので、状態の更新は [lock] で守る。破棄・記録は、ロックの外で行う。
 *
 * @param view 広告の View。
 * @param destroy View の破棄（本物は AdView.destroy）。
 * @param reportFailure 失敗の理由を Logcat などへ出す差し込み口。既定は何もしない（JVM の単体テストでは Log を使えないため）。
 */
class BannerLoadTracker<ViewT : Any>(
    val view: ViewT,
    private val destroy: (ViewT) -> Unit,
    private val reportFailure: (String) -> Unit = {},
) {
    private val lock = Any()
    private var disposed = false
    private val mutableLoad = MutableStateFlow<BannerLoad>(BannerLoad.Pending)

    /** 読み込みの結果。届くまでは [BannerLoad.Pending]。 */
    val load: StateFlow<BannerLoad> = mutableLoad.asStateFlow()

    /**
     * 読み込みを始める。[requestLoad] には [view] と、結果の受け口（成功・失敗）を渡す。要求が例外を投げたら、失敗として扱う。
     */
    fun start(requestLoad: (view: ViewT, onLoaded: () -> Unit, onFailed: (String) -> Unit) -> Unit) {
        try {
            requestLoad(view, { onLoaded() }, { onFailed(it) })
        } catch (e: Exception) {
            onFailed("読み込みの要求が例外を投げた: ${e.javaClass.simpleName}")
        }
    }

    /** 広告を読み込めた。待機中のときだけ採る（最初の結果だけ。[dispose] の後は待機中でないので、外れた後に届いた結果も採らない）。 */
    fun onLoaded() {
        synchronized(lock) {
            if (mutableLoad.value is BannerLoad.Pending) mutableLoad.value = BannerLoad.Loaded
        }
    }

    /** 読み込めなかった。待機中のときだけ採り、記録する（[onLoaded] と同じく、外れた後に届いた失敗は記録しない）。 */
    fun onFailed(reason: String) {
        val accepted = synchronized(lock) {
            if (mutableLoad.value !is BannerLoad.Pending) {
                false
            } else {
                mutableLoad.value = BannerLoad.Failed(reason)
                true
            }
        }
        if (accepted) reportQuietly(reason)
    }

    /** 画面から外れた。View を破棄する（2 回目以降は何もしない）。 */
    fun dispose() {
        synchronized(lock) {
            if (disposed) return
            disposed = true
            // 破棄した View を、観察している側が表示し続けないよう、載せない状態に変える。
            // 待機中でなくなるので、この後に届いた結果は [onLoaded]・[onFailed] が採らない
            mutableLoad.value = BannerLoad.Failed("画面から外れた")
        }
        try {
            destroy(view)
        } catch (e: Exception) {
            reportQuietly("広告の破棄に失敗した: ${e.javaClass.simpleName}")
        }
    }

    private fun reportQuietly(reason: String) {
        try {
            reportFailure(reason)
        } catch (ignored: Exception) {
            // 失敗の報告の失敗は、どこにも出しようがないので捨てる（枠を畳むことは状態で表している）
        }
    }
}
