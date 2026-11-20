// ⭐️ 退会で「50 件取って消す」を空になるまで繰り返す（iOS の BatchDrainer の写し。タスク 31.2・要件 12.3・12.4）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.DrainTarget
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource

/**
 * [target] の、[uid] に関わる文書を、空になるまで「先頭から [QuerySpec.DrainByField.PAGE_SIZE] 件取る → [deletePage] で消す」を繰り返す
 * （iOS の `BatchDrainer.drain`：BatchDrainer.swift:45-74。フォローは退会の手順 [DefaultAccountDeletionService] が、
 * いいね・コメントはタスク 31.3 の部品が使う）。
 *
 * - 取得は毎回**先頭から**取り直す（続きの起点を持たない）。消した分だけ先頭が繰り上がるので、カーソルを持つより単純で安全
 * - 取得は**サーバーから**（読み取り口も退会の形には SERVER を強制するが、ここでも明示する。キャッシュの一部を「全部消えた」と誤認しない）
 * - 取れたのが 0 件なら完了。件数が上限未満なら、それが最後のページなので、空を確かめるためだけの取得を撃たずに完了（iOS と同じ）
 * - [MAX_DRAIN_PAGES] 回取っても毎回上限ちょうど返り続けたら、[DRAIN_EXCEEDED] の `Unknown` で失敗にする。
 *   正常な大量のデータでもありうるが、削除が黙って効いていない（毎回同じ文書が返る）可能性のほうが怖いので、黙って打ち切らない（iOS と同じ判断）
 * - 取得の失敗・[deletePage] の失敗は、その場で止めてその失敗を返す（残りのページには進まない）
 *
 * 記録はしない（呼び出し側が段階名つきで 1 回だけ記録する）。例外は投げない（[deletePage] が投げたものと、取り消しを除く）。
 */
internal suspend fun drainOwnDocuments(
    reader: FirestoreReader,
    target: DrainTarget,
    uid: Uid,
    deletePage: suspend (List<RawDocument>) -> AppResult<Unit>,
): AppResult<Unit> {
    val spec = QuerySpec.DrainByField(target, uid)
    repeat(MAX_DRAIN_PAGES) {
        val documents = when (val page = reader.query(spec, ReadSource.SERVER)) {
            is AppResult.Err -> return page
            is AppResult.Ok -> page.value.documents
        }
        // 空になったら完了
        if (documents.isEmpty()) return AppResult.Ok(Unit)

        val deleted = deletePage(documents)
        if (deleted is AppResult.Err) return deleted

        // 上限未満＝これが最後のページ。空を確かめるためだけの 1 回を撃たずに終える
        if (documents.size < QuerySpec.DrainByField.PAGE_SIZE) return AppResult.Ok(Unit)
    }
    // ここに来るのは「毎回上限ちょうど返り続けた」場合
    return AppResult.Err(DRAIN_EXCEEDED)
}

/** 空になるまで取り直す回数の上限（iOS の `BatchDrainer.drain` の `maxPages` の既定値と同じ 200。50 件 × 200 ＝ 1 万件）。 */
internal const val MAX_DRAIN_PAGES: Int = 200

/**
 * [MAX_DRAIN_PAGES] を超えても空にならなかったときの失敗（iOS の `DrainError.exceededMaxPages`）。
 * 新しい種類を [AppError] に足さず `Unknown` にした（分類は system_error になり、Crashlytics にも残る。
 * 足すと :contract の種類の網羅〔説明・分類〕の全てに波及するが、画面の扱いは「失敗・再試行」で他の不明な失敗と変わらないため）。
 */
internal val DRAIN_EXCEEDED: AppError = AppError.Unknown("DrainExceededMaxPages($MAX_DRAIN_PAGES)")
