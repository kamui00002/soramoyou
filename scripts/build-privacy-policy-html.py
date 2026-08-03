#!/usr/bin/env python3
"""アプリ内プライバシーポリシー本文から、ホスティング用の HTML を生成する。☁️

なぜ生成するのか:
  App Store Connect は「ホストされたプライバシーポリシーURL」を要求するが、
  アプリ内にも同じ本文がある。**2箇所で手書きすると必ずドリフトする**ので、
  `SettingsView.swift` の `privacyPolicyText` を唯一の原本とし、
  HTML はここから機械的に生成する。

使い方:
  python3 scripts/build-privacy-policy-html.py
  → marketing/privacy-policy/index.html を出力

ホスティング先を決めたら、この HTML をそのまま置くだけ（外部依存なし・単一ファイル）。
"""
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Soramoyou/Soramoyou/Views/SettingsView.swift"
OUT = ROOT / "marketing/privacy-policy/index.html"


def extract_policy_text() -> str:
    """`privacyPolicyText` の複数行文字列リテラルを取り出し、共通インデントを除去する。"""
    src = SOURCE.read_text()
    start = src.find("private var privacyPolicyText")
    if start < 0:
        sys.exit("privacyPolicyText が見つかりません（SettingsView.swift の構造が変わった？）")
    m = re.search(r'"""\n(.*?)\n\s*"""', src[start:], re.S)
    if not m:
        sys.exit("privacyPolicyText の複数行リテラルを取り出せません")
    body = m.group(1)
    # Swift の複数行リテラルは閉じ """ のインデントぶんが各行から除かれる。ここでは8スペース固定。
    return "\n".join(l[8:] if l.startswith(" " * 8) else l.lstrip() for l in body.split("\n"))


def to_html_body(text: str) -> str:
    """プレーンテキストを、見出し/箇条書き/リンクを解釈した HTML に変換する。"""
    out = []
    in_list = False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    lines = text.split("\n")
    # 1行目はタイトル扱い（<h1> はテンプレート側で出すのでここでは飛ばす）
    for raw in lines[1:]:
        line = raw.rstrip()
        if not line:
            close_list()
            continue
        esc = html.escape(line)
        # URL をリンクにする（エスケープ後に行う。URL に & が含まれても壊れない）
        esc = re.sub(r"(https?://[^\s]+)", r'<a href="\1">\1</a>', esc)

        if line.startswith("■"):
            close_list()
            out.append(f"<h2>{esc.lstrip('■ ')}</h2>")
        elif line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{esc[2:]}</li>")
        elif re.match(r"^\d+\. ", line):
            close_list()
            out.append(f"<h3>{esc}</h3>")
        elif line.startswith("最終更新日"):
            close_list()
            out.append(f'<p class="updated">{esc}</p>')
        else:
            close_list()
            out.append(f"<p>{esc}</p>")
    close_list()
    return "\n".join(out)


TEMPLATE = """<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>プライバシーポリシー — そらもよう</title>
<meta name="description" content="iOSアプリ「そらもよう」のプライバシーポリシー">
<style>
  :root {{ --bg:#fff; --fg:#1c1c1e; --muted:#6b7280; --accent:#3b82f6; --line:#e5e7eb; --card:#f7f8fa; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#16181c; --fg:#e5e7eb; --muted:#9aa1ab; --accent:#60a5fa; --line:#2c3138; --card:#1e2126; }}
  }}
  * {{ box-sizing: border-box; }}
  body {{
    background: var(--bg); color: var(--fg); margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Hiragino Sans", "Yu Gothic", sans-serif;
    line-height: 1.9; padding: 2.5rem 1.25rem 4rem; max-width: 760px; margin: 0 auto;
  }}
  h1 {{ font-size: 1.6rem; margin: 0 0 .25rem; }}
  h2 {{ font-size: 1.15rem; margin: 2.4rem 0 .6rem; padding-bottom: .35rem; border-bottom: 2px solid var(--line); }}
  h3 {{ font-size: 1rem; margin: 1.5rem 0 .4rem; color: var(--fg); }}
  p {{ margin: .6rem 0; }}
  ul {{ margin: .4rem 0 .9rem; padding-left: 1.4rem; }}
  li {{ margin: .25rem 0; }}
  a {{ color: var(--accent); overflow-wrap: anywhere; }}
  .updated {{ color: var(--muted); font-size: .9rem; margin-bottom: 2rem; }}
  footer {{ margin-top: 3.5rem; padding-top: 1.2rem; border-top: 1px solid var(--line);
            color: var(--muted); font-size: .85rem; }}
</style>
</head>
<body>
<h1>{title}</h1>
{body}
<footer>
  そらもよう — 空を撮る、空を集める<br>
  お問い合わせ: <a href="mailto:soramoyou.app@gmail.com">soramoyou.app@gmail.com</a>
</footer>
</body>
</html>
"""


def main():
    text = extract_policy_text()
    title = text.split("\n")[0].strip()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(TEMPLATE.format(title=html.escape(title), body=to_html_body(text)))
    print(f"生成: {OUT}")
    print(f"  原本: {SOURCE.relative_to(ROOT)} の privacyPolicyText（{len(text)} 文字）")
    print("  ⚠️ アプリ内の本文を変えたらこのスクリプトを再実行してホスト側も更新すること")


if __name__ == "__main__":
    main()
