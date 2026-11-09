//
// skyMotionPurchase.js（onSkyMotionPurchaseCreated → verifyAndCredit）が、本物の Firestore（エミュレーター）で
// 購入の付与先を決め、購入 doc に creditedUid と creditedUidBasis を書くことを確かめるテスト ⭐️☁️
//
// 実行（functions/ の npm run test:emulator に登録。--project demo-soramoyou-security で起きる）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "NODE_PATH=node_modules node --test skyMotionPurchase.emulator.test.js"
//
// ■ 何を確かめるか（番号は skyMotionCore.decideCreditRecipient の creditedUidBasis と対応）
//   ① JWS に appAccountToken が無い → 申告者（userId）に付く・no_token
//   ② JWS の token と申告者の users.iapAccountToken が同じ → 申告者・token_match（JWS が大文字でも同じ扱い）
//   ③ 違う・users を token で逆引きして持ち主が見つかる → 持ち主・token_owner・warn が 1 回
//   ④ 違う・持ち主が見つからない → 申告者・token_owner_not_found・error が 1 回（項目は 3 つ）
//   ⑤ 同じ token の users が 2 人 → どちらか 1 人だけに付く・token_owner（どちらに付くかは決めない）
//
// ■ 書き方の約束（followBlock.emulator.test.js・soratomo.test.js と同じ型）
//   - Functions のエミュレーターは使わない。onSkyMotionPurchaseCreated.run() でハンドラーを直接呼ぶ
//     （reconcilePendingSkyMotionPurchases も同じ verifyAndCredit を通るが、このテストでは呼ばない）
//   - 次の 2 つは skyMotionPurchase.js を読む間だけ Module._load を差し替える（soratomo.test.js と同じ方式）:
//     ./skyMotionPurchaseVerify（JWS の検証。テストごとに決めた取引を返す・Apple への通信をしない）・
//     firebase-functions/logger（水準と引数を積む）
//   - skyMotionPurchase.js は読み込んだ時点で既定の app の getFirestore() を使うので、require の前に
//     既定の app を initializeApp で作る
//   - 期待値は uid・値の名前・回数を直に書く（何もしない実装で「空と空が一致」して緑にならないように）
//   - 1 つの test に 1 つの確かめを置く（assert は最初の失敗で止まるので、まとめると後ろの結果が見えない）
//   - 各テストの前にエミュレーターの文書を全部消す（demo- のプロジェクトだけ。npm run test:emulator は
//     --test-concurrency=1 で 1 ファイルずつ走るので、ほかのファイルと重ならない）
//
// ⚠️ 本番へ書く事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、またはプロジェクト ID が
//    demo- で始まらないときは、firebase-admin を読む前に終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。followBlock.emulator.test.js の柵と同じ型。
//
// ⚠️ 陽性対照（2026-11-10 実施）: skyMotionPurchase.js の写しをわざと壊して、skyMotionCore.test.js と合わせた 87 本を流した。
//    壊さない写しは 87 本すべて緑。次の 3 通りの壊し方は、どれも予想どおりのテストだけ赤になった:
//    ① t.update から creditedUidBasis を外す
//       （赤: 「購入 doc は …」の 6 件と、⑤「creditedUidBasis は token_owner …」）
//    ② 持ち主が見つからないときの error の項目を前の形に戻す
//       （赤: ④「error は 1 回で …」・④「申告者の users が無く …」の 2 件）
//    ③ 逆引きの結果を使わない（ownerUid を常に null にする）
//       （赤: ③ の 4 件と ⑤ の 2 件）
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
const Module = require("node:module");

// MARK: - 偽物（skyMotionPurchase.js を読む間だけ差し込む）

/** 記録（各テストの前に空にする）。logs は { level, args }。 */
const record = { logs: [] };
const log = (level) => (...args) => record.logs.push({ level, args });
const fakeLogger = { info: log("info"), warn: log("warn"), error: log("error"), debug: log("debug"), log: log("log") };

/** verifyTransactionJWS が返す結果（テストごとに入れる）。null のまま呼ばれたら投げる。 */
let jwsResult = null;
const fakeVerify = {
  verifyTransactionJWS: async () => {
    if (!jwsResult) throw new Error("テストが JWS の結果を入れていない");
    return jwsResult;
  },
};

const originalLoad = Module._load;
Module._load = function fakeLoad(request, parent, isMain) {
  if (request === "./skyMotionPurchaseVerify") return fakeVerify;
  if (request === "firebase-functions/logger") return fakeLogger;
  return originalLoad.call(this, request, parent, isMain);
};

const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");
const app = initializeApp({ projectId: PROJECT_ID });
const purchase = require("./skyMotionPurchase");
Module._load = originalLoad;
const db = getFirestore(app);

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${FIRESTORE_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  await res.arrayBuffer();
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
  record.logs = [];
  jwsResult = null;
});

test.after(async () => {
  await deleteApp(app);
});

const PACK = "com.yoshidometoru.Soramoyou.skymotion.pack5"; // 5 回パック（skyMotionCore.PACK_CREDITS）
const TX = "2000000123456789"; // 購入 doc の ID ＝ JWS の transactionId
const CLAIMED = "uid-claimed"; // 購入 doc を作った人（userId）
const OWNER = "uid-owner"; // JWS の token を users に持っている人
const OWNER_2 = "uid-owner-2"; // ⑤ で同じ token を持つもう 1 人
const TOKEN_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"; // JWS に入っている token
const TOKEN_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"; // 申告者の users に入っている token

/** users/{uid} を置く（id はアプリの users と同じく uid）。token は iapAccountToken（小文字で保存する規約）。 */
async function putUser(uid, iapAccountToken) {
  await db.collection("users").doc(uid).set({ id: uid, iapAccountToken });
}

/**
 * 申告者 CLAIMED の pending の購入 doc を作り、作成イベントのハンドラーを呼ぶ。
 * @param {string|undefined} appAccountToken JWS に入れる token（undefined なら JWS に項目を入れない）
 */
async function createPurchaseAndRun(appAccountToken) {
  const transaction = { transactionId: TX, productId: PACK };
  if (appAccountToken !== undefined) transaction.appAccountToken = appAccountToken;
  jwsResult = { transaction, environment: "Sandbox" };
  const ref = db.collection("skyMotionPurchases").doc(TX);
  await ref.set({ userId: CLAIMED, status: "pending", productId: PACK, jws: "jws-placeholder", createdAt: Timestamp.now() });
  await purchase.onSkyMotionPurchaseCreated.run({ params: { transactionId: TX }, data: await ref.get() });
}

/** 購入 doc の status・creditedUid・creditedUidBasis */
async function creditFields() {
  const data = (await db.collection("skyMotionPurchases").doc(TX).get()).data();
  return { status: data.status, creditedUid: data.creditedUid, creditedUidBasis: data.creditedUidBasis };
}

/** skyMotionBalance/{uid}.balance（doc が無ければ 0） */
async function balanceOf(uid) {
  const snap = await db.collection("skyMotionBalance").doc(uid).get();
  return snap.exists ? snap.data().balance : 0;
}

/** 指定した水準のログを { msg, fields } の配列で返す */
function logsAt(level) {
  return record.logs.filter((l) => l.level === level).map(({ args: [msg, fields] }) => ({ msg, fields }));
}

// MARK: - ① JWS に token が無い

test("① JWS に token が無い: 購入 doc は credited・creditedUid は申告者・creditedUidBasis は no_token", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await createPurchaseAndRun(undefined);
  assert.deepEqual(await creditFields(), { status: "credited", creditedUid: CLAIMED, creditedUidBasis: "no_token" });
});

test("① JWS に token が無い: 申告者の残高は 5", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await createPurchaseAndRun(undefined);
  assert.equal(await balanceOf(CLAIMED), 5);
});

// MARK: - ② 申告者の token と同じ

test("② token が申告者の users と同じ: 購入 doc は credited・creditedUid は申告者・creditedUidBasis は token_match", async () => {
  await putUser(CLAIMED, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual(await creditFields(), { status: "credited", creditedUid: CLAIMED, creditedUidBasis: "token_match" });
});

test("② token が申告者の users と同じ: 申告者の残高は 5", async () => {
  await putUser(CLAIMED, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  assert.equal(await balanceOf(CLAIMED), 5);
});

test("② JWS の token が大文字で、users は小文字: 購入 doc は申告者・token_match", async () => {
  await putUser(CLAIMED, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A.toUpperCase());
  assert.deepEqual(await creditFields(), { status: "credited", creditedUid: CLAIMED, creditedUidBasis: "token_match" });
});

// MARK: - ③ 違う・持ち主が見つかる

test("③ token が違い、持ち主が見つかる: 購入 doc は credited・creditedUid は持ち主・creditedUidBasis は token_owner", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await putUser(OWNER, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual(await creditFields(), { status: "credited", creditedUid: OWNER, creditedUidBasis: "token_owner" });
});

test("③ token が違い、持ち主が見つかる: 残高は持ち主が 5・申告者が 0", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await putUser(OWNER, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual({ owner: await balanceOf(OWNER), claimed: await balanceOf(CLAIMED) }, { owner: 5, claimed: 0 });
});

test("③ token が違い、持ち主が見つかる: warn は 1 回で、項目は transactionId・claimedUid・creditUid", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await putUser(OWNER, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual(logsAt("warn"), [
    {
      msg: "回数パック: appAccountToken不一致→本来の購入者へ付け替え",
      fields: { transactionId: TX, claimedUid: CLAIMED, creditUid: OWNER },
    },
  ]);
});

test("③ 申告者の users に token が無く、持ち主が見つかる: 購入 doc は持ち主・token_owner", async () => {
  await db.collection("users").doc(CLAIMED).set({ id: CLAIMED });
  await putUser(OWNER, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual(await creditFields(), { status: "credited", creditedUid: OWNER, creditedUidBasis: "token_owner" });
});

// MARK: - ④ 違う・持ち主が見つからない

test("④ token が違い、持ち主が見つからない: 購入 doc は credited・creditedUid は申告者・creditedUidBasis は token_owner_not_found", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual(await creditFields(), {
    status: "credited",
    creditedUid: CLAIMED,
    creditedUidBasis: "token_owner_not_found",
  });
});

test("④ token が違い、持ち主が見つからない: 申告者の残高は 5", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await createPurchaseAndRun(TOKEN_A);
  assert.equal(await balanceOf(CLAIMED), 5);
});

test("④ token が違い、持ち主が見つからない: error は 1 回で、項目は transactionId・uid・claimedTokenPresent（true）", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual(logsAt("error"), [
    {
      msg: "回数パック: appAccountToken不一致だが本来の購入者を特定できず（自己申告uidへ付与・要監査）",
      fields: { transactionId: TX, uid: CLAIMED, claimedTokenPresent: true },
    },
  ]);
});

test("④ 申告者の users が無く、持ち主も見つからない: error は 1 回で、claimedTokenPresent は false", async () => {
  await createPurchaseAndRun(TOKEN_A);
  assert.deepEqual(logsAt("error"), [
    {
      msg: "回数パック: appAccountToken不一致だが本来の購入者を特定できず（自己申告uidへ付与・要監査）",
      fields: { transactionId: TX, uid: CLAIMED, claimedTokenPresent: false },
    },
  ]);
});

// MARK: - ⑤ 同じ token の users が 2 人

test("⑤ 同じ token の users が 2 人: どちらか 1 人の残高が 5・もう 1 人と申告者は 0", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await putUser(OWNER, TOKEN_A);
  await putUser(OWNER_2, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  const owners = [await balanceOf(OWNER), await balanceOf(OWNER_2)].sort((a, b) => a - b);
  assert.deepEqual({ owners, claimed: await balanceOf(CLAIMED) }, { owners: [0, 5], claimed: 0 });
});

test("⑤ 同じ token の users が 2 人: creditedUidBasis は token_owner で、creditedUid は残高が 5 になった方", async () => {
  await putUser(CLAIMED, TOKEN_B);
  await putUser(OWNER, TOKEN_A);
  await putUser(OWNER_2, TOKEN_A);
  await createPurchaseAndRun(TOKEN_A);
  const { creditedUid, creditedUidBasis } = await creditFields();
  assert.deepEqual(
    { creditedUidBasis, isOneOfOwners: [OWNER, OWNER_2].includes(creditedUid), balance: await balanceOf(creditedUid) },
    { creditedUidBasis: "token_owner", isOneOfOwners: true, balance: 5 }
  );
});
