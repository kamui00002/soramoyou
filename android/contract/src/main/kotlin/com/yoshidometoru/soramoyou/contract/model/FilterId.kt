// ⭐️ 投稿のフィルターの識別子と色の変換（タスク 20.3・要件 6.6・8.3・16.1）
package com.yoshidometoru.soramoyou.contract.model

/**
 * フィルター（iOS と同じ 10 種）。[raw] は iOS 版の `FilterType.rawValue`、[displayName] は画面に出す日本語で、どちらも iOS と 1 文字も違わない。
 * 「フィルターなし」はこの enum に入れず、`null` で表す（設計書 :847 の `filter: FilterId?`）。iOS の選択肢の見出しは「なし」
 * （EditView.swift:833）。表示は 21.2 の画面が受け持つ。
 *
 * 出典（読んだ現物）:
 * - 文字列値と並び順：Soramoyou/Soramoyou/Models/FilterType.swift:12-21（iOS の 10 種の並びと同じ）
 * - 表示名：同 :24-36
 * - 4×5 の行列（[legacyMatrix]）を持つのは今の 6 種だけ。`natural` は iOS の実装が恒等変換、
 *   `warm`・`cool`（色温度）と `vintage`（セピアと周辺減光）は 1 枚のカラーマトリクスで表せないので、[legacyMatrix] は null
 *   （色は ColorKernel が受け持つ。Kiro android-edit-tools design.md:552-565）
 *
 * [raw] は、将来 iOS の `editSettings.appliedFilter`（EditSettings.swift:216, 250-252）へそのまま写せる値である（要件 8.3）。
 *
 * ## 色の変換（[legacyMatrix]）
 * プレビュー（Compose の `ColorFilter.colorMatrix`）と出力（`Canvas` と `ColorMatrixColorFilter`）の両方が、この 1 か所の定義を使う（設計書 :842）。
 * 形は Android の `ColorMatrix` と同じ 4 行 × 5 列の行優先で、R' = a·R + b·G + c·B + d·A + e。**5 列目 e は 0〜255 の尺度**である
 * （明るさ 0.1 は 25.5 になる。0〜1 のまま入れると効かない）。Compose の `ColorMatrix` も同じ配置・尺度であることを、
 * タスク 21.2 で端末（AVD・API 36）で実測した：一様な灰 128 と (200, 100, 50) の画像に 6 種を掛けたプレビューの画素が、
 * この行列を 0〜255 の尺度で掛けた値と 12 点すべて一致した（「なし」の 2 点を含め 14 点。手元（git の外）の `21.2-pixels.txt`）。
 *
 * ### iOS の係数から行列を作る方法
 * iOS の 6 種の係数は、FilterGraphBuilder.swift:496-515, 543-563 と ImageService.swift の `applyClearFilter` などの 2 か所にあり、
 * 2026-10-09 の時点で**値は一致していた**（どちらを出発点にしても同じ）。
 *
 * 1. 彩度・コントラスト・明るさ（clear・drama・soft・pastel・vivid の `CIColorControls`）
 *    Core Image の式を、作業色空間を sRGB にして 1 画素で実測した（手元（git の外）の `20.3-ci.swift`・`20.3-ci.tsv`）。
 *    - 彩度 s：輝度 L＝0.2125R＋0.7154G＋0.0721B を軸に、L＋s·(c−L)
 *    - コントラスト k：0.5 を軸に、k·(c−0.5)＋0.5
 *    - 明るさ b：コントラストの**後**に、全ての色に b を足す
 *    - 輝度の重みの和が 1 なので、彩度は平行移動（明るさとコントラストの軸）に影響しない。行列は k·S(s)、平行移動は 0.5·(1−k)＋b
 * 2. モノクロ（`CIColorMonochrome`・白・強度 1）
 *    実測で、出力は**線形の輝度の 2 倍**だった（灰 0.5 を sRGB の作業空間で通すと 1.0 になる）。ガンマ付きの値にそのまま 2 を掛けると
 *    中間の灰が白に飛ぶので、線形で 2 倍に相当する 2^(1/2.2) ≈ 1.37 倍をガンマ付きの輝度に掛ける。iOS アプリの実際の作業空間
 *    （線形 sRGB：CIContextPool.swift:50）で灰 0.5 が 0.686 になる実測（`20.3-mono.tsv`）と合う
 *
 * ### iOS と見た目が一致しないこと（決定事項 D1 の範囲）
 * iOS は線形の光の量で計算し、Android の `ColorMatrix` はガンマ付きの値に掛けるので、同じ係数でも見た目は一致しない。
 * iOS アプリと同じ条件で 343 色に掛けた実出力と比べると、平均の差は 0〜1 の尺度で 0.04〜0.09（`20.3-formula.py`）。
 * 実出力に最小二乗で合わせる案（`20.3-fit.py`）は平均の差が小さくなるが、モノクロで黒が 0.23 の灰色に浮くなどの欠陥が出るので採らない。
 */
enum class FilterId(val raw: String, val displayName: String) {
    NATURAL("natural", "ナチュラル"),
    CLEAR("clear", "クリア"),
    DRAMA("drama", "ドラマ"),
    SOFT("soft", "ソフト"),
    WARM("warm", "ウォーム"),
    COOL("cool", "クール"),
    VINTAGE("vintage", "ビンテージ"),
    MONOCHROME("monochrome", "モノクロ"),
    PASTEL("pastel", "パステル"),
    VIVID("vivid", "ヴィヴィッド");

    /**
     * このフィルターの 4×5 のカラーマトリクス（20 要素・行優先・5 列目は 0〜255 の尺度）。今の 6 種だけが持ち、
     * ナチュラル・ウォーム・クール・ビンテージは null。
     * 呼び出しごとに新しい配列を返す（共有の配列を書き換えられないように）。
     */
    fun legacyMatrix(): FloatArray? = when (this) {
        // 係数は FilterGraphBuilder.swift の各 case と同じ値
        CLEAR -> colorControls(saturation = 1.1f, contrast = 1.05f)
        DRAMA -> colorControls(saturation = 1.2f, contrast = 1.3f)
        SOFT -> colorControls(saturation = 0.8f, contrast = 0.9f)
        MONOCHROME -> monochrome()
        PASTEL -> colorControls(saturation = 0.6f, contrast = 0.9f, brightness = 0.1f)
        VIVID -> colorControls(saturation = 1.5f, contrast = 1.2f)
        NATURAL, WARM, COOL, VINTAGE -> null
    }

    companion object {
        /**
         * 文字列値からフィルターを引く。Swift の `init(rawValue:)` と同じく、完全一致・大文字小文字を区別する。
         * 未知の文字列・`null` は `null` を返す。
         */
        fun fromRaw(raw: String?): FilterId? = entries.firstOrNull { it.raw == raw }

        /** Core Image の `CIColorControls` の輝度の重み（実測。クラスの説明を参照）。 */
        private val LUMA = floatArrayOf(0.2125f, 0.7154f, 0.0721f)

        /** 線形で 2 倍に相当する、ガンマ付きの値への倍率（クラスの説明のモノクロ）。 */
        private val MONOCHROME_GAIN = Math.pow(2.0, 1.0 / 2.2).toFloat()

        /** `CIColorControls` と同じ式の行列。行 i は k·((1−s)·LUMA ＋ s·e_i)、平行移動は (0.5·(1−k)＋b)·255。 */
        private fun colorControls(saturation: Float, contrast: Float, brightness: Float = 0f): FloatArray {
            val offset = (0.5f * (1f - contrast) + brightness) * 255f
            return FloatArray(20).also { m ->
                for (row in 0 until 3) {
                    for (col in 0 until 3) {
                        val identity = if (row == col) saturation else 0f
                        m[row * 5 + col] = contrast * ((1f - saturation) * LUMA[col] + identity)
                    }
                    m[row * 5 + 4] = offset
                }
                m[3 * 5 + 3] = 1f   // 不透明度はそのまま
            }
        }

        /** モノクロの行列。R・G・B の 3 行とも、輝度 × [MONOCHROME_GAIN]。 */
        private fun monochrome(): FloatArray = FloatArray(20).also { m ->
            for (row in 0 until 3) {
                for (col in 0 until 3) m[row * 5 + col] = LUMA[col] * MONOCHROME_GAIN
            }
            m[3 * 5 + 3] = 1f
        }
    }
}
