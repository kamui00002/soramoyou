// ⭐️ ルートのビルド設定
// プラグインの版数をここで 1 回だけ読み込み、各モジュールでは版数を書かずに適用する。
plugins {
    alias(libs.plugins.android.application) apply false
    // :contract が使う Kotlin（JVM）のプラグイン。ここで読み込んだ版が、
    // AGP の組み込み Kotlin（既定は 2.2.10）にも使われる。
    alias(libs.plugins.kotlin.jvm) apply false
}
