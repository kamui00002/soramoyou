//
// check-soratomo-download-tokens.js の単体テスト（node:test・firebase-admin 非依存）⭐️☁️
//
// 実行: node --test scripts/check-soratomo-download-tokens.test.js
//
// 件数の数え方・出力の形（トークンの値・パスを出さないこと）・接続先の固定・読み取り専用だけを確かめる
// （本番には触れない）。本番での実行は tasks 15.1（iOS から実際にアップロードした後・ユーザーと一緒に）。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const check = require("./check-soratomo-download-tokens");

// MARK: - テスト用のデータ

/** 偽のトークンの値。出力に出てはいけない（出ていないことを確かめるための目印）。 */
const FAKE_TOKEN = "FAKE-TOKEN-9f2a7c1e";
/** uid とグループ ID を含む偽のパス。出力に出てはいけない。 */
const FAKE_PATH = "soratomo/group-xyz/uid-abc/sky-001/display.jpg";

/** トークン付きのオブジェクトのメタデータ（Storage の file.metadata の形・カスタムメタデータは metadata の中）。 */
function withTokenObject(name = FAKE_PATH) {
  return {
    name,
    contentType: "image/jpeg",
    mediaLink: `https://storage.googleapis.com/download/storage/v1/b/x/o/${FAKE_TOKEN}`,
    metadata: { firebaseStorageDownloadTokens: FAKE_TOKEN },
  };
}

/** トークンの無いオブジェクトのメタデータ（カスタムメタデータはあるが、トークンの項目が無い）。 */
function withoutTokenObject(name = "soratomo/group-xyz/uid-abc/sky-001/thumb.jpg") {
  return { name, contentType: "image/jpeg", metadata: { other: "x" } };
}

// MARK: - hasDownloadToken

test("hasDownloadToken: カスタムメタデータの firebaseStorageDownloadTokens が空でない文字列なら true", () => {
  assert.equal(check.hasDownloadToken(withTokenObject()), true);
});

test("hasDownloadToken: トークンが複数（カンマ区切り）でも true", () => {
  assert.equal(check.hasDownloadToken({ metadata: { firebaseStorageDownloadTokens: "a,b" } }), true);
});

test("hasDownloadToken: 項目が無い・カスタムメタデータが無い・null・undefined は false", () => {
  assert.equal(check.hasDownloadToken(withoutTokenObject()), false);
  assert.equal(check.hasDownloadToken({ name: "x" }), false);
  assert.equal(check.hasDownloadToken({ metadata: null }), false);
  assert.equal(check.hasDownloadToken({ metadata: { firebaseStorageDownloadTokens: null } }), false);
  assert.equal(check.hasDownloadToken(null), false);
  assert.equal(check.hasDownloadToken(undefined), false);
});

test("hasDownloadToken: 空文字・空白だけ・カンマだけは false（トークンが消されて項目だけ残った場合）", () => {
  for (const value of ["", "   ", ",", " , ,"]) {
    assert.equal(check.hasDownloadToken({ metadata: { firebaseStorageDownloadTokens: value } }), false, JSON.stringify(value));
  }
});

test("hasDownloadToken: 項目はオブジェクト直下ではなく metadata の中だけを見る（2 重の metadata）", () => {
  // 直下に同じ名前があっても、カスタムメタデータではないので数えない。
  assert.equal(check.hasDownloadToken({ firebaseStorageDownloadTokens: FAKE_TOKEN }), false);
});

test("hasDownloadToken: 文字列以外の想定外の型は、見落とさないよう true に倒す", () => {
  assert.equal(check.hasDownloadToken({ metadata: { firebaseStorageDownloadTokens: true } }), true);
  assert.equal(check.hasDownloadToken({ metadata: { firebaseStorageDownloadTokens: 123 } }), true);
});

// MARK: - isFolderMarker

test("isFolderMarker: 名前が「/」で終わるものだけフォルダの印", () => {
  assert.equal(check.isFolderMarker({ name: "soratomo/group-xyz/" }), true);
  assert.equal(check.isFolderMarker({ name: FAKE_PATH }), false);
  assert.equal(check.isFolderMarker({}), false);
  assert.equal(check.isFolderMarker(null), false);
});

// MARK: - countDownloadTokens

test("countDownloadTokens: 空の配列は 0 / 0 / 0", () => {
  assert.deepEqual(check.countDownloadTokens([]), { checked: 0, withToken: 0, withoutToken: 0 });
});

test("countDownloadTokens: トークンありとトークン無しの混ざった配列を、正しく分けて数える", () => {
  // ありとなしを同じ件数にしない（3 と 2）。同数だと、判定が逆になっても件数が同じで気づけない。
  const list = [
    withTokenObject(),
    withTokenObject("soratomo/g/u/s2/display.jpg"),
    withTokenObject("soratomo/g/u/s3/display.jpg"),
    withoutTokenObject(),
    { name: "soratomo/g/u/s3/thumb.jpg" },
  ];
  assert.deepEqual(check.countDownloadTokens(list), { checked: 5, withToken: 3, withoutToken: 2 });
});

test("countDownloadTokens: 全部トークンあり・全部トークン無しのとき", () => {
  assert.deepEqual(check.countDownloadTokens([withTokenObject(), withTokenObject()]), { checked: 2, withToken: 2, withoutToken: 0 });
  assert.deepEqual(check.countDownloadTokens([withoutTokenObject(), withoutTokenObject()]), { checked: 2, withToken: 0, withoutToken: 2 });
});

test("countDownloadTokens: フォルダの印は調べた件数に含めない", () => {
  const list = [{ name: "soratomo/" }, { name: "soratomo/group-xyz/" }, withTokenObject()];
  assert.deepEqual(check.countDownloadTokens(list), { checked: 1, withToken: 1, withoutToken: 0 });
});

test("countDownloadTokens: 戻り値は件数 3 つだけ（トークン・名前・パスを持ち出さない）", () => {
  const counts = check.countDownloadTokens([withTokenObject(), withoutTokenObject()]);
  assert.deepEqual(Object.keys(counts).sort(), ["checked", "withToken", "withoutToken"]);
  for (const value of Object.values(counts)) assert.equal(typeof value, "number");
});

test("countDownloadTokens: 渡した配列・オブジェクトを書き換えない", () => {
  const list = Object.freeze([Object.freeze(withTokenObject()), Object.freeze(withoutTokenObject())]);
  const before = JSON.stringify(list);
  check.countDownloadTokens(list);
  assert.equal(JSON.stringify(list), before);
});

// MARK: - formatResult（出力）

test("formatResult: 件数 3 つを出す", () => {
  const out = check.formatResult({ checked: 5, withToken: 3, withoutToken: 2 });
  assert.equal(out, ["調べた件数: 5", "トークンあり: 3", "トークン無し: 2"].join("\n"));
});

test("formatResult: トークンの値・URL・パス（uid とグループ ID）は、数えた結果の出力に現れない", () => {
  const list = [withTokenObject(), withoutTokenObject(), withTokenObject("soratomo/group-xyz/uid-abc/sky-002/display.jpg")];
  const out = check.formatResult(check.countDownloadTokens(list));
  assert.doesNotMatch(out, /FAKE-TOKEN/, "トークンの値を出している");
  assert.doesNotMatch(out, /uid-abc/, "uid を出している");
  assert.doesNotMatch(out, /group-xyz/, "グループ ID を出している");
  assert.doesNotMatch(out, /soratomo\//, "パスを出している");
  assert.doesNotMatch(out, /https?:/, "URL を出している");
  // 件数は出ている（出力が空で通ってしまう偽陽性を避ける）。
  assert.match(out, /調べた件数: 3/);
  assert.match(out, /トークンあり: 2/);
  assert.match(out, /トークン無し: 1/);
});

test("NO_OBJECTS_HINT: 0 件のときの固定の文言は、名前・パスを含まない", () => {
  assert.match(check.NO_OBJECTS_HINT, /0/);
  assert.doesNotMatch(check.NO_OBJECTS_HINT, /soratomo\//);
});

// MARK: - parseArgs

test("parseArgs: 引数なしだけ受け付ける（接続先と範囲は固定）", () => {
  assert.equal(check.parseArgs([]).ok, true);
  for (const argv of [["uid-1"], ["--revoke"], ["--prefix", "x/"], [""]]) {
    assert.equal(check.parseArgs(argv).ok, false, JSON.stringify(argv));
  }
});

// MARK: - 固定している接続先・範囲

test("プロジェクトは soramoyou-ios に固定している（ADC の取り違えで別プロジェクトを読まないため）", () => {
  assert.equal(check.EXPECTED_PROJECT_ID, "soramoyou-ios");
});

test("バケットは soramoyou-ios.firebasestorage.app に固定している", () => {
  assert.equal(check.EXPECTED_BUCKET, "soramoyou-ios.firebasestorage.app");
});

test("調べる範囲は soratomo/ だけ（接頭辞を間違えると、既存の posts の画像まで読んでしまう）", () => {
  assert.equal(check.PREFIX, "soratomo/");
});

test("トークンの項目名は firebaseStorageDownloadTokens", () => {
  assert.equal(check.TOKEN_KEY, "firebaseStorageDownloadTokens");
});

// MARK: - 読み込み・読み取り専用

test("読み込むだけでは firebase-admin を読まない（テストと引数の確認に依存を持ち込まない）", () => {
  const loaded = Object.keys(require.cache).filter((p) => p.includes(`${path.sep}firebase-admin${path.sep}`));
  assert.deepEqual(loaded, []);
});

test("スクリプト本体に、書き込み・削除・URL 発行の呼び出しが無い（本番を読むだけのスクリプトの守り）", () => {
  const source = fs.readFileSync(path.join(__dirname, "check-soratomo-download-tokens.js"), "utf8");
  const forbidden = /\.(delete|save|setMetadata|makePublic|makePrivate|move|copy|rename|createWriteStream|getSignedUrl)\s*\(|getDownloadURL|getSignedUrl/;
  assert.doesNotMatch(source, forbidden);
});
