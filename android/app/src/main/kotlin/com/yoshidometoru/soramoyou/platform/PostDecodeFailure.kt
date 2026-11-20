// ⭐️ 読み込んだ投稿を 1 件変換できず飛ばしたことの記録（タスク 4.2・設計書の追加の仮決め QE）
package com.yoshidometoru.soramoyou.platform

/**
 * 投稿の変換に失敗した取得元。値は iOS の `PostDocumentDecoder.decodePosts(_:source:)` に渡している文字列と同じ
 * （origin/main の FirestoreService.swift :291 `home_feed`・:393 `user_posts`・:268 `public_posts`）。
 * MVP の Android が読む 3 つだけを置く（設計書 PostDocumentReader 節）。iOS にはほかに `gallery`・`search_*` などがある。
 */
enum class PostDecodeSource(val raw: String) {
    /** フィード。 */
    HOME_FEED("home_feed"),

    /** 自分のプロフィールの投稿一覧。 */
    USER_POSTS("user_posts"),

    /** 他人のプロフィールの公開投稿。 */
    PUBLIC_POSTS("public_posts"),
}

/**
 * 読み込んだ投稿を 1 件変換できず飛ばしたことを、分析イベント `post_decode_failed` として送る（タスク 7.2 の PostDocumentReader が使う）。
 *
 * **Crashlytics には送らない**（タスク 4.2・設計書 QE）。壊れた投稿が 1 件あるだけで、全ユーザーがページを開くたびに
 * 記録が積み上がるためである。iOS の `PostDocumentDecoder.report`（origin/main :76-88）と同じ判断・同じキー
 * （`source`・`path`・`error`）にしている。
 *
 * [AnalyticsFacade] の拡張関数にして、使えるのが [AnalyticsFacade.logEvent] だけの形にしている（Crashlytics へ届く道が無い）。
 * 値の浄化は logEvent が行う。
 *
 * @param path 飛ばしたドキュメントのパス（例：`posts/abc123`）
 * @param reason 飛ばした理由（iOS は `String(describing: error)` のケース名。:81）
 */
fun AnalyticsFacade.logPostDecodeFailed(source: PostDecodeSource, path: String, reason: String) {
    logEvent(
        EventName.POST_DECODE_FAILED,
        mapOf(
            "source" to ParamValue.S(source.raw),
            "path" to ParamValue.S(path),
            "error" to ParamValue.S(reason),
        ),
    )
}
