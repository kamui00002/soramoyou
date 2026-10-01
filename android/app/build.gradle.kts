// ⭐️ アプリ本体（:app）のビルド設定
// 画面と Firebase への接続を持つモジュール。Firebase・Compose などの依存はタスク 1.2 で足す。
plugins {
    // AGP 9 は Kotlin を組み込みで扱うため、org.jetbrains.kotlin.android は適用しない
    alias(libs.plugins.android.application)
}

android {
    namespace = "com.yoshidometoru.soramoyou"
    compileSdk = 36

    defaultConfig {
        // Play では公開後に変更できない ID（決定済み）
        applicationId = "com.yoshidometoru.soramoyou"
        minSdk = 26
        targetSdk = 36
    }

    // Java 17 のバイトコードを出す。組み込み Kotlin の jvmTarget もこの値に揃う
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // ドキュメントの形・規則・列挙値は :contract から使う
    implementation(project(":contract"))
}
