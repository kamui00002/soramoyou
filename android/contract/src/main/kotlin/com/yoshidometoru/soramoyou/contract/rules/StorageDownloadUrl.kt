// ⭐️ 画像の URL として書いてよい、Firebase Storage のダウンロード URL の形（firestore.rules の isValidImageUrl を写したもの。レビュー R14）
package com.yoshidometoru.soramoyou.contract.rules

/**
 * 画像の URL（投稿の写真の `url`・`thumbnail`、プロフィールの `photoURL`）として書いてよい、Storage のダウンロード URL の形。
 * 書き込みの契約（ShapeContracts）が使う。
 *
 * 根拠：
 * - firestore.rules の `isValidImageUrl`（iOS #224）：
 *   `value.matches('(https://firebasestorage[.]googleapis[.]com(:443)?/v0/b/soramoyou-ios[.]firebasestorage[.]app/o/…)?')`。
 *   users・publicProfiles の `photoURL`（作成・更新）と、投稿の `images` の `url`・`thumbnail` に当たる
 * - 同じ所の注記「エミュレーターの Storage の URL はこの形に入らない。エミュレーターを起こすときは、その形を足した写しを読ませる」。
 *   Android の結合テストの写しは `android/tools/make-emulator-rules.sh` が作り、[EMULATOR_PATTERN] の 1 行だけを足す
 *
 * 正規表現は rules の文字列と**文字どおり同じ**にする（rules は RE2、Kotlin は java.util.regex だが、ここで使う
 * 文字の集合・グループ・`?`・`+` は両方で同じ意味）。本番の形は外側の `(…)?`（空を通すための包み）を除いたもの。
 * 空は形に入らないので、この形に合う値は空でない。EmulatorRulesCopyTest（:app）が、rules と写しの台本の文字列と突き合わせる。
 */
object StorageDownloadUrl {

    /** 名前（`/o/` の後ろ）とクエリ（`?` の後ろ）の形。名前は英数と `_ . ~ % -`、クエリはそれに `= &` を足した文字だけ（rules と同じ）。 */
    const val NAME_AND_QUERY: String = "[A-Za-z0-9_.~%-]+([?][A-Za-z0-9_.~%=&-]*)?"

    /** 本番の Storage のダウンロード URL の形（rules の `isValidImageUrl` から外側の `(…)?` を除いたもの）。 */
    const val PRODUCTION_PATTERN: String =
        "https://firebasestorage[.]googleapis[.]com(:443)?/v0/b/soramoyou-ios[.]firebasestorage[.]app/o/$NAME_AND_QUERY"

    /**
     * Android の検証用ビルドが書く、エミュレータの Storage のダウンロード URL の形。
     * 仮想端末から見た開発機（`10.0.2.2`）・Storage のエミュレータのポート（9199）・検証用ビルドのバケット（`demo-soramoyou.appspot.com`）。
     * 値はアプリの FirebaseEmulator（:app）と検証用の google-services.json に合わせる（EmulatorBuildIsolationTest が突き合わせる）。
     */
    const val EMULATOR_PATTERN: String =
        "http://10[.]0[.]2[.]2:9199/v0/b/demo-soramoyou[.]appspot[.]com/o/$NAME_AND_QUERY"
}
