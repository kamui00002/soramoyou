// ⭐️ 投稿の作成の画面（タスク 21.1 で写真の選択・タスク 21.2 でプレビューとフィルター・タスク 23.5 で投稿情報と送信・Kiro android-edit-tools I2〔19.1〕で編集の部品・下書き・装備）（android-ui-ios-parity タスク 12.2・要件 5.1）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.PagerState
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.edit.CropMath
import com.yoshidometoru.soramoyou.contract.edit.EditHistory
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.Loadout
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.edit.DraftId
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/**
 * 投稿の作成の画面。写真の選択→編集（プレビュー・フィルター・ツール・トリミングと回転）→「次へ」→投稿情報（キャプション・公開範囲・投稿ボタン）の
 * 3 段を [PostComposerUiState.step] で切り替える（iOS の PostView→EditView→PostInfoView と同じ。タスク 23.5）。
 * 状態と操作は全て引数で受ける（ViewModel を参照しない。SoramoyouApp が ViewModel の公開の関数をつなぐ：design.md:733）。
 *
 * 写真の選択：
 * - 写真選択画面を自動で開くかは、下書きの件数を読み終えてから 1 回だけ決める。下書きが 0 件で、写真がまだ無いときだけ開く
 *   （要件 6.1・利用者の判断 U7。件数は非同期で届くので、読み終える前の 0 は「まだ読んでいない」と読む。プロセスが落ちて作り直し、
 *   途中を読み戻したときは写真があるので開かない）。開かなかったときも、決めたことを [rememberSaveable] で覚える
 *   （画面の回転や、後で下書きを全部消したときに、思いがけず開かないため）
 * - 写真選択画面には上限 10 枚を渡す（要件 6.3）。上限が効かない別の選択画面に代わった場合のために、受け取った側でも
 *   [PhotoSelection.accept] で検査する（要件 6.4）
 * - 何も選ばずに写真選択画面を閉じたときは、一度も選んでいなければ画面も閉じる（[shouldCloseAfterPicker]）。ただし下書きがあれば
 *   閉じない（利用者の判断 U7。件数をまだ読み終えていないときも、下書きがあるかもしれないので閉じない）
 * - 下書きが 1 件以上あれば「下書き（n件）」のボタンを出し、下書きの一覧を投稿の画面の上に重ねて開く（新しい行き先を足さない）
 *
 * 編集の段：
 * - 表示中の写真は [PostComposerUiState.currentIndex] が決める。プレビューを送ったら ViewModel に知らせ、受け付けられなかったとき
 *   （写真を確かめている間）や、ViewModel が位置を変えたとき（選び直しで 1 枚目に戻る）は、止まったプレビューを位置に合わせ直す
 * - 写真を確かめている間とトリミング・回転の画面の間は、編集の操作と「次へ」を無効にする（要件 1.8・design.md:731）。
 *   フィルターの選択肢は無効の形を持たないので、その間は出さない。トリミング・回転の画面の間は、プレビューの代わりに
 *   トリミング・回転の部品（全体の絵と枠を自分で描く）を出す
 * - 選び直しは、どれかの写真に編集があるときだけ確かめる（要件 1.9）。確かめが出なければそのまま写真選択画面を開き、
 *   確かめで「選び直す」を選んだら、その後に開く
 * - 装備の画面は投稿の画面の上に重ねる（新しい行き先を足さない）
 *
 * 離れるとき：
 * - 編集の段では、「キャンセル」と端末の戻る操作で離れる。変更があれば「下書きに保存・破棄・編集を続ける」を確かめる（要件 1.7）。
 *   トリミング・回転の画面の間は、トリミング・回転を取りやめる（その部品のキャンセルと同じ。編集の内容は変わらない）
 * - 投稿情報の段では、「キャンセル」と端末の戻る操作で編集の段に戻る（iOS の投稿情報の画面を閉じると編集の画面に戻るのと同じ）
 * - アップロード中と下書きを保存している間は、戻る操作とキャンセルを効かなくする（[PostComposerUiState.canLeave]。投稿の保存中は
 *   離れてよい：ユーザー判断。下書きの保存中は、どの段でも離れさせない：利用者の決定 2026-11-14・タスク 20.6）
 * - 下書きに保存できたら画面を閉じる（design.md「下書きに保存」：保存できたら投稿の画面を閉じる）
 * - 画面が止まった（裏に回った）ときは ViewModel に知らせ、編集の途中を待たずに書かせる（design.md:984）
 *
 * 投稿：
 * - 投稿が成功したら、見出しの無いダイアログで「投稿が完了しました」を出し、OK で画面を閉じる。iOS は見出し（「投稿完了」）付きの
 *   alert を、見出しの無い重ね表示（PostCompletionOverlay。チェックマークを描いて約 1.2 秒で自動で閉じる：PostInfoView.swift:220-233）に
 *   替えたので、見出しだけを外した（自動で閉じる演出は合わせない。2026-11-06 の利用者の決定。PostPublishedDialogSourceTest が見る）。
 *   ダイアログの外を押したり戻る操作をしたりしても閉じる（投稿はもう終わっているので、この画面に留める理由が無い）
 * - 投稿の失敗は、成功と同じく段によらず「エラー」のダイアログで出し、OK で消す（iOS：PostInfoView.swift:184-192）。
 *   保存中に段を離れ、写真選択画面を開いている間に届いた失敗も、戻ったときに見える（レビュー R18・Q07）。
 *   文言は [postErrorText] で決め、何枚目の写真で失敗したかも出す（design.md:894）
 * - オフラインの間は投稿ボタンを押せなくし、その理由を出す。アップロード中に切れたときも出す（レビュー R05）
 *
 * 画像だけを選ばせる（`ImageOnly`）。動画は投稿できないため（iOS も画像だけ）。
 * 中身は縦に送れるようにして、文字を大きくしてもボタンが画面の外で押せなくならないようにする（要件 16.6）。
 *
 * @param isOnline 接続の有無。オフラインの間は投稿ボタンを押せなくし「ネットワークに接続できません」を出す（アップロード中も出す）。
 *   保存中かつオフラインのときは「接続が戻ると保存を続けます」を出す。
 * @param onStop 画面が止まった（裏に回った）ときに呼ぶ（ViewModel の onStop。編集の途中をすぐ書く）。
 * @param onRequestRepick 選び直しの前に呼ぶ。呼んだ直後の確かめ（出なければ null）を返す。null なら画面はそのまま写真選択画面を開く。
 * @param onShowPhoto 表示する写真を切り替えた（プレビューを送った）ときに、その位置（0 始まり）で呼ぶ。
 * @param onRequestLeave 編集の段から離れる（「キャンセル」と端末の戻る操作）。変更があれば ViewModel が確かめを出す。
 * @param onAnswerLeave 確かめへの答え。
 * @param onSaveDraft 編集の段と投稿情報の段の「下書きに保存」（要件 8.1）。
 * @param onSaveLoadout 装備の画面の保存（選んだツールを並びの順に並べた装備を渡す）。
 * @param onDismissSheet 装備の画面と下書きの一覧を閉じる。
 * @param onDismissNotice 下書きについての案内と、編集の途中を読めなかった案内の OK。
 */
@Composable
fun PostComposerScreen(
    state: PostComposerUiState,
    isOnline: Boolean,
    onScreenShown: () -> Unit,
    onStop: () -> Unit,
    onPhotosPicked: (List<String>) -> Unit,
    onRequestRepick: () -> LeaveQuestion?,
    onShowPhoto: (Int) -> Unit,
    onSelectFilter: (FilterId?) -> Unit,
    onOpenTool: (EditTool?) -> Unit,
    onSliderChange: (EditTool, Int) -> Unit,
    onSliderFinished: () -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onCropDrag: (CropMath.Handle, Double, Double) -> Unit,
    onCropNudge: (CropMath.Edge, Boolean) -> Unit,
    onRotateLeft: () -> Unit,
    onRotateRight: () -> Unit,
    onConfirmCrop: () -> Unit,
    onCancelCrop: () -> Unit,
    onRequestLeave: () -> Unit,
    onAnswerLeave: (LeaveChoice) -> Unit,
    onSaveDraft: () -> Unit,
    onOpenDrafts: () -> Unit,
    onOpenDraft: (DraftId) -> Unit,
    onDeleteDraft: (DraftId) -> Unit,
    onOpenLoadout: () -> Unit,
    onSaveLoadout: (Loadout) -> Unit,
    onDismissSheet: () -> Unit,
    onDismissNotice: () -> Unit,
    onGoToInfo: () -> Unit,
    onBackToEditing: () -> Unit,
    onCaptionChange: (String) -> Unit,
    onSelectVisibility: (Visibility) -> Unit,
    onPublish: () -> Unit,
    onDismissPublishError: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pickPhotos = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(maxItems = TextLimits.IMAGES_MAX),
    ) { uris ->
        val picked = uris.map { it.toString() }
        if (shouldCloseAfterPicker(picked, state) && state.draftCountLoaded && state.draftCount == 0) onClose() else onPhotosPicked(picked)
    }
    // 写真選択画面を開いたか、自動で開くかを決め終えたか。画面の回転で作り直されても、開き直さない・決め直さない
    var pickerOpened by rememberSaveable { mutableStateOf(false) }
    val launchPicker: () -> Unit = {
        pickerOpened = true
        pickPhotos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
    }
    LaunchedEffect(Unit) { onScreenShown() }
    // 自動で開くかは、下書きの件数を読み終えた時に 1 回だけ決める（利用者の判断 U7。読み終える前の 0 件で開いてしまわないため）
    LaunchedEffect(state.draftCountLoaded) {
        if (state.draftCountLoaded && !pickerOpened) {
            pickerOpened = true
            if (state.draftCount == 0 && state.photos.isEmpty()) launchPicker()
        }
    }
    // 裏に回ったら、編集の途中を待たずに書かせる（design.md:984。この画面の戻る履歴の 1 枚が止まった時）
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { onStop() }
    // 下書きに保存できたら閉じる（保存に失敗したら留まる：要件 8.17）
    LaunchedEffect(state.draftSaved) { if (state.draftSaved) onClose() }

    // 送りの位置は編集の段と投稿情報の段で 1 つを共有する（段を行き来しても同じ写真を見せ、描いてある絵と食い違わせない）。
    // 写真の並びが変わったら作り直し、表示中の写真の位置から始める
    val pagerState = key(state.photos.map { it.photo }) {
        rememberPagerState(initialPage = state.currentIndex) { state.photos.size }
    }
    val showPhoto by rememberUpdatedState(onShowPhoto)
    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.currentPage }.collect { page -> showPhoto(page) }
    }
    // 表示中の写真の真実は ViewModel の位置。送りが止まった時に食い違っていれば合わせ直す
    // （確かめている間は送りを受け付けない。選び直しで写しの場所が前と同じになると、並びが等しく、送りの位置が作り直されない）
    LaunchedEffect(pagerState, state.currentIndex, pagerState.isScrollInProgress) {
        if (!pagerState.isScrollInProgress && pagerState.currentPage != state.currentIndex && state.currentIndex < pagerState.pageCount) {
            pagerState.scrollToPage(state.currentIndex)
        }
    }

    // 選び直し：確かめが出なければ、そのまま写真選択画面を開く（出たら、確かめの答えの後に開く：下の LeaveDialog）
    val repick: () -> Unit = { if (onRequestRepick() == null) launchPicker() }

    // 写真の選択の段では、戻る操作は画面を閉じる（既定のまま）。アップロード中と下書きの保存中は何もしない（離れさせない）
    val back: () -> Unit = if (state.cropSession != null) {
        onCancelCrop
    } else {
        when (state.step) {
            ComposeStep.SELECTING -> onClose
            ComposeStep.EDITING -> onRequestLeave
            ComposeStep.INFO -> onBackToEditing
        }
    }
    BackHandler(enabled = state.step != ComposeStep.SELECTING || !state.canLeave) {
        if (state.canLeave) back()
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .imePadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.sm),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TextButton(onClick = back, enabled = state.canLeave) {
                Text(stringResource(R.string.action_cancel))
            }
            Text(
                text = stringResource(
                    when (state.step) {
                        ComposeStep.SELECTING -> R.string.compose_title
                        ComposeStep.EDITING -> R.string.compose_edit_title
                        ComposeStep.INFO -> R.string.compose_info_title
                    },
                ),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.weight(1f),
            )
            // 「次へ」は編集の段だけ。写真を確かめている間とトリミング・回転の画面の間は押せない
            // （確かめ終わる前の写真や、確定していない切り抜きを持ち越さない：要件 1.8・design.md:731）
            if (state.step == ComposeStep.EDITING) {
                TextButton(onClick = onGoToInfo, enabled = !state.isChecking && state.cropSession == null) {
                    Text(stringResource(R.string.action_next))
                }
            }
        }
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(DesignTokens.Spacing.md),
            // 要素の間は md（16dp）。作業の前の 12dp はトークンに無いので、16dp に寄せた（android-ui-ios-parity 要件 5.1）
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md),
        ) {
            DraftProgress(state)
            when (state.step) {
                ComposeStep.SELECTING -> {
                    SelectionNotices(state)
                    if (!state.isChecking) {
                        // アップロード中は写真を選ばせない（ViewModel も受け付けない：写しが進行中の投稿の写真を消すため。問い 22）
                        Button(
                            onClick = launchPicker,
                            enabled = state.progress !is PublishProgress.Uploading,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(stringResource(R.string.compose_pick_photos))
                        }
                        // 下書きが 1 件以上あるときだけ（利用者の判断 U7）
                        if (state.draftCount > 0) {
                            OutlinedButton(onClick = onOpenDrafts, modifier = Modifier.fillMaxWidth()) {
                                Text(stringResource(R.string.drafts_open_button, state.draftCount))
                            }
                        }
                    }
                }
                ComposeStep.EDITING -> {
                    SelectionNotices(state)
                    EditingContent(
                        state = state,
                        pagerState = pagerState,
                        onSelectFilter = onSelectFilter,
                        onOpenTool = onOpenTool,
                        onSliderChange = onSliderChange,
                        onSliderFinished = onSliderFinished,
                        onUndo = onUndo,
                        onRedo = onRedo,
                        onOpenLoadout = onOpenLoadout,
                        onCropDrag = onCropDrag,
                        onCropNudge = onCropNudge,
                        onRotateLeft = onRotateLeft,
                        onRotateRight = onRotateRight,
                        onConfirmCrop = onConfirmCrop,
                        onCancelCrop = onCancelCrop,
                        onRepick = repick,
                        onSaveDraft = onSaveDraft,
                    )
                }
                ComposeStep.INFO -> InfoContent(
                    state = state,
                    pagerState = pagerState,
                    isOnline = isOnline,
                    onCaptionChange = onCaptionChange,
                    onSelectVisibility = onSelectVisibility,
                    onPublish = onPublish,
                    onSaveDraft = onSaveDraft,
                )
            }
        }
    }

    // 装備の画面と下書きの一覧は、投稿の画面の上に重ねる（新しい行き先を足さない：design.md:1005）。
    // 下の確かめと案内より先に置く（下書きを開けなかった案内などを、一覧の上に出すため）
    if (state.showLoadout) {
        LoadoutSheetHost(
            loadout = state.loadout,
            saveFailed = state.loadoutSaveFailed,
            onSave = onSaveLoadout,
            onDismiss = onDismissSheet,
        )
    }
    if (state.showDrafts) {
        DraftListSheet(
            drafts = state.drafts,
            isOpening = state.isOpeningDraft,
            onOpen = onOpenDraft,
            onDelete = onDeleteDraft,
            onDismiss = onDismissSheet,
            // 進行中の投稿がある間は開けない（ViewModel の openDraft も受け付けない）ので、行を押せるように見せない（問い 34）
            openEnabled = state.progress == null,
        )
    }
    // 離れる・選び直すときの確かめ（要件 1.7・1.9）
    state.leaveQuestion?.let { question ->
        LeaveDialog(
            question = question,
            onChoice = { choice ->
                onAnswerLeave(choice)
                // 選び直しの確かめで「選び直す」を選んだら、写真選択画面を開く（ViewModel は確かめを閉じるだけ。
                // 選んだ写真が届いたら、編集と履歴を空にして作り直す：要件 6.10。何も選ばずに閉じたら、今の写真と編集のまま）
                if (question == LeaveQuestion.REPICK && choice == LeaveChoice.DISCARD) launchPicker()
            },
            isSavingDraft = state.isSavingDraft,
            // この画面の投稿の途中は、下書きに保存を押せない（ViewModel の saveDraft も受け付けない。投稿と下書きの両方を残さない：問い 34）
            canSaveDraft = !state.isPublishing,
        )
    }
    // 下書きについての案内（上限・保存の失敗・読めない下書き：要件 8.16〜8.18）。OK で消す
    state.draftNotice?.let { notice -> DraftNoticeDialog(notice = notice, onDismiss = onDismissNotice) }
    // 作り直した画面で編集の途中を読めなかった案内（要件 12.3）。OK で消し、写真の選択の段から選び直させる
    if (state.sessionUnreadable) {
        AlertDialog(
            onDismissRequest = onDismissNotice,
            text = { Text(stringResource(R.string.edit_session_unreadable)) },
            confirmButton = { TextButton(onClick = onDismissNotice) { Text(stringResource(R.string.action_ok)) } },
        )
    }
    if (state.published) {
        AlertDialog(
            onDismissRequest = onClose,
            text = { Text(stringResource(R.string.compose_published_message)) },
            confirmButton = { TextButton(onClick = onClose) { Text(stringResource(R.string.action_ok)) } },
        )
    }
    // 投稿の失敗も段によらずダイアログで出し、OK（とダイアログの外・戻る操作）でだけ消す（iOS も「エラー」のアラート：PostInfoView.swift:184-192）。
    // 写真選択画面を開いている間に届いた失敗も、戻ったときにここで見える（画面の中の文言だと、見せる前に選び直しで消えていた。レビュー Q07）。
    // 文言は何枚目の写真で失敗したかの値も入れて出す（design.md:894）
    state.publishError?.let { error ->
        val text = postErrorText(error)
        AlertDialog(
            onDismissRequest = onDismissPublishError,
            title = { Text(stringResource(R.string.compose_publish_failed_title)) },
            text = { Text(stringResource(text.res, *text.args.toTypedArray())) },
            confirmButton = { TextButton(onClick = onDismissPublishError) { Text(stringResource(R.string.action_ok)) } },
        )
    }
}

/** 確かめている最中の表示と、上限・読めない写真の案内（要件 6.4・6.9・16.2）。 */
@Composable
private fun SelectionNotices(state: PostComposerUiState) {
    if (state.isChecking) {
        // 輪と文言の間は sm（8dp）。作業の前の 12dp はトークンに無いので、進み具合の行は 8dp に寄せた（android-ui-ios-parity 要件 5.1）
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
            CircularProgressIndicator(modifier = Modifier.size(24.dp))
            Text(stringResource(R.string.compose_checking))
        }
    }
    if (state.exceeded) {
        Text(
            text = stringResource(R.string.compose_too_many, TextLimits.IMAGES_MAX),
            color = MaterialTheme.colorScheme.error,
        )
    }
    if (state.unreadablePositions.isNotEmpty()) {
        Text(
            text = stringResource(R.string.compose_unreadable, state.unreadablePositions.joinToString("・")) + "\n" +
                stringResource(R.string.compose_unreadable_reason),
            color = MaterialTheme.colorScheme.error,
        )
    }
}

/**
 * 下書きの保存と読み込みの進み具合（要件 10.5）。どの段でも中身の先頭に出す。
 * 一覧を開いたまま読み込んでいるときは一覧にも同じ文言が出るが、変化を読み上げるのはこちらだけ（一覧の文言は読み上げの変化を持たない）。
 */
@Composable
private fun DraftProgress(state: PostComposerUiState) {
    if (state.isSavingDraft) ProgressRow(stringResource(R.string.drafts_saving))
    if (state.isOpeningDraft) ProgressRow(stringResource(R.string.drafts_loading))
}

/** 輪と、変化を読み上げる文言の行（写真の確かめの行と同じ並び）。 */
@Composable
private fun ProgressRow(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
        CircularProgressIndicator(modifier = Modifier.size(24.dp))
        Status(text)
    }
}

/**
 * 編集の段：プレビュー（トリミング・回転の画面の間はその部品）・フィルターの選択・ツール・選び直し・下書きに保存（要件 1.1・1.4・5.6・6.1）。
 *
 * - 操作は全て表示中の写真（[PostComposerUiState.currentIndex]）に掛かる。フィルターの選択中の印とツールの値も、その写真から読む
 * - 写真を確かめている間とトリミング・回転の画面の間は、ツール（元に戻す・やり直しを含む）と下書きに保存を無効にし、
 *   フィルターの選択肢は出さない（無効の形を持たない部品なので、押せるように見せない）
 * - トリミング・回転の画面の間は、選び直しも押せない（選び直すと仮の切り抜きが黙って消える）
 * - アップロード中は選び直しを押せない（ViewModel も写真の選択を受け付けない：問い 22）
 */
@Composable
private fun EditingContent(
    state: PostComposerUiState,
    pagerState: PagerState,
    onSelectFilter: (FilterId?) -> Unit,
    onOpenTool: (EditTool?) -> Unit,
    onSliderChange: (EditTool, Int) -> Unit,
    onSliderFinished: () -> Unit,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onOpenLoadout: () -> Unit,
    onCropDrag: (CropMath.Handle, Double, Double) -> Unit,
    onCropNudge: (CropMath.Edge, Boolean) -> Unit,
    onRotateLeft: () -> Unit,
    onRotateRight: () -> Unit,
    onConfirmCrop: () -> Unit,
    onCancelCrop: () -> Unit,
    onRepick: () -> Unit,
    onSaveDraft: () -> Unit,
) {
    val cropSession = state.cropSession
    // 編集の操作を受け付けない間（要件 1.8・design.md:731）。下書きを保存している間も止める（その間に変えた分は下書きに入らず、
    // 保存できると画面が閉じて失われる：問い 34・利用者の決定 2026-11-13）
    val locked = state.isChecking || cropSession != null || state.isSavingDraft
    val current = state.photos.getOrNull(state.currentIndex)

    if (cropSession != null) {
        // 絵は仮の回転で読み直した全体の絵（design.md:731）。枠は仮の切り抜き
        CropPanel(
            image = state.previews[state.currentIndex],
            crop = cropSession.pending.crop,
            onDrag = onCropDrag,
            onNudge = onCropNudge,
            onRotateLeft = onRotateLeft,
            onRotateRight = onRotateRight,
            onConfirm = onConfirmCrop,
            onCancel = onCancelCrop,
            modifier = Modifier.fillMaxWidth(),
        )
    } else {
        EditedPhotoPreview(
            photos = state.photos,
            previews = state.previews,
            pagerState = pagerState,
            failedPreviews = state.failedPreviews,
        )
    }
    if (!locked) {
        Text(text = stringResource(R.string.compose_filter_label), style = MaterialTheme.typography.titleMedium)
        FilterOptions(
            selected = current?.edit?.filter,
            samples = state.filterSamples,
            onSelect = onSelectFilter,
            modifier = Modifier.fillMaxWidth(),
        )
    }
    EditToolPanel(
        tools = state.toolsToShow,
        edit = current?.edit ?: PhotoEdit.NONE,
        history = current?.history ?: EditHistory.EMPTY,
        openTool = state.openTool,
        onUndo = onUndo,
        onRedo = onRedo,
        onToolSelected = onOpenTool,
        onSliderChange = onSliderChange,
        onSliderFinished = onSliderFinished,
        onOpenLoadout = onOpenLoadout,
        modifier = Modifier.fillMaxWidth(),
        enabled = !locked,
    )
    OutlinedButton(
        onClick = onRepick,
        enabled = cropSession == null && state.progress !is PublishProgress.Uploading && !state.isSavingDraft,
    ) {
        Text(stringResource(R.string.compose_repick))
    }
    // この画面の投稿が戻るまでと投稿の後も押せない（投稿情報の段と同じ。保存中に編集の段へ戻った時に、投稿と下書きの両方を残さない）
    OutlinedButton(
        onClick = onSaveDraft,
        enabled = !locked && !state.isSavingDraft && !state.isPublishing && !state.published,
    ) {
        Text(stringResource(R.string.edit_save_draft))
    }
}

/**
 * 投稿情報の段：プレビュー・キャプション・ハッシュタグ・公開範囲・投稿ボタンと進み具合・下書きに保存
 * （要件 5.6・7.5・7.6・7.8・7.9・7.21・7.22・8.1・16.2）。
 * 並びは iOS の PostInfoView（:114-146）のうち MVP にあるものだけ（気分・位置・空の種類・保存の選択肢は無い）。
 *
 * - プレビューは編集の段と同じ部品で、各写真の編集を全て掛けた絵を出す（要件 5.6）
 * - キャプションは上限を超えても入力でき、文字数（UTF-16）と案内を出して投稿ボタンを押せなくする（ユーザー判断）
 * - ハッシュタグが 30 個を超えたら、同じく案内を出して投稿ボタンを押せなくする
 * - この画面の投稿が戻るまでは入力を変えさせない（送った内容と画面の内容を食い違わせない）。下書きに保存も同じ間は押せない
 */
@Composable
private fun InfoContent(
    state: PostComposerUiState,
    pagerState: PagerState,
    isOnline: Boolean,
    onCaptionChange: (String) -> Unit,
    onSelectVisibility: (Visibility) -> Unit,
    onPublish: () -> Unit,
    onSaveDraft: () -> Unit,
) {
    // 下書きを保存している間も入力を変えさせない（その間に変えた分は下書きに入らない：問い 34）
    val editable = !state.isPublishing && !state.published && !state.isSavingDraft
    EditedPhotoPreview(
        photos = state.photos,
        previews = state.previews,
        pagerState = pagerState,
        failedPreviews = state.failedPreviews,
    )

    Text(text = stringResource(R.string.compose_caption_label), style = MaterialTheme.typography.titleMedium)
    OutlinedTextField(
        value = state.caption,
        onValueChange = onCaptionChange,
        enabled = editable,
        minLines = 4,
        modifier = Modifier.fillMaxWidth(),
        supportingText = { Text(stringResource(R.string.compose_count, state.captionLength, TextLimits.CAPTION_MAX)) },
        isError = state.isCaptionTooLong,
    )
    if (state.isCaptionTooLong) Notice(stringResource(R.string.compose_caption_too_long))
    Text(text = stringResource(R.string.compose_hashtag_hint), style = MaterialTheme.typography.bodySmall)

    Text(text = stringResource(R.string.compose_hashtags_label), style = MaterialTheme.typography.titleMedium)
    Text(
        text = if (state.hashtags.isEmpty()) {
            stringResource(R.string.compose_hashtags_none)
        } else {
            state.hashtags.joinToString(" ") { "#$it" }
        },
        style = MaterialTheme.typography.bodyMedium,
    )
    if (state.hasTooManyHashtags) {
        Notice(
            stringResource(R.string.compose_hashtags_too_many) + "（" +
                stringResource(R.string.compose_count, state.hashtags.size, TextLimits.HASHTAGS_MAX) + "）",
        )
    }

    Text(text = stringResource(R.string.compose_visibility_label), style = MaterialTheme.typography.titleMedium)
    // iOS も 3 つを横に並べて 1 つ選ぶ（SegmentedPickerStyle：PostInfoView.swift:751-756）。表示名は :contract の displayName（要件 16.1）
    // 文字はボタンの役（labelLarge＝17sp）でなく 14sp（bodyMedium＝captionSize）にする。17sp だと 100% でも
    // 「フォロワーのみ」が 2 行に割れ、真ん中だけが縦に伸びて切り替えの形が崩れた（android-ui-ios-parity 13.1）。
    // iOS の切り替えも既定の小さめの文字で、ボタンの大きさのトークンは使っていない。
    // 文字 200% では割れるので、行の高さを 3 つのうち一番高い中身に合わせ、各ボタンをその高さまで伸ばして形を保つ
    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Min)) {
        Visibility.entries.forEachIndexed { index, visibility ->
            SegmentedButton(
                selected = state.visibility == visibility,
                onClick = { onSelectVisibility(visibility) },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = Visibility.entries.size),
                modifier = Modifier.fillMaxHeight(),
                enabled = editable,
            ) {
                Text(visibility.displayName, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }

    PublishProgressContent(state, isOnline)
    // オフラインの間は押せない（ViewModel の publish も同じく止める。兄弟の ProfileEditScreen の保存と同じ。レビュー R05）
    Button(onClick = onPublish, enabled = state.canPublish && isOnline, modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(if (state.isPublishing) R.string.compose_publishing else R.string.compose_publish))
    }
    OutlinedButton(onClick = onSaveDraft, enabled = editable && !state.isSavingDraft, modifier = Modifier.fillMaxWidth()) {
        Text(stringResource(R.string.edit_save_draft))
    }
}

/**
 * 投稿の進み具合（要件 7.21・16.2）。アップロードは上げ終えた枚数の棒、保存は終わりの見えない棒にする（iOS は棒だけ：PostInfoView.swift:844-847）。
 * 前に開いた投稿の画面で始めた投稿が保存中なら、そのことを出す（この画面の投稿ボタンを押せない理由）。
 * 保存中かつオフラインなら「接続が戻ると保存を続けます」を出す（Firestore は接続が戻るまで書き込みの完了を待つため。設計書の PostPublisher の節）。
 * アップロード中かつオフラインなら「ネットワークに接続できません」を出す（棒が止まり、戻る・キャンセルも効かない理由を出す。レビュー R05）。
 * 進行中の投稿が無いときにオフラインなら、同じ文言で投稿ボタンを押せない理由を出す（レビュー R05）。
 */
@Composable
private fun PublishProgressContent(state: PostComposerUiState, isOnline: Boolean) {
    when (val progress = state.progress) {
        is PublishProgress.Uploading -> {
            LinearProgressIndicator(
                progress = { if (progress.total == 0) 0f else progress.done.toFloat() / progress.total },
                modifier = Modifier.fillMaxWidth(),
            )
            // アップロードは接続を待って止まり、その間は戻る・キャンセルも効かない（タスク 23.5 の決定②。変えない）ので、切れていることを出す。
            // 待ちの長さは SDK の再試行と、失敗した後の後片付け（PostPublisher が 1 つずつ 30 秒で打ち切る：レビュー R07）で決まる
            Status(stringResource(R.string.compose_uploading, progress.done, progress.total))
            if (!isOnline) Status(stringResource(R.string.offline_title))
        }
        PublishProgress.Saving -> {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            Status(stringResource(if (state.isOthersProgress) R.string.compose_previous_saving else R.string.compose_saving))
            if (!isOnline) Status(stringResource(R.string.compose_saving_offline))
        }
        // 進行中の投稿が無い間のオフライン：投稿ボタンを押せない理由を、ボタンのすぐ上に出す
        null -> if (!isOnline) Status(stringResource(R.string.offline_title))
    }
}

/**
 * 装備の画面（[LoadoutSheet]）を、今の装備から開く。並べ替えとチェックの途中は、保存するまでこの画面だけが持つ
 * （ViewModel の装備は、保存の部品から届いた値のまま変えない。シートを閉じると途中は忘れ、次に開くと今の装備から始める）。
 * 並びは、今の装備のツールを装備の順に、続けて装備に無いツールを [EditTool] の順に置く（外したツールも下に残り、またチェックできる）。
 * 保存では、チェックの入ったツールを並びの順に並べた装備を渡す（LoadoutSheet の約束：画面の側が作る）。
 */
@Composable
private fun LoadoutSheetHost(
    loadout: Loadout,
    saveFailed: Boolean,
    onSave: (Loadout) -> Unit,
    onDismiss: () -> Unit,
) {
    var order by remember { mutableStateOf(loadout.tools + EditTool.entries.filterNot { it in loadout.tools }) }
    var checked by remember { mutableStateOf(loadout.tools.toSet()) }
    LoadoutSheet(
        tools = order,
        checked = checked,
        onToggle = { tool -> checked = if (tool in checked) checked - tool else checked + tool },
        onMove = { tool, offset -> order = order.moved(tool, offset) },
        onSave = { onSave(Loadout(order.filter { it in checked })) },
        onDismiss = onDismiss,
        saveFailed = saveFailed,
    )
}

/** [tool] を [offset] 個だけ動かした並び。端を越える動きは、そのままの並びを返す。 */
private fun List<EditTool>.moved(tool: EditTool, offset: Int): List<EditTool> {
    val from = indexOf(tool)
    val to = from + offset
    if (from < 0 || to !in indices) return this
    return toMutableList().apply { add(to, removeAt(from)) }
}

/** 進み具合の文言。読み上げにも変化を伝える。 */
@Composable
private fun Status(text: String) {
    Text(text = text, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
}

/** 上限の超過の案内（エラーの色）。読み上げにも変化を伝える。 */
@Composable
private fun Notice(text: String) {
    Text(
        text = text,
        color = MaterialTheme.colorScheme.error,
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
    )
}
