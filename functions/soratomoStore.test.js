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
// ⚠️ release-gate 2.1 から、作成と参加には方針（POLICY）が要り、作成・参加する人には同意（agree）が要る。
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

/**
 * 作成と参加に渡す方針（release-gate 2.1）。現行のガイドラインの版と、どの名前も該当しない NGワードの判定。
 * 同意の判定は「利用者の文書の版が、この版と等しいか」なので、作成・参加する人は agree() で同意を入れておく。
 */
const POLICY = Object.freeze({ guidelineVersion: core.GUIDELINE_VERSION, containsNgWord: () => false });

/** ダミーの語（実在の語は書かない・tasks の「進め方の約束」）で作った NGワードの判定つきの方針。 */
const NG_POLICY = Object.freeze({
  guidelineVersion: core.GUIDELINE_VERSION,
  containsNgWord: (text) => core.containsNgWord(text, core.prepareNgWords(["てすとごい"])),
});

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

/**
 * 利用者がすでに n 個のグループに所属している状態（所属数と所属の写し）を入れる。
 * agree() で入れた同意を消さないよう merge で書く（release-gate 2.1 で同意が要るようになった）。
 */
async function seedMemberships(uid, n) {
  const batch = db.batch();
  const userRef = db.collection(USERS).doc(uid);
  batch.set(userRef, { groupCount: n, updatedAt: Timestamp.now() }, { merge: true });
  for (let i = 0; i < n; i++) {
    batch.set(userRef.collection("groups").doc(`filler-${i}`), { groupId: `filler-${i}`, joinedAt: Timestamp.now() });
  }
  await batch.commit();
}

/**
 * 利用者が現行の版のガイドラインに同意した状態を入れる（release-gate 2.1）。所属数などほかの項目は merge で残す。
 * @param {...string} uids
 */
async function agree(...uids) {
  const batch = db.batch();
  for (const uid of uids) {
    batch.set(db.collection(USERS).doc(uid), { guidelineVersion: core.GUIDELINE_VERSION, guidelineAgreedAt: Timestamp.now() }, { merge: true });
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

/**
 * ドメインのエラー（理由つき）であることを確かめる assert.rejects 用の判定。
 * details を渡したときは、利用者へ返す詳細（release-gate 2.1・consent_required の currentVersion）も確かめる。
 */
function domainError(reason, details) {
  return (err) => {
    assert.ok(err instanceof store.SoratomoDomainError, `SoratomoDomainError ではない: ${err && err.stack}`);
    assert.equal(err.reason, reason);
    if (details !== undefined) assert.deepEqual(err.details, details);
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
  await agree("alice");
  const result = await store.createGroupTx(db, { uid: "alice", name: "  空の会  ", requestId: "req-1", policy: POLICY });

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
  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: " 　 ", requestId: "r1", policy: POLICY }), domainError("invalid_name"));
  const cloud = String.fromCodePoint(0x1f324);
  await assert.rejects(
    store.createGroupTx(db, { uid: "alice", name: cloud.repeat(31), requestId: "r2", policy: POLICY }),
    domainError("invalid_name")
  );
  assert.equal((await db.collection(GROUPS).get()).size, 0);
  assert.equal((await db.collection(USERS).get()).size, 0);
});

test("作成: 絵文字を含む30文字の名前は通る（コードポイントで数える）", async () => {
  await agree("alice");
  const cloud = String.fromCodePoint(0x1f324);
  const result = await store.createGroupTx(db, { uid: "alice", name: cloud.repeat(30), requestId: "r1", policy: POLICY });
  assert.equal((await groupData(result.groupId)).name, cloud.repeat(30));
});

test("作成: 同じ要求IDの再送では前回のグループを返し、2つ目を作らない（冪等）", async () => {
  await agree("alice");
  const first = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: POLICY });
  const again = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: POLICY });
  assert.deepEqual(again, first);
  assert.equal((await db.collection(GROUPS).get()).size, 1);
  assert.equal((await db.collection(CODES).get()).size, 1);
  assert.equal(await userGroupCount("alice"), 1);
  assert.equal(await userGroupDocCount("alice"), 1);

  const other = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-2", policy: POLICY });
  assert.notEqual(other.groupId, first.groupId, "別の要求IDなら新しく作る");
  assert.equal(await userGroupCount("alice"), 2);
});

test("作成: 前回のグループのメンバーでなくなっていたら、同じ要求IDでも前回のグループ（今の招待コード）を返さず、新しく作る", async () => {
  // レビュー #9: 停止と解除の後の状態。前回の要求IDと作ったグループの記録は利用者の文書に残るが、もうメンバーではない
  // （オーナーは bob に移り、コードは再発行済み）。ここで前回のグループを返すと、外されたグループに入り直せてしまう（要件8.8）
  await seedGroup({ groupId: "g1", ownerId: "bob", inviteCode: "SKYNEWCD", memberIds: ["bob"] });
  await db.collection("soratomoUsers").doc("alice").set({
    guidelineVersion: core.GUIDELINE_VERSION,
    groupCount: 0,
    lastCreateRequestId: "req-1",
    lastCreatedGroupId: "g1",
  });

  const result = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: POLICY });
  assert.notEqual(result.groupId, "g1", "外されたグループを返さない");
  assert.notEqual(result.inviteCode, "SKYNEWCD", "外されたグループの今の招待コードを返さない");
  assert.equal((await db.collection(GROUPS).doc("g1").collection("members").doc("alice").get()).exists, false);
  assert.equal((await db.collection(GROUPS).doc(result.groupId).get()).get("ownerId"), "alice");
  assert.equal(await userGroupCount("alice"), 1);

  // 新しく作ったグループを前回の記録として書き直すので、その後の再送は新しいグループを返す
  assert.deepEqual(await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: POLICY }), result);
});

test("作成: 同じ要求IDを同時に2回送っても、グループは1つだけ", async () => {
  await agree("alice");
  const results = await Promise.allSettled([
    store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: POLICY }),
    store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: POLICY }),
  ]);
  const t = tally(results);
  assert.deepEqual(t.other, []);
  assert.equal((await db.collection(GROUPS).get()).size, 1);
  assert.equal(await userGroupCount("alice"), 1);
  assert.equal(await userGroupDocCount("alice"), 1);
});

test("作成: 所属が9個なら作れ、10個なら user_limit で何も書かない", async () => {
  await agree("alice");
  await seedMemberships("alice", 9);
  await store.createGroupTx(db, { uid: "alice", name: "10個目", requestId: "r1", policy: POLICY });
  assert.equal(await userGroupCount("alice"), 10);
  assert.equal(await userGroupDocCount("alice"), 10);

  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: "11個目", requestId: "r2", policy: POLICY }), domainError("user_limit"));
  assert.equal(await userGroupCount("alice"), 10);
  assert.equal(await userGroupDocCount("alice"), 10);
  assert.equal((await db.collection(GROUPS).get()).size, 1);
});

test("作成: 招待コードが既存と重なれば作り直す", async () => {
  await agree("alice");
  await seedGroup({ groupId: "g-old", ownerId: "bob", inviteCode: "AAAAAAAA", memberIds: ["bob"] });
  // 先の8回は "A"（＝既存と重なる）、そのあとは "B" を返す
  const random = scriptedRandom([0, 0, 0, 0, 0, 0, 0, 0, 1]);
  const result = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r1", policy: POLICY }, { randomInt: random });
  assert.equal(result.inviteCode, "BBBBBBBB");
  assert.equal((await db.collection(CODES).doc("AAAAAAAA").get()).get("groupId"), "g-old", "既存のコードは書き換えない");
  assert.equal((await db.collection(CODES).doc("BBBBBBBB").get()).get("groupId"), result.groupId);
});

test("作成: 招待コードが5回続けて重なれば、ドメインのエラーではない失敗で終え、何も書かない", async () => {
  await agree("alice");
  await seedGroup({ groupId: "g-old", ownerId: "bob", inviteCode: "AAAAAAAA", memberIds: ["bob"] });
  const random = scriptedRandom([0]);
  await assert.rejects(
    store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r1", policy: POLICY }, { randomInt: random }),
    (err) => {
      assert.ok(!(err instanceof store.SoratomoDomainError), "想定外の失敗（internal）として扱う");
      return true;
    }
  );
  assert.equal(random.calls, 5 * core.INVITE_CODE_LENGTH, "作り直しは最大5回");
  assert.equal((await db.collection(GROUPS).get()).size, 1, "種のグループだけ");
  assert.equal(await userGroupCount("alice"), undefined, "所属数を書かない（同意の文書だけが残る）");
  assert.equal(await userGroupDocCount("alice"), 0);
});

test("作成: 要求IDが文字列でなければ、ドメインのエラーではない失敗にする", async () => {
  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "", policy: POLICY }), TypeError);
  await assert.rejects(store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: 1, policy: POLICY }), TypeError);
  assert.equal((await db.collection(GROUPS).get()).size, 0);
});

// MARK: - 参加（joinGroupTx）

test("参加: メンバーの文書・メンバー数・所属の写し・所属数が、そろって増える", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await seedMemberships("carol", 2);
  await agree("carol");

  const result = await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy: POLICY });
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

// release-gate 2.1 から、soratomoUsers の文書が無い人は同意が無いので参加できない（consent_required）。
// 「初めての利用者」は、同意だけを持ち所属数の項目が無い文書の人になった。
test("参加: 所属数の項目が無い利用者（同意だけの文書）でも、所属数1で作られる", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await agree("carol");
  await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy: POLICY });
  assert.equal(await userGroupCount("carol"), 1);
  assert.equal(await userGroupDocCount("carol"), 1);
});

test("参加: 小文字・ハイフン・全角の入力も正規化して照合する", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await agree("carol");
  const result = await store.joinGroupTx(db, { uid: "carol", code: "sky-aａaaa", policy: POLICY });
  assert.equal(result.groupId, "g1");
});

test("参加: 形が違うコードは invalid_format、無いコードは not_found", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await agree("carol");
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKY", policy: POLICY }), domainError("invalid_format"));
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKY0AAAA", policy: POLICY }), domainError("invalid_format"));
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYBBBBB", policy: POLICY }), domainError("not_found"));
  assert.equal((await groupData("g1")).memberCount, 1);
  assert.equal(await userGroupCount("carol"), undefined, "所属数を書かない（同意の文書だけが残る）");
  assert.equal(await userGroupDocCount("carol"), 0);
});

test("参加: コードの文書が残っていても、グループの今のコードでなければ not_found", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await agree("carol");
  await db.collection(CODES).doc("SKYPASTA").set({ groupId: "g1", createdAt: Timestamp.now() });
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYPASTA", policy: POLICY }), domainError("not_found"));
  assert.equal((await groupData("g1")).memberCount, 1);
});

test("参加: 19人のグループへの1人の参加は通り、20人になる", async () => {
  await seedGroup({ groupId: "g1", ownerId: "m00", inviteCode: "SKYAAAAA", memberIds: memberIds(19) });
  await agree("carol");
  await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy: POLICY });
  assert.equal((await groupData("g1")).memberCount, 20);
  assert.equal(await memberDocCount("g1"), 20);
});

test("参加: 20人のグループは group_full、所属10個の人は user_limit（両方なら user_limit が先）", async () => {
  await seedGroup({ groupId: "full", ownerId: "m00", inviteCode: "SKYFULLA", memberIds: memberIds(20) });
  await seedGroup({ groupId: "g2", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await seedMemberships("busy", 10);
  await agree("carol", "busy");

  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYFULLA", policy: POLICY }), domainError("group_full"));
  await assert.rejects(store.joinGroupTx(db, { uid: "busy", code: "SKYAAAAA", policy: POLICY }), domainError("user_limit"));
  await assert.rejects(store.joinGroupTx(db, { uid: "busy", code: "SKYFULLA", policy: POLICY }), domainError("user_limit"));

  assert.equal((await groupData("full")).memberCount, 20);
  assert.equal((await groupData("g2")).memberCount, 1);
  assert.equal(await userGroupCount("busy"), 10);
  assert.equal(await userGroupCount("carol"), undefined);
});

test("参加: 既存のメンバーの再参加は、上限とは無関係に「既存のメンバー」の印つきの成功で、何も増やさない", async () => {
  await seedGroup({ groupId: "full", ownerId: "m00", inviteCode: "SKYFULLA", memberIds: memberIds(20) });
  await seedMemberships("m05", 10);
  await agree("m05");
  const result = await store.joinGroupTx(db, { uid: "m05", code: "SKYFULLA", policy: POLICY });
  assert.deepEqual(result, { groupId: "full", alreadyMember: true });
  assert.equal((await groupData("full")).memberCount, 20);
  assert.equal(await memberDocCount("full"), 20);
  assert.equal(await userGroupCount("m05"), 10);
  assert.equal(await userGroupDocCount("m05"), 10);
});

/** 片づけ中の人（メンバーの文書は無く、所属の写しと所属数が残る）を作る。抜けるの手順1の後・退会の途中の形。 */
async function seedLeavePending(uid, groupId, { groupCount = 1 } = {}) {
  const userRef = db.collection(USERS).doc(uid);
  await userRef.set({ groupCount }, { merge: true });
  await userRef.collection("groups").doc(groupId).set({ groupId, joinedAt: Timestamp.now() });
}

test("参加（陽性対照C1・leave-group 2.1）: 片づけ中（写しが残り、メンバーの文書が無い）の人は、印の有無に関わらず leave_pending で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await agree("amy");
  await seedLeavePending("amy", "g1");

  // 印の無い形（退会の途中）と、印のある形（抜けるの途中）
  for (const withMarker of [false, true]) {
    if (withMarker) {
      await db.collection("soratomoPendingLeaves").doc("amy_g1").set({ uid: "amy", groupId: "g1", episodeId: "e1", leftAt: Timestamp.now() });
    }
    await assert.rejects(store.joinGroupTx(db, { uid: "amy", code: "SKYAAAAA", policy: POLICY }), domainError("leave_pending"), `印 ${withMarker}`);
    assert.equal((await groupData("g1")).memberCount, 1);
    assert.equal(await memberDocCount("g1"), 1);
    assert.equal(await userGroupCount("amy"), 1);
    assert.equal(await userGroupDocCount("amy"), 1);
  }
});

test("参加（leave-group 2.1）: 片づけ中で所属10個の人は、user_limit より先に leave_pending。片づけ中でないグループへは user_limit", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await seedGroup({ groupId: "g2", ownerId: "owner", inviteCode: "SKYBBBBB", memberIds: ["owner"] });
  await seedMemberships("busy", 9);
  await agree("busy");
  await seedLeavePending("busy", "g1", { groupCount: 10 }); // 片づけ中のグループも所属数に数えられたまま

  await assert.rejects(store.joinGroupTx(db, { uid: "busy", code: "SKYAAAAA", policy: POLICY }), domainError("leave_pending"));
  await assert.rejects(store.joinGroupTx(db, { uid: "busy", code: "SKYBBBBB", policy: POLICY }), domainError("user_limit"));
  assert.equal(await userGroupCount("busy"), 10);
  assert.equal(await userGroupDocCount("busy"), 10);
  assert.equal((await groupData("g1")).memberCount, 1);
});

test("同時の参加: 19人のグループへ25人が同時に参加しても、20人を超えない", async (t) => {
  await seedGroup({ groupId: "g1", ownerId: "m00", inviteCode: "SKYAAAAA", memberIds: memberIds(19) });
  const joiners = Array.from({ length: 25 }, (_, i) => `j${String(i).padStart(2, "0")}`);
  await agree(...joiners);
  const results = await Promise.allSettled(joiners.map((uid) => store.joinGroupTx(db, { uid, code: "SKYAAAAA", policy: POLICY })));
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
  await agree("dave");

  const results = await Promise.allSettled(groups.map((g) => store.joinGroupTx(db, { uid: "dave", code: g.code, policy: POLICY })));
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

// MARK: - 利用停止・同意・NGワード（release-gate 2.1）

/** グループ g1（オーナー1人・コード SKYAAAAA）が、種のまま変わっていないことを確かめる。 */
async function assertG1Untouched() {
  assert.equal((await groupData("g1")).memberCount, 1);
  assert.equal(await memberDocCount("g1"), 1);
}

test("方針: 省略・形の誤りは、検査を黙って飛ばさないよう TypeError で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await agree("alice", "carol");
  const never = () => false;
  const badPolicies = [
    undefined,
    null,
    {},
    { containsNgWord: never }, // 版が無い
    { guidelineVersion: String(core.GUIDELINE_VERSION), containsNgWord: never },
    { guidelineVersion: 1.5, containsNgWord: never },
    { guidelineVersion: 0, containsNgWord: never },
  ];
  // 作成はグループ名を検査するので、NGワードの判定も要る
  const badForCreate = [
    ...badPolicies,
    { guidelineVersion: core.GUIDELINE_VERSION },
    { guidelineVersion: core.GUIDELINE_VERSION, containsNgWord: "てすとごい" },
  ];
  for (const [i, policy] of badForCreate.entries()) {
    await assert.rejects(store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: `r${i}`, policy }), TypeError, `作成 ${i}`);
  }
  for (const [i, policy] of badPolicies.entries()) {
    await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy }), TypeError, `参加 ${i}`);
  }
  assert.equal((await db.collection(GROUPS).get()).size, 1, "種のグループだけ");
  await assertG1Untouched();
  assert.equal(await userGroupCount("alice"), undefined);
  assert.equal(await userGroupCount("carol"), undefined);

  // 参加は NGワードを検査しない（語のリストが読めなくても参加は止めない・design の API Contract）ので、版だけの方針で通る
  const joined = await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy: { guidelineVersion: core.GUIDELINE_VERSION } });
  assert.deepEqual(joined, { groupId: "g1", alreadyMember: false });
});

test("利用停止: 作成も参加も suspended で、何も書かず、停止の項目と所属数は残る", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  const suspendedAt = Timestamp.fromMillis(Date.UTC(2026, 9, 1));
  await seedMemberships("sam", 2);
  await agree("sam");
  await db.collection(USERS).doc("sam").set({ suspendedAt }, { merge: true });

  await assert.rejects(
    store.createGroupTx(db, { uid: "sam", name: "空の会", requestId: "r1", policy: POLICY }),
    domainError("suspended", null)
  );
  await assert.rejects(store.joinGroupTx(db, { uid: "sam", code: "SKYAAAAA", policy: POLICY }), domainError("suspended", null));

  assert.equal((await db.collection(GROUPS).get()).size, 1, "種のグループだけ");
  await assertG1Untouched();
  // 拒否では何も書かないので、停止の項目（suspendedAt）は消えない。所属数の merge は成功のときだけ書く
  const user = (await db.collection(USERS).doc("sam").get()).data();
  assert.equal(user.suspendedAt.toMillis(), suspendedAt.toMillis());
  assert.equal(user.groupCount, 2);
  assert.equal(user.guidelineVersion, core.GUIDELINE_VERSION);
  assert.equal(await userGroupDocCount("sam"), 2);
});

test("判定の順: 利用停止は同意より先（同意が無くても、古い版でも suspended）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  const suspendedAt = Timestamp.now();
  await db.collection(USERS).doc("sam").set({ suspendedAt });
  await db.collection(USERS).doc("old").set({ suspendedAt, guidelineVersion: core.GUIDELINE_VERSION - 1 });

  for (const uid of ["sam", "old"]) {
    await assert.rejects(
      store.createGroupTx(db, { uid, name: "空の会", requestId: "r1", policy: POLICY }),
      domainError("suspended", null),
      uid
    );
    await assert.rejects(store.joinGroupTx(db, { uid, code: "SKYAAAAA", policy: POLICY }), domainError("suspended", null), uid);
  }
  await assertG1Untouched();
});

test("同意: 文書が無い・版が無い・古い版・新しすぎる版・文字列の版は consent_required で、details に現行の版を付ける", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  const cases = {
    nodoc: null,
    noversion: { groupCount: 0 },
    old: { guidelineVersion: core.GUIDELINE_VERSION - 1 },
    newer: { guidelineVersion: core.GUIDELINE_VERSION + 1 },
    text: { guidelineVersion: String(core.GUIDELINE_VERSION) },
  };
  for (const [uid, data] of Object.entries(cases)) {
    if (data) await db.collection(USERS).doc(uid).set(data);
  }
  const details = { currentVersion: core.GUIDELINE_VERSION };
  for (const uid of Object.keys(cases)) {
    await assert.rejects(
      store.createGroupTx(db, { uid, name: "空の会", requestId: "r1", policy: POLICY }),
      domainError("consent_required", details),
      uid
    );
    await assert.rejects(
      store.joinGroupTx(db, { uid, code: "SKYAAAAA", policy: POLICY }),
      domainError("consent_required", details),
      uid
    );
    assert.equal(await userGroupDocCount(uid), 0, uid);
  }
  assert.equal((await db.collection(GROUPS).get()).size, 1, "種のグループだけ");
  await assertG1Untouched();
  assert.equal((await db.collection(USERS).doc("nodoc").get()).exists, false, "拒否では利用者の文書を作らない");

  // 現行の版は方針から取る（版を上げたら、前の版の同意は認めない・要件10.9）
  await agree("alice");
  const bumped = { guidelineVersion: core.GUIDELINE_VERSION + 1, containsNgWord: () => false };
  await assert.rejects(
    store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r1", policy: bumped }),
    domainError("consent_required", { currentVersion: core.GUIDELINE_VERSION + 1 })
  );
  await assert.rejects(
    store.joinGroupTx(db, { uid: "alice", code: "SKYAAAAA", policy: bumped }),
    domainError("consent_required", { currentVersion: core.GUIDELINE_VERSION + 1 })
  );
});

test("判定の順: 同意は、招待コードの有無と既存のメンバーより先。停止中の既存のメンバーも suspended", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner", "m01", "m02"] });
  const details = { currentVersion: core.GUIDELINE_VERSION };
  // 同意の無い人は、無いコードでも not_found より先に consent_required
  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYBBBBB", policy: POLICY }), domainError("consent_required", details));
  // 同意の無い既存のメンバーは、「既存のメンバー」の成功より先に consent_required
  await assert.rejects(store.joinGroupTx(db, { uid: "m02", code: "SKYAAAAA", policy: POLICY }), domainError("consent_required", details));
  // 停止中の既存のメンバーは suspended
  await agree("m01");
  await db.collection(USERS).doc("m01").set({ suspendedAt: Timestamp.now() }, { merge: true });
  await assert.rejects(store.joinGroupTx(db, { uid: "m01", code: "SKYAAAAA", policy: POLICY }), domainError("suspended", null));
  assert.equal((await groupData("g1")).memberCount, 3);
});

test("NGワード: グループ名に語を含めば（全角半角・ひらがなとカタカナの違いも同一視して）ng_word で、何も書かない", async () => {
  await agree("alice");
  for (const [i, name] of ["テストゴイの空", "空のてすとごい会", "ﾃｽﾄｺﾞｲ"].entries()) {
    await assert.rejects(
      store.createGroupTx(db, { uid: "alice", name, requestId: `r${i}`, policy: NG_POLICY }),
      domainError("ng_word", null),
      `名前 ${i}`
    );
  }
  assert.equal((await db.collection(GROUPS).get()).size, 0);
  assert.equal((await db.collection(CODES).get()).size, 0);
  assert.equal(await userGroupCount("alice"), undefined);
  assert.equal(await userGroupDocCount("alice"), 0);

  // 無関係の名前は、同じ方針で通る
  const created = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r9", policy: NG_POLICY });
  assert.equal((await groupData(created.groupId)).name, "空の会");
});

test("判定の順: 同じ要求IDの再送は NGワードより先、NGワードは所属数の上限より先", async () => {
  await agree("alice");
  const first = await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: POLICY });
  // 再送は、語の判定がすべてに該当しても前回のグループを返す（語のリストを変えた後の送り直しで、作れたものを失わない）
  const always = { guidelineVersion: core.GUIDELINE_VERSION, containsNgWord: () => true };
  assert.deepEqual(await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "req-1", policy: always }), first);
  assert.equal((await db.collection(GROUPS).get()).size, 1);

  // 所属10個の人の、語を含む名前は user_limit より先に ng_word
  await seedMemberships("busy", 10);
  await agree("busy");
  await assert.rejects(
    store.createGroupTx(db, { uid: "busy", name: "テストゴイの会", requestId: "r1", policy: NG_POLICY }),
    domainError("ng_word")
  );
  await assert.rejects(
    store.createGroupTx(db, { uid: "busy", name: "空の会", requestId: "r2", policy: NG_POLICY }),
    domainError("user_limit")
  );
});

test("merge: 所属数の項目が無い利用者（同意だけ）でも作成・参加で所属数1になり、同意の版と同意日時は消えない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  const agreedAt = Timestamp.fromMillis(Date.UTC(2026, 9, 8));
  for (const uid of ["alice", "carol"]) {
    await db.collection(USERS).doc(uid).set({ guidelineVersion: core.GUIDELINE_VERSION, guidelineAgreedAt: agreedAt });
  }

  await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r1", policy: POLICY });
  await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy: POLICY });

  for (const uid of ["alice", "carol"]) {
    const user = (await db.collection(USERS).doc(uid).get()).data();
    assert.equal(user.groupCount, 1, uid);
    assert.equal(user.guidelineVersion, core.GUIDELINE_VERSION, uid);
    assert.equal(user.guidelineAgreedAt.toMillis(), agreedAt.toMillis(), uid);
    assert.equal(await userGroupDocCount(uid), 1, uid);
  }
});

// MARK: - 投稿の作成（createSkyTx・release-gate 2.2）

/** 投稿の作成に渡す方針（NGワードの判定だけ。投稿は同意を確かめないので版は要らない）。 */
const SKY_POLICY = Object.freeze({ containsNgWord: () => false });

/** 投稿の作成の要求の本文（Callable soratomoCreateSky の data と同じ形）。 */
function skyInput(overrides = {}) {
  return { groupId: "g1", skyId: "sky1", caption: "夕焼けがきれい", width: 1080, height: 1440, ...overrides };
}
async function skyDoc(groupId, skyId) {
  const snap = await db.collection(GROUPS).doc(groupId).collection("skies").doc(skyId).get();
  return snap.exists ? snap.data() : null;
}
async function skyCount(groupId) {
  return (await db.collection(GROUPS).doc(groupId).collection("skies").get()).size;
}

test("投稿: メンバーなら、旧ルールと同じ5項目で作り、作成日時はサーバーの時刻にする（同意は確かめない）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  // bob は soratomoUsers の文書が無い（同意も無い）。投稿は拒否しない（決定事項14）
  const beforeMs = Date.now();
  // 要求に余分な項目（画像の URL・投稿者・作成日時）があっても、書く値に持ち込まない
  const result = await store.createSkyTx(db, {
    uid: "bob",
    input: skyInput({ imageUrl: "https://example.invalid/x.jpg", authorId: "mallory", createdAt: Timestamp.fromMillis(0) }),
    policy: SKY_POLICY,
  });
  assert.deepEqual(result, { skyId: "sky1", created: true });

  const sky = await skyDoc("g1", "sky1");
  assert.deepEqual(Object.keys(sky).sort(), ["authorId", "caption", "createdAt", "height", "width"]);
  assert.equal(sky.authorId, "bob", "投稿者は認証の uid（要求の値は使わない）");
  assert.equal(sky.caption, "夕焼けがきれい");
  assert.equal(sky.width, 1080);
  assert.equal(sky.height, 1440);
  assert.ok(sky.createdAt instanceof Timestamp);
  assert.ok(Math.abs(sky.createdAt.toMillis() - beforeMs) < 60_000, "作成日時はサーバーの時刻（要求の 0 ではない）");
  assert.equal((await db.collection(USERS).doc("bob").get()).exists, false, "利用者の文書を作らない");
});

test("投稿: キャプションが無ければ項目ごと省き（null を書かない）、null は invalid_input", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  const input = skyInput();
  delete input.caption;
  await store.createSkyTx(db, { uid: "alice", input, policy: SKY_POLICY });
  const sky = await skyDoc("g1", "sky1");
  // アプリの decodeSky は、キャプションの項目があって文字列でなければ壊れた文書として扱う
  assert.equal(Object.prototype.hasOwnProperty.call(sky, "caption"), false);
  assert.deepEqual(Object.keys(sky).sort(), ["authorId", "createdAt", "height", "width"]);

  await assert.rejects(
    store.createSkyTx(db, { uid: "alice", input: skyInput({ skyId: "sky2", caption: null }), policy: SKY_POLICY }),
    domainError("invalid_input", null)
  );
  assert.equal(await skyCount("g1"), 1);
});

test("投稿: 入力の誤りは invalid_input で、何も書かない（検査は soratomoCore.validateSkyInput）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  const bad = [
    null,
    "sky",
    skyInput({ groupId: "g_1" }),
    skyInput({ skyId: "a/b" }),
    skyInput({ width: 0 }),
    skyInput({ height: 2049 }),
    skyInput({ width: 1.5 }),
    skyInput({ height: "1440" }),
    skyInput({ caption: "" }),
    skyInput({ caption: "あ".repeat(101) }),
    skyInput({ caption: "一行目\n二行目" }),
  ];
  for (const [i, input] of bad.entries()) {
    await assert.rejects(store.createSkyTx(db, { uid: "alice", input, policy: SKY_POLICY }), domainError("invalid_input", null), `入力 ${i}`);
  }
  assert.equal(await skyCount("g1"), 0);
});

test("投稿: 非メンバーは not_member、利用停止中は suspended（停止がメンバーより先）で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  const suspendedAt = Timestamp.now();
  await db.collection(USERS).doc("bob").set({ suspendedAt, groupCount: 1 });
  await db.collection(USERS).doc("dave").set({ suspendedAt });

  await assert.rejects(store.createSkyTx(db, { uid: "carol", input: skyInput(), policy: SKY_POLICY }), domainError("not_member", null));
  await assert.rejects(store.createSkyTx(db, { uid: "bob", input: skyInput(), policy: SKY_POLICY }), domainError("suspended", null));
  // 停止中で非メンバー: 停止を先に見る
  await assert.rejects(store.createSkyTx(db, { uid: "dave", input: skyInput(), policy: SKY_POLICY }), domainError("suspended", null));
  // 無いグループへの投稿も、メンバーの文書が無いので not_member
  await assert.rejects(
    store.createSkyTx(db, { uid: "alice", input: skyInput({ groupId: "nope" }), policy: SKY_POLICY }),
    domainError("not_member", null)
  );
  assert.equal(await skyCount("g1"), 0);
  assert.equal(await skyCount("nope"), 0);
  assert.equal((await db.collection(USERS).doc("bob").get()).get("suspendedAt").toMillis(), suspendedAt.toMillis());
});

test("投稿: キャプションに語を含めば ng_word で、文書を作らない（作成のトリガーが発火せず通知も送られない）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  for (const [i, caption] of ["テストゴイな空", "ﾃｽﾄｺﾞｲ", "きょうはてすとごい"].entries()) {
    await assert.rejects(
      store.createSkyTx(db, { uid: "alice", input: skyInput({ skyId: `ng${i}`, caption }), policy: NG_POLICY }),
      domainError("ng_word", null),
      `キャプション ${i}`
    );
  }
  assert.equal(await skyCount("g1"), 0);

  // 無関係のキャプションと、キャプション無しは同じ方針で通る
  await store.createSkyTx(db, { uid: "alice", input: skyInput({ skyId: "ok1", caption: "青い空" }), policy: NG_POLICY });
  const noCaption = skyInput({ skyId: "ok2" });
  delete noCaption.caption;
  await store.createSkyTx(db, { uid: "alice", input: noCaption, policy: NG_POLICY });
  assert.equal(await skyCount("g1"), 2);
});

test("投稿: 同じ投稿IDの送り直しは created: false の成功で、文書は1件のまま（NGワードより先に見る）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  const first = await store.createSkyTx(db, { uid: "alice", input: skyInput(), policy: SKY_POLICY });
  assert.deepEqual(first, { skyId: "sky1", created: true });
  const createdAt = (await skyDoc("g1", "sky1")).createdAt.toMillis();

  assert.deepEqual(await store.createSkyTx(db, { uid: "alice", input: skyInput(), policy: SKY_POLICY }), { skyId: "sky1", created: false });
  // 語のリストを変えた後の送り直しでも、作れた投稿を失敗にしない
  const always = { containsNgWord: () => true };
  assert.deepEqual(await store.createSkyTx(db, { uid: "alice", input: skyInput(), policy: always }), { skyId: "sky1", created: false });

  assert.equal(await skyCount("g1"), 1);
  assert.equal((await skyDoc("g1", "sky1")).createdAt.toMillis(), createdAt, "書き直さない");
});

test("投稿: 同じ投稿IDを同時に2回送っても、文書は1件で、作ったのは1回だけ", async (t) => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  const results = await Promise.allSettled([
    store.createSkyTx(db, { uid: "alice", input: skyInput(), policy: SKY_POLICY }),
    store.createSkyTx(db, { uid: "alice", input: skyInput(), policy: SKY_POLICY }),
  ]);
  const r = tally(results);
  t.diagnostic(`成功=${r.ok} 競合=${r.contention}`);
  assert.deepEqual(r.other, []);
  const created = results.filter((x) => x.status === "fulfilled" && x.value.created === true).length;
  assert.equal(created, 1, "created: true は1回だけ");
  assert.equal(await skyCount("g1"), 1);
});

test("投稿: 判定の順 — メンバーでなくなった人の送り直しは、既存の文書より先に not_member", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  await store.createSkyTx(db, { uid: "bob", input: skyInput(), policy: SKY_POLICY });
  await db.collection(GROUPS).doc("g1").collection("members").doc("bob").delete();
  await assert.rejects(store.createSkyTx(db, { uid: "bob", input: skyInput(), policy: SKY_POLICY }), domainError("not_member", null));
});

test("投稿: 同じ投稿IDの文書が別の投稿者のものなら、ドメインのエラーではない失敗（internal）で、書き換えない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  await store.createSkyTx(db, { uid: "alice", input: skyInput(), policy: SKY_POLICY });
  await assert.rejects(store.createSkyTx(db, { uid: "bob", input: skyInput({ caption: "上書き" }), policy: SKY_POLICY }), (err) => {
    assert.ok(!(err instanceof store.SoratomoDomainError), "想定外の失敗（internal）として扱う");
    return true;
  });
  const sky = await skyDoc("g1", "sky1");
  assert.equal(sky.authorId, "alice");
  assert.equal(sky.caption, "夕焼けがきれい");
});

test("投稿: 方針の省略・判定が関数でないのは TypeError で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  for (const [i, policy] of [undefined, null, {}, { guidelineVersion: core.GUIDELINE_VERSION }, { containsNgWord: "てすとごい" }].entries()) {
    await assert.rejects(store.createSkyTx(db, { uid: "alice", input: skyInput(), policy }), TypeError, `方針 ${i}`);
  }
  assert.equal(await skyCount("g1"), 0);
});

// MARK: - 通報の受け付け（reportSkyTx・release-gate 2.3）

const REPORTS = "soratomoReports";

/** g1（alice がオーナー・bob と carol がメンバー）に、alice の投稿 sky1 を入れる。 */
async function seedReportScene() {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob", "carol"] });
  await db
    .collection(GROUPS)
    .doc("g1")
    .collection("skies")
    .doc("sky1")
    .set({ authorId: "alice", caption: "ひみつのキャプション", width: 1080, height: 1440, createdAt: Timestamp.now() });
}
function reportInput(overrides = {}) {
  return { groupId: "g1", skyId: "sky1", reason: "spam", ...overrides };
}
async function reportDocs() {
  return (await db.collection(REPORTS).get()).docs;
}

test("通報: メンバーの通報を記録する。項目は ID・理由・サーバーの時刻・転送の状態だけで、投稿者は投稿の文書から取る", async () => {
  await seedReportScene();
  const beforeMs = Date.now();
  // 要求に投稿者・キャプション・名前などを書いても、記録には持ち込まない（6.8・6.9）
  const result = await store.reportSkyTx(db, {
    uid: "bob",
    input: reportInput({ authorId: "mallory", caption: "偽のキャプション", groupName: "偽の名前", reporterId: "mallory" }),
  });
  const reportId = core.reportDocId("g1", "sky1", "bob");
  assert.deepEqual(result, { accepted: true, reportId, duplicate: false });

  const docs = await reportDocs();
  assert.equal(docs.length, 1);
  assert.equal(docs[0].id, reportId);
  const report = docs[0].data();
  assert.deepEqual(Object.keys(report).sort(), [
    "authorId",
    "createdAt",
    "forwardAttempts",
    "forwardStatus",
    "groupId",
    "reason",
    "reporterId",
    "skyId",
  ]);
  assert.equal(report.groupId, "g1");
  assert.equal(report.skyId, "sky1");
  assert.equal(report.authorId, "alice", "投稿者は投稿の文書から取る（要求の値は使わない）");
  assert.equal(report.reporterId, "bob", "通報者は認証の uid");
  assert.equal(report.reason, "spam");
  assert.equal(report.forwardStatus, "pending");
  assert.equal(report.forwardAttempts, 0);
  assert.ok(report.createdAt instanceof Timestamp);
  assert.ok(Math.abs(report.createdAt.toMillis() - beforeMs) < 60_000, "受け付けた時刻はサーバーの時刻");
  const text = JSON.stringify(report);
  for (const secret of ["ひみつのキャプション", "種のグループ", "SKYAAAAA", "偽の", "mallory"]) {
    assert.ok(!text.includes(secret), `記録に「${secret}」を含めない`);
  }

  // 通報された投稿者とほかのメンバーには何も送らない（通知の間引きの状態も書かない・5.9）。投稿も変えない
  assert.equal((await db.collection(GROUPS).doc("g1").collection("notifyState").get()).size, 0);
  assert.equal((await skyDoc("g1", "sky1")).caption, "ひみつのキャプション");
  assert.equal((await db.collection(USERS).get()).size, 0);
});

test("通報: 5つの理由はどれも受け付け、それ以外は invalid_reason、ID の形の誤りは invalid_input で、何も書かない", async () => {
  await seedReportScene();
  for (const [i, reason] of [undefined, null, "", "SPAM", "spam ", "abuse", 1, ["spam"]].entries()) {
    await assert.rejects(store.reportSkyTx(db, { uid: "bob", input: reportInput({ reason }) }), domainError("invalid_reason", null), `理由 ${i}`);
  }
  for (const [i, input] of [null, "sky1", reportInput({ groupId: "g_1" }), reportInput({ skyId: "a/b" }), reportInput({ skyId: undefined })].entries()) {
    await assert.rejects(store.reportSkyTx(db, { uid: "bob", input }), domainError("invalid_input", null), `入力 ${i}`);
  }
  // ID の形の誤りを、理由の誤りより先に見る
  await assert.rejects(store.reportSkyTx(db, { uid: "bob", input: reportInput({ groupId: "g_1", reason: "x" }) }), domainError("invalid_input", null));
  assert.equal((await reportDocs()).length, 0);

  // 5つの理由（iOS の ReportReason の rawValue と同じ）は、別の投稿への通報としてどれも受け付ける
  for (const [i, reason] of core.REPORT_REASONS.entries()) {
    const skyId = `s${i}`;
    await db.collection(GROUPS).doc("g1").collection("skies").doc(skyId).set({ authorId: "alice", width: 1, height: 1, createdAt: Timestamp.now() });
    await store.reportSkyTx(db, { uid: "bob", input: reportInput({ skyId, reason }) });
  }
  assert.deepEqual((await reportDocs()).map((d) => d.get("reason")).sort(), [...core.REPORT_REASONS].sort());
});

test("通報: 非メンバーは not_member、無い投稿は sky_not_found、自分の投稿は self_report で、記録を作らない", async () => {
  await seedReportScene();
  await assert.rejects(store.reportSkyTx(db, { uid: "dave", input: reportInput() }), domainError("not_member", null));
  await assert.rejects(store.reportSkyTx(db, { uid: "bob", input: reportInput({ skyId: "nope" }) }), domainError("sky_not_found", null));
  await assert.rejects(store.reportSkyTx(db, { uid: "alice", input: reportInput() }), domainError("self_report", null));
  // 無いグループは、メンバーの文書が無いので not_member
  await assert.rejects(store.reportSkyTx(db, { uid: "bob", input: reportInput({ groupId: "nope" }) }), domainError("not_member", null));
  assert.equal((await reportDocs()).length, 0);
});

test("通報: 判定の順 — メンバーでない→投稿が無い→自分の投稿→記録がある", async () => {
  await seedReportScene();
  // 非メンバーが無い投稿を通報: not_member が先
  await assert.rejects(store.reportSkyTx(db, { uid: "dave", input: reportInput({ skyId: "nope" }) }), domainError("not_member", null));
  // 通報した後に投稿が消えたら、同じ人の通報は記録があっても sky_not_found
  await store.reportSkyTx(db, { uid: "bob", input: reportInput() });
  await db.collection(GROUPS).doc("g1").collection("skies").doc("sky1").delete();
  await assert.rejects(store.reportSkyTx(db, { uid: "bob", input: reportInput() }), domainError("sky_not_found", null));
  assert.equal((await reportDocs()).length, 1, "記録は消さない");
});

test("通報: 同じ人の同じ投稿への2回目は、記録を作り直さず（転送の状態も戻さず）、受け付けと同じ結果を返す", async () => {
  await seedReportScene();
  const first = await store.reportSkyTx(db, { uid: "bob", input: reportInput() });
  const ref = db.collection(REPORTS).doc(first.reportId);
  const createdAtMs = (await ref.get()).get("createdAt").toMillis();
  // 転送が済んだ状態にしておく（2回目で pending に戻すと、二重に転送される）
  await ref.update({ forwardStatus: "sent", forwardedAt: Timestamp.now() });

  // 理由を変えた2回目も、同じ投稿なので重複として扱う
  const second = await store.reportSkyTx(db, { uid: "bob", input: reportInput({ reason: "harassment" }) });
  assert.equal(second.accepted, first.accepted);
  assert.equal(second.reportId, first.reportId, "利用者へ返す部分は同じ（6.7）");
  assert.equal(second.duplicate, true, "ログ用の印だけが違う");

  const docs = await reportDocs();
  assert.equal(docs.length, 1, "記録は1件のまま");
  const report = docs[0].data();
  assert.equal(report.forwardStatus, "sent");
  assert.equal(report.reason, "spam", "最初の理由のまま");
  assert.equal(report.createdAt.toMillis(), createdAtMs);
});

test("通報: 別の人の通報・同じ人の別の投稿への通報は、それぞれ別の記録になる", async () => {
  await seedReportScene();
  await db.collection(GROUPS).doc("g1").collection("skies").doc("sky2").set({ authorId: "alice", width: 1, height: 1, createdAt: Timestamp.now() });
  await store.reportSkyTx(db, { uid: "bob", input: reportInput() });
  await store.reportSkyTx(db, { uid: "carol", input: reportInput() });
  await store.reportSkyTx(db, { uid: "bob", input: reportInput({ skyId: "sky2" }) });
  assert.deepEqual(
    (await reportDocs()).map((d) => d.id).sort(),
    [core.reportDocId("g1", "sky1", "bob"), core.reportDocId("g1", "sky1", "carol"), core.reportDocId("g1", "sky2", "bob")].sort()
  );
});

test("通報: 同じ通報を同時に2回送っても、記録は1件で、作ったのは1回だけ", async (t) => {
  await seedReportScene();
  const results = await Promise.allSettled([
    store.reportSkyTx(db, { uid: "bob", input: reportInput() }),
    store.reportSkyTx(db, { uid: "bob", input: reportInput() }),
  ]);
  const r = tally(results);
  t.diagnostic(`成功=${r.ok} 競合=${r.contention}`);
  assert.deepEqual(r.other, []);
  const created = results.filter((x) => x.status === "fulfilled" && x.value.duplicate === false).length;
  assert.equal(created, 1);
  assert.equal((await reportDocs()).length, 1);
});

test("通報: 投稿の投稿者が壊れていたら、記録を作らずにドメインのエラーではない失敗（internal）にする", async () => {
  await seedReportScene();
  await db.collection(GROUPS).doc("g1").collection("skies").doc("broken").set({ width: 1, height: 1, createdAt: Timestamp.now() });
  await assert.rejects(store.reportSkyTx(db, { uid: "bob", input: reportInput({ skyId: "broken" }) }), (err) => {
    assert.ok(!(err instanceof store.SoratomoDomainError), "想定外の失敗（internal）として扱う");
    return true;
  });
  assert.equal((await reportDocs()).length, 0);
});

// MARK: - ガイドラインへの同意の記録（agreeGuidelineTx・release-gate 2.4）

/** 同意の記録に渡す方針（現行のガイドラインの版だけ）。 */
const AGREE_POLICY = Object.freeze({ guidelineVersion: core.GUIDELINE_VERSION });

test("同意の記録: 現行の版なら、版・サーバー時刻の同意日時・更新日時を書き、所属数などの既存の項目を壊さない", async () => {
  const userRef = db.collection(USERS).doc("alice");
  await seedMemberships("alice", 3);
  await userRef.set({ lastCreateRequestId: "req-1", lastCreatedGroupId: "g9" }, { merge: true });
  const beforeMs = Date.now();

  const result = await store.agreeGuidelineTx(db, { uid: "alice", input: { version: core.GUIDELINE_VERSION }, policy: AGREE_POLICY });
  assert.deepEqual(result, { version: core.GUIDELINE_VERSION });

  const user = (await userRef.get()).data();
  assert.equal(user.guidelineVersion, core.GUIDELINE_VERSION);
  assert.ok(user.guidelineAgreedAt instanceof Timestamp);
  assert.ok(Math.abs(user.guidelineAgreedAt.toMillis() - beforeMs) < 60_000, "同意日時はサーバーの時刻");
  assert.ok(user.updatedAt instanceof Timestamp);
  assert.equal(user.groupCount, 3, "所属数を残す");
  assert.equal(user.lastCreateRequestId, "req-1");
  assert.equal(user.lastCreatedGroupId, "g9");
  assert.equal(await userGroupDocCount("alice"), 3, "所属の写しを残す");

  // 記録した後は、作成と参加が通る
  await store.createGroupTx(db, { uid: "alice", name: "空の会", requestId: "r1", policy: POLICY });
});

test("同意の記録: 文書の無い人（初めての人）も記録でき、作成・参加の同意として効く", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await store.agreeGuidelineTx(db, { uid: "carol", input: { version: core.GUIDELINE_VERSION }, policy: AGREE_POLICY });
  const user = (await db.collection(USERS).doc("carol").get()).data();
  assert.equal(user.guidelineVersion, core.GUIDELINE_VERSION);
  assert.equal(user.groupCount, undefined, "所属数は書かない");
  assert.deepEqual(await store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy: POLICY }), { groupId: "g1", alreadyMember: false });
});

test("同意の記録: 古い版・新しすぎる版は outdated_guideline（details に現行の版）で、何も書かない", async () => {
  await seedMemberships("alice", 2);
  const details = { currentVersion: core.GUIDELINE_VERSION };
  for (const version of [core.GUIDELINE_VERSION - 1, core.GUIDELINE_VERSION + 1]) {
    await assert.rejects(
      store.agreeGuidelineTx(db, { uid: "alice", input: { version }, policy: AGREE_POLICY }),
      domainError("outdated_guideline", details),
      `版 ${version}`
    );
    await assert.rejects(
      store.agreeGuidelineTx(db, { uid: "nodoc", input: { version }, policy: AGREE_POLICY }),
      domainError("outdated_guideline", details),
      `版 ${version}`
    );
  }
  const user = (await db.collection(USERS).doc("alice").get()).data();
  assert.equal(user.guidelineVersion, undefined, "古い版を現行の版として記録しない");
  assert.equal(user.guidelineAgreedAt, undefined);
  assert.equal(user.groupCount, 2);
  assert.equal((await db.collection(USERS).doc("nodoc").get()).exists, false, "拒否では文書を作らない");

  // 版を上げたら、前の版での同意の要求は outdated（記録済みの前の版も書き換えない）
  await agree("bob");
  const bumped = { guidelineVersion: core.GUIDELINE_VERSION + 1 };
  await assert.rejects(
    store.agreeGuidelineTx(db, { uid: "bob", input: { version: core.GUIDELINE_VERSION }, policy: bumped }),
    domainError("outdated_guideline", { currentVersion: core.GUIDELINE_VERSION + 1 })
  );
  assert.equal((await db.collection(USERS).doc("bob").get()).get("guidelineVersion"), core.GUIDELINE_VERSION);
});

test("同意の記録: 版が整数でない（文字列・小数・無い・null）・本文が無いのは invalid_input で、何も書かない", async () => {
  const inputs = [
    { version: String(core.GUIDELINE_VERSION) },
    { version: core.GUIDELINE_VERSION + 0.5 },
    { version: null },
    {},
    null,
    "1",
    [core.GUIDELINE_VERSION],
  ];
  for (const [i, input] of inputs.entries()) {
    await assert.rejects(store.agreeGuidelineTx(db, { uid: "alice", input, policy: AGREE_POLICY }), domainError("invalid_input", null), `入力 ${i}`);
  }
  assert.equal((await db.collection(USERS).get()).size, 0);
});

test("同意の記録: 書くのは認証の uid の文書だけ（要求に uid を書いても、ほかの人の文書には書かない）", async () => {
  await store.agreeGuidelineTx(db, {
    uid: "alice",
    input: { version: core.GUIDELINE_VERSION, uid: "mallory", guidelineVersion: 99, groupCount: 10 },
    policy: AGREE_POLICY,
  });
  assert.equal((await db.collection(USERS).doc("mallory").get()).exists, false);
  const user = (await db.collection(USERS).doc("alice").get()).data();
  assert.deepEqual(Object.keys(user).sort(), ["guidelineAgreedAt", "guidelineVersion", "updatedAt"], "要求のほかの項目を持ち込まない");
  assert.equal(user.guidelineVersion, core.GUIDELINE_VERSION);
});

test("同意の記録: 方針の省略・版が整数でない方針は TypeError で、何も書かない", async () => {
  for (const [i, policy] of [undefined, null, {}, { guidelineVersion: "1" }, { guidelineVersion: 0 }].entries()) {
    await assert.rejects(
      store.agreeGuidelineTx(db, { uid: "alice", input: { version: core.GUIDELINE_VERSION }, policy }),
      TypeError,
      `方針 ${i}`
    );
  }
  assert.equal((await db.collection(USERS).get()).size, 0);
});

// MARK: - 再発行（regenerateInviteCodeTx）

test("再発行: オーナーなら新しいコードに替わり、古いコードでの参加は not_found、新しいコードでは参加できる", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner", "m01"] });
  await agree("carol");

  const { inviteCode } = await store.regenerateInviteCodeTx(db, { uid: "owner", groupId: "g1" });
  assert.notEqual(inviteCode, "SKYAAAAA");
  assert.equal(core.normalizeInviteCode(inviteCode), inviteCode);
  assert.equal((await groupData("g1")).inviteCode, inviteCode);
  assert.equal((await db.collection(CODES).doc("SKYAAAAA").get()).exists, false, "古いコードの文書を消す");
  assert.equal((await db.collection(CODES).doc(inviteCode).get()).get("groupId"), "g1");

  await assert.rejects(store.joinGroupTx(db, { uid: "carol", code: "SKYAAAAA", policy: POLICY }), domainError("not_found"));
  const joined = await store.joinGroupTx(db, { uid: "carol", code: inviteCode, policy: POLICY });
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

// MARK: - リアクション（setReactionTx・soratomo-reactions 2.2）

/** 種のリアクションの時刻（サーバーの時刻と見分けるため、過去の決まった時刻にする）。 */
const REACTION_AT0 = Timestamp.fromMillis(Date.UTC(2026, 9, 1, 0, 0, 0));
const SKY_CREATED_AT = Timestamp.fromMillis(Date.UTC(2026, 9, 1, 9, 0, 0));

function skyRefOf(groupId, skyId) {
  return db.collection(GROUPS).doc(groupId).collection("skies").doc(skyId);
}

/**
 * 投稿の文書を、データモデルの形で直接入れる（トランザクションを通さない）。
 * reactions・reactorIds を渡さなければ、その項目を持たない（リアクションが1つも無い投稿）。
 */
async function seedReactionSky(groupId, skyId, { authorId, reactions, reactorIds } = {}) {
  const sky = { authorId, caption: "夕焼けがきれい", width: 1080, height: 1440, createdAt: SKY_CREATED_AT };
  if (reactions !== undefined) sky.reactions = reactions;
  if (reactorIds !== undefined) sky.reactorIds = reactorIds;
  await skyRefOf(groupId, skyId).set(sky);
}

/** g1（alice がオーナー・bob と carol がメンバー）に、alice の投稿 sky1 を入れる。carol のリアクション（虹）が付いている。 */
async function seedReactionScene() {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob", "carol"] });
  await seedReactionSky("g1", "sky1", {
    authorId: "alice",
    reactions: { carol: { kind: "rainbow", at: REACTION_AT0 } },
    reactorIds: ["carol"],
  });
}

/** Callable soratomoSetReaction の data と同じ形の要求の本文。 */
function reactionInput(overrides = {}) {
  return { groupId: "g1", skyId: "sky1", kind: "sunset", ...overrides };
}

/** I1: reactions の鍵の集合と reactorIds が等しい（design.md の Domain Model）。 */
function assertReactionInvariant(sky, label) {
  const keys = Object.keys(sky.reactions || {}).sort();
  assert.deepEqual([...(sky.reactorIds || [])].sort(), keys, `${label}: reactions の鍵と reactorIds が等しい（I1）`);
}

/** carol の種のリアクション（虹・REACTION_AT0）が、そのまま残っていることを確かめる。 */
function assertCarolKept(sky, label) {
  assert.ok(sky.reactions && sky.reactions.carol, `${label}: carol のリアクションが残る`);
  assert.equal(sky.reactions.carol.kind, "rainbow", `${label}: carol の絵文字が変わらない`);
  assert.equal(sky.reactions.carol.at.toMillis(), REACTION_AT0.toMillis(), `${label}: carol の時刻が変わらない`);
  assert.ok(sky.reactorIds.includes("carol"), `${label}: carol が reactorIds に残る`);
}

/** エミュレーターの競合（ABORTED か、競合で返す INVALID_ARGUMENT の「Transaction is invalid or closed」）か（要確認3と同じ判定）。 */
function isTxContention(error) {
  return Boolean(error) && (error.code === 10 || (error.code === 3 && /Transaction is invalid or closed/.test(error.message)));
}

test("リアクション: 付ける→added・選び直す→replaced・同じもの→unchanged・外す→removed・無いものを外す→unchanged（I1・ほかの項目とグループの文書は書かない）", async () => {
  await seedReactionScene();
  const groupBefore = await db.collection(GROUPS).doc("g1").get();
  const beforeMs = Date.now();

  assert.deepEqual(await store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind: "sunset" }) }), {
    outcome: "added",
    kind: "sunset",
    authorId: "alice",
  });
  let sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.deepEqual(Object.keys(sky.reactions.bob).sort(), ["at", "kind"]);
  assert.equal(sky.reactions.bob.kind, "sunset");
  assert.ok(sky.reactions.bob.at instanceof Timestamp, "付けた時刻は Firestore の時刻");
  assert.ok(Math.abs(sky.reactions.bob.at.toMillis() - beforeMs) < 60_000, "付けた時刻はサーバーの時刻");
  assertReactionInvariant(sky, "added");

  assert.deepEqual(await store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind: "cloud" }) }), {
    outcome: "replaced",
    kind: "cloud",
    authorId: "alice",
  });
  sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.equal(sky.reactions.bob.kind, "cloud");
  assertReactionInvariant(sky, "replaced");

  const beforeSame = await skyRefOf("g1", "sky1").get();
  assert.deepEqual(await store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind: "cloud" }) }), {
    outcome: "unchanged",
    kind: "cloud",
    authorId: "alice",
  });
  assert.ok((await skyRefOf("g1", "sky1").get()).updateTime.isEqual(beforeSame.updateTime), "同じものを付ける要求は書かない");

  assert.deepEqual(await store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind: null }) }), {
    outcome: "removed",
    kind: null,
    authorId: "alice",
  });
  sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.equal(Object.prototype.hasOwnProperty.call(sky.reactions, "bob"), false, "外すと本人のキーが消える");
  assert.deepEqual(sky.reactorIds, ["carol"]);
  assertReactionInvariant(sky, "removed");

  const beforeNone = await skyRefOf("g1", "sky1").get();
  assert.deepEqual(await store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind: null }) }), {
    outcome: "unchanged",
    kind: null,
    authorId: "alice",
  });
  assert.ok((await skyRefOf("g1", "sky1").get()).updateTime.isEqual(beforeNone.updateTime), "付いていないものを外す要求は書かない");

  // 投稿のリアクション以外の項目と、グループの文書（lastActivityAt を含む）は変わらない（12.7）
  sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.deepEqual(Object.keys(sky).sort(), ["authorId", "caption", "createdAt", "height", "reactions", "reactorIds", "width"]);
  assert.equal(sky.authorId, "alice");
  assert.equal(sky.caption, "夕焼けがきれい");
  assert.equal(sky.width, 1080);
  assert.equal(sky.height, 1440);
  assert.equal(sky.createdAt.toMillis(), SKY_CREATED_AT.toMillis());
  assertCarolKept(sky, "最後");
  const groupAfter = await db.collection(GROUPS).doc("g1").get();
  assert.ok(groupAfter.updateTime.isEqual(groupBefore.updateTime), "グループの文書を書かない");
  assert.equal(groupAfter.get("lastActivityAt").toMillis(), groupBefore.get("lastActivityAt").toMillis());
});

test("リアクション: ほかの人のリアクションは残る（付ける・選び直す・外すのどれでも）", async () => {
  await seedReactionScene();
  for (const kind of ["eyes", "sparkles", null]) {
    await store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind }) });
    const sky = (await skyRefOf("g1", "sky1").get()).data();
    assertCarolKept(sky, String(kind));
    assertReactionInvariant(sky, String(kind));
  }
});

test("リアクション: uid に「.」を含む人のキーでも、ほかの人のキー（前半が同じ uid）に触れない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "a", "a.b"] });
  await seedReactionSky("g1", "sky1", { authorId: "alice", reactions: { a: { kind: "eyes", at: REACTION_AT0 } }, reactorIds: ["a"] });
  const assertAKept = (sky, label) => {
    assert.deepEqual(Object.keys(sky.reactions.a).sort(), ["at", "kind"], `${label}: a のリアクションの中に入り込まない`);
    assert.equal(sky.reactions.a.kind, "eyes", label);
    assert.equal(sky.reactions.a.at.toMillis(), REACTION_AT0.toMillis(), label);
  };

  assert.equal((await store.setReactionTx(db, { uid: "a.b", input: reactionInput({ kind: "sunset" }) })).outcome, "added");
  let sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.deepEqual(Object.keys(sky.reactions).sort(), ["a", "a.b"]);
  assert.equal(sky.reactions["a.b"].kind, "sunset");
  assertAKept(sky, "added");
  assertReactionInvariant(sky, "added");

  assert.equal((await store.setReactionTx(db, { uid: "a.b", input: reactionInput({ kind: "cloud" }) })).outcome, "replaced");
  sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.equal(sky.reactions["a.b"].kind, "cloud");
  assertAKept(sky, "replaced");

  assert.equal((await store.setReactionTx(db, { uid: "a.b", input: reactionInput({ kind: null }) })).outcome, "removed");
  sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.deepEqual(Object.keys(sky.reactions), ["a"]);
  assert.deepEqual(sky.reactorIds, ["a"]);
  assertAKept(sky, "removed");
});

test("リアクション: 今の値が壊れている（物でない・知らない名前）ときは「付いている」とみなし、付けると replaced・外すと removed", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  // 壊れた値と同じ名前（"sunset" という文字列）を付ける要求も、unchanged にせず正しい形に書き直す
  const brokenValues = ["sunset", 3, null, { kind: "star" }, { kind: "Sunset" }, { at: REACTION_AT0 }, ["sunset"]];
  for (const [i, broken] of brokenValues.entries()) {
    await seedReactionSky("g1", `add${i}`, { authorId: "alice", reactions: { bob: broken }, reactorIds: ["bob"] });
    await seedReactionSky("g1", `del${i}`, { authorId: "alice", reactions: { bob: broken }, reactorIds: ["bob"] });
  }
  for (const [i, broken] of brokenValues.entries()) {
    const label = JSON.stringify(broken);
    const added = await store.setReactionTx(db, { uid: "bob", input: reactionInput({ skyId: `add${i}`, kind: "sunset" }) });
    assert.deepEqual(added, { outcome: "replaced", kind: "sunset", authorId: "alice" }, `付ける ${label}`);
    const addSky = (await skyRefOf("g1", `add${i}`).get()).data();
    assert.equal(addSky.reactions.bob.kind, "sunset", `付ける ${label}`);
    assert.ok(addSky.reactions.bob.at instanceof Timestamp, `付ける ${label}`);
    assertReactionInvariant(addSky, `付ける ${label}`);

    const removed = await store.setReactionTx(db, { uid: "bob", input: reactionInput({ skyId: `del${i}`, kind: null }) });
    assert.deepEqual(removed, { outcome: "removed", kind: null, authorId: "alice" }, `外す ${label}`);
    const delSky = (await skyRefOf("g1", `del${i}`).get()).data();
    assert.deepEqual(delSky.reactions, {}, `外す ${label}`);
    assert.deepEqual(delSky.reactorIds, [], `外す ${label}`);
  }
});

test("リアクション: 入力の誤りは invalid_input、7つの名前でない絵文字は invalid_reaction で、何も書かない", async () => {
  await seedReactionScene();
  const skyBefore = await skyRefOf("g1", "sky1").get();
  const badInputs = [
    null,
    undefined,
    "sky1",
    3,
    ["g1", "sky1", "sunset"],
    {},
    { skyId: "sky1", kind: "sunset" },
    { groupId: "g1", kind: "sunset" },
    { groupId: "g1", skyId: "sky1" }, // kind の鍵が無い（外すときは kind: null を送る契約・要確認Q3）
    reactionInput({ groupId: "g_1" }),
    reactionInput({ skyId: "a/b" }),
    reactionInput({ groupId: "" }),
    reactionInput({ skyId: 1 }),
  ];
  for (const [i, input] of badInputs.entries()) {
    await assert.rejects(store.setReactionTx(db, { uid: "bob", input }), domainError("invalid_input", null), `入力 ${i}`);
  }
  const badKinds = [
    String.fromCodePoint(0x2601, 0xfe0f), // ☁️（絵文字そのもの）
    String.fromCodePoint(0x2601), // FE0F の無い ☁
    String.fromCodePoint(0x1f305), // 🌅
    "star",
    "Sunset",
    " sunset",
    "",
    0,
    false,
    {},
    ["sunset"],
    { kind: "sunset" },
  ];
  for (const [i, kind] of badKinds.entries()) {
    await assert.rejects(store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind }) }), domainError("invalid_reaction", null), `絵文字 ${i}`);
  }
  assert.ok((await skyRefOf("g1", "sky1").get()).updateTime.isEqual(skyBefore.updateTime), "投稿を書かない");
});

test("リアクション: 非メンバーは not_member、無い投稿は sky_not_found、自分の投稿は self_reaction（外す要求も）、利用停止中は suspended で、何も書かない", async () => {
  await seedReactionScene();
  const suspendedAt = Timestamp.now();
  // carol はメンバーで、リアクションが付いているが、利用停止中（停止の日時を書いてから外し終えるまでの間・4.11）
  await db.collection(USERS).doc("carol").set({ suspendedAt, groupCount: 1 });
  const skyBefore = await skyRefOf("g1", "sky1").get();

  for (const kind of ["sunset", null]) {
    await assert.rejects(store.setReactionTx(db, { uid: "dave", input: reactionInput({ kind }) }), domainError("not_member", null), `非メンバー ${kind}`);
    await assert.rejects(
      store.setReactionTx(db, { uid: "bob", input: reactionInput({ groupId: "nope", kind }) }),
      domainError("not_member", null),
      `無いグループ ${kind}`
    );
    await assert.rejects(
      store.setReactionTx(db, { uid: "bob", input: reactionInput({ skyId: "nope", kind }) }),
      domainError("sky_not_found", null),
      `無い投稿 ${kind}`
    );
    await assert.rejects(store.setReactionTx(db, { uid: "alice", input: reactionInput({ kind }) }), domainError("self_reaction", null), `自分の投稿 ${kind}`);
    await assert.rejects(store.setReactionTx(db, { uid: "carol", input: reactionInput({ kind }) }), domainError("suspended", null), `利用停止 ${kind}`);
  }

  assert.ok((await skyRefOf("g1", "sky1").get()).updateTime.isEqual(skyBefore.updateTime), "投稿を書かない");
  assert.equal((await skyRefOf("g1", "nope").get()).exists, false, "無い投稿を作らない");
  assert.equal((await skyRefOf("nope", "sky1").get()).exists, false, "無いグループの投稿を作らない");
  assert.equal((await db.collection(USERS).doc("carol").get()).get("suspendedAt").toMillis(), suspendedAt.toMillis());
});

test("リアクション: 判定の順 — invalid_input → invalid_reaction → suspended → not_member → sky_not_found → self_reaction", async () => {
  await seedReactionScene();
  await db.collection(USERS).doc("dave").set({ suspendedAt: Timestamp.now() }); // dave は停止中で、メンバーでない
  await db.collection(USERS).doc("alice").set({ suspendedAt: Timestamp.now() }); // 投稿者 alice も停止中

  // ID の形と絵文字の両方が誤り → invalid_input
  await assert.rejects(store.setReactionTx(db, { uid: "bob", input: reactionInput({ groupId: "g_1", kind: "star" }) }), domainError("invalid_input", null));
  // 絵文字の誤りで、停止中・非メンバー → invalid_reaction（トランザクションの前に断る）
  await assert.rejects(store.setReactionTx(db, { uid: "dave", input: reactionInput({ kind: "star" }) }), domainError("invalid_reaction", null));
  // 停止中で非メンバー → suspended
  await assert.rejects(store.setReactionTx(db, { uid: "dave", input: reactionInput() }), domainError("suspended", null));
  // 非メンバーで、無い投稿 → not_member
  await assert.rejects(store.setReactionTx(db, { uid: "eve", input: reactionInput({ skyId: "nope" }) }), domainError("not_member", null));
  // 停止中の投稿者が自分の投稿に → suspended（self_reaction より先）
  await assert.rejects(store.setReactionTx(db, { uid: "alice", input: reactionInput() }), domainError("suspended", null));
});

test("リアクション: ガイドラインに未同意・古い版の人も付けられ、投稿者にブロックされた人も付けられる（同意とブロックの一覧を読まない）", async () => {
  await seedReactionScene();
  // bob は soratomoUsers の文書が無い（同意が無い）。carol は古い版に同意している
  await db.collection(USERS).doc("carol").set({ guidelineVersion: core.GUIDELINE_VERSION - 1, groupCount: 1 });
  // 投稿者 alice は bob と carol をブロックしている（ルートの users/{uid}.blockedUserIds）
  await db.collection("users").doc("alice").set({ blockedUserIds: ["bob", "carol"] });
  const aliceUserBefore = await db.collection("users").doc("alice").get();

  assert.equal((await store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind: "sunset" }) })).outcome, "added");
  assert.equal((await store.setReactionTx(db, { uid: "carol", input: reactionInput({ kind: "cloud" }) })).outcome, "replaced");
  const sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.equal(sky.reactions.bob.kind, "sunset");
  assert.equal(sky.reactions.carol.kind, "cloud");
  assertReactionInvariant(sky, "未同意とブロック");

  assert.equal((await db.collection(USERS).doc("bob").get()).exists, false, "利用者の文書を作らない");
  assert.equal((await db.collection(USERS).doc("carol").get()).get("guidelineVersion"), core.GUIDELINE_VERSION - 1, "同意の版を書き換えない");
  assert.ok((await db.collection("users").doc("alice").get()).updateTime.isEqual(aliceUserBefore.updateTime), "投稿者の users を書かない");
});

test("リアクション（同時実行）: 同じ人が違う絵文字で20回並べても、本人のリアクションは1件で、絵文字は通った要求のどれか", async (t) => {
  await seedReactionScene();
  const kinds = Array.from({ length: 20 }, (_, i) => core.REACTION_KINDS[i % core.REACTION_KINDS.length].name);
  const results = await Promise.allSettled(kinds.map((kind) => store.setReactionTx(db, { uid: "bob", input: reactionInput({ kind }) })));
  const fulfilled = results.filter((r) => r.status === "fulfilled").map((r) => r.value);
  const contention = results.filter((r) => r.status === "rejected" && isTxContention(r.reason)).length;
  const unexpected = results
    .filter((r) => r.status === "rejected" && !isTxContention(r.reason))
    .map((r) => `${r.reason && r.reason.code} ${r.reason && r.reason.message}`);
  const outcomes = {};
  for (const v of fulfilled) outcomes[v.outcome] = (outcomes[v.outcome] || 0) + 1;
  t.diagnostic(`成功=${fulfilled.length} 競合=${contention} 内訳=${JSON.stringify(outcomes)}`);

  assert.deepEqual(unexpected, [], "想定外の失敗が無い");
  assert.ok(fulfilled.length >= 1, "少なくとも1回は通る");
  assert.ok((outcomes.added || 0) <= 1, "added は多くても1回（同じ人の要求は直列になる）");
  const sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.deepEqual(Object.keys(sky.reactions).sort(), ["bob", "carol"], "本人のリアクションは1件");
  assert.deepEqual([...sky.reactorIds].sort(), ["bob", "carol"]);
  assert.ok(
    fulfilled.map((v) => v.kind).includes(sky.reactions.bob.kind),
    `残った絵文字（${sky.reactions.bob.kind}）は、通った要求のどれか`
  );
  assertCarolKept(sky, "同時実行");
});

test("リアクション（同時実行）: 19人が同時に付けても19件で、絵文字ごとの数が実際に付けた人の数と一致する", async (t) => {
  const members = memberIds(20);
  const reactors = members.slice(1);
  await seedGroup({ groupId: "g1", ownerId: "m00", inviteCode: "SKYAAAAA", memberIds: members });
  await seedReactionSky("g1", "sky1", { authorId: "m00" }); // まだ reactions も reactorIds も無い投稿
  const kindOf = (i) => core.REACTION_KINDS[i % core.REACTION_KINDS.length].name;

  const first = await Promise.allSettled(reactors.map((uid, i) => store.setReactionTx(db, { uid, input: reactionInput({ kind: kindOf(i) }) })));
  const retry = [];
  const unexpected = [];
  for (const [i, r] of first.entries()) {
    if (r.status === "fulfilled") {
      assert.equal(r.value.outcome, "added", `${reactors[i]} の1回目`);
    } else if (isTxContention(r.reason)) {
      retry.push(i);
    } else {
      unexpected.push(`${reactors[i]}: ${r.reason && r.reason.code} ${r.reason && r.reason.message}`);
    }
  }
  assert.deepEqual(unexpected, [], "想定外の失敗が無い");

  // 通った要求は、送り直しの前にすべて残っている（失われた更新が無い）
  const mid = (await skyRefOf("g1", "sky1").get()).data();
  for (const [i, r] of first.entries()) {
    if (r.status === "fulfilled") assert.equal(mid.reactions[reactors[i]].kind, kindOf(i), `${reactors[i]} の付けたものが残る`);
  }
  // 競合で失敗した人は送り直す（本番なら Callable の失敗＝アプリの再試行に当たる）
  for (const i of retry) {
    const out = await store.setReactionTx(db, { uid: reactors[i], input: reactionInput({ kind: kindOf(i) }) });
    assert.ok(["added", "unchanged"].includes(out.outcome), `${reactors[i]} の送り直し: ${out.outcome}`);
  }
  t.diagnostic(`1回目の成功=${reactors.length - retry.length} 競合で送り直し=${retry.length}`);

  const sky = (await skyRefOf("g1", "sky1").get()).data();
  assert.equal(Object.keys(sky.reactions).length, 19);
  assertReactionInvariant(sky, "19人");
  const counts = {};
  for (const entry of Object.values(sky.reactions)) counts[entry.kind] = (counts[entry.kind] || 0) + 1;
  const expected = {};
  reactors.forEach((_, i) => {
    expected[kindOf(i)] = (expected[kindOf(i)] || 0) + 1;
  });
  assert.deepEqual(counts, expected, "絵文字ごとの数が、実際に付けた人の数と一致する");
});

// MARK: - リアクションの通知の枠（claimReactionNotifySlot・soratomo-reactions 2.3）

async function reactionNotifyStateOf(groupId, authorId) {
  const snap = await db.collection(GROUPS).doc(groupId).collection("reactionNotifyState").doc(authorId).get();
  return snap.exists ? snap.data() : null;
}
async function reactionNoticeOf(groupId, skyId) {
  const snap = await db.collection(GROUPS).doc(groupId).collection("reactionNotices").doc(skyId).get();
  return snap.exists ? snap.data() : null;
}

/** g1 の alice の投稿 sky1 に、bob が T0 に付けた場面の確保（overrides で変える）。 */
function claimReaction(overrides = {}) {
  return store.claimReactionNotifySlot(db, { groupId: "g1", skyId: "sky1", authorId: "alice", reactorUid: "bob", nowMs: T0, ...overrides });
}

test("リアクションの通知の枠: 初回は send。送る前に、投稿者の最後の時刻と、印に付けた人を書く", async () => {
  await seedReactionSky("g1", "sky1", { authorId: "alice" });
  assert.equal(await claimReaction(), "send");
  const state = await reactionNotifyStateOf("g1", "alice");
  assert.deepEqual(Object.keys(state), ["lastSentAt"]);
  assert.ok(state.lastSentAt instanceof Timestamp, "最後の時刻は Firestore の時刻で書く");
  assert.equal(state.lastSentAt.toMillis(), T0);
  assert.deepEqual(await reactionNoticeOf("g1", "sky1"), { notifiedReactorIds: ["bob"] });
});

test("リアクションの通知の枠: send の直後の別の人は throttled（5分ちょうどを含む）・5分を過ぎれば send。間引かれた付け方は印を残さない", async () => {
  await seedReactionSky("g1", "sky1", { authorId: "alice" });
  assert.equal(await claimReaction(), "send");

  assert.equal(await claimReaction({ reactorUid: "carol", nowMs: T0 + 1_000 }), "throttled");
  assert.equal(await claimReaction({ reactorUid: "carol", nowMs: T0 + core.THROTTLE_MS }), "throttled");
  assert.deepEqual(await reactionNoticeOf("g1", "sky1"), { notifiedReactorIds: ["bob"] }, "間引かれた人は印に入らない");
  assert.equal((await reactionNotifyStateOf("g1", "alice")).lastSentAt.toMillis(), T0, "送らないときは最後の時刻を書かない");

  // 印に入っていないので、5分を過ぎて付け直せば届く
  assert.equal(await claimReaction({ reactorUid: "carol", nowMs: T0 + core.THROTTLE_MS + 1 }), "send");
  assert.deepEqual([...(await reactionNoticeOf("g1", "sky1")).notifiedReactorIds].sort(), ["bob", "carol"]);
  assert.equal((await reactionNotifyStateOf("g1", "alice")).lastSentAt.toMillis(), T0 + core.THROTTLE_MS + 1);
});

test("リアクションの通知の枠: 同じ付けた人の同じ投稿は、5分を過ぎても（何時間後でも）duplicate。別の投稿なら1通目として数える", async () => {
  await seedReactionSky("g1", "sky1", { authorId: "alice" });
  await seedReactionSky("g1", "sky2", { authorId: "alice" });
  assert.equal(await claimReaction(), "send");

  assert.equal(await claimReaction({ nowMs: T0 + core.THROTTLE_MS + 1 }), "duplicate");
  assert.equal(await claimReaction({ nowMs: T0 + 24 * 60 * 60 * 1000 }), "duplicate");
  assert.equal((await reactionNotifyStateOf("g1", "alice")).lastSentAt.toMillis(), T0, "重複のときは最後の時刻を書かない");
  assert.deepEqual(await reactionNoticeOf("g1", "sky1"), { notifiedReactorIds: ["bob"] });

  // 印は投稿ごと。同じ bob でも、alice の別の投稿 sky2 なら（5分を過ぎていれば）送る
  assert.equal(await claimReaction({ skyId: "sky2", nowMs: T0 + core.THROTTLE_MS + 1 }), "send");
  assert.deepEqual(await reactionNoticeOf("g1", "sky2"), { notifiedReactorIds: ["bob"] });
});

test("リアクションの通知の枠: 別の投稿者・別のグループは別に数える", async () => {
  await seedReactionSky("g1", "sky1", { authorId: "alice" });
  await seedReactionSky("g1", "sky3", { authorId: "dave" });
  await seedReactionSky("g2", "sky4", { authorId: "alice" });
  assert.equal(await claimReaction(), "send");
  assert.equal(await claimReaction({ skyId: "sky3", authorId: "dave", nowMs: T0 + 1_000 }), "send", "別の投稿者");
  assert.equal(await claimReaction({ groupId: "g2", skyId: "sky4", nowMs: T0 + 2_000 }), "send", "別のグループの同じ投稿者");
  assert.equal((await reactionNotifyStateOf("g1", "dave")).lastSentAt.toMillis(), T0 + 1_000);
  assert.equal((await reactionNotifyStateOf("g2", "alice")).lastSentAt.toMillis(), T0 + 2_000);
  assert.equal((await reactionNotifyStateOf("g1", "alice")).lastSentAt.toMillis(), T0);
});

test("リアクションの通知の枠: 投稿が無ければ sky_gone で、何も書かない（記録が残っていても）", async () => {
  await seedReactionSky("g1", "sky1", { authorId: "alice" });
  assert.equal(await claimReaction({ skyId: "nope" }), "sky_gone");
  assert.equal(await reactionNotifyStateOf("g1", "alice"), null, "最後の時刻を書かない");
  assert.equal(await reactionNoticeOf("g1", "nope"), null, "印を作らない");

  // 記録があって5分を過ぎていても、投稿が無ければ送らない
  assert.equal(await claimReaction(), "send");
  await skyRefOf("g1", "sky1").delete();
  assert.equal(await claimReaction({ reactorUid: "carol", nowMs: T0 + core.THROTTLE_MS + 1 }), "sky_gone");
  assert.equal((await reactionNotifyStateOf("g1", "alice")).lastSentAt.toMillis(), T0);
  assert.deepEqual(await reactionNoticeOf("g1", "sky1"), { notifiedReactorIds: ["bob"] });
});

test("リアクションの通知の枠（同時実行）: 同じ投稿者へ2人がほぼ同時に付けても、送るのは1通だけ。同じ人の2回も1通だけ", async (t) => {
  await seedReactionSky("g1", "sky1", { authorId: "alice" });
  await seedReactionSky("g1", "sky2", { authorId: "alice" });
  const summarize = (results) => {
    const decisions = results.filter((r) => r.status === "fulfilled").map((r) => r.value);
    const contention = results.filter((r) => r.status === "rejected" && isTxContention(r.reason)).length;
    const unexpected = results.filter((r) => r.status === "rejected" && !isTxContention(r.reason)).map((r) => String(r.reason && r.reason.message));
    return { decisions, contention, unexpected };
  };

  const two = summarize(await Promise.allSettled([claimReaction(), claimReaction({ reactorUid: "carol", nowMs: T0 + 10 })]));
  t.diagnostic(`2人: ${JSON.stringify(two)}`);
  assert.deepEqual(two.unexpected, []);
  assert.equal(two.decisions.filter((d) => d === "send").length, 1, "2人のうち送るのは1通");
  assert.equal((await reactionNoticeOf("g1", "sky1")).notifiedReactorIds.length, 1);

  // 同じ人の同じ投稿への2回（別の投稿 sky2）: 1通だけ。前半でどちらが送っても（最後の時刻が T0 でも T0+10 でも）
  // 間引きに入らないよう、10分後にする
  const later = T0 + 2 * core.THROTTLE_MS;
  const same = summarize(await Promise.allSettled([claimReaction({ skyId: "sky2", nowMs: later }), claimReaction({ skyId: "sky2", nowMs: later + 10 })]));
  t.diagnostic(`同じ人: ${JSON.stringify(same)}`);
  assert.deepEqual(same.unexpected, []);
  assert.equal(same.decisions.filter((d) => d === "send").length, 1, "同じ人の2回のうち送るのは1通");
  assert.deepEqual(await reactionNoticeOf("g1", "sky2"), { notifiedReactorIds: ["bob"] });
});

test("リアクションの通知の枠: リアクションの通知を送った直後でも、同じグループの新着投稿の通知は send（陽性対照C4・新着投稿の notifyState に触れない）", async () => {
  await seedReactionSky("g1", "sky1", { authorId: "alice" });
  // リアクション → 新着投稿: alice へリアクションの通知を送った1秒後に、bob が新しく投稿する。
  // 陽性対照で「新着投稿の側が throttled になる」ことを赤の理由にするため、新着投稿の判定を最初に確かめる
  assert.equal(await claimReaction(), "send");
  const postStateBefore = await notifyState("g1", "alice");
  assert.equal(await store.claimNotifySlot(db, { groupId: "g1", uid: "alice", skyId: "sky2", nowMs: T0 + 1_000 }), "send");
  assert.equal(postStateBefore, null, "リアクションは新着投稿の notifyState を書かない");

  // 新着投稿 → リアクション: 別のグループで、alice へ新着投稿の通知を送った1秒後に、bob が alice の投稿に付ける
  await seedReactionSky("g2", "sky5", { authorId: "alice" });
  assert.equal(await store.claimNotifySlot(db, { groupId: "g2", uid: "alice", skyId: "sky6", nowMs: T0 }), "send");
  assert.equal(await claimReaction({ groupId: "g2", skyId: "sky5", nowMs: T0 + 1_000 }), "send");
  assert.equal((await notifyState("g2", "alice")).lastSkyId, "sky6", "新着投稿の記録はそのまま");
});
