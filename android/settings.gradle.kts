// ⭐️ そらもよう Android 版のビルド全体の設定
// iOS 版と同じリポジトリの android/ 配下に置き、Soramoyou/（iOS 版）には一切触れない（要件 1.1）

pluginManagement {
    // Gradle プラグイン（AGP・Kotlin など）を取りに行く場所
    repositories {
        google {
            // Google の Maven からは Android・Google 系のプラグインだけを取る
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // ライブラリの取得先はここだけで決める（各モジュールが勝手に増やすとビルドを失敗させる）
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "soramoyou-android"

// :app      … 画面と Firebase への接続を持つアプリ本体
// :contract … Firebase に依存しない純 Kotlin のモジュール（ドキュメントの形・規則・列挙値）
include(":app", ":contract")
