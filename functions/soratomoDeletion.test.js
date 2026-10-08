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
// ⚠️ 画像は偽のゲートウェイ（fakeStorage・メモリ上・接頭辞は本物と同じ文字列の前方一致）で消す。途中の失敗と時計は
//    偽物で作る。本物のゲートウェイは soratomoStorage.emulator.test.js で Storage のエミュレーターに対して確かめた（要確認2）。
//
// ■ 要確認1（design.md「recursiveDelete が、文書の無い親の下の子を消せるか」）
//   この Mac（firebase-tools 15.0.0・cloud-firestore-emulator v1.20.2・firebase-admin 14.5.0・
//   @google-cloud/firestore 9.3.1・2026-10-08）のエミュレーターで実測した事実:
//   - 親（グループの文書）を消した後の db.recursiveDelete(親) は、子（skies・members・notifyState）を全部消した
//     （テスト「要確認1: …」。実装の前から緑＝確かめているのは SDK とエミュレーター）
//   - 根拠: SDK の recursiveDelete は、親の文書の有無を見ずに「親のパスの下の全子孫」を種類を問わないクエリ
//     （kindless の allDescendants）で探して消す（@google-cloud/firestore の build/src/recursive-delete.js の
//     getAllDescendants）。親の文書の存在は条件に入っていない
//   - 本番の Firestore でも同じかは、まだ確かめていない。すべての delete_group の経路（手順1が親を先に消す）が
//     これに依存する。確かめどころは実機の退会（tasks 16.1）の「最後のメンバーの退会」の後に、本番のデータで
//     グループの下が空かを読むこと（GO の後。2026-10-08 時点の 16.1 の手順には、この読み取りはまだ書いていない）
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

// MARK: - 手順2〜4（deleteUserDataInGroup・タスク 3.2）

const REPORTS = "soratomoReports";
/** 締め切りの既定（テストの時計はこれより前から始める）。 */
const DEADLINE = 1_000_000;

/**
 * 偽の Storage ゲートウェイ（メモリ上のパスの集合）。接頭辞は本物と同じく文字列の前方一致（1.2 で実測）。
 * @param {string[]} paths 置いておくパス
 * @param {{ ghosts?: string[], failAt?: number|null, onDelete?: (count: number) => void }} [options]
 *   ghosts: 一覧には出るが、もう無いパス（消すと "absent"）。failAt: その回数目の deleteFile で投げる。
 *   onDelete: deleteFile を呼ぶたびに、それまでの回数で呼ぶ（時計を進めるため）
 */
function fakeStorage(paths, { ghosts = [], failAt = null, onDelete = null } = {}) {
  const files = new Set(paths);
  const state = { files, calls: 0, inFlight: 0, maxInFlight: 0, prefixes: [] };
  state.gateway = {
    async *listFiles(prefix) {
      if (typeof prefix !== "string" || !prefix.endsWith("/")) throw new TypeError("偽物: 接頭辞は / で終える");
      state.prefixes.push(prefix);
      const names = [...files, ...ghosts].filter((p) => p.startsWith(prefix)).sort();
      for (const name of names) yield name;
    },
    async deleteFile(path) {
      state.calls += 1;
      const call = state.calls;
      state.inFlight += 1;
      state.maxInFlight = Math.max(state.maxInFlight, state.inFlight);
      try {
        // 同時に何件走るかを数えられるよう、1 回だけ順番を譲る
        await new Promise((resolve) => setImmediate(resolve));
        if (failAt !== null && call === failAt) throw new Error("偽物: わざと失敗");
        if (onDelete) onDelete(call);
        return files.delete(path) ? "deleted" : "absent";
      } finally {
        state.inFlight -= 1;
      }
    },
  };
  return state;
}

/** 1 つの投稿の画像 2 枚のパス。 */
const imagesOf = (groupId, uid, skyId) => [
  `soratomo/${groupId}/${uid}/${skyId}/display.jpg`,
  `soratomo/${groupId}/${uid}/${skyId}/thumb.jpg`,
];

/** 動かない時計（締め切りより前）。 */
const steadyClock = () => () => 0;
/** 最初の n 回だけ締め切りより前を返し、その後は締め切りを返す時計（確かめる順はグループの前→投稿の1ページ目の後）。 */
function clockPastAfter(n) {
  let calls = 0;
  return () => (++calls <= n ? 0 : DEADLINE);
}

async function seedSkies(groupId, authorId, skyIds) {
  for (let i = 0; i < skyIds.length; i += 400) {
    const batch = db.batch();
    for (const skyId of skyIds.slice(i, i + 400)) {
      batch.set(db.collection(GROUPS).doc(groupId).collection("skies").doc(skyId), {
        authorId,
        width: 1,
        height: 1,
        createdAt: Timestamp.now(),
      });
    }
    await batch.commit();
  }
}
async function seedNotify(groupId, uids) {
  const batch = db.batch();
  for (const uid of uids) {
    batch.set(db.collection(GROUPS).doc(groupId).collection("notifyState").doc(uid), { lastSkyId: "s", lastSentAt: Timestamp.now() });
  }
  await batch.commit();
}
/** 利用者の文書（所属数）と所属の写しを入れる。groupCount を省略すると写しの数。 */
async function seedUser(uid, groupIds, { groupCount } = {}) {
  const batch = db.batch();
  const userRef = db.collection(USERS).doc(uid);
  batch.set(userRef, { groupCount: groupCount === undefined ? groupIds.length : groupCount, guidelineVersion: core.GUIDELINE_VERSION });
  for (const g of groupIds) batch.set(userRef.collection("groups").doc(g), { groupId: g, joinedAt: Timestamp.now() });
  await batch.commit();
}
async function seedReport(reportId, { groupId, skyId, authorId, reporterId }) {
  await db.collection(REPORTS).doc(reportId).set({ groupId, skyId, authorId, reporterId, reason: "spam", createdAt: Timestamp.now() });
}
async function skyAuthors(groupId) {
  const snap = await db.collection(GROUPS).doc(groupId).collection("skies").get();
  return snap.docs.map((d) => `${d.get("authorId")}:${d.id}`).sort();
}
async function notifyIds(groupId) {
  const snap = await db.collection(GROUPS).doc(groupId).collection("notifyState").get();
  return snap.docs.map((d) => d.id).sort();
}
async function copyIds(uid) {
  const snap = await db.collection(USERS).doc(uid).collection("groups").get();
  return snap.docs.map((d) => d.id).sort();
}
async function userData(uid) {
  const snap = await db.collection(USERS).doc(uid).get();
  return snap.exists ? snap.data() : null;
}
const sortedPaths = (state, prefix) => [...state.files].filter((p) => p.startsWith(prefix)).sort();

test("手順2〜4: 残るメンバーがいれば、退会者の投稿・画像（取り残しも）・通知の間引き・写しだけを消し、ほかの人のもの・通報の記録は残す", async () => {
  await seedGroup({
    groupId: "g1",
    ownerId: "owner",
    inviteCode: "SKYAAAAA",
    members: [
      { uid: "owner", role: "owner", joinedAtMs: T(1) },
      { uid: "amy", role: "member", joinedAtMs: T(2) },
      { uid: "amy2", role: "member", joinedAtMs: T(3) },
    ],
  });
  await seedSkies("g1", "amy", ["a1", "a2", "a3"]);
  await seedSkies("g1", "owner", ["o1"]);
  await seedSkies("g1", "amy2", ["b1"]);
  await seedNotify("g1", ["amy", "owner"]);
  await seedUser("amy", ["g1", "g2"]);
  await seedReport("r1", { groupId: "g1", skyId: "a1", authorId: "amy", reporterId: "owner" });
  await seedReport("r2", { groupId: "g1", skyId: "o1", authorId: "owner", reporterId: "amy" });
  const amyImages = [...imagesOf("g1", "amy", "a1"), ...imagesOf("g1", "amy", "a2"), ...imagesOf("g1", "amy", "a3"), ...imagesOf("g1", "amy", "orphan")];
  const keptImages = [...imagesOf("g1", "owner", "o1"), ...imagesOf("g1", "amy2", "b1"), ...imagesOf("g2", "amy", "x1")].sort();
  const storage = fakeStorage([...amyImages, ...keptImages]);

  const result = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(result, {
    done: true,
    kind: "leave",
    removed: true,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 3,
    imagesDeleted: 8,
  });
  assert.deepEqual(await skyAuthors("g1"), ["amy2:b1", "owner:o1"], "ほかのメンバーの投稿は残す（1.5）");
  assert.deepEqual([...storage.files].sort(), keptImages, "ほかの人の画像（隣の amy2 を含む）と別のグループの画像は残す");
  assert.deepEqual(storage.prefixes, ["soratomo/g1/amy/"], "画像は退会者のパスの接頭辞だけを一覧する");
  assert.deepEqual(await notifyIds("g1"), ["owner"], "退会者あての通知の間引きの状態だけを消す（2.4）");
  assert.deepEqual(await copyIds("amy"), ["g2"], "このグループの写しだけを消す");
  assert.equal((await userData("amy")).groupCount, 1, "所属数は残りの写しの件数");
  assert.equal((await db.collection(REPORTS).get()).size, 2, "通報の記録には触れない（6.11）");
  const group = await groupData("g1");
  assert.equal(group.lastActivityAt.toMillis(), LAST_ACTIVITY.toMillis(), "最新の投稿日時は戻さない");
  await assertGroupInvariants("g1");

  // 2回目は状態が変わらず、件数が0になる（3.4）
  const again = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(again, {
    done: true,
    kind: "leave",
    removed: false,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 0,
    imagesDeleted: 0,
  });
  assert.deepEqual(await skyAuthors("g1"), ["amy2:b1", "owner:o1"]);
  assert.deepEqual([...storage.files].sort(), keptImages);
  assert.equal((await userData("amy")).groupCount, 1);
  await assertGroupInvariants("g1");
});

test("手順2〜4: 最後の1人なら、グループの下のすべて（前のメンバーの投稿・通知の間引き）とグループのパスの画像を消す", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }] });
  await seedSkies("g1", "owner", ["o1", "o2"]);
  await seedSkies("g1", "old", ["x1"]);
  await seedNotify("g1", ["owner", "old"]);
  await seedUser("owner", ["g1"]);
  await seedReport("r1", { groupId: "g1", skyId: "o1", authorId: "owner", reporterId: "old" });
  const groupImages = [...imagesOf("g1", "owner", "o1"), ...imagesOf("g1", "owner", "o2"), ...imagesOf("g1", "old", "x1"), ...imagesOf("g1", "old", "orphan")];
  const keptImages = [...imagesOf("g10", "owner", "y1")].sort();
  const storage = fakeStorage([...groupImages, ...keptImages]);

  const result = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "owner", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(result, {
    done: true,
    kind: "delete_group",
    removed: true,
    ownerTransferred: false,
    groupDeleted: true,
    skiesDeleted: 3,
    imagesDeleted: 8,
  });
  const groupRef = db.collection(GROUPS).doc("g1");
  assert.equal(await groupData("g1"), null);
  assert.deepEqual((await groupRef.listCollections()).map((c) => c.id), [], "グループの下に何も残らない（2.9）");
  assert.equal((await db.collection(CODES).doc("SKYAAAAA").get()).exists, false);
  assert.deepEqual([...storage.files].sort(), keptImages, "隣のグループ g10 の画像は残す");
  assert.deepEqual(storage.prefixes, ["soratomo/g1/"]);
  assert.deepEqual(await copyIds("owner"), []);
  assert.equal((await userData("owner")).groupCount, 0);
  assert.equal((await db.collection(REPORTS).get()).size, 1, "通報の記録には触れない（6.11）");

  // 2回目は、グループが無いので数えず、件数も0
  const again = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "owner", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(again, {
    done: true,
    kind: "delete_group",
    removed: false,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 0,
    imagesDeleted: 0,
  });
});

test("手順2〜4: グループの文書が無く、ほかのメンバーの文書も無ければ、子と画像を消す（groupDeleted は数えない）", async () => {
  await seedMembersOnly("g1", ["owner"]);
  await seedSkies("g1", "owner", ["o1"]);
  await seedSkies("g1", "old", ["x1"]);
  await seedNotify("g1", ["old"]);
  await seedUser("owner", ["g1"]);
  const storage = fakeStorage([...imagesOf("g1", "owner", "o1"), ...imagesOf("g1", "old", "x1")]);

  const result = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "owner", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(result, {
    done: true,
    kind: "delete_group",
    removed: true,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 2,
    imagesDeleted: 4,
  });
  assert.deepEqual((await db.collection(GROUPS).doc("g1").listCollections()).map((c) => c.id), []);
  assert.equal(storage.files.size, 0);
  assert.deepEqual(await copyIds("owner"), []);
});

test("手順2〜4: グループの文書が無くても、ほかのメンバーの文書が残っていれば、自分の分だけを消し、ほかの人の子に触れない", async () => {
  await seedMembersOnly("g1", ["amy", "bob"]);
  await seedSkies("g1", "amy", ["a1"]);
  await seedSkies("g1", "bob", ["b1"]);
  await seedNotify("g1", ["amy", "bob"]);
  await seedUser("amy", ["g1"]);
  const bobImages = imagesOf("g1", "bob", "b1").sort();
  const storage = fakeStorage([...imagesOf("g1", "amy", "a1"), ...bobImages]);

  const result = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(result, {
    done: true,
    kind: "leave",
    removed: true,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 1,
    imagesDeleted: 2,
  });
  assert.deepEqual(await skyAuthors("g1"), ["bob:b1"]);
  assert.deepEqual(await notifyIds("g1"), ["bob"]);
  assert.deepEqual(await memberRoles("g1"), { bob: "member" });
  assert.deepEqual([...storage.files].sort(), bobImages);
  assert.deepEqual(await copyIds("amy"), []);
});

test("要確認1: 親の文書を先に消した後でも、recursiveDelete(親) は子（skies・members・notifyState）を消す", async () => {
  // グループごとの削除は、手順1で親（グループの文書）を消してから手順2で子を消す。どの delete_group の経路もこれに依存する
  await seedMembersOnly("g1", ["owner"]);
  await seedSkies("g1", "owner", ["o1"]);
  await seedNotify("g1", ["owner"]);
  await seedMembersOnly("g2", ["keep"]);
  const groupRef = db.collection(GROUPS).doc("g1");
  assert.equal((await groupRef.get()).exists, false, "親の文書が無い状態から始める");
  assert.deepEqual((await groupRef.listCollections()).map((c) => c.id).sort(), ["members", "notifyState", "skies"]);

  await db.recursiveDelete(groupRef);
  assert.deepEqual((await groupRef.listCollections()).map((c) => c.id), []);
  assert.deepEqual(await memberRoles("g2"), { keep: "member" }, "ほかのグループには触れない");
});

test("時間の予算: グループの前に締め切りを過ぎていれば、何もせず未完了で返す", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedSkies("g1", "amy", ["a1"]);
  await seedUser("amy", ["g1"]);
  const storage = fakeStorage(imagesOf("g1", "amy", "a1"));

  const result = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: () => DEADLINE },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(result, {
    done: false,
    kind: null,
    removed: false,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 0,
    imagesDeleted: 0,
  });
  assert.deepEqual(await memberRoles("g1"), { amy: "member", owner: "owner" }, "メンバーの文書も外さない");
  assert.deepEqual(await skyAuthors("g1"), ["amy:a1"]);
  assert.equal(storage.calls, 0);
  assert.deepEqual(await copyIds("amy"), ["g1"]);
});

test("時間の予算: 投稿300件を消した後に締め切りを過ぎていれば、写しを残して未完了で返し、続きで消し切る", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  const skyIds = Array.from({ length: 301 }, (_, i) => `a${String(i).padStart(3, "0")}`);
  await seedSkies("g1", "amy", skyIds);
  await seedNotify("g1", ["amy"]);
  await seedUser("amy", ["g1"]);
  const storage = fakeStorage(imagesOf("g1", "amy", "a000"));

  const first = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: clockPastAfter(1) },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.equal(first.done, false);
  assert.equal(first.removed, true, "手順1は済んでいる");
  assert.equal(first.skiesDeleted, deletion.SKY_PAGE_SIZE);
  assert.equal((await skyAuthors("g1")).length, 1);
  assert.equal(storage.calls, 0, "画像はまだ消していない");
  assert.deepEqual(await notifyIds("g1"), ["amy"]);
  assert.deepEqual(await copyIds("amy"), ["g1"], "写しが残るので、次の呼び出しがこのグループから続ける");

  const second = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.deepEqual(second, {
    done: true,
    kind: "leave",
    removed: false,
    ownerTransferred: false,
    groupDeleted: false,
    skiesDeleted: 1,
    imagesDeleted: 2,
  });
  assert.deepEqual(await skyAuthors("g1"), []);
  assert.deepEqual(await notifyIds("g1"), []);
  assert.deepEqual(await copyIds("amy"), []);
});

test("時間の予算: 画像100件を消した後に締め切りを過ぎていれば、写しと通知の間引きを残して未完了で返し、続きで消し切る", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedNotify("g1", ["amy"]);
  await seedUser("amy", ["g1"]);
  const paths = Array.from({ length: 101 }, (_, i) => `soratomo/g1/amy/orphan${String(i).padStart(3, "0")}/display.jpg`);
  let now = 0;
  const storage = fakeStorage(paths, { onDelete: (count) => { if (count >= deletion.IMAGE_CHECK_EVERY) now = DEADLINE; } });

  const first = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: () => now },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.equal(first.done, false);
  assert.equal(first.imagesDeleted, deletion.IMAGE_CHECK_EVERY);
  assert.equal(storage.files.size, 1);
  assert.deepEqual(await notifyIds("g1"), ["amy"], "手順3はまだ");
  assert.deepEqual(await copyIds("amy"), ["g1"], "写しは最後");

  now = 0;
  const second = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: () => now },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.equal(second.done, true);
  assert.equal(second.imagesDeleted, 1);
  assert.equal(storage.files.size, 0);
  assert.deepEqual(await notifyIds("g1"), []);
  assert.deepEqual(await copyIds("amy"), []);
});

test("途中の失敗: 画像の削除が失敗したら投げ、写しと通知の間引きは残る。再実行で消し切る（写しは最後に消す）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedSkies("g1", "amy", ["a1", "a2"]);
  await seedNotify("g1", ["amy"]);
  await seedUser("amy", ["g1"]);
  const images = [...imagesOf("g1", "amy", "a1"), ...imagesOf("g1", "amy", "a2")];
  const failing = fakeStorage(images, { failAt: 3 });

  await assert.rejects(
    deletion.deleteUserDataInGroup({ db, storage: failing.gateway, nowMs: steadyClock() }, { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }),
    /わざと失敗/
  );
  assert.ok(failing.files.size >= 1, "失敗した画像は残っている");
  assert.deepEqual(await copyIds("amy"), ["g1"], "写しが残っている（利用者→グループの唯一の経路・3.3）");
  assert.deepEqual(await notifyIds("g1"), ["amy"], "手順3へ進まない");
  assert.equal((await userData("amy")).groupCount, 1);

  const healthy = fakeStorage([...failing.files]);
  const result = await deletion.deleteUserDataInGroup(
    { db, storage: healthy.gateway, nowMs: steadyClock() },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.equal(result.done, true);
  assert.equal(healthy.files.size, 0);
  assert.deepEqual(await copyIds("amy"), []);
  assert.deepEqual(await notifyIds("g1"), []);
});

test("画像: もう無かったもの（absent）は消した数に数えず、同時に消すのは10件まで", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedUser("amy", ["g1"]);
  const paths = Array.from({ length: 25 }, (_, i) => `soratomo/g1/amy/s${i}/display.jpg`);
  const ghosts = Array.from({ length: 5 }, (_, i) => `soratomo/g1/amy/gone${i}/thumb.jpg`);
  const storage = fakeStorage(paths, { ghosts });

  const result = await deletion.deleteUserDataInGroup(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }
  );
  assert.equal(result.imagesDeleted, 25);
  assert.equal(storage.calls, 30, "一覧に出たものは全部消しにいく");
  assert.ok(storage.maxInFlight <= deletion.IMAGE_DELETE_CONCURRENCY, `同時に ${storage.maxInFlight} 件`);
  assert.ok(storage.maxInFlight > 1, "1件ずつではなく並べて消す");
});

test("手順4: 所属数は写しの件数で数え直して代入し、写しが無くても・利用者の文書が無くても壊れない", async () => {
  // ずれた所属数（7）から始めて、残りの写しの件数（2）を代入する
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedUser("amy", ["g1", "g2", "g3"], { groupCount: 7 });
  const storage = fakeStorage([]);
  const deps = { db, storage: storage.gateway, nowMs: steadyClock() };
  await deletion.deleteUserDataInGroup(deps, { uid: "amy", groupId: "g1", deadlineMs: DEADLINE });
  assert.deepEqual(await copyIds("amy"), ["g2", "g3"]);
  assert.equal((await userData("amy")).groupCount, 2, "7 から1減らすのではなく、残りの写しの件数");

  // 写しの無いグループ（管理スクリプトが足すグループ）でも、所属数を数え直すだけで失敗しない
  await seedUser("amy", ["g2", "g3"], { groupCount: 5 });
  await deletion.deleteUserDataInGroup(deps, { uid: "amy", groupId: "g9", deadlineMs: DEADLINE });
  assert.deepEqual(await copyIds("amy"), ["g2", "g3"]);
  assert.equal((await userData("amy")).groupCount, 2);

  // 利用者の文書が無い（写しだけが残る）なら、写しを消し、利用者の文書は作らない
  await db.collection(USERS).doc("ghost").collection("groups").doc("g1").set({ groupId: "g1", joinedAt: Timestamp.now() });
  await deletion.deleteUserDataInGroup(deps, { uid: "ghost", groupId: "g1", deadlineMs: DEADLINE });
  assert.deepEqual(await copyIds("ghost"), []);
  assert.equal(await userData("ghost"), null, "利用者の文書を作らない");
});

test("deleteUserDataInGroup: 引数の誤りは TypeError で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedUser("amy", ["g1"]);
  const storage = fakeStorage([]);
  const deps = { db, storage: storage.gateway, nowMs: steadyClock() };
  const cases = [
    [deps, { uid: "", groupId: "g1", deadlineMs: DEADLINE }],
    [deps, { uid: "a/b", groupId: "g1", deadlineMs: DEADLINE }],
    [deps, { uid: "amy", groupId: "g_1", deadlineMs: DEADLINE }],
    [deps, { uid: "amy", groupId: "g1", deadlineMs: undefined }],
    [deps, { uid: "amy", groupId: "g1", deadlineMs: Number.NaN }],
    [{ db, storage: storage.gateway }, { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }],
    [{ db, nowMs: steadyClock() }, { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }],
    [{ storage: storage.gateway, nowMs: steadyClock() }, { uid: "amy", groupId: "g1", deadlineMs: DEADLINE }],
  ];
  for (const [i, [d, req]] of cases.entries()) {
    await assert.rejects(deletion.deleteUserDataInGroup(d, req), TypeError, `引数 ${i}`);
  }
  assert.deepEqual(await memberRoles("g1"), { amy: "member", owner: "owner" });
  assert.deepEqual(await copyIds("amy"), ["g1"]);
});
