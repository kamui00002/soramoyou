//
// soratomo-ngwords.js の書き込みの経路のエミュレーターのテスト（Firestore のエミュレーター）☁️⭐️
//
// 実行（functions で。npm run test:emulator に登録してある）:
//   npm run test:emulator
//   単独なら（リポジトリ直下で。Firestore のエミュレーターは Java で動く。firebase-admin は functions/ の依存を借りる）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios \
//     "NODE_PATH=functions/node_modules node --test --test-concurrency=1 scripts/soratomo-ngwords.emulator.test.js"
//
// 単体テスト（soratomo-ngwords.test.js）は書く前に止める条件を見る。ここでは、書く経路（writeWordList）が本物の
// Firestore の soratomoConfig/ngWords に書いて読み返すことと、Functions の提供口（functions/soratomoNgWords.js）が
// その文書を読んで照合できることを確かめる。main は本番専用（エミュレーターを指す環境変数があれば止める）なので呼ばない。
// 語はダミー（「てすとごい」など）だけを使い、実在の語は書かない。
// ⚠️ 各テストの前に、エミュレーターの文書を全部消す。
// ⚠️ 本番へ書く事故の柵: エミュレーターを指していなければ、firebase-admin を読む前に止める（functions の各テストと同じ）。
//

"use strict";

// MARK: - 柵（ここより前で firebase-admin を読み込まない）

const EMULATOR_HOST = process.env.FIRESTORE_EMULATOR_HOST;
if (!EMULATOR_HOST || !/^(127\.0\.0\.1|localhost|\[::1\]):\d+$/.test(EMULATOR_HOST)) {
  throw new Error(
    "FIRESTORE_EMULATOR_HOST がエミュレーターを指していないため中止した（本番の Firestore へ書かないため）。" +
      " firebase emulators:exec --only firestore --project soramoyou-ios の中で実行すること。"
  );
}

const test = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");

const { NG_WORDS_COLLECTION, NG_WORDS_DOC, createNgWordProvider } = require("../functions/soratomoNgWords");
const ng = require("./soratomo-ngwords");

const PROJECT_ID = "soramoyou-ios";
const app = initializeApp({ projectId: PROJECT_ID }, "soratomoNgWordsScriptEmulatorTest");
const db = getFirestore(app);
const serverTimestamp = () => FieldValue.serverTimestamp();

/** ログを捨てる（提供口のログに語は出ないが、テストの出力を汚さない）。 */
const silentLogger = { info() {}, warn() {}, error() {} };

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
});

test.after(async () => {
  await deleteApp(app);
});

// MARK: - writeWordList

test("writeWordList: soratomoConfig/ngWords に語と updatedAt を書き、読み返して一致を返す", async () => {
  const words = ["てすとごい", "ＤＡＭＩＩ", "だみー#の語"];
  assert.equal(await ng.writeWordList(db, words, serverTimestamp), true);
  const snap = await db.collection(NG_WORDS_COLLECTION).doc(NG_WORDS_DOC).get();
  assert.deepEqual(snap.get("words"), words);
  assert.ok(snap.get("updatedAt") instanceof Timestamp, "updatedAt がサーバーの時刻でない");
  assert.deepEqual(Object.keys(snap.data()).sort(), ["updatedAt", "words"]);
});

test("writeWordList: 2回目は前のリストを置き換える（足し合わせない）", async () => {
  assert.equal(await ng.writeWordList(db, ["てすとごい", "だみー"], serverTimestamp), true);
  assert.equal(await ng.writeWordList(db, ["さいごの語"], serverTimestamp), true);
  const snap = await db.collection(NG_WORDS_COLLECTION).doc(NG_WORDS_DOC).get();
  assert.deepEqual(snap.get("words"), ["さいごの語"]);
});

test("ファイルから書いた語を、Functions の提供口が読んで照合する（表記の違いは照合の側で同一視）", async () => {
  const { words } = ng.parseWordList("# ダミーの語だけ\nてすとごい\n\n　だみー　\n");
  assert.equal(ng.validateWordList(words).ok, true);
  assert.equal(await ng.writeWordList(db, words, serverTimestamp), true);
  const matcher = await createNgWordProvider({ db, logger: silentLogger }).matcher();
  assert.equal(matcher("きょうは テストゴイ な空"), true);
  assert.equal(matcher("だみーの空"), true);
  assert.equal(matcher("ただの青空"), false);
});
