// ⭐️ 切り抜きの範囲の計算（Kiro android-edit-tools タスク 2.2・K0・design.md:509-516、中身はタスク 5・C2）
package com.yoshidometoru.soramoyou.contract.edit

/**
 * 切り抜きの範囲の計算。範囲は常に絵の内側（0〜1）で、各辺は [MIN_SIDE] 以上。
 * 縦横比の固定・細かい傾き・反転は入れない（design.md D-4・利用者の判断 U3）。
 */
object CropMath {
    const val MIN_SIDE = 0.15                                         // iOS CropOverlayView.swift:35

    /** 浮動小数の誤差で「ちょうど 0.15」が弾かれないための余裕 */
    private const val EPS = 1e-9

    enum class Handle { TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT, MOVE }

    /**
     * 内側に限り、各辺を MIN_SIDE 以上に保つ。dx・dy は絵に対する割合（右・下が正）。
     *
     * 写した元：iOS CropOverlayView.swift の moveGesture（131-146 行）と resizeGesture（151-213 行）。
     * 縦横比の固定（applyAspect）は除いた。
     * - MOVE：大きさを保ち、位置を [0, 1−幅] / [0, 1−高さ] に切り詰める（iOS 138-139 行）
     * - 4 隅：動かす辺だけ dx / dy を足し、反対側の辺から MIN_SIDE 以上離し（iOS 171-184 行）、絵の内側に切り詰める（iOS 187-190 行）
     *   iOS は「最小の大きさ → 内側」の順だが、こちらは動かす辺を「内側 かつ 反対側から MIN_SIDE」の範囲に収める 1 回の切り詰めで
     *   同じ結果になる（反対側の辺は動かないので、範囲は [0, 反対側−MIN] または [反対側+MIN, 1] になる）。
     */
    fun dragged(start: NormalizedRect, handle: Handle, dx: Double, dy: Double): NormalizedRect {
        if (handle == Handle.MOVE) {
            val newLeft = clampTo(start.left + dx, 0.0, 1.0 - start.width)
            val newTop = clampTo(start.top + dy, 0.0, 1.0 - start.height)
            return NormalizedRect(newLeft, newTop, newLeft + start.width, newTop + start.height)
        }
        var left = start.left
        var top = start.top
        var right = start.right
        var bottom = start.bottom
        // 左側の取っ手は左辺、右側の取っ手は右辺を動かす（iOS 160-170 行）
        when (handle) {
            Handle.TOP_LEFT, Handle.BOTTOM_LEFT -> left = clampTo(left + dx, 0.0, right - MIN_SIDE)
            else -> right = clampTo(right + dx, left + MIN_SIDE, 1.0)
        }
        when (handle) {
            Handle.TOP_LEFT, Handle.TOP_RIGHT -> top = clampTo(top + dy, 0.0, bottom - MIN_SIDE)
            else -> bottom = clampTo(bottom + dy, top + MIN_SIDE, 1.0)
        }
        return NormalizedRect(left, top, right, bottom)
    }

    /**
     * 1 つの辺を step（既定 5%）だけ動かす。inward＝内側へ（範囲を小さく）、false＝外側へ（大きく）。
     * 絵の内側と MIN_SIDE を超える分は切り詰める（動かせなければ同じ範囲を返す）。
     * 取っ手を引かずに範囲を変える手段（design.md:1000）。iOS には無い。
     */
    fun nudged(rect: NormalizedRect, edge: Edge, inward: Boolean, step: Double = 0.05): NormalizedRect {
        return when (edge) {
            Edge.LEFT -> rect.copy(left = clampTo(rect.left + if (inward) step else -step, 0.0, rect.right - MIN_SIDE))
            Edge.TOP -> rect.copy(top = clampTo(rect.top + if (inward) step else -step, 0.0, rect.bottom - MIN_SIDE))
            Edge.RIGHT -> rect.copy(right = clampTo(rect.right + if (inward) -step else step, rect.left + MIN_SIDE, 1.0))
            Edge.BOTTOM -> rect.copy(bottom = clampTo(rect.bottom + if (inward) -step else step, rect.top + MIN_SIDE, 1.0))
        }
    }

    /**
     * 壊れた値を FULL か、内側の正しい範囲にする。
     * - NaN・無限大が 1 つでもあれば FULL
     * - 各値を 0〜1 に切り詰める（はみ出しだけなら、内側に収めた範囲が残る）
     * - 切り詰めた後に、左≥右・上≥下（逆向き）か、幅・高さが [MIN_SIDE] 未満なら FULL
     * 端末に残った古い・壊れた文書の読み戻しで使う（Loadout / EditDocumentCodec 側から呼ばれる見込み）。
     */
    fun sanitized(rect: NormalizedRect): NormalizedRect {
        val values = doubleArrayOf(rect.left, rect.top, rect.right, rect.bottom)
        if (values.any { !it.isFinite() }) return NormalizedRect.FULL
        val clamped = NormalizedRect(
            rect.left.coerceIn(0.0, 1.0),
            rect.top.coerceIn(0.0, 1.0),
            rect.right.coerceIn(0.0, 1.0),
            rect.bottom.coerceIn(0.0, 1.0),
        )
        if (clamped.width < MIN_SIDE - EPS || clamped.height < MIN_SIDE - EPS) return NormalizedRect.FULL
        return clamped
    }

    enum class Edge { LEFT, TOP, RIGHT, BOTTOM }

    /**
     * value を lo〜hi に切り詰める。`coerceIn` と違い lo > hi でも例外を投げず lo を返す
     * （0.85+0.15 のような浮動小数の誤差や、壊れた範囲が渡されても落ちないため）。
     */
    private fun clampTo(value: Double, lo: Double, hi: Double): Double = if (lo > hi) lo else value.coerceIn(lo, hi)
}
