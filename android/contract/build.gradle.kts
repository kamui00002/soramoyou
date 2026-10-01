// ⭐️ 契約モジュール（:contract）のビルド設定
// Firebase にも Android にも依存しない純 Kotlin（JVM）のモジュール。
// ドキュメントの形・入力の規則・列挙値を置き、JVM の単体テストで速く確かめる。
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
}

// Java と Kotlin の出力を同じ 17 に揃える（揃っていないと Kotlin のプラグインがビルドを止める）
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        // ビルドに使う JDK が 17 より新しくても、JDK 18 以降にしか無い API は使えないようにする
        freeCompilerArgs.add("-Xjdk-release=17")
    }
}
