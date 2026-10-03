//
// soratomo.js（Callable 3本と onSoratomoSkyCreated の配線）のテスト ⭐️
//
// 実行（リポジトリの根で）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios "cd functions && node --test soratomo.test.js"
//
// - Firestore はエミュレーターの本物を使う（トランザクション・読み書きの形まで確かめるため）
// - 次の 3 つは require の前に Module._load を差し替えて偽物にする（pushHelpers.test.js と同じ方式）:
//     firebase-admin/auth（getUsers でフラグを返す）・./pushHelpers（送信を記録するだけ。本物の FCM へ送らない）・
//     firebase-functions/logger（ログを記録し、名前・キャプション・コード・トークンが出ていないかを見る）
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

const test = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");

// MARK: - 偽物（Auth・送信・ログ）

const record = { sends: [], logs: [], getUsersCalls: [] };
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

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === "firebase-admin/auth") return { getAuth: () => fakeAuth };
  if (request === "./pushHelpers") return fakePush;
  if (request === "firebase-functions/logger") return fakeLogger;
  return originalLoad.call(this, request, parent, isMain);
};

const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const PROJECT_ID = "soramoyou-ios";
const app = initializeApp({ projectId: PROJECT_ID });
const fns = require("./soratomo");
Module._load = originalLoad;
const db = getFirestore(app);

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${EMULATOR_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
  record.sends = [];
  record.logs = [];
  record.getUsersCalls = [];
  claims = new Map();
  sendImpl = async () => "sent";
  getUsersImpl = null;
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

/** HttpsError の code と details.reason を確かめる assert.rejects 用の判定。 */
function httpsError(code, reason) {
  return (err) => {
    assert.equal(err && err.code, code, `code が違う: ${err && err.stack}`);
    if (reason === undefined) {
      assert.equal(err.details && err.details.reason, undefined);
    } else {
      assert.equal(err.details && err.details.reason, reason);
    }
    return true;
  };
}

/** 記録したログを1つの文字列にする（個人情報が混ざっていないかを調べるため）。 */
function allLogs() {
  return JSON.stringify(record.logs);
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

const CALLABLES = [
  ["soratomoCreateGroup", { name: "空の会", requestId: "r1" }],
  ["soratomoJoinGroup", { code: "SKYAAAAA" }],
  ["soratomoRegenerateInviteCode", { groupId: "g1" }],
];

test("Callable: 3本とも、ログインが無ければ unauthenticated", async () => {
  for (const [name, data] of CALLABLES) {
    await assert.rejects(call(name, undefined, data), httpsError("unauthenticated"), name);
  }
});

test("Callable: 3本とも、クレームが無い・true でなければ permission-denied（flag_off）で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  for (const token of [{}, { soratomoBeta: false }, { soratomoBeta: "true" }]) {
    for (const [name, data] of CALLABLES) {
      await assert.rejects(call(name, authOf("alice", token), data), httpsError("permission-denied", "flag_off"), name);
    }
  }
  assert.equal((await db.collection("soratomoGroups").get()).size, 1);
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("inviteCode"), "SKYAAAAA");
  assert.equal((await db.collection("soratomoUsers").get()).size, 0);
});

// MARK: - Callable: 作成・参加・再発行（8.1）

test("作成: 結果を返し、ログには uid と groupId だけを出す（名前・コードを出さない）", async () => {
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
  await db.collection("soratomoUsers").doc("alice").set({ groupCount: 10 });
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

  assert.deepEqual(await call("soratomoJoinGroup", authOf("bob"), { code: "sky-aaaaa" }), { groupId: "g1", alreadyMember: false });
  assert.deepEqual(await call("soratomoJoinGroup", authOf("bob"), { code: "SKYAAAAA" }), { groupId: "g1", alreadyMember: true });

  await assert.rejects(call("soratomoJoinGroup", authOf("bob"), { code: "SKY" }), httpsError("invalid-argument", "invalid_format"));
  await assert.rejects(call("soratomoJoinGroup", authOf("bob"), { code: "SKYBBBBB" }), httpsError("not-found", "not_found"));
  await assert.rejects(call("soratomoJoinGroup", authOf("bob"), { code: "SKYFULLA" }), httpsError("resource-exhausted", "group_full"));
  await db.collection("soratomoUsers").doc("carol").set({ groupCount: 10 });
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
