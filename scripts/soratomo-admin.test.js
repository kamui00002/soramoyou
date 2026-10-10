//
// soratomo-admin.js の単体テスト（node:test・firebase-admin 非依存）☁️⭐️
//
// 実行: node --test scripts/soratomo-admin.test.js
//
// 引数の解釈・delete-user の Auth の検査・出力に内部ID以外が混ざらないこと・review-report の順序を、偽の db・auth・
// 共通の削除で確かめる（本番には触れない）。Firestore のパスとクエリが本物で動くかは soratomo-admin.emulator.test.js。
// ⚠️ package.json の test に登録してある（functions で npm test）。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const admin = require("./soratomo-admin");

const G = "grp1";
const S = "sky1";
const AUTHOR = "authorUid";
const REPORTER = "reporterUid";
const REPORT_ID = `${G}_${S}_${REPORTER}`;
const NOW = 1_800_000_000_000;

/**
 * 出力に混ざってはいけない目印（キャプション・グループ名・表示名・招待コード）。
 * 投稿の文書に画像の URL の項目は無い（画像は Storage のパスで持ち、show-report はそのパスを出す）ので、目印も置かない。
 */
const SECRETS = ["ひみつのキャプション", "ひみつのグループ名", "ひみつの表示名", "SECRETCODE"];

/** Firestore の Timestamp のように見える値。 */
const ts = (ms) => ({ toMillis: () => ms });

/**
 * 偽の db。docs は「コレクション/文書ID」→ 中身。update は updates に記録する。
 * @param {Record<string, Object>} docs
 */
function fakeDb(docs) {
  const updates = [];
  const snapOf = (path) => ({
    exists: Object.prototype.hasOwnProperty.call(docs, path),
    data: () => docs[path],
    get: (key) => (docs[path] || {})[key],
  });
  const docRef = (path) => ({
    get: async () => snapOf(path),
    update: async (value) => {
      updates.push({ path, value });
    },
  });
  return {
    updates,
    collection: (name) => ({ doc: (id) => docRef(`${name}/${id}`) }),
    doc: (path) => docRef(path),
  };
}

/**
 * 偽の auth。exists の uid だけアカウントがある。lookupError を渡すと getUser がそれを投げる。
 * getUsers は Admin SDK と同じく100件を超えると失敗し、渡された組の大きさを batches に記録する。
 */
function fakeAuth(exists, { lookupError = null } = {}) {
  const calls = [];
  const batches = [];
  return {
    calls,
    batches,
    async getUser(uid) {
      calls.push(uid);
      if (lookupError) throw lookupError;
      if (exists.includes(uid)) return { uid };
      throw Object.assign(new Error("not found"), { code: "auth/user-not-found" });
    },
    async getUsers(identifiers) {
      if (identifiers.length > 100) throw Object.assign(new Error("too many"), { code: "auth/maximum-user-count-exceeded" });
      batches.push(identifiers.length);
      return {
        users: identifiers.filter((i) => exists.includes(i.uid)).map((i) => ({ uid: i.uid })),
        notFound: identifiers.filter((i) => !exists.includes(i.uid)),
      };
    },
  };
}

/**
 * find-orphans 用の偽の db（listDocuments と、投稿の authorId の select だけ）。
 * @param {{ users?: string[], groups?: Record<string, { members?: string[], authors?: unknown[] }> }} tree
 */
function fakeTreeDb({ users = [], groups = {} }) {
  const refOf = (id) => ({ id });
  const groupRefOf = (id) => ({
    id,
    collection(sub) {
      const group = groups[id];
      if (sub === "members") return { listDocuments: async () => (group.members || []).map(refOf) };
      if (sub === "skies") {
        const docs = (group.authors || []).map((authorId) => ({ get: (key) => (key === "authorId" ? authorId : undefined) }));
        return { select: () => ({ get: async () => ({ docs }) }) };
      }
      throw new Error(`想定外のサブコレクション: ${sub}`);
    },
  });
  return {
    collection(name) {
      if (name === "soratomoUsers") return { listDocuments: async () => users.map(refOf) };
      if (name === "soratomoGroups") return { listDocuments: async () => Object.keys(groups).map(groupRefOf) };
      throw new Error(`想定外のコレクション: ${name}`);
    },
  };
}

/** 偽の Storage のゲートウェイ（listFiles だけ）。 */
function fakeStorage(paths = []) {
  return {
    async *listFiles(prefix) {
      for (const p of paths) if (p.startsWith(prefix)) yield p;
    },
  };
}

const DONE = { done: true, skiesDeleted: 2, imagesDeleted: 4, groupsLeft: 1, ownersTransferred: 1, groupsDeleted: 0 };

/** 偽の共通の削除。呼ばれた順と引数を calls に記録する。 */
function fakeDeletion({ userTotals = DONE, suspendTotals = DONE, sky = { skyDeleted: true, imagesDeleted: 2 } } = {}) {
  const calls = [];
  return {
    calls,
    async deleteSoratomoUserData(deps, request) {
      calls.push(["deleteSoratomoUserData", request]);
      return userTotals;
    },
    async deleteSoratomoSky(deps, request) {
      calls.push(["deleteSoratomoSky", request]);
      return sky;
    },
    async suspendSoratomoUser(deps, request) {
      calls.push(["suspendSoratomoUser", request]);
      return suspendTotals;
    },
    async unsuspendSoratomoUser(db, request) {
      calls.push(["unsuspendSoratomoUser", request]);
    },
  };
}

function deps(overrides = {}) {
  return {
    db: fakeDb({}),
    auth: fakeAuth([]),
    deletion: fakeDeletion(),
    nowMs: () => NOW,
    serverTimestamp: () => "SERVER_TIMESTAMP",
    ...overrides,
  };
}

function assertNoSecrets(lines) {
  const text = lines.join("\n");
  for (const secret of SECRETS) assert.equal(text.includes(secret), false, `出力に「${secret}」が混ざった`);
}

const REPORT = {
  groupId: G,
  skyId: S,
  authorId: AUTHOR,
  reporterId: REPORTER,
  reason: "spam",
  createdAt: ts(Date.UTC(2026, 9, 8, 1, 2, 3)),
  forwardStatus: "pending",
  forwardAttempts: 2,
};
const SKY = { authorId: AUTHOR, caption: "ひみつのキャプション", width: 1080, height: 1440, createdAt: ts(0) };

// MARK: - parseArgs

test("parseArgs: 8つのコマンドを正しい引数で読む", () => {
  assert.deepEqual(admin.parseArgs(["find-orphans"]), { ok: true, command: "find-orphans", deep: false });
  assert.deepEqual(admin.parseArgs(["find-orphans", "--deep"]), { ok: true, command: "find-orphans", deep: true });
  assert.deepEqual(admin.parseArgs(["delete-user", "u1"]), { ok: true, command: "delete-user", uid: "u1", groupIds: [] });
  assert.deepEqual(admin.parseArgs(["delete-user", "u1", "--group", "g1", "--group", "g2", "--group", "g1"]), {
    ok: true,
    command: "delete-user",
    uid: "u1",
    groupIds: ["g1", "g2"],
  });
  assert.deepEqual(admin.parseArgs(["show-report", REPORT_ID]), { ok: true, command: "show-report", reportId: REPORT_ID });
  assert.deepEqual(admin.parseArgs(["review-report", REPORT_ID, "--result", "violation"]), {
    ok: true,
    command: "review-report",
    reportId: REPORT_ID,
    result: "violation",
  });
  assert.deepEqual(admin.parseArgs(["review-report", REPORT_ID, "--result", "no_violation"]).result, "no_violation");
  assert.deepEqual(admin.parseArgs(["delete-sky", G, S]), { ok: true, command: "delete-sky", groupId: G, skyId: S });
  assert.deepEqual(admin.parseArgs(["suspend", "u1"]), { ok: true, command: "suspend", uid: "u1" });
  assert.deepEqual(admin.parseArgs(["unsuspend", "u1"]), { ok: true, command: "unsuspend", uid: "u1" });
  assert.deepEqual(admin.parseArgs(["list-unforwarded"]), { ok: true, command: "list-unforwarded" });
});

test("parseArgs: 足りない・余る・形の違う引数は ok: false（何も読み書きしない）", () => {
  const bad = [
    [],
    ["unknown"],
    ["find-orphans", "--deeper"],
    ["find-orphans", "--deep", "x"],
    ["delete-user"],
    ["delete-user", "-u1"],
    ["delete-user", "a/b"],
    ["delete-user", "x".repeat(129)],
    ["delete-user", "u1", "--group"],
    ["delete-user", "u1", "--group", "a/b"],
    ["delete-user", "u1", "--group", "g_1"],
    ["delete-user", "u1", "--groups", "g1"],
    ["delete-user", "u1", "u2"],
    ["show-report"],
    ["show-report", "g1_s1"],
    ["show-report", "g/1_s1_u1"],
    ["show-report", REPORT_ID, "x"],
    ["review-report", REPORT_ID],
    ["review-report", REPORT_ID, "--result"],
    ["review-report", REPORT_ID, "--result", "deleted"],
    ["review-report", REPORT_ID, "violation", "--result"],
    ["delete-sky", G],
    ["delete-sky", G, "s/1"],
    ["delete-sky", G, S, "x"],
    ["suspend"],
    ["suspend", "u1", "u2"],
    ["unsuspend", "--x"],
    ["list-unforwarded", "x"],
  ];
  for (const argv of bad) assert.deepEqual(admin.parseArgs(argv), { ok: false }, `通ってしまった: ${JSON.stringify(argv)}`);
});

test("isReportId: 「グループID_投稿ID_通報者」の形だけを受け付ける（通報者の uid は _ を含んでよい）", () => {
  assert.equal(admin.isReportId(REPORT_ID), true);
  assert.equal(admin.isReportId("g1_s1_user_with_underscore"), true);
  for (const bad of ["", "g1_s1", "g1__u1", "_s1_u1", "g1_s1_", "g-1_s1_u1", "g1_s1_u/1", 123, null]) {
    assert.equal(admin.isReportId(bad), false, `通ってしまった: ${JSON.stringify(bad)}`);
  }
});

// MARK: - delete-user（Auth の検査）

test("delete-user: Auth のアカウントがあれば拒否し、削除を呼ばない", async () => {
  const d = deps({ auth: fakeAuth([AUTHOR]) });
  const out = await admin.cmdDeleteUser(d, { uid: AUTHOR, groupIds: [] });
  assert.equal(out.exitCode, 1);
  assert.match(out.lines.join("\n"), /アカウントがあるので消さない/);
  assert.deepEqual(d.deletion.calls, []);
});

test("delete-user: アカウントが無い（auth/user-not-found）ときだけ、trigger admin と追加のグループで消す", async () => {
  const d = deps({ auth: fakeAuth([]) });
  const out = await admin.cmdDeleteUser(d, { uid: AUTHOR, groupIds: ["g9"] });
  assert.equal(out.exitCode, 0);
  assert.deepEqual(d.deletion.calls, [
    [
      "deleteSoratomoUserData",
      { uid: AUTHOR, trigger: "admin", deadlineMs: NOW + admin.DELETE_BUDGET_MS, extraGroupIds: ["g9"] },
    ],
  ]);
  assert.equal(out.lines[0], `uid: ${AUTHOR}`);
  assert.match(out.lines.join("\n"), /完了: はい/);
});

test("delete-user: アカウントの問い合わせが別の理由で失敗したら、「無い」と読まずに投げ、削除を呼ばない", async () => {
  const error = Object.assign(new Error("quota"), { code: "auth/internal-error" });
  const d = deps({ auth: fakeAuth([], { lookupError: error }) });
  await assert.rejects(admin.cmdDeleteUser(d, { uid: AUTHOR, groupIds: [] }), (err) => err === error);
  assert.deepEqual(d.deletion.calls, []);
});

test("delete-user: 予算の時間で止まったら終了コード 1 で、もう一度の実行を促す", async () => {
  const d = deps({ deletion: fakeDeletion({ userTotals: { ...DONE, done: false } }) });
  const out = await admin.cmdDeleteUser(d, { uid: AUTHOR, groupIds: [] });
  assert.equal(out.exitCode, 1);
  assert.match(out.lines.join("\n"), /同じコマンドをもう一度/);
});

// MARK: - show-report（出力に内部ID以外を混ぜない）

test("show-report: 記録の項目とコンソール・Storage のパスを出し、キャプションなどは出さない", async () => {
  const db = fakeDb({
    [`soratomoReports/${REPORT_ID}`]: REPORT,
    [`soratomoGroups/${G}/skies/${S}`]: SKY,
    [`soratomoGroups/${G}`]: { name: "ひみつのグループ名", inviteCode: "SECRETCODE" },
  });
  const out = await admin.cmdShowReport({ db }, { reportId: REPORT_ID });
  assert.equal(out.exitCode, 0);
  const text = out.lines.join("\n");
  for (const expected of [
    `通報の記録: ${REPORT_ID}`,
    "理由: spam",
    "受け付けた時刻: 2026-10-08T01:02:03.000Z",
    `投稿者: ${AUTHOR}`,
    `通報者: ${REPORTER}`,
    "転送: pending・失敗の回数: 2",
    "確認: 未確認",
    "投稿の文書: あり",
    `コンソールで開く文書: soratomoGroups/${G}/skies/${S}`,
    `soratomo/${G}/${AUTHOR}/${S}/display.jpg`,
    `soratomo/${G}/${AUTHOR}/${S}/thumb.jpg`,
  ]) {
    assert.ok(text.includes(expected), `出力に「${expected}」が無い`);
  }
  assertNoSecrets(out.lines);
});

test("show-report: 記録の値が ID の形でなければ値を出さずに（壊れた値）と出し、場所も出さない", async () => {
  const broken = { ...REPORT, authorId: "ひみつの表示名", reason: "ひみつのキャプション", reporterId: "a/b" };
  const db = fakeDb({ [`soratomoReports/${REPORT_ID}`]: broken, [`soratomoGroups/${G}/skies/${S}`]: SKY });
  const out = await admin.cmdShowReport({ db }, { reportId: REPORT_ID });
  assert.equal(out.exitCode, 1);
  const text = out.lines.join("\n");
  assert.ok(text.includes("投稿者: （壊れた値）"));
  assert.ok(text.includes("理由: （壊れた値）"));
  assert.ok(text.includes("通報者: （壊れた値）"));
  assert.equal(text.includes("コンソールで開く文書"), false);
  assert.equal(text.includes("a/b"), false);
  assertNoSecrets(out.lines);
});

test("show-report: 記録が無ければ終了コード 1", async () => {
  const out = await admin.cmdShowReport({ db: fakeDb({}) }, { reportId: REPORT_ID });
  assert.equal(out.exitCode, 1);
});

// MARK: - review-report（順序）

test("review-report violation: 投稿の削除 → 記録の投稿者の利用停止 → 確認の記録、の順に行う", async () => {
  const db = fakeDb({ [`soratomoReports/${REPORT_ID}`]: REPORT, [`soratomoGroups/${G}/skies/${S}`]: SKY });
  const d = deps({ db });
  const out = await admin.cmdReviewReport(d, { reportId: REPORT_ID, result: "violation" });
  assert.equal(out.exitCode, 0);
  assert.deepEqual(d.deletion.calls, [
    ["deleteSoratomoSky", { groupId: G, skyId: S }],
    ["suspendSoratomoUser", { uid: AUTHOR, deadlineMs: NOW + admin.DELETE_BUDGET_MS }],
  ]);
  assert.deepEqual(db.updates, [
    { path: `soratomoReports/${REPORT_ID}`, value: { reviewedAt: "SERVER_TIMESTAMP", reviewResult: "violation" } },
  ]);
  assertNoSecrets(out.lines);
});

test("review-report violation: 停止が予算の時間で止まったら、確認の記録を書かない", async () => {
  const db = fakeDb({ [`soratomoReports/${REPORT_ID}`]: REPORT });
  const d = deps({ db, deletion: fakeDeletion({ suspendTotals: { ...DONE, done: false } }) });
  const out = await admin.cmdReviewReport(d, { reportId: REPORT_ID, result: "violation" });
  assert.equal(out.exitCode, 1);
  assert.deepEqual(db.updates, []);
  assert.match(out.lines.join("\n"), /確認の記録はまだ書いていない/);
});

test("review-report violation: 記録の ID が壊れていれば、推測で消さずに止める", async () => {
  const db = fakeDb({ [`soratomoReports/${REPORT_ID}`]: { ...REPORT, authorId: "a/b" } });
  const d = deps({ db });
  const out = await admin.cmdReviewReport(d, { reportId: REPORT_ID, result: "violation" });
  assert.equal(out.exitCode, 1);
  assert.deepEqual(d.deletion.calls, []);
  assert.deepEqual(db.updates, []);
});

test("review-report violation: 今の投稿の投稿者が記録と違えば、消さず・止めず・記録も書かずに止める", async () => {
  // 元の投稿が消えた後に、同じ投稿IDで別の人の投稿が作られた（記録の投稿者と今の投稿者がずれる）
  const db = fakeDb({
    [`soratomoReports/${REPORT_ID}`]: REPORT,
    [`soratomoGroups/${G}/skies/${S}`]: { ...SKY, authorId: "someoneElse" },
  });
  const d = deps({ db });
  const out = await admin.cmdReviewReport(d, { reportId: REPORT_ID, result: "violation" });
  assert.equal(out.exitCode, 1);
  assert.deepEqual(d.deletion.calls, []);
  assert.deepEqual(db.updates, []);
  assert.match(out.lines.join("\n"), /今の投稿者 someoneElse が記録の投稿者 authorUid と違う/);
  assertNoSecrets(out.lines);
});

test("review-report violation: 今の投稿者の値が ID の形でなければ、値を出さずに止める", async () => {
  const db = fakeDb({
    [`soratomoReports/${REPORT_ID}`]: REPORT,
    [`soratomoGroups/${G}/skies/${S}`]: { ...SKY, authorId: "ひみつの表示名" },
  });
  const d = deps({ db });
  const out = await admin.cmdReviewReport(d, { reportId: REPORT_ID, result: "violation" });
  assert.equal(out.exitCode, 1);
  assert.deepEqual(d.deletion.calls, []);
  assert.deepEqual(db.updates, []);
  assertNoSecrets(out.lines);
});

test("review-report no_violation: 削除も停止もせず、確認の記録だけを書く。前回の結果は出して上書きする", async () => {
  const db = fakeDb({ [`soratomoReports/${REPORT_ID}`]: { ...REPORT, reviewResult: "violation", reviewedAt: ts(1) } });
  const d = deps({ db });
  const out = await admin.cmdReviewReport(d, { reportId: REPORT_ID, result: "no_violation" });
  assert.equal(out.exitCode, 0);
  assert.deepEqual(d.deletion.calls, []);
  assert.deepEqual(db.updates.map((u) => u.value.reviewResult), ["no_violation"]);
  assert.match(out.lines.join("\n"), /前回の結果: violation/);
});

// MARK: - suspend・unsuspend

test("suspend: アカウントの問い合わせが失敗しても、停止は行う（有無は打ち間違いに気づくための表示だけ）", async () => {
  const error = Object.assign(new Error("x"), { code: "auth/internal-error" });
  const d = deps({ auth: fakeAuth([], { lookupError: error }) });
  const out = await admin.cmdSuspend(d, { uid: AUTHOR });
  assert.equal(out.exitCode, 0);
  assert.deepEqual(d.deletion.calls, [["suspendSoratomoUser", { uid: AUTHOR, deadlineMs: NOW + admin.DELETE_BUDGET_MS }]]);
  assert.match(out.lines.join("\n"), /確かめられなかった（auth\/internal-error）/);
});

test("unsuspend: 停止の記録が無ければ、解除を呼ばない", async () => {
  for (const docs of [{}, { [`soratomoUsers/${AUTHOR}`]: { groupCount: 0 } }]) {
    const d = deps({ db: fakeDb(docs) });
    const out = await admin.cmdUnsuspend(d, { uid: AUTHOR });
    assert.equal(out.exitCode, 0);
    assert.deepEqual(d.deletion.calls, []);
    assert.match(out.lines.join("\n"), /停止の記録が無い/);
  }
});

test("unsuspend: 停止中なら解除を呼ぶ", async () => {
  const d = deps({ db: fakeDb({ [`soratomoUsers/${AUTHOR}`]: { groupCount: 0, suspendedAt: ts(1) } }) });
  const out = await admin.cmdUnsuspend(d, { uid: AUTHOR });
  assert.deepEqual(d.deletion.calls, [["unsuspendSoratomoUser", { uid: AUTHOR }]]);
  assert.match(out.lines.join("\n"), /利用停止を解いた/);
});

// MARK: - find-orphans（偽の db。Firestore のパスとクエリが本物で動くかは emulator のテスト）

test("find-orphans --deep: ID の形でないグループの文書IDは出さずに数え、その下のアカウントの無い uid は並べる", async () => {
  const d = deps({
    db: fakeTreeDb({
      groups: {
        "ひみつのグループ名": { members: ["deadX"], authors: ["deadZ"] },
        gOK: { members: ["alive", "deadY"] },
      },
    }),
    auth: fakeAuth(["alive"]),
    storage: fakeStorage([]),
  });
  const out = await admin.cmdFindOrphans(d, { deep: true });
  assert.equal(out.exitCode, 0);
  const text = out.lines.join("\n");
  for (const expected of [
    "アカウントの無い uid: 3 人",
    "  deadX  データの残るグループ: （なし）",
    "  deadY  データの残るグループ: gOK",
    "  deadZ  データの残るグループ: （なし）",
    "soratomoGroups の下で ID の形でないグループ: 1 個",
  ]) {
    assert.ok(text.includes(expected), `出力に「${expected}」が無い\n${text}`);
  }
  assertNoSecrets(out.lines);
});

test("find-orphans: getUsers には100件ずつ渡し、101人目（2つ目の組）のアカウントの無い uid も並べる", async () => {
  const users = Array.from({ length: 101 }, (_, i) => `u${String(i).padStart(3, "0")}`);
  const auth = fakeAuth(["u000", "u099"]);
  const out = await admin.cmdFindOrphans(deps({ db: fakeTreeDb({ users }), auth, storage: fakeStorage([]) }), { deep: false });
  assert.equal(out.exitCode, 0);
  assert.deepEqual(auth.batches, [100, 1]);
  assert.equal(out.lines[0], "調べた uid: 101 人（利用者の文書から）");
  assert.equal(out.lines[1], "アカウントの無い uid: 99 人");
  const listed = out.lines.filter((line) => /^ {2}u\d{3}$/.test(line)).map((line) => line.trim());
  assert.deepEqual(listed, users.filter((uid) => uid !== "u000" && uid !== "u099"));
  assert.equal(listed.at(-1), "u100");
});

// MARK: - 出力の部品

test("formatTotals: 件数だけを出す（完了でないときは再実行を促す）", () => {
  assert.deepEqual(admin.formatTotals(DONE), [
    "完了: はい",
    "消した投稿: 2 件・画像: 4 枚",
    "外したグループ: 1 個（うちオーナーを引き継いだ: 1 個）・消したグループ: 0 個",
  ]);
  assert.match(admin.formatTotals({ ...DONE, done: false })[0], /同じコマンドをもう一度/);
});

test("isoOf: Timestamp と Date は ISO 8601、無い・読めない値は（無い）", () => {
  assert.equal(admin.isoOf(ts(Date.UTC(2026, 0, 2))), "2026-01-02T00:00:00.000Z");
  assert.equal(admin.isoOf(new Date(Date.UTC(2026, 0, 2))), "2026-01-02T00:00:00.000Z");
  for (const v of [undefined, null, "2026-01-02", 123, new Date(Number.NaN)]) assert.equal(admin.isoOf(v), "（無い）");
});

// MARK: - 読み込み・固定している接続先（scripts/set-soratomo-beta-claim.test.js・check-soratomo-download-tokens.test.js と同じ守り）

test("読み込むだけでは firebase-admin を読まない（テストと引数の確認に依存を持ち込まない）", () => {
  const sep = require("node:path").sep;
  const loaded = Object.keys(require.cache).filter((p) => p.includes(`${sep}firebase-admin${sep}`));
  assert.deepEqual(loaded, []);
});

test("プロジェクトは soramoyou-ios に固定している（ADC の取り違えで別プロジェクトを消さないため）", () => {
  assert.equal(admin.EXPECTED_PROJECT_ID, "soramoyou-ios");
});

test("バケットは soramoyou-ios.firebasestorage.app に固定している", () => {
  assert.equal(admin.EXPECTED_BUCKET, "soramoyou-ios.firebasestorage.app");
});

// MARK: - main の冒頭の環境の確認（D5・D6）

test("findEmulatorEnv: 名前が _EMULATOR_HOST で終わり、値が空でない環境変数の名前だけを並べる", () => {
  const env = {
    FIRESTORE_EMULATOR_HOST: "127.0.0.1:8080",
    FIREBASE_AUTH_EMULATOR_HOST: "",
    STORAGE_EMULATOR_HOST: "http://127.0.0.1:9199",
    FIREBASE_STORAGE_EMULATOR_HOST: "127.0.0.1:9199",
    PATH: "/usr/bin",
    EMULATOR_HOST_NOTE: "x",
  };
  assert.deepEqual(admin.findEmulatorEnv(env), ["FIREBASE_STORAGE_EMULATOR_HOST", "FIRESTORE_EMULATOR_HOST", "STORAGE_EMULATOR_HOST"]);
  assert.deepEqual(admin.findEmulatorEnv({ PATH: "/usr/bin" }), []);
});

/**
 * firebase-admin を読もうとしたら、その場で投げる。柵が外れたときに、ネットワークへ出る前（再試行で固まる前）に赤にするため。
 * createRequire の require も Module._load を通る。差し替えはテストの終わりに戻る（t.mock）。
 */
function forbidFirebaseAdmin(t) {
  const Module = require("node:module");
  const original = Module._load;
  t.mock.method(Module, "_load", function load(request, ...rest) {
    if (String(request).startsWith("firebase-admin")) throw new Error("test: firebase-admin を読もうとした（柵が効いていない）");
    return original.call(this, request, ...rest);
  });
}

test("main: エミュレーターを指す環境変数が1つでもあれば、firebase-admin を読まずに止める（名前だけを出す）", async (t) => {
  // Auth だけエミュレーター・Firestore は本番という混在だと、delete-user の「アカウントが無い」が本番の削除に直結する。
  // 柵が外れても本番へ届かないよう、宛先はすべて閉じたポート・資格情報は存在しないファイルにしておく
  const env = {
    FIREBASE_AUTH_EMULATOR_HOST: "127.0.0.1:9",
    FIRESTORE_EMULATOR_HOST: "127.0.0.1:9",
    FIREBASE_STORAGE_EMULATOR_HOST: "127.0.0.1:9",
    GOOGLE_APPLICATION_CREDENTIALS: "/nonexistent/soratomo-admin-test.json",
  };
  forbidFirebaseAdmin(t);
  const saved = Object.fromEntries(Object.keys(env).map((k) => [k, process.env[k]]));
  Object.assign(process.env, env);
  const out = [];
  t.mock.method(console, "log", (...args) => out.push(args.join(" ")));
  t.mock.method(console, "error", (...args) => out.push(args.join(" ")));
  const before = process.exitCode;
  try {
    await admin.main(["delete-user", "orphanUid"]);
    assert.equal(process.exitCode, 1);
  } finally {
    process.exitCode = before;
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
  assert.equal(out.length, 1);
  assert.match(out[0], /FIREBASE_AUTH_EMULATOR_HOST FIREBASE_STORAGE_EMULATOR_HOST FIRESTORE_EMULATOR_HOST/);
  assert.equal(out[0].includes("127.0.0.1"), false);
  const sep = require("node:path").sep;
  assert.deepEqual(Object.keys(require.cache).filter((p) => p.includes(`${sep}firebase-admin${sep}`)), []);
});

test("firebase-admin は functions/ から解決する（共通の削除のモジュールと同じ実体。FieldValue の取り違えを防ぐ）", () => {
  const path = require("node:path");
  const { createRequire } = require("node:module");
  const fromDeletion = createRequire(require.resolve("../functions/soratomoDeletion"));
  for (const name of ["firebase-admin/app", "firebase-admin/firestore", "firebase-admin/auth", "firebase-admin/storage"]) {
    assert.equal(admin.functionsRequire.resolve(name), fromDeletion.resolve(name), name);
  }
  // main の中で素の require（NODE_PATH 頼み）で firebase-admin を読んでいない
  const source = require("node:fs").readFileSync(path.join(__dirname, "soratomo-admin.js"), "utf8");
  assert.doesNotMatch(source, /\brequire\(\s*["']firebase-admin/);
});

// MARK: - 失敗の出し方（D18）

test("describeError: 自前の soratomo: のエラーは本文を、それ以外は code（無ければ名前）だけを出す", () => {
  assert.equal(admin.describeError(new TypeError("soratomo: uid が文書IDとして使えない")), "soratomo: uid が文書IDとして使えない");
  assert.equal(admin.describeError(new Error("soratomo: 投稿の authorId が壊れている")), "soratomo: 投稿の authorId が壊れている");
  // 本文に資格情報のパスなどが入りうるので、自前でないエラーの本文は出さない
  const secretPath = "/Users/someone/.config/gcloud/application_default_credentials.json";
  assert.equal(admin.describeError(Object.assign(new Error(`ENOENT: ${secretPath}`), { code: "ENOENT" })), "ENOENT");
  assert.equal(admin.describeError(new RangeError(`読めない: ${secretPath}`)), "RangeError");
  assert.equal(admin.describeError(new Error("xsoratomo: 先頭でない")), "Error");
  for (const value of [null, undefined, "soratomo: 文字列", {}]) assert.equal(admin.describeError(value), "不明なエラー");
});

test("main の失敗は describeError を通して出す", () => {
  const source = require("node:fs").readFileSync(require("node:path").join(__dirname, "soratomo-admin.js"), "utf8");
  assert.match(source, /console\.error\(`❌ 失敗しました: \$\{describeError\(err\)\}`\)/);
});
