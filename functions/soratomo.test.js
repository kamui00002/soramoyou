//
// soratomo.js（Callable・退会の Callable と onSoratomoSkyCreated の配線）のテスト ⭐️
//
// 実行（リポジトリの根で）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios "cd functions && node --test soratomo.test.js"
//
// - Firestore はエミュレーターの本物を使う（トランザクション・読み書きの形まで確かめるため）
// - 次の 4 つは require の前に Module._load を差し替えて偽物にする（pushHelpers.test.js と同じ方式）:
//     firebase-admin/auth（getUsers でフラグを返す）・./pushHelpers（送信を記録するだけ。本物の FCM へ送らない）・
//     firebase-functions/logger（ログを記録し、名前・キャプション・コード・トークンが出ていないかを見る）・
//     ./soratomoStorage（画像の一覧と削除をメモリ上のパスの集合で行う。退会の削除が本番のバケットへ向かわないため）
// - Callable とトリガーは、firebase-functions の .run() でハンドラーを直接呼ぶ
//
// ⚠️ soratomoStore.test.js と soratomo.test.js は、同じエミュレーターの文書を各テストの前に全部消して使う。
//    node --test に2つ渡すと既定では同時に走って消し合うので、--test-concurrency=1 を付ける（npm run test:emulator）。
// ⚠️ 本番へ書く事故の柵は soratomoStore.test.js と同じ（エミュレーターを指していなければ firebase-admin を読む前に止める）。
// ⚠️ 陽性対照: 先に「わざと壊した soratomo.js」で赤になるのを確かめてから通す。
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

// Storage の柵（二重目）: 偽のゲートウェイへの差し替えが外れても、本番のバケットへ届かないようにする。
// 届かない宛先（ポート 9）を Storage のエミュレーターとして指しておく。エミュレーターが別に指定されていればそのまま使う。
if (!process.env.STORAGE_EMULATOR_HOST) process.env.STORAGE_EMULATOR_HOST = "127.0.0.1:9";

// 通報の送り先（秘密の値）。テストでは名前の解決できない偽の URL を入れ、下の fetch の偽物で受ける。
const WEBHOOK_URL = "https://discord.invalid/api/webhooks/soratomo-test/not-a-real-token";
process.env.DISCORD_REPORT_WEBHOOK_URL = WEBHOOK_URL;

const test = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");

// MARK: - 偽物（Auth・送信・ログ）

const record = { sends: [], logs: [], getUsersCalls: [], webhooks: [] };
/** uid → customClaims。ここに無い uid は Auth に居ない扱い。 */
let claims = new Map();
/** 送信の結果（テストごとに差し替える）。 */
let sendImpl = async () => "sent";
/** getUsers の振る舞いを差し替えるとき（例: 失敗させる）に入れる。 */
let getUsersImpl = null;

const fakeAuth = {
  getUsers: async (identifiers) => {
    record.getUsersCalls.push(identifiers.map((x) => x.uid));
    if (getUsersImpl) return getUsersImpl(identifiers);
    return {
      users: identifiers.filter((x) => claims.has(x.uid)).map((x) => ({ uid: x.uid, customClaims: claims.get(x.uid) })),
      notFound: identifiers.filter((x) => !claims.has(x.uid)),
    };
  },
};
const fakePush = {
  sendToTokenGrouped: async (uid, token, notification, data, grouping) => {
    record.sends.push({ uid, token, notification, data, grouping });
    return sendImpl(uid);
  },
};
const log = (level) => (...args) => record.logs.push({ level, args });
const fakeLogger = { info: log("info"), warn: log("warn"), error: log("error"), debug: log("debug"), log: log("log") };
/** Storage の画像のパス（テストごとに入れ直す）。偽のゲートウェイはここから一覧し、ここから消す。 */
let storageFiles = new Set();
/** soratomoStorage のゲートウェイと同じ2つの口（接頭辞は本物と同じ文字列の前方一致・404 は "absent"）。 */
const fakeStorageGateway = {
  async *listFiles(prefix) {
    for (const path of [...storageFiles].filter((p) => p.startsWith(prefix)).sort()) yield path;
  },
  async deleteFile(path) {
    return storageFiles.delete(path) ? "deleted" : "absent";
  },
};

/**
 * 通報の送り先への送信の結果（テストごとに差し替える）。既定は Discord と同じ 204（本文なし）。
 * @type {(init: Object) => Promise<{ ok: boolean, status: number, text?: () => Promise<string> }>}
 */
let webhookImpl = async () => ({ ok: true, status: 204 });
/**
 * fetch の偽物: 送り先の URL への送信を記録して webhookImpl の結果を返す。エミュレーターへの要求（文書の全消去）だけを
 * 本物の fetch に通し、それ以外の宛先へは送らずに失敗させる（テストから外へ出さない柵）。
 */
const realFetch = globalThis.fetch;
globalThis.fetch = async (url, init) => {
  if (url === WEBHOOK_URL) {
    record.webhooks.push({ method: init && init.method, headers: init && init.headers, body: JSON.parse(init.body) });
    return webhookImpl(init);
  }
  if (typeof url === "string" && url.startsWith(`http://${EMULATOR_HOST}/`)) return realFetch(url, init);
  throw new Error(`テストから外へ送らない: ${String(url).slice(0, 30)}`);
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === "firebase-admin/auth") return { getAuth: () => fakeAuth };
  if (request === "./pushHelpers") return fakePush;
  if (request === "firebase-functions/logger") return fakeLogger;
  if (request === "./soratomoStorage") return { createStorageGateway: () => fakeStorageGateway };
  return originalLoad.call(this, request, parent, isMain);
};

const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const PROJECT_ID = "soramoyou-ios";
const app = initializeApp({ projectId: PROJECT_ID });
const fns = require("./soratomo");
Module._load = originalLoad;
const db = getFirestore(app);
const core = require("./soratomoCore");

/**
 * 語のリスト（soratomoConfig/ngWords）に入れるダミーの語（実在の語は書かない・release-gate の「進め方の約束」）。
 * ⚠️ soratomo.js の語のリストの提供口はモジュールの中に1つで、5分キャッシュする。各テストの前に文書を全部消しても
 *    キャッシュは残るので、どのテストでも同じ中身を入れ直す（中身を変えると、テストの順で結果が変わる）。
 *    「文書が無いときは internal」のテスト（tasks 4.5）は、この形では書けない。4.5 で提供口を差し替える口を考える。
 */
const NG_WORDS = ["てすとごい"];

/** 利用者が現行の版のガイドラインに同意した状態を入れる（release-gate 2.1）。ほかの項目は merge で残す。 */
async function agree(...uids) {
  for (const uid of uids) {
    await db.collection("soratomoUsers").doc(uid).set({ guidelineVersion: core.GUIDELINE_VERSION }, { merge: true });
  }
}

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
  await db.collection("soratomoConfig").doc("ngWords").set({ words: NG_WORDS });
  record.sends = [];
  record.logs = [];
  record.getUsersCalls = [];
  claims = new Map();
  sendImpl = async () => "sent";
  getUsersImpl = null;
  storageFiles = new Set();
  record.webhooks = [];
  webhookImpl = async () => ({ ok: true, status: 204 });
});

test.after(async () => {
  await deleteApp(app);
});

const ON = { soratomoBeta: true };
const authOf = (uid, token = ON) => ({ uid, token });

/** Callable をハンドラーとして直接呼ぶ。 */
function call(name, auth, data) {
  return fns[name].run({ auth, data, rawRequest: {} });
}

/**
 * HttpsError の code と details.reason を確かめる assert.rejects 用の判定。
 * expectedDetails を渡すと、details が { reason, ...expectedDetails } と完全に一致することも確かめる
 * （理由のほかに何が利用者へ返るかを固定する。{} を渡せば「理由だけ」）。
 */
function httpsError(code, reason, expectedDetails) {
  return (err) => {
    assert.equal(err && err.code, code, `code が違う: ${err && err.stack}`);
    if (reason === undefined) {
      assert.equal(err.details && err.details.reason, undefined);
    } else {
      assert.equal(err.details && err.details.reason, reason);
    }
    if (expectedDetails !== undefined) assert.deepEqual(err.details, { reason, ...expectedDetails });
    return true;
  };
}

/** 記録したログを1つの文字列にする（個人情報が混ざっていないかを調べるため）。 */
function allLogs() {
  return JSON.stringify(record.logs);
}

/** 文言が message のログ（例「soratomoCreateSky: ok」）の項目を、出た順に並べる。 */
function logFieldsOf(message) {
  return record.logs.filter((l) => l.args[0] === message).map((l) => l.args[1]);
}

async function seedGroup({ groupId, ownerId, inviteCode, memberIds, name = "種のグループ", lastActivityAt }) {
  const batch = db.batch();
  const ref = db.collection("soratomoGroups").doc(groupId);
  batch.set(ref, {
    name,
    ownerId,
    inviteCode,
    memberCount: memberIds.length,
    createdAt: Timestamp.now(),
    lastActivityAt: lastActivityAt || Timestamp.now(),
  });
  for (const uid of memberIds) {
    batch.set(ref.collection("members").doc(uid), { uid, role: uid === ownerId ? "owner" : "member", joinedAt: Timestamp.now() });
  }
  batch.set(db.collection("soratomoInviteCodes").doc(inviteCode), { groupId, createdAt: Timestamp.now() });
  await batch.commit();
}

// MARK: - Callable: ログインとフラグ（8.1）

/** クレームを確かめる Callable（退会の削除の soratomoDeleteMyData 以外のすべて）と、正しい形の要求。 */
const CALLABLES = [
  ["soratomoCreateGroup", { name: "空の会", requestId: "r1" }],
  ["soratomoJoinGroup", { code: "SKYAAAAA" }],
  ["soratomoRegenerateInviteCode", { groupId: "g1" }],
  ["soratomoCreateSky", { groupId: "g1", skyId: "s1", width: 1080, height: 1440 }],
  ["soratomoReportSky", { groupId: "g1", skyId: "s1", reason: "spam" }],
  ["soratomoAgreeGuideline", { version: 1 }],
];

test("Callable: クレームを確かめる6本とも、ログインが無ければ unauthenticated", async () => {
  for (const [name, data] of CALLABLES) {
    await assert.rejects(call(name, undefined, data), httpsError("unauthenticated"), name);
  }
});

test("Callable: クレームを確かめる6本とも、クレームが無い・true でなければ permission-denied（flag_off）で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  for (const token of [{}, { soratomoBeta: false }, { soratomoBeta: "true" }]) {
    for (const [name, data] of CALLABLES) {
      await assert.rejects(call(name, authOf("alice", token), data), httpsError("permission-denied", "flag_off"), name);
    }
  }
  assert.equal((await db.collection("soratomoGroups").get()).size, 1);
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("inviteCode"), "SKYAAAAA");
  assert.equal((await db.collection("soratomoUsers").get()).size, 0);
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("skies").get()).size, 0);
  assert.equal((await db.collection("soratomoReports").get()).size, 0);
});

// MARK: - Callable: 作成・参加・再発行（8.1）

test("作成: 結果を返し、ログには uid と groupId だけを出す（名前・コードを出さない）", async () => {
  await agree("alice");
  const result = await call("soratomoCreateGroup", authOf("alice"), { name: "ひみつの空の会", requestId: "r1" });
  assert.deepEqual(Object.keys(result).sort(), ["groupId", "inviteCode", "memberCount", "name"]);
  assert.equal(result.name, "ひみつの空の会");
  assert.equal(result.memberCount, 1);
  assert.equal((await db.collection("soratomoGroups").doc(result.groupId).get()).get("ownerId"), "alice");

  const logs = allLogs();
  assert.ok(logs.includes(result.groupId), "groupId はログに出す");
  assert.ok(!logs.includes("ひみつの空の会"), "グループ名をログに出さない");
  assert.ok(!logs.includes(result.inviteCode), "招待コードをログに出さない");
});

test("作成: 名前が不正なら invalid-argument（invalid_name）、所属10個なら resource-exhausted（user_limit）", async () => {
  await assert.rejects(
    call("soratomoCreateGroup", authOf("alice"), { name: "  ", requestId: "r1" }),
    httpsError("invalid-argument", "invalid_name")
  );
  await db.collection("soratomoUsers").doc("alice").set({ groupCount: 10, guidelineVersion: core.GUIDELINE_VERSION });
  await assert.rejects(
    call("soratomoCreateGroup", authOf("alice"), { name: "空の会", requestId: "r2" }),
    httpsError("resource-exhausted", "user_limit")
  );
});

test("作成: 要求IDが無いのは想定外の失敗として internal（理由なし）、data が無ければ invalid_name", async () => {
  await assert.rejects(call("soratomoCreateGroup", authOf("alice"), { name: "空の会" }), httpsError("internal"));
  await assert.rejects(call("soratomoCreateGroup", authOf("alice"), null), httpsError("invalid-argument", "invalid_name"));
  assert.equal((await db.collection("soratomoGroups").get()).size, 0);
});

test("参加: 成功と既存のメンバー、形の誤り・不在・満員・所属上限を、理由つきのエラーに写す", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  const full = Array.from({ length: 20 }, (_, i) => `m${i}`);
  await seedGroup({ groupId: "full", ownerId: "m0", inviteCode: "SKYFULLA", memberIds: full });
  await agree("bob");

  assert.deepEqual(await call("soratomoJoinGroup", authOf("bob"), { code: "sky-aaaaa" }), { groupId: "g1", alreadyMember: false });
  assert.deepEqual(await call("soratomoJoinGroup", authOf("bob"), { code: "SKYAAAAA" }), { groupId: "g1", alreadyMember: true });

  await assert.rejects(call("soratomoJoinGroup", authOf("bob"), { code: "SKY" }), httpsError("invalid-argument", "invalid_format"));
  await assert.rejects(call("soratomoJoinGroup", authOf("bob"), { code: "SKYBBBBB" }), httpsError("not-found", "not_found"));
  await assert.rejects(call("soratomoJoinGroup", authOf("bob"), { code: "SKYFULLA" }), httpsError("resource-exhausted", "group_full"));
  await db.collection("soratomoUsers").doc("carol").set({ groupCount: 10, guidelineVersion: core.GUIDELINE_VERSION });
  await assert.rejects(call("soratomoJoinGroup", authOf("carol"), { code: "SKYAAAAA" }), httpsError("resource-exhausted", "user_limit"));

  assert.ok(!allLogs().includes("SKYAAAAA"), "招待コードをログに出さない");
  assert.ok(!allLogs().includes("SKYFULLA"), "招待コードをログに出さない");
});

test("再発行: オーナーは新しいコード、メンバーは permission-denied（not_owner）、無いグループは not-found", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });

  await assert.rejects(
    call("soratomoRegenerateInviteCode", authOf("bob"), { groupId: "g1" }),
    httpsError("permission-denied", "not_owner")
  );
  await assert.rejects(
    call("soratomoRegenerateInviteCode", authOf("alice"), { groupId: "nope" }),
    httpsError("not-found", "not_found")
  );
  const { inviteCode } = await call("soratomoRegenerateInviteCode", authOf("alice"), { groupId: "g1" });
  assert.notEqual(inviteCode, "SKYAAAAA");
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("inviteCode"), inviteCode);
  assert.ok(!allLogs().includes(inviteCode), "新しい招待コードをログに出さない");
});

test("作成と参加: 方針を渡す — 同意の無い人は failed-precondition（consent_required・現行の版つき）、語を含む名前は invalid-argument（ng_word）で、何も書かず、語と名前をログに出さない", async () => {
  // release-gate 2.1 で配線した方針（現行のガイドラインの版・語のリストの判定）が、Callable から届いていることと、
  // 拒否が理由つきの HttpsError に写ること（tasks 4.1）を見る。details に載るのは理由と現行の版だけ（該当した語は載せない）。
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });

  const consentRequired = httpsError("failed-precondition", "consent_required", { currentVersion: core.GUIDELINE_VERSION });
  await assert.rejects(call("soratomoCreateGroup", authOf("alice"), { name: "空の会", requestId: "r1" }), consentRequired);
  await assert.rejects(call("soratomoJoinGroup", authOf("alice"), { code: "SKYAAAAA" }), consentRequired);
  assert.equal((await db.collection("soratomoGroups").get()).size, 1, "同意が無ければ作らない");
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("memberCount"), 1, "同意が無ければ参加させない");

  await agree("alice");
  await assert.rejects(
    call("soratomoCreateGroup", authOf("alice"), { name: "テストゴイの空", requestId: "r2" }),
    httpsError("invalid-argument", "ng_word", {})
  );
  assert.equal((await db.collection("soratomoGroups").get()).size, 1, "語を含む名前では作らない");

  const created = await call("soratomoCreateGroup", authOf("alice"), { name: "空の会", requestId: "r3" });
  assert.equal(created.name, "空の会", "同意があり語を含まない名前なら作る（現行の版が届いている）");
  assert.deepEqual(await call("soratomoJoinGroup", authOf("alice"), { code: "SKYAAAAA" }), { groupId: "g1", alreadyMember: false });

  const logs = allLogs();
  for (const secret of ["テストゴイの空", ...NG_WORDS]) {
    assert.ok(!logs.includes(secret), `ログに「${secret}」を出さない`);
  }
});

test("作成と参加: 利用停止中の人は permission-denied（suspended）で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner"] });
  await db
    .collection("soratomoUsers")
    .doc("alice")
    .set({ suspendedAt: Timestamp.now(), groupCount: 0, guidelineVersion: core.GUIDELINE_VERSION });

  const suspended = httpsError("permission-denied", "suspended", {});
  await assert.rejects(call("soratomoCreateGroup", authOf("alice"), { name: "空の会", requestId: "r1" }), suspended);
  await assert.rejects(call("soratomoJoinGroup", authOf("alice"), { code: "SKYAAAAA" }), suspended);
  assert.equal((await db.collection("soratomoGroups").get()).size, 1, "停止中は作らない");
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("memberCount"), 1, "停止中は参加させない");
});

// MARK: - Callable: 投稿・通報・同意（release-gate 4.2）

test("投稿: メンバーの投稿を5項目で作って { skyId, created: true }、同じIDの送り直しは created: false で1件のまま、ログはIDだけ", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  const input = { groupId: "g1", skyId: "s1", caption: "夕焼けがきれい", width: 1080, height: 1440 };
  const skies = db.collection("soratomoGroups").doc("g1").collection("skies");

  assert.deepEqual(await call("soratomoCreateSky", authOf("alice"), input), { skyId: "s1", created: true });
  const sky = (await skies.doc("s1").get()).data();
  assert.deepEqual(Object.keys(sky).sort(), ["authorId", "caption", "createdAt", "height", "width"]);
  assert.equal(sky.authorId, "alice");
  assert.ok(sky.createdAt instanceof Timestamp, "作成日時はサーバーの時刻");

  assert.deepEqual(await call("soratomoCreateSky", authOf("alice"), input), { skyId: "s1", created: false });
  assert.equal((await skies.get()).size, 1);

  assert.deepEqual(logFieldsOf("soratomoCreateSky: ok"), [
    { uid: "alice", groupId: "g1", skyId: "s1", created: true },
    { uid: "alice", groupId: "g1", skyId: "s1", created: false },
  ]);
  assert.ok(!allLogs().includes("夕焼けがきれい"), "キャプションをログに出さない");
});

test("投稿: 語を含むキャプションは invalid-argument（ng_word）で作らず、拒否のログは uid・groupId・skyId・理由だけ", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  await assert.rejects(
    call("soratomoCreateSky", authOf("alice"), { groupId: "g1", skyId: "s2", caption: "テストゴイの空", width: 1, height: 1 }),
    httpsError("invalid-argument", "ng_word", {})
  );
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("skies").get()).size, 0);
  assert.deepEqual(logFieldsOf("soratomoCreateSky: rejected"), [{ uid: "alice", groupId: "g1", skyId: "s2", reason: "ng_word" }]);
  for (const secret of ["テストゴイの空", ...NG_WORDS]) {
    assert.ok(!allLogs().includes(secret), `ログに「${secret}」を出さない`);
  }
});

test("拒否のログ: 要求の groupId・skyId は自動IDの形のときだけ出す（形の違う値をログに書かせない）", async () => {
  await assert.rejects(
    call("soratomoCreateSky", authOf("alice"), { groupId: "ひみつの空の会", skyId: "s1", width: 1, height: 1 }),
    httpsError("invalid-argument", "invalid_input", {})
  );
  assert.deepEqual(logFieldsOf("soratomoCreateSky: rejected"), [{ uid: "alice", skyId: "s1", reason: "invalid_input" }]);
  assert.ok(!allLogs().includes("ひみつの空の会"));
});

test("通報: ほかの人の投稿の通報は { accepted: true } だけを返して記録を作り、2回目も同じ応答で記録は1件、ログは記録のIDと重複かどうか", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  await db
    .collection("soratomoGroups")
    .doc("g1")
    .collection("skies")
    .doc("s1")
    .set({ authorId: "alice", caption: "夕焼けがきれい", width: 1, height: 1, createdAt: Timestamp.now() });
  const input = { groupId: "g1", skyId: "s1", reason: "spam" };

  assert.deepEqual(await call("soratomoReportSky", authOf("bob"), input), { accepted: true });
  assert.deepEqual(await call("soratomoReportSky", authOf("bob"), input), { accepted: true });

  const reports = await db.collection("soratomoReports").get();
  assert.equal(reports.size, 1);
  const reportId = core.reportDocId("g1", "s1", "bob");
  assert.equal(reports.docs[0].id, reportId);
  assert.equal(reports.docs[0].get("authorId"), "alice");
  assert.equal(reports.docs[0].get("reporterId"), "bob");
  assert.deepEqual(logFieldsOf("soratomoReportSky: ok"), [
    { uid: "bob", reportId, duplicate: false },
    { uid: "bob", reportId, duplicate: true },
  ]);
  assert.ok(!allLogs().includes("夕焼けがきれい"));
});

test("同意: 現行の版を記録して { version } を返す。古い版は failed-precondition（outdated_guideline・現行の版つき）で何も書かない", async () => {
  await assert.rejects(
    call("soratomoAgreeGuideline", authOf("alice"), { version: core.GUIDELINE_VERSION - 1 }),
    httpsError("failed-precondition", "outdated_guideline", { currentVersion: core.GUIDELINE_VERSION })
  );
  assert.equal((await db.collection("soratomoUsers").doc("alice").get()).exists, false);

  assert.deepEqual(await call("soratomoAgreeGuideline", authOf("alice"), { version: core.GUIDELINE_VERSION }), {
    version: core.GUIDELINE_VERSION,
  });
  const user = (await db.collection("soratomoUsers").doc("alice").get()).data();
  assert.equal(user.guidelineVersion, core.GUIDELINE_VERSION);
  assert.ok(user.guidelineAgreedAt instanceof Timestamp, "同意の日時はサーバーの時刻");
  assert.deepEqual(logFieldsOf("soratomoAgreeGuideline: ok"), [{ uid: "alice", version: core.GUIDELINE_VERSION }]);
});

// MARK: - Callable: 退会（release-gate 4.1）

/** 退会の削除の場面: グループ gdel1 にオーナーの alice とメンバーの bob。2人とも投稿1件（画像2枚ずつ）と所属の写しを持つ。 */
const DEL_GROUP = "gdel1";
const imagesOf = (uid, skyId) => [`soratomo/${DEL_GROUP}/${uid}/${skyId}/display.jpg`, `soratomo/${DEL_GROUP}/${uid}/${skyId}/thumb.jpg`];
async function seedDeletionScene() {
  await seedGroup({ groupId: DEL_GROUP, ownerId: "alice", inviteCode: "SKYDELAA", memberIds: ["alice", "bob"], name: "ひみつの空の会" });
  const groupRef = db.collection("soratomoGroups").doc(DEL_GROUP);
  const batch = db.batch();
  batch.set(groupRef.collection("skies").doc("sa1"), { authorId: "alice", caption: "夕焼けがきれい", width: 1, height: 1, createdAt: Timestamp.now() });
  batch.set(groupRef.collection("skies").doc("sb1"), { authorId: "bob", width: 1, height: 1, createdAt: Timestamp.now() });
  for (const uid of ["alice", "bob"]) {
    const userRef = db.collection("soratomoUsers").doc(uid);
    batch.set(userRef, { groupCount: 1, guidelineVersion: core.GUIDELINE_VERSION });
    batch.set(userRef.collection("groups").doc(DEL_GROUP), { groupId: DEL_GROUP, joinedAt: Timestamp.now() });
  }
  await batch.commit();
  storageFiles = new Set([...imagesOf("alice", "sa1"), ...imagesOf("bob", "sb1")]);
}

/** 退会の Callable の ok のログ（1行だけのはず）の項目。 */
function deleteOkLogs() {
  return logFieldsOf("soratomoDeleteMyData: ok");
}

test("退会: ログインが無ければ unauthenticated で、何も消さない", async () => {
  await seedDeletionScene();
  await assert.rejects(call("soratomoDeleteMyData", undefined, {}), httpsError("unauthenticated"));
  assert.equal((await db.collection("soratomoUsers").doc("alice").get()).exists, true);
  assert.equal(storageFiles.size, 4);
});

test("退会: 機能フラグのクレームが無い人（匿名を含む）・false の人も自分のデータを消し、応答は { done } だけ・ログは内部IDと件数だけ", async () => {
  await seedDeletionScene();
  const groupRef = db.collection("soratomoGroups").doc(DEL_GROUP);

  // 匿名のログイン（クレーム無し）
  const anonymous = { firebase: { sign_in_provider: "anonymous" } };
  assert.deepEqual(await call("soratomoDeleteMyData", authOf("alice", anonymous), {}), { done: true });

  assert.equal((await groupRef.collection("skies").doc("sa1").get()).exists, false, "退会者の投稿は消える");
  assert.equal((await groupRef.collection("skies").doc("sb1").get()).exists, true, "ほかのメンバーの投稿は残る");
  assert.deepEqual([...storageFiles].sort(), imagesOf("bob", "sb1").sort(), "画像は退会者の分だけ消える（偽のゲートウェイを通っている）");
  assert.equal((await groupRef.collection("members").doc("alice").get()).exists, false);
  const group = (await groupRef.get()).data();
  assert.equal(group.ownerId, "bob", "オーナーを引き継ぐ");
  assert.equal(group.memberCount, 1);
  assert.equal((await db.collection("soratomoUsers").doc("alice").get()).exists, false, "利用者の文書も消える");

  assert.deepEqual(deleteOkLogs(), [
    { uid: "alice", done: true, skiesDeleted: 1, imagesDeleted: 2, groupsLeft: 1, ownersTransferred: 1, groupsDeleted: 0 },
  ]);
  const logs = allLogs();
  for (const secret of ["ひみつの空の会", "SKYDELAA", "夕焼けがきれい"]) {
    assert.ok(!logs.includes(secret), `ログに「${secret}」を出さない`);
  }

  // クレームが false の人の再実行（もう何も無い）: 空振りで完了し、件数は0
  record.logs = [];
  assert.deepEqual(await call("soratomoDeleteMyData", authOf("alice", { soratomoBeta: false }), {}), { done: true });
  assert.deepEqual(deleteOkLogs(), [
    { uid: "alice", done: true, skiesDeleted: 0, imagesDeleted: 0, groupsLeft: 0, ownersTransferred: 0, groupsDeleted: 0 },
  ]);
});

test("退会: 関数の設定は、制限時間120秒・メモリ512MiB・既存と同じリージョン", () => {
  // firebase deploy が読む関数の設定（onCall の選択肢がここに写る）。1回の予算45秒より長い制限時間にする（design の soratomoDeleteMyData）
  const endpoint = fns.soratomoDeleteMyData.__endpoint;
  assert.equal(endpoint.timeoutSeconds, 120);
  assert.equal(endpoint.availableMemoryMb, 512);
  assert.deepEqual(endpoint.region, ["asia-northeast1"]);
});

// MARK: - トリガー: onSoratomoSkyCreated（8.2）

const OLD = Timestamp.fromMillis(Date.UTC(2026, 0, 1));
const MEMBERS = ["poster", "a", "b", "c", "d", "e", "f"];

/**
 * 宛先の分類を一通り含む場面を入れる。
 * a・f: 送る / b: フラグOFF / c: 通知設定OFF / d: 投稿者をブロック / e: トークン無し / poster: 投稿者（宛先から除く）
 */
async function seedScene({ posterName = "ソラミ" } = {}) {
  await seedGroup({ groupId: "g1", ownerId: "poster", inviteCode: "SKYAAAAA", memberIds: MEMBERS, name: "ひみつの空の会", lastActivityAt: OLD });
  const users = {
    poster: { displayName: posterName, fcmToken: "tok-poster" },
    a: { fcmToken: "tok-a" },
    b: { fcmToken: "tok-b" },
    c: { fcmToken: "tok-c", notifySoratomo: false },
    d: { fcmToken: "tok-d", blockedUserIds: ["poster"] },
    e: {},
    f: { fcmToken: "tok-f", notifySoratomo: true },
  };
  const batch = db.batch();
  for (const [uid, data] of Object.entries(users)) batch.set(db.collection("users").doc(uid), data);
  await batch.commit();
  claims = new Map(MEMBERS.map((uid) => [uid, uid === "b" ? {} : ON]));
}

/** 投稿の文書を作り、そのスナップショットでトリガーのハンドラーを呼ぶ。 */
async function postSky(skyId, { caption = "夕焼けがきれい", createdAt = Timestamp.now(), authorId = "poster" } = {}) {
  const ref = db.collection("soratomoGroups").doc("g1").collection("skies").doc(skyId);
  const data = { authorId, width: 1080, height: 1440, createdAt };
  if (caption !== null) data.caption = caption;
  await ref.set(data);
  return runTrigger(skyId);
}
async function runTrigger(skyId, groupId = "g1") {
  const snap = await db.collection("soratomoGroups").doc(groupId).collection("skies").doc(skyId).get();
  return fns.onSoratomoSkyCreated.run({ params: { groupId, skyId }, data: snap });
}

/** 集計のログ（groupId と skyId を持つ info）を取り出す。 */
function summaryLog() {
  const found = record.logs.filter((l) => l.level === "info" && l.args.some((a) => a && typeof a === "object" && "sendFailed" in a));
  assert.equal(found.length, 1, "集計のログは1行だけ");
  return found[0].args.find((a) => a && typeof a === "object" && "sendFailed" in a);
}

test("トリガー: 投稿者を除いたメンバーを分類し、送れる宛先だけへ、まとめ指定つきで送る", async () => {
  await seedScene();
  await postSky("s1");

  assert.deepEqual(record.sends.map((s) => s.uid).sort(), ["a", "f"]);
  for (const s of record.sends) {
    assert.equal(s.token, `tok-${s.uid}`);
    assert.deepEqual(s.notification, { title: "ひみつの空の会", body: "ソラミさんが空を投稿しました「夕焼けがきれい」" });
    assert.deepEqual(s.data, { type: "soratomoPost", groupId: "g1", postId: "s1" });
    assert.deepEqual(s.grouping, { threadId: "soratomo-g1", collapseId: "soratomo-g1" });
  }
  assert.equal(record.getUsersCalls.length, 1, "フラグはまとめて1回で確かめる");
  assert.deepEqual([...record.getUsersCalls[0]].sort(), ["a", "b", "c", "d", "e", "f"]);

  assert.deepEqual(summaryLog(), {
    groupId: "g1",
    skyId: "s1",
    sent: 2,
    throttled: 0,
    duplicate: 0,
    noToken: 1,
    sendFailed: 0,
    prefOff: 1,
    blocked: 1,
    flagOff: 1,
  });
  const logs = allLogs();
  for (const secret of ["ひみつの空の会", "夕焼けがきれい", "ソラミ", "tok-", "SKYAAAAA"]) {
    assert.ok(!logs.includes(secret), `ログに「${secret}」を出さない`);
  }
});

test("トリガー: 同じ投稿の再配信は重複として送らず、5分以内の次の投稿は間引く", async () => {
  await seedScene();
  await postSky("s1");
  assert.equal(record.sends.length, 2);

  record.sends = [];
  record.logs = [];
  await runTrigger("s1");
  assert.equal(record.sends.length, 0);
  assert.equal(summaryLog().duplicate, 2);

  record.logs = [];
  await postSky("s2");
  assert.equal(record.sends.length, 0);
  assert.equal(summaryLog().throttled, 2);
});

test("トリガー: 1人の送信の失敗で残りを止めず、例外を投げずに終える", async () => {
  await seedScene();
  sendImpl = async (uid) => {
    if (uid === "a") throw new Error("送信の内部エラー");
    return "sent";
  };
  await postSky("s1");
  assert.deepEqual(record.sends.map((s) => s.uid).sort(), ["a", "f"]);
  const summary = summaryLog();
  assert.equal(summary.sent, 1);
  assert.equal(summary.sendFailed, 1);
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("skies").doc("s1").get()).exists, true, "投稿は消さない");
});

test("トリガー: フラグの確認に失敗しても例外を投げず、だれにも送らない", async () => {
  await seedScene();
  getUsersImpl = async () => {
    throw new Error("auth の失敗");
  };
  await postSky("s1");
  assert.equal(record.sends.length, 0);
  assert.equal(summaryLog().flagOff, 6);
});

test("トリガー: グループの最新の活動時刻を、投稿の作成日時との大きいほうにする", async () => {
  await seedScene();
  const createdAt = Timestamp.fromMillis(Date.UTC(2026, 5, 1));
  await postSky("s1", { createdAt });
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("lastActivityAt").toMillis(), createdAt.toMillis());

  // それより古い投稿では戻さない
  await postSky("s0", { createdAt: Timestamp.fromMillis(Date.UTC(2026, 2, 1)) });
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("lastActivityAt").toMillis(), createdAt.toMillis());
});

test("トリガー: 通知の準備で失敗しても、グループの最新の活動時刻は更新する（レビューで直した）", async () => {
  await seedScene();
  const core = require("./soratomoCore");
  const original = core.buildNotification;
  core.buildNotification = () => {
    throw new Error("通知の準備の失敗");
  };
  try {
    const createdAt = Timestamp.fromMillis(Date.UTC(2026, 5, 1));
    await postSky("s1", { createdAt });
    assert.equal(record.sends.length, 0, "準備で失敗したので、だれにも送らない");
    assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("lastActivityAt").toMillis(), createdAt.toMillis());
  } finally {
    core.buildNotification = original;
  }
});

test("トリガー: 表示名が空なら「だれか」、キャプションが無ければ「」を付けない", async () => {
  await seedScene({ posterName: "" });
  await postSky("s1", { caption: null });
  assert.equal(record.sends[0].notification.body, "だれかさんが空を投稿しました");
});

test("トリガー: グループが無ければ、例外を投げずに何もしない（メンバーの文書だけが残っていても送らない）", async () => {
  const ghost = db.collection("soratomoGroups").doc("ghost");
  await ghost.collection("members").doc("a").set({ uid: "a", role: "member", joinedAt: Timestamp.now() });
  await db.collection("users").doc("a").set({ fcmToken: "tok-a" });
  claims = new Map([["a", ON]]);
  await ghost.collection("skies").doc("s1").set({ authorId: "poster", createdAt: Timestamp.now() });
  await runTrigger("s1", "ghost");
  assert.equal(record.sends.length, 0);
  assert.equal(record.getUsersCalls.length, 0);
});

// MARK: - トリガー: onSoratomoReportCreated（release-gate 4.3）

/**
 * 通報の場面: グループ g1（名前・招待コードあり）で、bob が alice の投稿 s1（キャプションあり）を通報した記録を、
 * 通報の Callable で作る。記録のスナップショットを返す（トリガーに渡す・再配信のテストで同じものをもう一度渡す）。
 */
async function seedReportScene() {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"], name: "ひみつの空の会" });
  await db.collection("users").doc("alice").set({ displayName: "ソラミ" });
  await db
    .collection("soratomoGroups")
    .doc("g1")
    .collection("skies")
    .doc("s1")
    .set({ authorId: "alice", caption: "夕焼けがきれい", width: 1, height: 1, createdAt: Timestamp.now() });
  await call("soratomoReportSky", authOf("bob"), { groupId: "g1", skyId: "s1", reason: "harassment" });
  record.logs = [];
  return db.collection("soratomoReports").doc(core.reportDocId("g1", "s1", "bob")).get();
}

function runReportTrigger(snap) {
  return fns.onSoratomoReportCreated.run({ params: { reportId: snap.id }, data: snap });
}

/** 送ってはいけないもの（キャプション・グループ名・表示名・招待コード・送り先の URL）。 */
const FORWARD_SECRETS = ["夕焼けがきれい", "ひみつの空の会", "ソラミ", "SKYAAAAA", WEBHOOK_URL];

test("転送: 通報の記録の作成で、IDと理由と時刻だけを送り、送信済みと送信日時を書く。ログは記録のIDだけ", async () => {
  const snap = await seedReportScene();
  await runReportTrigger(snap);

  assert.equal(record.webhooks.length, 1);
  const { method, headers, body } = record.webhooks[0];
  assert.equal(method, "POST");
  assert.equal(headers["Content-Type"], "application/json");
  assert.equal(body.username, "そらとも 通報");
  assert.equal(body.embeds[0].title, "そらともの通報が届きました");
  const sent = JSON.stringify(body);
  for (const id of [snap.id, "g1", "s1", "alice", "bob", "harassment"]) assert.ok(sent.includes(id), `本文に ${id} を載せる`);
  for (const secret of FORWARD_SECRETS) assert.ok(!sent.includes(secret), `本文に「${secret}」を載せない`);
  assert.ok(!/https?:\/\//.test(sent), "本文に URL（画像・コンソール）を載せない");

  const after = (await snap.ref.get()).data();
  assert.equal(after.forwardStatus, "sent");
  assert.ok(after.forwardedAt instanceof Timestamp, "送信日時はサーバーの時刻");
  assert.equal(after.forwardAttempts, 0);
  assert.deepEqual(logFieldsOf("soratomoReport: forwarded"), [{ reportId: snap.id }]);
  for (const secret of FORWARD_SECRETS) assert.ok(!allLogs().includes(secret), `ログに「${secret}」を出さない`);
});

test("転送: 送れなければ（HTTP の失敗・通信の失敗）未送信のまま失敗の回数を増やし、error のログは記録のIDと状態だけで、例外を投げない", async () => {
  const snap = await seedReportScene();

  // HTTP の失敗（応答の本文はログに出さない）
  webhookImpl = async () => ({ ok: false, status: 500, text: async () => "応答のひみつの本文" });
  await runReportTrigger(snap);
  let after = (await snap.ref.get()).data();
  assert.equal(after.forwardStatus, "pending");
  assert.equal(after.forwardAttempts, 1);
  assert.equal(after.forwardedAt, undefined);

  // 通信の失敗（エラーの本文に送り先の URL が入っていてもログに出さない）
  webhookImpl = async () => {
    throw new TypeError(`fetch failed: ${WEBHOOK_URL}`);
  };
  await runReportTrigger(snap);
  after = (await snap.ref.get()).data();
  assert.equal(after.forwardStatus, "pending");
  assert.equal(after.forwardAttempts, 2);

  const failures = record.logs.filter((l) => l.level === "error").map((l) => l.args[1]);
  assert.deepEqual(failures, [
    { reportId: snap.id, status: 500 },
    { reportId: snap.id, status: "fetch_failed" },
  ]);
  assert.deepEqual(logFieldsOf("soratomoReport: forwarded"), []);
  for (const secret of ["応答のひみつの本文", ...FORWARD_SECRETS]) {
    assert.ok(!allLogs().includes(secret), `ログに「${secret}」を出さない`);
  }
});

test("転送: 送信済みの記録は送らない（同じ作成のイベントの再配信でも二重に送らない）", async () => {
  const snap = await seedReportScene();
  await runReportTrigger(snap);
  assert.equal(record.webhooks.length, 1);

  // 再配信: 作成のときのスナップショット（未送信のまま）がもう一度届く
  await runReportTrigger(snap);
  assert.equal(record.webhooks.length, 1, "いまの記録が送信済みなので送らない");
  assert.equal((await snap.ref.get()).get("forwardAttempts"), 0);
});
