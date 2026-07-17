# Living Sky 第2次調査 統合レポート（Deep Research ワークフロー・2026-07-17）⭐️

/deep-research ワークフロー（検索5並列→取得→3票敵対検証→統合）の結果。検証済み8件・傍証17件。
第1次レポート = `living-sky-research-2026-07.md`（方式C+B+D…v7で実装→「振動」評価で棄却）。

## 結論（Q5）

1. **シェーダ単独でのピクセルワープによる「写真自身の空の可視ドリフト」は不可能**——実装7回・数理・知覚科学（下記Q4）の三重確認。
2. **商用製品の答えは「実写雲素材の重ね合わせ/差し替え」**（Motionleap 自動空・Adobe公式手順とも）。
3. **真の正面突破はニューラル**（特徴量空間ワープ＋デコーダ）だがモバイル前例ゼロ・数ヶ月規模。
4. → **採用方針 = B案「雲オーバーレイ」**: 写真はワープせず、上に動く雲レイヤーを重ねる。
   - B2（第一試作）: タイル化ノイズの手続き的雲ベールをシェーダ内で生成。タイル周期=ループ長に整合させると**一方向ドリフトが継ぎ目ゼロ**（静止画ワープの「戻る」制約が自前レイヤーには無い）。素材・ライセンス・デコード不要。
   - B1（格上げ先）: 実写ループ雲素材（CC0系・オフラインでシーム処理）を色転写して重ねる。B2の質感が合成臭い場合に採用。

## Q1: 商用アプリの実現手段【検証済み】

- **Lightricks（Motionleap開発元）が出荷した唯一の変位ワープ論文**（SIGGRAPH 2021, dl.acm.org/10.1145/3450626.3459935・2-1票×2）: 「窓・階段など**繰り返し構造**」専用。雲・空は対象外。モバイル実時間動作（傍証U17）。
- **Motionleap の自動空アニメ = 実写雲素材への完全差し替え**（第1回run・tapsmart）。手動モードはユーザーがPath/Anchorを描く人力。
- **Adobe 公式 Photoshop シネマグラフ手順 = ストックループ動画をマスク領域に重ねる**（傍証U16・blog.adobe.com）。
- Microsoft 系特許2件はいずれも**動画入力前提**（3-0票）で単一静止画には非適用。

## Q2: ニューラル系【一部検証済み】

- **Endo et al. 2019 (Animating Landscape)**（3-0票×2）: 動き CNN と色変化 CNN を分離学習。**ループはニューラルでも「ただのクロスフェード」で閉じる**。毎フレーム元画像から再サンプル（ブラー蓄積回避・傍証U12は arXiv:2109.02216 の同型知見）。GPUで1010フレーム98秒。
- **Text2Cinemagraph (SIGGRAPH Asia 2023)**（2-0票）: ニューラルフロー予測＋softmax-splatting。**実写写真に直接使える Real Domain パスあり**。MIT・checkpoint 公開（傍証U1）。**ML版(v9+)の第一候補**。
- Holynski EMF (CVPR 2021): 特徴量空間ワープ＋前後双方向スプラット＋デコーダ（傍証U4/U5/U8/U9）。ピクセル空間へ翻訳すると当方の v5/v7 と同型＝デコーダ（描き足し）が本質。公式コード非公開（第1回run）。
- StyleCineGAN (CVPR 2024): GAN inversion 経由＝**出力が元写真でなくなる**ため要件非互換（第1回run）。
- SLR-SFS (ICCV 2023 Oral): 公開・MITだが**推論にユーザーのモーションヒント必要**（傍証U7）＝全自動要件と不一致。
- CoreML 変換障壁: データ依存制御フローの trace 変換問題（第1回run・apple coremltools docs）。

## Q3: 未検証シェーダ技の評価

- **二相クロスフェードの既知の副作用**（catlikecoding・傍証U13-15）: 実効ループ長が半分になる／位相Bを空間オフセットして「同じ絵の繰り返し」感を薄める——当方の v4 実装は既にこの定石を消化済み。新規の抜け道は無し。
- 層分離アドベクション・長周期化: 直接の文献証拠なし。Q4 の知覚限界により「見える速度×融合する分身幅」の同時達成は原理不可のため、期待薄と判断。
- **オーバーレイ（B案）: 業界標準そのもの**（Q1参照）。トライレンマの外側にある唯一の実装可能解。

## Q4: 知覚閾値【最重要の新知見】

**Braddick (1971) 短距離見かけの運動**（傍証U11・wexler.free.fr所蔵PDF）: 交互提示ランダムドットが「1つの動く物体」に融合するのは変位 **約5分角まで**。**15〜20分角で完全崩壊**（=2枚の別の絵に見える＝分身）。
iPhone 視聴距離(約30cm)換算:
- 融合限界 ≈ 画面上約 **3pt（≈8 作業px @1080）** → v7 の3px分身が「見えなかった」理由
- 完全崩壊 ≈ **20〜30 作業px** → v4 の20px分身が「くっきり見えた」理由
- 系: 二相方式で許される最大ループ移動量 A ≈ 16px → ドリフト速度 A/T ≈ 2.7px/s (T=6s) = 知覚下限未満。
  **「見える流れ」と「融合する分身」は知覚科学的に両立不可**。

## v8（B2案）設計メモ

- 写真は不変（ワープ全廃）→ warpMask/safeSample も不要・電線/電柱は原理的に安全
- 雲ベール = **タイル化 value noise/fbm**（格子座標を周期 P で mod）を風向きに `offset = windDir · (t/T) · k·L`（k=整数周期/ループ）でスクロール → `t=T` で場が厳密に一致＝**一方向ドリフト×完全ループ**
- 2層（k=1 と k=2）で速度差パララックス。層ごとに noise seed/スケール変更
- 色 = prepare 時に空領域の平均色を計測し、明側に寄せたベール色を kernel へ（写真パレット転写）
- 合成 = screen/soft-light 系 × 強度スライダー × 既存 compositeMask。シマー（光の呼吸）は既存のまま
- 速さスライダー → k∈{1,2,3} に量子化（連続速度はループ整合と非両立）
- 弱点想定: 質感が合成的に見える場合 → B1（実写素材）へ格上げ

## 出典一覧（主要）
- https://dl.acm.org/doi/10.1145/3450626.3459935（Lightricks/Pixaloop 出荷アルゴリズム）
- https://ar5iv.labs.arxiv.org/html/1910.07192（Endo et al. Animating Landscape）
- https://github.com/text2cinemagraph/text2cinemagraph（MIT・Real Domain）
- https://eulerian.cs.washington.edu/ ・ https://arxiv.org/abs/2011.15128（Holynski EMF）
- https://github.com/jeolpyeoni/StyleCineGAN ・ https://github.com/simon3dv/SLR-SFS
- http://wexler.free.fr/library/files/braddick%20(1971)%20a%20short-range%20process%20in%20apparent%20motion.pdf（知覚閾値）
- https://catlikecoding.com/unity/tutorials/flow/texture-distortion/（二相フローの定石と副作用）
- https://blog.adobe.com/en/publish/2019/02/26/create-cinemagraphs-in-a-snap-with-photoshop-and-adobe-stock（Adobe公式=オーバーレイ）
- https://patents.google.com/patent/US20180025749A1/en ・ https://patents.google.com/patent/US10242710B2（動画入力前提の特許）
