//
// soratomo-admin.js のエミュレーターのテスト（Firestore のエミュレーター・本物の共通の削除）☁️⭐️
//
// 実行（リポジトリ直下で。Firestore のエミュレーターは Java で動く。firebase-admin は functions/ の依存を借りる）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios \
//     "NODE_PATH=functions/node_modules node --test --test-concurrency=1 scripts/soratomo-admin.emulator.test.js"
//
// 単体テスト（soratomo-admin.test.js）が偽の db で見た順序と出力を、本物の Firestore のパス・クエリ・トランザクションで確かめる。
// - 削除は functions/soratomoDeletion.js の本物を使う（スクリプトが同じ実装を呼ぶことを確かめるため）
// - Auth は偽物（アカウントのある uid の集合）。Storage は偽のゲートウェイ（メモリ上・接頭辞は本物と同じ文字列の前方一致）。
//   本物のゲートウェイは functions/soratomoStorage.emulator.test.js で確かめた（要確認2）
// ⚠️ 各テストの前に、エミュレーターの文書を全部消す。
// ⚠️ 本番へ書く事故の柵: エミュレーターを指していなければ、firebase-admin を読む前に止める（functions の各テストと同じ）。
// ⚠️ package.json の test:emulator への登録は release-gate のタスク 7 で行う。
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

const deletion = require("../functions/soratomoDeletion");
const admin = require("./soratomo-admin");

const PROJECT_ID = "soramoyou-ios";
const app = initializeApp({ projectId: PROJECT_ID }, "soratomoAdminEmulatorTest");
const db = getFirestore(app);

const GROUPS = "soratomoGroups";
const USERS = "soratomoUsers";
const REPORTS = "soratomoReports";
const CODES = "soratomoInviteCodes";

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
});

test.after(async () => {
  await deleteApp(app);
});

/** 偽の Auth。existing の uid だけアカウントがある（getUser と getUsers の形は Admin SDK と同じ）。 */
function fakeAuth(existing) {
  const set = new Set(existing);
  return {
    async getUser(uid) {
      if (set.has(uid)) return { uid };
      throw Object.assign(new Error("not found"), { code: "auth/user-not-found" });
    },
    async getUsers(identifiers) {
      assert.ok(identifiers.length <= 100, "getUsers に100件を超えて渡した");
      return {
        users: identifiers.filter((i) => set.has(i.uid)).map((i) => ({ uid: i.uid })),
        notFound: identifiers.filter((i) => !set.has(i.uid)),
      };
    },
  };
}

/** 偽の Storage のゲートウェイ（soratomoStorage の2つの口と同じ形）。paths は今あるファイルの集合。 */
function fakeStorage(initial) {
  const paths = new Set(initial);
  return {
    paths,
    async *listFiles(prefix) {
      for (const path of [...paths].sort()) if (path.startsWith(prefix)) yield path;
    },
    async deleteFile(path) {
      return paths.delete(path) ? "deleted" : "absent";
    },
  };
}

function deps({ existing = [], images = [] } = {}) {
  return {
    db,
    auth: fakeAuth(existing),
    storage: fakeStorage(images),
    deletion,
    nowMs: Date.now,
    serverTimestamp: () => FieldValue.serverTimestamp(),
  };
}

const imagesOf = (groupId, uid, skyId) => [
  `soratomo/${groupId}/${uid}/${skyId}/display.jpg`,
  `soratomo/${groupId}/${uid}/${skyId}/thumb.jpg`,
];

/**
 * グループを入れる（グループ・メンバー・招待コード・所属の写し・利用者の文書・投稿）。
 * @param {{ groupId: string, members: Array<{ uid: string, role: string }>, skies?: Array<{ skyId: string, authorId: string }> }} args
 */
async function seedGroup({ groupId, members, skies = [] }) {
  const batch = db.batch();
  const groupRef = db.collection(GROUPS).doc(groupId);
  const owner = members.find((m) => m.role === "owner");
  const code = `CODE${groupId.toUpperCase()}`.slice(0, 8);
  batch.set(groupRef, {
    name: "ひみつのグループ名",
    ownerId: owner ? owner.uid : null,
    inviteCode: code,
    memberCount: members.length,
    createdAt: Timestamp.now(),
    lastActivityAt: Timestamp.now(),
  });
  batch.set(db.collection(CODES).doc(code), { groupId, createdAt: Timestamp.now() });
  for (const m of members) {
    batch.set(groupRef.collection("members").doc(m.uid), { uid: m.uid, role: m.role, joinedAt: Timestamp.now() });
    batch.set(db.collection(USERS).doc(m.uid), { groupCount: FieldValue.increment(1), guidelineVersion: 1 }, { merge: true });
    batch.set(db.collection(USERS).doc(m.uid).collection("groups").doc(groupId), { groupId, joinedAt: Timestamp.now() });
  }
  for (const s of skies) {
    batch.set(groupRef.collection("skies").doc(s.skyId), {
      authorId: s.authorId,
      caption: "ひみつのキャプション",
      width: 1080,
      height: 1440,
      createdAt: Timestamp.now(),
    });
  }
  await batch.commit();
}

async function seedReport({ groupId, skyId, authorId, reporterId, forwardStatus = "pending", createdAtMs = Date.now() }) {
  const reportId = `${groupId}_${skyId}_${reporterId}`;
  await db.collection(REPORTS).doc(reportId).set({
    groupId,
    skyId,
    authorId,
    reporterId,
    reason: "inappropriate",
    createdAt: Timestamp.fromMillis(createdAtMs),
    forwardStatus,
    forwardAttempts: forwardStatus === "pending" ? 1 : 0,
  });
  return reportId;
}

const exists = async (path) => (await db.doc(path).get()).exists;
const memberIds = async (groupId) => (await db.collection(GROUPS).doc(groupId).collection("members").get()).docs.map((d) => d.id).sort();

/** 出力に混ざってはいけない目印。 */
function assertNoSecrets(lines) {
  const text = lines.join("\n");
  for (const secret of ["ひみつのキャプション", "ひみつのグループ名", "ひみつの表示名", "CODEGA"]) {
    assert.equal(text.includes(secret), false, `出力に「${secret}」が混ざった`);
  }
}

// MARK: - find-orphans

test("find-orphans: 利用者の文書（写しだけが残った親を含む）から、アカウントの無い uid だけを並べる", async () => {
  await db.collection(USERS).doc("alive").set({ groupCount: 0 });
  await db.collection(USERS).doc("dead1").set({ groupCount: 1 });
  await db.collection(USERS).doc("dead2").collection("groups").doc("gZ").set({ groupId: "gZ" }); // 親の文書が無い
  const out = await admin.cmdFindOrphans(deps({ existing: ["alive"] }), { deep: false });
  assert.equal(out.exitCode, 0);
  assert.deepEqual(out.lines.slice(0, 4), [
    "調べた uid: 3 人（利用者の文書から）",
    "アカウントの無い uid: 2 人",
    "  dead1",
    "  dead2",
  ]);
  assert.equal(out.lines.join("\n").includes("alive"), false);
});

test("find-orphans --deep: メンバー・投稿者・画像のパスからも集め、データの残るグループIDを並べる", async () => {
  await seedGroup({
    groupId: "gA",
    members: [
      { uid: "alive", role: "owner" },
      { uid: "deadM", role: "member" },
    ],
    skies: [
      { skyId: "s1", authorId: "deadA" }, // 抜けた後に残った投稿
      { skyId: "s2", authorId: "ひみつの表示名" }, // 壊れた値（出さずに数える）
    ],
  });
  // 親の文書の無いグループのメンバー
  await db.collection(GROUPS).doc("gB").collection("members").doc("deadP").set({ uid: "deadP", role: "member" });
  const images = [...imagesOf("gC", "deadS", "s9"), "soratomo/readme.txt"];
  const out = await admin.cmdFindOrphans(deps({ existing: ["alive"], images }), { deep: true });
  assert.equal(out.exitCode, 0);
  const text = out.lines.join("\n");
  for (const expected of [
    "アカウントの無い uid: 4 人",
    "  deadA  データの残るグループ: gA",
    "  deadM  データの残るグループ: gA",
    "  deadP  データの残るグループ: gB",
    "  deadS  データの残るグループ: gC",
    "ID の形でない値: 1 件",
    "soratomo/ の下で形の違うパス: 1 件",
  ]) {
    assert.ok(text.includes(expected), `出力に「${expected}」が無い\n${text}`);
  }
  assert.equal(text.includes("  alive"), false);
  assertNoSecrets(out.lines);
});

// MARK: - delete-user

test("delete-user: アカウントの無い人のデータを、写しのグループと --group のグループから消す。アカウントのある人は拒否", async () => {
  await seedGroup({
    groupId: "gA",
    members: [
      { uid: "alive", role: "owner" },
      { uid: "deadU", role: "member" },
    ],
    skies: [
      { skyId: "s1", authorId: "deadU" },
      { skyId: "s2", authorId: "alive" },
    ],
  });
  // 写しの無いグループに残ったメンバーの文書（--group で渡す）
  await seedGroup({ groupId: "gX", members: [{ uid: "other", role: "owner" }] });
  await db.collection(GROUPS).doc("gX").collection("members").doc("deadU").set({ uid: "deadU", role: "member" });
  await db.collection(GROUPS).doc("gX").update({ memberCount: 2 });
  const d = deps({ existing: ["alive", "other"], images: [...imagesOf("gA", "deadU", "s1"), ...imagesOf("gA", "alive", "s2")] });

  const refused = await admin.cmdDeleteUser(d, { uid: "alive", groupIds: [] });
  assert.equal(refused.exitCode, 1);
  assert.deepEqual(await memberIds("gA"), ["alive", "deadU"]);

  const out = await admin.cmdDeleteUser(d, { uid: "deadU", groupIds: ["gX"] });
  assert.equal(out.exitCode, 0, out.lines.join("\n"));
  assert.deepEqual(await memberIds("gA"), ["alive"]);
  assert.deepEqual(await memberIds("gX"), ["other"]);
  assert.equal(await exists(`${GROUPS}/gA/skies/s1`), false);
  assert.equal(await exists(`${GROUPS}/gA/skies/s2`), true);
  assert.equal(await exists(`${USERS}/deadU`), false);
  assert.deepEqual([...d.storage.paths].sort(), imagesOf("gA", "alive", "s2"));
  assert.equal((await db.doc(`${GROUPS}/gX`).get()).get("memberCount"), 1);
  assert.ok(out.lines.includes("消した投稿: 1 件・画像: 2 枚"), out.lines.join("\n"));
});

// MARK: - show-report・review-report

test("show-report: 本物の記録から ID・状態・場所を出し、キャプションとグループ名は出さない", async () => {
  await seedGroup({
    groupId: "gA",
    members: [
      { uid: "alive", role: "owner" },
      { uid: "bad", role: "member" },
    ],
    skies: [{ skyId: "s1", authorId: "bad" }],
  });
  const reportId = await seedReport({ groupId: "gA", skyId: "s1", authorId: "bad", reporterId: "alive" });
  const out = await admin.cmdShowReport(deps(), { reportId });
  assert.equal(out.exitCode, 0);
  const text = out.lines.join("\n");
  for (const expected of ["理由: inappropriate", "投稿者: bad", "通報者: alive", "投稿の文書: あり", "soratomoGroups/gA/skies/s1"]) {
    assert.ok(text.includes(expected), `出力に「${expected}」が無い`);
  }
  assertNoSecrets(out.lines);
});

test("review-report violation: 投稿と画像を消し、投稿者を停止して全グループから外し、確認の記録を書く", async () => {
  await seedGroup({
    groupId: "gA",
    members: [
      { uid: "alive", role: "owner" },
      { uid: "bad", role: "member" },
    ],
    skies: [
      { skyId: "s1", authorId: "bad" },
      { skyId: "s2", authorId: "alive" },
    ],
  });
  await seedGroup({ groupId: "gB", members: [{ uid: "bad", role: "owner" }, { uid: "friend", role: "member" }] });
  const reportId = await seedReport({ groupId: "gA", skyId: "s1", authorId: "bad", reporterId: "alive" });
  const d = deps({ existing: ["alive", "bad", "friend"], images: [...imagesOf("gA", "bad", "s1"), ...imagesOf("gA", "alive", "s2")] });

  const out = await admin.cmdReviewReport(d, { reportId, result: "violation" });
  assert.equal(out.exitCode, 0, out.lines.join("\n"));
  assert.equal(await exists(`${GROUPS}/gA/skies/s1`), false);
  assert.equal(await exists(`${GROUPS}/gA/skies/s2`), true);
  assert.deepEqual([...d.storage.paths].sort(), imagesOf("gA", "alive", "s2"));
  const user = await db.doc(`${USERS}/bad`).get();
  assert.ok(user.get("suspendedAt") instanceof Timestamp, "利用停止の日時が無い");
  assert.equal(user.get("groupCount"), 0);
  assert.deepEqual(await memberIds("gA"), ["alive"]);
  assert.deepEqual(await memberIds("gB"), ["friend"]);
  const report = await db.doc(`${REPORTS}/${reportId}`).get();
  assert.equal(report.get("reviewResult"), "violation");
  assert.ok(report.get("reviewedAt") instanceof Timestamp, "確認日時が無い");
  assertNoSecrets(out.lines);
});

test("review-report no_violation: 投稿も投稿者もそのままで、確認の記録だけを書く", async () => {
  await seedGroup({
    groupId: "gA",
    members: [
      { uid: "alive", role: "owner" },
      { uid: "bad", role: "member" },
    ],
    skies: [{ skyId: "s1", authorId: "bad" }],
  });
  const reportId = await seedReport({ groupId: "gA", skyId: "s1", authorId: "bad", reporterId: "alive" });
  const d = deps({ existing: ["alive", "bad"], images: imagesOf("gA", "bad", "s1") });
  const out = await admin.cmdReviewReport(d, { reportId, result: "no_violation" });
  assert.equal(out.exitCode, 0);
  assert.equal(await exists(`${GROUPS}/gA/skies/s1`), true);
  assert.equal(d.storage.paths.size, 2);
  assert.equal((await db.doc(`${USERS}/bad`).get()).get("suspendedAt"), undefined);
  assert.deepEqual(await memberIds("gA"), ["alive", "bad"]);
  const report = await db.doc(`${REPORTS}/${reportId}`).get();
  assert.equal(report.get("reviewResult"), "no_violation");
  assert.ok(report.get("reviewedAt") instanceof Timestamp);
});

// MARK: - delete-sky・suspend・unsuspend・list-unforwarded

test("delete-sky: 投稿1件の文書と画像だけを消す", async () => {
  await seedGroup({
    groupId: "gA",
    members: [{ uid: "amy", role: "owner" }],
    skies: [
      { skyId: "s1", authorId: "amy" },
      { skyId: "s2", authorId: "amy" },
    ],
  });
  const d = deps({ images: [...imagesOf("gA", "amy", "s1"), ...imagesOf("gA", "amy", "s2")] });
  const out = await admin.cmdDeleteSky(d, { groupId: "gA", skyId: "s1" });
  assert.equal(out.exitCode, 0);
  assert.equal(await exists(`${GROUPS}/gA/skies/s1`), false);
  assert.equal(await exists(`${GROUPS}/gA/skies/s2`), true);
  assert.deepEqual([...d.storage.paths].sort(), imagesOf("gA", "amy", "s2"));
  assert.ok(out.lines.includes("消した（画像: 2 枚）"));
});

test("suspend → unsuspend: 停止の日時を書いて所属から外し、解除で日時だけを消す。2回目の解除は何もしない", async () => {
  await seedGroup({ groupId: "gA", members: [{ uid: "amy", role: "owner" }, { uid: "bob", role: "member" }] });
  const d = deps({ existing: ["amy", "bob"] });

  const suspended = await admin.cmdSuspend(d, { uid: "bob" });
  assert.equal(suspended.exitCode, 0);
  assert.ok(suspended.lines.includes("Auth のアカウント: あり"));
  assert.ok((await db.doc(`${USERS}/bob`).get()).get("suspendedAt") instanceof Timestamp);
  assert.deepEqual(await memberIds("gA"), ["amy"]);

  const lifted = await admin.cmdUnsuspend(d, { uid: "bob" });
  assert.ok(lifted.lines.includes("利用停止を解いた（消した投稿と所属は戻らない）"));
  const user = await db.doc(`${USERS}/bob`).get();
  assert.equal(user.exists, true);
  assert.equal(user.get("suspendedAt"), undefined);
  assert.deepEqual(await memberIds("gA"), ["amy"]);

  const again = await admin.cmdUnsuspend(d, { uid: "bob" });
  assert.ok(again.lines.includes("停止の記録が無い（何もしていない）"));
});

test("list-unforwarded: 未送信の通報だけを、受け付けた時刻の古い順に並べる", async () => {
  const base = Date.UTC(2026, 9, 8, 0, 0, 0);
  const newer = await seedReport({ groupId: "gA", skyId: "s2", authorId: "bad", reporterId: "amy", createdAtMs: base + 60_000 });
  const older = await seedReport({ groupId: "gA", skyId: "s1", authorId: "bad", reporterId: "amy", createdAtMs: base });
  const sent = await seedReport({ groupId: "gA", skyId: "s3", authorId: "bad", reporterId: "amy", forwardStatus: "sent" });
  const out = await admin.cmdListUnforwarded(deps());
  assert.equal(out.exitCode, 0);
  assert.equal(out.lines[0], "未送信の通報: 2 件");
  assert.ok(out.lines[1].startsWith(`  ${older}  失敗の回数: 1  受け付けた時刻: 2026-10-08T00:00:00.000Z`), out.lines[1]);
  assert.ok(out.lines[2].startsWith(`  ${newer}  `), out.lines[2]);
  assert.equal(out.lines.join("\n").includes(sent), false);
});
