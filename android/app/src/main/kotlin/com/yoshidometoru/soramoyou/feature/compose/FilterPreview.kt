// ⭐️ フィルターの選択肢の並びと選択の部品（設計書の部品 FilterPreview・タスク 21.2・要件 6.5〜6.8・16.1・16.5）（android-ui-ios-parity タスク 12.2・要件 5.1）
package com.yoshidometoru.soramoyou.feature.compose

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.contract.model.FilterId
import com.yoshidometoru.soramoyou.data.image.PreviewImage
import com.yoshidometoru.soramoyou.ui.theme.DesignTokens

/** 画面に並べるフィルターの選択肢。先頭が「なし」（null）、続けて iOS と同じ並びの 10 種（FilterType.swift の順）。「なし」＋10 種の 11 個（K0：design.md:360）。 */
val FILTER_OPTIONS: List<FilterId?> = listOf(null) + FilterId.entries

/**
 * [FilterOptions]（見本の絵を受け取る形）が並べる 1 つ分（Kiro android-edit-tools タスク 13・A3）。
 * [sample] はその選択肢の見本の絵（まだ描けていなければ null）、[isSelected] は選択中か。
 */
internal data class FilterSampleOption(val filter: FilterId?, val sample: PreviewImage?, val isSelected: Boolean)

/**
 * [FILTER_OPTIONS] の並び（「なし」＋10 種の 11 個）に、同じ並びの見本 [samples] と選択中の印を合わせる。
 * [samples] が足りない所（まだ描けていない・数が少ない）は null にし、多すぎる分は使わない。選択中は [selected] と同じ 1 つだけ。
 */
internal fun filterSampleOptions(samples: List<PreviewImage?>, selected: FilterId?): List<FilterSampleOption> =
    FILTER_OPTIONS.mapIndexed { index, option -> FilterSampleOption(option, samples.getOrNull(index), option == selected) }

/**
 * フィルターの選択肢を横に並べる、見本の絵を受け取る形（Kiro android-edit-tools タスク 13・A3・design.md:998・要件 2.5・13.8）。
 * 各選択肢は、ViewModel が表示中の写真の小さな絵にそのフィルターだけを掛けた見本（[samples]。[FILTER_OPTIONS] と同じ並びの 11 個）と、
 * iOS と同じ表示名。この部品は色を計算しない（受け取った絵をそのまま描く）。選ぶと前のフィルターを置き換える（[onSelect] に 1 つだけ渡す）。
 *
 * TalkBack には「ラジオボタン」と選択中かどうかを読ませる。見本の絵は名前の飾りなので読ませない。
 * 選択中は、見本の枠と名前の太字の 2 つで示す（色だけに頼らない：要件 13.8）。文字を大きくしても名前が切れないよう、
 * 幅は文字に合わせ、横に送れるようにする。
 *
 * まだ見本が無い選択肢は、見本の場所に背景の色の四角を描く。
 */
@Composable
fun FilterOptions(
    selected: FilterId?,
    samples: List<PreviewImage?>,
    onSelect: (FilterId?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .horizontalScroll(rememberScrollState())
            .selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
    ) {
        filterSampleOptions(samples, selected).forEach { option ->
            val bitmap = remember(option.sample) { option.sample?.let(::previewImageBitmapOf) }
            Column(
                modifier = Modifier
                    .widthIn(min = 64.dp)
                    .selectable(selected = option.isSelected, onClick = { onSelect(option.filter) }, role = Role.RadioButton)
                    .padding(DesignTokens.Spacing.xs),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val shape = RoundedCornerShape(8.dp)
                val sampleModifier = Modifier
                    .size(56.dp)
                    .clip(shape)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .then(
                        if (option.isSelected) Modifier.border(3.dp, MaterialTheme.colorScheme.primary, shape) else Modifier,
                    )
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = sampleModifier,
                    )
                } else {
                    Box(modifier = sampleModifier)
                }
                Text(
                    text = option.filter?.displayName ?: stringResource(R.string.compose_filter_none),
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = if (option.isSelected) FontWeight.Bold else FontWeight.Normal,
                    modifier = Modifier.padding(top = DesignTokens.Spacing.xs),
                )
            }
        }
    }
}
