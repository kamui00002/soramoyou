// ⭐️ 通報・ブロックの書き込みと、ブロック中のユーザーの取得（タスク 29.1・要件 11.2・11.4・11.5・11.6）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.BlockChange
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.data.model.AuthorDisplay
import com.yoshidometoru.soramoyou.data.model.BlockedUserView
import com.yoshidometoru.soramoyou.data.model.PostView
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade

/**
 * 通報とブロックの書き込みと、ブロック中のユーザーの取得（設計書の部品 ModerationRepository。:945-952）。
 * 操作を出す画面（フィード・投稿詳細・設定のブロック中のユーザー）はタスク 29.2 で作る。この部品は状態を持たない。
 *
 * 書き込みの失敗は [AppResult.Err] で返し、記録はこの部品が行う（発生箇所は `ModerationRepository.<メソッド名>`。
 * 入口が自分で断って記録済みのもの〔可否の無効・形の違反〕は記録し直さない）。呼び出し側（画面）は、失敗を表示するだけで記録し直さない。
 * iOS と違い、ログインしていないときは黙って何もしないのでなく、`PermissionDenied` で失敗を返して記録する（通報・ブロックの操作を
 * 押せたのに何も起きない状態を作らない。要件 11.6）。
 */
interface ModerationRepository {

    /**
     * 投稿 [post] を [reason] で通報する（iOS の `FirestoreService.reportPost`：FirestoreService.swift:1143-1155）。
     * `reports` に、投稿の ID・通報者（自分）・通報される投稿者・理由・サーバー時刻の作成日時の 5 項目だけを、自動 ID の文書として作る（要件 11.2）。
     * 可否は [WriteCapability.REPORT]。無効なビルド（M4 以前）では Firebase に届かずに `WriteBlocked` を返す。
     * 通報される投稿者の uid が空の投稿は、契約が止めて `ShapeViolation` を返す（運営が追えない通報を作らない）。
     */
    suspend fun report(post: PostView, reason: ReportReason): AppResult<Unit>

    /**
     * [uid] をブロックする（iOS の `blockUser`：FirestoreService.swift:1174-1183）。
     * 自分のユーザー文書（`users/{自分}`）の `blockedUserIds` へ、[uid] 1 つの追加（`arrayUnion`）だけを書く。
     * 一覧を値で上書きしないので、別の端末で足したブロックを消さない。更新日時は書かない。可否は [WriteCapability.BLOCK]。
     * 操作を他人の投稿にだけ出すのは画面の役目（要件 11.7）。
     */
    suspend fun block(uid: Uid): AppResult<Unit>

    /**
     * [uid] のブロックを解除する（iOS の `unblockUser`：FirestoreService.swift:1185-1194）。
     * `blockedUserIds` から [uid] 1 つの削除（`arrayRemove`）だけを書く。可否は [WriteCapability.BLOCK]。
     */
    suspend fun unblock(uid: Uid): AppResult<Unit>

    /**
     * 自分がブロック中のユーザーを、公開プロフィール（`publicProfiles/{uid}`）の表示名とアイコンつきで返す。
     * 並びは `blockedUserIds` の並び（ブロックした順）。
     *
     * - 公開プロフィールを取得できない・中の `id` が合わない・表示名が無いユーザーは、一覧から落とさずに代替表示
     *   （[AuthorDisplay.Fallback]。名前は「ユーザー」）にする。投稿者の表示（[AuthorProfileCache]）と同じ規則で、個々の失敗は記録しない
     * - ブロック中の uid の一覧そのものを読めなければ、プロフィールは読まずに全体を `Err` で返す。
     *   この失敗は [BlockListRepository.blockedIds] が記録済みなので、ここでは記録し直さない
     * - ログインしていない・ブロック中のユーザーがいないときは、何も読まずに空の一覧を返す
     */
    suspend fun blockedProfiles(): AppResult<List<BlockedUserView>>
}

/**
 * [ModerationRepository] の実装。書き込みは必ず [gateway]（可否 → 形の検証 → 実行）を通す。
 *
 * @param gateway Firestore への書き込みの唯一の入口。
 * @param blockList ブロック中の uid の一覧の読み取り。
 * @param authors 公開プロフィールの表示名とアイコンの取得（並列の上限・代替表示の規則を持つ）。
 * @param analytics 失敗の記録先。
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。呼ぶたびに読む。
 * @param newReportId 通報の文書の ID を作る。既定は Firestore の自動 ID と同じ形（iOS の `addDocument` と同じ）。単体テストでは決まった値に差し替える。
 */
class DefaultModerationRepository(
    private val gateway: FirestoreWriteGateway,
    private val blockList: BlockListRepository,
    private val authors: AuthorProfileCache,
    private val analytics: AnalyticsFacade,
    private val currentUid: () -> Uid?,
    private val newReportId: () -> String = { FirestoreAutoId.next() },
) : ModerationRepository {

    override suspend fun report(post: PostView, reason: ReportReason): AppResult<Unit> {
        val uid = currentUid() ?: return refuseNotSignedIn(REPORT_CONTEXT)
        val result = gateway.create(
            WriteCapability.REPORT,
            DocRef.report(newReportId()),
            ShapeContracts.REPORT_CREATE,
            DocumentBuilders.reportCreate(post.postId, reporterId = uid, reportedUserId = post.userId, reason = reason),
        )
        if (result is AppResult.Err) analytics.recordForwardedWriteFailure(result.error, REPORT_CONTEXT)
        return result
    }

    override suspend fun block(uid: Uid): AppResult<Unit> = changeBlocked(BlockChange.Block(uid), BLOCK_CONTEXT)

    override suspend fun unblock(uid: Uid): AppResult<Unit> = changeBlocked(BlockChange.Unblock(uid), UNBLOCK_CONTEXT)

    override suspend fun blockedProfiles(): AppResult<List<BlockedUserView>> {
        // 一覧そのものの読み取りの失敗は、BlockListRepository が記録してから返す。ここでは記録し直さない
        val blocked = when (val result = blockList.blockedIds()) {
            is AppResult.Err -> return result
            is AppResult.Ok -> result.value
        }
        if (blocked.isEmpty()) return AppResult.Ok(emptyList())

        // 戻った時点で blocked の全員が authors に入っている（取得に失敗した人は代替表示が入る）。入っていなければ（取得の途中でログアウトしたとき）も代替表示
        authors.ensure(blocked)
        val displays = authors.authors.value
        return AppResult.Ok(blocked.map { uid -> BlockedUserView(uid, displays[uid] ?: AuthorDisplay.Fallback(null)) })
    }

    /** `users/{自分}` の `blockedUserIds` を 1 要素だけ変える。ブロックと解除は変える向きだけが違う。 */
    private suspend fun changeBlocked(change: BlockChange, context: String): AppResult<Unit> {
        val uid = currentUid() ?: return refuseNotSignedIn(context)
        val result = gateway.update(
            WriteCapability.BLOCK,
            DocRef.user(uid),
            ShapeContracts.USER_BLOCKED_IDS,
            DocumentBuilders.blockedUserIds(change),
        )
        if (result is AppResult.Err) analytics.recordForwardedWriteFailure(result.error, context)
        return result
    }

    /** ログインしていないときの書き込みは誤りなので、入口の「未ログイン」の断りと同じ扱いで記録して返す。 */
    private fun refuseNotSignedIn(context: String): AppResult.Err {
        analytics.logError(AppError.PermissionDenied, context)
        return AppResult.Err(AppError.PermissionDenied)
    }

    private companion object {
        /** 記録の発生箇所（`クラス名.メソッド名`）。 */
        const val REPORT_CONTEXT = "ModerationRepository.report"
        const val BLOCK_CONTEXT = "ModerationRepository.block"
        const val UNBLOCK_CONTEXT = "ModerationRepository.unblock"
    }
}
