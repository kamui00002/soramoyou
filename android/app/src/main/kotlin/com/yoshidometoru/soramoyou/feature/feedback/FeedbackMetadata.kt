// ⭐️ フィードバックに自動で付ける、アプリのバージョンと端末の情報（タスク 30・要件 13.2・13.4）
package com.yoshidometoru.soramoyou.feature.feedback

import android.os.Build
import com.yoshidometoru.soramoyou.BuildConfig

/**
 * フィードバックに自動で付ける 2 つの文字列。どちらも調べるための情報で、メールアドレスと表示名は含めない（要件 13.4）。
 *
 * - アプリのバージョン：「バージョン名 (バージョンコード)」（iOS の「1.7.4 (57)」：FeedbackViewModel.swift:75-80）。
 *   報告の元になったビルドを特定するのに使う。値は `BuildConfig`（app/build.gradle.kts に実際の値で 1 回だけ書いたもの）から読む
 * - 端末情報：「Android {OSの版} / {機種名}」（iOS の「iOS 18.5 / iPhone」：同 :82-84）。`Build.VERSION.RELEASE`（例 `14`）と
 *   `Build.MODEL`（例 `Pixel 8`）
 *
 * 読めない項目（空・空白だけ）は「?」にする（iOS が版数を読めないとき `?` にするのと同じ）。
 * 形そのものは [appVersion]・[deviceInfo] で作り、単体テストで確かめる（`Build` の値は JVM の単体テストでは入らないため）。
 */
object FeedbackMetadata {

    /** 読めない項目の代わりに出す文字。 */
    private const val UNKNOWN = "?"

    /** 「バージョン名 (バージョンコード)」の形のアプリのバージョン。[versionName] が空か空白だけなら「?」。 */
    fun appVersion(versionName: String?, versionCode: Int): String = "${versionName.orUnknown()} ($versionCode)"

    /** 「Android {OSの版} / {機種名}」の形の端末情報。[release]・[model] が空か空白だけなら、その項目を「?」にする。 */
    fun deviceInfo(release: String?, model: String?): String = "Android ${release.orUnknown()} / ${model.orUnknown()}"

    /** このビルドのアプリのバージョン。 */
    fun currentAppVersion(): String = appVersion(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE)

    /** この端末の情報。 */
    fun currentDeviceInfo(): String = deviceInfo(Build.VERSION.RELEASE, Build.MODEL)

    private fun String?.orUnknown(): String = this?.takeIf { it.isNotBlank() } ?: UNKNOWN
}
