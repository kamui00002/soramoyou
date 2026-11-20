// ⭐️ 撮影時刻の「時」から時間帯を決める（タスク 20.2・要件 7.15）
package com.yoshidometoru.soramoyou.contract.rules

import com.yoshidometoru.soramoyou.contract.model.TimeOfDay

/**
 * 撮影日時の「時」（0〜23）から時間帯を決める。iOS 版の `TimeOfDay.from(date:)` と同じ区切りである
 * （Soramoyou/Soramoyou/Models/TimeOfDay.swift:38-51）。
 *
 * | 時 | 時間帯 |
 * |---|---|
 * | 5〜11 | [TimeOfDay.MORNING] |
 * | 12〜16 | [TimeOfDay.AFTERNOON] |
 * | 17〜19 | [TimeOfDay.EVENING] |
 * | それ以外 | [TimeOfDay.NIGHT] |
 *
 * ## 「時」は投稿する端末のタイムゾーンで取る（呼び出し側の責任）
 * iOS は `Calendar.current` で「時」を取る（PostViewModel.swift:296 の「投稿端末のタイムゾーンで『時』を取る」がアプリ全体の規約）。
 * 撮影日時を EXIF のオフセットで解釈していても、時間帯は**撮影地の時刻ではなく端末の時刻**で決まる。
 * 例：ニューヨークで 17:30（EST）に撮った写真を東京の端末から投稿すると、東京では 7:30 なので [TimeOfDay.MORNING] になる。
 * この関数は「時」だけを受け取るので、撮影日時を端末のタイムゾーンの「時」へ直すのは呼び出し側が行う。
 *
 * 0〜23 の外の値は、Swift の `switch` の `default` と同じく [TimeOfDay.NIGHT] にする（例外にしない）。
 */
object TimeOfDayResolver {

    fun fromLocalHour(hour: Int): TimeOfDay = when (hour) {
        in 5..11 -> TimeOfDay.MORNING
        in 12..16 -> TimeOfDay.AFTERNOON
        in 17..19 -> TimeOfDay.EVENING
        else -> TimeOfDay.NIGHT
    }
}
