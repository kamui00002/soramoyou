// ⭐️ 投稿の作成の画面の状態（タスク 21.1 で写真の選択・タスク 21.2 で読めない写真の除外とフィルター・タスク 23.5 で投稿情報と送信・Kiro android-edit-tools I1〔18.2〜18.4〕で写真ごとの編集・途中の保存・下書き・後始末）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import com.yoshidometoru.soramoyou.contract.AppError
import com.yoshidometoru.soramoyou.contract.AppResult
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.contract.edit.ColorRecipe
import com.yoshidometoru.soramoyou.contract.edit.CropMath
import com.yoshidometoru.soramoyou.contract.edit.EditHistory
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.EditWorkDocument
import com.yoshidometoru.soramoyou.contract.edit.EditWorkPhoto
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.contract.rules.HashtagExtractor
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.edit.DraftId
import com.yoshidometoru.soramoyou.data.edit.DraftOpenResult
import com.yoshidometoru.soramoyou.data.edit.DraftSaveResult
import com.yoshidometoru.soramoyou.data.edit.EditSessionStore
import com.yoshidometoru.soramoyou.data.edit.LoadoutStore
import com.yoshidometoru.soramoyou.data.edit.LocalDraftRepository
import com.yoshidometoru.soramoyou.data.edit.LocalDraftSummary
import com.yoshidometoru.soramoyou.data.edit.SessionLoad
import com.yoshidometoru.soramoyou.data.edit.WorkingPhoto
import com.yoshidometoru.soramoyou.data.edit.WorkingPhotoImporter
import com.yoshidometoru.soramoyou.data.image.CapturedAtSource
import com.yoshidometoru.soramoyou.data.image.EditPreviewRenderer
import com.yoshidometoru.soramoyou.data.image.PhotoProbe
import com.yoshidometoru.soramoyou.data.image.PickedPhoto
import com.yoshidometoru.soramoyou.data.image.PreviewBase
import com.yoshidometoru.soramoyou.data.image.PreviewImage
import com.yoshidometoru.soramoyou.data.repository.PostDraft
import com.yoshidometoru.soramoyou.data.repository.PostPhoto
import com.yoshidometoru.soramoyou.data.repository.PostPublisher
import com.yoshidometoru.soramoyou.data.repository.PublishState
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.ScreenName
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** 投稿の作成の画面の段（[PostComposerUiState.step]）。 */
enum class ComposeStep {
    /** 写真の選択（iOS の「投稿」タブ：PostView）。 */
    SELECTING,

    /** 編集（プレビューとフィルター。iOS の EditView）。 */
    EDITING,

    /** 投稿情報（キャプション・公開範囲・投稿ボタン。iOS の PostInfoView）。 */
    INFO,
}

/**
 * 画面が拾う、投稿の「いま進行中」の段階（[PostPublisher.state] の [PublishState.Uploading]・[PublishState.Saving] だけを写したもの）。
 * 成功・失敗（[PublishState.Succeeded]・[PublishState.Failed]）は写さない。それらは自分が呼んだ `publish` の戻り値だけで出す
 * （ログアウトの後や、画面を開き直したときに、前の投稿の結果を出さないため。設計書の PostPublisher の節「タスク23.5の着手前に決めたこと」）。
 */
sealed interface PublishProgress {

    /** 画像を上げている。[done] 枚を上げ終えた。全部で [total] 枚。 */
    data class Uploading(val done: Int, val total: Int) : PublishProgress

    /** 全ての画像を上げ終え、投稿の文書を保存している。 */
    data object Saving : PublishProgress
}

/**
 * 投稿の作成の画面の状態。
 *
 * 画面は 3 段で、[step] で切り替える。iOS の「投稿」タブ（写真の選択：PostView）→「編集」（EditView）→「次へ」→「投稿情報」
 * （PostInfoView）と同じ流れ（タスク 23.5・ユーザー判断）。
 * - 写真の選択：読めた写真が 1 枚も無いあいだ。写真選択画面を開くボタンと、案内（上限・読めない写真）を出す
 * - 編集：読めた写真が 1 枚以上あり、投稿情報の段に進んでいないあいだ。プレビューとフィルターの選択を出す
 * - 投稿情報：編集の段で「次へ」を押した後。写真と編集の内容は編集の段から持ち越す
 *
 * @property photos 投稿の対象にする写真（読めた写真だけ・選んだ順）と、写真ごとの編集の内容と履歴（design.md:727）。
 *   投稿・変換に渡す番号は、外した写真を詰めた並びの位置（[WorkingPhoto.toPickedPhoto] に 0 から渡す。投稿の `images[].order` と、
 *   変換の失敗の「何枚目」が、画面に出ている並びと合うように）。写真はアプリの中に写したもの（写せなかった写真とログインしていない間は
 *   選んだ写真の URI のままで、relativeFile は null）。撮影日時は 1 枚目だけ、写す時に読んだ値（[WorkingPhotoImporter]）
 * @property exceeded 上限（10 枚）を超えて選ばれ、超えた分を受け付けなかったら true（[PhotoSelection.exceeded]）。
 * @property unreadablePositions 読めずに外した写真の、選んだ順の位置（1 始まり。iOS の「\(index)枚目」も 1 始まり：
 *   ImagePickerService.swift:323）。空なら案内しない。
 * @property isChecking 選んだ写真を読めるか確かめ、アプリの中に写しているあいだ true（読み込み中を出す：要件 16.2。この間は
 *   編集の操作と「次へ」を受け付けない：android-edit-tools 要件 1.8）。
 * @property hasPicked この画面で 1 回でも写真を選んだか（何も選ばずに閉じたときに、画面ごと閉じるかの判断に使う：[shouldCloseAfterPicker]）。
 * @property isEnteringInfo 編集の段で「次へ」を押して、投稿情報の段に進んだか（写真が無ければ [step] は写真の選択のまま）。
 * @property caption キャプションの入力欄の値そのもの（前後の空白も残す。取り除くのは [PostPublisher]）。
 *   上限を超えても入力は止めない（貼り付けた文を黙って切らない。ユーザー判断）。元に戻す・やり直しの対象にしない（要件 6.11）。
 * @property visibility 公開範囲。既定は公開（要件 7.9）。元に戻す・やり直しの対象にしない（要件 6.11）。
 * @property progress 投稿の「いま進行中」の段階（[PublishProgress]）。誰が始めた投稿でも写す（開き直した画面でも送信ボタンを押せなくする）。
 * @property isPublishing この画面が呼んだ `publish` が、まだ戻っていない。
 * @property publishError この画面が呼んだ `publish` の失敗。画面は成功と同じく段によらず「エラー」のダイアログで出す
 *   （iOS の PostInfoView.swift:184-192 と同じ。文言は [postErrorMessageRes] で引く）。消すのは OK（[PostComposerViewModel.dismissPublishError]）と、
 *   もう一度の投稿の始まりだけ。入力を変えても、段を移っても、写真を選び直しても消さない（保存中に段を離れて写真選択画面を開いている間に
 *   届いた失敗を、見せる前に消さないため。レビュー R18・Q07）。
 * @property published この画面が呼んだ `publish` が成功した。画面は完了のダイアログを出し、OK で閉じる。
 * @property currentIndex 表示中の写真の位置（0 始まり）。編集の操作は全てこの写真だけに掛かる（要件 5.3〜5.5）。
 * @property openTool 開いているツール（null は閉じている）。トリミング・回転は [cropSession] と一緒に開く。
 * @property sliderStart スライダーに触れた時の、表示中の写真の編集の内容（離すまで。離した時に 1 手として積む：要件 6.2）。
 *   null でない間は途中の保存を書かない（design.md:984）。
 * @property cropSession トリミング・回転の画面の仮の状態。null でない間は、元に戻す・やり直し・スライダー・フィルターの選択・
 *   写真の送り・「次へ」を受け付けない（design.md:731）。
 * @property loadout 装備（[LoadoutStore.loadout] を写したもの。並べるツールは [toolsToShow]）。
 * @property draftId 開いている下書きの ID（新しい編集なら null）。下書きに保存すると、この下書きを上書きする（要件 8.7）。
 * @property draftCount 今の利用者の下書きの件数（写真選択画面を自動で開かない判断に使う：利用者の判断 U7）。
 * @property leaveQuestion 画面を離れる・選び直すときの確かめ（null は出していない）。
 * @property isSavingDraft 下書きを保存しているあいだ true（`drafts_saving` を出す：要件 10.5）。
 * @property draftNotice 下書きについての案内（上限・保存の失敗・読めない下書き）。OK（[PostComposerViewModel.dismissNotice]）で消す。
 * @property sessionUnreadable 作り直した画面で、編集の途中を読めなかった（`edit_session_unreadable` を出して選び直させる：要件 12.3）。
 * @property showLoadout 装備の画面を開いている。
 * @property showDrafts 下書きの一覧を開いている。
 * @property drafts 下書きの一覧（今の利用者の分だけ・保存した日時の新しい順：要件 8.4・8.11）。
 * @property previews 写真の位置→描いた絵。表示中の写真とその両隣の分だけ（design.md:907）。トリミング・回転の画面の間の表示中の写真は、
 *   仮の回転で読み直した全体の絵（design.md:731）。
 * @property filterSamples フィルターの見本（[FILTER_OPTIONS] と同じ並びの 11 個。表示中の写真の小さな絵に、そのフィルターだけを掛けたもの）。
 *   まだ描けていなければ空。
 * @property isOpeningDraft 下書きを読み込んでいるあいだ true（`drafts_loading` を出す：要件 10.5）。
 * @property loadoutSaveFailed 装備を保存できなかった（装備の画面に `loadout_save_failed` を出す）。design.md:727 の表に無い項目
 *   （LoadoutSheet の引数 `saveFailed` に渡すために足した）。
 * @property draftSaved 下書きに保存できた（画面は閉じる：design.md「下書きの保存」の「保存できたら画面を閉じる」）。design.md:727 の表に無い項目。
 * @property draftCountLoaded 開いた時の [draftCount] の読み込みが終わった（ログインしていなくて読まない時も true）。false の間の
 *   [draftCount] の 0 は「まだ読んでいない」で、「0 件」ではない。画面は true になるまで写真選択画面を自動で開かない
 *   （利用者の判断 U7。件数は非同期で届くので、印が無いと件数より先に開いてしまう：「設計への問い」の 27）。design.md:727 の表に無い項目。
 * @property failedPreviews プレビューの土台を読めなかった写真の位置（表示中の写真とその両隣の分だけ）。[previews] に絵が無い理由が
 *   「まだ描いていない」のか「描けない」のかを見分ける印で、画面はこの位置にだけ `compose_preview_failed` を出す
 *   （利用者の決定 2026-11-14・タスク 20.6）。design.md:727 の表に無い項目。
 * @property sliderChanges スライダーに触れてから、表示中の写真の値が実際に変わった回数（同じ値が続けて届いても数えない）。
 *   [sliderStart] と一緒に、離す・写真の送り・写真の選び直しで 0 に戻す。2 回以上の間（＝指で引いている間）だけ、表示中の写真を
 *   長辺 720 の土台で描く。TalkBack の ±5・「0に戻す」・線のタップのような 1 手の操作は 1 回で離すので、長辺 1024 の描き 1 回のまま
 *   （タスク 20.5・利用者の決定 2026-11-14）。design.md:727 の表に無い項目。
 */
data class PostComposerUiState(
    val photos: List<EditingPhoto> = emptyList(),
    val exceeded: Boolean = false,
    val unreadablePositions: List<Int> = emptyList(),
    val isChecking: Boolean = false,
    val hasPicked: Boolean = false,
    val isEnteringInfo: Boolean = false,
    val caption: String = "",
    val visibility: Visibility = Visibility.PUBLIC,
    val progress: PublishProgress? = null,
    val isPublishing: Boolean = false,
    val publishError: AppError? = null,
    val published: Boolean = false,
    // ── 編集（Kiro android-edit-tools I1・design.md:727） ──
    val currentIndex: Int = 0,
    val openTool: EditTool? = null,
    val sliderStart: PhotoEdit? = null,
    val cropSession: CropSession? = null,
    val loadout: Loadout = Loadout.DEFAULT,
    val draftId: DraftId? = null,
    val draftCount: Int = 0,
    val leaveQuestion: LeaveQuestion? = null,
    val isSavingDraft: Boolean = false,
    val draftNotice: DraftNotice? = null,
    val sessionUnreadable: Boolean = false,
    val showLoadout: Boolean = false,
    val showDrafts: Boolean = false,
    val drafts: List<LocalDraftSummary> = emptyList(),
    val previews: Map<Int, PreviewImage> = emptyMap(),
    val filterSamples: List<PreviewImage?> = emptyList(),
    val isOpeningDraft: Boolean = false,
    // ── design.md:727 の表に無い項目（設計に無い決め） ──
    val loadoutSaveFailed: Boolean = false,
    val draftSaved: Boolean = false,
    val draftCountLoaded: Boolean = false,
    val failedPreviews: Set<Int> = emptySet(),
    val sliderChanges: Int = 0,
) {
    /** いまの段。 */
    val step: ComposeStep
        get() = when {
            photos.isEmpty() -> ComposeStep.SELECTING
            isEnteringInfo -> ComposeStep.INFO
            else -> ComposeStep.EDITING
        }

    /** 編集の段か。 */
    val isEditing: Boolean get() = step == ComposeStep.EDITING

    /**
     * 前後の空白を取り除いたキャプション。文字数とハッシュタグは、[PostPublisher] の検証と同じくこの値で数える
     * （画面が通して PostPublisher が断る、という食い違いを作らない）。前後の空白（TextLimits の集合）はどれも
     * ハッシュタグの単語文字でないので、ハッシュタグは素のキャプションから抽出したものと変わらない。
     */
    private val trimmedCaption: String get() = TextLimits.trimWhitespace(caption)

    /** キャプションの文字数（UTF-16 の長さ。rules の `caption.size()` と同じ単位）。 */
    val captionLength: Int get() = trimmedCaption.length

    /** キャプションが上限（2000）を超えているか（要件 7.6）。 */
    val isCaptionTooLong: Boolean get() = !TextLimits.isCaptionWithinLimit(trimmedCaption)

    /** キャプションから抽出したハッシュタグ（出現順・重複込み。[PostPublisher] が保存するものと同じ）。 */
    val hashtags: List<String> get() = HashtagExtractor.extract(trimmedCaption)

    /** ハッシュタグが上限（30 個）を超えているか（要件 7.8）。 */
    val hasTooManyHashtags: Boolean get() = !TextLimits.isHashtagCountWithinLimit(hashtags)

    /**
     * 画面を離れてよいか。アップロード中は離れさせない（戻る操作とキャンセルを効かなくする。投稿の保存中は離れてよい：ユーザー判断）。
     * 下書きを保存している間（[isSavingDraft]）も離れさせない（利用者の決定 2026-11-14・タスク 20.6）。変更の無い編集でキャンセルすると
     * 写真の選択の段へ戻り、そこから開いた写真選択画面が、保存の完了でこの画面が閉じた後も残るため。投稿情報の段から編集の段へ戻る
     * 操作も同じ値で止まる。保存が成功すれば画面は閉じ、失敗すれば案内の後で離れられる。
     */
    val canLeave: Boolean get() = progress !is PublishProgress.Uploading && !isSavingDraft

    /**
     * 投稿ボタンを押せるか。投稿情報の段で、キャプションとハッシュタグが上限以内で、進行中の投稿が無く（誰が始めたものでも）、
     * この画面の投稿が戻っておらず、成功してもいないとき（要件 7.21：処理中は送信ボタンを押せなくする）。
     * 下書きを保存している間も押せない（保存が終わると編集の途中を消して画面を閉じるので、その間に始めた投稿が写真を読めなくなる：
     * 問い 34・利用者の決定 2026-11-13）。
     */
    val canPublish: Boolean
        get() = step == ComposeStep.INFO && !isCaptionTooLong && !hasTooManyHashtags &&
            progress == null && !isPublishing && !published && !isSavingDraft

    /** 進行中の投稿が、この画面が始めたものでない（前に開いた投稿の画面で始め、保存中に離れた投稿）。 */
    val isOthersProgress: Boolean get() = progress != null && !isPublishing

    /** 表示中の写真の履歴に、元に戻せる手があるか（写真を切り替えると、切り替えた先の履歴になる：要件 6.6・6.8）。 */
    val canUndo: Boolean get() = photos.getOrNull(currentIndex)?.history?.canUndo == true

    /** 表示中の写真の履歴に、やり直せる手があるか（要件 6.6・6.8）。 */
    val canRedo: Boolean get() = photos.getOrNull(currentIndex)?.history?.canRedo == true

    /** 編集の段に並べるツール（装備のツールだけを装備の順で：要件 1.2・7.2。[EditingState.toolsToShow] を通すだけ）。 */
    val toolsToShow: List<EditTool>
        get() = EditingState.toolsToShow(loadout, photos.getOrNull(currentIndex)?.edit ?: PhotoEdit.NONE)
}

/**
 * 写真選択画面から [uris] が返ってきたときに、投稿の作成の画面ごと閉じるか。
 * この画面で一度も写真を選ばないうちに、何も選ばずに閉じたら閉じる（選ぶ写真が無い投稿の画面に留めない。タスク 21.1）。
 * 一度でも選んだ後（編集から写真の選択に戻った後や、選んだ写真が全て読めなかった後）は、何も選ばなくても留まる。
 */
fun shouldCloseAfterPicker(uris: List<String>, state: PostComposerUiState): Boolean = uris.isEmpty() && !state.hasPicked

/**
 * 投稿の作成の画面の ViewModel（設計書の部品 PostComposerViewModel。Kiro android-edit-tools design.md:970-991）。
 *
 * - 写真を選んだら、先頭の 10 枚を受け付け（[PhotoSelection.accept]）、1 枚ずつ [PhotoProbe] で読めるかを確かめる。
 *   読めない写真は投稿の対象から外し、位置を [PostComposerUiState.unreadablePositions] に残して理由を出させる（要件 6.9）。
 *   外した写真ごとに失敗を記録する（要件 15.8。iOS はログに書くだけで画面には出さない：ImagePickerService.swift:111）。
 *   読めた写真は今の利用者のフォルダへ写し（[WorkingPhotoImporter]）、編集の内容と履歴を空にして作り直す（要件 6.10）。
 *   このときに新しい途中の印（大文字の UUID）を作る。アップロード中は選んでも受け付けない（写しが先に session/ を消すため：問い 22）
 * - 選び直したら、前の選択を丸ごと置き換える。確かめている途中で選び直したら、前の確認は取りやめる（古い結果で上書きしない）。
 *   何も選ばずに写真選択画面を閉じたら、前の選択を残す
 * - 編集の操作は全部 [EditingState] の関数を呼んで [PostComposerUiState.photos] を置き換える（この ViewModel は式を持たない）。
 *   どの操作も表示中の写真（[PostComposerUiState.currentIndex]）だけに掛かる
 * - プレビュー：表示中の写真とその両隣の絵を [EditPreviewRenderer] で描く。描き直しは最新の値だけ（描いている間に来た値は、
 *   最後の 1 つだけを次に描く：design.md:908）。フィルターの見本は、表示中の写真かその回転が変わったときだけ作り直す（design.md:729）
 * - 編集の途中の保存（design.md:984）：写真・編集・キャプション・公開範囲・段が変わってから 0.5 秒後に書く。[onStop] ではすぐ書く。
 *   スライダーを動かしている間は書かない。プロセスが落ちて作り直されたら、今の利用者の途中を読み戻す（要件 12.2〜12.4）
 * - 離れるとき（[requestLeave]）は、変更があるときだけ「下書きに保存・破棄・編集を続ける」を確かめる（要件 1.7）。
 *   選び直し（[requestRepick]）は、どれかの写真に編集があるときだけ確かめる（要件 1.9）
 * - 画面名（要件 15.4）：「投稿」は画面を開いたときに 1 回（[onScreenShown]。回転で作り直されても送り直さない。
 *   iOS もタブを切り替えたときだけ送る：MainTabView.swift:87-92）。「編集」は写真の選択の段から編集の段に入るたびに 1 回（iOS の EditView も
 *   表示のたびに送る：EditView.swift:347）。下書きを開いて編集の段に入ったとき・途中を読み戻して編集の段に入ったときも同じ決まりで送る。
 *   編集の段のまま選び直したとき・投稿情報の段から戻ったときは送らない。投稿情報の段は送らない（iOS の PostInfoView も送らない。
 *   送ってよい画面名は 4 つだけ：ScreenName）。新しいイベントは送らない（design.md D-6）
 * - 投稿（タスク 23.5）：投稿情報の段の入力を [PostDraft] にして [PostPublisher.publish] を呼ぶ。成功・失敗の表示には**自分が呼んだ
 *   `publish` の戻り値だけ**を使い、共有の [PostPublisher.state] からは進行中の段階だけを拾う（[PublishProgress]）。
 *   失敗は記録しない（PostPublisher と保存の部品が記録済み）。オフラインの間は投稿を始めない（兄弟の ProfileEditViewModel の保存と同じ。
 *   始めると画像のアップロードが接続を待って止まり、アップロード中は戻る・キャンセルも効かないため。レビュー R05）。
 *   投稿と、成功の後の後始末（その投稿の途中と、開いていた下書きを消す）は [appScope] で最後まで行う（design.md:988）。
 *   後始末は `publish` を始めた時に控えた uid・途中の印・下書きの ID だけを使う（design.md:989）。失敗では何も消さない（要件 8.10）
 * - 投稿情報の段から編集の段に戻っても、キャプションと公開範囲は残す（iOS は投稿情報の画面を閉じると作り直すので消える＝差。
 *   打った文を失わない方を採った）。写真の選択の段に戻ると、写真・編集・キャプション・公開範囲を全て捨てる
 *
 * 画面の回転などで画面が作り直されても状態が消えないよう、[ViewModel] にしてある。
 * プロセスが落ちて作り直されたとき（裏に回っている間にメモリの不足で殺され、戻る履歴と一緒にこの画面が戻ったとき）のために、
 * 打った入力（キャプション・公開範囲）と、一度選んだこと（[PostComposerUiState.hasPicked]）と、編集の途中があること（KEY_HAS_SESSION）を
 * [savedState] に残し、作るときに読み戻す（全体レビュー 4 回目 Q09）。写真と編集の内容は [savedState] に入れず、端末の中のファイル
 * （[EditSessionStore]）に置く（大きさの上限がある箱に入れない：design.md:985）。
 * 写真の選択の段に戻ったとき・投稿できたときは、残した入力も捨てる（捨てた入力や、投稿済みの入力を作り直した画面に戻さない）。
 * 画面を閉じると [scope] が閉じる。保存中に閉じても、保存と後始末は [appScope] で最後まで行う（結果はこの画面に出ない）。
 *
 * @param postPublisher 投稿の公開（アプリ全体で 1 つ。前に開いた投稿の画面の投稿が、まだ保存中のことがある）。
 * @param isOnline 接続の有無（NetworkMonitor.isOnline）。オフラインの間は投稿を始めない（[publish]）。画面はオフラインの案内に使う。
 * @param savedState この画面（戻る履歴の 1 枚）の保存の箱（`createSavedStateHandle()`）。プロセスが落ちても残る。
 * @param scope この ViewModel の viewModelScope（FeedViewModel と同じ理由で外から渡す）。
 * @param sessionSaveDelayMillis 編集の途中を、変わってから書くまでの待ち（本番は 0.5 秒：design.md:984）。:app の単体テストには
 *   仮想の時計が無いので、テストは差し替える（兄弟の DefaultPostPublisher の rollbackDeleteTimeout と同じ考え方。design.md の
 *   足す引数の表に無い引数＝設計に無い決め）
 */
class PostComposerViewModel(
    private val photoProbe: PhotoProbe,
    private val analytics: AnalyticsFacade,
    private val postPublisher: PostPublisher,
    val isOnline: StateFlow<Boolean>,
    private val savedState: SavedStateHandle,
    private val scope: CoroutineScope,
    // ── 編集機能の部品（Kiro android-edit-tools 18.1） ──
    private val importer: WorkingPhotoImporter,
    private val sessionStore: EditSessionStore,
    private val drafts: LocalDraftRepository,
    private val loadoutStore: LoadoutStore,
    private val previewRenderer: EditPreviewRenderer,
    /** いまログインしている人の uid（ログインしていなければ null）。呼ぶたびに読む */
    private val currentUid: () -> Uid?,
    /** アプリの寿命のスコープ。投稿とその後始末だけに使う（画面を閉じても最後まで行う：design.md:988） */
    private val appScope: CoroutineScope,
    private val sessionSaveDelayMillis: Long = 500L,
) : ViewModel(scope) {

    // ※ ここから init までの変数は、init の中で走らせる処理が使うので、全て init より上に置く（下に置くと、init で入れた値が後の初期化で消える）

    // プロセスが落ちて作り直したときは、残した入力から始める（初めて開いたときは、どの鍵も無いので既定の値になる）
    private val mutableState = MutableStateFlow(
        PostComposerUiState(
            hasPicked = savedState.get<Boolean>(KEY_HAS_PICKED) ?: false,
            caption = savedState.get<String>(KEY_CAPTION) ?: "",
            visibility = Visibility.fromRaw(savedState.get<String>(KEY_VISIBILITY)) ?: Visibility.PUBLIC,
        ),
    )

    /** 画面の状態。 */
    val state: StateFlow<PostComposerUiState> = mutableState.asStateFlow()

    /** 画面名「投稿」を送ったか。 */
    private var postScreenLogged = false

    /** いま走っている、写真の確かめと写し、または下書きの読み込み。選び直し・写真の選択に戻ったら取りやめる。 */
    private var checkJob: Job? = null

    /**
     * 今の編集の途中の印（大文字の UUID。design.md:981）。写真を写し終えた時・下書きを開いた時・途中を読み戻した時に入れ、
     * 途中が終わった時（写真の選択に戻る・破棄・下書きの保存・投稿の成功）に null にする。null の間は途中を書かない
     * （消した session/ へ書き直さないため）。
     */
    private val sessionIdFlow = MutableStateFlow<String?>(null)

    /**
     * 写真の一覧を作り直した回数（プレビューの世代）。写しは毎回同じ場所（session/photo-N）に置くので、場所だけでは前の写真と
     * 見分けられない。世代が変わったら、描いている途中の古い絵を捨て、土台を読み直す。
     */
    private var previewGeneration = 0

    /** 読んだプレビューの土台（表示中とその両隣・フィルターの見本の分だけ）。プレビューの描き直しの中だけで触る。 */
    private val bases = HashMap<PreviewKey, PreviewBase>()

    /** 描いたプレビュー（写真の位置→描いた絵と、その元）。プレビューの描き直しの中だけで触る。 */
    private val drawn = HashMap<Int, DrawnPreview>()

    /**
     * 土台を読めなかった写真（写真の位置→そのときのプレビューの世代）。プレビューの描き直しの中だけで触る。
     * 位置だけで持つと、写真の一覧を作り直した後の別の写真に前の印が残るので、世代と組にする。
     */
    private val failed = HashMap<Int, Int>()

    /** 今のフィルターの見本の元の土台（変わったときだけ作り直す）。 */
    private var samplesKey: PreviewKey? = null

    init {
        // 共有の進み具合から、進行中の段階だけを写す（成功・失敗は写さない：PublishProgress）
        scope.launch {
            postPublisher.state.collect { publishState ->
                mutableState.update { it.copy(progress = publishState.toProgress()) }
            }
        }
        // 装備を購読する（並べるのは PostComposerUiState.toolsToShow）
        scope.launch {
            loadoutStore.loadout.collect { loadout -> mutableState.update { it.copy(loadout = loadout) } }
        }
        // プレビューの描き直し。StateFlow は描いている間に来た値を捨て、終わった時に最新の 1 つだけを渡す（design.md:908）
        scope.launch {
            mutableState
                .map { previewPlanOf(it, previewGeneration) }
                .distinctUntilChanged()
                .collect { drawPreviews(it) }
        }
        // 編集の途中の保存：書く中身が変わってから待ちの後に書く。待っている間に変わったら、待ち直す（最後の中身だけを書く）
        scope.launch {
            combine(mutableState, sessionIdFlow) { state, sessionId -> sessionContentOf(state, sessionId) }
                .distinctUntilChanged()
                .collectLatest { content ->
                    if (content == null) return@collectLatest
                    delay(sessionSaveDelayMillis)
                    writeSession(content)
                }
        }
        scope.launch { startSession() }
    }

    /** 画面の表示のたびに呼ぶ。画面名「投稿」は、この ViewModel で最初の 1 回だけ送る。 */
    fun onScreenShown() {
        if (postScreenLogged) return
        postScreenLogged = true
        analytics.logScreen(ScreenName.POST)
    }

    /**
     * 写真選択画面から戻ったときに呼ぶ。[uris] が空なら（何も選ばずに閉じたら）何もしない。
     * 読めるかを確かめる→今の利用者のフォルダへ写す→写真の一覧を作り直す（編集の内容と履歴は空：要件 6.10）。確かめと写しの間は
     * [PostComposerUiState.isChecking]（要件 1.8）。写し終えたら新しい途中の印を作り、KEY_HAS_SESSION を立てる（design.md:981・985）。
     * ログインしていない間は写さず、選んだ写真の URI のまま使う（その編集は途中も下書きも保存できない）。
     * 選んでも、前の投稿の失敗（[PostComposerUiState.publishError]）は消さない。写真選択画面を開いている間に届いた失敗は
     * まだ見せていないので、ダイアログの OK まで残す（レビュー Q07）。
     */
    fun onPhotosPicked(uris: List<String>) {
        if (uris.isEmpty()) return
        // アップロード中は受け付けない：写しが先に session/ を消し、進行中の投稿の残りの写真が読めなくなるため（問い 22・利用者の決定 2026-11-12）
        if (mutableState.value.progress is PublishProgress.Uploading) return
        // 下書きを保存している間も受け付けない：保存が終わると session/ を消して画面を閉じるので、選んだ写真が失われる（問い 34）
        if (mutableState.value.isSavingDraft) return
        val selection = PhotoSelection.accept(uris)
        checkJob?.cancel()
        mutableState.update { it.copy(hasPicked = true, isChecking = true, isOpeningDraft = false) }
        savedState[KEY_HAS_PICKED] = true
        checkJob = scope.launch {
            // 読めた写真（番号は読めた写真を詰めた並びの位置）と、読めなかった写真の選んだ順の位置（1 始まり）
            val readable = mutableListOf<PickedPhoto>()
            val unreadable = mutableListOf<Int>()
            // 1 枚ずつ順に確かめる（同時に復号する画像を 1 枚にする）
            for (photo in selection.photos) {
                when (val result = photoProbe.probe(photo)) {
                    is AppResult.Ok -> readable += PickedPhoto(photo.uri, readable.size)
                    is AppResult.Err -> {
                        analytics.logError(result.error, "$CONTEXT.onPhotosPicked")
                        unreadable += photo.index + 1
                    }
                }
            }
            val working: List<WorkingPhoto> = if (readable.isEmpty()) emptyList() else importOrKeep(currentUid(), readable)
            val wasEditing = mutableState.value.isEditing
            previewGeneration++
            sessionIdFlow.value = if (working.isEmpty()) null else newSessionId()
            mutableState.update {
                it.withPhotos(working.map { photo -> EditingPhoto(photo) }).copy(
                    exceeded = selection.exceeded,
                    unreadablePositions = unreadable,
                    isChecking = false,
                    // 選び直しは編集の段からだけ行う。投稿情報の段のまま写真が変わらないよう、編集の段に置く
                    isEnteringInfo = false,
                    sessionUnreadable = false,
                )
            }
            // 読めた写真が 0 枚なら写真の選択の段に戻るので、途中があることの印も消す（design.md:985）
            if (working.isEmpty()) savedState.remove<Boolean>(KEY_HAS_SESSION) else savedState[KEY_HAS_SESSION] = true
            if (!wasEditing && working.isNotEmpty()) analytics.logScreen(ScreenName.EDIT)
        }
    }

    /** 今の利用者のフォルダへ写す。ログインしていなければ写さず、選んだ写真の URI のまま返す（relativeFile は null）。 */
    private suspend fun importOrKeep(uid: Uid?, photos: List<PickedPhoto>): List<WorkingPhoto> =
        if (uid == null) {
            photos.map { WorkingPhoto(it.uri, relativeFile = null, capturedAt = null) }
        } else {
            importer.import(uid, photos)
        }

    // ── 編集の操作（どれも EditingState の関数を呼んで photos を置き換える。表示中の写真だけに掛かる） ──
    // 下書きを保存している間（isSavingDraft）は、編集の内容を変える操作を受け付けない。保存する文書は「下書きに保存」を押した時の
    // 内容で作り、保存できたら画面を閉じるので、その間に変えた分は失われる（問い 34・利用者の決定 2026-11-13）。
    // 写真の送り（showPhoto）とスライダーを離す操作（onSliderFinished）は止めない（編集の内容を変えない。離す操作を止めると、
    // 保存に失敗した後も sliderStart が残り、途中の保存が止まったままになる）。

    /** 表示する写真を切り替える。トリミング・回転の画面の間と、確かめている間は受け付けない。 */
    fun showPhoto(index: Int) {
        val state = mutableState.value
        if (state.cropSession != null || state.isChecking) return
        if (index !in state.photos.indices || index == state.currentIndex) return
        mutableState.update { s ->
            // スライダーを動かしている途中なら、元の写真で 1 手にしてから切り替える（触れた時の内容を別の写真の履歴に積まない）
            val photos = s.sliderStart?.let { before -> EditingState.endSlider(s.photos, s.currentIndex, before) } ?: s.photos
            s.copy(photos = photos, sliderStart = null, sliderChanges = 0, currentIndex = index)
        }
    }

    /**
     * 表示中の写真のフィルターを選ぶ（1 手）。前のフィルターを置き換え、null（「なし」）で外す。ツール・切り抜き・回転は変えない
     * （要件 2.3・2.4）。トリミング・回転の画面の間と、確かめている間は受け付けない。
     */
    fun selectFilter(filter: FilterId?) {
        val state = mutableState.value
        if (state.cropSession != null || state.isChecking || state.isSavingDraft) return
        mutableState.update { it.copy(photos = EditingState.selectFilter(it.photos, it.currentIndex, filter)) }
    }

    /**
     * ツールを開く（null で閉じる）。トリミング・回転を開くと、表示中の写真の今の回転と切り抜きから仮の状態を始める。
     * トリミング・回転の画面の間（確定か取りやめまで）と、確かめている間は受け付けない。
     */
    fun openTool(tool: EditTool?) {
        val state = mutableState.value
        if (state.cropSession != null || state.isChecking || state.isSavingDraft) return
        if (tool == EditTool.CROP_AND_ROTATE) {
            val photo = state.photos.getOrNull(state.currentIndex) ?: return
            mutableState.update { it.copy(openTool = tool, cropSession = EditingState.beginCrop(photo.edit)) }
        } else {
            mutableState.update { it.copy(openTool = tool) }
        }
    }

    /**
     * スライダーを動かした（動かしている間はプレビューだけ追従し、履歴に積まない）。最初の 1 回で、触れた時の内容を
     * [PostComposerUiState.sliderStart] に控え、値が実際に変わった回数を [PostComposerUiState.sliderChanges] に数える。
     * トリミング・回転の画面の間と、確かめている間は受け付けない。
     */
    fun onSliderChange(tool: EditTool, value: Int) {
        val state = mutableState.value
        if (state.cropSession != null || state.isChecking || state.isSavingDraft) return
        if (!tool.isSlider) return
        mutableState.update { s ->
            val photo = s.photos.getOrNull(s.currentIndex) ?: return@update s
            val photos = EditingState.slide(s.photos, s.currentIndex, tool, value)
            // 値が実際に変わった回数を数える（同じ値が続けて届いても数えない。2 回目からプレビューを長辺 720 で描く：タスク 20.5）
            val changed = photos[s.currentIndex].edit != photo.edit
            s.copy(
                sliderStart = s.sliderStart ?: photo.edit,
                sliderChanges = if (changed) s.sliderChanges + 1 else s.sliderChanges,
                photos = photos,
            )
        }
    }

    /** スライダーを離した。触れた時の内容を 1 手として積む（値が変わっていなければ積まない：要件 6.9）。 */
    fun onSliderFinished() {
        mutableState.update { s ->
            val before = s.sliderStart ?: return@update s
            s.copy(sliderStart = null, sliderChanges = 0, photos = EditingState.endSlider(s.photos, s.currentIndex, before))
        }
    }

    /** 表示中の写真の 1 手を元に戻す。トリミング・回転の画面の間と、確かめている間は受け付けない（design.md:731）。 */
    fun undo() {
        val state = mutableState.value
        if (state.cropSession != null || state.isChecking || state.isSavingDraft) return
        mutableState.update { it.copy(photos = EditingState.undo(it.photos, it.currentIndex)) }
    }

    /** 表示中の写真の、元に戻した 1 手をやり直す。トリミング・回転の画面の間と、確かめている間は受け付けない（design.md:731）。 */
    fun redo() {
        val state = mutableState.value
        if (state.cropSession != null || state.isChecking || state.isSavingDraft) return
        mutableState.update { it.copy(photos = EditingState.redo(it.photos, it.currentIndex)) }
    }

    /** トリミング・回転の画面で、取っ手か枠の中を引いた。今の範囲を起点にする（EditingState.dragCrop の約束）。 */
    fun onCropDrag(handle: CropMath.Handle, dx: Double, dy: Double) {
        mutableState.update { s ->
            val session = s.cropSession ?: return@update s
            s.copy(cropSession = EditingState.dragCrop(session, session.pending.crop, handle, dx, dy))
        }
    }

    /** トリミング・回転の画面で、辺のボタン（内側へ・外側へ）を押した。 */
    fun onCropNudge(edge: CropMath.Edge, inward: Boolean) {
        mutableState.update { s ->
            val session = s.cropSession ?: return@update s
            s.copy(cropSession = EditingState.nudgeCrop(session, edge, inward))
        }
    }

    /** トリミング・回転の画面で、左に 90° 回す（反時計回り）。 */
    fun rotateLeft() {
        mutableState.update { s ->
            val session = s.cropSession ?: return@update s
            s.copy(cropSession = EditingState.rotateCrop(session, clockwise = false))
        }
    }

    /** トリミング・回転の画面で、右に 90° 回す（時計回り）。 */
    fun rotateRight() {
        mutableState.update { s ->
            val session = s.cropSession ?: return@update s
            s.copy(cropSession = EditingState.rotateCrop(session, clockwise = true))
        }
    }

    /**
     * トリミング・回転を確定する（手の数は EditingState.confirmCrop が決める）。画面を閉じ、ツールも閉じる。
     * 下書きを保存している間は確定しない（取りやめはできる）。
     */
    fun confirmCrop() {
        if (mutableState.value.isSavingDraft) return
        mutableState.update { s ->
            val session = s.cropSession ?: return@update s
            s.copy(photos = EditingState.confirmCrop(s.photos, s.currentIndex, session), cropSession = null, openTool = null)
        }
    }

    /** トリミング・回転を取りやめる。写真は変わっていないので、仮の状態を捨てるだけ（要件 4.5）。ツールも閉じる。 */
    fun cancelCrop() {
        mutableState.update { s -> if (s.cropSession == null) s else s.copy(cropSession = null, openTool = null) }
    }

    // ── 装備 ──

    /** 装備の画面を開く。 */
    fun openLoadout() = mutableState.update { it.copy(showLoadout = true, loadoutSaveFailed = false) }

    /**
     * 装備を保存する。1 個も選ばない装備は保存しない（要件 7.5。画面も保存のボタンを押せなくする）。保存できたら装備の画面を閉じ、
     * 失敗したら `loadout_save_failed` を出す（記録は LoadoutStore.save が行う）。並びは保存の部品の流れから届く。
     */
    fun saveLoadout(loadout: Loadout) {
        if (!loadout.canSave) return
        mutableState.update { it.copy(loadoutSaveFailed = false) }
        scope.launch {
            when (loadoutStore.save(loadout)) {
                is AppResult.Ok -> mutableState.update { it.copy(showLoadout = false) }
                is AppResult.Err -> mutableState.update { it.copy(loadoutSaveFailed = true) }
            }
        }
    }

    /** 装備の画面・下書きの一覧を閉じる。 */
    fun dismissSheet() = mutableState.update { it.copy(showLoadout = false, showDrafts = false, loadoutSaveFailed = false) }

    // ── 段の行き来 ──

    /**
     * 編集の段で「次へ」を押した。写真を確かめている間と、トリミング・回転の画面の間は進まない。
     * 編集の内容と履歴は触らない（要件 1.5）。
     */
    fun goToInfo() {
        val state = mutableState.value
        if (state.step != ComposeStep.EDITING || state.isChecking) return
        if (state.cropSession != null) return
        mutableState.update { it.copy(isEnteringInfo = true) }
    }

    /**
     * 投稿情報の段から編集の段に戻る（投稿情報の画面の「キャンセル」と、端末の戻る操作）。キャプションと公開範囲、編集の内容と履歴は残す
     * （要件 1.6）。アップロード中と下書きの保存中は戻らない（[PostComposerUiState.canLeave]。投稿の保存中は戻ってよい）。投稿の失敗は消さない（ダイアログの OK でだけ消す）。
     */
    fun backToEditing() {
        val state = mutableState.value
        if (state.step != ComposeStep.INFO || !state.canLeave) return
        mutableState.update { it.copy(isEnteringInfo = false) }
    }

    /**
     * 編集の段から離れる（編集の画面の「キャンセル」と、端末の戻る操作。今までの backToSelecting の入口：design.md:977）。
     * 変更がある（[EditingState.hasWork]）ときは、すぐには離れず「下書きに保存・破棄・編集を続ける」を確かめる（要件 1.7）。
     * 変更が無ければ今と同じく写真の選択の段に戻る（選んだ写真は捨てる。一度選んだことは残すので、この後に何も選ばずに
     * 写真選択画面を閉じても、投稿の作成の画面は閉じない）。
     * 投稿の進み具合と、この画面の投稿の途中・成功・失敗は残す（[PostComposerUiState.progress] は共有の状態が変わるまで流れ直さないので、捨てると戻らない。
     * 投稿の保存中に戻った後に保存が終われば、完了のダイアログを出す）。アップロード中（要件 12.6）と下書きの保存中は戻らない
     * （[PostComposerUiState.canLeave]）。
     * 投稿の失敗（[PostComposerUiState.publishError]）は、ダイアログの OK でだけ消す（レビュー Q07）。
     */
    fun requestLeave() {
        val state = mutableState.value
        if (!state.canLeave) return
        if (EditingState.hasWork(state.photos, state.caption, state.visibility)) {
            mutableState.update { it.copy(leaveQuestion = LeaveQuestion.DISCARD_OR_DRAFT) }
            return
        }
        leaveToSelecting()
    }

    /**
     * 写真の選び直しの前に呼ぶ。どれかの写真に編集が掛かっているときだけ、選び直すかを確かめる（要件 1.9）。
     * 編集が無ければ何もしない（画面はそのまま写真選択画面を開く）。
     */
    fun requestRepick() {
        val state = mutableState.value
        if (state.photos.any { !it.edit.isNeutral }) mutableState.update { it.copy(leaveQuestion = LeaveQuestion.REPICK) }
    }

    /**
     * 確かめへの答え。続けるならダイアログを閉じるだけ。
     * - 離れるときの確かめ：下書きに保存（[saveDraft]）か、破棄（編集の途中を消して写真の選択の段に戻る：要件 12.5）
     * - 選び直しの確かめ：選び直す（[LeaveChoice.DISCARD]）ならダイアログを閉じる。写真選択画面を開くのは画面で、選んだ写真が届いたら
     *   [onPhotosPicked] が編集と履歴を空にして作り直す（要件 6.10）。何も選ばずに閉じたら、今の写真と編集のまま
     */
    fun answerLeave(choice: LeaveChoice) {
        val question = mutableState.value.leaveQuestion ?: return
        if (choice == LeaveChoice.CONTINUE) {
            mutableState.update { it.copy(leaveQuestion = null) }
            return
        }
        when (question) {
            LeaveQuestion.DISCARD_OR_DRAFT -> if (choice == LeaveChoice.SAVE_DRAFT) saveDraft() else discard()
            LeaveQuestion.REPICK -> if (choice == LeaveChoice.DISCARD) mutableState.update { it.copy(leaveQuestion = null) }
        }
    }

    /** 編集を破棄する：写真の選択の段に戻り、今の利用者の編集の途中を丸ごと消す（要件 12.5。下書きは残す：design.md:959）。 */
    private fun discard() {
        // アップロード中は離れない（要件 12.6。途中の写真を消すと、進行中の投稿が読めなくなる）。下書きの保存中も離れない（タスク 20.6）
        if (!mutableState.value.canLeave) return
        val uid = currentUid()
        leaveToSelecting()
        if (uid != null) scope.launch { sessionStore.clear(uid) }
    }

    /** 写真の選択の段に戻る。写真・編集・入力・確かめ・プレビューは捨て、投稿の進み具合と結果・装備・下書きの件数は残す。 */
    private fun leaveToSelecting() {
        checkJob?.cancel()
        previewGeneration++
        sessionIdFlow.value = null
        mutableState.update {
            PostComposerUiState(
                hasPicked = it.hasPicked,
                progress = it.progress,
                isPublishing = it.isPublishing,
                publishError = it.publishError,
                published = it.published,
                loadout = it.loadout,
                draftCount = it.draftCount,
                draftCountLoaded = it.draftCountLoaded,
            )
        }
        forgetInputs()
        savedState.remove<Boolean>(KEY_HAS_SESSION)
    }

    // ── 入力 ──

    /** キャプションの入力。上限を超えても受け付ける（[PostComposerUiState.caption]）。下書きを保存している間は受け付けない（問い 34）。 */
    fun onCaptionChange(value: String) {
        if (mutableState.value.isSavingDraft) return
        mutableState.update { it.copy(caption = value) }
        savedState[KEY_CAPTION] = value
    }

    /** 公開範囲を選ぶ。下書きを保存している間は受け付けない（問い 34）。 */
    fun selectVisibility(visibility: Visibility) {
        if (mutableState.value.isSavingDraft) return
        mutableState.update { it.copy(visibility = visibility) }
        savedState[KEY_VISIBILITY] = visibility.raw
    }

    /** 投稿の失敗のダイアログの OK（と、ダイアログの外・戻る操作）。失敗を消す（[PostComposerUiState.publishError]）。 */
    fun dismissPublishError() = mutableState.update { it.copy(publishError = null) }

    // ── 下書き ──

    /**
     * 今の編集を下書きに保存する（開いた下書きなら上書き：要件 8.7）。見本は 1 枚目の写真とその編集で作る（design.md:949）。
     * 保存できたら編集の途中を消して画面を閉じる（[PostComposerUiState.draftSaved]）。上限・失敗は案内を出し、編集の状態は変えない
     * （要件 8.16・8.17）。写せなかった写真がある編集と、ログインしていない間は、保存せずに保存の失敗を出す（design.md:933）。
     * この画面の投稿の途中（[PostComposerUiState.isPublishing]）は何もしない（案内も出さない。投稿が成功すると、同じ中身の下書きが
     * 残ってしまう。確かめのダイアログの道にも効かせるため、画面のボタンだけでなくここで止める：問い 34・利用者の決定 2026-11-13）。
     */
    fun saveDraft() {
        val state = mutableState.value
        if (state.photos.isEmpty() || state.isSavingDraft) return
        if (state.isPublishing) return
        val uid = currentUid()
        val photos = state.photos.map { it.toWorkPhoto() }
        if (uid == null || photos.any { it == null }) {
            mutableState.update { it.copy(leaveQuestion = null, draftNotice = DraftNotice.SAVE_FAILED) }
            return
        }
        val document = EditWorkDocument(
            sessionId = sessionIdFlow.value.orEmpty(),
            draftId = state.draftId?.value,
            savedAtEpochMillis = System.currentTimeMillis(),
            caption = state.caption,
            visibilityRaw = state.visibility.raw,
            enteredInfo = state.step == ComposeStep.INFO,
            photos = photos.filterNotNull(),
        )
        val first = state.photos.first()
        mutableState.update { it.copy(isSavingDraft = true) }
        scope.launch {
            // 見本を作れなければ null（記録は EditPreviewRenderer.draftThumbnail。下書きは見本なしで保存する）
            val thumbnail = previewRenderer.draftThumbnail(first.photo.toPickedPhoto(0), first.edit)
            when (drafts.save(uid, document, thumbnail)) {
                is DraftSaveResult.Saved -> {
                    // 新しい下書きを保存できた後に session/ を消すのはこの画面（design.md:942）。先に途中を書かないようにしてから消す
                    sessionIdFlow.value = null
                    savedState.remove<Boolean>(KEY_HAS_SESSION)
                    mutableState.update { it.copy(isSavingDraft = false, leaveQuestion = null, draftSaved = true) }
                    sessionStore.clear(uid)
                }
                DraftSaveResult.LimitReached ->
                    mutableState.update { it.copy(isSavingDraft = false, leaveQuestion = null, draftNotice = DraftNotice.LIMIT_REACHED) }
                is DraftSaveResult.Failed ->
                    mutableState.update { it.copy(isSavingDraft = false, leaveQuestion = null, draftNotice = DraftNotice.SAVE_FAILED) }
            }
        }
    }

    /** 下書きの一覧を開く（今の利用者の分だけ：要件 8.11。ログインしていなければ空）。 */
    fun openDrafts() {
        val uid = currentUid()
        mutableState.update { it.copy(showDrafts = true, drafts = emptyList()) }
        if (uid != null) scope.launch { showDraftList(uid) }
    }

    /**
     * 下書きを開く。読み込んでいる間は [PostComposerUiState.isOpeningDraft]。開けたら写真・編集・キャプション・公開範囲を戻し
     * （履歴は空：要件 8.19）、新しい途中の印で編集の段から始める（design.md:981）。読めなければ `drafts_broken` の案内を出す。
     * 進行中の投稿がある間（[PostComposerUiState.progress] が null でない間）は受け付けない（投稿中の下書きを開き、その後に
     * 後始末で消される、を起こさない：design.md:990。下書きを開く操作も先に session/ を消すので、アップロード中も止まる）。
     */
    fun openDraft(id: DraftId) {
        val state = mutableState.value
        if (state.progress != null) return
        if (state.isOpeningDraft) return
        val uid = currentUid() ?: return
        checkJob?.cancel()
        mutableState.update { it.copy(isOpeningDraft = true, isChecking = false) }
        checkJob = scope.launch {
            when (val opened = drafts.open(uid, id)) {
                is DraftOpenResult.Opened -> startDraft(id, opened)
                DraftOpenResult.Broken ->
                    mutableState.update { it.copy(isOpeningDraft = false, draftNotice = DraftNotice.DRAFT_BROKEN) }
            }
        }
    }

    /** 開いた下書きで編集を始める。途中の文書は印が空なので、新しい印で作り直す（次の途中の保存で書く）。 */
    private fun startDraft(id: DraftId, opened: DraftOpenResult.Opened) {
        val document = opened.document
        val wasEditing = mutableState.value.isEditing
        val visibility = Visibility.fromRaw(document.visibilityRaw) ?: Visibility.PUBLIC
        previewGeneration++
        sessionIdFlow.value = newSessionId()
        mutableState.update {
            it.withPhotos(opened.photos.zip(document.photos) { photo, saved -> EditingPhoto(photo, saved.edit) }).copy(
                caption = document.caption,
                visibility = visibility,
                isEnteringInfo = false,
                draftId = id,
                hasPicked = true,
                exceeded = false,
                unreadablePositions = emptyList(),
                isOpeningDraft = false,
                showDrafts = false,
                sessionUnreadable = false,
            )
        }
        savedState[KEY_HAS_PICKED] = true
        savedState[KEY_CAPTION] = document.caption
        savedState[KEY_VISIBILITY] = visibility.raw
        savedState[KEY_HAS_SESSION] = true
        if (!wasEditing && mutableState.value.isEditing) analytics.logScreen(ScreenName.EDIT)
    }

    /** 下書きを消して、一覧を読み直す（失敗の記録は LocalDraftRepository.delete が行う）。 */
    fun deleteDraft(id: DraftId) {
        // アップロード中は下書きを消さない。開いた下書きから始めた投稿は、写真を下書きのフォルダから直に読むので、
        // 消すと送っている途中の写真が無くなる（利用者の決定 2026-11-13。写真の選択の止めと同じ扱い）
        if (mutableState.value.progress is PublishProgress.Uploading) return
        val uid = currentUid() ?: return
        scope.launch {
            drafts.delete(uid, id)
            showDraftList(uid)
        }
    }

    /** 下書きと編集の途中についての案内の OK。下書きの案内と、途中を読めなかった案内を消す。 */
    fun dismissNotice() = mutableState.update { it.copy(draftNotice = null, sessionUnreadable = false) }

    private suspend fun showDraftList(uid: Uid) {
        val list = drafts.list(uid)
        mutableState.update { it.copy(drafts = list, draftCount = list.size) }
    }

    // ── 投稿 ──

    /**
     * 投稿情報の段の入力のまま投稿する。押せないとき（[PostComposerUiState.canPublish]）は何もしない（二重に送らない）。
     * オフラインの間も何もしない（画面も投稿ボタンを押せなくする。兄弟の ProfileEditViewModel.save と同じく、
     * [PostComposerUiState.canPublish] には接続を入れず、ここと画面の 2 か所で接続を見る。レビュー R05）。
     * キャプションは入力欄の値をそのまま渡す（前後の空白は PostPublisher が取り除く）。
     * 成功したら、その投稿の編集の途中と開いていた下書きを消し（要件 8.9）、履歴を空にする（要件 6.10）。失敗では何も消さない（要件 8.10）。
     */
    fun publish() {
        val state = mutableState.value
        if (!state.canPublish || !isOnline.value) return
        // 後始末に使う値は、始めた時に 1 回だけ控える（design.md:989）。後始末の時に読み直すと、ログアウトの後は null か別の人の uid になる。
        // 保存中に開き直した画面が次の写真を選ぶと新しい印の途中ができるので、控えた印の途中だけを消す
        val cleanup = PostCleanup(uid = currentUid(), sessionId = sessionIdFlow.value, draftId = state.draftId)
        mutableState.update { it.copy(isPublishing = true, publishError = null) }
        // 番号は画面に出ている並びの位置（0 始まり）。撮影日時は 1 枚目を写した時に読んだ値（design.md:987）
        val draft = PostDraft(
            photos = state.photos.mapIndexed { index, photo -> PostPhoto(photo.photo.toPickedPhoto(index), photo.edit) },
            caption = state.caption,
            visibility = state.visibility,
            firstPhotoCapturedAt = state.photos.first().photo.capturedAt,
        )
        // 投稿と後始末はアプリの寿命のスコープで最後まで行う（保存中に画面を閉じても、後始末だけが取り消されないように：design.md:988）
        val running = appScope.async {
            val result = postPublisher.publish(draft)
            if (result is AppResult.Ok) cleanUpAfterPost(cleanup)
            result
        }
        // 結果を画面へ写す所だけ、この画面のスコープ（閉じた後は写さない）
        scope.launch {
            val result = running.await()
            if (result is AppResult.Ok) sessionIdFlow.value = null
            mutableState.update {
                when (result) {
                    is AppResult.Ok -> it.copy(
                        isPublishing = false,
                        published = true,
                        photos = it.photos.map { photo -> photo.copy(history = EditHistory.EMPTY) },
                    )
                    is AppResult.Err -> it.copy(isPublishing = false, publishError = result.error)
                }
            }
            if (result is AppResult.Ok) {
                forgetInputs()
                savedState.remove<Boolean>(KEY_HAS_SESSION)
            }
        }
    }

    /**
     * 投稿の成功の後始末（[appScope] の中で呼ぶ）。控えた uid・途中の印・下書きの ID だけを使う（design.md:989）。
     * 編集の途中は印つきで消し（[EditSessionStore.clearSession]。印が違う＝新しい編集の途中なら消さない。丸ごと消す clear は使わない）、
     * 開いていた下書きを消す（design.md:960）。どちらも例外を投げない／失敗は部品が記録する。
     */
    private suspend fun cleanUpAfterPost(cleanup: PostCleanup) {
        val uid = cleanup.uid ?: return
        cleanup.sessionId?.let { sessionStore.clearSession(uid, it) }
        cleanup.draftId?.let { drafts.delete(uid, it) }
    }

    /** 残した入力（キャプション・公開範囲）を捨てる。一度選んだことは残す（写真の選択の段に戻った後も残すのと同じ）。 */
    private fun forgetInputs() {
        savedState.remove<String>(KEY_CAPTION)
        savedState.remove<String>(KEY_VISIBILITY)
    }

    // ── 編集の途中の保存と作り直し ──

    /** 画面が止まった（裏に回った）ときに呼ぶ。待たずにすぐ書く（design.md:984）。スライダーを動かしている間は書かない。 */
    fun onStop() {
        val content = sessionContentOf(mutableState.value, sessionIdFlow.value) ?: return
        scope.launch { writeSession(content) }
    }

    /** 今の利用者のフォルダへ途中を書く（失敗の記録は EditSessionStore.save が行い、画面には出さない）。 */
    private suspend fun writeSession(content: SessionContent) {
        val uid = currentUid() ?: return
        sessionStore.save(uid, content.toDocument(System.currentTimeMillis()))
    }

    /**
     * 開いた時に 1 回。作り直された（KEY_HAS_SESSION が真）なら今の利用者の途中を読み戻す。初めて開いた（鍵が無い）なら、
     * 前の画面が残した途中を消す（design.md:986）。ただしアップロード中は消さない（問い 22・利用者の決定 2026-11-12：進行中の投稿が
     * 写真を読んでいる）。見送った途中は、次の写し（WorkingPhotoImporter）と下書きを開く操作が先に消すので、後でやり直さない。
     * 最後に、今の利用者の下書きの件数を読む。
     */
    private suspend fun startSession() {
        val uid = currentUid()
        if (savedState.get<Boolean>(KEY_HAS_SESSION) == true) {
            restoreSession(uid)
        } else if (uid != null && postPublisher.state.value !is PublishState.Uploading) {
            sessionStore.clear(uid)
        }
        if (uid != null) showDraftCount(uid)
        // 読まない時（ログインしていない）も立てる。画面はこの印を待ってから、写真選択画面を自動で開くかを決める（利用者の判断 U7）
        mutableState.update { it.copy(draftCountLoaded = true) }
    }

    /**
     * 作り直された画面で、今の利用者の途中を読み戻す（要件 12.2・12.4。ほかの uid のフォルダは読まない）。
     * 読めたら編集の段か投稿情報の段に戻す（履歴は空）。読めない・無い・ログインしていないなら、案内を出して写真の選択の段から（要件 12.3）。
     * キャプションと公開範囲は、残した入力があればそれを使う（打つたびに残すので、0.5 秒待って書く途中の文書より新しい）。
     */
    private suspend fun restoreSession(uid: Uid?) {
        val loaded = if (uid == null) SessionLoad.None else sessionStore.load(uid)
        if (loaded !is SessionLoad.Restored) {
            savedState.remove<Boolean>(KEY_HAS_SESSION)
            mutableState.update { it.copy(sessionUnreadable = true) }
            return
        }
        val document = loaded.document
        val caption = savedState.get<String>(KEY_CAPTION) ?: document.caption
        val visibility = Visibility.fromRaw(savedState.get<String>(KEY_VISIBILITY))
            ?: Visibility.fromRaw(document.visibilityRaw)
            ?: Visibility.PUBLIC
        previewGeneration++
        // 印が空の文書（下書きを開いた直後に落ちたなど：EditDocumentCodec.decodeWork）は、新しい印で作り直す
        sessionIdFlow.value = document.sessionId.ifEmpty { newSessionId() }
        mutableState.update {
            it.withPhotos(loaded.photos.zip(document.photos) { photo, saved -> EditingPhoto(photo, saved.edit) }).copy(
                caption = caption,
                visibility = visibility,
                isEnteringInfo = document.enteredInfo,
                draftId = document.draftId?.let { id -> DraftId(id) },
                hasPicked = true,
            )
        }
        savedState[KEY_HAS_PICKED] = true
        if (mutableState.value.isEditing) analytics.logScreen(ScreenName.EDIT)
    }

    private suspend fun showDraftCount(uid: Uid) {
        val list = drafts.list(uid)
        mutableState.update { it.copy(draftCount = list.size) }
    }

    /** 途中に書く中身。書けないとき（写真が無い・途中の印が無い・スライダーの途中・写せなかった写真がある）は null。 */
    private fun sessionContentOf(state: PostComposerUiState, sessionId: String?): SessionContent? {
        if (sessionId == null || state.photos.isEmpty()) return null
        if (state.sliderStart != null) return null
        val photos = state.photos.map { it.toWorkPhoto() ?: return null }
        return SessionContent(
            sessionId = sessionId,
            draftId = state.draftId,
            photos = photos,
            caption = state.caption,
            visibility = state.visibility,
            enteredInfo = state.step == ComposeStep.INFO,
        )
    }

    /** 文書の写真 1 枚。写せなかった写真（relativeFile が null）は null（その編集は途中も下書きも保存できない：design.md:933）。 */
    private fun EditingPhoto.toWorkPhoto(): EditWorkPhoto? {
        val file = photo.relativeFile ?: return null
        return EditWorkPhoto(
            file = file,
            capturedAtEpochMillis = photo.capturedAt?.instant?.toEpochMilli(),
            capturedAtSourceRaw = (photo.capturedAt?.source ?: CapturedAtSource.NONE).raw,
            edit = edit,
        )
    }

    private fun newSessionId(): String = UUID.randomUUID().toString().uppercase(Locale.ROOT)

    /** 写真の一覧を作り直す（表示の位置・開いたツール・スライダー・トリミング・確かめ・絵を初めに戻す。編集の内容と履歴は渡したもの）。 */
    private fun PostComposerUiState.withPhotos(photos: List<EditingPhoto>): PostComposerUiState = copy(
        photos = photos,
        currentIndex = 0,
        openTool = null,
        sliderStart = null,
        sliderChanges = 0,
        cropSession = null,
        leaveQuestion = null,
        previews = emptyMap(),
        failedPreviews = emptySet(),
        filterSamples = emptyList(),
    )

    // ── プレビュー（表示中の写真とその両隣・フィルターの見本） ──

    /**
     * 描くものの全部。表示中の写真を先に、両隣を後に並べる。トリミング・回転の画面の間の表示中の写真は仮の回転で読む（design.md:731）。
     * スライダーを指で引いている間（[PostComposerUiState.sliderStart] があり、値が [DRAG_PREVIEW_MIN_CHANGES] 回以上変わった間）は、
     * 表示中の写真だけを長辺 [DRAG_PREVIEW_LONG_EDGE] の土台で描き、離したら長辺 1024 の土台で描き直す（design.md:1157・タスク 20.5・
     * 利用者の決定 2026-11-14）。両隣は値が変わらないので 1024 のまま。1024 の土台は引いている間も残す（[drawPreviews]）
     */
    private fun previewPlanOf(state: PostComposerUiState, generation: Int): PreviewPlan {
        val current = state.photos.getOrNull(state.currentIndex) ?: return PreviewPlan(emptyList(), null)
        val dragging = state.sliderStart != null && state.sliderChanges >= DRAG_PREVIEW_MIN_CHANGES
        val targets = listOf(state.currentIndex, state.currentIndex - 1, state.currentIndex + 1)
            .filter { it in state.photos.indices }
            .map { index ->
                val photo = state.photos[index]
                val turns = state.cropSession?.takeIf { index == state.currentIndex }?.pending?.quarterTurns
                    ?: photo.edit.geometry.quarterTurns
                val longEdge = if (dragging && index == state.currentIndex) {
                    DRAG_PREVIEW_LONG_EDGE
                } else {
                    EditPreviewRenderer.PREVIEW_LONG_EDGE
                }
                PreviewTarget(
                    key = PreviewKey(generation, index, photo.photo, turns, longEdge),
                    recipe = ColorRecipe.of(photo.edit),
                )
            }
        // フィルターの見本は、表示中の写真とその回転だけで決まる（ツールの値では作り直さない：design.md:729）
        val samples = PreviewKey(
            generation,
            state.currentIndex,
            current.photo,
            current.edit.geometry.quarterTurns,
            EditPreviewRenderer.FILTER_SAMPLE_EDGE,
        )
        return PreviewPlan(targets, samples)
    }

    /** 1 回分の描き直し。窓の外と前の世代の絵を捨て、変わった絵だけを描き、最後にフィルターの見本を描く。 */
    private suspend fun drawPreviews(plan: PreviewPlan) {
        val wanted = plan.previews.associateBy { it.key.index }
        // 捨てるのは、窓の外へ出た位置と、別の写真・回転・世代になった位置の絵。長辺だけが違う絵（指で引き始めた・離した）は、
        // 新しい絵で置き換わるまで残す（捨てると、描き直す間だけ写真が消えて背景の色だけになる：タスク 20.5・利用者の決定 2026-11-14）
        val stale = drawn.filter { (index, done) -> wanted[index]?.key?.sameImageAs(done.target.key) != true }.keys
        drawn.keys.removeAll(stale)
        // 描けない印は、窓の外へ出た位置と前の世代の分だけ外す。同じ写真の印はここでは外さない（読めない写真は計画のたびに
        // 読み直すので、頭で外すと、スライダーを動かすたびに文言が消えて出る）。外すのは描けた時
        failed.entries.removeAll { (index, generation) -> wanted[index]?.key?.generation != generation }
        val keep = plan.previews.mapTo(HashSet()) { it.key }
        // 長辺 720 で描いている間も、同じ写真の長辺 1024 の土台は残す（離した時に読み直さず、描くだけにする：タスク 20.5・
        // 利用者の決定 2026-11-14）。読んでいなければ残すものは無い
        plan.previews.forEach { target ->
            if (target.key.longEdge != EditPreviewRenderer.PREVIEW_LONG_EDGE) {
                keep += target.key.copy(longEdge = EditPreviewRenderer.PREVIEW_LONG_EDGE)
            }
        }
        plan.samples?.let { keep += it }
        bases.keys.retainAll(keep)
        publishPreviews()
        for (target in plan.previews) {
            if (drawn[target.key.index]?.target == target) continue
            val base = baseFor(target.key)
            // 読んでいる間に写真の一覧を作り直した：この計画の残りは描かない（次の計画で描き直す）
            if (target.key.generation != previewGeneration) return
            if (base == null) {
                // 土台を読めなかった：この位置に「描けない」の印を付ける（画面が compose_preview_failed を出す：タスク 20.6）。
                // 長辺だけが違う古い絵を残していたら外す（古い絵と「描けない」の印を同時に立てない：タスク 20.5）
                drawn.remove(target.key.index)
                failed[target.key.index] = target.key.generation
                publishPreviews()
                continue
            }
            val pixels = previewRenderer.render(base, target.recipe)
            // 描いている間に写真の一覧を作り直した：古い写真の絵は書かない（次の計画で描き直す）
            if (target.key.generation != previewGeneration) return
            drawn[target.key.index] = DrawnPreview(target, PreviewImage(pixels, base.width, base.height))
            failed.remove(target.key.index)
            publishPreviews()
        }
        drawSamples(plan.samples)
    }

    private fun publishPreviews() {
        val images = drawn.mapValues { it.value.image }
        val unreadable = failed.keys.toSet()
        val now = mutableState.value
        if (now.previews != images || now.failedPreviews != unreadable) {
            mutableState.update { it.copy(previews = images, failedPreviews = unreadable) }
        }
    }

    /** 土台を読む（読んだものは使い回す）。読めない写真は絵を出さない（読み込みの失敗は記録しない：設計への問い 19 の②）。 */
    private suspend fun baseFor(key: PreviewKey): PreviewBase? {
        bases[key]?.let { return it }
        val base = when (val loaded = previewRenderer.loadBase(key.photo.toPickedPhoto(key.index), key.quarterTurns, key.longEdge)) {
            is AppResult.Ok -> loaded.value
            is AppResult.Err -> return null
        }
        if (key.generation != previewGeneration) return null
        bases[key] = base
        return base
    }

    /** フィルターの見本を、表示中の写真か回転が変わったときだけ作り直す（選択肢ごとに、そのフィルターだけを掛ける：design.md:729）。 */
    private suspend fun drawSamples(key: PreviewKey?) {
        if (key == samplesKey) return
        samplesKey = key
        if (mutableState.value.filterSamples.isNotEmpty()) mutableState.update { it.copy(filterSamples = emptyList()) }
        if (key == null) return
        val base = baseFor(key) ?: return
        val samples = mutableListOf<PreviewImage?>()
        for (option in FILTER_OPTIONS) {
            val pixels = previewRenderer.render(base, ColorRecipe.of(PhotoEdit(filter = option)))
            if (key.generation != previewGeneration) return
            samples += PreviewImage(pixels, base.width, base.height)
        }
        mutableState.update { it.copy(filterSamples = samples) }
    }

    /** プレビューの土台の鍵（写真の一覧の世代・位置・写真・回転・長辺）。 */
    private data class PreviewKey(val generation: Int, val index: Int, val photo: WorkingPhoto, val quarterTurns: Int, val longEdge: Int) {
        /** 長辺のほかが同じ（同じ世代・位置・写真・回転の絵で、細かさだけが違う）。 */
        fun sameImageAs(other: PreviewKey): Boolean = copy(longEdge = other.longEdge) == other
    }

    /** 描く 1 枚（土台と色）。 */
    private data class PreviewTarget(val key: PreviewKey, val recipe: ColorRecipe)

    /** 描いた 1 枚と、その元。 */
    private class DrawnPreview(val target: PreviewTarget, val image: PreviewImage)

    /** 1 回分の描くもの（表示中とその両隣のプレビュー・フィルターの見本の土台）。 */
    private data class PreviewPlan(val previews: List<PreviewTarget>, val samples: PreviewKey?)

    /** 途中に書く中身（書いた日時を除く。同じ中身なら書き直さない）。 */
    private data class SessionContent(
        val sessionId: String,
        val draftId: DraftId?,
        val photos: List<EditWorkPhoto>,
        val caption: String,
        val visibility: Visibility,
        val enteredInfo: Boolean,
    ) {
        fun toDocument(savedAtEpochMillis: Long) = EditWorkDocument(
            sessionId = sessionId,
            draftId = draftId?.value,
            savedAtEpochMillis = savedAtEpochMillis,
            caption = caption,
            visibilityRaw = visibility.raw,
            enteredInfo = enteredInfo,
            photos = photos,
        )
    }

    /** 投稿の後始末に使う値（publish を始めた時に 1 回だけ控える：design.md:989）。 */
    private data class PostCleanup(val uid: Uid?, val sessionId: String?, val draftId: DraftId?)

    private companion object {
        const val CONTEXT = "PostComposerViewModel"

        /** [savedState] の鍵（打ったキャプション・公開範囲の raw・一度選んだか・編集の途中があるか）。 */
        const val KEY_CAPTION = "caption"
        const val KEY_VISIBILITY = "visibility"
        const val KEY_HAS_PICKED = "hasPicked"
        const val KEY_HAS_SESSION = "hasSession"

        /**
         * スライダーを動かしている間の、表示中の写真のプレビューの土台の長辺（design.md:1157・タスク 20.5・利用者の決定 2026-11-14）。
         * 実機（デバッグ版）の描き直し（render）の測りで、長辺 1024 のおよそ半分の時間だった（タスク 21）。それでも目安の 100 ミリ秒には
         * 届かない。引き始めに 720 の土台を読む時間は測っていない（離した時は、残しておいた 1024 の土台で描くので読み直さない）
         */
        const val DRAG_PREVIEW_LONG_EDGE = 720

        /**
         * 長辺 [DRAG_PREVIEW_LONG_EDGE] で描き始める、値が変わった回数（タスク 20.5・利用者の決定 2026-11-14）。1 回で離す 1 手の操作
         * （TalkBack の ±5・「0に戻す」・線のタップ）は 720 に切り替えず、長辺 1024 の描き 1 回のまま。代わりに、指で引くたびに
         * 最初の 1 枚は長辺 1024 で描く
         */
        const val DRAG_PREVIEW_MIN_CHANGES = 2
    }
}

/** 共有の進み具合のうち、進行中の段階だけを [PublishProgress] にする（それ以外は null）。 */
private fun PublishState.toProgress(): PublishProgress? = when (this) {
    is PublishState.Uploading -> PublishProgress.Uploading(done, total)
    PublishState.Saving -> PublishProgress.Saving
    PublishState.Idle,
    is PublishState.Succeeded,
    is PublishState.Failed,
    -> null
}
