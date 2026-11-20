#!/bin/zsh
# ⭐️☀️ 結合テスト用のエミュレータに読ませる rules の写しを作る（Kiro android-mvp 17.1・レビュー R14）
#
# 使い方: android/tools/make-emulator-rules.sh <rules のあるディレクトリ> <写しを置くディレクトリ>
#   start-firebase-emulators.sh が、リポジトリの根と一時ディレクトリを渡して呼ぶ。写しが作れなければ 0 以外で終わり、写しを残さない。
#
# 何を写すか:
#   storage.rules は原本のまま写し、原本と sha256 で一致することを確かめる。
#   firestore.rules は、画像の URL の形（isValidImageUrl）に、Android のエミュレータの Storage の URL の形を 1 行だけ足した写し。
#   エミュレータの Storage の URL（http://10.0.2.2:9199/…）は本番の形に入らず、投稿の写真・アイコンの保存が rules で断られるため
#   （firestore.rules の isValidImageUrl の注記「エミュレーターを起こすときは、その形を足した写しを読ませる」に従う）。
#   確かめること：差し込む所（isValidImageUrl の見出しの行と次の行の組）がちょうど 1 か所・足した行が写しにちょうど 1 行・
#   写しから足した行を除くと原本と sha256 で一致（＝足した所以外は原本と同じ）。
#   原本の isValidImageUrl の形が変わって差し込む所が決まらないときは止める（形を足さない写しで起動すると、結合テストの投稿が
#   rules で断られ、原因が分かりにくい）。
#
# 足す形は、契約の StorageDownloadUrl.EMULATOR_PATTERN（android/contract）と同じ文字列で、名前とクエリの部分は本番の形と同じ
# （EmulatorRulesCopyTest が突き合わせる）。
set -eu

SRC=$1
OUT=$2

# 差し込む所（isValidImageUrl の見出しの行と、その次の行）と、足す 1 行
HEAD_LINE='    function isValidImageUrl(value) {'
NEXT_LINE='      return value == null'
ADD_LINE="             || value.matches('http://10[.]0[.]2[.]2:9199/v0/b/demo-soramoyou[.]appspot[.]com/o/[A-Za-z0-9_.~%-]+([?][A-Za-z0-9_.~%=&-]*)?')"

sha256_of() { shasum -a 256 | cut -d' ' -f1 }

fail() {
  rm -f "$OUT/firestore.rules" "$OUT/storage.rules"
  echo "$1" >&2
  exit 1
}

# storage.rules：原本のまま
cp "$SRC/storage.rules" "$OUT/storage.rules"
a=$(sha256_of < "$SRC/storage.rules")
b=$(sha256_of < "$OUT/storage.rules")
[ "$a" = "$b" ] || fail "storage.rules の写しが原本と一致しない"
echo "storage.rules の写し: sha256 $a（原本と一致）"

# firestore.rules：差し込む所の後ろに 1 行足す。差し込んだ数がちょうど 1 でなければ止める
# （awk の -v は \ を読み替えるので、3 つの行は環境変数で渡す）
HEAD_LINE=$HEAD_LINE NEXT_LINE=$NEXT_LINE ADD_LINE=$ADD_LINE awk '
  { print }
  prev == ENVIRON["HEAD_LINE"] && $0 == ENVIRON["NEXT_LINE"] { print ENVIRON["ADD_LINE"]; n++ }
  { prev = $0 }
  END { exit (n == 1 ? 0 : 3) }
' "$SRC/firestore.rules" > "$OUT/firestore.rules" \
  || fail "firestore.rules に差し込む所（isValidImageUrl の見出しの行と次の行）がちょうど 1 か所でない"

added=$(grep -cxF -- "$ADD_LINE" "$OUT/firestore.rules" || true)
[ "$added" = "1" ] || fail "firestore.rules の写しに足した行がちょうど 1 行でない（$added 行）"

a=$(sha256_of < "$SRC/firestore.rules")
b=$(grep -vxF -- "$ADD_LINE" "$OUT/firestore.rules" | sha256_of)
[ "$a" = "$b" ] || fail "firestore.rules の写しから足した行を除いたものが原本と一致しない"
echo "firestore.rules の写し: 足した 1 行（エミュレータの画像の URL の形）を除くと sha256 $a（原本と一致）"
