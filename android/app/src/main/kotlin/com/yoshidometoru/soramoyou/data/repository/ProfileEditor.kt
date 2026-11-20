// ⭐️ プロフィールの保存（設計書の部品 ProfileEditor。タスク 16.2・要件 10.6〜10.10）
package com.yoshidometoru.soramoyou.data.repository

import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.StoragePath
import com.yoshidometoru.soramoyou.contract.ValidationReason
import com.yoshidometoru.soramoyou.contract.WriteCapability
import com.yoshidometoru.soramoyou.contract.document.DocumentBuilders
import com.yoshidometoru.soramoyou.contract.document.FieldChange
import com.yoshidometoru.soramoyou.contract.document.FsDocument
import com.yoshidometoru.soramoyou.contract.document.ProfileChange
import com.yoshidometoru.soramoyou.contract.document.ShapeContracts
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.image.ImagePipeline
import com.yoshidometoru.soramoyou.data.image.JpegSpec
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.image.PreparedImage
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.ReadSource
import com.yoshidometoru.soramoyou.data.remote.write.DocRef
import com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import java.time.Clock
import java.time.Instant
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * プロフィール編集の入力（設計書 :868）。画面の入力欄の値をそのまま渡す。
 *
 * @property displayName 表示名。空（または空白だけ）なら「表示名を消す」。
 * @property bio 自己紹介。空（または空白だけ）なら「自己紹介を消す」。
 * @property newIcon 新しく選んだアイコン。null ならアイコンは変えない（MVP にアイコンを消す操作は無い）。
 */
data class ProfileEdit(val displayName: String, val bio: String, val newIcon: PickedPhoto?)

/**
 * 表示名・自己紹介の入力欄の値 [edited] を、いまの値 [current] と比べて変更の種類にする（保存の部品と、編集画面の上限の判断が使う）。
 * - いまと同じ → 変えない（空白だけの値をそのまま保存し直すことも含む）
 * - 空、または空白だけ（全角空白を含む。設計書 :623）→ いまの値があれば削除、無ければ変えない。
 *   ⚠️ iOS（ProfileViewModel.swift:534-535）は `isEmpty` だけを見て、空白だけの値も保存する。Android は設計書に従い削除にする
 * - それ以外 → その値にする。前後の空白は取り除かない（iOS も取り除かない）
 */
internal fun profileTextChangeOf(edited: String, current: String?): FieldChange<String> = when {
    edited == current -> FieldChange.Unchanged
    TextLimits.isBlank(edited) -> if (current == null) FieldChange.Unchanged else FieldChange.Clear
    else -> FieldChange.Set(edited)
}

/**
 * 表示名・自己紹介の入力欄の値 [edited] が上限を超えていて、保存を止めるなら true（要件 10.10）。上限は [withinLimit]
 * （[TextLimits.isDisplayNameWithinLimit] か [TextLimits.isBioWithinLimit]）で見る。保存の部品（[DefaultProfileEditor.save]）と
 * 編集画面（赤い枠・案内・保存のボタン）が、同じこの判断を使う。
 *
 * 利用者の決定（2026-11-08・全体レビュー 4 回目 R21）で、次の 2 つでは止めない：
 * - いまの値 [current] から変えていない値（[profileTextChangeOf] がその値にする〔Set〕と決めたときだけ見る。空にして消すのも見ない）。
 *   iOS（ProfileViewModel.swift:742-745）は変えたかによらず常に両方を見るので、ここは iOS と違う。iOS より多く数える古い端末で、
 *   iOS で上限ちょうどにした値を読んだだけで、自己紹介やアイコンも保存できなくなるのを避けるため
 * - [enforce] が false のとき。既定は、iOS より多く数える古い端末（[TextLimits.isLegacyGraphemeBreaking]）で false。
 *   変えた値でも止めない（iOS では通る値を止めるより、緩い側に倒す）
 *
 * @param enforce 上限で止めるか。本番の呼び出しは渡さない（既定の値をここ 1 か所で決める）。単体テストだけが古い端末を写して渡す。
 */
internal fun exceedsProfileTextLimit(
    edited: String,
    current: String?,
    withinLimit: (String) -> Boolean,
    enforce: Boolean = !TextLimits.isLegacyGraphemeBreaking,
): Boolean {
    if (!enforce) return false
    val change = profileTextChangeOf(edited, current)
    return change is FieldChange.Set && !withinLimit(change.value)
}

/**
 * プロフィールの保存の段（[ProfileEditor.state]）。画面は、前に開いた編集画面で始めた保存（保存中に閉じたもの）が走っている間も
 * 保存を押せなくし（全体レビュー 4 回目 Q04）、オフラインの案内を段で分ける（Q05）。
 */
enum class ProfileSaveStage {
    /** 取り消さない書き込みは走っていない（アイコンの変換の間もここ。変換は取り消されれば何も書かずに止まる）。 */
    IDLE,

    /** アイコンを上げている。接続が切れると、送信は Storage の再試行の上限（AppContainer の 60 秒）を過ぎて失敗し、保存はそこで終わる。 */
    UPLOADING_ICON,

    /** `users` → `publicProfiles` を書いている。接続が切れても、Firestore の書き込みは接続が戻るのを待って続く。 */
    SAVING,
}

/** 自分のプロフィール（表示名・自己紹介・アイコン）を保存する（設計書の部品 ProfileEditor。:879）。 */
interface ProfileEditor {

    /**
     * 保存の段。アプリ全体で 1 つで、画面ごとの ViewModel より長生きする（PostPublisher.state と同じ考え方）。
     * 保存中に閉じた画面の保存は取り消されずに走り続けるので、開き直した画面はこれを見て、その保存が終わるまで保存を押せなくする。
     * 押せると、後から終わった前の保存が、開き直して保存した値を古い値で上書きする（全体レビュー 4 回目 Q04）。
     * 段を 1 つしか持たないので、[save] は 1 本ずつ呼ぶ（画面がこれを見て押せなくする）。
     */
    val state: StateFlow<ProfileSaveStage>

    /**
     * [edit] を、いま表示している [current] と比べて、**変えた項目と `updatedAt` だけ**を保存する（要件 10.6）。
     * 何も変えていなければ、Firestore にも Storage にも書かずに `Ok` を返す（2026-10-07 ユーザー判断）。
     *
     * 順序（設計書 :874-877。iOS の ProfileViewModel.updateProfile と同じ）：
     * 1. アイコンを選んでいれば、長辺 1024px 以下・品質 90 の JPEG にして `users/{uid}/profile/profile.jpg` へ上げ、URL を得る（要件 10.8）
     * 2. `users/{uid}` を部分更新する
     * 3. 同じ内容で `publicProfiles/{uid}` を部分更新する。失敗したら、**エラーの種類では判断せず**、有無をサーバーから読んで確かめる。
     *    無ければ補完（[AccountDocumentRepairer]）で作ってから 1 回だけ更新し直し、あれば失敗を返す（要件 10.9）
     *
     * 変えた表示名・自己紹介が上限（書記素で 50・200。要件 10.10）を超えていれば、何もせずに `AppError.Validation` を返す
     * （変えていない項目と、iOS より多く数える古い端末では見ない。[exceedsProfileTextLimit]）。
     * 失敗は [AppResult.Err] で返す。例外は投げない（コルーチンの取り消しを除く）。
     * 取り消しで止まるのはアイコンの変換までで、アイコンの送信を始めた後は、呼び出し側が取り消されても `publicProfiles` まで書き切る（レビュー R03）。
     * ログアウトは、この書き切る間の終わりを上限（10 秒）まで待ってから行う。上限を過ぎてもまだ書いていれば、残りはログアウトの後に
     * 未ログインとして断られる（全体レビュー 4 回目 Q03）。
     */
    suspend fun save(edit: ProfileEdit, current: OwnProfile): AppResult<Unit>
}

/**
 * [ProfileEditor] の実装。書き込みは必ず [gateway]・[storage] を通す（可否は [WriteCapability.PROFILE_EDIT]。M1 では `WriteBlocked`）。
 *
 * 書き込み先は [OwnProfile.uid] から組む。部分更新の契約は `id` の一致を見ないので、uid の取り違えを止める最後の守りは rules の
 * 所有者の検査である（[OwnProfile] を作るのはログイン中の uid で読む ProfileRepository だけ）。
 *
 * 記録（`error_occurred`）の取り決め：発生箇所は `ProfileEditor.save.<段階>`。入口が自分で断って記録済みのもの
 * （[recordForwardedWriteFailure]・[recordForwardedStorageFailure] が除くもの）と、補完の失敗（補完が自分で記録する）は記録し直さない。
 * 写真の変換の失敗は変換が記録しないので、ここで記録する。入力の上限の超過は、画面が先に止める入力の不備なので記録しない。
 *
 * ⚠️ アイコンを上げた後に `users` の更新が失敗すると、Storage には新しいアイコンが残る（iOS と同じ。同じパスへの上書きなので
 *    溜まらない）。
 *
 * @param inFlight 走っている取り消さない書き込みの数（アプリ全体で 1 つ。ログアウトの [DefaultAuthRepository] と同じもの）。
 * @param clock 端末の時刻（設計書 QC）。1 回の保存で 1 度だけ読み、`users`・`publicProfiles`・やり直しの全てに同じ `updatedAt` を書く。
 */
class DefaultProfileEditor(
    private val gateway: FirestoreWriteGateway,
    private val storage: StorageGateway,
    private val pipeline: ImagePipeline,
    private val reader: FirestoreReader,
    private val repairer: AccountDocumentRepairer,
    private val analytics: AnalyticsFacade,
    private val inFlight: InFlightWrites,
    private val clock: Clock = Clock.systemUTC(),
) : ProfileEditor {

    private val mutableState = MutableStateFlow(ProfileSaveStage.IDLE)
    override val state: StateFlow<ProfileSaveStage> = mutableState.asStateFlow()

    override suspend fun save(edit: ProfileEdit, current: OwnProfile): AppResult<Unit> {
        // 1. 入力の上限（iOS と同じく書記素で数える。前後の空白も数に入る）。変えていない項目と、iOS より多く数える古い端末では
        //    止めない（判断は編集画面と同じ exceedsProfileTextLimit。全体レビュー 4 回目 R21 の利用者の決定）
        if (exceedsProfileTextLimit(edit.displayName, current.displayName, TextLimits::isDisplayNameWithinLimit)) {
            return invalid(ValidationReason.DISPLAY_NAME_TOO_LONG)
        }
        if (exceedsProfileTextLimit(edit.bio, current.bio, TextLimits::isBioWithinLimit)) return invalid(ValidationReason.BIO_TOO_LONG)

        val displayName = profileTextChangeOf(edit.displayName, current.displayName)
        val bio = profileTextChangeOf(edit.bio, current.bio)
        // 何も変えていなければ書かない。profileUpdate は常に updatedAt を入れるので、組み立てる前に判定する
        // （組み立ててから空かを見ると、updatedAt だけの更新を書いてしまう）
        if (edit.newIcon == null && displayName == FieldChange.Unchanged && bio == FieldChange.Unchanged) return AppResult.Ok(Unit)

        // 2. アイコンを JPEG にする。まだ何も書いていないので、ここまでは取り消されてもよい
        val icon = edit.newIcon
        val iconJpeg: PreparedImage? = icon?.let { photo ->
            when (val prepared = prepareIcon(photo)) {
                is AppResult.Ok -> prepared.value
                is AppResult.Err -> return prepared
            }
        }

        // 3〜4 は取り消さない（レビュー R03。PostDeleter と同じ形）。保存中に「キャンセル」や戻るで画面を離れると呼び出し側が取り消され、
        // users だけ書いて止まると publicProfiles が古いまま残る（比べる元は users なので、同じ値で保存し直しても「変えていない」で直らない）。
        // アイコンの送信中に止まると、profile.jpg だけが上書きされて photoURL が変わらない。iOS も画面を閉じても保存の Task は最後まで走る。
        // 取り消さない範囲は、走っている書き込みとして数える（ログアウトがその終わりを待つ。全体レビュー 4 回目 Q03）。
        // 同じ範囲で保存の段も出す（画面が見る。全体レビュー 4 回目 Q04・Q05）
        return inFlight.track {
            withContext(NonCancellable) {
                try {
                    // 3. アイコンを上げる（Firestore より先。URL が無いと書けない）
                    val photoUrl: FieldChange<String> = if (icon == null || iconJpeg == null) {
                        FieldChange.Unchanged
                    } else {
                        mutableState.value = ProfileSaveStage.UPLOADING_ICON
                        when (val uploaded = uploadIcon(icon, iconJpeg, current)) {
                            is AppResult.Ok -> FieldChange.Set(uploaded.value)
                            is AppResult.Err -> return@withContext uploaded
                        }
                    }

                    val fields = DocumentBuilders.profileUpdate(ProfileChange(displayName, bio, photoUrl), Instant.now(clock))

                    // 4. users → publicProfiles の順
                    mutableState.value = ProfileSaveStage.SAVING
                    val userResult = gateway.update(WriteCapability.PROFILE_EDIT, DocRef.user(current.uid), ShapeContracts.USER_PROFILE_UPDATE, fields)
                    if (userResult is AppResult.Err) {
                        analytics.recordForwardedWriteFailure(userResult.error, "$CONTEXT.users")
                        return@withContext userResult
                    }
                    updatePublicProfile(current, fields)
                } finally {
                    // 終わり方（成功・失敗）によらず戻す。戻さないと、次に開いた編集画面がいつまでも保存を押せない
                    mutableState.value = ProfileSaveStage.IDLE
                }
            }
        }
    }

    /** [icon] を JPEG にする。変換の失敗は変換が記録しないので、ここで記録してから返す。 */
    private suspend fun prepareIcon(icon: PickedPhoto): AppResult<PreparedImage> {
        val result = pipeline.prepare(icon, JpegSpec.ICON)
        if (result is AppResult.Err) analytics.logError(result.error, "$CONTEXT.icon")
        return result
    }

    /** JPEG にした [icon]（[prepared]）を上げ、ダウンロード URL を返す。失敗は記録の取り決めに従って記録してから返す。 */
    private suspend fun uploadIcon(icon: PickedPhoto, prepared: PreparedImage, current: OwnProfile): AppResult<String> {
        val uploaded = storage.uploadJpeg(WriteCapability.PROFILE_EDIT, StoragePath.profileIcon(current.uid), prepared.body, icon.index)
        if (uploaded is AppResult.Err) analytics.recordForwardedStorageFailure(uploaded.error, "$CONTEXT.upload")
        return uploaded
    }

    /**
     * `publicProfiles` を [fields] で部分更新する。失敗の種類は見ずに、有無をサーバーから読んで確かめる（要件 10.9）。
     * 読むのはサーバーから（[ReadSource.SERVER]）。端末のキャッシュの「無い」で補完すると、実際にはある文書を補完が読み直すだけの
     * 遠回りになり、キャッシュの「ある」で諦めると、無い文書を作り損ねる。
     */
    private suspend fun updatePublicProfile(current: OwnProfile, fields: FsDocument): AppResult<Unit> {
        val ref = DocRef.publicProfile(current.uid)
        val first = gateway.update(WriteCapability.PROFILE_EDIT, ref, ShapeContracts.PUBLIC_PROFILE_UPDATE, fields)
        if (first !is AppResult.Err) return first
        analytics.recordForwardedWriteFailure(first.error, "$CONTEXT.publicProfiles")

        // 有無を確かめられない・あるなら、最初の失敗をそのまま返す
        val existing = reader.get(ref, ReadSource.SERVER)
        if (existing !is AppResult.Ok || existing.value != null) return first

        // 無い：補完で作ってから 1 回だけやり直す。補完の失敗は補完が記録済み
        val repaired = repairer.ensureAccountDocuments()
        if (repaired is AppResult.Err) return repaired

        val retried = gateway.update(WriteCapability.PROFILE_EDIT, ref, ShapeContracts.PUBLIC_PROFILE_UPDATE, fields)
        if (retried is AppResult.Err) analytics.recordForwardedWriteFailure(retried.error, "$CONTEXT.publicProfilesRetry")
        return retried
    }

    private fun invalid(reason: ValidationReason): AppResult.Err = AppResult.Err(AppError.Validation(reason))

    private companion object {
        /** 記録の発生箇所の前半（`クラス名.メソッド名`）。後ろに `.段階` を付ける。 */
        const val CONTEXT = "ProfileEditor.save"
    }
}
