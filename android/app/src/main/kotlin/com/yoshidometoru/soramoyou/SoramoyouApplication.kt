// ⭐️ アプリの起動の入口：依存の組み立てと、接続先の Firebase プロジェクトの確認（タスク 5.1・要件 1.2）
package com.yoshidometoru.soramoyou

import android.app.Application
import android.util.Log
import com.yoshidometoru.soramoyou.di.AppContainer
import com.yoshidometoru.soramoyou.di.FirebaseProjectCheck

/** アプリが Logcat に出すときのタグ（[SoramoyouApplication] と [AppContainer] で共用）。 */
internal const val LOG_TAG = "Soramoyou"

/**
 * アプリの Application。起動時に 1 回だけ [AppContainer] を作り、接続先の Firebase プロジェクトを Logcat に出す。
 * マニフェストの `<application android:name>` でこのクラスを指定している（ApplicationClassManifestTest で固定）。
 *
 * 画面（Activity・ViewModel）は、`(application as SoramoyouApplication).container` から依存を受け取る。
 */
class SoramoyouApplication : Application() {

    /** アプリ全体の依存。[onCreate] で作る（Application の Context が使えるのは onCreate から）。 */
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
        logFirebaseProject(container.firebaseProjectId)
    }

    /**
     * 接続先のプロジェクトが本番（soramoyou-ios）かを、起動のたびに Logcat に出す（要件 1.2。端末での確認はタスク 11.3）。
     * 本番でなくても止めない。ここで分かるのは設定ファイルの取り違えで、直すのは開発者の作業のため、見える形で知らせるだけにする。
     * 本番のときも警告（Log.w）で出す。リリースの R8 の規則（proguard-rules.pro）が Log.v・d・i を消すため（レビュー R12）。
     */
    private fun logFirebaseProject(projectId: String?) {
        if (FirebaseProjectCheck.isProduction(projectId)) {
            Log.w(LOG_TAG, "Firebase の接続先: $projectId（本番）")
        } else {
            Log.e(
                LOG_TAG,
                "Firebase の接続先が本番（${FirebaseProjectCheck.PRODUCTION_PROJECT_ID}）ではない: $projectId。" +
                    "android/app/google-services.json を確かめること",
            )
        }
    }
}
