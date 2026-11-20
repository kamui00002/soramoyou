// ⭐️ 編集の途中・下書き・装備・写真の写し・後始末の契約（interface と型）（Kiro android-edit-tools タスク 2.3・K0・design.md:626-681）
package com.yoshidometoru.soramoyou.data.edit

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import com.yoshidometoru.soramoyou.data.image.CapturedAt
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import kotlinx.coroutines.flow.StateFlow

/*
 * K0 はこのファイルの型と interface の形だけを置く（design.md:353。形は K0 の後で変えない）。
 * 実装（端末の中の置き場・装備の保存・編集の途中の保存・写真の写し・下書き〔A4〕、後始末〔A5〕）は後のタスクが作る。
 * K0 の時点では、本体のどこもこれらを使わない。
 */

/** 下書きの ID（大文字の UUID） */
@JvmInline value class DraftId(val value: String)

/** アプリの中に写した写真。uri は file: の場所。relativeFile は利用者のフォルダからの相対（写せなかったら null で、uri は元の URI） */
data class WorkingPhoto(val uri: String, val relativeFile: String?, val capturedAt: CapturedAt?) {
    /** 画像の部品（ImagePipeline・EditPreviewRenderer・PostPhoto）へ渡す形。index は画面に出ている並びの 0 始まりの位置 */
    fun toPickedPhoto(index: Int): PickedPhoto = PickedPhoto(uri, index)
}

interface WorkingPhotoImporter {
    /** 読めると確かめた写真を、選んだ順に写す。1 枚でも写せなければ、その写真は元の URI のまま返し、失敗を記録する */
    suspend fun import(uid: Uid, photos: List<PickedPhoto>): List<WorkingPhoto>
}

/** 編集の途中を読み戻した結果 */
sealed interface SessionLoad {
    data object None : SessionLoad
    data class Restored(val document: EditWorkDocument, val photos: List<WorkingPhoto>) : SessionLoad
    data object Unreadable : SessionLoad
}

interface EditSessionStore {
    suspend fun save(uid: Uid, document: EditWorkDocument): AppResult<Unit>
    suspend fun load(uid: Uid): SessionLoad

    /** session/ を丸ごと消す。例外を投げない */
    suspend fun clear(uid: Uid)

    /**
     * session/ の文書の sessionId が同じときだけ、session/ を丸ごと消す。文書が無い・印が違うときは何もしない。例外を投げない
     * （投稿の成功の後の後始末が使う）
     */
    suspend fun clearSession(uid: Uid, sessionId: String)
}

data class LocalDraftSummary(val id: DraftId, val savedAtEpochMillis: Long, val photoCount: Int, val thumbnailUri: String?, val isBroken: Boolean)

sealed interface DraftSaveResult {
    data class Saved(val id: DraftId) : DraftSaveResult
    data object LimitReached : DraftSaveResult
    data class Failed(val error: AppError) : DraftSaveResult
}

sealed interface DraftOpenResult {
    data class Opened(val document: EditWorkDocument, val photos: List<WorkingPhoto>) : DraftOpenResult
    data object Broken : DraftOpenResult
}

interface LocalDraftRepository {
    /** 保存した日時の新しい順 */
    suspend fun list(uid: Uid): List<LocalDraftSummary>
    suspend fun save(uid: Uid, document: EditWorkDocument, thumbnailJpeg: ByteArray?): DraftSaveResult
    suspend fun open(uid: Uid, id: DraftId): DraftOpenResult
    suspend fun delete(uid: Uid, id: DraftId): AppResult<Unit>

    companion object {
        const val MAX_DRAFTS = 10
    }
}

interface LoadoutStore {
    /** 読むまでは DEFAULT */
    val loadout: StateFlow<Loadout>

    /** canSave でなければ Validation を返さず、呼ぶ側が先に止める */
    suspend fun save(loadout: Loadout): AppResult<Unit>
}

/** 利用者の区切り（ログアウト・匿名のログアウト・退会） */
enum class SessionEndReason { SIGN_OUT, SIGN_OUT_ANONYMOUS, ACCOUNT_DELETED }

fun interface UserEditDataPurger {
    /** 例外を投げない。失敗は記録する */
    suspend fun purge(uid: Uid, reason: SessionEndReason)

    companion object {
        val NONE = UserEditDataPurger { _, _ -> }
    }
}
