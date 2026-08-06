// ⭐️ PersonalDefaultThumbnailComparer.swift
// パーソナルAI編集（柱1 v2）: 「AIで自動編集」候補シートの重複判定を、
// レシピの数値差ではなく実際に描画したサムネイル画像同士の見た目の差で行うための純関数
//
//  PersonalDefaultThumbnailComparer.swift
//  Soramoyou
//

import UIKit

/// 「AIで自動編集」候補シートに並ぶ候補が、見た目として区別できるかどうかを判定する純関数群。
///
/// ## 背景
/// 従来 `PersonalDefaultCandidateProvider.isSimilar(_:_:)` はレシピの数値差
/// （`exposureEV` や `saturationCI` などの差分）だけで重複判定していた。
/// しかし実測（後述）では、「数値上は別物なのに見た目はほぼ同じ」という組み合わせが
/// 存在することが分かった。レシピの数値差だけでは「見た目は同じなのに候補として並ぶ」を
/// 防げないため、この enum では実際に描画された画像そのものを比較する方式を提供する。
/// 副作用なし・I/O なしの純粋な計算のみ（UIKit/CoreGraphics のみに依存し、
/// Firebase 等の外部サービスには依存しない）。
enum PersonalDefaultThumbnailComparer {
    /// 「見た目が違う」と判定する平均絶対差の閾値（0〜255スケール）。
    ///
    /// ## 較正の根拠（2026-08-04 実測・シミュレータ実機描画経路）
    /// `test_sim` でシミュレータ上の実際の Metal/CoreImage 描画経路を通し、
    /// 一時的な較正テスト（TEMP_ThumbnailComparerCalibrationTests、実測後に削除済み）で
    /// `ImageService.applyEditRecipe` の実出力を比較して測定した値。
    /// 基準レシピ（exposureEV=0.3 / saturationCI=1.15 / contrastCI=1.05）を合成空写真3種
    /// （①明るい青空+雲 ②夕焼け相当の暖色グラデーション ③暗めの曇天・低彩度）に適用した画像を
    /// 基準とし、各バリアントとの meanAbsoluteDifference（32×32縮小・0〜255スケール）を測定した。
    ///
    /// 閾値決定に必要な実測値（3画像中で最も厳しい値を太字で表記）:
    ///
    /// | 画像                   | warmthNorm+0.10 | saturationCI+0.08 | filter=vivid | filter=warm | filter=cool | filter=drama |
    /// |---|---|---|---|---|---|---|
    /// | ①明るい青空+雲         | 0.71             | 1.98               | 20.54        | 8.56        | **4.16**    | 19.32        |
    /// | ②夕焼けグラデーション   | 0.60             | **3.25**           | 39.02        | 6.26        | 4.62        | 37.55        |
    /// | ③暗めの曇天             | 0.80             | 0.23               | 22.69        | 7.18        | 4.91        | 33.94        |
    ///
    /// - 「見分けがつかないはず」の微差（warmthNorm+0.10 / saturationCI+0.08）の3画像中の最大値は
    ///   **3.25**（②夕焼け・saturationCI+0.08）→ 閾値はこれより大きくなければならない。
    /// - 「見分けがつくはず」の固定プリセット4種（vivid/warm/cool/drama。`natural` を除外する理由は
    ///   下記参照）の3画像中の最小値は **4.16**（①明るい青空・filter=cool）→ 閾値はこれ以下でなければならない。
    /// - 有効レンジは **(3.25, 4.16]**。中央付近を取り、両側にほぼ均等なマージン（約0.45〜0.46）を
    ///   残す **3.7** を採用した。
    ///
    /// ## `filter=natural` を必須distinct対象から除外する理由
    /// `FilterGraphBuilder.applyFilter(_:to:)` の `.natural` ケース（`FilterGraphBuilder.swift:412-413`、
    /// `case .natural: return image`）は**恒等変換**であり、他フィールド値が同一の「フィルタなし」レシピと
    /// `.natural` 適用後のレシピは、どの画像・どの閾値でも必ず meanAbsoluteDifference=0.0 になる
    /// （実測でも3画像すべてで厳密に0.0）。これは比較解像度（32×32）や閾値の調整では解決できない、
    /// コード上の構造的事実である。
    /// 実際の候補プールでは `FixedPresetKind.natural.recipe` は常に完全に中立な `EditRecipe()`
    /// （exposureEV=0 等）+ `appliedFilter=.natural` であり、「あなたの定番」等の他候補は
    /// `EditRecipe.isNeutral` によるコーパス書き込み時ゲート（未編集投稿を学習コーパスに含めない）
    /// のため中立値と一致することが実質的にない。したがって実運用でこの恒等変換由来の重複判定が
    /// 発生することは想定していない。もし将来 `FixedPresetKind.natural` の生成方法が変わり、
    /// 「フィルタなしレシピと同一の他フィールド値」を持つ候補と共存するようになった場合、
    /// この2候補は必ず重複（not distinct）と判定される点に注意すること。
    ///
    /// ## 副次的な注意点（閾値算出はブロックしないが要認識）
    /// `contrastCI+0.08` の差分（①4.33 / ②5.42 / ③6.81）は①の `filter=cool`（4.16）より大きい。
    /// 「ごくわずかなコントラスト変更」の方が「クールプリセット」より強く distinct 判定される
    /// 逆転現象が起きている。`contrastCI` の微差は今回の「必ず not distinct」対象に含まれていない
    /// ため閾値選定はブロックしないが、このメトリクスの識別力が全項目で単調ではないことを示す
    /// 実例として記録しておく。
    static let distinctThreshold: Double = 3.7

    /// 比較用にダウンスケールする一辺のピクセル数。
    ///
    /// 32×32 という小さいサイズに両画像を揃えてから比較する理由は2つ:
    /// 1. サムネイル表示サイズでの知覚に近づけるため。フル解像度のまま比較すると
    ///    「実際にユーザーが見る縮小表示では同じに見えるのに、フル解像度の細部の違いで
    ///    "区別できる" と誤判定してしまう」というズレが起きる。
    /// 2. ノイズ・アンチエイリアシングなど局所的なブレを平均化して安定した差分値を得るため。
    ///    ダウンスケール時の面積平均（`CGContext.draw` によるリサンプリング）が
    ///    自然なノイズ低減フィルタとしても働く。
    private static let compareSide: Int = 32

    /// 比較不能（CGImage・ピクセルバッファが取得できない等）の場合に返す番兵値。
    ///
    /// `distinctThreshold` を確実に超える値にしてあるため、この値が返ると
    /// `isVisuallyDistinct` は必ず「区別できる」側と同じ扱い（＝その候補とは重複しない）になる。
    /// 判定不能を「同じ」扱いにしてしまうと候補が黙って候補シートから消えてしまい、
    /// 誤って「区別できる」と扱って候補が1つ余分に残ることよりも実害が大きいため、
    /// 比較不能時は常に「区別できる」側に倒す設計判断。
    private static let incomparableSentinel: Double = .greatestFiniteMagnitude

    /// 2 枚の画像の知覚差を、32×32 にダウンスケールした RGB の平均絶対差（0〜255スケール）として返す。
    ///
    /// アルファチャンネルは比較対象に含めない。`downscaledRGBAPixels` が `noneSkipLast`
    /// （アルファ合成なし・RGB のみ有効）でバッファへ描画するため、そもそも半透明ピクセルの
    /// RGB がアルファでスケールされる（プリマルチプライ）心配がなく、常に生の RGB 値を比較できる。
    /// どちらかの画像から CGImage・ピクセルバッファが取得できず比較不能な場合は
    /// `incomparableSentinel`（＝ 閾値を必ず超える大きな値）を返す。
    static func meanAbsoluteDifference(_ a: UIImage, _ b: UIImage) -> Double {
        guard
            let pixelsA = downscaledRGBAPixels(a),
            let pixelsB = downscaledRGBAPixels(b)
        else {
            return incomparableSentinel
        }

        var totalAbsDiff: Double = 0
        var sampleCount = 0
        var index = 0
        while index < pixelsA.count {
            // RGBA のうち R/G/B の3チャンネルだけ加算する（index+3 のアルファはスキップ）。
            totalAbsDiff += abs(Double(pixelsA[index]) - Double(pixelsB[index]))
            totalAbsDiff += abs(Double(pixelsA[index + 1]) - Double(pixelsB[index + 1]))
            totalAbsDiff += abs(Double(pixelsA[index + 2]) - Double(pixelsB[index + 2]))
            sampleCount += 3
            index += 4
        }

        guard sampleCount > 0 else { return incomparableSentinel }
        return totalAbsDiff / Double(sampleCount)
    }

    /// 候補画像 `candidate` が、既に採用済みの画像群 `accepted` のいずれとも見分けがつくか
    /// （＝どれとも重複していないか）を判定する。
    ///
    /// `accepted` のどれか1枚とでも `meanAbsoluteDifference` が `distinctThreshold` 未満なら、
    /// その1枚と見た目が同じ＝重複とみなし false を返す。`accepted` が空（まだ何も採用していない）
    /// 場合は比較対象が無いので無条件で true。
    static func isVisuallyDistinct(_ candidate: UIImage, from accepted: [UIImage]) -> Bool {
        for acceptedImage in accepted {
            if meanAbsoluteDifference(candidate, acceptedImage) < distinctThreshold {
                return false
            }
        }
        return true
    }

    /// 画像を `compareSide` × `compareSide` の RGBX8（`noneSkipLast` = アルファ合成なし）バッファへ
    /// 描画し、生ピクセル配列を返す。CGImage が取得できない・CGContext の生成に失敗した場合は nil。
    ///
    /// `noneSkipLast` を使う理由: `premultipliedLast` だと半透明ピクセルの RGB がアルファで
    /// スケール（プリマルチプライ）されてしまい、「アルファは無視して RGB だけ比較する」という
    /// 意図と食い違う（アルファ差が RGB 値に紛れ込む）。`noneSkipLast` は下地への合成を行わず
    /// 常に不透明として描画するため、生の RGB 値をそのまま比較できる。
    private static func downscaledRGBAPixels(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }

        var pixels = [UInt8](repeating: 0, count: compareSide * compareSide * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // `&pixels`（inout ポインタ）の有効期間は CGContext(data:) の呼び出し中だけであり、
        // 呼び出しを抜けた後に描画（context.draw）すると無効化されたポインタへ書き込む恐れがある。
        // `withUnsafeMutableBytes` でバッファのポインタが生きているスコープ内に
        // CGContext の生成〜描画を閉じ込めることで、この生存期間問題を避ける。
        let succeeded = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: compareSide,
                height: compareSide,
                bitsPerComponent: 8,
                bytesPerRow: compareSide * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: compareSide, height: compareSide))
            return true
        }

        return succeeded ? pixels : nil
    }
}
