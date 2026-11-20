// ⭐️ 本番の Firebase プロジェクトに繋がっているかの判定（タスク 5.1・要件 1.2）
package com.yoshidometoru.soramoyou.di

/**
 * 接続先の Firebase プロジェクトが、本番（iOS 版と同じ `soramoyou-ios`）かどうかを判定する。
 *
 * プロジェクト ID は、google-services.json（Git 管理外）から Gradle のプラグインが作るリソースを、Firebase が起動時に読んだもの
 * （FirebaseOptions.projectId）。設定ファイルを取り違えると、ビルドは通ったまま別のプロジェクトへ繋がるので、起動時に判定して
 * Logcat に出す（[com.yoshidometoru.soramoyou.SoramoyouApplication]）。
 * Firestore のリージョン（asia-northeast1）はサーバー側の設定で、端末の設定からは読めないので判定しない。
 */
object FirebaseProjectCheck {

    /** 本番のプロジェクト ID（iOS 版と同じバックエンド。要件 1.2）。 */
    const val PRODUCTION_PROJECT_ID = "soramoyou-ios"

    /** [projectId] が本番のものなら true。表記が少しでも違えば（大文字・小文字を含め）、また読めない（null）・空なら false。 */
    fun isProduction(projectId: String?): Boolean = projectId == PRODUCTION_PROJECT_ID
}
