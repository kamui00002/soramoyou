//
// dailyPick.js（runDailyPick）が、本物の Firestore（エミュレーター）で「今日のおすすめのそらもよう」を選んで書き、
// 選ばれた人へ多くて 1 回だけ知らせることを確かめるテスト ⭐️☁️
// ⚠️ 「私のおすすめの空」（recommendationNotices）とは別物。
//
// 実行（functions/ の npm run test:emulator に登録。--project demo-soramoyou-security で起きる）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "NODE_PATH=node_modules node --test dailyPick.emulator.test.js"
//
// ■ 何を確かめるか
//   - 流れ: 公開投稿だけから選び、dailyPicks と dailyPickLog を書き、主役（candidates[0]）の投稿者へ 1 回知らせて
//     印（notifyClaimedAt）と結果（notifyResult）を残す
//   - 二重実行・同時実行: dailyPicks は 1 件、知らせるのは合計 1 回
//   - 設定なし・壊れた設定: 何も書かず、知らせない
//   - 通知オフ→オン: オフの回は印を取らず、オンにした次の回で 1 回だけ知らせる
//     （＝選んだ直後に落ちて、通知の段に届かなかった回の再試行と同じ状態から 1 回だけ送る）
//   - 時間帯の外（22:00・翌朝 06:59）: 印を取らず、知らせない
//   - notifyOwner が投げる: runDailyPick は投げず、印は残り、もう一度呼んでも知らせない
//   - 送る権利のトランザクションが落ちる（権利を取る前）: runDailyPick は投げ（＝再試行に任せる）、印も結果も残さず、
//     次の回で 1 回だけ知らせ、その次の回は知らせない
//   - 除外: 30 日以内に主役になった投稿者（足りなければ古い順に緩める）・通報された投稿・運営の投稿者
//   - 走査の上限（truncated）
//
// ■ 書き方の約束（followBlock.emulator.test.js と同じ型）
//   - Functions のエミュレーターは使わない。runDailyPick を本物の Firestore（エミュレーター）で直接呼ぶ
//     （定期実行が本当に 7 時に起きること・retryCount で起き直すことは、このテストでは見えない。見たと書かない）
//     送る権利の失敗のテストだけ、db をくるんで runTransaction を偽物にする（collection・batch・getAll は本物）
//   - 依存は偽物: notifyOwner は呼ばれた引数を積んで "attempted" を返す・logger は水準と msg を積む・
//     now は固定の瞬間（2026-10-25T07:00:05+09:00 → 鍵 2026-10-25）・rng は常に 0
//   - 期待値は postId・件数・回数を直に書く（何もしない実装で「空と空が一致」して緑にならないように）
//   - 1 つの test に 1 つの確かめを置く（assert は最初の失敗で止まるので、まとめると後ろの結果が見えない）
//   - 各テストの前にエミュレーターの文書を全部消す（demo- のプロジェクトだけ。同じエミュレーターで動く
//     dailyPickRules.emulator.test.js とは --test-concurrency=1 で 1 ファイルずつ走るので重ならない）
//
// ■ 同時実行（テスト「同時実行: …」）
//   ⚠️ 本番の競合挙動は確かめていない。エミュレーターは、競合したトランザクションを ABORTED（SDK が再試行する）でなく
//   INVALID_ARGUMENT（code 3）「Transaction is invalid or closed」で返すことがあり、SDK は再試行しない
//   （2026-10-08 soratomoDeletion.test.js の要確認3で実測）。そのため送る権利の取り合いで負けた側は、
//   "already_claimed" を返す（勝った側の印を読んだ）か、code 3 か 10 の競合でトランザクションが落ちて
//   runDailyPick が投げる（本番では定期実行の再試行に任せる道）かのどちらでもよいとする。
//   投げてよいのは負けた側だけ（2 本とも投げたら赤）。投げた側は戻り値を見られないので、status と notify は
//   投げなかった側だけで確かめる（2 本とも返せば picked と already_picked が 1 本ずつ、1 本ならその status は
//   picked か already_picked で notify は attempted）。
//   1 本目の deps.now()（runDailyPick の最初）を合図に、2 本目を回ごとに 0〜15ms ずらして発火し、6 回並べる。
//   選ぶ段の衝突（ALREADY_EXISTS）が何回起きたかと、負けた側の内訳（already_claimed の回数・投げた回数）は
//   t.diagnostic に出す（片寄りを見る）
//
// ⚠️ 本番へ書く事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、またはプロジェクト ID が
//    demo- で始まらないときは、firebase-admin を読む前に終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。followBlock.emulator.test.js の柵と同じ型。
//
// ⚠️ 陽性対照（実施日を書く）: 先に dailyPick.js をわざと壊して赤になるのを確かめてから通す。壊し方は 4 つ
//    （④ は 2026-10-24 に送る権利のトランザクションの失敗を投げるように直したときに足した）:
//    ① 送る権利のトランザクションを外す（印を見ずに毎回 notifyOwner を呼ぶ）
//       （赤になるはず:「二重実行: notifyOwner は 2 回の合計で 1 回」「二重実行: 2 回目の戻り値は …」
//        「同時実行: …」「通知オフ→オン: 3 回目は送らない …」「notifyOwner が投げる: もう一度呼んでも …」）→ 結果を書く
//    ② 3 で「ログがあれば return」にする（通知の段へ進まない）
//       （必ず赤になるはず:「通知オフ→オン: 2 回目は already_picked・notify attempted」
//        「通知オフ→オン: 2 回目で notifyOwner をちょうど 1 回呼ぶ（相手は candidates[0]）」
//        「通知オフ→オン: 3 回目は送らない …」。
//        「二重実行: 2 回目の戻り値は …」「notifyOwner が投げる: もう一度呼んでも …」も、早く返した回の notify が
//        already_claimed でなければ赤になるはず）→ 結果を書く
//    ③ 30 日除外の recentPrimaries を空にする
//       （必ず赤になるはず:「30 日除外を緩める: 4 番目は W（20 日前）・5 番目は X（10 日前）」
//        「30 日除外を緩める: relaxedCount は 2」。
//        「30 日除外: 候補はちょうど Z・A・B・C・D の 5 人」「30 日除外: 10 日前に主役だった X は候補に入らない」
//        「30 日除外: 過去のログで candidates[1] だっただけの A は除外されない」も赤になるはず。ただしこの 3 件は、
//        クエリが文書 ID 順に返し（post-a1 が先頭）、rng 0 の混ぜ方で先頭の 1 件が落ちる前提に依る）→ 結果を書く
//    ④ claimAndNotify の送る権利のトランザクションの catch を `return "error"` に戻す（投げ直さない＝修正前の形）
//       （必ず赤になるはず:「送る権利のトランザクションが落ちる（権利を取る前）: …」の 1 件（末尾に置いたので番号 54）。
//        「同時実行: …」は、負けた側が競合（code 3 か 10）で落ちる回が出たときだけ赤になる（修正前の実測では 6 回中 0 回
//        だったので、緑のままのことがある）＝赤は 1〜2 件）→ 結果を書く
//    【結果 2026-10-24・修正前】送る権利の失敗を "error" で返していた本体・テスト 53 件の時点（④ とテスト 54 はまだ無い）。
//      リポジトリの本体は触らず、一時フォルダの写しを壊してエミュレーターで流した（番号は node --test の番号）
//      ① 赤 5 件（9・11・12・27・37）＝予言の 5 件どおり
//      ② 赤 6 件（9・12・24・26・27・37）＝必ず赤の 3 件・前提つきの 2 件に加え、同時実行も赤
//      ③ 赤 6 件（38・39・40・42・43・44）＝予言の 5 件に加え「30 日除外を緩める: 1〜3 番目は A・B・C」も赤
//      壊さない本体では 53/53 緑。同時実行の分布は selectCollided 5・loserAlreadyClaimed 6・loserError 0
//      （この数値は修正前の実測。loserError は当時「負けた側が error を返した回数」。衝突の道を実際に通った。
//       ただしエミュレーターでの話で、本番の競合挙動は確かめていない）
//    【結果 2026-10-24・修正後】送る権利の失敗を投げ直す本体・テスト 54 件の時点。写しを壊して流したのは ④ だけ
//      ④ 赤 1 件（54）＝必ず赤の 1 件どおり。食い違いは 1 回目の threwThatError だけ（false＝投げずに "error" を返した）。
//         同時実行は緑のまま（その回の分布 selectCollided 6・loserAlreadyClaimed 6・loserError 0）
//      壊さない本体では 54/54 緑（ルールのテスト 28 件と合わせて 82/82）。同時実行の分布は selectCollided 4・
//      loserAlreadyClaimed 6・loserError 0（loserError は投げた回数）。全エミュレーターテストも 442/442 緑（既存込み）
//      ⚠️ 投げる道（負けた側が code 3 か 10 で投げる）は、ここまでの 3 回の実行で 1 度も通っていない（loserError 0）。
//         同時実行テストの「投げた側」の確かめは書いてあるが、エミュレーターでは確かめられていない
//      テスト 54 は ①・② でも赤になるはず（① は 1 回目が投げずに送る・② は 2 回目が送らずに返る）。未実測
//

"use strict";

// MARK: - 柵（ここより前で firebase-admin を読み込まない）

const FIRESTORE_HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT_ID = process.env.GCLOUD_PROJECT;
const LOOPBACK = /^(127\.0\.0\.1|localhost|\[::1\]):\d+$/;
if (!FIRESTORE_HOST || !LOOPBACK.test(FIRESTORE_HOST)) {
  console.error(
    "Firestore のエミュレーターを指していないため中止した（本番へ書かないため）。" +
      ` firestore=${FIRESTORE_HOST ?? "(未設定)"}`
  );
  process.exit(1);
}
if (!PROJECT_ID || !PROJECT_ID.startsWith("demo-")) {
  console.error(`プロジェクト ID が demo- で始まらないため中止した: ${PROJECT_ID ?? "(未設定)"}`);
  process.exit(1);
}

const test = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");

const dailyPick = require("./dailyPick");

const app = initializeApp({ projectId: PROJECT_ID }, "dailyPickEmulatorTest");
const db = getFirestore(app);

// MARK: - 下ごしらえ

/** エミュレーターの文書を全部消す（demo- のプロジェクトだけ。柵の後でしか呼ばれない） */
async function clearEmulator() {
  const url = `http://${FIRESTORE_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  await res.arrayBuffer();
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
}

test.beforeEach(async () => {
  await clearEmulator();
});

test.after(async () => {
  await deleteApp(app);
});

// MARK: - 時刻と鍵

const DAY_MS = 24 * 3600 * 1000;
/** 定期実行が起きた瞬間（日本時間 7:00:05）。鍵は 2026-10-25 */
const NOW = new Date("2026-10-25T07:00:05+09:00");
const KEY = "2026-10-25";
/** 同じ日の 22:00（日本時間）。鍵は 2026-10-25 のまま・通知の時間帯の外 */
const NIGHT = new Date("2026-10-25T22:00:00+09:00");
/** 翌朝 06:59（日本時間）。7 時より前なので鍵は前日の 2026-10-25・通知の時間帯の外 */
const EARLY_NEXT_MORNING = new Date("2026-10-26T06:59:00+09:00");

// 過去のログの鍵（KEY から数えた日数）
const KEY_3_DAYS_AGO = "2026-10-22";
const KEY_4_DAYS_AGO = "2026-10-21";
const KEY_5_DAYS_AGO = "2026-10-20";
const KEY_6_DAYS_AGO = "2026-10-19";
const KEY_10_DAYS_AGO = "2026-10-15";
const KEY_20_DAYS_AGO = "2026-10-05";
const KEY_31_DAYS_AGO = "2026-09-24"; // 30 日の窓（前日から 30 日分）の外

// MARK: - 偽物の依存

/** notifyOwner の偽物。呼ばれた引数を積み、"attempted" を返す（throws なら積んでから投げる） */
function fakeNotifier({ throws = false } = {}) {
  const calls = [];
  return {
    calls,
    notifyOwner: async (args) => {
      calls.push(args);
      if (throws) throw new Error("わざと失敗");
      return "attempted";
    },
  };
}

/** logger の偽物。呼ばれた水準と msg（と中身）を積む */
function fakeLogger() {
  const entries = [];
  const at = (level) => (msg, obj) => {
    entries.push({ level, msg, obj });
  };
  return { entries, logger: { info: at("info"), warn: at("warn"), error: at("error") } };
}

/** 水準ごとの回数 */
function levelCount(log, level) {
  return log.entries.filter((e) => e.level === level).length;
}

/** runDailyPick に渡す deps（now は呼ぶたびに同じ瞬間の新しい Date・rng は常に 0） */
function makeDeps({ at = NOW, notifier = fakeNotifier(), log = fakeLogger(), maxScan } = {}) {
  const deps = {
    now: () => new Date(at.getTime()),
    rng: () => 0,
    logger: log.logger,
    notifyOwner: notifier.notifyOwner,
  };
  if (maxScan !== undefined) deps.maxScan = maxScan;
  return deps;
}

// MARK: - 文書を置く・読む

const CONFIG_ON = { excludedUserIds: [], notifyEnabled: true };
const CONFIG_OFF = { excludedUserIds: [], notifyEnabled: false };

/** posts/{postId} を置く（クエリが見るのは visibility と userId だけ） */
async function putPost(postId, userId, visibility = "public") {
  await db.collection("posts").doc(postId).set({ userId, visibility });
}

/** dailyPickConfig/settings を置く */
async function putConfig(data) {
  await db.collection("dailyPickConfig").doc("settings").set(data);
}

/** 過去の dailyPickLog/{dateKey} を置く（data は candidates などの中身） */
async function putLog(dateKey, data) {
  await db.collection("dailyPickLog").doc(dateKey).set({ dateKey, ...data });
}

/** reports に 1 件置く（firestore.rules の作成の条件と同じ 5 項目） */
async function putReport(postId, reportedUserId) {
  await db.collection("reports").add({
    postId,
    reporterId: "user-reporter",
    reportedUserId,
    reason: "inappropriate",
    createdAt: NOW,
  });
}

/** dailyPicks/{dateKey} の中身（無ければ null） */
async function pickDoc(dateKey = KEY) {
  const snap = await db.collection("dailyPicks").doc(dateKey).get();
  return snap.exists ? snap.data() : null;
}

/** dailyPickLog/{dateKey} の中身（無ければ null） */
async function logDoc(dateKey = KEY) {
  const snap = await db.collection("dailyPickLog").doc(dateKey).get();
  return snap.exists ? snap.data() : null;
}

/** コレクションの文書の数 */
async function countDocs(collection) {
  return (await db.collection(collection).get()).size;
}

/** 文字列の配列を並べ替えたコピー（集合として比べる） */
const sorted = (values) => [...values].sort();

/** candidates を postId 順に並べ替えたコピー */
const byPostId = (candidates) => [...candidates].sort((a, b) => (a.postId < b.postId ? -1 : a.postId > b.postId ? 1 : 0));

/**
 * 基本の下ごしらえ: 別々の投稿者 3 人の公開投稿と、非公開・フォロワー限定の投稿を 1 件ずつ置く。
 * 選ばれてよいのは post-a・post-b・post-c だけ。
 */
async function seedThreePublicPosts() {
  await putPost("post-a", "user-a");
  await putPost("post-b", "user-b");
  await putPost("post-c", "user-c");
  await putPost("post-private", "user-d", "private");
  await putPost("post-followers", "user-e", "followers");
}

const PUBLIC_THREE = [
  { postId: "post-a", userId: "user-a" },
  { postId: "post-b", userId: "user-b" },
  { postId: "post-c", userId: "user-c" },
];

// MARK: - 1. 流れ

/** 基本の下ごしらえ＋通知オンで 1 回流す */
async function runFlowOnce() {
  await seedThreePublicPosts();
  await putConfig(CONFIG_ON);
  const notifier = fakeNotifier();
  const log = fakeLogger();
  const result = await dailyPick.runDailyPick(db, makeDeps({ notifier, log }));
  return { result, notifier, log };
}

test("流れ: dailyPicks の postIds は公開投稿の 3 件だけ（非公開・フォロワー限定は入らない）", async () => {
  await runFlowOnce();
  assert.deepEqual(sorted((await pickDoc()).postIds), ["post-a", "post-b", "post-c"]);
});

test("流れ: dailyPicks の dateKey は now の日の鍵（2026-10-25）", async () => {
  await runFlowOnce();
  assert.equal((await pickDoc()).dateKey, "2026-10-25");
});

test("流れ: dailyPickLog の candidates は公開投稿 3 件と投稿者の組", async () => {
  await runFlowOnce();
  assert.deepEqual(byPostId((await logDoc()).candidates), PUBLIC_THREE);
});

test("流れ: dailyPickLog の relaxedCount 0・scanned 3・total 3・truncated false・reportedCount 0", async () => {
  await runFlowOnce();
  const { relaxedCount, scanned, total, truncated, reportedCount } = await logDoc();
  assert.deepEqual(
    { relaxedCount, scanned, total, truncated, reportedCount },
    { relaxedCount: 0, scanned: 3, total: 3, truncated: false, reportedCount: 0 }
  );
});

test("流れ: createdAt は now・dailyPickLog の expireAt は now + 90 日", async () => {
  await runFlowOnce();
  const pick = await pickDoc();
  const log = await logDoc();
  assert.deepEqual(
    { pickCreatedAt: pick.createdAt.toMillis(), logCreatedAt: log.createdAt.toMillis(), expireAt: log.expireAt.toMillis() },
    { pickCreatedAt: NOW.getTime(), logCreatedAt: NOW.getTime(), expireAt: NOW.getTime() + 90 * DAY_MS }
  );
});

test("流れ: notifyOwner はちょうど 1 回で、ownerId と postId は candidates[0]", async () => {
  const { notifier } = await runFlowOnce();
  const first = (await logDoc()).candidates[0];
  assert.deepEqual(notifier.calls, [{ ownerId: first.userId, postId: first.postId, dateKey: KEY }]);
});

test("流れ: 印（notifyClaimedAt = now）と結果（notifyResult attempted）が書かれる", async () => {
  await runFlowOnce();
  const log = await logDoc();
  assert.deepEqual(
    { claimedAt: log.notifyClaimedAt && log.notifyClaimedAt.toMillis(), notifyResult: log.notifyResult },
    { claimedAt: NOW.getTime(), notifyResult: "attempted" }
  );
});

test("流れ: 戻り値は picked・件数・notify attempted（uid・postId を含まない）", async () => {
  const { result } = await runFlowOnce();
  assert.deepEqual(result, {
    dateKey: KEY,
    status: "picked",
    candidatesCount: 3,
    relaxedCount: 0,
    scanned: 3,
    total: 3,
    truncated: false,
    reportedCount: 0,
    notify: "attempted",
  });
});

// MARK: - 2. 二重実行（順に 2 回）

/** 基本の下ごしらえ＋通知オンで、同じ notifyOwner の偽物を使って順に 2 回流す */
async function runTwice() {
  await seedThreePublicPosts();
  await putConfig(CONFIG_ON);
  const notifier = fakeNotifier();
  const first = await dailyPick.runDailyPick(db, makeDeps({ notifier }));
  const postIdsAfterFirst = (await pickDoc()).postIds;
  const second = await dailyPick.runDailyPick(db, makeDeps({ notifier }));
  const postIdsAfterSecond = (await pickDoc()).postIds;
  return { first, second, notifier, postIdsAfterFirst, postIdsAfterSecond };
}

test("二重実行: 2 回目の戻り値は already_picked・数値は 1 回目のログの値・notify already_claimed", async () => {
  const { second } = await runTwice();
  assert.deepEqual(second, {
    dateKey: KEY,
    status: "already_picked",
    candidatesCount: 3,
    relaxedCount: 0,
    scanned: 3,
    total: 3,
    truncated: false,
    reportedCount: 0,
    notify: "already_claimed",
  });
});

test("二重実行: 2 回目でも postIds は 1 回目と同じ（3 件）", async () => {
  const { postIdsAfterFirst, postIdsAfterSecond } = await runTwice();
  assert.equal(postIdsAfterFirst.length, 3);
  assert.deepEqual(postIdsAfterSecond, postIdsAfterFirst);
});

test("二重実行: notifyOwner は 2 回の合計で 1 回", async () => {
  const { notifier } = await runTwice();
  assert.equal(notifier.calls.length, 1);
});

// MARK: - 3. 同時実行

test("同時実行: 2 本を並べても dailyPicks は 1 件・notifyOwner は合計 1 回（6 回並べる・本番の競合挙動は確かめていない）", async (t) => {
  // loserError は「負けた側が投げた回数」（送る権利のトランザクションが競合で落ちた回）
  const tally = { selectCollided: 0, loserAlreadyClaimed: 0, loserError: 0 };
  const settle = (p) => p.then((value) => ({ ok: true, value }), (error) => ({ ok: false, error }));
  const later = (ms, fn) => new Promise((resolve) => setTimeout(resolve, ms)).then(fn);
  for (let i = 0; i < 6; i += 1) {
    await clearEmulator();
    await seedThreePublicPosts();
    await putConfig(CONFIG_ON);
    const notifier = fakeNotifier();
    const logA = fakeLogger();
    const logB = fakeLogger();
    const depsA = makeDeps({ notifier, log: logA });
    const depsB = makeDeps({ notifier, log: logB });

    // 1 本目の最初の deps.now() を合図に、2 本目を回ごとに 0〜15ms ずらして発火する
    // （同時に投げるだけだと、片方が毎回先に終わって競合の場面にならないことがある）
    const delay = i * 3;
    let racerB = null;
    const nowA = depsA.now;
    depsA.now = () => {
      if (racerB === null) racerB = settle(later(delay, () => dailyPick.runDailyPick(db, depsB)));
      return nowA();
    };
    const a = await settle(dailyPick.runDailyPick(db, depsA));
    assert.ok(racerB, `回 ${i}: 1 本目の最初で 2 本目を発火できた`);
    const b = await racerB;

    // 投げてよいのは負けた側だけ＝多くて 1 本。理由は送る権利のトランザクションの競合（code 3 か 10）だけを認める
    // （その catch は投げる前に同じ code の warn を出すので、warn にも同じ code があることを見る）
    const runs = [["A", a, logA], ["B", b, logB]];
    const okRuns = runs.filter(([, r]) => r.ok);
    const thrownRuns = runs.filter(([, r]) => !r.ok);
    assert.ok(
      thrownRuns.length <= 1,
      `回 ${i}: 投げたのは多くて 1 本: ${JSON.stringify(thrownRuns.map(([name, r]) => [name, r.error.code, r.error.message]))}`
    );
    for (const [name, r, log] of thrownRuns) {
      const warnCodes = log.entries.filter((e) => e.level === "warn").map((e) => e.obj && e.obj.code);
      assert.ok(
        (r.error.code === 3 || r.error.code === 10) && warnCodes.includes(r.error.code),
        `回 ${i} ${name}: 投げてよいのは送る権利の取り合いの競合（code 3 か 10）だけ: ` +
          `code=${r.error.code} ${r.error.message} warn=${JSON.stringify(warnCodes)}`
      );
      tally.loserError += 1;
    }

    // status と notify は投げなかった側だけで見る（投げた側は戻り値を見られない）
    const statuses = sorted(okRuns.map(([, r]) => r.value.status));
    if (okRuns.length === 2) {
      assert.deepEqual(statuses, ["already_picked", "picked"], `回 ${i}: picked はちょうど 1 本`);
    } else {
      assert.ok(
        statuses[0] === "picked" || statuses[0] === "already_picked",
        `回 ${i}: 投げなかった 1 本の status は picked か already_picked: ${statuses[0]}`
      );
    }
    assert.equal(await countDocs("dailyPicks"), 1, `回 ${i}: dailyPicks は 1 件`);
    assert.equal(notifier.calls.length, 1, `回 ${i}: notifyOwner は合計 1 回`);

    // 送る権利: 勝った側は attempted（投げた側は負けた側なので、勝った側は必ず投げなかった側にいる）。
    // 2 本とも返したときの負けた側は already_claimed だけ（"error" は notifyOwner が投げたときにしか出ず、偽物は投げない）
    const notifies = okRuns.map(([, r]) => r.value.notify);
    assert.equal(notifies.filter((n) => n === "attempted").length, 1, `回 ${i}: attempted はちょうど 1 本`);
    if (okRuns.length === 2) {
      assert.equal(notifies.find((n) => n !== "attempted"), "already_claimed", `回 ${i}: 負けた側の notify は already_claimed`);
      tally.loserAlreadyClaimed += 1;
    }
    // 選ぶ段で衝突した（2 本とも「ログが無い」を見て書きに行き、片方が ALREADY_EXISTS になった）回数
    tally.selectCollided += [...logA.entries, ...logB.entries].filter(
      (e) => e.level === "info" && /ALREADY_EXISTS/.test(e.msg)
    ).length;
  }
  t.diagnostic(`同時実行の分布 ${JSON.stringify(tally)}`);
});

// MARK: - 4. 設定なし・壊れた設定

/** 基本の下ごしらえ（公開投稿 3 件）＋設定 configData（undefined なら置かない）で 1 回流す */
async function runWithConfig(configData) {
  await seedThreePublicPosts();
  if (configData !== undefined) await putConfig(configData);
  const notifier = fakeNotifier();
  const log = fakeLogger();
  const result = await dailyPick.runDailyPick(db, makeDeps({ notifier, log }));
  return { result, notifier, log };
}

const NO_CONFIG_RESULT = {
  dateKey: KEY,
  status: "no_config",
  candidatesCount: 0,
  relaxedCount: 0,
  scanned: 0,
  total: 0,
  truncated: false,
  reportedCount: 0,
  notify: "not_run",
};
const BROKEN_CONFIG = { excludedUserIds: "user-staff", notifyEnabled: true };

test("設定なし: 戻り値は no_config・notify not_run", async () => {
  const { result } = await runWithConfig(undefined);
  assert.deepEqual(result, NO_CONFIG_RESULT);
});

test("設定なし: dailyPicks も dailyPickLog も書かない", async () => {
  await runWithConfig(undefined);
  assert.deepEqual({ picks: await countDocs("dailyPicks"), logs: await countDocs("dailyPickLog") }, { picks: 0, logs: 0 });
});

test("設定なし: notifyOwner を呼ばない", async () => {
  const { notifier } = await runWithConfig(undefined);
  assert.equal(notifier.calls.length, 0);
});

test("設定なし: logger.error がちょうど 1 回（warn は 0 回）", async () => {
  const { log } = await runWithConfig(undefined);
  assert.deepEqual({ error: levelCount(log, "error"), warn: levelCount(log, "warn") }, { error: 1, warn: 0 });
});

test("壊れた設定（excludedUserIds が配列でない）: 戻り値は no_config・notify not_run", async () => {
  const { result } = await runWithConfig(BROKEN_CONFIG);
  assert.deepEqual(result, NO_CONFIG_RESULT);
});

test("壊れた設定（excludedUserIds が配列でない）: dailyPicks も dailyPickLog も書かない", async () => {
  await runWithConfig(BROKEN_CONFIG);
  assert.deepEqual({ picks: await countDocs("dailyPicks"), logs: await countDocs("dailyPickLog") }, { picks: 0, logs: 0 });
});

test("壊れた設定（excludedUserIds が配列でない）: notifyOwner を呼ばない", async () => {
  const { notifier } = await runWithConfig(BROKEN_CONFIG);
  assert.equal(notifier.calls.length, 0);
});

test("壊れた設定（excludedUserIds が配列でない）: logger.error がちょうど 1 回（warn は 0 回）", async () => {
  const { log } = await runWithConfig(BROKEN_CONFIG);
  assert.deepEqual({ error: levelCount(log, "error"), warn: levelCount(log, "warn") }, { error: 1, warn: 0 });
});

// MARK: - 5. 通知オフ→オン

/**
 * 通知オフで 1 回目 → 設定をオンに変えて 2 回目 → そのまま 3 回目（runs 回まで流す）。
 * notifyOwner の偽物は 3 回とも同じものを使う。
 */
async function runOffThenOn(runs) {
  await seedThreePublicPosts();
  await putConfig(CONFIG_OFF);
  const notifier = fakeNotifier();
  const results = [];
  results.push(await dailyPick.runDailyPick(db, makeDeps({ notifier })));
  const postIdsAfterFirst = (await pickDoc()).postIds;
  const logAfterFirst = await logDoc();
  if (runs >= 2) {
    await putConfig(CONFIG_ON);
    results.push(await dailyPick.runDailyPick(db, makeDeps({ notifier })));
  }
  if (runs >= 3) results.push(await dailyPick.runDailyPick(db, makeDeps({ notifier })));
  return { results, notifier, postIdsAfterFirst, logAfterFirst };
}

test("通知オフ: 1 回目は picked・notify skipped_disabled", async () => {
  const { results } = await runOffThenOn(1);
  assert.deepEqual({ status: results[0].status, notify: results[0].notify }, { status: "picked", notify: "skipped_disabled" });
});

test("通知オフ: 1 回目は印（notifyClaimedAt）も結果（notifyResult）も書かない", async () => {
  const { logAfterFirst } = await runOffThenOn(1);
  assert.deepEqual(
    { claimedAt: logAfterFirst.notifyClaimedAt, notifyResult: logAfterFirst.notifyResult },
    { claimedAt: undefined, notifyResult: undefined }
  );
});

test("通知オフ: 1 回目は notifyOwner を呼ばない", async () => {
  const { notifier } = await runOffThenOn(1);
  assert.equal(notifier.calls.length, 0);
});

test("通知オフ→オン: 2 回目は already_picked・notify attempted", async () => {
  const { results } = await runOffThenOn(2);
  assert.deepEqual({ status: results[1].status, notify: results[1].notify }, { status: "already_picked", notify: "attempted" });
});

test("通知オフ→オン: 2 回目でも postIds は変わらない（3 件）", async () => {
  const { postIdsAfterFirst } = await runOffThenOn(2);
  assert.equal(postIdsAfterFirst.length, 3);
  assert.deepEqual((await pickDoc()).postIds, postIdsAfterFirst);
});

test("通知オフ→オン: 2 回目で notifyOwner をちょうど 1 回呼ぶ（相手は candidates[0]）", async () => {
  const { notifier } = await runOffThenOn(2);
  const first = (await logDoc()).candidates[0];
  assert.deepEqual(notifier.calls, [{ ownerId: first.userId, postId: first.postId, dateKey: KEY }]);
});

test("通知オフ→オン: 3 回目は送らない（合計 1 回のまま・notify already_claimed）", async () => {
  const { results, notifier } = await runOffThenOn(3);
  assert.deepEqual({ calls: notifier.calls.length, notify: results[2].notify }, { calls: 1, notify: "already_claimed" });
});

// MARK: - 6. 時間帯の外

/** 基本の下ごしらえ＋通知オンで、now を at にして 1 回流す */
async function runAt(at) {
  await seedThreePublicPosts();
  await putConfig(CONFIG_ON);
  const notifier = fakeNotifier();
  const result = await dailyPick.runDailyPick(db, makeDeps({ at, notifier }));
  return { result, notifier };
}

test("時間帯の外（22:00）: picked・notify skipped_window", async () => {
  const { result } = await runAt(NIGHT);
  assert.deepEqual({ status: result.status, notify: result.notify }, { status: "picked", notify: "skipped_window" });
});

test("時間帯の外（22:00）: 印（notifyClaimedAt）を書かない", async () => {
  await runAt(NIGHT);
  assert.equal((await logDoc()).notifyClaimedAt, undefined);
});

test("時間帯の外（22:00）: notifyOwner を呼ばない", async () => {
  const { notifier } = await runAt(NIGHT);
  assert.equal(notifier.calls.length, 0);
});

test("時間帯の外（翌朝 06:59）: 鍵は前日の 2026-10-25・picked・notify skipped_window", async () => {
  const { result } = await runAt(EARLY_NEXT_MORNING);
  assert.deepEqual(
    { dateKey: result.dateKey, status: result.status, notify: result.notify },
    { dateKey: "2026-10-25", status: "picked", notify: "skipped_window" }
  );
});

test("時間帯の外（翌朝 06:59）: dailyPicks は前日の鍵（2026-10-25）に書かれ、当日の鍵（2026-10-26）には無い", async () => {
  await runAt(EARLY_NEXT_MORNING);
  assert.deepEqual(
    { previousDay: (await pickDoc("2026-10-25")) !== null, sameDay: (await pickDoc("2026-10-26")) !== null },
    { previousDay: true, sameDay: false }
  );
});

test("時間帯の外（翌朝 06:59）: 印を書かず notifyOwner を呼ばない", async () => {
  const { notifier } = await runAt(EARLY_NEXT_MORNING);
  assert.deepEqual(
    { claimedAt: (await logDoc("2026-10-25")).notifyClaimedAt, calls: notifier.calls.length },
    { claimedAt: undefined, calls: 0 }
  );
});

test("時間帯の判定は取り直した時刻で行う（最初 20:59:59・判定のとき 21:00:00 → skipped_window・呼ばない）", async () => {
  await seedThreePublicPosts();
  await putConfig(CONFIG_ON);
  const notifier = fakeNotifier();
  const deps = makeDeps({ notifier });
  const times = [new Date("2026-10-25T20:59:59+09:00"), new Date("2026-10-25T21:00:00+09:00")];
  let nowCalls = 0;
  deps.now = () => new Date(times[Math.min(nowCalls++, times.length - 1)].getTime());
  const result = await dailyPick.runDailyPick(db, deps);
  assert.deepEqual({ notify: result.notify, calls: notifier.calls.length }, { notify: "skipped_window", calls: 0 });
});

// MARK: - 7. notifyOwner が投げる

/** 基本の下ごしらえ＋通知オンで、投げる notifyOwner の偽物を使って 1 回流す（投げたかどうかも返す） */
async function runWithThrowingNotifier() {
  await seedThreePublicPosts();
  await putConfig(CONFIG_ON);
  const notifier = fakeNotifier({ throws: true });
  let result = null;
  let thrown = null;
  try {
    result = await dailyPick.runDailyPick(db, makeDeps({ notifier }));
  } catch (err) {
    thrown = err;
  }
  return { result, thrown, notifier };
}

test("notifyOwner が投げる: runDailyPick は投げず notify error を返す", async () => {
  const { result, thrown } = await runWithThrowingNotifier();
  assert.deepEqual({ thrown: thrown && thrown.message, notify: result && result.notify }, { thrown: null, notify: "error" });
});

test("notifyOwner が投げる: notifyResult は error・notifyClaimedAt は残る", async () => {
  await runWithThrowingNotifier();
  const log = await logDoc();
  assert.deepEqual(
    { notifyResult: log.notifyResult, claimedAt: log.notifyClaimedAt && log.notifyClaimedAt.toMillis() },
    { notifyResult: "error", claimedAt: NOW.getTime() }
  );
});

test("notifyOwner が投げる: もう一度呼んでも notifyOwner は呼ばれない（合計 1 回・notify already_claimed）", async () => {
  const { notifier } = await runWithThrowingNotifier();
  const second = await dailyPick.runDailyPick(db, makeDeps({ notifier }));
  assert.deepEqual({ calls: notifier.calls.length, notify: second.notify }, { calls: 1, notify: "already_claimed" });
});

// MARK: - 8. 30 日除外（きびしい）

/**
 * 投稿者 A・B・C・D・X・Z の公開投稿を 1 件ずつ置き、過去のログを置いて 1 回流す。
 *   - X: 10 日前のログで candidates[0]（主役）→ 除外される
 *   - Z: 31 日前のログで candidates[0] → 30 日の窓の外なので除外されない
 *   - A: 5 日前のログで candidates[1] だっただけ（主役は投稿の無い user-gone）→ 除外されない
 *   - 壊れたログ（candidates が配列でない・candidates が無い・candidates[0] に userId が無い）は飛ばす
 * 文書 ID は post-a1 が先頭に並ぶ（陽性対照 ③ で先頭の A が落ち、X が残るように）
 */
async function runStrictRecentExclusion() {
  for (const user of ["a", "b", "c", "d", "x", "z"]) await putPost(`post-${user}1`, `user-${user}`);
  await putConfig(CONFIG_OFF);
  await putLog(KEY_10_DAYS_AGO, { candidates: [{ postId: "post-x-old", userId: "user-x" }] });
  await putLog(KEY_31_DAYS_AGO, { candidates: [{ postId: "post-z-old", userId: "user-z" }] });
  await putLog(KEY_5_DAYS_AGO, {
    candidates: [
      { postId: "post-gone-old", userId: "user-gone" },
      { postId: "post-a-old", userId: "user-a" },
    ],
  });
  await putLog(KEY_3_DAYS_AGO, { candidates: "壊れた" });
  await putLog(KEY_4_DAYS_AGO, {});
  await putLog(KEY_6_DAYS_AGO, { candidates: [{ postId: "post-broken-old" }] });
  await dailyPick.runDailyPick(db, makeDeps());
  return logDoc();
}

test("30 日除外: 候補はちょうど Z・A・B・C・D の 5 人", async () => {
  const log = await runStrictRecentExclusion();
  assert.deepEqual(sorted(log.candidates.map((c) => c.userId)), ["user-a", "user-b", "user-c", "user-d", "user-z"]);
});

test("30 日除外: 10 日前に主役だった X は候補に入らない", async () => {
  const log = await runStrictRecentExclusion();
  assert.equal(log.candidates.some((c) => c.userId === "user-x"), false);
});

test("30 日除外: 過去のログで candidates[1] だっただけの A は除外されない", async () => {
  const log = await runStrictRecentExclusion();
  assert.equal(log.candidates.some((c) => c.userId === "user-a"), true);
});

test("30 日除外: 足りているので緩めない（relaxedCount 0）", async () => {
  const log = await runStrictRecentExclusion();
  assert.equal(log.relaxedCount, 0);
});

// MARK: - 9. 30 日除外（緩める）

/**
 * 投稿者 A・B・C・W・X の公開投稿を 1 件ずつ置き、X（10 日前に主役）・W（20 日前に主役）のログを置いて 1 回流す。
 * きびしい組は A・B・C の 3 人だけなので、主役になった日が古い順に W → X を足す。
 */
async function runRelaxedRecentExclusion() {
  for (const user of ["a", "b", "c", "w", "x"]) await putPost(`post-${user}1`, `user-${user}`);
  await putConfig(CONFIG_OFF);
  await putLog(KEY_10_DAYS_AGO, { candidates: [{ postId: "post-x-old", userId: "user-x" }] });
  await putLog(KEY_20_DAYS_AGO, { candidates: [{ postId: "post-w-old", userId: "user-w" }] });
  await dailyPick.runDailyPick(db, makeDeps());
  return logDoc();
}

test("30 日除外を緩める: 4 番目は W（20 日前）・5 番目は X（10 日前）", async () => {
  const log = await runRelaxedRecentExclusion();
  assert.deepEqual(log.candidates.slice(3), [
    { postId: "post-w1", userId: "user-w" },
    { postId: "post-x1", userId: "user-x" },
  ]);
});

test("30 日除外を緩める: relaxedCount は 2", async () => {
  const log = await runRelaxedRecentExclusion();
  assert.equal(log.relaxedCount, 2);
});

test("30 日除外を緩める: 1〜3 番目は A・B・C", async () => {
  const log = await runRelaxedRecentExclusion();
  assert.deepEqual(sorted(log.candidates.slice(0, 3).map((c) => c.userId)), ["user-a", "user-b", "user-c"]);
});

// MARK: - 10. 通報除外

/** 投稿者 A の P1（通報あり）と P2 だけを置いて 1 回流す */
async function runReportedExclusion() {
  await putPost("post-p1", "user-a");
  await putPost("post-p2", "user-a");
  await putReport("post-p1", "user-a");
  await putConfig(CONFIG_OFF);
  await dailyPick.runDailyPick(db, makeDeps());
  return { pick: await pickDoc(), log: await logDoc() };
}

test("通報除外: 候補はちょうど [P2]（dailyPicks の postIds も同じ）", async () => {
  const { pick, log } = await runReportedExclusion();
  assert.deepEqual(
    { postIds: pick.postIds, candidates: log.candidates },
    { postIds: ["post-p2"], candidates: [{ postId: "post-p2", userId: "user-a" }] }
  );
});

test("通報除外: reportedCount は 1", async () => {
  const { log } = await runReportedExclusion();
  assert.equal(log.reportedCount, 1);
});

// MARK: - 11. 運営除外

test("運営除外: excludedUserIds の投稿者は選ばれない", async () => {
  await putPost("post-staff1", "user-staff");
  await putPost("post-a1", "user-a");
  await putPost("post-b1", "user-b");
  await putConfig({ excludedUserIds: ["user-staff"], notifyEnabled: false });
  await dailyPick.runDailyPick(db, makeDeps());
  assert.deepEqual(sorted((await logDoc()).candidates.map((c) => c.userId)), ["user-a", "user-b"]);
});

/** 運営の投稿 2 件だけを置き、運営を除外する設定で 1 回流す */
async function runStaffOnly() {
  await putPost("post-staff1", "user-staff");
  await putPost("post-staff2", "user-staff");
  await putConfig({ excludedUserIds: ["user-staff"], notifyEnabled: true });
  const notifier = fakeNotifier();
  const log = fakeLogger();
  const result = await dailyPick.runDailyPick(db, makeDeps({ notifier, log }));
  return { result, notifier, log };
}

test("運営除外: 運営の投稿しか無ければ no_candidates・notify not_run", async () => {
  const { result } = await runStaffOnly();
  assert.deepEqual(result, {
    dateKey: KEY,
    status: "no_candidates",
    candidatesCount: 0,
    relaxedCount: 0,
    scanned: 2,
    total: 2,
    truncated: false,
    reportedCount: 0,
    notify: "not_run",
  });
});

test("運営除外: 運営の投稿しか無ければ文書を書かず、notifyOwner を呼ばず、logger.warn を 1 回出す", async () => {
  const { notifier, log } = await runStaffOnly();
  assert.deepEqual(
    {
      picks: await countDocs("dailyPicks"),
      logs: await countDocs("dailyPickLog"),
      calls: notifier.calls.length,
      warn: levelCount(log, "warn"),
    },
    { picks: 0, logs: 0, calls: 0, warn: 1 }
  );
});

// MARK: - 12. 走査の上限（truncated）

/** 公開投稿 3 件・maxScan 2 で 1 回流す */
async function runTruncated() {
  await seedThreePublicPosts();
  await putConfig(CONFIG_ON);
  const log = fakeLogger();
  const result = await dailyPick.runDailyPick(db, makeDeps({ log, maxScan: 2 }));
  return { result, log };
}

test("truncated: 戻り値は scanned 2・total 3・truncated true", async () => {
  const { result } = await runTruncated();
  assert.deepEqual(
    { scanned: result.scanned, total: result.total, truncated: result.truncated },
    { scanned: 2, total: 3, truncated: true }
  );
});

test("truncated: dailyPickLog にも scanned 2・total 3・truncated true が残る", async () => {
  await runTruncated();
  const { scanned, total, truncated } = await logDoc();
  assert.deepEqual({ scanned, total, truncated }, { scanned: 2, total: 3, truncated: true });
});

test("truncated: logger.warn を 1 回出す", async () => {
  const { log } = await runTruncated();
  assert.equal(levelCount(log, "warn"), 1);
});

// MARK: - logger に uid・postId を出さない

test("logger に uid・postId を出さない（truncated の warn と notifyOwner が投げたときの warn）", async () => {
  await seedThreePublicPosts();
  await putConfig({ excludedUserIds: ["user-staff"], notifyEnabled: true });
  const log = fakeLogger();
  await dailyPick.runDailyPick(db, makeDeps({ log, maxScan: 2, notifier: fakeNotifier({ throws: true }) }));
  // 2 つの warn が出ている（何も出していない「空」で緑にならないように先に数える）
  assert.equal(levelCount(log, "warn"), 2);
  const text = JSON.stringify(log.entries);
  const ids = ["user-a", "user-b", "user-c", "user-d", "user-e", "user-staff", "post-a", "post-b", "post-c"];
  assert.deepEqual(ids.filter((id) => text.includes(id)), []);
});

// MARK: - 13. 送る権利のトランザクションが落ちる（権利を取る前）
// ⚠️ 既存のテストの node --test の番号（陽性対照の記録）を変えないよう、末尾に置く

/**
 * 本物の db をくるみ、runTransaction だけ error で落ちる偽物（1 回目の runDailyPick にだけ渡す）。
 * dailyPick.js が使うほかのもの（collection・batch・getAll）は本物に bind して渡す
 */
function dbWithFailingTransaction(error) {
  return {
    collection: db.collection.bind(db),
    batch: db.batch.bind(db),
    getAll: db.getAll.bind(db),
    runTransaction: async () => {
      throw error;
    },
  };
}

test("送る権利のトランザクションが落ちる（権利を取る前）: 投げる→印も結果も無い→次の回で 1 回だけ送る→その次の回は送らない", async () => {
  await seedThreePublicPosts();
  await putConfig(CONFIG_ON);
  const notifier = fakeNotifier();
  const log = fakeLogger();
  const unavailable = Object.assign(new Error("わざと失敗（UNAVAILABLE 相当）"), { code: 14 });

  // 1 回目: トランザクションだけ落ちる db で流す（選ぶ段は本物で書く）
  let thrown = null;
  try {
    await dailyPick.runDailyPick(dbWithFailingTransaction(unavailable), makeDeps({ notifier, log }));
  } catch (err) {
    thrown = err;
  }
  const logAfterFirst = await logDoc();
  const first = {
    threwThatError: thrown === unavailable,
    logExists: logAfterFirst !== null,
    claimedAt: logAfterFirst ? logAfterFirst.notifyClaimedAt : null,
    notifyResult: logAfterFirst ? logAfterFirst.notifyResult : null,
    calls: notifier.calls.length,
    warnCodes: log.entries.filter((e) => e.level === "warn").map((e) => e.obj && e.obj.code),
  };

  // 2 回目（定期実行の再試行に当たる回）: 本物の db。ログがあるので「選ぶ」を飛ばし、印が無いので取って送る
  const second = await dailyPick.runDailyPick(db, makeDeps({ notifier }));
  const callsAfterSecond = notifier.calls.length;

  // 3 回目: 印があるので送らない
  const third = await dailyPick.runDailyPick(db, makeDeps({ notifier }));

  // 3 回分を集めてから 1 回で比べる（途中の回で止まって、後ろの回が見えなくならないように）
  assert.deepEqual(
    {
      first,
      second: { status: second.status, notify: second.notify, calls: callsAfterSecond },
      third: { status: third.status, notify: third.notify, calls: notifier.calls.length },
    },
    {
      first: { threwThatError: true, logExists: true, claimedAt: undefined, notifyResult: undefined, calls: 0, warnCodes: [14] },
      second: { status: "already_picked", notify: "attempted", calls: 1 },
      third: { status: "already_picked", notify: "already_claimed", calls: 1 },
    }
  );
});
