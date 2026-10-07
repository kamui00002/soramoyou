#!/usr/bin/env python3
"""⭐️ 「そらとも」のスクショ（1320×2868）から、ASC の 2 つの入れ物に入れる画像を作る。

1.14 時点の ASC に入っているスクショの入れ物は 2 つだけ（2026-10-08 に ASC API で確認）:
  - APP_IPHONE_65（1284×2778）8 枚
  - APP_IPAD_PRO_3GEN_129（2048×2732）8 枚
6.9"（1320×2868）の入れ物は無いので、そらともも上の 2 サイズで作り、既存の 8 枚の 2 枚目に足す。

作り方は、今ストアにある 8 枚と同じにする:
  - iPhone 6.5": 1320×2868 をそのまま 1284×2778 へ縮小する。
    （ストアの 04-filter・07-postinfo の 1320 版を同じ方法で縮めると、6.5 版と画素差 0 で一致した）
  - iPad: ブランチ「改善-appstoreスクショ新機能2枚」の make-ipad-letterbox.py と同じ「横レターボックス」。
    高さ 2732 に縮めて中央に置き、左右の余白を背景のグラデーションの列で埋める。
    ただし左の余白は左端の列、右の余白は右端の列で埋める（片側の列だけで両方を埋めると、
    見出しの裏の光の分だけ右の境目に継ぎ目が見えたため）。

出力は RGB・アルファなし（ASC はアルファ付き PNG を拒否する）。
使い方: python3 screenshots/make-soratomo-store-sizes.py （リポジトリのルートで実行）
"""
import os

import numpy as np
from PIL import Image

SRC = "screenshots/appstore-2026-10-07/07-soratomo-1320x2868.png"
OUT_DIR = "screenshots/appstore-2026-10-07"

IPHONE_65 = (1284, 2778)  # ASC APP_IPHONE_65
IPAD_W, IPAD_H = 2048, 2732  # ASC APP_IPAD_PRO_3GEN_129


def make_iphone_65(src: Image.Image) -> Image.Image:
    """6.9" の画像をそのまま 6.5" の大きさへ縮める（既存の 6.5 版と同じ方法）"""
    return src.resize(IPHONE_65, Image.LANCZOS)


def make_ipad(src: Image.Image) -> Image.Image:
    """iPhone の画像を iPad の台紙の中央に置き、左右をそれぞれの端の色で埋める"""
    w, h = src.size
    nw = round(w * IPAD_H / h)  # 高さを 2732 に合わせたときの幅
    scaled = src.resize((nw, IPAD_H), Image.LANCZOS)
    pixels = np.asarray(scaled)

    # 端の 1 列（電話の枠や影が乗らない、背景のグラデーションだけの列）
    left_col = Image.fromarray(pixels[:, 0:1, :].copy())
    right_col = Image.fromarray(pixels[:, nw - 1 : nw, :].copy())

    canvas = Image.new("RGB", (IPAD_W, IPAD_H))
    ox = (IPAD_W - nw) // 2
    canvas.paste(scaled, (ox, 0))
    canvas.paste(left_col.resize((ox, IPAD_H)), (0, 0))
    canvas.paste(right_col.resize((IPAD_W - (ox + nw), IPAD_H)), (ox + nw, 0))
    return canvas


def main() -> None:
    src = Image.open(SRC).convert("RGB")
    outputs = {
        f"{OUT_DIR}/6.5/02-soratomo-1284x2778.png": make_iphone_65(src),
        f"{OUT_DIR}/ipad/02-soratomo-2048x2732.png": make_ipad(src),
    }
    for path, image in outputs.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        image.save(path)
        print(f"OK {path} ({image.size[0]}x{image.size[1]} {image.mode})")


if __name__ == "__main__":
    main()
