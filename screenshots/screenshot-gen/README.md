# screenshot-gen ☁️

App Store Connect に提出する **そらもよう** のスクリーンショットを、ブラウザ上で 7 枚まとめて生成するための Next.js アプリです。

実機や Simulator で個別に撮影せず、コードで定義したスライド定義（`src/app/page.tsx` 内 `SLIDES`）から端末モックアップ込みの PNG を一括出力できるため、画像を差し替えても常に同一レイアウト・同一解像度を再現できます。

## 構成

- **フレームワーク**: Next.js 16 (App Router) + React 19 + Tailwind CSS 4
- **画像書き出し**: [`html-to-image`](https://github.com/bubkoo/html-to-image) の `toPng` を利用
- **端末モックアップ**: `public/mockup.png`（1022 × 2082px 基準）
- **スクリーンショット素材**: `public/screenshots/*.png`

## 前提環境

- Node.js 20 以上（本体側で bun.lock を採用しているため bun 1.1+ でも可）
- macOS / Linux / Windows いずれも可（ブラウザからの書き出しのため OS 差は出にくい）

## セットアップ

```bash
cd screenshots/screenshot-gen

# 依存関係のインストール（いずれか一つ）
npm install
# or
bun install
```

## 開発サーバー起動

```bash
npm run dev
# → http://localhost:3000
```

## スクリーンショット一括生成の手順

1. `npm run dev` でローカルサーバーを起動し、ブラウザで `http://localhost:3000` を開く
2. 画面上部の **端末サイズセレクタ** で書き出したいサイズを選ぶ
   - `6.9"` → 1320 × 2868（iPhone 16 Pro Max）
   - `6.5"` → 1284 × 2778（iPhone 11 Pro Max など）
   - `6.3"` → 1206 × 2622（iPhone 15 Pro）
   - `6.1"` → 1125 × 2436（iPhone X 〜 11 Pro など）
3. **Export All** ボタンを押すと、`SLIDES` 配列の順に 7 枚が連続ダウンロードされる
   - ファイル名: `01-cover-1320x2868.png` 形式（`連番-スライドID-幅x高さ.png`）
4. ダウンロードされた PNG を `screenshots/appstore/{サイズ}/` 配下に配置する

> 個別に書き出したい場合は各スライドカードの **Export** ボタンを使用する。

### 書き出し精度について

`toPng` のオプションには `canvasWidth` / `canvasHeight` を指定しており、端末サイズごとの縦横比の微差（例: 6.9" と 6.5" で 0.4% 程度）を吸収してピクセル単位で target size に一致させています。単純な `pixelRatio` では App Store Connect の寸法検証を通らないケースがあるため注意。

## 提出先への配置例

```
screenshots/
├── screenshot-gen/         # 本プロジェクト
└── appstore/
    ├── 6.9/
    │   ├── 01-cover-1320x2868.png
    │   └── ...
    ├── 6.5/
    ├── 6.3/
    └── 6.1/
```

## スライドを追加・差し替えるには

1. `src/app/page.tsx` の `SLIDES` 配列を編集（id, タイトル, 本文, 画像パス）
2. 必要なら `public/screenshots/` に素材 PNG を追加
3. 開発サーバーでレイアウトを確認
4. 上記「一括生成の手順」を再実行して PNG を更新

## 本番ビルド確認

レビュー時に型エラー等を確認する用。通常は使用しない。

```bash
npm run build
```

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| 書き出しサイズが 1〜10px ずれる | `toPng` の `canvasWidth`/`canvasHeight` が指定されているか確認（`page.tsx` の `exportSingle`/`exportAll`）|
| 書き出しでテキストが抜ける | フォント読み込み完了前に実行されている可能性。`document.fonts.ready` 後に実行される設計だが、カスタムフォント追加時は要確認 |
| 画像が真っ白になる | `IMAGE_PATHS` に載っていない素材を参照しているケース。`preloadAllImages` に追加する |
