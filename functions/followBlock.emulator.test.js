//
// followBlock.js が、本物の Firestore（エミュレーター）で「新しくブロックした相手との両方向のフォロー」だけを
// 消すことを確かめるテスト ⭐️☁️（監査 2-3・PR-B の Functions の半分）
//
// 実行（functions/ の npm run test:emulator に登録。--project demo-soramoyou-security で起きる）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "NODE_PATH=node_modules node --test followBlock.emulator.test.js"
//
// ■ 何を確かめるか
//   - users/{A}.blockedUserIds に B が増えたら、follows/A_B と follows/B_A が消える
//   - 前からブロックしていた相手（C）とのフォロー・関係の無い人（D）とのフォローは残る
//     （ブロックした本人が、ブロックした相手をフォローするのはルールで止めていない。決定 4）
//   - 同じ一覧でもう一度呼ばれても（数え直しで users が書かれて起き直したとき）何も消さない
//   - トリガーの中身（handleUserWritten）は、本物のスナップショット（作成・更新・削除）で同じように動く
//
// ■ 書き方の約束
//   - Functions のエミュレーターは使わない。トリガーの中身を本物のスナップショットで直接呼ぶ
//     （トリガーが本当に起き直して止まることは、このテストでは見えない。見たと書かない）
//   - 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろの結果が見えない）
//   - 各テストの前にエミュレーターの文書を全部消す（demo- のプロジェクトだけ）
//
// ⚠️ 本番へ書く事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、またはプロジェクト ID が
//    demo- で始まらないときは、firebase-admin を読む前に終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。followsBlockRules.emulator.test.js の柵と同じ型。
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
const { getFirestore, Timestamp } = require("firebase-admin/firestore");

const followBlock = require("./followBlock");

const app = initializeApp({ projectId: PROJECT_ID }, "followBlockEmulatorTest");
const db = getFirestore(app);

// MARK: - 下ごしらえ

test.beforeEach(async () => {
  const url = `http://${FIRESTORE_HOST}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`;
  const res = await fetch(url, { method: "DELETE" });
  await res.arrayBuffer();
  assert.equal(res.ok, true, `エミュレーターの文書を消せなかった: HTTP ${res.status}`);
});

test.after(async () => {
  await deleteApp(app);
});

const A = "user-a"; // ブロックする人
const B = "user-b"; // A が新しくブロックする相手
const C = "user-c"; // A が前からブロックしている相手
const D = "user-d"; // 関係の無い人

/** follows/{followerId}_{followeeId} を置く（アプリの Follow.toFirestoreData と同じ 3 項目） */
async function putFollow(followerId, followeeId) {
  await db
    .collection("follows")
    .doc(`${followerId}_${followeeId}`)
    .set({ followerId, followeeId, createdAt: Timestamp.now() });
}

/** follows/{followerId}_{followeeId} があるか */
async function followExists(followerId, followeeId) {
  return (await db.collection("follows").doc(`${followerId}_${followeeId}`).get()).exists;
}

/**
 * 1 つの下ごしらえで、壊し方 3 つ（片方向だけ消す・差分でなく全部消す・関係の無い人まで消す）を見分ける:
 * A が前からブロックしている C に加えて、B を新しくブロックした。
 * 消えてよいのは A_B と B_A だけ。A_C・C_A（前から）と A_D・D_B（関係の無い組）は残る。
 * @returns {Promise<string[]>} removeFollowsForNewBlocks の戻り値
 */
async function blockBWhileAlreadyBlockingC() {
  for (const [f, e] of [[A, B], [B, A], [A, C], [C, A], [A, D], [D, B]]) await putFollow(f, e);
  return followBlock.removeFollowsForNewBlocks(db, A, [C], [C, B]);
}

/**
 * users/{A} を before → after の順に書き（undefined は「文書が無い」）、
 * それぞれの本物のスナップショットで handleUserWritten を呼ぶ（onDocumentWritten の event と同じ形）
 */
async function writeUserAndHandle(beforeData, afterData) {
  const ref = db.collection("users").doc(A);
  if (beforeData === undefined) await ref.delete();
  else await ref.set(beforeData);
  const before = await ref.get();
  if (afterData === undefined) await ref.delete();
  else await ref.set(afterData);
  const after = await ref.get();
  return followBlock.handleUserWritten(db, { params: { userId: A }, data: { before, after } });
}

// MARK: - 新しくブロックした相手との組は消える

test("新しくブロックした相手へのフォロー（A→B）が消える", async () => {
  await blockBWhileAlreadyBlockingC();
  assert.equal(await followExists(A, B), false);
});

test("新しくブロックした相手からのフォロー（B→A）が消える", async () => {
  await blockBWhileAlreadyBlockingC();
  assert.equal(await followExists(B, A), false);
});

test("戻り値は消しに行った 2 件の文書 ID", async () => {
  assert.deepEqual(await blockBWhileAlreadyBlockingC(), [`${A}_${B}`, `${B}_${A}`]);
});

test("フォローが 1 件も無い相手を新しくブロックしても失敗しない（無い文書を消しても何も起きない）", async () => {
  assert.deepEqual(await followBlock.removeFollowsForNewBlocks(db, A, [], [B]), [`${A}_${B}`, `${B}_${A}`]);
});

// MARK: - ほかの組は残る

test("前からブロックしていた相手へのフォロー（A→C）は残る", async () => {
  await blockBWhileAlreadyBlockingC();
  assert.equal(await followExists(A, C), true);
});

test("前からブロックしていた相手からのフォロー（C→A）は残る", async () => {
  await blockBWhileAlreadyBlockingC();
  assert.equal(await followExists(C, A), true);
});

test("関係の無い人へのフォロー（A→D）は残る", async () => {
  await blockBWhileAlreadyBlockingC();
  assert.equal(await followExists(A, D), true);
});

test("ブロックされた相手の、関係の無い人からのフォロー（D→B）は残る", async () => {
  await blockBWhileAlreadyBlockingC();
  assert.equal(await followExists(D, B), true);
});

// MARK: - 起き直し（数え直しで users が書かれ、同じ一覧のままもう一度呼ばれる）

test("同じ一覧でもう一度呼ばれたら、ブロックした本人がフォローし直した A→B を消さない", async () => {
  await blockBWhileAlreadyBlockingC();
  await putFollow(A, B); // 決定 4：ブロックした本人は、ブロックした相手をフォローできる
  assert.deepEqual(await followBlock.removeFollowsForNewBlocks(db, A, [C, B], [C, B]), []);
  assert.equal(await followExists(A, B), true);
});

// MARK: - トリガーの中身（本物のスナップショット）

test("トリガー: users の作成で一覧に B があれば、B→A が消える", async () => {
  await putFollow(B, A);
  await writeUserAndHandle(undefined, { id: A, blockedUserIds: [B] });
  assert.equal(await followExists(B, A), false);
});

test("トリガー: 更新で B が増えたら、A→B が消える", async () => {
  await putFollow(A, B);
  await writeUserAndHandle({ id: A, blockedUserIds: [C] }, { id: A, blockedUserIds: [C, B] });
  assert.equal(await followExists(A, B), false);
});

test("トリガー: 更新でも前からいた C とのフォロー（C→A）は残る", async () => {
  await putFollow(C, A);
  await writeUserAndHandle({ id: A, blockedUserIds: [C] }, { id: A, blockedUserIds: [C, B] });
  assert.equal(await followExists(C, A), true);
});

test("トリガー: ブロック解除（一覧から減った）ではフォローを消さない", async () => {
  await putFollow(A, B);
  await writeUserAndHandle({ id: A, blockedUserIds: [B] }, { id: A, blockedUserIds: [] });
  assert.equal(await followExists(A, B), true);
});

test("トリガー: users の削除ではフォローを消さない（退会の follows は退会の処理が消す）", async () => {
  await putFollow(A, B);
  await writeUserAndHandle({ id: A, blockedUserIds: [B] }, undefined);
  assert.equal(await followExists(A, B), true);
});
