// ⭐️ 編集の段のツールの部品 EditToolPanel（Kiro android-edit-tools タスク 8・部品 U2・design.md:999・要件 1.4・3.4・3.7・6.1・6.6・13.2〜13.8）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.edit.EditHistory
import com.yoshidometoru.soramoyou.contract.edit.EditTool
import com.yoshidometoru.soramoyou.contract.edit.PhotoEdit
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens
import kotlin.math.roundToInt

/*
 * 編集の段の「ツール」の部品。PostComposerScreen の編集の段が呼ぶ。公開の Composable の引数を先に書く。
 *
 * 【EditToolPanel の引数】（状態と操作は全て引数で受ける。ViewModel は参照しない：design.md:1228）
 * - tools: 並びに出すツール。`EditingState.toolsToShow(loadout, edit)` の結果をそのまま渡す（装備で選んだものだけ・装備の順）。この部品は並べ替えも絞り込みもしない
 * - edit: 表示中の写真の編集の内容。スライダーの値と「調整済み」の印はここから読む
 * - history: 表示中の写真の履歴。`canUndo`・`canRedo` が偽の間は、元に戻す・やり直しを無効の表示にする（6.6）
 * - openTool: 今開いているツール（無ければ null）。スライダーのツールならスライダーと数字を出す
 * - enabled: 偽の間は全ての操作を無効にする。トリミング・回転の画面を開いている間（cropSession != null）に偽にする（design.md:731）。既定は真
 * - onUndo / onRedo: 元に戻す・やり直しのボタン
 * - onToolSelected: ツールを選んだ（`PostComposerViewModel.openTool(tool?)` に渡す）。
 *     スライダーのツールは、開いているものをもう一度押すと null（閉じる）を渡す。
 *     トリミング・回転（CROP_AND_ROTATE）は、押すたびにそのツールを渡すだけで、この部品の中には切り抜きの画面を持たない
 *     （切り抜きの画面は部品 U3。呼ぶ側が `beginCrop` に進める）。このツールではスライダーを出さない
 * - onSliderStart: スライダーに触れた時（指を置いた時・ドラッグを始めた時。TalkBack など指を置かない操作では、最初の値の変更の直前に 1 回）。
 *     ViewModel に対応する関数が無ければ、`onSliderChange` の最初の呼び出しで触れた時の内容を控える作りでもよい。既定は何もしない
 * - onSliderChange: 値が変わった（ツール・新しい値＝-100〜100 の整数）。履歴には積まない（`EditingState.slide`）
 * - onSliderFinished: 指を離した時（TalkBack の 1 回の操作では、値の変更の直後に 1 回）。触れた時の内容を 1 手として積む（`EditingState.endSlider`）。
 *     「0に戻す」は、onSliderStart → onSliderChange(tool, 0) → onSliderFinished の 3 つを続けて呼ぶ（スライダーの 1 回の操作と同じ 1 手）
 * - onOpenLoadout: 「ツールの並びを変える」ボタン（装備の画面を開く）
 * - modifier: 外側の修飾
 *
 * 【見た目と読み上げ】
 * - 色は MaterialTheme.colorScheme だけ。高さは固定しない（文字 200% では縦に伸び、ツールの並びは横に送れる）。押せる所は 48dp 以上
 * - 選択中のツールは枠＋太字、調整済みのツールは点＋「調整済み」の文字（色だけで伝えない：3.7・13.8）
 * - スライダーは「露出、+25」と読み上げる（edit_slider_description）。指では 1 刻み（iOS と同じ。目盛りは置かない：利用者の決定 2026-11-12）、
 *     TalkBack の 1 回の操作では 5 動く（13.3。外の箱が範囲の情報と setProgress を持ち、中の Slider の読み上げの情報は消す）
 * - 数字の形は iOS の formatSliderValue と同じ（EditView.swift:1065-1072）：0 以上は「+25」「+0」、負は「-10」
 */

/** スライダーの刻み。TalkBack の 1 回の操作で動く量（13.3） */
private const val SLIDER_STEP = 5


/** 数字の表示。0 以上は先頭に「+」、負はそのまま「-10」（iOS EditView.swift:1065-1072 の formatSliderValue と同じ） */
fun formatToolValue(value: Int): String = if (value >= 0) "+$value" else "$value"

/**
 * 編集の段のツールの部品。上から、元に戻す・やり直し・装備を開くボタンの行、ツールの並び、開いたツールのスライダーと数字。
 * 引数の意味はファイルの先頭のコメントを見る。
 */
@Composable
fun EditToolPanel(
    tools: List<EditTool>,
    edit: PhotoEdit,
    history: EditHistory,
    openTool: EditTool?,
    onUndo: () -> Unit,
    onRedo: () -> Unit,
    onToolSelected: (EditTool?) -> Unit,
    onSliderChange: (EditTool, Int) -> Unit,
    onSliderFinished: () -> Unit,
    onOpenLoadout: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onSliderStart: () -> Unit = {},
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
        // 元に戻す・やり直し・装備を開くボタン。文字が大きくなって入りきらないときは横に送れる
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState()),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs),
        ) {
            HistoryButton(
                glyph = "↶",
                description = stringResource(R.string.edit_undo),
                enabled = enabled && history.canUndo,
                onClick = onUndo,
            )
            HistoryButton(
                glyph = "↷",
                description = stringResource(R.string.edit_redo),
                enabled = enabled && history.canRedo,
                onClick = onRedo,
            )
            TextButton(
                onClick = onOpenLoadout,
                enabled = enabled,
                modifier = Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp),
            ) {
                Text(text = stringResource(R.string.edit_loadout_open))
            }
        }

        // ツールの並び。横に送れる。装備で選んだものだけ（呼ぶ側が絞って渡す）
        val toolsLabel = stringResource(R.string.edit_tools_label)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .semantics { contentDescription = toolsLabel }
                .horizontalScroll(rememberScrollState())
                .selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        ) {
            tools.forEach { tool ->
                ToolChip(
                    tool = tool,
                    selected = tool == openTool,
                    adjusted = isAdjusted(tool, edit),
                    enabled = enabled,
                    onClick = {
                        // スライダーのツールは、開いているものをもう一度押すと閉じる。切り抜きのツールは呼ぶ側へ知らせるだけ
                        onToolSelected(if (tool.isSlider && tool == openTool) null else tool)
                    },
                )
            }
        }

        // 開いたツールのスライダーと数字（切り抜きのツールにはスライダーが無い）
        if (openTool != null && openTool.isSlider) {
            ToolSlider(
                tool = openTool,
                value = edit.tools[openTool],
                enabled = enabled,
                onSliderStart = onSliderStart,
                onSliderChange = onSliderChange,
                onSliderFinished = onSliderFinished,
            )
        }
    }
}

/** そのツールが調整済みか。スライダーのツールは値が 0 でない、切り抜きのツールは回転か切り抜きが入っている */
private fun isAdjusted(tool: EditTool, edit: PhotoEdit): Boolean =
    if (tool.isSlider) tool in edit.tools.adjusted else edit.geometry != PhotoEdit.NONE.geometry

/**
 * 元に戻す・やり直しの、アイコンだけのボタン。文字の記号を描き、説明（TalkBack 用）は [description]（13.4）。
 * IconButton は 48dp の押せる大きさを持つ。押せない間は無効の表示になる（6.6）。
 */
@Composable
private fun HistoryButton(glyph: String, description: String, enabled: Boolean, onClick: () -> Unit) {
    IconButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.semantics { contentDescription = description },
    ) {
        // 記号の文字そのものは読ませない（説明は上の contentDescription）。無効の色は IconButton が当てる
        Text(text = glyph, style = MaterialTheme.typography.titleLarge)
    }
}

/**
 * ツールの並びの 1 つ。名前の下に、調整済みなら点＋「調整済み」の文字。選択中は枠＋太字（色だけに頼らない：13.8）。
 * 1 つだけを選ぶ組なので「ラジオボタン」と選択中かを読ませる。幅は文字に合わせ、高さは固定しない（最低 48dp）。
 */
@Composable
private fun ToolChip(tool: EditTool, selected: Boolean, adjusted: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Column(
        modifier = Modifier
            .defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
            .then(
                if (selected) Modifier.border(2.dp, MaterialTheme.colorScheme.primary, shape) else Modifier,
            )
            .selectable(selected = selected, enabled = enabled, onClick = onClick, role = Role.RadioButton)
            .padding(horizontal = DesignTokens.Spacing.sm, vertical = DesignTokens.Spacing.xs),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = tool.displayName,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (adjusted) {
            // 点＋文字（色だけで伝えない：3.7）。TalkBack は名前に続けて「調整済み」と読む
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "●",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                )
                Text(
                    text = stringResource(R.string.edit_tool_adjusted),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = DesignTokens.Spacing.xs),
                )
            }
        }
    }
}

/**
 * 開いたツールのスライダー・数字・「0に戻す」。
 * 触れた時と離した時を呼ぶ側へ知らせる（1 手の数え方：6.2）。指を置かない操作（TalkBack）では、値の変更の直前に触れた時を 1 回だけ知らせる。
 */
@Composable
private fun ToolSlider(
    tool: EditTool,
    value: Int,
    enabled: Boolean,
    onSliderStart: () -> Unit,
    onSliderChange: (EditTool, Int) -> Unit,
    onSliderFinished: () -> Unit,
) {
    val currentStart by rememberUpdatedState(onSliderStart)
    val currentFinished by rememberUpdatedState(onSliderFinished)

    // 触れている間か。指を置く・ドラッグ・TalkBack の変更のどれでも、始まりを 1 回だけ知らせる
    var active by remember(tool) { mutableStateOf(false) }
    val startIfNeeded = {
        if (!active) {
            active = true
            currentStart()
        }
    }
    val finish = {
        active = false
        currentFinished()
    }

    // 指を置いた時・ドラッグを始めた時を拾う（Slider は触れた時の通知を持たないため）
    val interactionSource = remember(tool) { MutableInteractionSource() }
    LaunchedEffect(interactionSource) {
        interactionSource.interactions.collect { interaction ->
            if (interaction is PressInteraction.Press || interaction is DragInteraction.Start) startIfNeeded()
        }
    }

    val valueText = formatToolValue(value)
    val description = stringResource(R.string.edit_slider_description, tool.displayName, valueText)

    Column(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            // 数字（見える文字）。読み上げはスライダー側が「露出、+25」と読むので、ここは二重に読ませない
            Text(
                text = tool.displayName,
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier
                    .weight(1f)
                    .clearAndSetSemantics {},
            )
            Text(
                text = valueText,
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.clearAndSetSemantics {},
            )
            TextButton(
                onClick = {
                    // スライダーの 1 回の操作と同じ 1 手にする
                    startIfNeeded()
                    onSliderChange(tool, 0)
                    finish()
                },
                enabled = enabled && value != 0,
                modifier = Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp),
            ) {
                Text(text = stringResource(R.string.edit_slider_reset))
            }
        }
        // Slider に読み上げの情報を直に付けると、その範囲の高さは端末で 116px（約 44dp）と測れ、48dp に届かなかった
        // （EditScreenDeviceTest。最小の高さを前後どちらに足しても変わらなかった）。箱に入れて読み上げの情報を箱に付けると
        // 48dp 以上になる（要件 13.2）。
        // 箱は、中の Slider の読み上げの情報を消して（clearAndSetSemantics）、自分の情報だけを TalkBack に渡す。
        // 「まとめる」（mergeDescendants）だけでは、中の Slider が別の部品として TalkBack に渡り続け、TalkBack はそちら
        // （読み上げの文が無く、1 回で 10 動く）に止まった（20.3 の端末の観察・タスク 20.6）。指で引く操作は Slider がそのまま受ける。
        // 下の最小の高さは守りとして残した（これを外しても端末のテストは緑のままだったので、この 1 行の効き目は確かめていない）
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .defaultMinSize(minHeight = 48.dp)
                .clearAndSetSemantics {
                    contentDescription = description
                    stateDescription = valueText
                    // 範囲の情報を付けると、TalkBack はこの箱を値を調整できる部品（SeekBar）として扱う。
                    // 刻みの数は、-100〜100 を SLIDER_STEP（5）ずつに分けたときの間の点の数（39）
                    progressBarRangeInfo = ProgressBarRangeInfo(
                        current = value.toFloat(),
                        range = EditTool.MIN.toFloat()..EditTool.MAX.toFloat(),
                        steps = (EditTool.MAX - EditTool.MIN) / SLIDER_STEP - 1,
                    )
                    // 中の Slider の情報を消したので、「無効」は箱の側で読ませる
                    if (!enabled) disabled()
                    // TalkBack の 1 回の操作は、今の値から SLIDER_STEP（5）だけ動かす（13.3）。
                    // 渡ってくる目標の値は向きだけを使って読み替える（目標の値の作り方は端末の側が決めるので、頼らない）。
                    // 指を離す通知が来ない道なので、ここで 1 手（始まり→値→終わり）にする
                    if (enabled) {
                        setProgress { target ->
                            val next = when {
                                target > value -> (value + SLIDER_STEP).coerceAtMost(EditTool.MAX)
                                target < value -> (value - SLIDER_STEP).coerceAtLeast(EditTool.MIN)
                                else -> value
                            }
                            if (next == value) {
                                false
                            } else {
                                startIfNeeded()
                                onSliderChange(tool, next)
                                finish()
                                true
                            }
                        }
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            Slider(
                value = value.toFloat(),
                onValueChange = { raw ->
                    startIfNeeded()
                    onSliderChange(tool, raw.roundToInt())
                },
                onValueChangeFinished = { finish() },
                valueRange = EditTool.MIN.toFloat()..EditTool.MAX.toFloat(),
                // 指では iOS と同じ 1 刻み（目盛りを置かない。利用者の決定 2026-11-12）
                steps = 0,
                enabled = enabled,
                interactionSource = interactionSource,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
