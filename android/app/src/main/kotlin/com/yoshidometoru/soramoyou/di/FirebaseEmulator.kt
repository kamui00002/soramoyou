// ⭐️ 検証用ビルド（emulator）が繋ぐ Firebase Local Emulator Suite の宛先（タスク 11.1・要件 1.3）
package com.yoshidometoru.soramoyou.di

/**
 * 検証用ビルドが繋ぐエミュレータの宛先。本番向けのビルドでは使わない（BuildConfig.USE_FIREBASE_EMULATOR が false）。
 * エミュレータは `android/tools/start-firebase-emulators.sh` で起動する（firebase.json は変えず、一時ディレクトリの設定と rules の写しで
 * Auth・Firestore・Storage を起動する。タスク 17.1）。写しは storage.rules が原本のまま、firestore.rules が画像の URL の形に
 * このエミュレータの Storage の URL の形を 1 行だけ足したもの（`android/tools/make-emulator-rules.sh`・レビュー R14）。
 * アプリは Auth もここへ向けるので、エミュレータが起動していなくても本番の Auth へは行かない（ログインが失敗するだけ）。
 * ポートは Firebase CLI の既定の値で、起動スクリプトとここで同じ値にする（EmulatorBuildIsolationTest が突き合わせる）。
 */
object FirebaseEmulator {

    /**
     * 検証用のプロジェクト ID。`demo-` は Firebase が本物のプロジェクトに割り当てない予約の接頭辞で、
     * このプロジェクト ID のアプリはエミュレータ以外の Firebase へは繋がらない。
     */
    const val PROJECT_ID = "demo-soramoyou"

    /** Android の仮想端末から見た、開発機（エミュレータを起動した Mac）の住所。 */
    const val HOST = "10.0.2.2"

    const val AUTH_PORT = 9099
    const val FIRESTORE_PORT = 8080
    const val STORAGE_PORT = 9199
}
