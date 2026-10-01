// ⭐️ ルートのビルド設定
// プラグインの版数をここで 1 回だけ読み込み、各モジュールでは版数を書かずに適用する。
plugins {
    alias(libs.plugins.android.application) apply false
    // :contract が使う Kotlin（JVM）のプラグイン。ここで読み込んだ版が、
    // AGP の組み込み Kotlin（既定は 2.2.10）にも使われる。
    alias(libs.plugins.kotlin.jvm) apply false
    // :app が使う Compose コンパイラと Firebase の Gradle プラグイン（版数はカタログで固定）
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.google.services) apply false
    alias(libs.plugins.firebase.crashlytics) apply false
}
