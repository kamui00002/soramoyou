//
// backfill-follow-counters.js の backfill が、本物の Firestore（エミュレーター）で数え直して代入できることを確かめるテスト ⭐️☁️
//
// 実行（functions/ の npm run test:emulator に登録。--project demo-soramoyou-security で起きる）。
// このファイルだけを流すときは、リポジトリ直下で:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "NODE_PATH=functions/node_modules node --test --test-concurrency=1 scripts/backfill-follow-counters.emulator.test.js"
//
// ■ 何を確かめるか
//   1. ずれた数が、users と publicProfiles の両方で、follows から数え直した数に直る
//   2. dryRun では、ずれを見つけても何も書かない
//   3. publicProfiles が無い人は、users だけ直して publicProfiles は作らない
//
// ■ 書き方の約束（follows-cleanup.emulator.test.js と同じ）
//   - 台本の main（firebase-admin の初期化と本番への接続）は呼ばない。このテストが demo- の Emulator へ向けて
//     初期化した db を backfill に渡す
//   - 期待する値はここに直接書く（入力から作った値どうしを比べると、何もしない実装でも緑になるため）
//   - 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろの結果が見えない）
//   - 各テストの前にエミュレーターの文書を全部消す（demo- のプロジェクトだけ）
//
// ⚠️ 本番へ書く事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、またはプロジェクト ID が
//    demo- で始まらないときは、firebase-admin を読む前に終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。follows-cleanup.emulator.test.js の柵と同じ型。
//

"use strict";

// MARK: - 柵（ここより前で firebase-admin を読み込まない）

const FIRESTORE_HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT_ID = process.env.GCLOUD_PROJECT;
const LOOPBACK = /^(127\.0\.0\.1|localhost|\[::1\]):\d+$/;
if (!FIRESTORE_HOST || !LOOPBACK.test(FIRESTORE_HOST)) {
  console.error(
    "Firestore のエミュレーターを指していないため中止した（本番へ書かないため）。" +
      ` firestore=${FIRESTORE_HOST ?? "(未設定)"}`
  );
  process.exit(1);
}
if (!PROJECT_ID || !PROJECT_ID.startsWith("demo-")) {
  console.error(`プロジェクト ID が demo- で始まらないため中止した: ${PROJECT_ID ?? "(未設定)"}`);
  process.exit(1);
}

const test = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

const { backfill } = require("./backfill-follow-counters");

const app = initializeApp({ projectId: PROJECT_ID }, "backfillFollowCountersEmulatorTest");
const db = getFirestore(app);

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${FIRESTORE_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  await res.arrayBuffer();
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
});

test.after(async () => {
  await deleteApp(app);
});

/**
 * フォローは F2→F1・F3→F1・F1→F2 の 3 件。正しい数（フォロワー・フォロー中）は F1: 2・1 ／ F2: 1・1 ／ F3: 0・1
 * F1 は users も publicProfiles も 0・0 にずらす。F2 は両方正しい。F3 は users を 0・0 にずらし、publicProfiles は置かない
 */
async function seedScenario() {
  for (const [f, e] of [["F2", "F1"], ["F3", "F1"], ["F1", "F2"]]) {
    await db.collection("follows").doc(`${f}_${e}`).set({ followerId: f, followeeId: e });
  }
  await db.collection("users").doc("F1").set({ followersCount: 0, followingCount: 0 });
  await db.collection("users").doc("F2").set({ followersCount: 1, followingCount: 1 });
  await db.collection("users").doc("F3").set({ followersCount: 0, followingCount: 0 });
  await db.collection("publicProfiles").doc("F1").set({ followersCount: 0, followingCount: 0 });
  await db.collection("publicProfiles").doc("F2").set({ followersCount: 1, followingCount: 1 });
}

/** users/{uid} と publicProfiles/{uid} の [フォロワー, フォロー中]（文書が無ければ null） */
async function countersOf(uid) {
  const pick = (snap) => (snap.exists ? [snap.get("followersCount"), snap.get("followingCount")] : null);
  const [user, profile] = await Promise.all([
    db.collection("users").doc(uid).get(),
    db.collection("publicProfiles").doc(uid).get(),
  ]);
  return { users: pick(user), publicProfiles: pick(profile) };
}

// MARK: - 確かめ

test("ずれた数が、users と publicProfiles の両方で数え直した数に直る", async () => {
  await seedScenario();
  await backfill(db, { dryRun: false });
  assert.deepEqual(await countersOf("F1"), { users: [2, 1], publicProfiles: [2, 1] });
});

test("dryRun では、ずれを見つけても何も書かない", async () => {
  await seedScenario();
  const summary = await backfill(db, { dryRun: true });
  // 「ずれを見つけた（F1・F3 の 2 人）」と「書いていない」を 1 組で見る（見つけていないだけの緑にしないため）
  assert.deepEqual([summary.changed, await countersOf("F1")], [2, { users: [0, 0], publicProfiles: [0, 0] }]);
});

test("publicProfiles が無い人は、users だけ直して publicProfiles は作らない", async () => {
  await seedScenario();
  await backfill(db, { dryRun: false });
  // users が直っている（＝F3 まで処理が届いた）ことと、publicProfiles が無いままのことを 1 組で見る
  assert.deepEqual(await countersOf("F3"), { users: [0, 1], publicProfiles: null });
});
