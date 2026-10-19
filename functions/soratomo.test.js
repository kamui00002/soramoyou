//
// soratomo.js（Callable・トリガー・定期実行の配線）のテスト ⭐️
//
// 実行（リポジトリの根で）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
//     firebase emulators:exec --only firestore --project soramoyou-ios "cd functions && node --test soratomo.test.js"
//
// - Firestore はエミュレーターの本物を使う（トランザクション・読み書きの形まで確かめるため）
// - 次の 5 つは require の前に Module._load を差し替える（pushHelpers.test.js と同じ方式）:
//     firebase-admin/auth（getUsers でアカウントの有無を返す。定期実行が使う。通知の宛先の絞り込みでは呼ばれないことも見る）・
//     ./pushHelpers（送信を記録するだけ。本物の FCM へ
//     送らない）・firebase-functions/logger（ログを記録し、名前・キャプション・コード・トークンが出ていないかを見る）・
//     ./soratomoStorage（画像の一覧と削除をメモリ上のパスの集合で行う。退会の削除が本番のバケットへ向かわないため）・
//     ./soratomoNgWords（本物を包み、ngWordsOverride を入れた間だけ別の提供口を使う。「一度も読めていない」場面のため）
// - グローバルの fetch も偽物にする（Module._load ではない）。通報の送り先の URL への送信を記録し、エミュレーターへの
//   要求（文書の全消去）だけを本物に通す。それ以外の宛先へは送らない
// - Callable とトリガーと定期実行は、firebase-functions の .run() でハンドラーを直接呼ぶ
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
const fs = require("node:fs");
const path = require("node:path");

// MARK: - 偽物（Auth・送信・ログ）

const record = { sends: [], otherSends: [], logs: [], getUsersCalls: [], webhooks: [] };
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
  // 既存のほかの通知（いいね・コメントなど index.js の通知）の送信の口。そらともから呼ばれないことを見るため、記録だけする
  sendToToken: async (...args) => {
    record.otherSends.push({ fn: "sendToToken", uid: args[0] });
  },
  sendToUid: async (...args) => {
    record.otherSends.push({ fn: "sendToUid", uid: args[0] });
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

/**
 * 語のリストの提供口の差し替え（release-gate 4.5）。soratomo.js の提供口はモジュールに1つで5分キャッシュするため、
 * 「一度も読めていない」場面はそのままでは作れない。soratomo.js が作る提供口を包み、ngWordsOverride を入れた間だけ
 * そちらの matcher() を使う（本体の exports は増やさない）。realCreateNgWordProvider は本物の作り方（新しい提供口を作る）。
 */
let ngWordsOverride = null;
let realCreateNgWordProvider = null;

const originalLoad = Module._load;
/** 偽物へ差し替える読み込み。soratomo.js を読む間だけ入れる（選択肢の名前の検査のテストでも、写しを読む間だけ入れ直す）。 */
function fakeLoad(request, parent, isMain) {
  if (request === "firebase-admin/auth") return { getAuth: () => fakeAuth };
  if (request === "./pushHelpers") return fakePush;
  if (request === "firebase-functions/logger") return fakeLogger;
  if (request === "./soratomoStorage") return { createStorageGateway: () => fakeStorageGateway };
  if (request === "./soratomoNgWords") {
    const real = originalLoad.call(this, request, parent, isMain);
    realCreateNgWordProvider = real.createNgWordProvider;
    return {
      ...real,
      createNgWordProvider: (deps) => {
        const shared = real.createNgWordProvider(deps);
        return { matcher: () => (ngWordsOverride || shared).matcher() };
      },
    };
  }
  return originalLoad.call(this, request, parent, isMain);
}
Module._load = fakeLoad;

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
 *    「文書が無いときは internal」のテスト（tasks 4.5）は、ngWordsOverride に新しい提供口を入れて書く。
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
  record.otherSends = [];
  record.logs = [];
  record.getUsersCalls = [];
  claims = new Map();
  sendImpl = async () => "sent";
  getUsersImpl = null;
  storageFiles = new Set();
  record.webhooks = [];
  webhookImpl = async () => ({ ok: true, status: 204 });
  ngWordsOverride = null;
});

test.after(async () => {
  await deleteApp(app);
});

/**
 * ID トークンの形（public-launch 3.1）。本番のトークンには firebase.sign_in_provider が必ずある。
 * - REGISTERED: 登録済み（メールとパスワード）・クレーム無し。1.15.0 の一般の利用者で、既定のトークン
 * - CLAIMED: 登録済み・クレーム soratomoBeta あり。1.14.x の先行公開でクレームを付けた人
 * - ANONYMOUS: 匿名のログイン（退会の削除だけ通す）
 * BETA_CLAIMS はトークンでなく、偽の Auth の getUsers が返す customClaims（定期実行の「アカウントがある」の印にも使う）。
 */
const REGISTERED = { firebase: { sign_in_provider: "password" } };
const CLAIMED = { soratomoBeta: true, firebase: { sign_in_provider: "password" } };
const ANONYMOUS = { firebase: { sign_in_provider: "anonymous" } };
const BETA_CLAIMS = { soratomoBeta: true };
const authOf = (uid, token = REGISTERED) => ({ uid, token });

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

// MARK: - Callable: ログインと関門（8.1・public-launch 3.1）

/** 匿名を拒否する Callable（退会の削除 soratomoDeleteMyData 以外の8本）と、正しい形の要求。 */
const CALLABLES = [
  ["soratomoCreateGroup", { name: "空の会", requestId: "r1" }],
  ["soratomoJoinGroup", { code: "SKYAAAAA" }],
  ["soratomoRegenerateInviteCode", { groupId: "g1" }],
  ["soratomoCreateSky", { groupId: "g1", skyId: "s1", width: 1080, height: 1440 }],
  ["soratomoReportSky", { groupId: "g1", skyId: "s1", reason: "spam" }],
  ["soratomoAgreeGuideline", { version: 1 }],
  ["soratomoSetReaction", { groupId: "g1", skyId: "s1", kind: "sunset" }],
  ["soratomoLeaveGroup", { groupId: "g1" }],
];

/**
 * 関門で止められた後に、何も書かれていないことを確かめる。場面は g1（alice だけ・招待コード SKYAAAAA）。
 * alice が関門を通ってしまうと、再発行でコードが変わる・投稿ができる・同意が記録される・抜けるでグループごと消える。
 */
async function assertGateWroteNothing() {
  const groupRef = db.collection("soratomoGroups").doc("g1");
  assert.equal((await db.collection("soratomoGroups").get()).size, 1);
  assert.equal((await groupRef.get()).get("inviteCode"), "SKYAAAAA");
  assert.deepEqual((await groupRef.collection("members").get()).docs.map((d) => d.id), ["alice"]);
  assert.equal((await db.collection("soratomoUsers").get()).size, 0);
  assert.equal((await groupRef.collection("skies").get()).size, 0);
  assert.equal((await db.collection("soratomoReports").get()).size, 0);
  assert.equal((await db.collection("soratomoPendingLeaves").get()).size, 0);
}

test("Callable: 関門を持つ8本とも、ログインが無ければ unauthenticated", async () => {
  for (const [name, data] of CALLABLES) {
    await assert.rejects(call(name, undefined, data), httpsError("unauthenticated"), name);
  }
});

test("Callable（public-launch 1.7）: 匿名のログインは、クレームの有無に関係なく8本とも permission-denied（registration_required・理由だけ）で、何も書かない。拒否のログに理由を出す", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  for (const token of [ANONYMOUS, { ...ANONYMOUS, soratomoBeta: true }]) {
    for (const [name, data] of CALLABLES) {
      await assert.rejects(
        call(name, authOf("alice", token), data),
        httpsError("permission-denied", "registration_required", {}),
        `${name} ${JSON.stringify(token)}`
      );
    }
  }
  await assertGateWroteNothing();
  for (const [name] of CALLABLES) {
    const rejected = logFieldsOf(`${name}: rejected`);
    assert.equal(rejected.length, 2, name);
    for (const fields of rejected) {
      // 既存の形（{name}: rejected { uid, groupId?, skyId?, reason }）。関門の拒否では uid はまだ決まっていないので null
      // （1.14 期の flag_off の拒否と同じ）。トークンの中身は出さない
      assert.equal(fields.uid, null, name);
      assert.equal(fields.reason, "registration_required", name);
      assert.deepEqual(Object.keys(fields).filter((k) => !["uid", "groupId", "skyId", "reason"].includes(k)), [], name);
    }
  }
});

test("Callable（public-launch 1.7）: ログインの方式が読めないトークン（firebase の項目が無い・方式が文字列でない・トークンが無い）も、8本とも registration_required で拒否し、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  const auths = [
    authOf("alice", {}),
    authOf("alice", { soratomoBeta: true }), // 1.14 期に通っていた形でも、方式が無ければ拒否（閉じる側に倒す）
    authOf("alice", { firebase: {} }),
    authOf("alice", { firebase: { sign_in_provider: 1 } }),
    { uid: "alice" }, // トークンそのものが無い
  ];
  for (const auth of auths) {
    for (const [name, data] of CALLABLES) {
      await assert.rejects(
        call(name, auth, data),
        httpsError("permission-denied", "registration_required", {}),
        `${name} ${JSON.stringify(auth.token)}`
      );
    }
  }
  await assertGateWroteNothing();
});

test("Callable（public-launch 1.1・1.6）: クレームの無い登録済みは、8本とも関門で止められない（拒否されるならドメインの理由で、registration_required でも flag_off でもない）", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  for (const [name, data] of CALLABLES) {
    try {
      await call(name, authOf("alice"), data);
    } catch (err) {
      const reason = err && err.details && err.details.reason;
      assert.ok(reason !== "registration_required" && reason !== "flag_off", `${name}: 関門で止められた（${reason}）`);
      assert.notEqual(err && err.code, "unauthenticated", name);
    }
  }
  const logs = allLogs();
  assert.ok(!logs.includes("registration_required"), "関門の拒否のログが出ていない");
  assert.ok(!logs.includes("flag_off"), "1.14 期の拒否のログが出ていない");
});

/**
 * 2人（どちらも同じトークンの形）で、同意・作成・参加・投稿・通報・再発行・抜けるを1回ずつ通す。
 * @param {Object} token ID トークンの形（REGISTERED か CLAIMED）
 */
async function runHappyPath(token) {
  const alice = authOf("alice", token);
  const bob = authOf("bob", token);
  for (const auth of [alice, bob]) {
    assert.deepEqual(await call("soratomoAgreeGuideline", auth, { version: core.GUIDELINE_VERSION }), {
      version: core.GUIDELINE_VERSION,
    });
  }
  const created = await call("soratomoCreateGroup", alice, { name: "空の会", requestId: "r1" });
  const { groupId } = created;
  assert.deepEqual(await call("soratomoJoinGroup", bob, { code: created.inviteCode }), { groupId, alreadyMember: false });
  assert.deepEqual(await call("soratomoCreateSky", bob, { groupId, skyId: "s1", width: 1080, height: 1440 }), {
    skyId: "s1",
    created: true,
  });
  assert.deepEqual(await call("soratomoReportSky", alice, { groupId, skyId: "s1", reason: "spam" }), { accepted: true });
  assert.equal((await db.collection("soratomoReports").get()).size, 1);
  const { inviteCode } = await call("soratomoRegenerateInviteCode", alice, { groupId });
  assert.notEqual(inviteCode, created.inviteCode);
  assert.deepEqual(await call("soratomoLeaveGroup", bob, { groupId }), { done: true, groupDeleted: false });
  const members = await db.collection("soratomoGroups").doc(groupId).collection("members").get();
  assert.deepEqual(members.docs.map((d) => d.id), ["alice"]);
}

test("Callable（public-launch 1.1・1.2）: クレームの無い登録済みの2人で、同意・作成・参加・投稿・通報・再発行・抜けるが通る", async () => {
  await runHappyPath(REGISTERED);
});

test("Callable（public-launch 1.9）: クレームのある登録済み（1.14.x の人）も、今までどおり同意・作成・参加・投稿・通報・再発行・抜けるが通る", async () => {
  await runHappyPath(CLAIMED);
});

// MARK: - 選択肢の名前の検査（public-launch 3.1）

/**
 * soratomo.js の本文の module.exports の前に1行足した写しを、偽物の読み込みを入れた間だけ読み込み、その exports を返す。
 * soratomoCallable は公開していない（公開するのは関数の12本だけ）ので、本文に呼び出しを足して「読み込みの時点」の挙動を見る。
 * @param {string} extraLine 足す1行
 */
function loadSoratomoWith(extraLine) {
  const filename = path.join(__dirname, "soratomo.js");
  const source = fs.readFileSync(filename, "utf8");
  const marker = "\nmodule.exports = {";
  assert.equal(source.split(marker).length, 2, "module.exports の位置が1つに決まる");
  const probe = new Module(path.join(__dirname, "soratomo.probe.js"), module);
  probe.filename = probe.id;
  probe.paths = Module._nodeModulePaths(__dirname);
  Module._load = fakeLoad;
  try {
    probe._compile(source.replace(marker, `\n${extraLine}\n${marker}`), probe.filename);
  } finally {
    Module._load = originalLoad;
  }
  return probe.exports;
}

test("選択肢の名前の検査（public-launch 3.2）: soratomoCallable に知らない選択肢（1.14 期の requireFlag を含む）を渡すと、読み込みの時点で例外になる", () => {
  // 対照: 知っている選択肢だけなら、写しも読み込めて同じ12本を公開する（下の例外が、写しの読み込みの失敗でないことの確かめ）
  const probed = loadSoratomoWith('soratomoCallable("soratomoProbe", async () => ({}), { allowAnonymous: false });');
  assert.deepEqual(Object.keys(probed).sort(), Object.keys(fns).sort());

  for (const [options, unknownName] of [
    ["{ requireFlag: false }", "requireFlag"],
    ["{ requireFlag: true }", "requireFlag"],
    ["{ allowAnonymus: true }", "allowAnonymus"],
  ]) {
    assert.throws(
      () => loadSoratomoWith(`soratomoCallable("soratomoProbe", async () => ({}), ${options});`),
      (err) => err instanceof Error && err.message.includes(unknownName),
      options
    );
  }
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

test("参加（陽性対照C1・leave-group 2.1）: 片づけ中（写しが残り、メンバーの文書が無い）の人は failed-precondition（leave_pending）で、何も書かない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice"] });
  await agree("bob");
  const userRef = db.collection("soratomoUsers").doc("bob");
  await userRef.set({ groupCount: 1 }, { merge: true });
  await userRef.collection("groups").doc("g1").set({ groupId: "g1", joinedAt: Timestamp.now() });

  await assert.rejects(call("soratomoJoinGroup", authOf("bob"), { code: "SKYAAAAA" }), httpsError("failed-precondition", "leave_pending", {}));
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("memberCount"), 1);
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("members").get()).size, 1);
  assert.equal((await userRef.get()).get("groupCount"), 1);
  assert.ok(!allLogs().includes("SKYAAAAA"), "招待コードをログに出さない");
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

// MARK: - Callable: グループだけ抜ける（leave-group 3.1）

/** 抜けるの Callable の ok のログの項目。 */
function leaveOkLogs() {
  return logFieldsOf("soratomoLeaveGroup: ok");
}
/** gdel1 のメンバー（uid → 役割）。 */
async function delGroupRoles() {
  const snap = await db.collection("soratomoGroups").doc(DEL_GROUP).collection("members").get();
  return Object.fromEntries(snap.docs.map((d) => [d.id, d.get("role")]));
}

test("抜ける: ログインが無ければ unauthenticated で、何も消さない", async () => {
  await seedDeletionScene();
  await assert.rejects(call("soratomoLeaveGroup", undefined, { groupId: DEL_GROUP }), httpsError("unauthenticated"));
  assert.deepEqual(await delGroupRoles(), { alice: "owner", bob: "member" });
  assert.equal(storageFiles.size, 4);
  assert.deepEqual(leaveOkLogs(), []);
});

test("抜ける: クレームの無い登録済み・クレームが false の人・利用停止中の人・ガイドラインに未同意の人も抜けられ、応答は { done, groupDeleted } だけ（匿名は関門で拒否する・public-launch 3.1）", async () => {
  const cases = [
    ["クレーム無し（登録済み）", REGISTERED, async () => {}],
    ["クレームが false", { ...REGISTERED, soratomoBeta: false }, async () => {}],
    ["利用停止中", REGISTERED, (ref) => ref.update({ suspendedAt: Timestamp.now() })],
    ["ガイドラインに未同意", REGISTERED, (ref) => ref.set({ groupCount: 1 })],
  ];
  for (const [name, token, prepare] of cases) {
    await seedDeletionScene();
    const bobRef = db.collection("soratomoUsers").doc("bob");
    await prepare(bobRef);
    const groupRef = db.collection("soratomoGroups").doc(DEL_GROUP);

    const response = await call("soratomoLeaveGroup", authOf("bob", token), { groupId: DEL_GROUP });
    assert.deepEqual(response, { done: true, groupDeleted: false }, name);
    assert.deepEqual(await delGroupRoles(), { alice: "owner" }, `${name}: 本人が外れる`);
    assert.equal((await groupRef.get()).get("memberCount"), 1, name);
    assert.equal((await groupRef.collection("skies").doc("sb1").get()).exists, false, `${name}: 本人の投稿は消える`);
    assert.equal((await groupRef.collection("skies").doc("sa1").get()).exists, true, `${name}: ほかのメンバーの投稿は残る`);
    assert.deepEqual([...storageFiles].sort(), imagesOf("alice", "sa1").sort(), `${name}: 画像は本人の分だけ消える`);
    assert.equal((await bobRef.collection("groups").doc(DEL_GROUP).get()).exists, false, `${name}: 写しが消える`);
    assert.equal((await bobRef.get()).exists, true, `${name}: 利用者の文書は残る（退会と違う）`);
  }
});

test("抜ける: groupId が自動IDの形でなければ invalid-argument（invalid_input）で、何も書かない", async () => {
  await seedDeletionScene();
  for (const data of [{}, null, { groupId: "" }, { groupId: "g-1" }, { groupId: "a/b" }, { groupId: 123 }, { groupId: ["gdel1"] }]) {
    await assert.rejects(
      call("soratomoLeaveGroup", authOf("bob"), data),
      httpsError("invalid-argument", "invalid_input", {}),
      JSON.stringify(data)
    );
  }
  assert.deepEqual(await delGroupRoles(), { alice: "owner", bob: "member" });
  assert.equal(storageFiles.size, 4);
  assert.equal((await db.collection("soratomoPendingLeaves").get()).size, 0, "印を書かない");
  assert.deepEqual(record.logs.filter((l) => l.level === "error"), [], "想定外の失敗（internal）にしない");
});

test("抜ける: 本文に他人の uid を書いても、抜けるのは認証の uid だけ。メンバーでない人には { done: true, groupDeleted: false } で、何も変わらない", async () => {
  await seedDeletionScene();
  const groupRef = db.collection("soratomoGroups").doc(DEL_GROUP);

  // メンバーでない carol が alice を指定しても、何も変わらない（not_member も返さない）
  assert.deepEqual(await call("soratomoLeaveGroup", authOf("carol"), { groupId: DEL_GROUP, uid: "alice" }), { done: true, groupDeleted: false });
  assert.deepEqual(await delGroupRoles(), { alice: "owner", bob: "member" });
  assert.equal((await groupRef.get()).get("memberCount"), 2);
  assert.equal(storageFiles.size, 4);
  assert.equal((await db.collection("soratomoUsers").doc("carol").get()).exists, false, "メンバーでない人の文書を作らない");

  // メンバーの bob が alice を指定しても、抜けるのは bob
  assert.deepEqual(await call("soratomoLeaveGroup", authOf("bob"), { groupId: DEL_GROUP, uid: "alice" }), { done: true, groupDeleted: false });
  assert.deepEqual(await delGroupRoles(), { alice: "owner" });
  assert.equal((await groupRef.collection("skies").doc("sa1").get()).exists, true);
  assert.equal((await db.collection("soratomoUsers").doc("alice").collection("groups").doc(DEL_GROUP).get()).exists, true);
  assert.deepEqual([...storageFiles].sort(), imagesOf("alice", "sa1").sort());
  assert.deepEqual(leaveOkLogs().map((l) => l.uid), ["carol", "bob"]);
});

test("抜ける: 最後の1人なら groupDeleted: true。ログは内部IDと件数だけで、グループ名・表示名・キャプション・招待コードを出さない", async () => {
  await seedDeletionScene();
  await db.collection("users").doc("alice").set({ displayName: "そらのアリス" });

  assert.deepEqual(await call("soratomoLeaveGroup", authOf("bob"), { groupId: DEL_GROUP }), { done: true, groupDeleted: false });
  assert.deepEqual(await call("soratomoLeaveGroup", authOf("alice"), { groupId: DEL_GROUP }), { done: true, groupDeleted: true });
  assert.equal((await db.collection("soratomoGroups").doc(DEL_GROUP).get()).exists, false);
  assert.equal((await db.collection("soratomoInviteCodes").doc("SKYDELAA").get()).exists, false);
  assert.equal(storageFiles.size, 0);

  assert.deepEqual(leaveOkLogs(), [
    {
      uid: "bob", groupId: DEL_GROUP, done: true, state: "started", kind: "leave", removed: true,
      ownerTransferred: false, groupDeleted: false, skiesDeleted: 1, imagesDeleted: 2,
    },
    {
      uid: "alice", groupId: DEL_GROUP, done: true, state: "started", kind: "delete_group", removed: true,
      ownerTransferred: false, groupDeleted: true, skiesDeleted: 1, imagesDeleted: 2,
    },
  ]);
  const logs = allLogs();
  for (const secret of ["ひみつの空の会", "SKYDELAA", "夕焼けがきれい", "そらのアリス"]) {
    assert.ok(!logs.includes(secret), `ログに「${secret}」を出さない`);
  }
});

test("抜ける: 関数の設定は、制限時間120秒・メモリ512MiB・既存と同じリージョン。公開する関数は12本", () => {
  const endpoint = fns.soratomoLeaveGroup.__endpoint;
  assert.equal(endpoint.timeoutSeconds, 120);
  assert.equal(endpoint.availableMemoryMb, 512);
  assert.deepEqual(endpoint.region, ["asia-northeast1"]);
  assert.deepEqual(Object.keys(fns).sort(), [
    "onSoratomoReportCreated",
    "onSoratomoSkyCreated",
    "soratomoAgreeGuideline",
    "soratomoCreateGroup",
    "soratomoCreateSky",
    "soratomoDeleteMyData",
    "soratomoHousekeeping",
    "soratomoJoinGroup",
    "soratomoLeaveGroup",
    "soratomoRegenerateInviteCode",
    "soratomoReportSky",
    "soratomoSetReaction",
  ]);
});

// MARK: - トリガー: onSoratomoSkyCreated（8.2）

const OLD = Timestamp.fromMillis(Date.UTC(2026, 0, 1));
const MEMBERS = ["poster", "a", "b", "c", "d", "e", "f"];

/**
 * 宛先の分類を一通り含む場面を入れる。
 * a・b・f: 送る / c: 通知設定OFF / d: 投稿者をブロック / e: トークン無し / poster: 投稿者（宛先から除く）
 * b だけクレームが無い（1.14 期はフラグOFFで送らなかった。public-launch 1.3 から、クレームに関係なく送る）。
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
  claims = new Map(MEMBERS.map((uid) => [uid, uid === "b" ? {} : BETA_CLAIMS]));
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

test("トリガー: 投稿者を除いたメンバーを分類し、送れる宛先だけへ、まとめ指定つきで送る（クレームの無い宛先にも送る・宛先の絞り込みで Auth を読まない）", async () => {
  await seedScene();
  await postSky("s1");

  assert.deepEqual(record.sends.map((s) => s.uid).sort(), ["a", "b", "f"]);
  for (const s of record.sends) {
    assert.equal(s.token, `tok-${s.uid}`);
    assert.deepEqual(s.notification, { title: "ひみつの空の会", body: "ソラミさんが空を投稿しました「夕焼けがきれい」" });
    assert.deepEqual(s.data, { type: "soratomoPost", groupId: "g1", postId: "s1" });
    assert.deepEqual(s.grouping, { threadId: "soratomo-g1", collapseId: "soratomo-g1" });
  }
  assert.equal(record.getUsersCalls.length, 0, "宛先のクレームを Auth に問い合わせない（public-launch 1.3）");

  // 集計の形は 1.14 期と同じ（flagOff の項目は残し、いつも 0）
  assert.deepEqual(summaryLog(), {
    groupId: "g1",
    skyId: "s1",
    sent: 3,
    throttled: 0,
    duplicate: 0,
    noToken: 1,
    sendFailed: 0,
    prefOff: 1,
    blocked: 1,
    flagOff: 0,
  });
  const logs = allLogs();
  for (const secret of ["ひみつの空の会", "夕焼けがきれい", "ソラミ", "tok-", "SKYAAAAA"]) {
    assert.ok(!logs.includes(secret), `ログに「${secret}」を出さない`);
  }
});

test("トリガー: 同じ投稿の再配信は重複として送らず、5分以内の次の投稿は間引く", async () => {
  await seedScene();
  await postSky("s1");
  assert.equal(record.sends.length, 3);

  record.sends = [];
  record.logs = [];
  await runTrigger("s1");
  assert.equal(record.sends.length, 0);
  assert.equal(summaryLog().duplicate, 3);

  record.logs = [];
  await postSky("s2");
  assert.equal(record.sends.length, 0);
  assert.equal(summaryLog().throttled, 3);
});

test("トリガー: 1人の送信の失敗で残りを止めず、例外を投げずに終える", async () => {
  await seedScene();
  sendImpl = async (uid) => {
    if (uid === "a") throw new Error("送信の内部エラー");
    return "sent";
  };
  await postSky("s1");
  assert.deepEqual(record.sends.map((s) => s.uid).sort(), ["a", "b", "f"]);
  const summary = summaryLog();
  assert.equal(summary.sent, 2);
  assert.equal(summary.sendFailed, 1);
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("skies").doc("s1").get()).exists, true, "投稿は消さない");
});

test("トリガー: Auth が失敗していても、宛先の絞り込みは Auth を読まないので送る（public-launch 1.3）", async () => {
  await seedScene();
  getUsersImpl = async () => {
    throw new Error("auth の失敗");
  };
  await postSky("s1");
  assert.deepEqual(record.sends.map((s) => s.uid).sort(), ["a", "b", "f"]);
  assert.equal(record.getUsersCalls.length, 0);
  const summary = summaryLog();
  assert.equal(summary.sent, 3);
  assert.equal(summary.flagOff, 0);
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
  claims = new Map([["a", BETA_CLAIMS]]);
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

// MARK: - 定期実行: soratomoHousekeeping（release-gate 4.4）

/** 作成から ageMs 前の通報の記録を直接入れる（定期実行の仕事Bの対象を作る）。 */
async function seedReportRecord(reportId, { ageMs, forwardStatus = "pending" }) {
  await db.collection("soratomoReports").doc(reportId).set({
    groupId: "g1",
    skyId: "s1",
    authorId: "alice",
    reporterId: "bob",
    reason: "spam",
    createdAt: Timestamp.fromMillis(Date.now() - ageMs),
    forwardStatus,
    forwardAttempts: 0,
  });
}

/** 1人ぶんの所属（メンバーの文書・所属の写し・投稿1件と画像2枚）を入れる。withUserDoc が false なら利用者の文書を作らない。 */
async function seedMembership(uid, groupId, skyId, { withUserDoc = true } = {}) {
  const groupRef = db.collection("soratomoGroups").doc(groupId);
  const userRef = db.collection("soratomoUsers").doc(uid);
  const batch = db.batch();
  batch.set(groupRef.collection("skies").doc(skyId), { authorId: uid, width: 1, height: 1, createdAt: Timestamp.now() });
  if (withUserDoc) batch.set(userRef, { groupCount: 1, guidelineVersion: core.GUIDELINE_VERSION });
  batch.set(userRef.collection("groups").doc(groupId), { groupId, joinedAt: Timestamp.now() });
  await batch.commit();
  for (const name of ["display.jpg", "thumb.jpg"]) storageFiles.add(`soratomo/${groupId}/${uid}/${skyId}/${name}`);
}

/**
 * 仕事Aの場面。アカウントがあるのは alice（クレームあり）と erin（クレーム無し）だけ。
 * - gh1: オーナーの alice とメンバーの carol（アカウント無し）。2人とも投稿1件
 * - gh2: dave（アカウント無し）だけ。dave は利用者の文書が無く、所属の写しだけが残っている（文書の無い親）
 * - erin: 利用者の文書だけ / frank（アカウント無し）: 利用停止中の文書だけ（所属数0）
 */
async function seedSweepScene() {
  await seedGroup({ groupId: "gh1", ownerId: "alice", inviteCode: "SKYGHONE", memberIds: ["alice", "carol"] });
  await seedGroup({ groupId: "gh2", ownerId: "dave", inviteCode: "SKYGHTWO", memberIds: ["dave"] });
  await seedMembership("alice", "gh1", "sa1");
  await seedMembership("carol", "gh1", "sc1");
  await seedMembership("dave", "gh2", "sd1", { withUserDoc: false });
  await db.collection("soratomoUsers").doc("erin").set({ groupCount: 0, guidelineVersion: core.GUIDELINE_VERSION });
  await db.collection("soratomoUsers").doc("frank").set({ groupCount: 0, suspendedAt: Timestamp.now() });
  claims = new Map([
    ["alice", BETA_CLAIMS],
    ["erin", {}],
  ]);
}

function runHousekeeping() {
  return fns.soratomoHousekeeping.run({ scheduleTime: new Date().toISOString() });
}

const bySummaryUid = (a, b) => (a.uid < b.uid ? -1 : 1);

test("定期実行の仕事A: アカウントの無い人（文書の無い親・停止中を含む）だけを account_deleted で消し、1人ごとと実行ごとの要約を出す", async () => {
  await seedSweepScene();
  await runHousekeeping();

  // アカウントのある人は残る
  assert.equal((await db.collection("soratomoUsers").doc("alice").get()).exists, true);
  assert.equal((await db.collection("soratomoUsers").doc("erin").get()).exists, true);
  assert.equal((await db.collection("soratomoGroups").doc("gh1").collection("skies").doc("sa1").get()).exists, true);
  // アカウントの無い人は消える（carol: メンバーを外す / dave: 最後の1人なのでグループごと / frank: 停止中の文書も）
  assert.equal((await db.collection("soratomoUsers").doc("carol").get()).exists, false);
  assert.equal((await db.collection("soratomoGroups").doc("gh1").collection("skies").doc("sc1").get()).exists, false);
  const gh1 = (await db.collection("soratomoGroups").doc("gh1").get()).data();
  assert.equal(gh1.memberCount, 1);
  assert.equal(gh1.ownerId, "alice");
  assert.equal((await db.collection("soratomoGroups").doc("gh2").get()).exists, false);
  assert.equal((await db.collection("soratomoUsers").doc("dave").collection("groups").get()).size, 0);
  assert.equal((await db.collection("soratomoUsers").doc("frank").get()).exists, false, "停止中でもアカウントが無ければ文書ごと消す（要件2.3）");
  assert.deepEqual([...storageFiles].sort(), ["soratomo/gh1/alice/sa1/display.jpg", "soratomo/gh1/alice/sa1/thumb.jpg"]);

  assert.deepEqual([...record.getUsersCalls[0]].sort(), ["alice", "carol", "dave", "erin", "frank"]);
  const zero = { skiesDeleted: 0, imagesDeleted: 0, groupsLeft: 0, ownersTransferred: 0, groupsDeleted: 0 };
  assert.deepEqual(logFieldsOf("soratomoDeletion: summary").sort(bySummaryUid), [
    { uid: "carol", trigger: "account_deleted", done: true, ...zero, skiesDeleted: 1, imagesDeleted: 2, groupsLeft: 1 },
    { uid: "dave", trigger: "account_deleted", done: true, ...zero, skiesDeleted: 1, imagesDeleted: 2, groupsLeft: 1, groupsDeleted: 1 },
    { uid: "frank", trigger: "account_deleted", done: true, ...zero },
  ]);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: sweep"), [{ scanned: 5, missingAuth: 3, completed: 3, unfinished: 0 }]);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: reforward"), [{ attempted: 0, sent: 0 }]);
});

test("定期実行の仕事A: 問い合わせが失敗した組は何も消さない（失敗を「アカウントが無い」と読まない）。仕事Bは続ける", async () => {
  await seedSweepScene();
  await seedReportRecord("rold", { ageMs: 11 * 60 * 1000 });
  getUsersImpl = async () => {
    throw new Error("auth の失敗");
  };
  await runHousekeeping();

  for (const uid of ["alice", "carol", "erin", "frank"]) {
    assert.equal((await db.collection("soratomoUsers").doc(uid).get()).exists, true, `${uid} の文書は残る`);
  }
  assert.equal((await db.collection("soratomoGroups").doc("gh2").get()).exists, true);
  assert.equal(storageFiles.size, 6);
  assert.deepEqual(logFieldsOf("soratomoDeletion: summary"), []);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: sweep"), [{ scanned: 0, missingAuth: 0, completed: 0, unfinished: 0 }]);
  assert.equal(logFieldsOf("soratomoHousekeeping: lookup_failed")[0].count, 5);
  assert.equal(record.webhooks.length, 1, "仕事Bは止まらない");
});

test("定期実行の仕事B: 作成から10分を過ぎた未送信の通報だけを送り直し、10分未満と送信済みは送らない", async () => {
  await seedReportRecord("rold", { ageMs: 11 * 60 * 1000 });
  await seedReportRecord("rnew", { ageMs: 60 * 1000 });
  await seedReportRecord("rsent", { ageMs: 11 * 60 * 1000, forwardStatus: "sent" });
  await runHousekeeping();

  assert.equal(record.webhooks.length, 1);
  assert.ok(JSON.stringify(record.webhooks[0].body).includes("rold"));
  assert.equal((await db.collection("soratomoReports").doc("rold").get()).get("forwardStatus"), "sent");
  assert.equal((await db.collection("soratomoReports").doc("rnew").get()).get("forwardStatus"), "pending");
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: reforward"), [{ attempted: 1, sent: 1 }]);
});

test("定期実行: 仕事Aが例外で止まっても、仕事Bは動く", async () => {
  await seedReportRecord("rold", { ageMs: 11 * 60 * 1000 });
  const originalCollection = db.collection;
  // soratomo.js も同じ Firestore（既定のアプリ）を使うので、ここで差し替えると仕事Aの一覧が失敗する
  db.collection = function (name) {
    if (name === "soratomoUsers") return { listDocuments: async () => Promise.reject(new Error("一覧の失敗")) };
    return originalCollection.call(this, name);
  };
  try {
    await runHousekeeping();
  } finally {
    db.collection = originalCollection;
  }
  assert.equal(logFieldsOf("soratomoHousekeeping: sweep_failed").length, 1);
  assert.equal(record.webhooks.length, 1, "仕事Bは止まらない");
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: reforward"), [{ attempted: 1, sent: 1 }]);
});

test("定期実行: 6時間ごと・制限時間540秒・メモリ512MiB・同時に1つ・通報の送り先の秘密の値を渡す", () => {
  const endpoint = fns.soratomoHousekeeping.__endpoint;
  assert.equal(endpoint.scheduleTrigger.schedule, "every 6 hours");
  assert.equal(endpoint.timeoutSeconds, 540);
  assert.equal(endpoint.availableMemoryMb, 512);
  assert.equal(endpoint.maxInstances, 1);
  assert.deepEqual(endpoint.secretEnvironmentVariables, [{ key: "DISCORD_REPORT_WEBHOOK_URL" }]);
  assert.deepEqual(endpoint.region, ["asia-northeast1"]);
});

// MARK: - 定期実行の仕事C: 途中で止まった抜けるを終える（leave-group 3.2）

const MINUTE = 60 * 1000;
const LEAVE_SECRETS = Object.freeze(["ひみつの抜ける会", "SKYLEAVA", "SKYLEAVB", "ひみつのキャプション", "そらのボブ"]);

/**
 * 抜けるの途中で止まった人を入れる。groupId のグループ（オーナーは owner）から uid が外れた後で、片づけ中の印（leftAt は
 * ageMs 前）・所属の写し・利用者の文書・投稿1件（キャプションつき）と画像2枚が残っている。
 * member が真なら、入り直した後（メンバーの文書がある・印だけが古いまま残った）。
 */
async function seedPendingLeave({ uid, groupId, owner, code, ageMs, member = false }) {
  await seedGroup({ groupId, ownerId: owner, inviteCode: code, memberIds: member ? [owner, uid] : [owner], name: "ひみつの抜ける会" });
  await seedMembership(uid, groupId, `s${uid}`);
  await db.collection("soratomoGroups").doc(groupId).collection("skies").doc(`s${uid}`).update({ caption: "ひみつのキャプション" });
  await db.collection("soratomoPendingLeaves").doc(`${uid}_${groupId}`).set({ uid, groupId, episodeId: "e1", leftAt: Timestamp.fromMillis(Date.now() - ageMs) });
}
/** 印・写し・投稿・画像が残っているか。 */
async function leaveLeftovers(uid, groupId) {
  return {
    marker: (await db.collection("soratomoPendingLeaves").doc(`${uid}_${groupId}`).get()).exists,
    copy: (await db.collection("soratomoUsers").doc(uid).collection("groups").doc(groupId).get()).exists,
    sky: (await db.collection("soratomoGroups").doc(groupId).collection("skies").doc(`s${uid}`).get()).exists,
    images: [...storageFiles].filter((p) => p.startsWith(`soratomo/${groupId}/${uid}/`)).length,
  };
}
/** swept のログから、実行のたびに変わる ageMs を外して返す（ageMs は別に確かめる）。 */
function sweptLogs() {
  return logFieldsOf("soratomoLeave: swept").map(({ ageMs, ...rest }) => rest);
}

test("定期実行の仕事C: 確定から30分を過ぎた印を sweep で終えて swept を出し、30分より新しい印には触らない。仕事Aより先に動き、ログに名前などを出さない", async () => {
  await seedPendingLeave({ uid: "bob", groupId: "gl1", owner: "alice", code: "SKYLEAVA", ageMs: 31 * MINUTE });
  await seedPendingLeave({ uid: "carl", groupId: "gl2", owner: "alice", code: "SKYLEAVB", ageMs: 5 * MINUTE });
  await db.collection("users").doc("bob").set({ displayName: "そらのボブ" });
  claims = new Map([["alice", BETA_CLAIMS], ["bob", BETA_CLAIMS], ["carl", {}]]); // 仕事Aに消されないよう、アカウントはある

  await runHousekeeping();

  assert.deepEqual(await leaveLeftovers("bob", "gl1"), { marker: false, copy: false, sky: false, images: 0 }, "30分を過ぎた印は終える");
  assert.equal((await db.collection("soratomoUsers").doc("bob").get()).get("groupCount"), 0);
  assert.deepEqual(await leaveLeftovers("carl", "gl2"), { marker: true, copy: true, sky: true, images: 2 }, "30分より新しい印には触らない");
  assert.deepEqual(sweptLogs(), [
    {
      uid: "bob", groupId: "gl1", done: true, state: "continued", kind: "leave", removed: false,
      ownerTransferred: false, groupDeleted: false, skiesDeleted: 1, imagesDeleted: 2,
    },
  ]);
  const ageMs = logFieldsOf("soratomoLeave: swept")[0].ageMs;
  assert.ok(ageMs >= 31 * MINUTE && ageMs < 40 * MINUTE, `ageMs は確定からの時間（${ageMs}）`);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: leave_sweep"), [
    { scanned: 1, completed: 1, unfinished: 0, overdue: 0, malformed: 0, failed: 0 },
  ]);
  const order = record.logs.map((l) => l.args[0]);
  assert.ok(
    order.indexOf("soratomoHousekeeping: leave_sweep") < order.indexOf("soratomoHousekeeping: sweep"),
    "仕事Cは仕事Aより先に動く"
  );
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: sweep"), [{ scanned: 2, missingAuth: 0, completed: 0, unfinished: 0 }]);
  const logs = allLogs();
  for (const secret of LEAVE_SECRETS) assert.ok(!logs.includes(secret), `ログに「${secret}」を出さない`);
});

test("定期実行の仕事C（陽性対照C2のサーバー版）: 入り直した後の古い印は、印だけを消してメンバーを外さない（stale_marker）", async () => {
  await seedPendingLeave({ uid: "bob", groupId: "gl1", owner: "alice", code: "SKYLEAVA", ageMs: 31 * MINUTE, member: true });
  claims = new Map([["alice", BETA_CLAIMS], ["bob", BETA_CLAIMS]]);

  await runHousekeeping();

  const groupRef = db.collection("soratomoGroups").doc("gl1");
  assert.equal((await groupRef.collection("members").doc("bob").get()).exists, true, "入り直したメンバーを外し直さない（8.6）");
  assert.equal((await groupRef.get()).get("memberCount"), 2);
  assert.deepEqual(await leaveLeftovers("bob", "gl1"), { marker: false, copy: true, sky: true, images: 2 }, "印だけが消える");
  assert.equal((await db.collection("soratomoUsers").doc("bob").get()).get("groupCount"), 1);
  assert.deepEqual(sweptLogs(), [
    {
      uid: "bob", groupId: "gl1", done: true, state: "stale_marker", kind: null, removed: false,
      ownerTransferred: false, groupDeleted: false, skiesDeleted: 0, imagesDeleted: 0,
    },
  ]);
});

test("定期実行の仕事C: 24時間を過ぎて終わらない（失敗した）ものに overdue と sweep_item_failed を出し、印と写しを残す。次の実行で終える", async () => {
  await seedPendingLeave({ uid: "bob", groupId: "gl1", owner: "alice", code: "SKYLEAVA", ageMs: 25 * 60 * MINUTE });
  claims = new Map([["alice", BETA_CLAIMS], ["bob", BETA_CLAIMS]]);
  const originalDelete = fakeStorageGateway.deleteFile;
  fakeStorageGateway.deleteFile = async () => {
    throw new Error("偽物: 画像の削除の失敗");
  };
  try {
    await runHousekeeping();
  } finally {
    fakeStorageGateway.deleteFile = originalDelete;
  }

  const left = await leaveLeftovers("bob", "gl1");
  assert.equal(left.marker, true, "印が残る（次の実行が拾う）");
  assert.equal(left.copy, true, "写しが残る");
  const failed = logFieldsOf("soratomoLeave: sweep_item_failed");
  assert.equal(failed.length, 1);
  assert.equal(failed[0].uid, "bob");
  assert.equal(failed[0].groupId, "gl1");
  assert.equal(failed[0].errorName, "Error");
  const overdue = logFieldsOf("soratomoLeave: overdue");
  assert.equal(overdue.length, 1);
  assert.deepEqual(Object.keys(overdue[0]).sort(), ["ageMs", "groupId", "uid"]);
  assert.ok(overdue[0].ageMs > 24 * 60 * MINUTE);
  assert.equal(record.logs.find((l) => l.args[0] === "soratomoLeave: overdue").level, "warn");
  assert.equal(record.logs.find((l) => l.args[0] === "soratomoLeave: sweep_item_failed").level, "error");
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: leave_sweep"), [
    { scanned: 1, completed: 0, unfinished: 0, overdue: 1, malformed: 0, failed: 1 },
  ]);

  // ゲートウェイが直った後の次の実行で終える
  record.logs = [];
  await runHousekeeping();
  assert.deepEqual(await leaveLeftovers("bob", "gl1"), { marker: false, copy: false, sky: false, images: 0 });
  assert.equal(sweptLogs()[0].done, true);
  assert.deepEqual(logFieldsOf("soratomoLeave: overdue"), []);
});

test("定期実行の仕事C: 形の違う印は消さずに飛ばして malformed_marker を出し、ほかには触らない", async () => {
  const old = Timestamp.fromMillis(Date.now() - 31 * MINUTE);
  const markers = {
    bad1: { uid: "bob", groupId: "gl1" }, // 文書IDが「uid_groupId」でない
    "bob_gl-1": { uid: "bob", groupId: "gl-1" }, // groupId が自動IDの形でない
    "a_gl1": { uid: "a/b", groupId: "gl1" }, // uid に「/」
    nouid_gl1: { groupId: "gl1" }, // uid が無い
  };
  for (const [id, fields] of Object.entries(markers)) {
    await db.collection("soratomoPendingLeaves").doc(id).set({ ...fields, episodeId: "e1", leftAt: old });
  }
  await seedGroup({ groupId: "gl1", ownerId: "alice", inviteCode: "SKYLEAVA", memberIds: ["alice", "bob"], name: "ひみつの抜ける会" });

  await runHousekeeping();

  assert.deepEqual(logFieldsOf("soratomoLeave: malformed_marker").map((f) => f.markerId).sort(), Object.keys(markers).sort());
  assert.equal(record.logs.find((l) => l.args[0] === "soratomoLeave: malformed_marker").level, "warn");
  assert.equal((await db.collection("soratomoPendingLeaves").get()).size, 4, "消さない（開発者が確かめる）");
  assert.equal((await db.collection("soratomoGroups").doc("gl1").collection("members").doc("bob").get()).exists, true);
  assert.deepEqual(sweptLogs(), []);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: leave_sweep"), [
    { scanned: 4, completed: 0, unfinished: 0, overdue: 0, malformed: 4, failed: 0 },
  ]);
});

test("定期実行: 仕事Cが例外で止まっても、仕事Aと仕事Bは動く", async () => {
  await seedSweepScene();
  await seedReportRecord("rold", { ageMs: 11 * MINUTE });
  const originalCollection = db.collection;
  db.collection = function (name) {
    if (name === "soratomoPendingLeaves") {
      return {
        where: () => {
          throw new Error("クエリの失敗");
        },
      };
    }
    return originalCollection.call(this, name);
  };
  try {
    await runHousekeeping();
  } finally {
    db.collection = originalCollection;
  }
  assert.equal(logFieldsOf("soratomoHousekeeping: leave_sweep_failed").length, 1);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: leave_sweep"), []);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: sweep"), [{ scanned: 5, missingAuth: 3, completed: 3, unfinished: 0 }], "仕事Aは動く");
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: reforward"), [{ attempted: 1, sent: 1 }], "仕事Bは動く");
});

// MARK: - Callable の拒否と要確認6（release-gate 4.5）

test("退会: 要求の本文に他人の uid を書いても、消すのは認証の uid だけ（要件3.5）", async () => {
  await seedDeletionScene();
  const groupRef = db.collection("soratomoGroups").doc(DEL_GROUP);

  // そらともを使っていない carol が alice を指定しても、carol の空振りで終わる
  assert.deepEqual(await call("soratomoDeleteMyData", authOf("carol", {}), { uid: "alice", targetUid: "alice" }), { done: true });
  // メンバーの bob が alice を指定しても、消えるのは bob だけ
  assert.deepEqual(await call("soratomoDeleteMyData", authOf("bob", {}), { uid: "alice" }), { done: true });

  assert.equal((await db.collection("soratomoUsers").doc("alice").get()).exists, true);
  assert.equal((await groupRef.collection("skies").doc("sa1").get()).exists, true);
  assert.equal((await groupRef.collection("members").doc("alice").get()).exists, true);
  assert.equal((await db.collection("soratomoUsers").doc("bob").get()).exists, false);
  assert.equal((await groupRef.collection("skies").doc("sb1").get()).exists, false);
  assert.deepEqual([...storageFiles].sort(), imagesOf("alice", "sa1").sort());
  assert.deepEqual(
    deleteOkLogs().map((l) => l.uid),
    ["carol", "bob"]
  );
});

test("投稿: メンバーでない人は not_member、停止中の人は suspended、入力の誤りは invalid_input で、どれも作らない。投稿者は認証の uid", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "carol"] });
  await db.collection("soratomoUsers").doc("carol").set({ suspendedAt: Timestamp.now(), groupCount: 0 });
  const valid = { groupId: "g1", skyId: "s1", caption: "夕焼けがきれい", width: 1080, height: 1440 };

  await assert.rejects(call("soratomoCreateSky", authOf("bob"), valid), httpsError("permission-denied", "not_member", {}));
  await assert.rejects(call("soratomoCreateSky", authOf("carol"), valid), httpsError("permission-denied", "suspended", {}));
  const invalids = [
    { ...valid, width: 0 },
    { ...valid, height: 2049 },
    { ...valid, width: 1.5 },
    { ...valid, caption: "" },
    { ...valid, caption: "改行\nあり" },
    { ...valid, caption: "あ".repeat(101) },
    { ...valid, skyId: undefined },
    { ...valid, groupId: "g/1" },
  ];
  for (const input of invalids) {
    await assert.rejects(call("soratomoCreateSky", authOf("alice"), input), httpsError("invalid-argument", "invalid_input", {}));
  }
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("skies").get()).size, 0, "拒否では作らない");

  // 要求に投稿者を書いても、投稿者は認証の uid になる
  await call("soratomoCreateSky", authOf("alice"), { ...valid, authorId: "carol" });
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("skies").doc("s1").get()).get("authorId"), "alice");
});

test("語のリスト: 一度も読めていなければ、投稿と作成は internal で何も作らない。入力の誤りは語のリストより先に invalid_input、参加は通る", async () => {
  await seedGroup({ groupId: "g1", ownerId: "owner", inviteCode: "SKYAAAAA", memberIds: ["owner", "alice"] });
  await agree("alice", "bob");
  await db.collection("soratomoConfig").doc("ngWords").delete();
  ngWordsOverride = realCreateNgWordProvider({ db });

  await assert.rejects(
    call("soratomoCreateSky", authOf("alice"), { groupId: "g1", skyId: "s1", width: 1, height: 1 }),
    httpsError("internal")
  );
  await assert.rejects(
    call("soratomoCreateSky", authOf("alice"), { groupId: "g1", skyId: "s1", width: 0, height: 1 }),
    httpsError("invalid-argument", "invalid_input", {})
  );
  await assert.rejects(call("soratomoCreateGroup", authOf("alice"), { name: "空の会", requestId: "r1" }), httpsError("internal"));
  assert.deepEqual(await call("soratomoJoinGroup", authOf("bob"), { code: "SKYAAAAA" }), { groupId: "g1", alreadyMember: false });

  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("skies").get()).size, 0);
  assert.equal((await db.collection("soratomoGroups").get()).size, 1);
  assert.equal(logFieldsOf("soratomoCreateSky: internal").length, 1);
});

test("通報: メンバーでない（not_member）・投稿が無い（sky_not_found）・自分の投稿（self_report）・理由の誤り（invalid_reason）・ID の形の誤り（invalid_input）は、記録を作らない", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  await db
    .collection("soratomoGroups")
    .doc("g1")
    .collection("skies")
    .doc("s1")
    .set({ authorId: "alice", width: 1, height: 1, createdAt: Timestamp.now() });
  const input = { groupId: "g1", skyId: "s1", reason: "spam" };

  await assert.rejects(call("soratomoReportSky", authOf("carol"), input), httpsError("permission-denied", "not_member", {}));
  await assert.rejects(
    call("soratomoReportSky", authOf("bob"), { ...input, skyId: "s9" }),
    httpsError("not-found", "sky_not_found", {})
  );
  await assert.rejects(call("soratomoReportSky", authOf("alice"), input), httpsError("failed-precondition", "self_report", {}));
  for (const reason of ["abuse", undefined, "SPAM"]) {
    await assert.rejects(
      call("soratomoReportSky", authOf("bob"), { ...input, reason }),
      httpsError("invalid-argument", "invalid_reason", {})
    );
  }
  await assert.rejects(
    call("soratomoReportSky", authOf("bob"), { ...input, groupId: "g/1" }),
    httpsError("invalid-argument", "invalid_input", {})
  );
  assert.equal((await db.collection("soratomoReports").get()).size, 0);
});

test("通報: 通報者は認証の uid、投稿者は投稿の文書から取り、要求に書いた値を使わない（要件6.2・6.8）。記録は8項目だけ", async () => {
  await seedGroup({ groupId: "g1", ownerId: "alice", inviteCode: "SKYAAAAA", memberIds: ["alice", "bob"] });
  await db
    .collection("soratomoGroups")
    .doc("g1")
    .collection("skies")
    .doc("s1")
    .set({ authorId: "alice", caption: "夕焼けがきれい", width: 1, height: 1, createdAt: Timestamp.now() });

  await call("soratomoReportSky", authOf("bob"), { groupId: "g1", skyId: "s1", reason: "other", reporterId: "mallory", authorId: "eve" });
  const reports = await db.collection("soratomoReports").get();
  assert.equal(reports.size, 1);
  assert.equal(reports.docs[0].id, core.reportDocId("g1", "s1", "bob"));
  const report = reports.docs[0].data();
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
  assert.equal(report.reporterId, "bob");
  assert.equal(report.authorId, "alice");
});

test("同意: 版が整数でなければ invalid-argument（invalid_input）、新しすぎる版も outdated_guideline で、何も書かない", async () => {
  for (const version of ["1", 1.5, undefined, null]) {
    await assert.rejects(
      call("soratomoAgreeGuideline", authOf("alice"), { version }),
      httpsError("invalid-argument", "invalid_input", {})
    );
  }
  await assert.rejects(
    call("soratomoAgreeGuideline", authOf("alice"), { version: core.GUIDELINE_VERSION + 1 }),
    httpsError("failed-precondition", "outdated_guideline", { currentVersion: core.GUIDELINE_VERSION })
  );
  assert.equal((await db.collection("soratomoUsers").doc("alice").get()).exists, false);
});

test("要確認6: Callable で作った投稿でも、新着通知の宛先・本文・まとめ指定・集計と、グループの最新の活動時刻の更新は、クライアントが作った投稿と同じ", async () => {
  // 比べる相手は「トリガー: 投稿者を除いたメンバーを分類し…」（クライアントが文書を直接作った形・postSky）の期待値
  await seedScene();
  assert.deepEqual(
    await call("soratomoCreateSky", authOf("poster"), { groupId: "g1", skyId: "s1", caption: "夕焼けがきれい", width: 1080, height: 1440 }),
    { skyId: "s1", created: true }
  );
  record.logs = [];
  await runTrigger("s1");

  assert.deepEqual(record.sends.map((s) => s.uid).sort(), ["a", "b", "f"]);
  for (const s of record.sends) {
    assert.equal(s.token, `tok-${s.uid}`);
    assert.deepEqual(s.notification, { title: "ひみつの空の会", body: "ソラミさんが空を投稿しました「夕焼けがきれい」" });
    assert.deepEqual(s.data, { type: "soratomoPost", groupId: "g1", postId: "s1" });
    assert.deepEqual(s.grouping, { threadId: "soratomo-g1", collapseId: "soratomo-g1" });
  }
  assert.deepEqual(summaryLog(), {
    groupId: "g1",
    skyId: "s1",
    sent: 3,
    throttled: 0,
    duplicate: 0,
    noToken: 1,
    sendFailed: 0,
    prefOff: 1,
    blocked: 1,
    flagOff: 0,
  });
  const createdAt = (await db.collection("soratomoGroups").doc("g1").collection("skies").doc("s1").get()).get("createdAt");
  assert.ok(createdAt instanceof Timestamp, "Callable の作成日時もサーバーの時刻（Timestamp）");
  assert.ok(createdAt.toMillis() > OLD.toMillis());
  assert.equal((await db.collection("soratomoGroups").doc("g1").get()).get("lastActivityAt").toMillis(), createdAt.toMillis());
});

// MARK: - 定期実行の仕事Aの組（release-gate 4.6）

test("定期実行の仕事A: 100件ずつ問い合わせ、失敗した組だけを飛ばす（ほかの組のアカウントの無い人は消す）", async () => {
  // アカウントの無い150人（利用者の文書だけ）。1回目の問い合わせ（100人）だけ失敗させる
  const uids = Array.from({ length: 150 }, (_, i) => `u${String(i).padStart(3, "0")}`);
  for (let i = 0; i < uids.length; i += 100) {
    const batch = db.batch();
    for (const uid of uids.slice(i, i + 100)) batch.set(db.collection("soratomoUsers").doc(uid), { groupCount: 0 });
    await batch.commit();
  }
  let lookups = 0;
  getUsersImpl = async (identifiers) => {
    lookups += 1;
    if (lookups === 1) throw new Error("auth の失敗");
    return { users: [], notFound: identifiers };
  };
  await runHousekeeping();

  assert.deepEqual(
    record.getUsersCalls.map((c) => c.length),
    [100, 50]
  );
  const [failedBatch, okBatch] = record.getUsersCalls;
  const remaining = new Set((await db.collection("soratomoUsers").get()).docs.map((d) => d.id));
  assert.deepEqual([...remaining].sort(), [...failedBatch].sort(), "失敗した組の人だけが残る");
  for (const uid of okBatch) assert.ok(!remaining.has(uid), `${uid} は消える`);
  assert.deepEqual(logFieldsOf("soratomoHousekeeping: sweep"), [{ scanned: 50, missingAuth: 50, completed: 50, unfinished: 0 }]);
  assert.equal(logFieldsOf("soratomoHousekeeping: lookup_failed")[0].count, 100);
});

// MARK: - Callable: リアクション（soratomo-reactions 3.1）

/**
 * リアクションの場面: グループ g1（名前・招待コードあり）に、投稿者 poster・付ける人 a・ほかのメンバー b。
 * 投稿 s1 は poster のもの（キャプションあり）。users は poster（表示名・トークン・そらとも通知は未保存）・
 * a（表示名・トークン）・b（表示名・トークン）。
 * ⚠️ 投稿者への通知の間引きの記録（reactionNotifyState/poster）と送った印（reactionNotices/s1）は各テストの前にしか消えない。
 *    1つのテストの中で「送った」を2回期待するときは、resetReactionNotifyRecords で消すか、時刻を戻す。
 */
const REACTION_GROUP = "g1";
async function seedReactionScene() {
  await seedGroup({ groupId: REACTION_GROUP, ownerId: "poster", inviteCode: "SKYAAAAA", memberIds: ["poster", "a", "b"], name: "ひみつの空の会" });
  const batch = db.batch();
  batch.set(db.collection("soratomoGroups").doc(REACTION_GROUP).collection("skies").doc("s1"), {
    authorId: "poster",
    caption: "夕焼けがきれい",
    width: 1080,
    height: 1440,
    createdAt: Timestamp.now(),
  });
  batch.set(db.collection("users").doc("poster"), { displayName: "ソラミ", fcmToken: "tok-poster" });
  batch.set(db.collection("users").doc("a"), { displayName: "そらのアリス", fcmToken: "tok-a" });
  batch.set(db.collection("users").doc("b"), { displayName: "そらのボブ", fcmToken: "tok-b" });
  await batch.commit();
}

/** uid が投稿（既定は s1）に kind を付ける（null なら外す）。 */
function react(uid, kind, skyId = "s1") {
  return call("soratomoSetReaction", authOf(uid), { groupId: REACTION_GROUP, skyId, kind });
}

/** リアクションの Callable の ok のログの項目。 */
function reactionOkLogs() {
  return logFieldsOf("soratomoSetReaction: ok");
}

/** g1 の投稿の文書の中身。 */
async function reactionSky(skyId = "s1") {
  return (await db.collection("soratomoGroups").doc(REACTION_GROUP).collection("skies").doc(skyId).get()).data();
}

/** g1 のサブコレクションの文書の数（reactionNotices・reactionNotifyState・notifyState など）。 */
async function reactionGroupDocs(collection) {
  return (await db.collection("soratomoGroups").doc(REACTION_GROUP).collection(collection).get()).size;
}

/** poster への通知の間引きの記録と、s1 の送った印を消す（1つのテストの中で、もう一度「送った」を見るため）。 */
async function resetReactionNotifyRecords() {
  const groupRef = db.collection("soratomoGroups").doc(REACTION_GROUP);
  await groupRef.collection("reactionNotifyState").doc("poster").delete();
  await groupRef.collection("reactionNotices").doc("s1").delete();
}

/** poster への最後のリアクションの通知を msAgo ミリ秒前にする（5分を過ぎた形を作る）。 */
async function setReactionLastSentAt(msAgo) {
  await db
    .collection("soratomoGroups")
    .doc(REACTION_GROUP)
    .collection("reactionNotifyState")
    .doc("poster")
    .set({ lastSentAt: Timestamp.fromMillis(Date.now() - msAgo) });
}

/** 絵文字をコードポイントの数値から作る（期待値を実装の表から作らない。U+FE0F が両方から落ちても緑のままにしないため）。 */
const emojiOf = (...codePoints) => String.fromCodePoint(...codePoints);
const SUNSET = emojiOf(0x1f305);
const CLOUD = emojiOf(0x2601, 0xfe0f);
const EYES = emojiOf(0x1f440);
const TEN_MINUTES_MS = 10 * 60 * 1000;

/** リアクションの場面で、ログに出してはいけない値（グループ名・表示名・キャプション・招待コード・トークン）。 */
const REACTION_SECRETS = ["ひみつの空の会", "ソラミ", "そらのアリス", "そらのボブ", "夕焼けがきれい", "SKYAAAAA", "tok-"];

test("リアクション（4.15・14.3）: 付ける・選び直す・同じもの・外す・無いものを外すの応答は { outcome, kind } だけ（投稿者の uid を返さない）。成功のログは uid・groupId・skyId・outcome・kind・notify だけで、送らなかったときの notify は null", async () => {
  await seedReactionScene();
  const steps = [
    ["sunset", { outcome: "added", kind: "sunset" }, "sent"],
    ["cloud", { outcome: "replaced", kind: "cloud" }, null],
    ["cloud", { outcome: "unchanged", kind: "cloud" }, null],
    [null, { outcome: "removed", kind: null }, null],
    [null, { outcome: "unchanged", kind: null }, null],
  ];
  for (const [kind, expected] of steps) {
    assert.deepEqual(await react("a", kind), expected, JSON.stringify(kind));
  }
  assert.deepEqual(
    reactionOkLogs(),
    steps.map(([, expected, notify]) => ({ uid: "a", groupId: "g1", skyId: "s1", outcome: expected.outcome, kind: expected.kind, notify }))
  );
  const sky = await reactionSky();
  assert.deepEqual(sky.reactions, {}, "外した後は本人のキーが無い");
  assert.deepEqual(sky.reactorIds, []);
});

test("リアクション（4.1〜4.6・4.11・4.15）: メンバーでない・投稿が無い・自分の投稿（外す要求も）・7種類にない値・利用停止・入力の誤りは、それぞれ決めた code と details.reason（理由だけ）で、何も書かず、だれにも送らない", async () => {
  await seedReactionScene();
  await db.collection("soratomoUsers").doc("b").set({ suspendedAt: Timestamp.now() });
  const valid = { groupId: "g1", skyId: "s1", kind: "sunset" };
  const cases = [
    ["メンバーでない", "carol", valid, "permission-denied", "not_member"],
    ["投稿が無い", "a", { ...valid, skyId: "s9" }, "not-found", "sky_not_found"],
    ["自分の投稿に付ける", "poster", valid, "failed-precondition", "self_reaction"],
    ["自分の投稿から外す", "poster", { ...valid, kind: null }, "failed-precondition", "self_reaction"],
    ["絵文字そのもの", "a", { ...valid, kind: CLOUD }, "invalid-argument", "invalid_reaction"],
    ["FE0F の無い形", "a", { ...valid, kind: emojiOf(0x2601) }, "invalid-argument", "invalid_reaction"],
    ["大文字", "a", { ...valid, kind: "Sunset" }, "invalid-argument", "invalid_reaction"],
    ["知らない名前", "a", { ...valid, kind: "thumbs_up" }, "invalid-argument", "invalid_reaction"],
    ["利用停止", "b", valid, "permission-denied", "suspended"],
    ["kind の鍵が無い", "a", { groupId: "g1", skyId: "s1" }, "invalid-argument", "invalid_input"],
    ["groupId の形の誤り", "a", { ...valid, groupId: "g/1" }, "invalid-argument", "invalid_input"],
    ["本文が無い", "a", null, "invalid-argument", "invalid_input"],
  ];
  for (const [name, uid, data, code, reason] of cases) {
    await assert.rejects(call("soratomoSetReaction", authOf(uid), data), httpsError(code, reason, {}), name);
  }

  const sky = await reactionSky();
  assert.equal(sky.reactions, undefined, "リアクションを書かない");
  assert.equal(sky.reactorIds, undefined);
  assert.deepEqual(record.sends, [], "だれにも送らない");
  assert.equal(await reactionGroupDocs("reactionNotices"), 0);
  assert.equal(await reactionGroupDocs("reactionNotifyState"), 0);
  assert.deepEqual(reactionOkLogs(), []);
  assert.deepEqual(
    logFieldsOf("soratomoSetReaction: rejected").map((f) => f.reason),
    cases.map((c) => c[4])
  );
  assert.deepEqual(record.logs.filter((l) => l.level === "error"), [], "想定外の失敗（internal）にしない");
});

test("リアクション（6.1〜6.4・6.9〜6.14・11.3・12.4）: 新しく付けたら投稿者へだけ1通（そらとも通知が未保存なら ON）。題はグループ名・本文は表示名と絵文字でキャプションなし・data は soratomoReaction・スレッドはグループごと・置き換えキーは新着投稿と別。要求に書いた uid は使わず、既存のほかの通知の送信と新着投稿の間引きの記録は使わない。ログに名前などを出さない", async () => {
  await seedReactionScene();
  // 要求に別の uid や投稿者を書いても、付けるのは認証の uid、送り先は投稿の文書の投稿者
  assert.deepEqual(
    await call("soratomoSetReaction", authOf("a"), { groupId: "g1", skyId: "s1", kind: "sunset", uid: "b", authorId: "b" }),
    { outcome: "added", kind: "sunset" }
  );

  assert.deepEqual(record.sends, [
    {
      uid: "poster",
      token: "tok-poster",
      notification: { title: "ひみつの空の会", body: `そらのアリスさんがあなたの空に${SUNSET}を付けました` },
      data: { type: "soratomoReaction", groupId: "g1", postId: "s1" },
      grouping: { threadId: "soratomo-g1", collapseId: "soratomo-reaction-g1" },
    },
  ]);
  assert.ok(!record.sends[0].notification.body.includes("夕焼けがきれい"), "本文にキャプションを入れない");
  assert.deepEqual(record.otherSends, [], "既存のほかの通知の送信を呼ばない");
  assert.equal(record.getUsersCalls.length, 0, "宛先の判定で Auth を読まない");
  assert.equal(await reactionGroupDocs("notifyState"), 0, "新着投稿の間引きの記録に書かない");

  const sky = await reactionSky();
  assert.deepEqual(Object.keys(sky.reactions), ["a"]);
  assert.equal(sky.reactions.a.kind, "sunset");
  assert.deepEqual(sky.reactorIds, ["a"]);
  assert.deepEqual(reactionOkLogs(), [{ uid: "a", groupId: "g1", skyId: "s1", outcome: "added", kind: "sunset", notify: "sent" }]);
  const logs = allLogs();
  for (const secret of REACTION_SECRETS) {
    assert.ok(!logs.includes(secret), `ログに「${secret}」を出さない`);
  }
});

test("リアクション（6.10）: 付けた人の表示名が空・空白だけ・文字列でない・users が無いときは「だれか」。絵文字は U+FE0F まで載る", async () => {
  await seedReactionScene();
  const reactorRef = db.collection("users").doc("a");
  const cases = [
    ["空", { displayName: "", fcmToken: "tok-a" }],
    ["空白だけ", { displayName: " \u{3000}\t", fcmToken: "tok-a" }],
    ["文字列でない", { displayName: 42, fcmToken: "tok-a" }],
    ["users が無い", null],
  ];
  for (const [name, reactorUser] of cases) {
    await resetReactionNotifyRecords();
    if (reactorUser) await reactorRef.set(reactorUser);
    else await reactorRef.delete();
    record.sends = [];
    assert.deepEqual(await react("a", "cloud"), { outcome: "added", kind: "cloud" }, name);
    assert.deepEqual(
      record.sends.map((s) => s.notification.body),
      [`だれかさんがあなたの空に${CLOUD}を付けました`],
      name
    );
    await react("a", null);
  }
});

test("リアクション（6.7）: 選び直す・同じもの・外すでは、5分を過ぎていても送らない", async () => {
  await seedReactionScene();
  assert.deepEqual(await react("b", "eyes"), { outcome: "added", kind: "eyes" }); // 送る
  assert.deepEqual(await react("a", "sunset"), { outcome: "added", kind: "sunset" }); // 5分以内なので間引く（a は印に入らない）
  // 5分を過ぎた形にする。ここで a の選び直しを送る実装なら、間引きにも重複にも当たらず送ってしまう
  await setReactionLastSentAt(TEN_MINUTES_MS);
  record.sends = [];
  assert.deepEqual(await react("a", "cloud"), { outcome: "replaced", kind: "cloud" });
  assert.deepEqual(await react("a", "cloud"), { outcome: "unchanged", kind: "cloud" });
  assert.deepEqual(await react("a", null), { outcome: "removed", kind: null });

  assert.deepEqual(record.sends, [], "選び直す・同じもの・外すでは送らない");
  assert.deepEqual(
    reactionOkLogs().map((f) => [f.uid, f.outcome, f.notify]),
    [
      ["b", "added", "sent"],
      ["a", "added", "throttled"],
      ["a", "replaced", null],
      ["a", "unchanged", null],
      ["a", "removed", null],
    ]
  );
  const notice = await db.collection("soratomoGroups").doc(REACTION_GROUP).collection("reactionNotices").doc("s1").get();
  assert.deepEqual(notice.get("notifiedReactorIds"), ["b"]);
});

test("リアクション（6.5・6.8）: 5分以内の別の人は間引く。外して付け直した同じ人は、5分を過ぎても2通目を送らない。間引かれた人は、5分を過ぎて付け直せば届く", async () => {
  await seedReactionScene();
  await react("a", "sunset"); // 送る
  await react("b", "eyes"); // 5分以内の別の人: 間引く
  await react("a", null);
  await react("a", "rainbow"); // 外して付け直した同じ人: 重複
  await setReactionLastSentAt(TEN_MINUTES_MS);
  await react("a", null);
  await react("a", "sunset"); // 5分を過ぎても、同じ人の同じ投稿は1通まで
  await react("b", null);
  await react("b", "eyes"); // 間引かれた人は印に入っていないので、5分を過ぎれば届く

  assert.deepEqual(
    record.sends.map((s) => [s.uid, s.notification.body]),
    [
      ["poster", `そらのアリスさんがあなたの空に${SUNSET}を付けました`],
      ["poster", `そらのボブさんがあなたの空に${EYES}を付けました`],
    ]
  );
  assert.deepEqual(
    reactionOkLogs()
      .filter((f) => f.outcome === "added")
      .map((f) => [f.uid, f.notify]),
    [
      ["a", "sent"],
      ["b", "throttled"],
      ["a", "duplicate"],
      ["a", "duplicate"],
      ["b", "sent"],
    ]
  );
  const notice = await db.collection("soratomoGroups").doc(REACTION_GROUP).collection("reactionNotices").doc("s1").get();
  assert.deepEqual([...notice.get("notifiedReactorIds")].sort(), ["a", "b"]);
});

test("リアクション（5.4・6.3・6.4）: 投稿者の通知設定OFF・投稿者が付けた人をブロック・トークン無し・投稿者の users が無い・投稿者がもうメンバーでない・グループの文書が無いでは送らず、notify に理由を出す。どれもリアクションは残り、応答は成功で、通知の記録を書かない", async () => {
  await seedReactionScene();
  const groupRef = db.collection("soratomoGroups").doc(REACTION_GROUP);
  const posterRef = db.collection("users").doc("poster");
  const expectReactionKept = async (name) => {
    assert.deepEqual(await react("a", "sunset"), { outcome: "added", kind: "sunset" }, name);
    assert.equal((await reactionSky()).reactions.a.kind, "sunset", `${name}: リアクションは残る`);
    await react("a", null);
  };

  for (const [name, posterUser] of [
    ["通知設定OFF", { displayName: "ソラミ", fcmToken: "tok-poster", notifySoratomo: false }],
    ["付けた人をブロック", { fcmToken: "tok-poster", blockedUserIds: ["a"] }],
    ["トークン無し", { displayName: "ソラミ" }],
  ]) {
    await posterRef.set(posterUser);
    await expectReactionKept(name);
  }
  await posterRef.delete();
  await expectReactionKept("投稿者の users が無い");

  // 投稿者がもうメンバーでない（投稿の文書だけが残っている）
  await posterRef.set({ fcmToken: "tok-poster" });
  await groupRef.collection("members").doc("poster").delete();
  await expectReactionKept("投稿者がもうメンバーでない");

  // グループの文書が無い（メンバーの文書と投稿の文書だけが残っている）。投稿者のメンバーの文書は戻して、グループの有無だけで止まることを見る
  await groupRef.collection("members").doc("poster").set({ uid: "poster", role: "owner", joinedAt: Timestamp.now() });
  await groupRef.delete();
  await expectReactionKept("グループの文書が無い");

  assert.deepEqual(record.sends, [], "どの場面でも送らない");
  assert.deepEqual(
    reactionOkLogs()
      .filter((f) => f.outcome === "added")
      .map((f) => f.notify),
    ["pref_off", "blocked", "no_token", "no_token", "author_left", "group_missing"]
  );
  assert.equal(await reactionGroupDocs("reactionNotices"), 0, "送った印を書かない");
  assert.equal(await reactionGroupDocs("reactionNotifyState"), 0, "間引きの記録を書かない");
});

test("リアクション（12.4・6.18）: 既存の3つの通知設定を見ず（notifyReactions が OFF でも送り、ON でもそらとも通知が OFF なら送らない）、宛先の版の情報で分けず、users のどの値も書き換えない", async () => {
  await seedReactionScene();
  const usersOf = async () =>
    Object.fromEntries(
      (await db.getAll(...["poster", "a", "b"].map((uid) => db.collection("users").doc(uid)))).map((snap) => [
        snap.id,
        { data: snap.data(), updateTime: snap.updateTime && snap.updateTime.toMillis() },
      ])
    );
  const cases = [
    ["notifyReactions が OFF・そらとも通知は未保存", { fcmToken: "tok-poster", notifyReactions: false, notifyNewPostsFromFollowing: false, notifyNewPostsFromEveryone: false }, "sent"],
    ["notifyReactions が OFF・そらとも通知が ON", { fcmToken: "tok-poster", notifyReactions: false, notifySoratomo: true }, "sent"],
    ["既存の3つが ON・そらとも通知が OFF", { fcmToken: "tok-poster", notifyReactions: true, notifyNewPostsFromFollowing: true, notifyNewPostsFromEveryone: true, notifySoratomo: false }, "pref_off"],
    ["版の情報あり（リアクションを持たない版）", { fcmToken: "tok-poster", appVersion: "1.15.0", appBuild: "113" }, "sent"],
    ["版の情報あり（新しい版）", { fcmToken: "tok-poster", appVersion: "9.9.9" }, "sent"],
  ];
  for (const [name, posterUser, expected] of cases) {
    await resetReactionNotifyRecords();
    await db.collection("users").doc("poster").set(posterUser);
    const before = await usersOf();
    record.sends = [];
    record.logs = [];
    assert.deepEqual(await react("a", "sunset"), { outcome: "added", kind: "sunset" }, name);
    assert.equal(reactionOkLogs()[0].notify, expected, name);
    assert.equal(record.sends.length, expected === "sent" ? 1 : 0, name);
    assert.deepEqual(await usersOf(), before, `${name}: users を書き換えない`);
    await react("a", null);
  }
});

test("リアクション（6.16）: 送信の失敗（投げる・failed・無効なトークン）と、通知文の組み立て・枠の確保の失敗でも、リアクションは残り、応答は成功。notify は failed か invalid_token で、warn のログは内部IDと errorName・errorCode だけ", async () => {
  await seedReactionScene();
  const store = require("./soratomoStore");
  const originalBuild = core.buildReactionNotification;
  const originalClaim = store.claimReactionNotifySlot;
  const cases = [
    {
      name: "送信が投げる",
      arrange: () => {
        sendImpl = async () => {
          throw Object.assign(new Error("送信の内部エラー tok-poster"), { code: "messaging/internal-error" });
        };
      },
      notify: "failed",
      warn: { errorName: "Error", errorCode: "messaging/internal-error" },
      sends: 1,
    },
    { name: "送信が failed を返す", arrange: () => (sendImpl = async () => "failed"), notify: "failed", warn: null, sends: 1 },
    { name: "無効なトークン", arrange: () => (sendImpl = async () => "invalid_token"), notify: "invalid_token", warn: null, sends: 1 },
    {
      name: "通知文の組み立てが投げる",
      arrange: () => {
        core.buildReactionNotification = () => {
          throw new TypeError("組み立ての失敗");
        };
      },
      notify: "failed",
      warn: { errorName: "TypeError", errorCode: undefined },
      sends: 0,
      // 枠の確保より前に組み立てるので、間引きの記録と送った印を使わない
      noRecords: true,
    },
    {
      name: "枠の確保が投げる",
      arrange: () => {
        store.claimReactionNotifySlot = async () => {
          throw Object.assign(new Error("トランザクションの失敗"), { code: 10 });
        };
      },
      notify: "failed",
      warn: { errorName: "Error", errorCode: 10 },
      sends: 0,
    },
  ];
  for (const c of cases) {
    await resetReactionNotifyRecords();
    record.sends = [];
    record.logs = [];
    c.arrange();
    try {
      assert.deepEqual(await react("a", "sunset"), { outcome: "added", kind: "sunset" }, c.name);
    } finally {
      sendImpl = async () => "sent";
      core.buildReactionNotification = originalBuild;
      store.claimReactionNotifySlot = originalClaim;
    }
    assert.equal((await reactionSky()).reactions.a.kind, "sunset", `${c.name}: リアクションは残る`);
    assert.equal(record.sends.length, c.sends, c.name);
    assert.deepEqual(reactionOkLogs().map((f) => f.notify), [c.notify], c.name);
    assert.deepEqual(
      logFieldsOf("soratomoSetReaction: notify_failed"),
      c.warn ? [{ uid: "a", groupId: "g1", skyId: "s1", ...c.warn }] : [],
      c.name
    );
    assert.deepEqual(record.logs.filter((l) => l.level === "error"), [], `${c.name}: 想定外の失敗（internal）にしない`);
    if (c.noRecords) {
      assert.equal(await reactionGroupDocs("reactionNotifyState"), 0, `${c.name}: 間引きの記録を使わない`);
      assert.equal(await reactionGroupDocs("reactionNotices"), 0, `${c.name}: 送った印を使わない`);
    }
    const logs = allLogs();
    for (const secret of [...REACTION_SECRETS, "送信の内部エラー", "組み立ての失敗", "トランザクションの失敗"]) {
      assert.ok(!logs.includes(secret), `${c.name}: ログに「${secret}」を出さない`);
    }
    await react("a", null);
  }
});

test("リアクション: 書いた直後に投稿が消えたら、送らずに notify を sky_gone にする（応答は成功）", async () => {
  await seedReactionScene();
  const store = require("./soratomoStore");
  const original = store.setReactionTx;
  store.setReactionTx = async (...args) => {
    const result = await original(...args);
    await db.collection("soratomoGroups").doc(REACTION_GROUP).collection("skies").doc("s1").delete();
    return result;
  };
  try {
    assert.deepEqual(await react("a", "sunset"), { outcome: "added", kind: "sunset" });
  } finally {
    store.setReactionTx = original;
  }
  assert.deepEqual(record.sends, []);
  assert.deepEqual(reactionOkLogs().map((f) => f.notify), ["sky_gone"]);
  assert.equal(await reactionGroupDocs("reactionNotices"), 0, "消えた投稿の印を作らない");
});

test("リアクション（6.6）: リアクションの通知の直後でも新着投稿の通知は間引かれず、新着投稿の通知の直後でもリアクションの通知は届く。リアクションで既存のほかの通知の送信を呼ばない", async () => {
  await seedScene();
  const skies = db.collection("soratomoGroups").doc("g1").collection("skies");
  await skies.doc("s1").set({ authorId: "poster", width: 1080, height: 1440, createdAt: Timestamp.now() });
  await skies.doc("s3").set({ authorId: "f", width: 1080, height: 1440, createdAt: Timestamp.now() });

  // (1) a が poster の s1 に付ける → poster へリアクションの通知
  assert.deepEqual(await react("a", "sunset"), { outcome: "added", kind: "sunset" });
  assert.deepEqual(record.sends.map((s) => [s.uid, s.data.type]), [["poster", "soratomoReaction"]]);
  assert.equal((await db.collection("soratomoGroups").doc("g1").collection("notifyState").get()).size, 0);

  // (2) 直後に b が s2 を投稿 → poster にも新着投稿の通知が届く（リアクションの記録で間引かない）
  record.sends = [];
  record.logs = [];
  await postSky("s2", { authorId: "b" });
  assert.deepEqual(
    record.sends.map((s) => [s.uid, s.data.type]).sort(),
    [
      ["a", "soratomoPost"],
      ["d", "soratomoPost"],
      ["f", "soratomoPost"],
      ["poster", "soratomoPost"],
    ]
  );
  assert.equal(summaryLog().throttled, 0);

  // (3) 新着投稿の通知を受けた直後の f に、a のリアクションの通知が届く（新着投稿の記録で間引かない）
  record.sends = [];
  assert.deepEqual(await react("a", "eyes", "s3"), { outcome: "added", kind: "eyes" });
  assert.deepEqual(record.sends.map((s) => [s.uid, s.data.type]), [["f", "soratomoReaction"]]);
  assert.deepEqual(record.otherSends, [], "既存のほかの通知の送信を呼ばない");
});
