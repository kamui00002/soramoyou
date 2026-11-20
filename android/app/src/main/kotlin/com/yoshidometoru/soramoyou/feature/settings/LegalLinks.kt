// ⭐️ 法的情報（プライバシーポリシー・利用規約）の Web ページの URL の定数（レビュー R01。設定と新規登録の画面が同じ定数を開く）
package com.yoshidometoru.soramoyou.feature.settings

/**
 * プライバシーポリシーの Web ページ（hosting/privacy/。iOS の設定の「法的情報」と同じ場所）。
 * 設定の項目（SettingsScreen）と新規登録の画面（SignUpScreen）が、外のブラウザで開く。
 *
 * このファイルは法的情報の URL の定数だけを持つ。
 */
const val PRIVACY_POLICY_URL = "https://soramoyou-ios.web.app/privacy/"

/**
 * 利用規約の Web ページ（hosting/terms/。iOS のアプリ内の本文 termsOfServiceText から生成したもの。レビュー R02）。
 * Android は本文をアプリに持たず、設定の項目と新規登録の画面から外のブラウザで開く。
 */
const val TERMS_OF_SERVICE_URL = "https://soramoyou-ios.web.app/terms/"
