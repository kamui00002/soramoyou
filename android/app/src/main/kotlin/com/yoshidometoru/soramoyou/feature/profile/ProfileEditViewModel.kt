// ⭐️ プロフィール編集の画面の状態：いまのプロフィールの読み込み・入力・残りの文字数・保存（タスク 16.3・要件 10.6・10.8・10.10・16.2）
package com.yoshidometoru.soramoyou.feature.profile

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.model.OwnProfile
import com.yoshidometoru.soramoyou.data.repository.ProfileEdit
import com.yoshidometoru.soramoyou.data.repository.ProfileEditor
import com.yoshidometoru.soramoyou.data.repository.ProfileRepository
import com.yoshidometoru.soramoyou.data.repository.ProfileSaveStage
import com.yoshidometoru.soramoyou.data.repository.exceedsProfileTextLimit
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 編集の元にする、いまのプロフィールの読み込みの段階。 */
sealed interface ProfileEditLoad {

    /** 読み込み中（要件 16.2）。入力欄はまだ出さない。 */
    data object Loading : ProfileEditLoad

    /** 読めた。入力欄に、読んだ値が入っている。 */
    data object Ready : ProfileEditLoad

    /**
     * 読めなかった。ユーザー文書が無い（`NotFound`）ときも、保存（`users` の部分更新から始まる）が必ず失敗するのでここに入れる。
     * @property failedWhileOffline 失敗した時点でオフラインだったか（OfflineContent を出すのはこのときだけ）。
     */
    data class Failed(val error: AppError, val failedWhileOffline: Boolean) : ProfileEditLoad
}

/**
 * プロフィール編集の画面の状態。
 *
 * @property displayName 表示名の入力欄の値。
 * @property bio 自己紹介の入力欄の値。
 * @property currentPhotoUrl いまのアイコンの URL（新しく選んでいなければ、これを出す）。
 * @property newIcon 新しく選んだアイコン。null なら変えない（MVP にアイコンを消す操作は無い：ProfileEdit）。
 * @property saveStage 保存の部品（アプリ全体で 1 つ）の段。前に開いた編集画面で始めた保存（保存中に閉じたもの）も、ここに出る
 *   （全体レビュー 4 回目 Q04・Q05）。
 * @property error 直前の保存の失敗。文言は [profileEditErrorMessageRes] で引く。
 * @property saved 保存できた。画面はこれを見て閉じる。
 * @property loadedDisplayName 読んだときの表示名（保存で比べる元。ProfileEditor に渡す [OwnProfile] の値と同じ）。読めるまでと、無い項目は null。
 * @property loadedBio 読んだときの自己紹介（[loadedDisplayName] と同じ）。
 */
data class ProfileEditUiState(
    val load: ProfileEditLoad = ProfileEditLoad.Loading,
    val displayName: String = "",
    val bio: String = "",
    val currentPhotoUrl: String? = null,
    val newIcon: PickedPhoto? = null,
    val isSaving: Boolean = false,
    val saveStage: ProfileSaveStage = ProfileSaveStage.IDLE,
    val error: AppError? = null,
    val saved: Boolean = false,
    val loadedDisplayName: String? = null,
    val loadedBio: String? = null,
) {
    /** 表示名の上限までの残り（見た目の 1 文字＝書記素で数える。超えると負。画面は 0 で止めて出す）。 */
    val displayNameRemaining: Int get() = TextLimits.DISPLAY_NAME_MAX - TextLimits.graphemeCount(displayName)

    /** 自己紹介の上限までの残り（数え方は [displayNameRemaining] と同じ）。 */
    val bioRemaining: Int get() = TextLimits.BIO_MAX - TextLimits.graphemeCount(bio)

    /**
     * 表示名が上限を超えていて、保存を止める（画面は欄を赤くする）。判断は保存の部品と同じ [exceedsProfileTextLimit] で、
     * 読んだ値から変えていない表示名と、iOS より多く数える古い端末では立てない（全体レビュー 4 回目 R21 の利用者の決定）。
     */
    val displayNameOverLimit: Boolean
        get() = exceedsProfileTextLimit(displayName, loadedDisplayName, TextLimits::isDisplayNameWithinLimit)

    /** 自己紹介が上限を超えていて、保存を止める（[displayNameOverLimit] と同じ判断）。 */
    val bioOverLimit: Boolean get() = exceedsProfileTextLimit(bio, loadedBio, TextLimits::isBioWithinLimit)

    /**
     * 両方が上限以内か（iOS の `isValidProfileEdit`：ProfileViewModel.swift:742-745）。false の間は、iOS と同じ案内を出して保存を押せなくする。
     * iOS は変えたかによらず常に両方を見るが、ここは [displayNameOverLimit]・[bioOverLimit] の判断に従う（変えていない値と古い端末では見ない）。
     */
    val isWithinLimits: Boolean get() = !displayNameOverLimit && !bioOverLimit

    /**
     * 保存を押せるか。読めていて、上限以内で、保存中でも保存済みでもなく、前に開いた画面で始めた保存も走っていないとき
     * （iOS の保存のボタンの `disabled`：ProfileEditView.swift:112。iOS は共有の ViewModel の `isLoading` で、開き直しても前の保存が終わるまで押せない）。
     * 何も変えていなくても押せる（iOS と同じ。書かずに閉じるのは ProfileEditor が決める）。
     * 接続の有無はここでは見ない。画面のボタンと [ProfileEditViewModel.save] の入口が、これと合わせて見る（レビュー R09）。
     */
    val canSave: Boolean get() = load == ProfileEditLoad.Ready && isWithinLimits && !isSaving && !saved && saveStage == ProfileSaveStage.IDLE

    /**
     * 前に開いた編集画面で始めた保存（保存中に閉じたもの）が、まだ走っている。この画面の保存を押せない理由を出す（全体レビュー 4 回目 Q04）。
     * 自分の保存の間は、読み込み中の表示を出しているので立てない。
     */
    val isOthersSaving: Boolean get() = saveStage != ProfileSaveStage.IDLE && !isSaving
}

/**
 * プロフィール編集の画面の ViewModel（iOS の `ProfileEditView` ＋ `ProfileViewModel.updateProfile`）。
 *
 * - いまのプロフィールは [ProfileRepository.observeOwn] の**最初の 1 回だけ**を読み、監視はやめる。監視し続けると、入力している間に
 *   別の端末の更新が届いて欄を書き換えてしまうため。保存はこの 1 回で読んだ値と比べて「変えた項目」を決める（ProfileEditor）
 * - 読み込みの失敗は記録する（ProfileViewModel と同じ。ユーザー文書が無いのは補完を待つ普通の状態なので記録しない）
 * - 保存の失敗は記録しない（ProfileEditor が `ProfileEditor.save.<段階>` で記録済み）。選んだ写真は残し、もう一度押せば上げ直す
 * - 画面名は送らない（iOS の ProfileEditView も送らない）
 * - キャンセル（戻る）では何も残さない。この ViewModel は画面ごとに作られ、閉じると捨てられる。
 *   ただし保存中に閉じても、送り始めた保存は最後まで届く（ProfileEditor が取り消さない。レビュー R03）。開き直した画面は、その保存が
 *   終わるまで保存を押せない（保存の段は ProfileEditor が持つ。後から終わった前の保存が、開き直して保存した値を古い値で上書きしないように。
 *   全体レビュー 4 回目 Q04）。開き直した画面の欄は前の保存より前の値で埋まるが、変えなかった項目は書かないので、前の保存の値が残る
 * - オフラインの間は保存しない（兄弟の FeedbackViewModel と同じ。書き込みが接続を待ち続け、理由の出ないまま止まるため。レビュー R09）
 * - プロセスが落ちて作り直されたとき（写真選択画面を開いている間などに、裏に回ったアプリがメモリの不足で殺され、戻る履歴と一緒に
 *   この画面が戻ったとき）のために、打った表示名・自己紹介を [savedState] に残し、読み込みが終わったら読んだ値より先に入れる
 *   （全体レビュー 4 回目 Q10。残さないと、選んだアイコンだけが新しく、打った文は読み直した値に戻ったまま保存される）。
 *   打っていない項目は読んだ値のまま（前に読んだ古い値を残すと、その間の別の端末の更新を保存で上書きするため）。
 *   選んだアイコンは残さない（写真選択画面がくれる読む許可はプロセスと共に切れる＝推定。開いている間に落ちたときは、
 *   選んだ結果が作り直した画面に届く）
 *
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。
 * @param savedState この画面（戻る履歴の 1 枚）の保存の箱（`createSavedStateHandle()`）。プロセスが落ちても残る。
 * @param scope この ViewModel の viewModelScope（RootViewModel と同じ理由で外から渡す）。
 */
class ProfileEditViewModel(
    private val profileRepository: ProfileRepository,
    private val editor: ProfileEditor,
    private val analytics: AnalyticsFacade,
    val isOnline: StateFlow<Boolean>,
    private val savedState: SavedStateHandle,
    private val scope: CoroutineScope,
) : ViewModel(scope) {

    private val mutableState = MutableStateFlow(ProfileEditUiState())

    val state: StateFlow<ProfileEditUiState> = mutableState.asStateFlow()

    /** 読み込んだ、いまのプロフィール（保存で比べる元）。読めるまで null。 */
    private var current: OwnProfile? = null

    private var loadJob: Job? = null

    init {
        // 保存の段は保存の部品が持つ（画面より長生きする）ので、前に開いた画面で始めた保存もここで見える（全体レビュー 4 回目 Q04・Q05）
        scope.launch { editor.state.collect { stage -> mutableState.update { it.copy(saveStage = stage) } } }
        load()
    }

    /** 読み込みの失敗の後に、読み直す。 */
    fun retryLoad() {
        if (mutableState.value.load is ProfileEditLoad.Failed) load()
    }

    fun onDisplayNameChange(value: String) {
        mutableState.update { it.copy(displayName = value, error = null) }
        savedState[KEY_DISPLAY_NAME] = value
    }

    fun onBioChange(value: String) {
        mutableState.update { it.copy(bio = value, error = null) }
        savedState[KEY_BIO] = value
    }

    /** 写真選択画面で選んだ写真の URI。選ばずに閉じたとき（null）は前の選択のままにする。 */
    fun onIconPicked(uri: String?) {
        if (uri == null) return
        mutableState.update { it.copy(newIcon = PickedPhoto(uri, index = 0), error = null) }
    }

    /** 入力のまま保存する。押せないとき（読み込み前・上限超過・保存中・保存済み・前の保存が走っている・オフライン）は何もしない（二重に送らない）。 */
    fun save() {
        val state = mutableState.value
        val base = current ?: return
        if (!state.canSave || !isOnline.value) return
        mutableState.update { it.copy(isSaving = true, error = null) }
        scope.launch {
            when (val result = editor.save(ProfileEdit(state.displayName, state.bio, state.newIcon), base)) {
                is AppResult.Ok -> mutableState.update { it.copy(isSaving = false, saved = true) }
                is AppResult.Err -> mutableState.update { it.copy(isSaving = false, error = result.error) }
            }
        }
    }

    private fun load() {
        loadJob?.cancel()
        mutableState.update { it.copy(load = ProfileEditLoad.Loading) }
        loadJob = scope.launch {
            when (val first = profileRepository.observeOwn().first()) {
                is AppResult.Ok -> {
                    val profile = first.value
                    current = profile
                    // 読んだままの値を入れる（空白だけの値も。ProfileEditor が「変えていない」と判定できるように）。
                    // プロセスが落ちる前に打った値が残っていれば、そちらを入れる（入力欄は読み込みの後にしか出ないので、
                    // 残っているのは前のプロセスの画面で打った値だけ）
                    mutableState.update {
                        it.copy(
                            load = ProfileEditLoad.Ready,
                            displayName = savedState.get<String>(KEY_DISPLAY_NAME) ?: profile.displayName.orEmpty(),
                            bio = savedState.get<String>(KEY_BIO) ?: profile.bio.orEmpty(),
                            currentPhotoUrl = profile.photoUrl,
                            // 上限の判断で「変えたか」を比べる元（保存で ProfileEditor に渡す current と同じ値）
                            loadedDisplayName = profile.displayName,
                            loadedBio = profile.bio,
                        )
                    }
                }
                is AppResult.Err -> {
                    if (first.error != AppError.NotFound) analytics.logError(first.error, "$CONTEXT.load")
                    mutableState.update { it.copy(load = ProfileEditLoad.Failed(first.error, failedWhileOffline = !isOnline.value)) }
                }
            }
        }
    }

    private companion object {
        /** 記録の発生箇所の前置き。 */
        const val CONTEXT = "ProfileEditViewModel"

        /** [savedState] の鍵（打った表示名・自己紹介。打っていなければ鍵は無い）。 */
        const val KEY_DISPLAY_NAME = "displayName"
        const val KEY_BIO = "bio"
    }
}
