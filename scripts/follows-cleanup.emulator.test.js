//
// follows-cleanup.js が、本物の Firestore（エミュレーター）で数えて消せることを確かめるテスト ⭐️☁️（D-1）
//
// 実行（functions/ の npm run test:emulator に登録。--project demo-soramoyou-security で起きる）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "NODE_PATH=functions/node_modules node --test --test-concurrency=1 scripts/follows-cleanup.emulator.test.js"
//
// ■ 何を確かめるか
//   - 本物の窓口（createFirestoreStore）で、ページの大きさ 2 でもページをまたいで全部読み、区分ごとに数える
//   - 要確認 1：select で項目を絞って読んでも createTime が取れる
//   - delete が 1a-before・1b-before の文書だけを消し、ほかは残す。2 回目は何も消さない
//   - 読んでから消すまでの間に文書が変わった（作り直した・書き換えた・消した）ら、lastUpdateTime で消さない
//   - 写しの JSON に消した文書が中身ごとそろう
//
// ■ 書き方の約束
//   - Functions のエミュレーターは使わない。follows と blockedUserIds は Admin SDK で直接置く
//     → ブロック済みの組が残ったままになる＝陽性対照（本番でブロック済みなのに残っている状態と同じ）
//   - deploy の境目は、エミュレーターが付けた createTime から決める（前の文書の最後の作成時刻 + 1 ミリ秒）
//   - 台本の main（firebase-admin の初期化と本番への接続）は呼ばない。このテストが demo- の Emulator へ向けて
//     初期化した db を、台本の窓口に差し込む
//   - 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろの結果が見えない）
//   - 各テストの前にエミュレーターの文書を全部消す（demo- のプロジェクトだけ）
//   - 写しの JSON は os.tmpdir() の下の使い捨てのフォルダに書く（リポジトリの中には書かない）
//
// ⚠️ 本番へ書く事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、またはプロジェクト ID が
//    demo- で始まらないときは、firebase-admin を読む前に終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。functions/followBlock.emulator.test.js の柵と同じ型。
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
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");

const cleanup = require("./follows-cleanup");

const app = initializeApp({ projectId: PROJECT_ID }, "followsCleanupEmulatorTest");
const db = getFirestore(app);
/** ページの大きさ 2：下ごしらえの 9 件は 5 ページに分かれる（ページをまたいで読むことを確かめる） */
const store = cleanup.createFirestoreStore(db, { pageSize: 2 });

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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** follows/{docId} を置く（fields はそのまま。アプリと同じく createdAt を足す） */
async function putFollow(docId, fields) {
  await db.collection("follows").doc(docId).set({ ...fields, createdAt: Timestamp.now() });
}

/** users/{uid} を置く。出力に混ざってはいけない項目（FCM のトークン・メール）も一緒に入れる */
async function putUser(uid, blockedUserIds) {
  await db.collection("users").doc(uid).set({ blockedUserIds, fcmToken: "ひみつのトークン", email: "himitsu@example.com" });
}

/** 今ある follows の文書 ID（昇順） */
async function followIds() {
  return (await db.collection("follows").get()).docs.map((d) => d.id).sort();
}

/**
 * 単体テストの scenario() と同じ組を置き、deploy の境目（ミリ秒）を返す。
 * U は X を、V は Y を、W は Q をブロックしている。M1 と M2 はお互いにブロックしている。
 * 境目より前：X_U（1a）・U_X（1b）・M1_M2（1a と 1b）・A_C（関係無し）・odd-dup（2a）・odd-uniq（2b）・broken（3）
 * 境目より後：Y_V（1a-after）・V_Y（1b-after）
 */
async function seedScenario() {
  for (const [uid, blocked] of [["U", ["X"]], ["M1", ["M2"]], ["M2", ["M1"]], ["V", ["Y"]], ["W", ["Q"]]]) {
    await putUser(uid, blocked);
  }
  for (const [f, e] of [["X", "U"], ["U", "X"], ["M1", "M2"], ["A", "C"]]) {
    await putFollow(`${f}_${e}`, { followerId: f, followeeId: e });
  }
  await putFollow("odd-dup", { followerId: "A", followeeId: "C" });
  await putFollow("odd-uniq", { followerId: "Q", followeeId: "W" });
  await putFollow("broken", { followeeId: "C" });

  const before = (await db.collection("follows").get()).docs;
  const boundaryMs = Math.max(...before.map((d) => d.createTime.toMillis())) + 1;
  await sleep(20); // 後の文書の createTime が境目より確実に後になるように
  await putFollow("Y_V", { followerId: "Y", followeeId: "V" });
  await putFollow("V_Y", { followerId: "V", followeeId: "Y" });

  const after = await Promise.all(["Y_V", "V_Y"].map((id) => db.collection("follows").doc(id).get()));
  if (after.some((d) => d.createTime.toMillis() < boundaryMs)) {
    throw new Error("下ごしらえの時刻がずれた（後の文書の createTime が境目より前）");
  }
  return boundaryMs;
}

/** seedScenario の後に残るべき文書（1a-before・1b-before を消した後） */
const REMAINING_AFTER_DELETE = ["A_C", "V_Y", "Y_V", "broken", "odd-dup", "odd-uniq"].sort();

/** count を流して行を返す */
async function count(boundaryMs, { list = false } = {}) {
  return cleanup.cmdCount({ store, deployedAtMs: boundaryMs }, { list });
}

/** delete を流す（既定は 1a-before=2・1b-before=2・確認は yes） */
async function runDelete(boundaryMs, { expect = { "1a-before": 2, "1b-before": 2 }, confirm = async () => true, backupDir } = {}) {
  const dir = backupDir ?? fs.mkdtempSync(path.join(os.tmpdir(), "d1-follows-emu-"));
  const out = await cleanup.cmdDelete(
    { store, deployedAtMs: boundaryMs, confirm, nowMs: Date.now },
    { ok: true, command: "delete", targets: ["1a-before", "1b-before"], expect, backupDir: dir }
  );
  return { out, dir };
}

const lineStartingWith = (lines, prefix) => lines.find((l) => l.startsWith(prefix));

// MARK: - 本物の窓口で読む

test("要確認 1: select で項目を絞って読んでも createTime が取れる", async () => {
  await seedScenario();
  const records = await store.scanFollows({ full: false });
  assert.deepEqual(
    records.map((r) => typeof (r.createTime && r.createTime.toMillis)),
    Array(9).fill("function")
  );
});

test("ページの大きさ 2 でも、ページをまたいで 9 件を全部読む", async () => {
  await seedScenario();
  assert.deepEqual((await store.scanFollows({ full: false })).map((r) => r.id).sort(), await followIds());
});

test("中身ごと（select なしで）読むと updateTime と中身が取れる", async () => {
  await seedScenario();
  const xu = (await store.scanFollows({ full: true })).find((r) => r.id === "X_U");
  assert.deepEqual(
    [typeof (xu && xu.updateTime && xu.updateTime.toMillis), xu && Object.keys(xu.data).sort()],
    ["function", ["createdAt", "followeeId", "followerId"]]
  );
});

// MARK: - count

test("count: 完全性（走査した件数と follows.count()）が一致する", async () => {
  const out = await count(await seedScenario());
  assert.equal(out.lines[1], "走査した follows: 9 件・follows.count(): 9 件 → 一致");
});

test("count: 1a を deploy の前・後に分けて数える", async () => {
  const out = await count(await seedScenario());
  assert.equal(
    lineStartingWith(out.lines, "1a "),
    "1a ブロックされた人 → ブロックした人: deploy 前 2 件・deploy 後 1 件"
  );
});

test("count: 1b を deploy の前・後に分けて数える", async () => {
  const out = await count(await seedScenario());
  assert.equal(lineStartingWith(out.lines, "1b "), "1b ブロックした人 → ブロックされた人: deploy 前 2 件・deploy 後 1 件");
});

test("count: 両方からブロックしている組の重なりを「うち重なり n 件」で出す", async () => {
  const out = await count(await seedScenario());
  assert.equal(
    lineStartingWith(out.lines, "  うち重なり"),
    "  うち重なり 1 件（1a と 1b の両方に数えた＝両方からブロックしている組の文書。deploy 前 1 件・deploy 後 0 件）"
  );
});

test("count: 2a（ID がずれた重複）を数える", async () => {
  const out = await count(await seedScenario());
  assert.equal(lineStartingWith(out.lines, "2a "), "2a ID がずれた重複（正しい ID の文書もある）: 1 件（うちブロック済みの組 0 件）");
});

test("count: 2b（ID がずれていて正しい ID の文書が無い）を数える", async () => {
  const out = await count(await seedScenario());
  assert.equal(lineStartingWith(out.lines, "2b "), "2b ID がずれていて、正しい ID の文書は無い: 1 件（うちブロック済みの組 1 件）");
});

test("count: 3（項目が欠けた文書）を数える", async () => {
  const out = await count(await seedScenario());
  assert.equal(lineStartingWith(out.lines, "3 "), "3 項目が欠けた・壊れた: followerId だけ 1 件・followeeId だけ 0 件・両方 0 件");
});

test("count --list: users のほかの項目（FCM のトークン・メール）は出さない", async () => {
  const out = await count(await seedScenario(), { list: true });
  const text = out.lines.join("\n");
  assert.deepEqual([out.lines.length > 10, text.includes("ひみつ"), text.includes("himitsu")], [true, false, false]);
});

// MARK: - delete

test("delete: 1a-before の X→U を消す", async () => {
  await runDelete(await seedScenario());
  assert.equal((await followIds()).includes("X_U"), false);
});

test("delete: 1b-before の U→X を消す", async () => {
  await runDelete(await seedScenario());
  assert.equal((await followIds()).includes("U_X"), false);
});

test("delete: 両方からブロックしている組の M1→M2 を消す", async () => {
  await runDelete(await seedScenario());
  assert.equal((await followIds()).includes("M1_M2"), false);
});

test("delete: 1a・1b の deploy 後・2a・2b・3・関係の無い組は残る", async () => {
  await runDelete(await seedScenario());
  assert.deepEqual(await followIds(), REMAINING_AFTER_DELETE);
});

test("delete: 消した件数を出す（重なりは 1 回だけ）", async () => {
  const { out } = await runDelete(await seedScenario());
  assert.ok(out.lines.includes("消した: 3 件・読んだ後に変わっていたので飛ばした: 0 件・失敗: 0 件"), out.lines.join("\n"));
});

test("delete: 2 回目（--expect は 0）は何も消さない", async () => {
  const boundaryMs = await seedScenario();
  await runDelete(boundaryMs);
  await runDelete(boundaryMs, { expect: { "1a-before": 0, "1b-before": 0 } });
  assert.deepEqual(await followIds(), REMAINING_AFTER_DELETE);
});

test("delete: --expect と違えば、何も消さない", async () => {
  await runDelete(await seedScenario(), { expect: { "1a-before": 1, "1b-before": 2 } });
  assert.equal((await followIds()).length, 9);
});

test("delete: 確認で yes でなければ、何も消さない", async () => {
  await runDelete(await seedScenario(), { confirm: async () => false });
  assert.equal((await followIds()).length, 9);
});

test("delete: 写しの JSON に、消した 3 件がそろう", async () => {
  const { dir } = await runDelete(await seedScenario());
  const files = fs.readdirSync(dir);
  assert.deepEqual(
    files.length === 1 ? JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8")).docs.map((d) => d.id) : files,
    ["M1_M2", "U_X", "X_U"]
  );
});

test("delete: 写しの JSON に、文書の中身（followerId・followeeId・createdAt）が入る", async () => {
  const { dir } = await runDelete(await seedScenario());
  const files = fs.readdirSync(dir);
  const entry = files.length === 1 ? JSON.parse(fs.readFileSync(path.join(dir, files[0]), "utf8")).docs.find((d) => d.id === "X_U") : null;
  // 中身が無い（select で読んだ）ときも、TypeError でなくアサーションで落とす
  assert.deepEqual(entry && entry.data && Object.keys(entry.data).sort(), ["createdAt", "followeeId", "followerId"]);
});

// MARK: - delete: 読んでから消すまでの間に変わった文書（lastUpdateTime）

test("delete: 読んだ後に消して作り直された X→U は消さない", async () => {
  const confirm = async () => {
    await db.collection("follows").doc("X_U").delete();
    await putFollow("X_U", { followerId: "X", followeeId: "U" });
    return true;
  };
  await runDelete(await seedScenario(), { confirm });
  assert.equal((await followIds()).includes("X_U"), true);
});

test("delete: 読んだ後に書き換えられた X→U は消さない", async () => {
  const confirm = async () => {
    await db.collection("follows").doc("X_U").update({ createdAt: Timestamp.now() });
    return true;
  };
  await runDelete(await seedScenario(), { confirm });
  assert.equal((await followIds()).includes("X_U"), true);
});

test("delete: 読んだ後に作り直された文書は「飛ばした」に数え、失敗には数えない", async () => {
  const confirm = async () => {
    await db.collection("follows").doc("X_U").delete();
    await putFollow("X_U", { followerId: "X", followeeId: "U" });
    return true;
  };
  const { out } = await runDelete(await seedScenario(), { confirm });
  assert.ok(out.lines.includes("消した: 2 件・読んだ後に変わっていたので飛ばした: 1 件・失敗: 0 件"), out.lines.join("\n"));
});

test("delete: 読んだ後に消されただけの文書も「飛ばした」に数え、失敗には数えない", async () => {
  const confirm = async () => {
    await db.collection("follows").doc("X_U").delete();
    return true;
  };
  const { out } = await runDelete(await seedScenario(), { confirm });
  assert.ok(out.lines.includes("消した: 2 件・読んだ後に変わっていたので飛ばした: 1 件・失敗: 0 件"), out.lines.join("\n"));
});
