#!/usr/bin/env python3
"""iPhone 提出スクショ(実写アプリ画面)を iPad(2048×2732)ポスターに変換する。

採用版 iPhone パネル(appstore-submit/04-08)は「グラデ＋見出し＋iPhone モックアップに
実写アプリ画面」の縦長(0.46)構図で、採用版の実写は canonical パネルに焼き込まれている。
iPad ネイティブ UI は引き伸ばしレイアウトで見栄えが悪いため(既存 appstore/ipad_* で確認)、
iPhone 実写画面をそのまま使い iPad 比率に「横レターボックス」する:

  1. パネルを iPad 高さ(2732)に合わせて縮小し、横方向中央に配置
  2. 左右に空く余白を「純グラデ列」で埋めてシームレスに広げる
     - 純グラデ列 = 電話/影/2枚目の電話が乗らない縦1列(各パネルで手動指定)
     - グラデは縦方向(横方向にほぼ均一)なので片側の純列で両余白を埋めてよい
     - search は右端列に主電話のベゼル角が数行だけ混入するため、青くない行
       (R>=B-8)や暗い行(max<70)を線形補間で除去してから使う(blue=True)

出力は RGB / アルファなし / 2048×2732(ASC 13" iPad スロット適合)。
"""
from PIL import Image
import numpy as np

TW, TH = 2048, 2732  # iPad 13" portrait

# (入力, 出力名, 純グラデ列の原画 x 座標, 青グラデ汚染除去)
SPECS = [
    ("appstore-submit/04-filter-1320x2868.png",    "04-filter",    0,    False),
    ("appstore-submit/05-edittools-1320x2868.png", "05-edittools", 3,    False),
    ("appstore-submit/06-style-1320x2868.png",     "06-style",     0,    False),
    ("appstore-submit/07-postinfo-1320x2868.png",  "07-postinfo",  1295, False),
    ("appstore-submit/08-search-1320x2868.png",    "08-search",    1305, True),
]
OUT_DIR = "appstore-submit-ipad"


def _gauss1d(x: np.ndarray, sigma: float) -> np.ndarray:
    """1次元ガウシアン平滑化（端は edge パディング）。補間セグメント境界の折れを均す。"""
    r = int(sigma * 3)
    k = np.exp(-(np.arange(-r, r + 1) ** 2) / (2 * sigma * sigma))
    k /= k.sum()
    return np.convolve(np.pad(x, (r, r), mode="edge"), k, mode="valid")


def gradient_column(scaled: Image.Image, sx: int, blue: bool) -> Image.Image:
    """スケール済みパネルの x=sx 列を取り出し、必要なら汚染行を補間で除去して返す。"""
    col = np.asarray(scaled)[:, sx, :].astype(float)  # (TH, 3)
    if blue:
        # 08-search のみ: 右端純グラデ列に主電話のベゼル角が数行混入するため、
        # 青くない/暗い行を線形補間で除去 → さらに縦ガウシアンで補間境界の折れ
        # （横方向の段＝継ぎ目に見える）を均してシームレスにする。
        contam = (col[:, 0] >= col[:, 2] - 8) | (col.max(axis=1) < 70)
        idx = np.arange(len(col))
        good = ~contam
        for c in range(3):
            col[:, c] = np.interp(idx, idx[good], col[good, c])
        for c in range(3):
            col[:, c] = _gauss1d(col[:, c], 60)
    return Image.fromarray(np.clip(col, 0, 255).astype("uint8").reshape(len(col), 1, 3))


def main() -> None:
    import os
    os.makedirs(OUT_DIR, exist_ok=True)
    for src, name, gx, blue in SPECS:
        im = Image.open(src).convert("RGB")
        w, h = im.size
        nw = round(w * TH / h)
        scaled = im.resize((nw, TH), Image.LANCZOS)
        sx = min(int(gx * nw / w), nw - 1)
        grad = gradient_column(scaled, sx, blue)

        canvas = Image.new("RGB", (TW, TH))
        ox = (TW - nw) // 2
        canvas.paste(scaled, (ox, 0))
        if ox > 0:
            canvas.paste(grad.resize((ox, TH)), (0, 0))
            canvas.paste(grad.resize((TW - (ox + nw), TH)), (ox + nw, 0))

        out = f"{OUT_DIR}/{name}-2048x2732.png"
        canvas.save(out)
        print(f"OK {out}  ({canvas.size[0]}x{canvas.size[1]} RGB)")


if __name__ == "__main__":
    main()
