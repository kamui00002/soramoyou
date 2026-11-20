// ⭐️ 時間帯の判定の単体テスト（タスク 20.2・要件 7.15）
package com.yoshidometoru.soramoyou.contract.rules

import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * [TimeOfDayResolver] が、iOS 版の `TimeOfDay.from(date:)`（TimeOfDay.swift:38-51）と同じ区切りで時間帯を決めることを確かめる。
 *
 * 境界の期待値は、同じ判定を Swift 6.4（macOS 27・`TZ=Asia/Tokyo`）で実測した（手元（git の外）の `20.2-timeofday_tokyo.tsv`）。
 * 判定は「時」だけで決まり、分は効かない（4:59 は夜、5:00 は朝）。
 */
class TimeOfDayResolverTest {

    @Test
    fun `境界の時刻で時間帯が切り替わる`() {
        val expected = listOf(
            4 to TimeOfDay.NIGHT,
            5 to TimeOfDay.MORNING,
            11 to TimeOfDay.MORNING,
            12 to TimeOfDay.AFTERNOON,
            16 to TimeOfDay.AFTERNOON,
            17 to TimeOfDay.EVENING,
            19 to TimeOfDay.EVENING,
            20 to TimeOfDay.NIGHT,
            0 to TimeOfDay.NIGHT,
            23 to TimeOfDay.NIGHT,
        )
        for ((hour, timeOfDay) in expected) {
            assertEquals(timeOfDay, TimeOfDayResolver.fromLocalHour(hour), "$hour 時")
        }
    }

    @Test
    fun `0から23の外は夜にする`() {
        // Swift の switch の default と同じ。例外にしない
        assertEquals(TimeOfDay.NIGHT, TimeOfDayResolver.fromLocalHour(-1))
        assertEquals(TimeOfDay.NIGHT, TimeOfDayResolver.fromLocalHour(24))
    }

    @Test
    fun `撮影地のオフセットでなく端末のタイムゾーンの時で決まる`() {
        // ニューヨークで 17:30（EST・-05:00）に撮った写真を、東京の端末で投稿する。撮影地では夕方だが、東京では 7:30 なので朝
        val tokyo = ZoneId.of("Asia/Tokyo")
        val capturedAt = ExifDateTimeParser.parse("2026:01:15 17:30:00", "-05:00", tokyo)!!
        val hourOnDevice = capturedAt.atZone(tokyo).hour
        assertEquals(7, hourOnDevice)
        assertEquals(TimeOfDay.MORNING, TimeOfDayResolver.fromLocalHour(hourOnDevice))
    }
}
