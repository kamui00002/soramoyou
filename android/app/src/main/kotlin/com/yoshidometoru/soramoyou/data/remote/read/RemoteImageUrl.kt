// ⭐️ 画像の URL のうち、画面で読み込んでよいもの（このビルドの Storage のダウンロード URL）だけを通す（全体レビュー 4 回目 R11）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.rules.StorageDownloadUrl

/**
 * 画面で読み込んでよい画像の URL の形。ビルドの変種ごとに 1 つだけを使う（[forBuild]。AppContainer が選んで部品に渡す）。
 *
 * 投稿の画像（`images[].url`・`thumbnail`）とプロフィールのアイコン（`photoURL`）は、このビルドが書く Storage のダウンロード URL の形に
 * **全体で**一致する値だけを通す（iOS の StorageImageURL と同じ考え。origin/main の #229）。
 *
 * - 形は書き込みの契約と同じ定数（[StorageDownloadUrl]。firestore.rules の `isValidImageUrl` を写したもの）を使う。
 *   契約はビルドの変種を見分けられないので本番とエミュレータの両方の形を通す。読む側は、このビルドの形の 1 つだけを通す
 * - rules と同じ文字の集合で全体を比べる（`#` 以降・空白などは通さない）
 */
enum class RemoteImageUrlPolicy(pattern: String) {
    /** 本番のビルド（prod）。本番の Storage のダウンロード URL の形だけを通す。 */
    PRODUCTION(StorageDownloadUrl.PRODUCTION_PATTERN),

    /** 検証用のビルド（emulator）。仮想端末から見た、エミュレータの Storage のダウンロード URL の形だけを通す。 */
    EMULATOR(StorageDownloadUrl.EMULATOR_PATTERN),
    ;

    /** 判定に使う形。比べるのは [remoteImageUrlOf] の 1 か所だけ。 */
    internal val regex = Regex(pattern)

    companion object {
        /** ビルドの変種の形。[useFirebaseEmulator] は `BuildConfig.USE_FIREBASE_EMULATOR`。 */
        fun forBuild(useFirebaseEmulator: Boolean): RemoteImageUrlPolicy =
            if (useFirebaseEmulator) EMULATOR else PRODUCTION
    }
}

/**
 * [value] が [policy] の形に全体で一致する文字列なら、その文字列をそのまま返す（作り直さない）。
 * それ以外（文字列でない・空・形の一部にしか合わない・別の方式やホストやバケット）は null。
 *
 * 判定は読み取りの変換（PostDocumentReader・AuthorProfileCache・ProfileRepository）で行い、画面では行わない（この先の画面にも同じ規則が効くように）。
 */
internal fun remoteImageUrlOf(value: Any?, policy: RemoteImageUrlPolicy): String? {
    val text = value as? String ?: return null
    return text.takeIf { policy.regex.matches(it) }
}
