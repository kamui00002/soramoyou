//
// soratomoStore.js のテスト（Firestore のエミュレーターに対してトランザクションを直接呼ぶ）⭐️
//
// 実行（リポジトリの根で。Firestore のエミュレーターは Java で動く）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios "cd functions && node --test soratomoStore.test.js"
//
// ⚠️ soratomoStore.test.js と soratomo.test.js は、同じエミュレーターの文書を各テストの前に全部消して使う。
//    node --test に2つ渡すと既定では同時に走って消し合うので、--test-concurrency=1 を付ける（npm run test:emulator）。
// ⚠️ 本番へ書く事故の柵: プロジェクトID の soramoyou-ios は本番と同じで、この Mac の firebase-admin は
//    資格情報を持っている。FIRESTORE_EMULATOR_HOST が無いと、firebase-admin はそのまま本番の Firestore へ書く。
//    そこで、エミュレーター（127.0.0.1・localhost・[::1]）を指していなければ、initializeApp より前に例外で止める。
//    skip にはしない（skip は「何も確かめていない緑」に化けるため）。
//
// ⚠️ 陽性対照（tasks 7.3 の完了の条件）: 先に「わざと壊した soratomoStore.js」でこのテストが赤になるのを
//    確かめてから、正しい実装で通す。壊し方は handoffs の「壊し方_7.json」にある。
//
// ⚠️ package.json の lint / test への登録は tasks 8.3 で行う（エミュレーターが要るので、登録の形も 8.3 で決める）。
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

/** エミュレーターのプロジェクトID。種データと同じ ID にそろえる（tasks 7.3）。 */
const PROJECT_ID = "soramoyou-ios";
const app = initializeApp({ projectId: PROJECT_ID }, "soratomoStoreTest");
const db = getFirestore(app);

const GROUPS = "soratomoGroups";
const CODES = "soratomoInviteCodes";
const USERS = "soratomoUsers";

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

/**
 * 種データ用の招待コード（字種内の8文字）。i ごとに別のコードになる。
 * @param {number} i
 */
function seedCode(i) {
  const a = core.INVITE_ALPHABET;
  return "SEED" + a[Math.floor(i / a.length) % a.length] + a[i % a.length] + "ZZ";
}

/**
 * グループの文書・メンバー・招待コードの文書を、データモデルの形で直接入れる（トランザクションを通さない）。
 * メンバーの所属の写し（soratomoUsers）は入れない（必要なテストだけ seedMemberships で入れる）。
 */
async function seedGroup({ groupId, ownerId, inviteCode, memberIds }) {
  const batch = db.batch();
  const groupRef = db.collection(GROUPS).doc(groupId);
  batch.set(groupRef, {
    name: "種のグループ",
    ownerId,
    inviteCode,
    memberCount: memberIds.length,
    createdAt: Timestamp.now(),
    lastActivityAt: Timestamp.now(),
  });
  for (const uid of memberIds) {
    batch.set(groupRef.collection("members").doc(uid), {
      uid,
      role: uid === ownerId ? "owner" : "member",
      joinedAt: Timestamp.now(),
    });
  }
  batch.set(db.collection(CODES).doc(inviteCode), { groupId, createdAt: Timestamp.now() });
  await batch.commit();
}

/** 利用者がすでに n 個のグループに所属している状態（所属数と所属の写し）を入れる。 */
async function seedMemberships(uid, n) {
  const batch = db.batch();
  const userRef = db.collection(USERS).doc(uid);
  batch.set(userRef, { groupCount: n, updatedAt: Timestamp.now() });
  for (let i = 0; i < n; i++) {
    batch.set(userRef.collection("groups").doc(`filler-${i}`), { groupId: `filler-${i}`, joinedAt: Timestamp.now() });
  }
  await batch.commit();
}

/** n 人のメンバー ID（m00, m01, …）。 */
function memberIds(n) {
  return Array.from({ length: n }, (_, i) => `m${String(i).padStart(2, "0")}`);
}

async function groupData(groupId) {
  return (await db.collection(GROUPS).doc(groupId).get()).data();
}
async function memberDocCount(groupId) {
  return (await db.collection(GROUPS).doc(groupId).collection("members").get()).size;
}
async function userGroupCount(uid) {
  const snap = await db.collection(USERS).doc(uid).get();
  return snap.exists ? snap.get("groupCount") : undefined;
}
async function userGroupDocCount(uid) {
  return (await db.collection(USERS).doc(uid).collection("groups").get()).size;
}

/** ドメインのエラー（理由つき）であることを確かめる assert.rejects 用の判定。 */
function domainError(reason) {
  return (err) => {
    assert.ok(err instanceof store.SoratomoDomainError, `SoratomoDomainError ではない: ${err && err.stack}`);
    assert.equal(err.reason, reason);
    return true;
  };
}

/**
 * 同時に呼んだ結果を、成功・ドメインのエラーの理由・競合（ABORTED）・その他に分けて数える。
 * 競合を上限の理由に丸めない（丸めると、上限の判定が壊れていても緑に見えるため）。
 */
function tally(results) {
  const out = { ok: 0, reasons: {}, contention: 0, other: [] };
  for (const r of results) {
    if (r.status === "fulfilled") {
      out.ok++;
    } else if (r.reason instanceof store.SoratomoDomainError) {
      out.reasons[r.reason.reason] = (out.reasons[r.reason.reason] || 0) + 1;
    } else if (r.reason && r.reason.code === 10) {
      // 10 = gRPC の ABORTED（トランザクションの競合で再試行が尽きた）
      out.contention++;
    } else {
      out.other.push(String(r.reason && r.reason.message));
    }
  }
  return out;
}

/** 決まった順に値を返す乱数（招待コードの重なりを起こすため）。呼ばれた回数も数える。 */
function scriptedRandom(values) {
  const fn = () => {
    const v = values[Math.min(fn.calls, values.length - 1)];
    fn.calls++;
    return v;
  };
  fn.calls = 0;
  return fn;
}

// MARK: - 作成（createGroupTx）

test("作成: 作成者をオーナーかつ最初のメンバーにし、所属数・所属の写し・招待コードをそろえて作る", async () => {
  const result = await store.createGroupTx(db, { uid: "alice", name: "  空の会  ", requestId: "req-1" });

  assert.equal(result.name, "空の会", "前後の空白を除いた名前で作る");
  assert.equal(result.memberCount, 1);
  assert.equal(core.normalizeInviteCode(result.inviteCode), result.inviteCode, "字種内の8文字のコード");

  const group = await groupData(result.groupId);
  assert.equal(group.name, "空の会");
  assert.equal(group.ownerId, "alice");
  assert.equal(group.inviteCode, result.inviteCode);
  assert.equal(group.memberCount, 1);
  assert.ok(group.createdAt instanceof Timestamp);
  assert.ok(group.lastActivityAt instanceof Timestamp);

  const member = (await db.collection(GROUPS).doc(result.groupId).collection("members").doc("alice").get()).data();
  assert.equal(member.uid, "alice");
  assert.equal(member.role, "owner");
  assert.equal(await memberDocCount(result.groupId), 1);

  const code = (await db.collection(CODES).doc(result.inviteCode).get()).data();
  assert.equal(code.groupId, result.groupId);

  const user = (await db.collection(USERS).doc("alice").get()).data();
  assert.equal(user.groupCount, 1);
  assert.equal(user.lastCreateRequestId, "req-1");
  assert.equal(user.lastCreatedGroupId, result.groupId);
  assert.equal(await userGroupDocCount("alice"), 1);
  const copy = (await db.collection(USERS).doc("alice").collection("groups").doc(result.groupId).get()).data();
  assert.equal(copy.groupId, result.groupId);

  assert.equal((await db.collection("users").get()).size, 0, "利用者の文書（users）には書かない");
});

test("作成: 名前が空白だけ・31文字なら invalid_name で、何も書かない", async () => {
  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: " 　 ", requestId: "r1" }), domainError("invalid_name"));
  const cloud = String.fromCodePoint(0x1f324);
  await assert.rejects(
    store.createGroupTx(db, { uid: "alice", name: cloud.repeat(31), requestId: "r2" }),
    domainError("invalid_name")
  );
  assert.equal((await db.collection(GROUPS).get()).size, 0);
  assert.equal((await db.collection(USERS).get()).size, 0);
});

test("作成: 絵文字を含む30文字の名前は通る（コードポイントで数える）", async () => {
  const cloud = String.fromCodePoint(0x1f324);
  const result = await store.createGroupTx(db, { uid: "alice", name: cloud.repeat(30), requestId: "r1" });
  assert.equal((await groupData(result.groupId)).name, cloud.repeat(30));
});

test("作成: 同じ要求IDの再送では前回のグループを返し、2つ目を作らない（冪等）", async () => {
  const first = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1" });
  const again = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1" });
  assert.deepEqual(again, first);
  assert.equal((await db.collection(GROUPS).get()).size, 1);
  assert.equal((await db.collection(CODES).get()).size, 1);
  assert.equal(await userGroupCount("alice"), 1);
  assert.equal(await userGroupDocCount("alice"), 1);

  const other = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-2" });
  assert.notEqual(other.groupId, first.groupId, "別の要求IDなら新しく作る");
  assert.equal(await userGroupCount("alice"), 2);
});

test("作成: 同じ要求IDを同時に2回送っても、グループは1つだけ", async () => {
  const results = await Promise.allSettled([
    store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1" }),
    store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1" }),
  ]);
  const t = tally(results);
  assert.deepEqual(t.other, []);
  assert.equal((await db.collection(GROUPS).get()).size, 1);
  assert.equal(await userGroupCount("alice"), 1);
  assert.equal(await userGroupDocCount("alice"), 1);
});

test("作成: 所属が9個なら作れ、10個なら user_limit で何も書かない", async () => {
  await seedMemberships("alice", 9);
  await store.createGroupTx(db, { uid: "alice", name: "10個目", requestId: "r1" });
  assert.equal(await userGroupCount("alice"), 10);
  assert.equal(await userGroupDocCount("alice"), 10);

  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: "11個目", requestId: "r2" }), domainError("user_limit"));
  assert.equal(await userGroupCount("alice"), 10);
  assert.equal(await userGroupDocCount("alice"), 10);
  assert.equal((await db.collection(GROUPS).get()).size, 1);
});

test("作成: 招待コードが既存と重なれば作り直す", async () => {
  await seedGroup({ groupId: "g-old", ownerId: "bob", inviteCode: "AAAAAAAA", memberIds: ["bob"] });
  // 先の8回は "A"（＝既存と重なる）、そのあとは "B" を返す
  const random = scriptedRandom([0, 0, 0, 0, 0, 0, 0, 0, 1]);
  const result = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r1" }, { randomInt: random });
  assert.equal(result.inviteCode, "BBBBBBBB");
  assert.equal((await db.collection(CODES).doc("AAAAAAAA").get()).get("groupId"), "g-old", "既存のコードは書き換えない");
  assert.equal((await db.collection(CODES).doc("BBBBBBBB").get()).get("groupId"), result.groupId);
});

test("作成: 招待コードが5回続けて重なれば、ドメインのエラーではない失敗で終え、何も書かない", async () => {
  await seedGroup({ groupId: "g-old", ownerId: "bob", inviteCode: "AAAAAAAA", memberIds: ["bob"] });
  const random = scriptedRandom([0]);
  await assert.rejects(
    store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r1" }, { randomInt: random }),
    (err) => {
      assert.ok(!(err instanceof store.SoratomoDomainError), "想定外の失敗（internal）として扱う");
      return true;
    }
  );
  assert.equal(random.calls, 5 * core.INVITE_CODE_LENGTH, "作り直しは最大5回");
  assert.equal((await db.collection(GROUPS).get()).size, 1, "種のグループだけ");
  assert.equal((await db.collection(USERS).get()).size, 0);
});

test("作成: 要求IDが文字列でなければ、ドメインのエラーではない失敗にする", async () => {
  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "" }), TypeError);
  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: 1 }), TypeError);
  assert.equal((await db.collection(GROUPS).get()).size, 0);
});

// MARK: - 参加（joinGroupTx）

test("参加: メンバーの文書・メンバー数・所属の写し・所属数が、そろって増える", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await seedMemberships("carol", 2);

  const result = await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA" });
  assert.deepEqual(result, { groupId: "g1", alreadyMember: false });

  const member = (await db.collection(GROUPS).doc("g1").collection("members").doc("carol").get()).data();
  assert.equal(member.uid, "carol");
  assert.equal(member.role, "member");
  assert.ok(member.joinedAt instanceof Timestamp);
  assert.equal((await groupData("g1")).memberCount, 2);
  assert.equal(await memberDocCount("g1"), 2);
  assert.equal(await userGroupCount("carol"), 3);
  assert.equal(await userGroupDocCount("carol"), 3);
  assert.equal((await db.collection(USERS).doc("carol").collection("groups").doc("g1").get()).get("groupId"), "g1");
  assert.equal((await db.collection("users").get()).size, 0, "利用者の文書（users）には書かない");
});

test("参加: 初めての利用者（soratomoUsers の文書が無い）でも所属数1で作られる", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA" });
  assert.equal(await userGroupCount("carol"), 1);
  assert.equal(await userGroupDocCount("carol"), 1);
});

test("参加: 小文字・ハイフン・全角の入力も正規化して照合する", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  const result = await store.joinGroupTx(db, { uid: "carol", code: "sky-aａaaa" });
  assert.equal(result.groupId, "g1");
});

test("参加: 形が違うコードは invalid_format、無いコードは not_found", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKY" }), domainError("invalid_format"));
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKY0AAAA" }), domainError("invalid_format"));
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYBBBBB" }), domainError("not_found"));
  assert.equal((await groupData("g1")).memberCount, 1);
  assert.equal((await db.collection(USERS).get()).size, 0);
});

test("参加: コードの文書が残っていても、グループの今のコードでなければ not_found", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await db.collection(CODES).doc("SKYPASTA").set({ groupId: "g1", createdAt: Timestamp.now() });
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYPASTA" }), domainError("not_found"));
  assert.equal((await groupData("g1")).memberCount, 1);
});

test("参加: 19人のグループへの1人の参加は通り、20人になる", async () => {
  await seedGroup({ groupId: "g1", ownerId: "m00", inviteCode: "SKYAAAAA", memberIds: memberIds(19) });
  await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA" });
  assert.equal((await groupData("g1")).memberCount, 20);
  assert.equal(await memberDocCount("g1"), 20);
});

test("参加: 20人のグループは group_full、所属10個の人は user_limit（両方なら user_limit が先）", async () => {
  await seedGroup({ groupId: "full", ownerId: "m00", inviteCode: "SKYFULLA", memberIds: memberIds(20) });
  await seedGroup({ groupId: "g2", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await seedMemberships("busy", 10);

  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYFULLA" }), domainError("group_full"));
  await assert.rejects(store.joinGroupTx(db, { uid: "busy", code: "SKYAAAAA" }), domainError("user_limit"));
  await assert.rejects(store.joinGroupTx(db, { uid: "busy", code: "SKYFULLA" }), domainError("user_limit"));

  assert.equal((await groupData("full")).memberCount, 20);
  assert.equal((await groupData("g2")).memberCount, 1);
  assert.equal(await userGroupCount("busy"), 10);
  assert.equal(await userGroupCount("carol"), undefined);
});

test("参加: 既存のメンバーの再参加は、上限とは無関係に「既存のメンバー」の印つきの成功で、何も増やさない", async () => {
  await seedGroup({ groupId: "full", ownerId: "m00", inviteCode: "SKYFULLA", memberIds: memberIds(20) });
  await seedMemberships("m05", 10);
  const result = await store.joinGroupTx(db, { uid: "m05", code: "SKYFULLA" });
  assert.deepEqual(result, { groupId: "full", alreadyMember: true });
  assert.equal((await groupData("full")).memberCount, 20);
  assert.equal(await memberDocCount("full"), 20);
  assert.equal(await userGroupCount("m05"), 10);
  assert.equal(await userGroupDocCount("m05"), 10);
});

test("同時の参加: 19人のグループへ25人が同時に参加しても、20人を超えない", async (t) => {
  await seedGroup({ groupId: "g1", ownerId: "m00", inviteCode: "SKYAAAAA", memberIds: memberIds(19) });
  const joiners = Array.from({ length: 25 }, (_, i) => `j${String(i).padStart(2, "0")}`);
  const results = await Promise.allSettled(joiners.map((uid) => store.joinGroupTx(db, { uid, code: "SKYAAAAA" })));
  const r = tally(results);
  t.diagnostic(`成功=${r.ok} 理由=${JSON.stringify(r.reasons)} 競合=${r.contention}`);

  assert.deepEqual(r.other, [], "想定外の失敗が無い");
  assert.equal(r.ok, 1, "通るのは1人だけ");
  assert.equal((r.reasons.group_full || 0) + r.contention, 24);
  assert.deepEqual(Object.keys(r.reasons).filter((k) => k !== "group_full"), []);

  assert.equal((await groupData("g1")).memberCount, 20);
  assert.equal(await memberDocCount("g1"), 20, "メンバーの文書の数とメンバー数が一致する");
  let copies = 0;
  for (const uid of joiners) copies += await userGroupDocCount(uid);
  assert.equal(copies, 1, "所属の写しも1人分だけ");
});

test("同時の参加: 所属9個の人が25のグループへ同時に参加しても、10個を超えない", async (t) => {
  const groups = Array.from({ length: 25 }, (_, i) => ({ groupId: `g${i}`, code: seedCode(i) }));
  for (const g of groups) await seedGroup({ groupId: g.groupId, ownerId: `o${g.groupId}`, inviteCode: g.code, memberIds: [`o${g.groupId}`] });
  await seedMemberships("dave", 9);

  const results = await Promise.allSettled(groups.map((g) => store.joinGroupTx(db, { uid: "dave", code: g.code })));
  const r = tally(results);
  t.diagnostic(`成功=${r.ok} 理由=${JSON.stringify(r.reasons)} 競合=${r.contention}`);

  assert.deepEqual(r.other, [], "想定外の失敗が無い");
  assert.equal(r.ok, 1, "通るのは1つだけ");
  assert.equal((r.reasons.user_limit || 0) + r.contention, 24);
  assert.deepEqual(Object.keys(r.reasons).filter((k) => k !== "user_limit"), []);

  assert.equal(await userGroupCount("dave"), 10);
  assert.equal(await userGroupDocCount("dave"), 10, "所属の写しの数と所属数が一致する");
  let joined = 0;
  for (const g of groups) joined += (await groupData(g.groupId)).memberCount - 1;
  assert.equal(joined, 1, "メンバー数が増えたグループも1つだけ");
});

// MARK: - 再発行（regenerateInviteCodeTx）

test("再発行: オーナーなら新しいコードに替わり、古いコードでの参加は not_found、新しいコードでは参加できる", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner", "m01"] });

  const { inviteCode } = await store.regenerateInviteCodeTx(db, { uid: "owner", groupId: "g1" });
  assert.notEqual(inviteCode, "SKYAAAAA");
  assert.equal(core.normalizeInviteCode(inviteCode), inviteCode);
  assert.equal((await groupData("g1")).inviteCode, inviteCode);
  assert.equal((await db.collection(CODES).doc("SKYAAAAA").get()).exists, false, "古いコードの文書を消す");
  assert.equal((await db.collection(CODES).doc(inviteCode).get()).get("groupId"), "g1");

  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA" }), domainError("not_found"));
  const joined = await store.joinGroupTx(db, { uid: "carol", code: inviteCode });
  assert.equal(joined.groupId, "g1");
});

test("再発行: オーナーでないメンバーは not_owner で、何も変えない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner", "m01"] });
  await assert.rejects(store.regenerateInviteCodeTx(db, { uid: "m01", groupId: "g1" }), domainError("not_owner"));
  assert.equal((await groupData("g1")).inviteCode, "SKYAAAAA");
  assert.equal((await db.collection(CODES).doc("SKYAAAAA").get()).get("groupId"), "g1");
  assert.equal((await db.collection(CODES).get()).size, 1);
});

test("再発行: 無いグループは not_found", async () => {
  await assert.rejects(store.regenerateInviteCodeTx(db, { uid: "owner", groupId: "nope" }), domainError("not_found"));
  await assert.rejects(store.regenerateInviteCodeTx(db, { uid: "owner", groupId: "a/b" }), domainError("not_found"));
  await assert.rejects(store.regenerateInviteCodeTx(db, { uid: "owner", groupId: "" }), domainError("not_found"));
});

test("再発行: 新しいコードが既存と重なれば作り直す", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await seedGroup({ groupId: "g2", ownerId: "bob", inviteCode: "AAAAAAAA", memberIds: ["bob"] });
  const random = scriptedRandom([0, 0, 0, 0, 0, 0, 0, 0, 1]);
  const { inviteCode } = await store.regenerateInviteCodeTx(db, { uid: "owner", groupId: "g1" }, { randomInt: random });
  assert.equal(inviteCode, "BBBBBBBB");
  assert.equal((await db.collection(CODES).doc("AAAAAAAA").get()).get("groupId"), "g2", "他のグループのコードは消さない");
});

test("再発行: グループのコードの文書が別のグループを指していたら、その文書は消さない", async () => {
  await seedGroup({ groupId: "g2", ownerId: "bob", inviteCode: "SHAREDAA", memberIds: ["bob"] });
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  // 壊れた状態: g1 の inviteCode が g2 のコードを指している
  await db.collection(GROUPS).doc("g1").update({ inviteCode: "SHAREDAA" });
  const { inviteCode } = await store.regenerateInviteCodeTx(db, { uid: "owner", groupId: "g1" });
  assert.equal((await db.collection(CODES).doc("SHAREDAA").get()).get("groupId"), "g2");
  assert.equal((await groupData("g1")).inviteCode, inviteCode);
});

// MARK: - 通知の枠（claimNotifySlot）

const T0 = Date.UTC(2026, 9, 4, 12, 0, 0);

async function notifyState(groupId, uid) {
  const snap = await db.collection(GROUPS).doc(groupId).collection("notifyState").doc(uid).get();
  return snap.exists ? snap.data() : null;
}

test("通知の枠: 初回は送る。送る前に最後の時刻と投稿IDを書く", async () => {
  const decision = await store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "sky1", nowMs: T0 });
  assert.equal(decision, "send");
  const state = await notifyState("g1", "bob");
  assert.equal(state.lastSkyId, "sky1");
  assert.ok(state.lastSentAt instanceof Timestamp, "最後の時刻は Firestore の時刻で書く");
  assert.equal(state.lastSentAt.toMillis(), T0);
});

test("通知の枠: 同じ投稿は重複、5分以内（ちょうどを含む）は間引き、5分を過ぎたら送る", async () => {
  await store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "sky1", nowMs: T0 });

  assert.equal(await store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "sky1", nowMs: T0 + 3_600_000 }), "duplicate");
  assert.equal(await store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "sky2", nowMs: T0 + 1_000 }), "throttled");
  assert.equal(await store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "sky3", nowMs: T0 + core.THROTTLE_MS }), "throttled");
  const kept = await notifyState("g1", "bob");
  assert.equal(kept.lastSkyId, "sky1", "送らないときは状態を書かない");
  assert.equal(kept.lastSentAt.toMillis(), T0);

  assert.equal(await store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "sky4", nowMs: T0 + core.THROTTLE_MS + 1 }), "send");
  const moved = await notifyState("g1", "bob");
  assert.equal(moved.lastSkyId, "sky4");
  assert.equal(moved.lastSentAt.toMillis(), T0 + core.THROTTLE_MS + 1);
});

test("通知の枠: ほぼ同時の2件の投稿でも、同じ受信者へ送るのは1通だけ", async () => {
  const results = await Promise.all([
    store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "skyA", nowMs: T0 }),
    store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "skyB", nowMs: T0 + 10 }),
  ]);
  assert.deepEqual([...results].sort(), ["send", "throttled"]);
});

test("通知の枠: 受信者ごと・グループごとに別に数える", async () => {
  assert.equal(await store.claimNotifySlot(db, { groupId: "g1", uid: "bob", skyId: "sky1", nowMs: T0 }), "send");
  assert.equal(await store.claimNotifySlot(db, { groupId: "g1", uid: "carol", skyId: "sky1", nowMs: T0 }), "send");
  assert.equal(await store.claimNotifySlot(db, { groupId: "g2", uid: "bob", skyId: "skyX", nowMs: T0 }), "send");
});
