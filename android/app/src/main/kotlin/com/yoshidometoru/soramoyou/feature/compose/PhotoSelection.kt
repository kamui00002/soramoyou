// ⭐️ 写真選択画面から受け取った写真の枚数を、受け取った側でも検査する（タスク 21.1・要件 6.3・6.4）
package com.yoshidometoru.soramoyou.feature.compose

import com.yoshidometoru.soramoyou.contract.rules.TextLimits
import com.yoshidometoru.soramoyou.data.image.PickedPhoto

/**
 * 写真選択の結果。
 *
 * @property photos 投稿の対象として受け付けた写真（選んだ順・[PickedPhoto.index] は 0 から）。何も選ばずに閉じたら空。
 * @property exceeded 上限（[TextLimits.IMAGES_MAX]）を超えて選ばれ、超えた分を受け付けなかったら true。画面は上限を案内する。
 */
data class PhotoSelection(val photos: List<PickedPhoto>, val exceeded: Boolean) {

    companion object {
        /** 何も選んでいない状態。 */
        val EMPTY = PhotoSelection(emptyList(), exceeded = false)

        /**
         * 写真選択画面から返ってきた URI の並びを受け付ける。先頭から [TextLimits.IMAGES_MAX]（10）枚までを、選んだ順に受け付ける。
         *
         * 写真選択画面には上限（`PickMultipleVisualMedia(maxItems = 10)`）を渡しているが、それだけに頼らない。
         * 端末に写真選択画面が無く、別の選択画面（`ACTION_OPEN_DOCUMENT` など）に代わった場合は、上限が効かないためである
         * （要件 6.4「超過分を受け付けず、上限を案内する」）。超えた分は捨て、[exceeded] で案内させる。
         *
         * iOS は選択画面の上限（ImagePickerService.swift:56 の `selectionLimit`）で止め、超えたら「選択できる画像は最大10枚までです」
         * （同 :360）を出す。Android は捨てて続ける（選び直しを強いない）。
         */
        fun accept(uris: List<String>): PhotoSelection = PhotoSelection(
            photos = uris.take(TextLimits.IMAGES_MAX).mapIndexed { index, uri -> PickedPhoto(uri, index) },
            exceeded = uris.size > TextLimits.IMAGES_MAX,
        )
    }
}
