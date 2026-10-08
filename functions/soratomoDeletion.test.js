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
// ■ 要確認3（design.md「トランザクションの中のメンバーのクエリと、参加の同時実行」・同じ版で実測）
//   テスト「要確認3: …」: 19人のグループから退会者を消す削除と、ほかの人2人の参加・退会者自身の別のグループへの参加・
//   退会者の投稿の作成を、手順1の直前を合図に回ごとに 0〜38ms ずらして発火し、20回並べた。どの回も、人数＝メンバーの件数で
//   20人以下・所属数＝写しの件数で10個以下・退会者の投稿と文書が残らない。分布は1回の例で参加の成功 39/40・退会者自身の参加の
//   成功 10/20・投稿の作成 3/20（片側に寄っていない＝競合の場面を作れている）。
//   - エミュレーターは、競合したトランザクションを ABORTED（SDK が再試行する）でなく INVALID_ARGUMENT
//     「Transaction is invalid or closed」で返すことがあり、SDK は再試行しない。20回のうち 1〜5 回、削除の手順4か
//     最後の確認の写しのクエリ（退会者自身の参加と利用者の文書を取り合う所）で起きた。テストは、この2種だけを「競合による失敗」
//     として数えて続きを流す（本番なら Callable の失敗＝アプリの再試行に当たる）。本番が同じ形で返すかは確かめていない
//   - 陽性対照: 人数を1減らす実装は赤（統合テストを含む3件）。手順1の読み（グループの文書とメンバーのクエリ）をトランザクションの
//     外に出した実装は、この並べ方では検出できなかった（読みと書きの隙間は数ミリ秒で、20回のどれも隙間に参加が落ちなかった。
//     runTransaction を包んで直前に参加を通す形も試したが、外で読む実装の読みも渡す関数の中にあるので区別できず、残していない）。
//     手順4の読みを外に出した実装も緑だが、これは設計どおりの自己修復（最後の確認が増えた写しを見つけ、手順4が数え直す）による
//   - コードの審査（読んで書く文書）: 手順1は groupRef とメンバーのクエリを読み、groupRef を更新か削除・自分のメンバーを削除。
//     joinGroupTx は codeRef・userRef・groupRef・memberRef を読み、memberRef・groupRef・userRef・写しを書く。
//     createGroupTx は userRef（と招待コード）を読み、userRef・写しを書く。createSkyTx は userRef・memberRef・skyRef を読み、
//     skyRef を作る。手順4と最後の確認は userRef と写しのクエリを読み、写し・userRef を書く。
//     → 人数は「手順1と参加が groupRef を両方読んで書く」、所属数は「手順4・最後の確認と参加・作成が userRef を両方読んで書く」、
//     投稿は「手順1が退会者のメンバーの文書をクエリで読んで消し、作成がそれを読む」ことで直列になる（Admin SDK はトランザクションで
//     読んだ文書にロックを置く前提。本番のロックがエミュレーターと同じかは文書では確かめられない）
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
 *   onDelete: deleteFile を呼ぶたびに、それまでの回数で呼んで待つ（時計を進める・削除の途中に参加を差し込むため）
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
        if (onDelete) await onDelete(call);
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

// MARK: - 利用者単位の削除・利用停止・解除・投稿1件の削除（タスク 3.3）

const JOIN_POLICY = Object.freeze({ guidelineVersion: core.GUIDELINE_VERSION });
const CREATE_POLICY = Object.freeze({ guidelineVersion: core.GUIDELINE_VERSION, containsNgWord: () => false });
const ZERO_TOTALS = Object.freeze({ skiesDeleted: 0, imagesDeleted: 0, groupsLeft: 0, ownersTransferred: 0, groupsDeleted: 0 });

test("利用者単位: 写しの全グループと、追加のグループIDの和について消し、最後に利用者の文書を消す。2回目は件数0", async () => {
  // g1: amy がオーナーで bob が残る（引き継ぎ）。g2: amy が最後の1人（グループごと）。g3: 写しの無いグループ（管理が足す）
  await seedGroup({
    groupId: "g1",
    ownerId: "amy",
    inviteCode: "SKYAAAAA",
    members: [
      { uid: "amy", role: "owner", joinedAtMs: T(1) },
      { uid: "bob", role: "member", joinedAtMs: T(2) },
    ],
  });
  await seedGroup({ groupId: "g2", ownerId: "amy", inviteCode: "SKYBBBBB", members: [{ uid: "amy", role: "owner", joinedAtMs: T(1) }] });
  await seedGroup({ groupId: "g3", ownerId: "bob", inviteCode: "SKYCCCCC", members: [{ uid: "bob", role: "owner", joinedAtMs: T(1) }] });
  await seedSkies("g1", "amy", ["a1"]);
  await seedSkies("g1", "bob", ["b1"]);
  await seedSkies("g2", "amy", ["a2", "a3"]);
  await seedSkies("g3", "amy", ["a4"]);
  await seedSkies("g3", "bob", ["b3"]);
  await seedUser("amy", ["g1", "g2"]);
  const kept = [...imagesOf("g1", "bob", "b1"), ...imagesOf("g3", "bob", "b3")].sort();
  const storage = fakeStorage([
    ...imagesOf("g1", "amy", "a1"),
    ...imagesOf("g2", "amy", "a2"),
    ...imagesOf("g2", "amy", "a3"),
    ...imagesOf("g3", "amy", "a4"),
    ...kept,
  ]);
  const deps = { db, storage: storage.gateway, nowMs: steadyClock() };
  const request = { uid: "amy", trigger: "self", deadlineMs: DEADLINE, extraGroupIds: ["g3", "g1"] };

  const result = await deletion.deleteSoratomoUserData(deps, request);
  assert.deepEqual(result, {
    done: true,
    skiesDeleted: 4,
    imagesDeleted: 8,
    groupsLeft: 2,
    ownersTransferred: 1,
    groupsDeleted: 1,
  });
  assert.equal(await userData("amy"), null, "利用者の文書を消す（2.3）");
  assert.deepEqual(await copyIds("amy"), []);
  assert.deepEqual(await skyAuthors("g1"), ["bob:b1"]);
  assert.deepEqual(await skyAuthors("g3"), ["bob:b3"], "写しの無い追加のグループでも、退会者の投稿を消す");
  assert.equal(await groupData("g2"), null);
  assert.equal((await groupData("g1")).ownerId, "bob");
  await assertGroupInvariants("g1");
  await assertGroupInvariants("g3");
  assert.deepEqual([...storage.files].sort(), kept);

  const again = await deletion.deleteSoratomoUserData(deps, request);
  assert.deepEqual(again, { done: true, ...ZERO_TOTALS }, "2回目は件数が0（3.4）");
  assert.equal(await userData("amy"), null);
  assert.deepEqual(await skyAuthors("g1"), ["bob:b1"]);
  await assertGroupInvariants("g1");
});

test("利用者単位: そらともを使っていない人（文書も写しも無い）は、空振りで完了し、文書を作らない", async () => {
  const storage = fakeStorage([]);
  const result = await deletion.deleteSoratomoUserData(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "anon", trigger: "self", deadlineMs: DEADLINE }
  );
  assert.deepEqual(result, { done: true, ...ZERO_TOTALS });
  assert.equal(await userData("anon"), null);
  assert.equal(storage.calls, 0);
});

test("利用者単位: 削除の途中で参加が入って写しが増えても、最後の確認で見つけて続け、消し切ってから利用者の文書を消す", async () => {
  await seedGroup({
    groupId: "g1",
    ownerId: "owner",
    inviteCode: "SKYAAAAA",
    members: [
      { uid: "owner", role: "owner", joinedAtMs: T(1) },
      { uid: "amy", role: "member", joinedAtMs: T(2) },
    ],
  });
  await seedGroup({ groupId: "g2", ownerId: "bob", inviteCode: "SKYBBBBB", members: [{ uid: "bob", role: "owner", joinedAtMs: T(1) }] });
  await seedUser("amy", ["g1"]);
  let joined = null;
  const storage = fakeStorage(imagesOf("g1", "amy", "a1"), {
    onDelete: async (count) => {
      if (count === 1) joined = await store.joinGroupTx(db, { uid: "amy", code: "SKYBBBBB", policy: JOIN_POLICY });
    },
  });

  const result = await deletion.deleteSoratomoUserData(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", trigger: "self", deadlineMs: DEADLINE }
  );
  assert.deepEqual(joined, { groupId: "g2", alreadyMember: false }, "削除の途中で参加が通った（この場面を作れている）");
  assert.equal(result.done, true);
  assert.equal(result.groupsLeft, 2, "途中で入った g2 からも外す");
  assert.deepEqual(await memberRoles("g2"), { bob: "owner" });
  await assertGroupInvariants("g2");
  assert.deepEqual(await copyIds("amy"), []);
  assert.equal(await userData("amy"), null);
});

test("利用者単位: 追加のグループIDで渡した、メンバーのいない孤児のグループの文書を消したら groupsDeleted に数える（groupsLeft は数えない）", async () => {
  await seedGroup({ groupId: "g9", ownerId: "ghost", inviteCode: "SKYAAAAA", members: [] });
  await seedSkies("g9", "ghost", ["x1"]);
  const storage = fakeStorage(imagesOf("g9", "ghost", "x1"));
  const result = await deletion.deleteSoratomoUserData(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", trigger: "admin", deadlineMs: DEADLINE, extraGroupIds: ["g9"] }
  );
  assert.deepEqual(result, {
    done: true,
    skiesDeleted: 1,
    imagesDeleted: 2,
    groupsLeft: 0,
    ownersTransferred: 0,
    groupsDeleted: 1,
  });
  assert.equal(await groupData("g9"), null);
  assert.deepEqual((await db.collection(GROUPS).doc("g9").listCollections()).map((c) => c.id), []);
});

test("利用者単位: 締め切りを過ぎたら、写しと利用者の文書を残して未完了で返し、続きで完了する", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedGroup({ groupId: "g2", ownerId: "owner", inviteCode: "SKYBBBBB", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedSkies("g1", "amy", ["a1"]);
  await seedSkies("g2", "amy", ["a2"]);
  await seedUser("amy", ["g1", "g2"]);
  const storage = fakeStorage([]);
  // 1つ目のグループの前は間に合い、1つ目の投稿のページの後で締め切りを過ぎる
  const first = await deletion.deleteSoratomoUserData(
    { db, storage: storage.gateway, nowMs: clockPastAfter(1) },
    { uid: "amy", trigger: "self", deadlineMs: DEADLINE }
  );
  assert.equal(first.done, false);
  assert.equal(first.skiesDeleted, 1);
  assert.ok(await userData("amy"), "利用者の文書は残る");
  assert.deepEqual(await copyIds("amy"), ["g1", "g2"], "写しが残るので続きから");

  const second = await deletion.deleteSoratomoUserData(
    { db, storage: storage.gateway, nowMs: steadyClock() },
    { uid: "amy", trigger: "self", deadlineMs: DEADLINE }
  );
  assert.equal(second.done, true);
  assert.equal(second.skiesDeleted, 1);
  assert.equal(second.groupsLeft, 1, "1回目に外した g1 は数え直さない");
  assert.equal(await userData("amy"), null);
});

test("利用停止: 停止の日時を先に書いてから消す。削除の途中の参加と作成は停止で拒否され、文書は停止の日時と所属数0で残る", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedGroup({ groupId: "g2", ownerId: "bob", inviteCode: "SKYBBBBB", members: [{ uid: "bob", role: "owner", joinedAtMs: T(1) }] });
  await seedSkies("g1", "amy", ["a1"]);
  await seedUser("amy", ["g1"]);
  const attempts = [];
  const storage = fakeStorage(imagesOf("g1", "amy", "a1"), {
    onDelete: async (count) => {
      if (count !== 1) return;
      for (const call of [
        () => store.joinGroupTx(db, { uid: "amy", code: "SKYBBBBB", policy: JOIN_POLICY }),
        () => store.createGroupTx(db, { uid: "amy", name: "空の会", requestId: "r1", policy: CREATE_POLICY }),
      ]) {
        attempts.push(await call().then(() => "ok", (err) => err.reason || err.message));
      }
    },
  });
  const deps = { db, storage: storage.gateway, nowMs: steadyClock() };

  const result = await deletion.suspendSoratomoUser(deps, { uid: "amy", deadlineMs: DEADLINE });
  assert.deepEqual(attempts, ["suspended", "suspended"], "削除の途中でも、参加と作成は停止で拒否される（8.6）");
  assert.deepEqual(result, { done: true, skiesDeleted: 1, imagesDeleted: 2, groupsLeft: 1, ownersTransferred: 0, groupsDeleted: 0 });
  const user = await userData("amy");
  assert.ok(user && user.suspendedAt, "停止の日時が残る");
  assert.equal(user.groupCount, 0);
  assert.deepEqual(await copyIds("amy"), []);
  assert.deepEqual(await skyAuthors("g1"), []);
  assert.deepEqual(await memberRoles("g1"), { owner: "owner" });
  await assert.rejects(
    store.createSkyTx(db, { uid: "amy", input: { groupId: "g1", skyId: "s1", width: 1, height: 1 }, policy: { containsNgWord: () => false } }),
    (err) => err.reason === "suspended"
  );

  // 2回目: 停止の日時を上書きせず、件数は0
  const again = await deletion.suspendSoratomoUser(deps, { uid: "amy", deadlineMs: DEADLINE });
  assert.deepEqual(again, { done: true, ...ZERO_TOTALS });
  assert.equal((await userData("amy")).suspendedAt.toMillis(), user.suspendedAt.toMillis());
});

test("利用停止: そらともを使っていない人でも、停止の日時と所属数0の文書ができ、以後の作成は停止で拒否される", async () => {
  const storage = fakeStorage([]);
  const result = await deletion.suspendSoratomoUser({ db, storage: storage.gateway, nowMs: steadyClock() }, { uid: "newbie", deadlineMs: DEADLINE });
  assert.deepEqual(result, { done: true, ...ZERO_TOTALS });
  const user = await userData("newbie");
  assert.ok(user && user.suspendedAt);
  assert.equal(user.groupCount, 0);
  await assert.rejects(
    store.createGroupTx(db, { uid: "newbie", name: "空の会", requestId: "r1", policy: CREATE_POLICY }),
    (err) => err.reason === "suspended"
  );
});

test("解除: 停止の日時だけを消し、消した投稿と所属は戻さない。解除の後は参加できる。文書が無ければ何もしない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedSkies("g1", "amy", ["a1"]);
  await seedUser("amy", ["g1"]);
  const storage = fakeStorage([]);
  await deletion.suspendSoratomoUser({ db, storage: storage.gateway, nowMs: steadyClock() }, { uid: "amy", deadlineMs: DEADLINE });

  await deletion.unsuspendSoratomoUser(db, { uid: "amy" });
  const user = await userData("amy");
  assert.equal(user.suspendedAt, undefined, "停止の日時を消す（8.8）");
  assert.equal(user.groupCount, 0);
  assert.equal(user.guidelineVersion, core.GUIDELINE_VERSION, "ほかの項目（同意）は残す");
  assert.deepEqual(await skyAuthors("g1"), [], "消した投稿は戻さない");
  assert.deepEqual(await copyIds("amy"), [], "所属は戻さない");
  assert.deepEqual(await store.joinGroupTx(db, { uid: "amy", code: "SKYAAAAA", policy: JOIN_POLICY }), { groupId: "g1", alreadyMember: false });

  await deletion.unsuspendSoratomoUser(db, { uid: "nobody" });
  assert.equal(await userData("nobody"), null, "文書を作らない");
});

test("投稿1件の削除: 文書と画像2枚を消し、同じ投稿者のほかの投稿と画像・通報の記録は残す。文書が無ければ何もしない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedSkies("g1", "amy", ["a1", "a10"]);
  await seedReport("r1", { groupId: "g1", skyId: "a1", authorId: "amy", reporterId: "owner" });
  const kept = imagesOf("g1", "amy", "a10").sort();
  const storage = fakeStorage([...imagesOf("g1", "amy", "a1"), ...kept]);
  const deps = { db, storage: storage.gateway, nowMs: steadyClock() };

  assert.deepEqual(await deletion.deleteSoratomoSky(deps, { groupId: "g1", skyId: "a1" }), { skyDeleted: true, imagesDeleted: 2 });
  assert.deepEqual(await skyAuthors("g1"), ["amy:a10"]);
  assert.deepEqual([...storage.files].sort(), kept, "隣の a10 の画像は残す");
  assert.equal((await db.collection(REPORTS).get()).size, 1, "通報の記録には触れない");
  assert.equal((await groupData("g1")).lastActivityAt.toMillis(), LAST_ACTIVITY.toMillis());

  assert.deepEqual(await deletion.deleteSoratomoSky(deps, { groupId: "g1", skyId: "a1" }), { skyDeleted: false, imagesDeleted: 0 });
});

test("投稿1件の削除: 画像の削除が失敗したら文書を残して投げ、再実行で消し切る（画像を先・文書を後に消す）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }] });
  await seedSkies("g1", "owner", ["o1"]);
  const failing = fakeStorage(imagesOf("g1", "owner", "o1"), { failAt: 1 });
  await assert.rejects(deletion.deleteSoratomoSky({ db, storage: failing.gateway, nowMs: steadyClock() }, { groupId: "g1", skyId: "o1" }), /わざと失敗/);
  assert.deepEqual(await skyAuthors("g1"), ["owner:o1"], "文書が残るので、再実行で投稿者がわかる");

  const remaining = failing.files.size;
  assert.equal(remaining, 1, "2枚のうち、失敗した1枚が残っている");
  const healthy = fakeStorage([...failing.files]);
  assert.deepEqual(await deletion.deleteSoratomoSky({ db, storage: healthy.gateway, nowMs: steadyClock() }, { groupId: "g1", skyId: "o1" }), {
    skyDeleted: true,
    imagesDeleted: remaining,
  });
  assert.deepEqual(await skyAuthors("g1"), []);
  assert.equal(healthy.files.size, 0);
});

test("利用者単位・利用停止・解除・投稿1件: 引数の誤りは TypeError で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedSkies("g1", "amy", ["a1"]);
  await seedUser("amy", ["g1"]);
  const storage = fakeStorage([]);
  const deps = { db, storage: storage.gateway, nowMs: steadyClock() };
  const base = { uid: "amy", trigger: "self", deadlineMs: DEADLINE };
  for (const [i, req] of [
    { ...base, trigger: "other" },
    { ...base, trigger: undefined },
    { ...base, uid: "a/b" },
    { ...base, deadlineMs: Number.POSITIVE_INFINITY },
    { ...base, extraGroupIds: "g1" },
    { ...base, extraGroupIds: ["g_1"] },
  ].entries()) {
    await assert.rejects(deletion.deleteSoratomoUserData(deps, req), TypeError, `削除の引数 ${i}`);
  }
  await assert.rejects(deletion.deleteSoratomoUserData({ db, storage: storage.gateway }, base), TypeError, "nowMs が無い");
  await assert.rejects(deletion.suspendSoratomoUser(deps, { uid: "amy", deadlineMs: undefined }), TypeError, "停止の締め切りが無い");
  await assert.rejects(deletion.suspendSoratomoUser({ db, nowMs: steadyClock() }, { uid: "amy", deadlineMs: DEADLINE }), TypeError, "停止のゲートウェイが無い");
  await assert.rejects(deletion.unsuspendSoratomoUser(db, { uid: "" }), TypeError);
  await assert.rejects(deletion.deleteSoratomoSky(deps, { groupId: "g1", skyId: "a/1" }), TypeError);
  await assert.rejects(deletion.deleteSoratomoSky({ db }, { groupId: "g1", skyId: "a1" }), TypeError);

  const user = await userData("amy");
  assert.equal(user.suspendedAt, undefined, "停止の日時を書いていない");
  assert.deepEqual(await copyIds("amy"), ["g1"]);
  assert.deepEqual(await skyAuthors("g1"), ["amy:a1"]);
  assert.deepEqual(await memberRoles("g1"), { amy: "member", owner: "owner" });
});

// MARK: - 削除のエミュレーターのテスト（タスク 3.4・要確認3）

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
/** 回ごとに別の招待コード（3文字の頭＋回の番号）。 */
const codeFor = (head, i) => `${head}AAA${CODE_ALPHABET[i % 32]}${CODE_ALPHABET[Math.floor(i / 32) % 32]}`;
/** 想定内の拒否の理由（同時実行の並べ方で起きうるもの）。 */
const EXPECTED_REJECTIONS = new Set(["group_full", "not_member", "consent_required", "user_limit"]);

/** 退会の後の確認に使う、グループ1つの中身（投稿・メンバー・人数・オーナー・通知の間引き）。 */
async function groupSnapshot(groupId) {
  return {
    group: await groupData(groupId),
    skies: await skyAuthors(groupId),
    roles: await memberRoles(groupId),
    notify: await notifyIds(groupId),
  };
}

test("統合: 3つのグループ（引き継ぎ・ただのメンバー・最後の1人）と取り残しの画像。途中の失敗・締め切りの後も続きで消し切り、2回目は変わらない", async () => {
  // gA: amy がオーナー。参加の古い bob へ引き継ぐ
  await seedGroup({
    groupId: "gA",
    ownerId: "amy",
    inviteCode: "SKYAAAAA",
    members: [
      { uid: "amy", role: "owner", joinedAtMs: T(1) },
      { uid: "bob", role: "member", joinedAtMs: T(2) },
      { uid: "carl", role: "member", joinedAtMs: T(3) },
    ],
  });
  // gB: amy はただのメンバー。人数が 9 にずれている（数え直して 2 にする）
  await seedGroup({
    groupId: "gB",
    ownerId: "owner",
    inviteCode: "SKYBBBBB",
    memberCount: 9,
    members: [
      { uid: "owner", role: "owner", joinedAtMs: T(1) },
      { uid: "amy", role: "member", joinedAtMs: T(2) },
      { uid: "dan", role: "member", joinedAtMs: T(3) },
    ],
  });
  // gC: amy が最後の1人。前のメンバー old の投稿と通知の間引きが残っている
  await seedGroup({ groupId: "gC", ownerId: "amy", inviteCode: "SKYCCCCC", members: [{ uid: "amy", role: "owner", joinedAtMs: T(1) }] });
  await seedSkies("gA", "amy", ["a1"]);
  await seedSkies("gA", "bob", ["b1"]);
  await seedSkies("gB", "amy", ["a2"]);
  await seedSkies("gB", "owner", ["o2"]);
  await seedSkies("gC", "amy", ["a3"]);
  await seedSkies("gC", "old", ["x3"]);
  await seedNotify("gA", ["amy", "bob"]);
  await seedNotify("gB", ["amy", "owner"]);
  await seedNotify("gC", ["amy", "old"]);
  await seedUser("amy", ["gA", "gB", "gC"]);
  await seedReport("r1", { groupId: "gA", skyId: "a1", authorId: "amy", reporterId: "bob" });
  await seedReport("r2", { groupId: "gA", skyId: "b1", authorId: "bob", reporterId: "amy" });
  const kept = [...imagesOf("gA", "bob", "b1"), ...imagesOf("gB", "owner", "o2")].sort();
  const all = [
    ...imagesOf("gA", "amy", "a1"),
    "soratomo/gA/amy/orphan1/display.jpg",
    ...imagesOf("gB", "amy", "a2"),
    "soratomo/gB/amy/orphan2/thumb.jpg",
    ...imagesOf("gC", "amy", "a3"),
    ...imagesOf("gC", "old", "x3"),
    ...kept,
  ];
  const request = { uid: "amy", trigger: "self", deadlineMs: DEADLINE };

  // 1回目: 3件目の画像の削除で失敗する
  const failing = fakeStorage(all, { failAt: 3 });
  await assert.rejects(deletion.deleteSoratomoUserData({ db, storage: failing.gateway, nowMs: steadyClock() }, request), /わざと失敗/);
  assert.ok(await userData("amy"), "失敗の後も利用者の文書は残る");
  assert.ok((await copyIds("amy")).length >= 1, "失敗の後も写しが残る");

  // 2回目: 2つ目のグループに入った後で締め切りを過ぎる
  const files = fakeStorage([...failing.files]);
  const second = await deletion.deleteSoratomoUserData({ db, storage: files.gateway, nowMs: clockPastAfter(2) }, request);
  assert.equal(second.done, false);
  assert.ok((await copyIds("amy")).length >= 1, "未完了の後も写しが残る");

  // 3回目: 消し切る
  const third = await deletion.deleteSoratomoUserData({ db, storage: files.gateway, nowMs: steadyClock() }, request);
  assert.equal(third.done, true);

  // 消えるもの
  assert.equal(await userData("amy"), null);
  assert.deepEqual(await copyIds("amy"), []);
  assert.equal(await groupData("gC"), null);
  assert.deepEqual((await db.collection(GROUPS).doc("gC").listCollections()).map((c) => c.id), []);
  assert.equal((await db.collection(CODES).doc("SKYCCCCC").get()).exists, false);
  // 残るもの（ほかのメンバーの投稿と画像・通報の記録）
  assert.deepEqual([...files.files].sort(), kept);
  const a = await groupSnapshot("gA");
  assert.deepEqual(a.skies, ["bob:b1"]);
  assert.deepEqual(a.roles, { bob: "owner", carl: "member" });
  assert.deepEqual(a.notify, ["bob"]);
  assert.equal(a.group.inviteCode, "SKYAAAAA", "引き継いでもコードは変えない");
  const b = await groupSnapshot("gB");
  assert.deepEqual(b.skies, ["owner:o2"]);
  assert.equal(b.group.memberCount, 2, "ずれた人数（9）から、残りの数で代入する");
  assert.deepEqual(b.notify, ["owner"]);
  await assertGroupInvariants("gA");
  await assertGroupInvariants("gB");
  assert.equal((await db.collection(REPORTS).get()).size, 2);

  // 4回目: 状態も件数も変わらない（3.4）
  const before = { a: await groupSnapshot("gA"), b: await groupSnapshot("gB"), files: [...files.files].sort() };
  const fourth = await deletion.deleteSoratomoUserData({ db, storage: files.gateway, nowMs: steadyClock() }, request);
  assert.deepEqual(fourth, { done: true, ...ZERO_TOTALS });
  assert.deepEqual({ a: await groupSnapshot("gA"), b: await groupSnapshot("gB"), files: [...files.files].sort() }, before);
  assert.equal(await userData("amy"), null);
});

test("要確認3: 退会の削除と、参加（ほかの人2人と退会者自身）・投稿の作成を20回並べても、人数・所属数がずれず、退会者の投稿が残らない", async (t) => {
  const tally = { joinOk: 0, joinFull: 0, selfJoinOk: 0, selfJoinRejected: 0, skyCreated: 0, skyRejected: 0, deletionRetried: 0 };
  const unexpected = [];
  const contentionSites = [];
  for (let i = 0; i < 20; i += 1) {
    const g = `c${i}`;
    const h = `h${i}`;
    const amy = `amy${i}`;
    const carol = `carol${i}`;
    const dave = `dave${i}`;
    // 1人分の空きがある19人のグループから amy が抜ける（満員にすると、手順1の読みと書きの隙間に届いた参加が必ず
    // group_full で弾かれ、ずれが起きうる場面が消える）。2人とも入っても20人以下になる
    const fillers = Array.from({ length: 17 }, (_, k) => ({ uid: `f${i}x${k}`, role: "member", joinedAtMs: T(10 + k) }));
    await seedGroup({
      groupId: g,
      ownerId: `o${i}`,
      inviteCode: codeFor("CCC", i),
      members: [{ uid: `o${i}`, role: "owner", joinedAtMs: T(1) }, { uid: amy, role: "member", joinedAtMs: T(2) }, ...fillers],
    });
    await seedGroup({ groupId: h, ownerId: `p${i}`, inviteCode: codeFor("HHH", i), members: [{ uid: `p${i}`, role: "owner", joinedAtMs: T(1) }] });
    await seedSkies(g, amy, ["a1"]);
    await seedUser(amy, [g]);
    await seedUser(carol, []);
    await seedUser(dave, []);
    const storage = fakeStorage(imagesOf(g, amy, "a1"));

    // 手順1のトランザクションの直前（グループの前の締め切りの確認）を合図に、参加と作成を待たずに発火させる。
    // 合図からの遅れを回ごとに 0〜38ms ずらす（同時に投げるだけだと、毎回手順1より先に終わって競合の場面にならなかった）
    let racers = null;
    const settle = (p) => p.then((value) => ({ ok: true, value }), (error) => ({ ok: false, error }));
    const later = (ms, fn) => new Promise((resolve) => setTimeout(resolve, ms)).then(fn);
    const delay = i * 2;
    const nowMs = () => {
      if (racers === null) {
        racers = [
          settle(later(delay, () => store.joinGroupTx(db, { uid: carol, code: codeFor("CCC", i), policy: JOIN_POLICY }))),
          settle(later(delay, () => store.joinGroupTx(db, { uid: dave, code: codeFor("CCC", i), policy: JOIN_POLICY }))),
          settle(later(delay, () => store.joinGroupTx(db, { uid: amy, code: codeFor("HHH", i), policy: JOIN_POLICY }))),
          settle(
            later(delay, () =>
              store.createSkyTx(db, { uid: amy, input: { groupId: g, skyId: `s${i}`, width: 1, height: 1 }, policy: { containsNgWord: () => false } })
            )
          ),
        ];
      }
      return 0;
    };
    const deps = { db, storage: storage.gateway, nowMs };
    let result = await settle(deletion.deleteSoratomoUserData(deps, { uid: amy, trigger: "self", deadlineMs: DEADLINE }));
    assert.ok(racers, "手順1の前に参加と作成を発火できた");
    const [carolJoin, daveJoin, selfJoin, sky] = await Promise.all(racers);
    if (!result.ok) {
      // 削除のトランザクションの競合（本番なら Callable の失敗＝アプリの再試行に当たる）。数えてから続きを流す。
      // 競合と認めるのは ABORTED（10）と、エミュレーターが競合で返す INVALID_ARGUMENT（3）の
      // 「Transaction is invalid or closed」だけ。ほかは想定外として赤にする
      const e = result.error;
      const contention = e.code === 10 || (e.code === 3 && /Transaction is invalid or closed/.test(e.message));
      if (contention) {
        tally.deletionRetried += 1;
        const frame = (e.stack || "").split("\n").find((line) => line.includes("soratomoDeletion.js")) || "(場所不明)";
        contentionSites.push(`回 ${i}: code ${e.code} ${frame.trim()}`);
      } else {
        unexpected.push(`回 ${i} 削除: ${e.code} ${e.message}`);
      }
      result = await settle(deletion.deleteSoratomoUserData({ db, storage: storage.gateway, nowMs: steadyClock() }, { uid: amy, trigger: "self", deadlineMs: DEADLINE }));
    }
    assert.ok(result.ok && result.value.done, `回 ${i}: 削除が完了する`);

    for (const [name, r] of [["carol", carolJoin], ["dave", daveJoin], ["self", selfJoin], ["sky", sky]]) {
      if (!r.ok && !EXPECTED_REJECTIONS.has(r.error.reason)) unexpected.push(`回 ${i} ${name}: ${r.error.reason || r.error.code} ${r.error.message}`);
    }
    tally.joinOk += [carolJoin, daveJoin].filter((r) => r.ok).length;
    tally.joinFull += [carolJoin, daveJoin].filter((r) => !r.ok && r.error.reason === "group_full").length;
    if (selfJoin.ok) tally.selfJoinOk += 1;
    else tally.selfJoinRejected += 1;
    if (sky.ok) tally.skyCreated += 1;
    else tally.skyRejected += 1;

    // 人数＝メンバーの件数で20以下・オーナーはちょうど1人（2.11）
    for (const groupId of [g, h]) {
      const group = await groupData(groupId);
      const roles = await memberRoles(groupId);
      assert.equal(group.memberCount, Object.keys(roles).length, `回 ${i} ${groupId}: 人数がメンバーの件数と等しい`);
      assert.ok(group.memberCount <= core.MAX_MEMBERS, `回 ${i} ${groupId}: 20人以下`);
      assert.equal(roles[amy], undefined, `回 ${i} ${groupId}: 退会者はメンバーでない`);
      await assertGroupInvariants(groupId);
    }
    // 所属数＝写しの件数で10以下（文書が無ければ写しも無い）
    for (const uid of [amy, carol, dave]) {
      const user = await userData(uid);
      const copies = await copyIds(uid);
      if (user === null) assert.deepEqual(copies, [], `回 ${i} ${uid}: 文書が無ければ写しも無い`);
      else {
        assert.equal(user.groupCount, copies.length, `回 ${i} ${uid}: 所属数が写しの件数と等しい`);
        assert.ok(user.groupCount <= core.MAX_GROUPS_PER_USER, `回 ${i} ${uid}: 10個以下`);
      }
    }
    assert.equal(await userData(amy), null, `回 ${i}: 退会者の文書は残らない`);
    assert.deepEqual((await skyAuthors(g)).filter((s) => s.startsWith(`${amy}:`)), [], `回 ${i}: 退会者の投稿が残らない`);
  }
  t.diagnostic(`要確認3の分布 ${JSON.stringify(tally)}`);
  if (contentionSites.length > 0) t.diagnostic(`削除の競合 ${JSON.stringify(contentionSites)}`);
  if (unexpected.length > 0) t.diagnostic(`想定外 ${JSON.stringify(unexpected)}`);
  assert.deepEqual(unexpected, [], "想定外の失敗（トランザクションの競合の使い切りなど）が無い");
});

test("利用停止の後: 作成・参加・投稿が停止を理由に拒否され、解除の後は作成と参加が通る", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid: "amy", role: "member", joinedAtMs: T(2) }] });
  await seedGroup({ groupId: "g2", ownerId: "bob", inviteCode: "SKYBBBBB", members: [{ uid: "bob", role: "owner", joinedAtMs: T(1) }] });
  await seedUser("amy", ["g1"]);
  const deps = { db, storage: fakeStorage([]).gateway, nowMs: steadyClock() };
  assert.equal((await deletion.suspendSoratomoUser(deps, { uid: "amy", deadlineMs: DEADLINE })).done, true);
  const user = await userData("amy");
  assert.ok(user.suspendedAt);
  assert.equal(user.groupCount, 0);
  assert.deepEqual(await copyIds("amy"), []);

  const suspended = (err) => err.reason === "suspended";
  await assert.rejects(store.createGroupTx(db, { uid: "amy", name: "空の会", requestId: "r1", policy: CREATE_POLICY }), suspended);
  await assert.rejects(store.joinGroupTx(db, { uid: "amy", code: "SKYBBBBB", policy: JOIN_POLICY }), suspended);
  await assert.rejects(
    store.createSkyTx(db, { uid: "amy", input: { groupId: "g2", skyId: "s1", width: 1, height: 1 }, policy: { containsNgWord: () => false } }),
    suspended
  );

  await deletion.unsuspendSoratomoUser(db, { uid: "amy" });
  const created = await store.createGroupTx(db, { uid: "amy", name: "空の会", requestId: "r2", policy: CREATE_POLICY });
  assert.equal(created.memberCount, 1);
  assert.deepEqual(await store.joinGroupTx(db, { uid: "amy", code: "SKYBBBBB", policy: JOIN_POLICY }), { groupId: "g2", alreadyMember: false });
  assert.equal((await userData("amy")).groupCount, 2);
  assert.deepEqual(await copyIds("amy"), [created.groupId, "g2"].sort());
});

// MARK: - 停止中の人の記録（セキュリティの指摘への対応）

test("停止中の人: 本人の退会の削除（self）や管理の削除（admin）では停止の記録を消さない。アカウントの無い人の後始末だけが消す", async () => {
  const deps = { db, storage: fakeStorage([]).gateway, nowMs: steadyClock() };
  for (const trigger of ["self", "admin"]) {
    const uid = `sus${trigger}`;
    await seedGroup({ groupId: `g${trigger}`, ownerId: "owner", inviteCode: trigger === "self" ? "SKYAAAAA" : "SKYBBBBB", members: [{ uid: "owner", role: "owner", joinedAtMs: T(1) }, { uid, role: "member", joinedAtMs: T(2) }] });
    await seedUser(uid, [`g${trigger}`]);
    await deletion.suspendSoratomoUser(deps, { uid, deadlineMs: DEADLINE });
    const suspendedAt = (await userData(uid)).suspendedAt.toMillis();
    // 停止の後にまた所属が増えた場合も含めて、削除を流す（停止中は参加できないので、写しは管理の都合で直接入れる）
    await db.collection(USERS).doc(uid).collection("groups").doc(`g${trigger}`).set({ groupId: `g${trigger}`, joinedAt: Timestamp.now() });

    const result = await deletion.deleteSoratomoUserData(deps, { uid, trigger, deadlineMs: DEADLINE });
    assert.equal(result.done, true);
    const user = await userData(uid);
    assert.ok(user, `${trigger}: 停止中の人の文書は残る（アカウントを消さずに呼ぶと、停止が解けてしまうため）`);
    assert.equal(user.suspendedAt.toMillis(), suspendedAt, `${trigger}: 停止の日時は変わらない`);
    assert.equal(user.groupCount, 0);
    assert.deepEqual(await copyIds(uid), []);
    // 同意し直しても、作成は停止で拒否される
    await store.agreeGuidelineTx(db, { uid, input: { version: core.GUIDELINE_VERSION }, policy: JOIN_POLICY });
    await assert.rejects(
      store.createGroupTx(db, { uid, name: "空の会", requestId: "r1", policy: CREATE_POLICY }),
      (err) => err.reason === "suspended",
      `${trigger}: 削除の後も停止のまま`
    );
  }
});

test("停止中の人: アカウントの無い人の後始末（account_deleted）は停止の記録ごと消す。停止していない人の self は従来どおり消す", async () => {
  const deps = { db, storage: fakeStorage([]).gateway, nowMs: steadyClock() };
  await deletion.suspendSoratomoUser(deps, { uid: "gone", deadlineMs: DEADLINE });
  assert.ok((await userData("gone")).suspendedAt);
  assert.equal((await deletion.deleteSoratomoUserData(deps, { uid: "gone", trigger: "account_deleted", deadlineMs: DEADLINE })).done, true);
  assert.equal(await userData("gone"), null, "要件2.3: アカウントが無くなったら、停止の記録も消す");

  await seedUser("plain", []);
  assert.equal((await deletion.deleteSoratomoUserData(deps, { uid: "plain", trigger: "self", deadlineMs: DEADLINE })).done, true);
  assert.equal(await userData("plain"), null);
});
