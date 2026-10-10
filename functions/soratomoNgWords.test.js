//
// soratomoNgWords.js のテスト（Firestore のエミュレーターに語のリストの文書を置いて読む）⭐️
//
// 実行（functions で。Firestore のエミュレーターは Java で動く）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios "node --test soratomoNgWords.test.js"
//
// ⚠️ 語のリストの中身（実在の語）は書かない。ダミーの語（てすとごい・dummyng）だけを使う。
// ⚠️ 本番へ書く事故の柵: soratomoStore.test.js と同じ。FIRESTORE_EMULATOR_HOST がエミュレーターを
//    指していなければ、firebase-admin を読み込む前に止める（skip にはしない）。
// ⚠️ 読み直しの失敗は、本物の db を包んだ偽物（get が投げる）で作る。時刻は偽の時計で進める。
// ⚠️ package.json の test:emulator に登録してある（soratomoNgWords.js は lint にも）。
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
const { getFirestore } = require("firebase-admin/firestore");

const { createNgWordProvider, NgWordsUnavailableError, NG_WORDS_TTL_MS } = require("./soratomoNgWords");

const PROJECT_ID = "soramoyou-ios";
const app = initializeApp({ projectId: PROJECT_ID }, "soratomoNgWordsTest");
const db = getFirestore(app);

const NG_DOC = db.collection("soratomoConfig").doc("ngWords");
/** ダミーの語（ひらがな・英字）。 */
const NG_KANA = "てすとごい";
const NG_LATIN = "dummyng";

// MARK: - 下ごしらえ

/** エミュレーターの文書をすべて消す（テストどうしを独立させる）。 */
async function clearEmulator() {
  const url = `http://${EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
}

test.beforeEach(async () => {
  await clearEmulator();
});

test.after(async () => {
  await deleteApp(app);
});

/** 偽の時計（ミリ秒）。advance で進める。 */
function fakeClock(start = 1_700_000_000_000) {
  let now = start;
  return { nowMs: () => now, advance: (ms) => (now += ms) };
}

/** 呼ばれた順にログを溜める偽の logger。 */
function fakeLogger() {
  const calls = [];
  const record = (level) => (message, fields) => calls.push({ level, message, fields });
  return { calls, info: record("info"), warn: record("warn"), error: record("error") };
}

/**
 * 本物の db を包み、語のリストの文書の get の回数を数え、fail が真の間は get を失敗させる偽物。
 * provider が読むのは soratomoConfig/ngWords の get だけ。
 */
function wrappedDb() {
  const state = { reads: 0, fail: false };
  const fake = {
    collection: (c) => ({
      doc: (d) => ({
        get: async () => {
          state.reads += 1;
          if (state.fail) throw Object.assign(new Error("unavailable"), { code: 14 });
          return db.collection(c).doc(d).get();
        },
      }),
    }),
  };
  return { db: fake, state };
}

/** ログのすべて（メッセージと項目）に、語が出ていないことを確かめる。 */
function assertNoWordsInLogs(logger) {
  const json = JSON.stringify(logger.calls);
  for (const word of [NG_KANA, NG_LATIN, "テストゴイ", "ＤＵＭＭＹＮＧ"]) {
    assert.ok(!json.includes(word), `ログに語が出た: ${word}`);
  }
}

// MARK: - 読み込み

test("定数: キャッシュは5分", () => {
  assert.equal(NG_WORDS_TTL_MS, 5 * 60 * 1000);
});

test("文書の語で照合し、正規化（カタカナ・全角）した入力にも該当する", async () => {
  await NG_DOC.set({ words: [NG_KANA, "ＤＵＭＭＹＮＧ"] });
  const logger = fakeLogger();
  const provider = createNgWordProvider({ db, logger });
  const matches = await provider.matcher();
  assert.equal(matches("これはテストゴイです"), true);
  assert.equal(matches("dummyng"), true);
  assert.equal(matches("今日の空はきれい"), false);
  // 読めたことを件数と経過時間だけでログに出す
  const loaded = logger.calls.find((c) => c.message === "soratomoNgWords: loaded");
  assert.ok(loaded, "読み込みのログが無い");
  assert.deepEqual(Object.keys(loaded.fields).sort(), ["count", "elapsedMs"]);
  assert.equal(loaded.fields.count, 2);
  assertNoWordsInLogs(logger);
});

test("空の配列は「語が無い」として、どの文も通す", async () => {
  await NG_DOC.set({ words: [] });
  const provider = createNgWordProvider({ db, logger: fakeLogger() });
  const matches = await provider.matcher();
  assert.equal(matches("なんでも"), false);
});

test("文書が無ければ、検査を飛ばさずに失敗する（一度も読めていない）", async () => {
  const logger = fakeLogger();
  const provider = createNgWordProvider({ db, logger });
  await assert.rejects(provider.matcher(), NgWordsUnavailableError);
  assert.ok(
    logger.calls.some((c) => c.level === "error" && c.message === "soratomoNgWords: unavailable"),
    "読めないことを error で出していない"
  );
});

test("words が配列でない壊れた文書も、一度も読めていないとして失敗する", async () => {
  await NG_DOC.set({ words: NG_KANA });
  const provider = createNgWordProvider({ db, logger: fakeLogger() });
  await assert.rejects(provider.matcher(), NgWordsUnavailableError);
});

test("words に文字列でない要素が混ざっていたら、一部だけ使わずに壊れた文書として失敗する（レビュー #11）", async () => {
  for (const words of [[NG_KANA, { w: "x" }], [1, 2], [null]]) {
    await NG_DOC.set({ words });
    const provider = createNgWordProvider({ db, logger: fakeLogger() });
    await assert.rejects(provider.matcher(), NgWordsUnavailableError, JSON.stringify(words));
  }
});

test("words が空でないのに使える語が1つも無ければ（空・空白だけ）、壊れた文書として失敗する（レビュー #11）", async () => {
  await NG_DOC.set({ words: ["", "  "] });
  const provider = createNgWordProvider({ db, logger: fakeLogger() });
  await assert.rejects(provider.matcher(), NgWordsUnavailableError);
});

test("読み直しで壊れた文書になっていたら、古いリストで検査を続け、壊れていることを warn で出す（レビュー #11）", async () => {
  await NG_DOC.set({ words: [NG_KANA] });
  const clock = fakeClock();
  const logger = fakeLogger();
  const provider = createNgWordProvider({ db, nowMs: clock.nowMs, logger });
  await provider.matcher();

  await NG_DOC.set({ words: [{ w: "x" }] });
  clock.advance(NG_WORDS_TTL_MS + 1000);
  const matches = await provider.matcher();
  assert.equal(matches(NG_KANA), true, "古いリストで検査していない（空のリストで通してしまう）");
  const stale = logger.calls.find((c) => c.message === "soratomoNgWords: stale");
  assert.ok(stale && stale.fields.kind === "malformed", "壊れていることを warn で出していない");
});

test("一度も読めていないときに読み取りが失敗したら、失敗として返す", async () => {
  await NG_DOC.set({ words: [NG_KANA] });
  const wrapped = wrappedDb();
  wrapped.state.fail = true;
  const provider = createNgWordProvider({ db: wrapped.db, logger: fakeLogger() });
  await assert.rejects(provider.matcher(), NgWordsUnavailableError);
  // 失敗の後でも、読めるようになれば使える（失敗を覚えて止まり続けない）
  wrapped.state.fail = false;
  const matches = await provider.matcher();
  assert.equal(matches(NG_KANA), true);
});

// MARK: - キャッシュ

test("5分の間は読み直さず、5分を過ぎたら読み直す", async () => {
  await NG_DOC.set({ words: [NG_KANA] });
  const clock = fakeClock();
  const wrapped = wrappedDb();
  const provider = createNgWordProvider({ db: wrapped.db, nowMs: clock.nowMs, logger: fakeLogger() });

  assert.equal((await provider.matcher())(NG_KANA), true);
  assert.equal(wrapped.state.reads, 1);

  // 文書を変えても、5分の手前までは古いリストのまま（読み直さない）
  await NG_DOC.set({ words: [NG_LATIN] });
  clock.advance(NG_WORDS_TTL_MS - 1);
  assert.equal((await provider.matcher())(NG_KANA), true);
  assert.equal(wrapped.state.reads, 1, "5分の手前で読み直した");

  // ちょうど5分で読み直し、新しいリストになる
  clock.advance(1);
  const matches = await provider.matcher();
  assert.equal(wrapped.state.reads, 2, "5分を過ぎても読み直していない");
  assert.equal(matches(NG_KANA), false);
  assert.equal(matches(NG_LATIN), true);
});

test("読み直しに失敗したら、古いリストで検査を続け、警告を出す", async () => {
  await NG_DOC.set({ words: [NG_KANA] });
  const clock = fakeClock();
  const wrapped = wrappedDb();
  const logger = fakeLogger();
  const provider = createNgWordProvider({ db: wrapped.db, nowMs: clock.nowMs, logger });
  await provider.matcher();

  wrapped.state.fail = true;
  clock.advance(NG_WORDS_TTL_MS + 1000);
  const matches = await provider.matcher();
  assert.equal(matches(NG_KANA), true, "古いリストで検査していない");
  const stale = logger.calls.find((c) => c.message === "soratomoNgWords: stale");
  assert.ok(stale && stale.level === "warn", "古いリストを使うことを warn で出していない");
  assert.equal(stale.fields.ageMs, NG_WORDS_TTL_MS + 1000);
  assertNoWordsInLogs(logger);

  // 失敗の間は次の呼び出しでも読み直しを試みる（古い時刻を新しくしない）
  await provider.matcher();
  assert.equal(wrapped.state.reads, 3);
});

test("読み直しで文書が消えていたら、古いリストで検査を続ける", async () => {
  await NG_DOC.set({ words: [NG_KANA] });
  const clock = fakeClock();
  const logger = fakeLogger();
  const provider = createNgWordProvider({ db, nowMs: clock.nowMs, logger });
  await provider.matcher();

  await NG_DOC.delete();
  clock.advance(NG_WORDS_TTL_MS);
  const matches = await provider.matcher();
  assert.equal(matches(NG_KANA), true);
  assert.ok(logger.calls.some((c) => c.level === "warn" && c.message === "soratomoNgWords: stale"));
});

test("同時の呼び出しでも、読み込みは1回にまとめる", async () => {
  await NG_DOC.set({ words: [NG_KANA] });
  const wrapped = wrappedDb();
  const provider = createNgWordProvider({ db: wrapped.db, logger: fakeLogger() });
  const results = await Promise.all([provider.matcher(), provider.matcher(), provider.matcher()]);
  assert.equal(wrapped.state.reads, 1);
  for (const matches of results) assert.equal(matches(NG_KANA), true);
});

test("照合の結果は真偽値だけで、語を返さない", async () => {
  await NG_DOC.set({ words: [NG_KANA] });
  const provider = createNgWordProvider({ db, logger: fakeLogger() });
  const matches = await provider.matcher();
  assert.equal(matches(`前置き${NG_KANA}後ろ`), true);
  assert.equal(typeof matches(NG_KANA), "boolean");
});
