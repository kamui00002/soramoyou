//
// soratomoDeletion.js のテスト（Firestore のエミュレーターに対してトランザクションを直接呼ぶ）⭐️
//
// 実行（functions で。Firestore のエミュレーターは Java で動く）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios "node --test --test-concurrency=1 soratomoDeletion.test.js"
//
// ⚠️ ほかのエミュレーターのテストと同じく、各テストの前にエミュレーターの文書を全部消す。
//    node --test に複数のファイルを渡すときは --test-concurrency=1 を付ける。
// ⚠️ 本番へ書く事故の柵は soratomoStore.test.js と同じ（エミュレーターを指していなければ firebase-admin を読む前に止める）。
// ⚠️ package.json の lint / test:emulator への登録は release-gate のタスク 7 で行う。
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
const { getFirestore, Timestamp } = require("firebase-admin/firestore");

const core = require("./soratomoCore");
const store = require("./soratomoStore");
const deletion = require("./soratomoDeletion");

const PROJECT_ID = "soramoyou-ios";
const app = initializeApp({ projectId: PROJECT_ID }, "soratomoDeletionTest");
const db = getFirestore(app);

const GROUPS = "soratomoGroups";
const CODES = "soratomoInviteCodes";
const USERS = "soratomoUsers";

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
});

test.after(async () => {
  await deleteApp(app);
});

const LAST_ACTIVITY = Timestamp.fromMillis(Date.UTC(2026, 8, 1));

/**
 * グループを入れる。メンバーごとに参加日時と役割を指定できる（引き継ぎの並び規則を確かめるため）。
 * @param {{ groupId: string, ownerId: string|null, inviteCode: string|null, memberCount?: number,
 *   members: Array<{ uid: string, role: string, joinedAtMs: number|null }>, withCode?: boolean }} args
 *   memberCount を省略するとメンバーの数。withCode が false なら招待コードの文書を入れない
 */
async function seedGroup({ groupId, ownerId, inviteCode, memberCount, members, withCode = true }) {
  const batch = db.batch();
  const groupRef = db.collection(GROUPS).doc(groupId);
  batch.set(groupRef, {
    name: "種のグループ",
    ownerId,
    inviteCode,
    memberCount: memberCount === undefined ? members.length : memberCount,
    createdAt: Timestamp.now(),
    lastActivityAt: LAST_ACTIVITY,
  });
  for (const m of members) {
    const doc = { uid: m.uid, role: m.role };
    if (m.joinedAtMs !== null) doc.joinedAt = Timestamp.fromMillis(m.joinedAtMs);
    batch.set(groupRef.collection("members").doc(m.uid), doc);
  }
  if (withCode && inviteCode) batch.set(db.collection(CODES).doc(inviteCode), { groupId, createdAt: Timestamp.now() });
  await batch.commit();
}

/** メンバーの文書だけを入れる（グループの文書が無い壊れた状態を作るため）。 */
async function seedMembersOnly(groupId, uids) {
  const batch = db.batch();
  for (const uid of uids) {
    batch.set(db.collection(GROUPS).doc(groupId).collection("members").doc(uid), { uid, role: "member", joinedAt: Timestamp.now() });
  }
  await batch.commit();
}

const T = (n) => Date.UTC(2026, 0, 1) + n * 1000;

async function groupData(groupId) {
  const snap = await db.collection(GROUPS).doc(groupId).get();
  return snap.exists ? snap.data() : null;
}
async function memberRoles(groupId) {
  const snap = await db.collection(GROUPS).doc(groupId).collection("members").get();
  return Object.fromEntries(snap.docs.map((d) => [d.id, d.get("role")]));
}

/**
 * 残ったグループの不変条件（design の Invariants）: 人数はメンバーの文書の数と等しく、
 * オーナーはちょうど1人で、グループの ownerId とメンバーの役割が一致する。
 */
async function assertGroupInvariants(groupId) {
  const group = await groupData(groupId);
  assert.ok(group, `グループ ${groupId} が無い`);
  const roles = await memberRoles(groupId);
  assert.equal(group.memberCount, Object.keys(roles).length, "人数がメンバーの文書の数と等しい");
  const owners = Object.entries(roles).filter(([, role]) => role === "owner").map(([uid]) => uid);
  assert.deepEqual(owners, [group.ownerId], "オーナーはちょうど1人で、ownerId と一致する");
}

// MARK: - 手順1（leaveOrDeleteGroupTx）

test("手順1: 他にメンバーがいるオーナーの退会は、参加の最も古い人（同じなら uid の昇順）へ引き継ぎ、人数を残りの数にする", async () => {
  await seedGroup({
    groupId: "g1",
    ownerId: "owner",
    inviteCode: "SKYAAAAA",
    members: [
      { uid: "owner", role: "owner", joinedAtMs: T(100) },
      { uid: "zed", role: "member", joinedAtMs: T(200) },
      { uid: "amy", role: "member", joinedAtMs: T(200) },
      { uid: "bob", role: "member", joinedAtMs: T(300) },
    ],
  });

  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g1" });
  assert.deepEqual(result, { kind: "leave", removed: true, ownerTransferred: true, groupExisted: true });

  const group = await groupData("g1");
  assert.equal(group.ownerId, "amy", "参加日時が同じ zed と amy では uid の昇順で amy");
  assert.equal(group.memberCount, 3);
  assert.deepEqual(await memberRoles("g1"), { amy: "owner", bob: "member", zed: "member" });
  await assertGroupInvariants("g1");
  // 引き継いでも招待コードは変えない（2.7）。最新の投稿日時も戻さない
  assert.equal(group.inviteCode, "SKYAAAAA");
  assert.equal((await db.collection(CODES).doc("SKYAAAAA").get()).get("groupId"), "g1");
  assert.equal(group.lastActivityAt.toMillis(), LAST_ACTIVITY.toMillis());
});

test("手順1: ただのメンバーの退会は、オーナーも役割も変えず、人数だけを残りの数にする", async () => {
  await seedGroup({
    groupId: "g1",
    ownerId: "owner",
    inviteCode: "SKYAAAAA",
    members: [
      { uid: "owner", role: "owner", joinedAtMs: T(100) },
      { uid: "amy", role: "member", joinedAtMs: T(200) },
      { uid: "bob", role: "member", joinedAtMs: T(300) },
    ],
  });
  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "bob", groupId: "g1" });
  assert.deepEqual(result, { kind: "leave", removed: true, ownerTransferred: false, groupExisted: true });
  assert.deepEqual(await memberRoles("g1"), { amy: "member", owner: "owner" });
  assert.equal((await groupData("g1")).ownerId, "owner");
  await assertGroupInvariants("g1");
});

test("手順1: 最後の1人の退会は、招待コード・グループの文書・自分のメンバーの文書を一緒に消す（子は手順2）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }] });
  const groupRef = db.collection(GROUPS).doc("g1");
  await groupRef.collection("skies").doc("sky1").set({ authorId: "owner", width: 1, height: 1, createdAt: Timestamp.now() });
  await groupRef.collection("notifyState").doc("x").set({ lastSkyId: "sky1", lastSentAt: Timestamp.now() });

  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g1" });
  assert.deepEqual(result, { kind: "delete_group", removed: true, ownerTransferred: false, groupExisted: true });
  assert.equal(await groupData("g1"), null);
  assert.equal((await db.collection(CODES).doc("SKYAAAAA").get()).exists, false);
  assert.deepEqual(await memberRoles("g1"), {});
  // 投稿と通知の間引きの状態は、手順2（タスク 3.2）が消す
  assert.equal((await groupRef.collection("skies").get()).size, 1);
  assert.equal((await groupRef.collection("notifyState").get()).size, 1);

  // 消した後の参加は、コードもグループの文書も無いので「見つかりません」
  await db.collection(USERS).doc("carol").set({ guidelineVersion: core.GUIDELINE_VERSION });
  const policy = { guidelineVersion: core.GUIDELINE_VERSION };
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy }), (err) => err.reason === "not_found");
});

test("手順1: すでにメンバーでない再実行でも、人数とオーナーを整えるだけで同じ結果になる", async () => {
  await seedGroup({
    groupId: "g1",
    ownerId: "owner",
    inviteCode: "SKYAAAAA",
    members: [
      { uid: "owner", role: "owner", joinedAtMs: T(100) },
      { uid: "amy", role: "member", joinedAtMs: T(200) },
    ],
  });
  await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g1" });
  const afterFirst = { group: await groupData("g1"), roles: await memberRoles("g1") };

  const again = await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g1" });
  assert.deepEqual(again, { kind: "leave", removed: false, ownerTransferred: false, groupExisted: true });
  assert.deepEqual(await memberRoles("g1"), afterFirst.roles);
  const group = await groupData("g1");
  assert.equal(group.ownerId, afterFirst.group.ownerId);
  assert.equal(group.memberCount, afterFirst.group.memberCount);
  await assertGroupInvariants("g1");
});

test("手順1: 壊れた状態（オーナーの記録が残りにいない・オーナーが2人・人数がずれている）から、オーナーを1人にそろえ人数を数え直す", async () => {
  await seedGroup({
    groupId: "g1",
    ownerId: "ghost",
    inviteCode: "SKYAAAAA",
    memberCount: 7,
    members: [
      { uid: "amy", role: "owner", joinedAtMs: T(300) },
      { uid: "bob", role: "owner", joinedAtMs: T(100) },
      { uid: "carl", role: "member", joinedAtMs: T(200) },
      { uid: "dan", role: "member", joinedAtMs: null },
    ],
  });
  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "carl", groupId: "g1" });
  assert.deepEqual(result, { kind: "leave", removed: true, ownerTransferred: true, groupExisted: true });
  const group = await groupData("g1");
  assert.equal(group.ownerId, "bob", "参加の最も古い bob（参加日時の無い dan は最後）");
  assert.equal(group.memberCount, 3, "7 から1減らすのではなく、残りの数で代入する");
  assert.deepEqual(await memberRoles("g1"), { amy: "member", bob: "owner", dan: "member" });
  await assertGroupInvariants("g1");
});

test("手順1: 退会者がメンバーでなくても、ずれた人数とオーナーを整える（ただのメンバーの再実行・人数のずれ）", async () => {
  await seedGroup({
    groupId: "g1",
    ownerId: "owner",
    inviteCode: "SKYAAAAA",
    memberCount: 9,
    members: [
      { uid: "owner", role: "owner", joinedAtMs: T(100) },
      { uid: "amy", role: "member", joinedAtMs: T(200) },
    ],
  });
  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "gone", groupId: "g1" });
  assert.deepEqual(result, { kind: "leave", removed: false, ownerTransferred: false, groupExisted: true });
  assert.equal((await groupData("g1")).memberCount, 2);
  await assertGroupInvariants("g1");
});

test("手順1: グループごと消すとき、招待コードの文書が別のグループを指していれば消さない・無くても失敗しない", async () => {
  await seedGroup({ groupId: "g2", ownerId: "x", inviteCode: "SHAREDAA", members: [{ uid: "x", role: "owner", joinedAtMs: T(1) }] });
  // 壊れた状態: g1 の inviteCode が g2 のコードを指している
  await seedGroup({
    groupId: "g1",
    ownerId: "owner",
    inviteCode: "SHAREDAA",
    members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }],
    withCode: false,
  });
  await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g1" });
  assert.equal(await groupData("g1"), null);
  assert.equal((await db.collection(CODES).doc("SHAREDAA").get()).get("groupId"), "g2", "別のグループのコードは消さない");

  // コードの文書が無い
  await seedGroup({
    groupId: "g3",
    ownerId: "owner",
    inviteCode: "SKYNONEA",
    members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }],
    withCode: false,
  });
  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g3" });
  assert.equal(result.kind, "delete_group");
  assert.equal(await groupData("g3"), null);
});

test("手順1: グループの文書が無く、ほかのメンバーもいなければ、自分のメンバーの文書だけを消す（groupExisted: false）", async () => {
  await seedMembersOnly("g1", ["owner"]);
  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g1" });
  assert.deepEqual(result, { kind: "delete_group", removed: true, ownerTransferred: false, groupExisted: false });
  assert.deepEqual(await memberRoles("g1"), {});
  assert.equal(await groupData("g1"), null, "グループの文書を作らない");

  const again = await deletion.leaveOrDeleteGroupTx(db, { uid: "owner", groupId: "g1" });
  assert.deepEqual(again, { kind: "delete_group", removed: false, ownerTransferred: false, groupExisted: false });
});

test("手順1: グループの文書が無く、ほかのメンバーが残っていれば、自分のメンバーの文書だけを消し、ほかには触れない", async () => {
  await seedMembersOnly("g1", ["amy", "bob"]);
  const result = await deletion.leaveOrDeleteGroupTx(db, { uid: "amy", groupId: "g1" });
  assert.deepEqual(result, { kind: "leave", removed: true, ownerTransferred: false, groupExisted: false });
  assert.deepEqual(await memberRoles("g1"), { bob: "member" }, "ほかのメンバーの役割を書き換えない");
  assert.equal(await groupData("g1"), null, "グループの文書を作らない");
});

test("手順1: uid が文書IDとして使えない・groupId が自動IDの形でないのは TypeError で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }] });
  for (const [i, args] of [
    { uid: "", groupId: "g1" },
    { uid: "a/b", groupId: "g1" },
    { uid: undefined, groupId: "g1" },
    { uid: "owner", groupId: "g_1" },
    { uid: "owner", groupId: "a/b" },
    { uid: "owner", groupId: undefined },
  ].entries()) {
    await assert.rejects(deletion.leaveOrDeleteGroupTx(db, args), TypeError, `引数 ${i}`);
  }
  await assertGroupInvariants("g1");
});
