// ⭐️ 退会の手順の本体：再認証 → iOS と同じ順のデータの削除（画像の 3 段階を含む）→ 認証のアカウントの削除 → 端末内のデータの消去（設計書の部品 AccountDeletionService。タスク 31.2・31.6・要件 12.3〜12.5・12.7）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.AuthErrorKind
import com.yoshidometoru.soramoyou.contract.DeletionStage
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.data.edit.SessionEndReason
import com.yoshidometoru.soramoyou.data.edit.UserEditDataPurger
import com.yoshidometoru.soramoyou.data.remote.RawDocument
import com.yoshidometoru.soramoyou.data.remote.read.DrainTarget
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.OwnedCollection
import com.yoshidometoru.soramoyou.data.remote.read.QuerySpec
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.SessionManager
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** アカウントの削除（設計書の AccountDeletionService の節）。退会の画面（タスク 31.5）が使う。 */
interface AccountDeletionService {

    /**
     * いま実行している段階。[delete] を実行していない間は null（成功・失敗で終わったら null に戻る）。
     * 退会の画面が「〜を削除しています」を出すのに使う。止まった段階は [delete] の戻り値の `StageFailed` が持つ。
     */
    val stage: StateFlow<DeletionStage?>

    /**
     * いまログインしているユーザーのアカウントとデータを消す。順は [DeletionStage] の宣言の順（設計書の AccountDeletionService の節。iOS の
     * `deleteUserData`：FirestoreService.swift:874-951 と、その呼び出し元 `performReauthAndDelete`：SettingsViewModel.swift:232-260 と同じ順。
     * 投稿の画像〔POST_IMAGES〕とアイコン画像〔PROFILE_IMAGE〕の 2 段階はタスク 26 の判断②、文書から拾えなかった画像〔STORAGE_LEFTOVERS〕は
     * タスク 31.6 で足した。iOS の退会も #260 から同じ 3 段階を持つ）。
     *
     * - 最初に [password] で再認証する（REAUTH）。ここで失敗したら、データには一切触れていない
     * - 途中の段階で失敗したら、以降の段階と認証のアカウントの削除を行わずに `StageFailed(止まった段階, 原因)` を返す。
     *   もう一度呼べば再認証からやり直し、各段階はサーバーから取り直してから消すので、残りだけを消す（既に無いものの削除が成功になるのは
     *   一部の文書と Storage だけ。取ってから消すまでの間に別の操作で消えた文書は `PermissionDenied` で止まりうる。下の実装の注記）
     * - 全て消せたら、端末内のそのユーザーのデータを消して（SessionManager。要件 12.7）`Ok` を返す。認証状態は SignedOut に切り替わる
     * - 未ログインなら何もせずに `PermissionDenied` を返す
     * - 再認証の後、返るまでの間は、他の画面からの「作る・書き換える」書き込み（補完・プロフィールの保存・投稿・いいねなど）を
     *   書き込みの入口が `PermissionDenied` で断る（消したばかりの文書や画像を作り直させない。消す書き込みは通る）
     *
     * 失敗の記録はこの部品が行う（呼び出し側は記録し直さない）。例外は投げない（再認証の間の取り消しを除く）。
     * 同時に 2 回呼ばない（画面は削除中に押せなくする）。
     */
    suspend fun delete(password: String): AppResult<Unit>
}

/**
 * [AccountDeletionService] の実装。各段階の中身は次のとおり（設計書の手順の番号）。
 *
 * | 段階 | 中身 |
 * |---|---|
 * | REAUTH | 0. [AuthRepository.reauthenticate]（Android の MVP には匿名が無いので、全員メールアカウントとして必ず行う） |
 * | PUBLIC_PROFILE | 1. `publicProfiles/{uid}` を消す |
 * | FOLLOWS_AS_FOLLOWER・FOLLOWS_AS_FOLLOWEE | 2. `follows` を 50 件ずつ、空になるまで（[drainOwnDocuments]。200 ページで打ち切り） |
 * | LIKES・COMMENTS | 3・4. [OwnReactionsDeleter] に任せる（タスク 31.3） |
 * | POST_IMAGES | 5 の前半. 自分の投稿の本体・サムネイル・元画像を Storage から消す（パスが無ければ URL から解決） |
 * | POSTS | 5. 自分の投稿をサーバーから全件取り直して消す（500 件ずつの一括削除は書き込みの入口が分ける） |
 * | DRAFTS・FAVORITES | 6・7. 下書き・お気に入りを全件消す（下書きに Storage の画像は無い） |
 * | PROFILE_IMAGE | 8 の前半. アイコン画像 `users/{uid}/profile/profile.jpg` を消す |
 * | STORAGE_LEFTOVERS | 8 の前半の続き. 自分の画像のフォルダ 10 個（[ownImageFolders]）を一覧して、残っている画像を消す（タスク 31.6） |
 * | USER | 8. `users/{uid}` を消す |
 * | AUTH | 9. [AuthRepository.deleteAuthAccount]（最近のログインを求められたら、1 回だけ再認証して呼び直す：[deleteAuthAccount]） |
 *
 * - 取得は全てサーバーから（[ReadSource.SERVER]。読み取り口も退会の形には SERVER を強制する）。通信が切れたときにキャッシュの一部を
 *   「全件」と誤認して、残りを消さずに認証のアカウントまで消してしまわないため
 * - 既に無いものの削除が成功になるのは、rules がパスだけで判定する文書（`publicProfiles`・`users`・`users/{uid}/favorites`：
 *   firestore.rules:213・:163・:179）と、Storage の「既に無い」（`NotFound`。消せたものとみなす）だけ。`follows`・`posts`・`drafts`・
 *   `likes`・`comments` の削除の rules は `resource.data` を見る（:249-251・:283・:305-306・:326-327・:359-361）ので、無い文書の削除は
 *   rules の評価が拒否になり `PermissionDenied` が返る。どれも取った直後の存在する文書を消すが、
 *   取ってから消すまでの間に別の操作（相手のフォロワー削除・別の端末でのいいねの取り消しなど）で消えると、その段階は
 *   `StageFailed(段階, PermissionDenied)` で止まる。もう一度呼べば取り直すので回復する。退会の画面（31.5）は、この失敗を「権限がない」と
 *   言い切らずに再試行を案内する。単体テストの記憶域は無い文書の削除を黙って成功させるので、この振る舞いは単体テストには表れない
 * - 画像の削除は 1 つごとに
 *   [imageDeleteTimeout] まで待ち、返事が無ければ `Network` として段階を失敗にする（PostDeleter と同じ上限。SDK は返事の無い要求を打ち切らない）
 * - 再認証の後は取り消さない（[NonCancellable]）。画面を離れて取り消されても、消し始めたら最後まで行う。途中で止めると、公開プロフィールや
 *   フォローだけが消えた半端なアカウントが残るため（自分の投稿の削除 PostDeleter と同じ考え方）
 * - 再認証の後は、Firestore と Storage の書き込みの入口を、退会（ACCOUNT_DELETE）だけを通す区間にする（[FirestoreWriteGateway.exclusively]・
 *   [StorageGateway.exclusively]）。画面を離れても消し続けるので、その間の補完・プロフィールの保存・投稿・いいねなどの書き込みは
 *   入口で断る（退会の画面の作り〔31.5〕に頼らない）。区間は、成功・失敗のどちらで返っても出る（失敗ならアカウントは残っているので、
 *   使い続けても再試行してもよい）
 *
 * 記録（`error_occurred` と、分類に応じて Crashlytics）の取り決め：
 * - 段階の失敗は `StageFailed(段階, 原因)` を、発生箇所 `AccountDeletionService.delete.<段階名の小文字>`（例 `.likes`・`.post_images`）で 1 回だけ記録する。
 *   Crashlytics に送るかは分類（原因の分類を引き継ぐ）で [AnalyticsFacade.logError] が決める。CrashReporter を直接は呼ばない
 * - 原因が、書き込みの入口が自分で断って記録済みにした `WriteBlocked`・`ShapeViolation` なら記録し直さない（WriteFailureRecording.kt と同じ理由：
 *   リリースを止める根拠になる件数を二重にしない）
 * - ⚠️ 入口が「未ログイン」で自分で断った `PermissionDenied`（退会の途中で SDK のログインが消えたとき。別の経路でアカウントが無効になった等）は、
 *   rules の拒否と値の上で区別できないので、段階の失敗として記録し直す（WriteFailureRecording.kt と同じく、rules の拒否の見逃しより二重を選ぶ）。
 *   いいね・コメントの段階では、部品（[OwnReactionsDeleter]）がこの断りも「投稿に届かない」とみなして段 A→B→C と進むので、
 *   入口の 3 件と段階の 1 件で、合わせて 4 件の `error_occurred` になる。書き込みは Firebase に 1 つも届かず、user_error なので
 *   Crashlytics の件数にも響かない（害は `error_occurred` の水増しだけ）
 * - 未ログインは `AccountDeletionService.delete` で `PermissionDenied`
 *
 * @param currentUid いまログインしているユーザーの uid（いなければ null）。呼ぶたびに読む
 * @param imageDeleteTimeout 画像 1 つの削除と、フォルダ 1 つの一覧を待つ上限。単体テストでは短くする
 * @param purger 全段階が終わった後に、端末の編集の途中と下書きを消す部品（タスク 17・design.md:963）。既定の NONE は何もしない
 */
class DefaultAccountDeletionService(
    private val auth: AuthRepository,
    private val reader: FirestoreReader,
    private val gateway: FirestoreWriteGateway,
    private val storage: StorageGateway,
    private val reactions: OwnReactionsDeleter,
    private val sessionManager: SessionManager,
    private val analytics: AnalyticsFacade,
    private val currentUid: () -> Uid?,
    private val imageDeleteTimeout: Duration = IMAGE_DELETE_TIMEOUT,
    private val purger: UserEditDataPurger = UserEditDataPurger.NONE,
) : AccountDeletionService {

    private val current = MutableStateFlow<DeletionStage?>(null)

    override val stage: StateFlow<DeletionStage?> = current.asStateFlow()

    /** 画像の削除を同時に送る数の上限（投稿が多いと数百本になるので、全てを一度に送らない）。 */
    private val imagePermits = Semaphore(MAX_CONCURRENT_IMAGE_DELETES)

    override suspend fun delete(password: String): AppResult<Unit> {
        val uid = currentUid() ?: return refuse(AppError.PermissionDenied)
        try {
            // 0. 再認証。データに触る前に行う（iOS #142：最後のログインが古いと、データを消した後で認証のアカウントの削除だけが
            //    断られ、データの無いアカウントが残った。SettingsViewModel.swift:197-207）
            runStage(DeletionStage.REAUTH) { perform(DeletionStage.REAUTH, uid, password) }?.let { return it }

            // 1〜9。消し始めたら最後まで行う。その間は、Firestore・Storage の入口が退会のもの以外の「作る・書き換える」書き込みを断る
            return withContext(NonCancellable) {
                gateway.exclusively(CAPABILITY) { storage.exclusively(CAPABILITY) { deleteData(uid, password) } }
            }
        } finally {
            current.value = null
        }
    }

    /** 再認証の後の段階（[DATA_STAGES]）を順に行い、全て消せたら端末内のデータを消して `Ok` を返す。最初の失敗で止めて、その失敗を返す。 */
    private suspend fun deleteData(uid: Uid, password: String): AppResult<Unit> {
        for (stage in DATA_STAGES) {
            runStage(stage) { perform(stage, uid, password) }?.let { return it }
        }
        // 端末内のそのユーザーのデータを消す（要件 12.7）。例外を投げず、失敗した段は SessionManager が記録して続ける
        sessionManager.clearLocalUserData()
        // 端末の編集の途中と下書きを消す（要件 8.14・12.5）。例外は投げない約束。段階が失敗したときは上で返っているので、ここには来ない
        purger.purge(uid, SessionEndReason.ACCOUNT_DELETED)
        return AppResult.Ok(Unit)
    }

    /**
     * [stage] の中身。新しい段階を [DeletionStage] に足すと、この when が網羅でなくなりコンパイルが止まる
     * （ただし実行の順は [DATA_STAGES] で決まるので、足した段階は [DATA_STAGES] にも並べる）。
     */
    private suspend fun perform(stage: DeletionStage, uid: Uid, password: String): AppResult<Unit> = when (stage) {
        DeletionStage.REAUTH -> auth.reauthenticate(password)
        // 公開プロフィールを消す（iOS :886-889）。rules は isOwner(uid) なので、既に無くても成功する
        DeletionStage.PUBLIC_PROFILE -> gateway.delete(CAPABILITY, DocRef.publicProfile(uid))
        // フォローは、自分がした側とされた側の両方を消す（iOS :891-905）
        DeletionStage.FOLLOWS_AS_FOLLOWER -> deleteFollows(DrainTarget.FOLLOWS_AS_FOLLOWER, uid)
        DeletionStage.FOLLOWS_AS_FOLLOWEE -> deleteFollows(DrainTarget.FOLLOWS_AS_FOLLOWEE, uid)
        DeletionStage.LIKES -> reactions.deleteAll(ReactionKind.LIKE, uid)
        DeletionStage.COMMENTS -> reactions.deleteAll(ReactionKind.COMMENT, uid)
        DeletionStage.POST_IMAGES -> deletePostImages(uid)
        DeletionStage.POSTS -> deleteAllOwned(OwnedCollection.POSTS, uid) { DocRef.post(PostId(it.id)) }
        DeletionStage.DRAFTS -> deleteAllOwned(OwnedCollection.DRAFTS, uid) { DocRef.draft(it.id) }
        DeletionStage.FAVORITES -> deleteAllOwned(OwnedCollection.FAVORITES, uid) { DocRef.favorite(uid, it.id) }
        DeletionStage.PROFILE_IMAGE -> deleteObjects(listOf(StoragePath.profileIcon(uid)))
        DeletionStage.STORAGE_LEFTOVERS -> deleteLeftoverImages(uid)
        DeletionStage.USER -> gateway.delete(CAPABILITY, DocRef.user(uid))
        DeletionStage.AUTH -> deleteAuthAccount(password)
    }

    /**
     * 認証のアカウントを消す。`Auth(REQUIRES_RECENT_LOGIN)` で断られたら、手元の [password] で 1 回だけ再認証してから呼び直す（レビュー F11）。
     * 再認証は REAUTH の 1 回だけなので、いいね・コメント（1 件ずつのトランザクション）や画像が多いアカウントでは、データの段階の間に
     * 「最近のログイン」の窓を過ぎうる。断られたまま返すと、データは消し終えたのに認証のアカウントとメールアドレスだけが残る
     * （iOS #142 と同じ状態。再試行をやめると、次のログインで補完が users・publicProfiles を作り直す）。
     *
     * - 再認証に失敗したら、その失敗を返す（AUTH の段階の失敗になる。呼び直さない）
     * - 呼び直しても `REQUIRES_RECENT_LOGIN` なら、そのまま返す（繰り返さない。退会の画面は再試行を案内する：AccountDeletionMessages）
     * - 段階は AUTH のまま行う（REAUTH に戻さない）。失敗の記録は [runStage] が最後の結果だけを 1 回行うので、呼び直して成功すれば記録は残らない
     */
    private suspend fun deleteAuthAccount(password: String): AppResult<Unit> {
        val first = auth.deleteAuthAccount()
        if (first != AppResult.Err(AppError.Auth(AuthErrorKind.REQUIRES_RECENT_LOGIN))) return first
        return when (val reauth = auth.reauthenticate(password)) {
            is AppResult.Err -> reauth
            is AppResult.Ok -> auth.deleteAuthAccount()
        }
    }

    /**
     * [stage] を立ててから [work] を行う。成功なら null、失敗なら記録の取り決めに従って記録し、`StageFailed` を返す。
     * 部品は例外を投げない約束だが、万一投げたら（壊れた ID で DocRef が断るなど）`Unknown` の失敗にして、アプリを落とさずに再試行できる形で返す。
     */
    private suspend fun runStage(stage: DeletionStage, work: suspend () -> AppResult<Unit>): AppResult.Err? {
        current.value = stage
        val result = try {
            work()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            AppResult.Err(AppError.Unknown(e.javaClass.simpleName))
        }
        if (result !is AppResult.Err) return null
        val failure = AppError.StageFailed(stage, result.error)
        if (!isRecordedByEntryPoint(result.error)) analytics.logError(failure, "$CONTEXT.${stage.name.lowercase()}")
        return AppResult.Err(failure)
    }

    /** `follows` の [target] の向きを、50 件ずつ空になるまで消す（iOS の deleteFollows：FirestoreService.swift:970-984）。 */
    private suspend fun deleteFollows(target: DrainTarget, uid: Uid): AppResult<Unit> =
        drainOwnDocuments(reader, target, uid) { page -> gateway.batchDelete(CAPABILITY, page.map { DocRef.follow(it.id) }) }

    /**
     * 自分の [collection] をサーバーから全件取って、まとめて消す（iOS :919-941）。0 件なら何も書かない。
     * Firestore の一括書き込みの上限（500 件）ごとに分けるのは書き込みの入口 [FirestoreWriteGateway.batchDelete] の仕事（iOS batchDelete：:1122-1138）。
     */
    private suspend fun deleteAllOwned(collection: OwnedCollection, uid: Uid, refOf: (RawDocument) -> DocRef): AppResult<Unit> {
        val documents = when (val page = reader.query(QuerySpec.AllOwned(collection, uid), ReadSource.SERVER)) {
            is AppResult.Err -> return page
            is AppResult.Ok -> page.value.documents
        }
        if (documents.isEmpty()) return AppResult.Ok(Unit)
        return gateway.batchDelete(CAPABILITY, documents.map(refOf))
    }

    /**
     * 自分の投稿の画像（本体・サムネイル・元画像）を Storage から消す（タスク 26 の判断②。iOS の退会も同じ段階を持つ：#260）。
     * パスの集め方は自分の投稿の削除と同じ [postImagePathsOf]（`storagePath` が無ければ URL から解決し、自分の投稿の画像の形のパスだけを残す）。
     *
     * 投稿の文書は、この段階と POSTS の段階で**それぞれサーバーから取る**（ここで取った一覧を POSTS に渡さない）。
     * 2 回の取得の間に増えた投稿（送信中だった投稿など）があっても、POSTS で文書は必ず消える。
     */
    private suspend fun deletePostImages(uid: Uid): AppResult<Unit> {
        val posts = when (val page = reader.query(QuerySpec.AllOwned(OwnedCollection.POSTS, uid), ReadSource.SERVER)) {
            is AppResult.Err -> return page
            is AppResult.Ok -> page.value.documents
        }
        return deleteObjects(posts.flatMap { postImagePathsOf(it.data, uid) }.distinct())
    }

    /**
     * 自分の画像のフォルダ（[ownImageFolders] の 10 個）を 1 つずつ一覧して、残っている画像を全て消す（タスク 31.6・レビュー F20）。
     * POST_IMAGES は投稿の文書からパスを集めるので、文書が先に消えて画像だけが残ったもの（自分の投稿の削除 PostDeleter は文書を先に消し、
     * 画像はベストエフォートで後から消す）・2 回の取得の間に確定した投稿の画像・パスを解決できない画像を拾えない。そこで
     * POSTS と PROFILE_IMAGE の後に、フォルダの中身から拾い直す。
     *
     * - 一覧は葉のフォルダごとに行う（その上の階層の一覧は rules が断る：タスク 33.1 で実測）。1 つごとに [imageDeleteTimeout] まで待ち、
     *   返事が無ければ `Network` とする（SDK は返事の無い要求を打ち切らない。削除と同じ）
     * - 一覧の失敗は、そのフォルダで段階を失敗にして返す（取りこぼしたまま認証のアカウントまで消さない）。もう一度呼べば一覧し直す
     * - 消すのは [deleteObjects]（既に無いものは消せたものとみなす・同時に 8 本まで）。何も残っていなければ何も消さない
     */
    private suspend fun deleteLeftoverImages(uid: Uid): AppResult<Unit> {
        val leftovers = mutableListOf<StoragePath>()
        for (folder in ownImageFolders(uid)) {
            when (val listed = withTimeoutOrNull(imageDeleteTimeout) { storage.list(CAPABILITY, folder) } ?: AppResult.Err(AppError.Network)) {
                is AppResult.Err -> return listed
                is AppResult.Ok -> leftovers += listed.value
            }
        }
        return deleteObjects(leftovers)
    }

    /**
     * [paths] を全て消す（同時に [MAX_CONCURRENT_IMAGE_DELETES] 本まで）。既に無いもの（`NotFound`）は消せたものとみなす。
     * 1 つ失敗しても残りは試してから、パスの並びで最初の失敗を段階の失敗として返す（再試行で消す数を減らすため）。
     * 1 つごとに [imageDeleteTimeout] まで待ち、返事が無ければ `Network` とする。
     */
    private suspend fun deleteObjects(paths: List<StoragePath>): AppResult<Unit> {
        val results = coroutineScope {
            paths.map { path ->
                async {
                    imagePermits.withPermit {
                        withTimeoutOrNull(imageDeleteTimeout) { storage.delete(CAPABILITY, path) } ?: AppResult.Err(AppError.Network)
                    }
                }
            }.awaitAll()
        }
        return results.firstOrNull { it is AppResult.Err && it.error != AppError.NotFound } ?: AppResult.Ok(Unit)
    }

    /** 未ログインを記録して返す。 */
    private fun refuse(error: AppError): AppResult.Err {
        analytics.logError(error, CONTEXT)
        return AppResult.Err(error)
    }

    /** 書き込みの入口が自分で断って記録済みにした失敗か（Storage の入口が削除で自分から断るのは `WriteBlocked` だけ）。 */
    private fun isRecordedByEntryPoint(cause: AppError): Boolean =
        cause is AppError.WriteBlocked || cause is AppError.ShapeViolation

    internal companion object {
        /** 記録の発生箇所の前半（`クラス名.メソッド名`）。後ろに `.段階名の小文字` を付ける。 */
        const val CONTEXT = "AccountDeletionService.delete"

        /** 退会の書き込みの可否（M5 で有効）。 */
        private val CAPABILITY = WriteCapability.ACCOUNT_DELETE

        /**
         * 再認証の後に行う段階の順（設計書の AccountDeletionService の節の手順 0〜9 のうち 1〜9 に、画像の 3 段階を足したもの）。
         * 「人から見えなくなるもの」を先に消す（iOS :875-882：途中で止まっても、見えたまま残るより見えなくなるほうへ倒す）。
         * 認証のアカウントの削除は必ず最後。
         */
        val DATA_STAGES: List<DeletionStage> = listOf(
            DeletionStage.PUBLIC_PROFILE,
            DeletionStage.FOLLOWS_AS_FOLLOWER,
            DeletionStage.FOLLOWS_AS_FOLLOWEE,
            DeletionStage.LIKES,
            DeletionStage.COMMENTS,
            DeletionStage.POST_IMAGES,
            DeletionStage.POSTS,
            DeletionStage.DRAFTS,
            DeletionStage.FAVORITES,
            DeletionStage.PROFILE_IMAGE,
            DeletionStage.STORAGE_LEFTOVERS,
            DeletionStage.USER,
            DeletionStage.AUTH,
        )

        /** 画像の削除を同時に送る数の上限（投稿者の表示を読む AuthorProfileCache の同時 8 件と同じ）。 */
        const val MAX_CONCURRENT_IMAGE_DELETES: Int = 8

        /** 画像 1 つの削除を待つ上限（自分の投稿の削除 PostDeleter と同じ 30 秒）。 */
        val IMAGE_DELETE_TIMEOUT: Duration = 30.seconds
    }
}
