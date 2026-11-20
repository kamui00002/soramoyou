// ⭐️☁️ 同意の取得と、広告 SDK の初期化（タスク 32.1・要件 14.1〜14.3。設計書の部品 AdsController）
package com.yoshidometoru.soramoyou.platform

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 広告の準備の状態。バナーの枠（タスク 32.2）は [Ready] のときだけ広告を読み込む。 */
sealed interface AdsState {
    /** まだ始めていない（[AdsController.start] の前）。 */
    data object NotStarted : AdsState

    /** このビルドでは広告を出さない（マイルストーンが M5 より前。[adsEnabledAt]）。 */
    data object Disabled : AdsState

    /** 同意の情報を更新し、必要なら同意のフォームを表示している。 */
    data object GatheringConsent : AdsState

    /** 広告 SDK を背景のスレッドで初期化している。 */
    data object Initializing : AdsState

    /** 広告を読み込める。[bannerUnitId] はこのビルドのバナーの広告ユニット ID。 */
    data class Ready(val bannerUnitId: String) : AdsState

    /** 広告を出さない（理由は [reason]）。他の操作は妨げない（要件 14.4）。 */
    data class Unavailable(val reason: AdsUnavailableReason) : AdsState
}

/** 広告を出さない理由。 */
enum class AdsUnavailableReason {
    /** ID がビルドの種類に合っていない（本番トラック用のビルドで本番の ID が未設定など。[adsConfigProblem]）。 */
    MISCONFIGURED,

    /** 同意の取得の後、UMP が「広告を要求してよい」と答えなかった。 */
    CANNOT_REQUEST_ADS,

    /** 広告 SDK の初期化が失敗した。 */
    INITIALIZATION_FAILED,
}

/** UMP の 1 つの段の結果。 */
sealed interface ConsentStepResult {
    /** 段が終わった（フォームが不要だった・閉じられた場合を含む）。 */
    data object Completed : ConsentStepResult

    /** 段が失敗した（UMP の FormError の番号と文）。 */
    data class Failed(val code: Int, val message: String) : ConsentStepResult
}

/**
 * 同意の取得（UMP）の窓口。本物は [UmpConsentGateway]（Activity が要るので、画面の起動のたびに作る）。
 * 呼ぶのは main スレッドから（UMP の API は main で呼ぶ前提。[DefaultAdsController] は渡されたスコープ＝本番は main で呼ぶ）。
 */
interface ConsentGateway {
    /** 同意の情報を更新する（UMP の requestConsentInfoUpdate。起動のたびに呼ぶ）。 */
    suspend fun requestConsentInfoUpdate(): ConsentStepResult

    /** 同意が必要ならフォームを読み込んで表示し、閉じられるまで待つ（UMP の loadAndShowConsentFormIfRequired）。 */
    suspend fun loadAndShowConsentFormIfRequired(): ConsentStepResult

    /** 広告を要求してよいか（UMP の canRequestAds。前回の起動で得た同意も含む）。 */
    fun canRequestAds(): Boolean
}

/**
 * 広告 SDK の初期化の窓口。本物は [GmaMobileAdsInitializer]。
 * [initialize] は終わるまで戻らない呼び出しで、main 以外のスレッドで呼ぶ（main で呼ぶと ANR になりうる）。
 */
fun interface MobileAdsInitializer {
    fun initialize(appId: String)
}

/** 同意の取得と広告 SDK の初期化を受け持つ（設計書の部品 AdsController）。アプリ全体で 1 つ（AppContainer）。 */
interface AdsController {
    /** 広告の準備の状態。 */
    val state: StateFlow<AdsState>

    /**
     * 同意の取得と初期化を始める。画面（MainActivity）の起動のたびに呼んでよい。
     * 受け付けるのは、まだ始めていないとき（初回）と、前回が「広告を要求してよいと答えなかった」で終わったとき
     * （[AdsUnavailableReason.CANNOT_REQUEST_ADS]）だけで、そのときは渡された [consent] で同意の情報の更新からやり直す。
     * それ以外（取得中・初期化中・準備完了・設定の誤り・初期化の失敗・無効なビルド）では何もしない。
     * 失敗は外へ出さない（広告が出ないだけで、他の操作は妨げない：要件 14.4）。
     */
    fun start(consent: ConsentGateway)
}

/**
 * [AdsController] の実装。順序は設計書の部品 AdsController と UMP の公式の手順
 * （developers.google.com/admob/android/next-gen/privacy・2026-10-13 に確認）に従う。
 *
 * 1. 同意の情報を更新する（起動のたびに）
 * 2. 更新に成功したときだけ、必要なら同意のフォームを表示し、閉じられるまで待つ
 * 3. 広告を要求してよいかを UMP に聞く。更新やフォームに失敗しても聞く（前回の起動で得た同意が使えるため：公式「If an error occurs …」）
 * 4. 要求してよいときだけ、広告 SDK を背景のスレッドで初期化する（main で呼ぶと ANR になりうる：next-gen/quick-start）
 *
 * - 公式のサンプルは、1. を呼んだ直後にも前回の同意で初期化を始める近道を持つ。ここでは設計書の順（更新→フォーム→初期化）に揃え、
 *   近道は持たない（初期化の口が 1 つなので、二重に初期化する心配が無い）。広告が出始めるのが、同意の更新の分だけ遅れうる
 * - 失敗（UMP の段の失敗・例外、初期化の例外）は外へ出さず、[reportFailure] に「どこで」の名前と例外を渡して、広告を出さないだけにする
 *   （本番のスコープの例外はアプリを落とすため。要件 14.4）。分析のイベントは送らない（iOS 版にも広告のイベントは無い）
 * - [start] を受け付けるのは、状態が [AdsState.NotStarted]（初回）か [AdsState.Unavailable]（[AdsUnavailableReason.CANNOT_REQUEST_ADS]）のときだけ。
 *   画面の回転などで MainActivity が作り直されて [start] がまた呼ばれても、取得中・初期化中・準備完了・設定の誤り・初期化の失敗なら何もしない。
 *   CANNOT_REQUEST_ADS からのやり直しは、インストール直後にオフラインで開いて同意の情報の更新に失敗し、広告を要求してよいと答えなかった後で、
 *   接続が戻ってから画面を開き直したときに広告が出るようにするため（UMP が初期状態でそう答えるのは推定で、公式文書では確かめていない）。
 *   広告 SDK の初期化はこの経路を通る 1 回だけ（初期化に進むと状態が取得中でなくなり、準備完了か初期化の失敗で終わるので、再び受け付けない）
 *
 * @param config ビルドに焼き込んだ広告の設定。種類に合っていなければ（[adsConfigProblem]）同意の取得も初期化も行わない。
 * @param enabled このビルドで広告を出すか（[adsEnabledAt]）。false なら最初から [AdsState.Disabled] で、[start] は何もしない。
 * @param sdk 広告 SDK の初期化（本物は [GmaMobileAdsInitializer]）。
 * @param scope 同意の段を行うスコープ。UMP は main で呼ぶ前提なので、本番は main のスコープ（AppContainer）。
 * @param background 初期化を行うディスパッチャ（本番は Dispatchers.IO）。
 * @param reportFailure 握りつぶした失敗を Logcat などへ出す差し込み口。既定は何もしない（JVM の単体テストでは Log を使えないため）。
 */
class DefaultAdsController(
    private val config: AdsConfig,
    private val enabled: Boolean,
    private val sdk: MobileAdsInitializer,
    private val scope: CoroutineScope,
    private val background: CoroutineDispatcher,
    private val reportFailure: (String, Exception) -> Unit = { _, _ -> },
) : AdsController {

    private val mutableState = MutableStateFlow<AdsState>(if (enabled) AdsState.NotStarted else AdsState.Disabled)
    override val state: StateFlow<AdsState> = mutableState.asStateFlow()

    override fun start(consent: ConsentGateway) {
        if (!enabled) return
        val problem = adsConfigProblem(config)
        if (problem != null) {
            // 設定は変わらないので、やり直しは受け付けない（初回だけ記録して、設定の誤りの状態にする）
            if (mutableState.compareAndSet(AdsState.NotStarted, AdsState.Unavailable(AdsUnavailableReason.MISCONFIGURED))) {
                report("AdsConfig", AdsSetupException(problem))
            }
            return
        }
        if (!acceptStart()) return
        scope.launch { gatherConsentAndInitialize(consent) }
    }

    /**
     * [start] を受け付けるかを決め、受け付けるなら状態を取得中にする。判定と状態の変更は 1 回の compareAndSet なので、
     * 画面の作り直しで [start] が重なっても、同意の取得を始められるのは 1 つだけ。
     * 受け付けるのは未開始か、前回が [AdsUnavailableReason.CANNOT_REQUEST_ADS] で終わったとき（[AdsState.Unavailable] は data class なので値で比べられる）。
     */
    private fun acceptStart(): Boolean =
        mutableState.compareAndSet(AdsState.NotStarted, AdsState.GatheringConsent) ||
            mutableState.compareAndSet(AdsState.Unavailable(AdsUnavailableReason.CANNOT_REQUEST_ADS), AdsState.GatheringConsent)

    private suspend fun gatherConsentAndInitialize(consent: ConsentGateway) {
        // 1・2. 同意の情報の更新と、（更新に成功したら）必要なときの同意のフォーム
        val update = consentStep("UMP.requestConsentInfoUpdate") { consent.requestConsentInfoUpdate() }
        if (update == ConsentStepResult.Completed) {
            consentStep("UMP.loadAndShowConsentFormIfRequired") { consent.loadAndShowConsentFormIfRequired() }
        }

        // 3. 広告を要求してよいか。分からない（例外）ときは要求しない
        val canRequestAds = try {
            consent.canRequestAds()
        } catch (e: Exception) {
            report("UMP.canRequestAds", e)
            false
        }
        if (!canRequestAds) {
            mutableState.value = AdsState.Unavailable(AdsUnavailableReason.CANNOT_REQUEST_ADS)
            return
        }

        // 4. 背景のスレッドで初期化する（呼び出しは初期化が終わるまで戻らない）
        mutableState.value = AdsState.Initializing
        mutableState.value = try {
            withContext(background) { sdk.initialize(config.appId) }
            AdsState.Ready(config.bannerUnitId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            report("MobileAds.initialize", e)
            AdsState.Unavailable(AdsUnavailableReason.INITIALIZATION_FAILED)
        }
    }

    /** UMP の段を 1 つ行い、失敗（[ConsentStepResult.Failed] と例外）を記録する。例外は失敗の結果に変えて返す。 */
    private suspend fun consentStep(where: String, step: suspend () -> ConsentStepResult): ConsentStepResult {
        val result = try {
            step()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            report(where, e)
            return ConsentStepResult.Failed(code = -1, message = e.javaClass.simpleName)
        }
        if (result is ConsentStepResult.Failed) report(where, AdsSetupException("UMP の FormError code=${result.code}: ${result.message}"))
        return result
    }

    /** [reportFailure] に渡す。差し込み口自体の失敗も外へ出さない（[DefaultNetworkMonitor] と同じ）。 */
    private fun report(where: String, error: Exception) {
        try {
            reportFailure(where, error)
        } catch (ignored: Exception) {
            // 失敗の報告の失敗は、どこにも出しようがないので捨てる（広告を出さないことは状態で表している）
        }
    }
}

/** 広告の準備の失敗のうち、例外でないもの（設定の誤り・UMP の FormError）を [DefaultAdsController] の記録に渡すための例外。 */
private class AdsSetupException(message: String) : Exception(message)
