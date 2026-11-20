// ⭐️ 退会の段階 LIKES・COMMENTS を受け持つ部品（口を定めたのはタスク 31.2・実装 DefaultOwnReactionsDeleter はタスク 31.3・要件 12.3・12.4）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.ShapeContract
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.DrainTarget
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade

/**
 * 退会で、自分が付けたいいね・自分が書いたコメントを**全て**消し、相手の投稿のカウンタを 1 件ごとに 1 減らす部品
 * （設計書 AccountDeletionService の手順 3・4。iOS の `deleteReactions`／`deleteReaction`：FirestoreService.swift:1000-1095）。
 * 退会の手順の本体（[DefaultAccountDeletionService]）は、段階 LIKES で [ReactionKind.LIKE]、段階 COMMENTS で [ReactionKind.COMMENT] を渡して
 * これを呼ぶだけで、取得の繰り返し・1 件ずつのトランザクション・3 段の分岐はこの部品が持つ（タスク 31.3）。
 *
 * 実装（タスク 31.3）への約束：
 * - 取得は `drainOwnDocuments`（DeletionDrain.kt。`DrainTarget.LIKES`／`COMMENTS`・50 件ずつ・サーバーから・200 ページで打ち切り）を使う。
 *   空になるまで消し切ったら `Ok`
 * - 1 件ずつ順に処理する（同じ投稿へのコメントが 2 件あると、まとめて -2 にした書き込みは rules の `isCountOnlyUpdate` に拒否されるため）
 * - 段 A（トランザクションで投稿を読み、存在してカウンタが 1 以上なら -1 して消す）・段 B（段 A が権限拒否・不在なら、読まずに削除と -1 を一括で書く）・
 *   段 C（段 B も権限拒否・不在なら、削除だけ）のどれで消せても、その 1 件は成功。`postId` の無い文書は削除だけ。
 *   段 C と `postId` 無しで「カウンタを直せずに消した」ことは、この部品が自分の発生箇所で記録してよい（退会は止めない）
 * - `Err` を返すのは**退会を止める失敗**だけ：権限拒否・不在**以外**の失敗（通信の断絶など）、段 C の削除自体の失敗、取得の失敗・200 ページの超過
 * - 返す `Err` は**記録しない**。手順の本体が `StageFailed(LIKES|COMMENTS, 原因)` として、段階名つきの発生箇所で 1 回だけ記録する
 *   （書き込みの入口が自分で断って記録済みにした `WriteBlocked`・`ShapeViolation` は、手順の本体も記録し直さない）
 * - 例外は投げない（コルーチンの取り消しを除く）。書き込みの可否は `WriteCapability.ACCOUNT_DELETE`
 */
interface OwnReactionsDeleter {

    /** [uid]（退会するログイン中の本人）の [kind] を全て消し、相手の投稿のカウンタを減らす。消し切れたら `Ok`、退会を止める失敗なら `Err`。 */
    suspend fun deleteAll(kind: ReactionKind, uid: Uid): AppResult<Unit>
}

/** [OwnReactionsDeleter] が消す反応の種類。コレクション名とカウンタのフィールド名は実装（タスク 31.3）にだけ書く。 */
enum class ReactionKind {
    /** 自分が付けたいいね：`likes` の `userId == uid`。減らすのは投稿の `likesCount`。 */
    LIKE,

    /** 自分が書いたコメント：`comments` の `userId == uid`。減らすのは投稿の `commentsCount`。 */
    COMMENT,
}

/**
 * [OwnReactionsDeleter] の実装（タスク 31.3）。iOS の `deleteReactions`／`deleteReaction`（FirestoreService.swift:1000-1095）の写し。
 *
 * 取得は [drainOwnDocuments]（50 件ずつ・サーバーから・消してから先頭を取り直す・200 ページで打ち切り）。取った 1 件ごとに、次の 3 段で消す
 * （投稿が「読めない」ことがあるため。iOS と同じ段の分け方）：
 *
 * | 段 | 中身 | 次の段へ進む条件 |
 * |---|---|---|
 * | A | 1 つのトランザクションで投稿を読み、存在してカウンタが 1 以上なら -1 を書き、反応を消す（投稿が無い・カウンタが 0 以下なら消すだけ） | 権限拒否・不在 |
 * | B | 投稿を読まずに、反応の削除とカウンタの -1 を 1 つのトランザクションで書く | 権限拒否・不在 |
 * | C | 反応だけを消す（カウンタのずれを残すので、気づけるよう記録する） | — |
 *
 * - 段 A が権限拒否になるのは、投稿が既に消えている（rules の評価で拒否になる）・他人の非公開の投稿・フォロワー限定の投稿
 *   （手順 2 でフォローを消した後なので、もう読めない）の 3 つ。消えた投稿は段 B も不在・権限拒否になり、段 C に落ちる（iOS :1032-1040）
 * - 段 B では 0 以下かを確かめられないが、反応が残っている以上カウンタは 1 以上のはずなので、減らさずにずれを残すより減らす側を選ぶ（iOS と同じ）
 * - **それ以外の失敗**（通信の断絶・可否の無効・形の違反・不明）は、その場で `Err` を返して退会を止める（カウンタを直さないまま削除だけ進めない）。
 *   段 C の削除自体の失敗も止める（ここを消せないと退会者の痕跡が残る）
 * - `postId` が無い・空・パスに使えない文書は、減らす先が分からないので削除だけ（1 件の壊れたデータで退会全体を止めない。iOS :1047-1053）
 *
 * 段 B の「一括の書き込み」は、書き込みの入口に一括書き込み（削除と更新の混在）の口を足さず、**読み取りの無いトランザクション**
 * （[FirestoreWriteGateway.transaction] で `TxScope.get` を呼ばない）で書く。読み取りが無ければ、書き込みは版の条件を持たずに 1 回の
 * コミットで原子的に適用され、存在しない投稿の更新は一括書き込みと同じく不在で失敗する。入口の口を増やさないので、書き込みの API を
 * write パッケージに閉じ込める検査（WriteApiConfinementTest）にも手を入れずに済み、カウンタの書き込みは段 A と同じ形の検証を通る。
 *
 * 記録：返す `Err` は記録しない（手順の本体 [DefaultAccountDeletionService] が段階名つきで 1 回だけ記録する）。段 A→B の移り変わりも記録しない
 * （非公開の投稿で普通に起きる。iOS も残さない）。段 C と `postId` 無しで「カウンタを直せずに消した」ことだけを、消せた後に、この部品の発生箇所
 * `OwnReactionsDeleter.deleteAll.<likes|comments>.<counter_skipped|post_id_missing>` で記録する。ただし**1 回の [deleteAll] の中では、
 * 発生箇所ごとに最初の 1 回だけ**にする。消えた投稿へのいいねが段 C に落ちるのは普通のことで、
 * 1 件ごとに記録すると 1 回の退会で数百件の `error_occurred` になりうる（記録には ID を載せないので、件数の多さは手がかりを増やさない）。
 * 段 C の原因は段 B の権限拒否・不在（分類は user_error で `error_occurred` だけ）、`postId` 無しは壊れたデータとして `Unknown`（system_error で
 * Crashlytics にも残る。投稿の読めない文書を `Unknown("PostDecode.…")` で記録する PostDetailViewModel と同じ考え方）。
 *
 * @param analytics 段 C・`postId` 無しの記録の送り先
 */
class DefaultOwnReactionsDeleter(
    private val reader: FirestoreReader,
    private val gateway: FirestoreWriteGateway,
    private val analytics: AnalyticsFacade,
) : OwnReactionsDeleter {

    override suspend fun deleteAll(kind: ReactionKind, uid: Uid): AppResult<Unit> {
        val target = targetOf(kind)
        // この呼び出しの中で既に記録した発生箇所（同じものは 1 回だけ記録する）
        val recorded = mutableSetOf<String>()
        return drainOwnDocuments(reader, target.drain, uid) { page ->
            // 1 件ずつ順に（同じ投稿へのコメント 2 件をまとめて -2 にすると isCountOnlyUpdate に拒否される。
            // 並列にすると同じ投稿への書き込みが競合して、トランザクションのやり直しが増えるだけ：iOS :1015）
            for (document in page) {
                val deleted = deleteOne(target, document, recorded)
                if (deleted is AppResult.Err) return@drainOwnDocuments deleted
            }
            AppResult.Ok(Unit)
        }
    }

    /** 反応 [document] を 1 件、段 A → B → C の順に消す。消せたら `Ok`、退会を止める失敗なら `Err`。 */
    private suspend fun deleteOne(target: ReactionTarget, document: RawDocument, recorded: MutableSet<String>): AppResult<Unit> {
        val reactionRef = target.refOf(document.id)
        val postRef = postRefOf(document.data)
        if (postRef == null) {
            val deleted = gateway.delete(CAPABILITY, reactionRef)
            if (deleted is AppResult.Ok) recordOnce(recorded, POST_ID_MISSING, "$CONTEXT.${target.label}.post_id_missing")
            return deleted
        }

        // 段 A：投稿を読み、減らしてよいときだけ -1。反応はどちらでも消す。読み取りは全ての書き込みより前に行う（トランザクションの規則）
        val stageA = gateway.transaction(CAPABILITY) {
            val post = get(postRef)
            if (shouldDecrementCounter(post, target.counterField)) update(postRef, target.counterContract, target.decrement)
            delete(reactionRef)
        }
        if (stageA !is AppResult.Err) return AppResult.Ok(Unit)
        if (!isPostUnreachable(stageA.error)) return stageA

        // 段 B：投稿を読めない。読まずに「削除＋-1」を 1 回のコミットで書く（非公開・フォロワー限定の投稿はここで直る）
        val stageB = gateway.transaction(CAPABILITY) {
            delete(reactionRef)
            update(postRef, target.counterContract, target.decrement)
        }
        if (stageB !is AppResult.Err) return AppResult.Ok(Unit)
        if (!isPostUnreachable(stageB.error)) return stageB

        // 段 C：投稿が消えている（またはカウンタを書けない）。反応だけを消す
        val stageC = gateway.delete(CAPABILITY, reactionRef)
        if (stageC is AppResult.Ok) recordOnce(recorded, stageB.error, "$CONTEXT.${target.label}.counter_skipped")
        return stageC
    }

    /** [context] がこの呼び出しでまだ記録されていなければ、[error] を記録する。 */
    private fun recordOnce(recorded: MutableSet<String>, error: AppError, context: String) {
        if (recorded.add(context)) analytics.logError(error, context)
    }

    /** 反応の種類ごとの、取得の形・記録の名前・減らすカウンタ・反応の文書のパス。 */
    private class ReactionTarget(
        val drain: DrainTarget,
        /** 記録の発生箇所に入れる名前（退会の段階名の小文字と同じ）。 */
        val label: String,
        val counterField: String,
        val counterContract: ShapeContract,
        /** カウンタの -1（[counterContract] に合う形）。 */
        val decrement: FsDocument,
        /** 取った文書の ID のまま、反応の文書のパスにする（組み立て直さない）。 */
        val refOf: (String) -> DocRef,
    )

    internal companion object {
        /** 記録の発生箇所の前半（`クラス名.メソッド名`）。後ろに `.<likes|comments>.<理由>` を付ける。 */
        const val CONTEXT = "OwnReactionsDeleter.deleteAll"

        /** 退会の書き込みの可否（M5 で有効。手順の本体と同じ）。 */
        private val CAPABILITY = WriteCapability.ACCOUNT_DELETE

        /** `postId` が無い・空・パスに使えない反応を、カウンタを直さずに消したことの記録（壊れたデータ。値は固定の名前だけで、ID を載せない）。 */
        val POST_ID_MISSING: AppError = AppError.Unknown("ReactionWithoutPostId")

        private val LIKES = ReactionTarget(
            drain = DrainTarget.LIKES,
            label = "likes",
            counterField = "likesCount",
            counterContract = ShapeContracts.POST_LIKE_COUNTER,
            decrement = DocumentBuilders.likeCounter(-1),
            refOf = DocRef::likeById,
        )

        private val COMMENTS = ReactionTarget(
            drain = DrainTarget.COMMENTS,
            label = "comments",
            counterField = "commentsCount",
            counterContract = ShapeContracts.POST_COMMENT_COUNTER,
            decrement = DocumentBuilders.commentCounter(-1),
            refOf = DocRef::comment,
        )

        private fun targetOf(kind: ReactionKind): ReactionTarget = when (kind) {
            ReactionKind.LIKE -> LIKES
            ReactionKind.COMMENT -> COMMENTS
        }

        /**
         * 段 A で、投稿 [post] の [counterField] を減らしてよいか（iOS の `shouldDecrementCounter`：FirestoreService.swift:1105-1108）。
         * 投稿が存在し、カウンタが 1 以上のときだけ true。0 以下で減らすと負になるので減らさない。フィールドが無い・整数でない旧データも
         * 0 とみなして減らさない（投稿の読み込み・いいねの書き込み LikeRepository と同じ解釈）。
         */
        fun shouldDecrementCounter(post: RawDocument?, counterField: String): Boolean {
            val current = post?.data?.get(counterField) as? Long ?: return false
            return current >= 1
        }

        /**
         * 投稿に届かないことによる失敗か（権限拒否か不在。iOS の `isPostUnreachableError`：FirestoreService.swift:1114-1118）。
         * true なら次の段へ進む。それ以外（通信の断絶・可否の無効・形の違反・不明）は退会を止める。
         */
        fun isPostUnreachable(error: AppError): Boolean = error == AppError.PermissionDenied || error == AppError.NotFound

        /**
         * 反応の `postId` から投稿の文書のパスを作る。文字列でない・空・パスの 1 つの区切りにならない（`/` を含む）なら null
         * （減らす先が分からないものとして扱う）。
         */
        private fun postRefOf(data: Map<String, Any?>): DocRef? {
            val postId = data["postId"] as? String
            if (postId.isNullOrEmpty()) return null
            return try {
                DocRef.post(PostId(postId))
            } catch (e: IllegalArgumentException) {
                null
            }
        }
    }
}
