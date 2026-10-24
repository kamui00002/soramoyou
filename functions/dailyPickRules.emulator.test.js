//
// firestore.rules の「今日のおすすめのそらもよう」の 3 つのコレクション（dailyPicks・dailyPickLog・dailyPickConfig）を、
// Firestore のエミュレーターで本物の要求として評価するテスト ⭐️☁️
// ⚠️ 「私のおすすめの空」（publicProfiles.recommendedPostIds・recommendationNotices）とは別物。
//
// 実行（functions/ の npm run test:emulator に登録済み。--project demo-soramoyou-security で起きる。単体ならリポジトリの根で）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "node --test functions/dailyPickRules.emulator.test.js"
//
// ■ 何を確かめるか
//   - dailyPicks/{yyyy-MM-dd} は、未ログイン（ゲスト）もログイン済みも 1 件ずつ get できる。存在しない鍵は 404
//     （403 でなく 404 が返る＝許可が効いて、文書が無いところまで届いている）
//   - dailyPicks の一覧（list）は、ログインの有無に関わらず拒否（アプリは鍵で get するだけ）
//   - dailyPicks の作成・更新・削除は、ログインの有無に関わらず拒否（書くのは Functions の Admin SDK だけ）
//   - dailyPickLog（候補の投稿者 uid・通知の結果）と dailyPickConfig（運営・テスト用 UID の除外一覧など）は、
//     ログインの有無に関わらず get・list・create のすべてを拒否
//
// ■ 書き方の約束（followsBlockRules.emulator.test.js と同じ型）
//   - 要求は firebase-admin でなく、アプリの SDK と同じ REST の入口に fetch で送る（firebase-admin はルールを通らない）。
//     ID トークンはエミュレーターが受け付ける署名なしの JWT（rules の request.auth.uid は user_id から入る）
//   - 下ごしらえ（文書を置く）は管理者（Bearer owner）で行い、確かめる対象のルールを通さない
//   - 拒否のケースだけでは「判定が効いている」証拠にならない（要求の形の間違いでも 4xx になる）。
//     一覧・作成・更新・削除は、同じ形の要求がルールを通らない管理者なら通ることを「対照」として一緒に見る
//   - ルールは鍵の形（yyyy-MM-dd）を見ないので、文書の ID はテストごと・実行ごとに別にする
//     （同じエミュレーターで dailyPick.emulator.test.js が本物の日付の鍵や dailyPickConfig/settings を書くため、混ぜない。
//       陽性対照で書けてしまった文書が次の実行に残っても、同じ ID に当たらない）
//   - 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろのケースの結果が見えない）
//
// ⚠️ 本番へ要求を送る事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、または
//    プロジェクト ID が demo- で始まらないときは、何も送らずに終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。followsBlockRules.emulator.test.js の柵と同じ型。
//
// ⚠️ 陽性対照（実施日を書く）: 先に「わざと壊した firestore.rules」で赤になるのを確かめてから通す。壊し方は 3 つ:
//    ① dailyPicks の allow get: if true → if request.auth != null
//       （赤になるはず: 未ログインの get と、未ログインの存在しない鍵の 2 件）→ 結果を書く
//    ② dailyPicks の allow write: if false → if true
//       （赤になるはず: dailyPicks の作成・更新・削除 × ログインの有無の 6 件）→ 結果を書く
//    ③ dailyPickLog の allow read, write: if false → allow read: if true; と allow write: if false; に分ける
//       （赤になるはず: dailyPickLog の get と list × ログインの有無の 4 件）→ 結果を書く
//    dailyPickLog・dailyPickConfig はルールが無くても既定で拒否されるので、③ で赤にならなければ、
//    match のパスの書き間違いで「何も確かめていない 403」に化けている。
//    ① ではログイン済みの get が緑のまま残ることで、ログイン済みのトークンが効いていることも分かる。
//    【結果 2026-10-24】リポジトリの firestore.rules は触らず、一時フォルダの写しを壊して読ませた（番号は node --test の番号）
//      ① 赤 2 件（1・3）＝予言どおり。ログイン済みの get（2・4）は緑のまま
//      ② 赤 6 件（8〜13）＝予言どおり
//      ③ 赤 4 件（17〜20）＝予言どおり
//      ④（追加）dailyPickConfig に ③ と同じ壊し方 → 赤 4 件（23〜26）＝get・list × ログインの有無
//      壊さないルールでは 28/28 緑
//

"use strict";

// MARK: - 柵（ここより前で通信しない）

const FIRESTORE_HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT_ID = process.env.GCLOUD_PROJECT;
const LOOPBACK = /^(127\.0\.0\.1|localhost|\[::1\]):\d+$/;
if (!FIRESTORE_HOST || !LOOPBACK.test(FIRESTORE_HOST)) {
  console.error(
    "Firestore のエミュレーターを指していないため中止した（本番へ要求を送らないため）。" +
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

const DOCUMENTS = `projects/${PROJECT_ID}/databases/(default)/documents`;
const FIRESTORE = `http://${FIRESTORE_HOST}/v1/${DOCUMENTS}`;

// MARK: - 道具

/** エミュレーターが受け付ける署名なしの ID トークン（メールとパスワードでログインした人の形） */
function idToken(uid) {
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: `https://securetoken.google.com/${PROJECT_ID}`,
    aud: PROJECT_ID,
    auth_time: now,
    user_id: uid,
    sub: uid,
    iat: now,
    exp: now + 3600,
    firebase: { identities: {}, sign_in_provider: "password" },
  };
  return `${b64({ alg: "none", typ: "JWT" })}.${b64(payload)}.`;
}

/** 認証のヘッダー。null は未ログイン（ヘッダーなし）、ADMIN はエミュレーターの管理者（ルールを通らない） */
const ADMIN = Symbol("admin");
function authHeader(who) {
  if (who === ADMIN) return { Authorization: "Bearer owner" };
  return who ? { Authorization: `Bearer ${idToken(who)}` } : {};
}

/** 文字列の配列を Firestore の REST の値にする（空の配列は values を持たない） */
function stringArray(values) {
  return { arrayValue: values.length ? { values: values.map((v) => ({ stringValue: v })) } : {} };
}

/** 文書へのパス（collection/docId） */
function docPath(collection, docId) {
  return `${collection}/${encodeURIComponent(docId)}`;
}

/** 下ごしらえ: collection/docId を管理者で置く（前提の無い PATCH＝置き直しも同じ） */
async function seed(collection, docId, fields) {
  const res = await fetch(`${FIRESTORE}/${docPath(collection, docId)}`, {
    method: "PATCH",
    headers: { ...authHeader(ADMIN), "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  assert.equal(res.status, 200, `下ごしらえ: ${collection}/${docId} を置けなかった`);
}

/** 1 件を取る（SDK の getDocument と同じ入口）。HTTP の状態を返す */
async function getDoc(who, collection, docId) {
  const res = await fetch(`${FIRESTORE}/${docPath(collection, docId)}`, { headers: authHeader(who) });
  await res.arrayBuffer();
  return res.status;
}

/**
 * 一覧を取る（SDK の getDocuments と同じ runQuery の入口。ルールでは list として評価される）。HTTP の状態を返す。
 * runQuery の応答は配列のストリームなので、状態が 200 でも中に error があればその code を返す
 * （拒否が「200 の中の error」の形で返っても、403 として数えるため）
 */
async function listDocs(who, collection) {
  const res = await fetch(`${FIRESTORE}:runQuery`, {
    method: "POST",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ structuredQuery: { from: [{ collectionId: collection }], limit: 1 } }),
  });
  const text = await res.text();
  if (res.status !== 200) return res.status;
  const parts = [].concat(JSON.parse(text));
  const failed = parts.find((p) => p && p.error);
  return failed ? failed.error.code : 200;
}

/** collection/docId を作る（SDK の addDocument・setData と同じ createDocument の入口）。HTTP の状態を返す */
async function createDoc(who, collection, docId, fields) {
  const res = await fetch(`${FIRESTORE}/${collection}?documentId=${encodeURIComponent(docId)}`, {
    method: "POST",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  return res.status;
}

/**
 * 既にある collection/docId の項目を書き換える（SDK の updateData と同じ、項目を指定し文書がある前提の PATCH。
 * ルールでは update として評価される）。HTTP の状態を返す
 */
async function updateDoc(who, collection, docId, fields) {
  const params = new URLSearchParams({ "currentDocument.exists": "true" });
  for (const key of Object.keys(fields)) params.append("updateMask.fieldPaths", key);
  const res = await fetch(`${FIRESTORE}/${docPath(collection, docId)}?${params}`, {
    method: "PATCH",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  return res.status;
}

/** collection/docId を消す（SDK の delete と同じ入口）。HTTP の状態を返す */
async function deleteDoc(who, collection, docId) {
  const res = await fetch(`${FIRESTORE}/${docPath(collection, docId)}`, { method: "DELETE", headers: authHeader(who) });
  await res.arrayBuffer();
  return res.status;
}

// MARK: - 実行ごとに変える印

const RUN = Date.now().toString(36);
/** テストごとの文書 ID（ルールは鍵の形を見ないので、取り違えないよう用途の名前を付ける） */
const key = (name) => `${name}-${RUN}`;

// MARK: - 文書の中身（計画の形に合わせる。ルールは中身を見ないので、形は読みやすさのため）

/** dailyPicks の中身（dateKey・postIds・createdAt） */
function pickFields(dateKey) {
  return {
    dateKey: { stringValue: dateKey },
    postIds: stringArray([`post-a-${RUN}`, `post-b-${RUN}`]),
    createdAt: { timestampValue: new Date().toISOString() },
  };
}

/** dailyPickLog の中身（候補の postId と投稿者の uid・緩めた数） */
function logFields() {
  return {
    candidates: {
      arrayValue: {
        values: [{
          mapValue: { fields: { postId: { stringValue: `post-a-${RUN}` }, userId: { stringValue: `owner-${RUN}` } } },
        }],
      },
    },
    relaxedCount: { integerValue: "0" },
  };
}

/** dailyPickConfig の中身（除外する UID の一覧・通知のオン/オフ） */
function configFields() {
  return {
    excludedUserIds: stringArray([`staff-${RUN}`]),
    notifyEnabled: { booleanValue: false },
  };
}

// MARK: - 登場人物と鍵

const SIGNED_IN = `signed-in-${RUN}`; // ログイン済みの人（だれでもよい。ルールは uid を見ない）
const GUEST = null; // 未ログイン（ゲスト）

const PICKS = "dailyPicks";
const LOG = "dailyPickLog";
const CONFIG = "dailyPickConfig";

const PICK_KEY = key("pick"); // get で読む（その日の鍵の代わり）
const MISSING_KEY = key("missing"); // どこにも置かない鍵
const UPDATE_KEY = key("update"); // 更新の的（置いておく。消さないので共用）
const DELETE_SIGNED_IN_KEY = key("delete-signed-in"); // 削除の的（壊したルールで消えても、ほかに響かないよう別々）
const DELETE_GUEST_KEY = key("delete-guest");
const DELETE_ADMIN_KEY = key("delete-admin");
const LOG_KEY = key("log");
const CONFIG_KEY = key("config");

test.before(async () => {
  await seed(PICKS, PICK_KEY, pickFields(PICK_KEY));
  await seed(PICKS, UPDATE_KEY, pickFields(UPDATE_KEY));
  await seed(PICKS, DELETE_SIGNED_IN_KEY, pickFields(DELETE_SIGNED_IN_KEY));
  await seed(PICKS, DELETE_GUEST_KEY, pickFields(DELETE_GUEST_KEY));
  await seed(PICKS, DELETE_ADMIN_KEY, pickFields(DELETE_ADMIN_KEY));
  // Log・Config も置いておく（陽性対照 ③ で読めるようにしたとき、404 でなく 200 で赤になるように）
  await seed(LOG, LOG_KEY, logFields());
  await seed(CONFIG, CONFIG_KEY, configFields());
});

// MARK: - dailyPicks の get（ゲストも読む）

test("dailyPicks: 未ログイン（ゲスト）でも、その日の鍵で get できる", async () => {
  assert.equal(await getDoc(GUEST, PICKS, PICK_KEY), 200);
});

test("dailyPicks: ログイン済みでも、その日の鍵で get できる", async () => {
  assert.equal(await getDoc(SIGNED_IN, PICKS, PICK_KEY), 200);
});

// 403 でなく 404 が返る＝許可が効いて、文書が無いところまで届いている（陽性対照 ① ではこちらが 403 になる）
test("dailyPicks: 未ログインで存在しない鍵を get すると 404（403 でない）", async () => {
  assert.equal(await getDoc(GUEST, PICKS, MISSING_KEY), 404);
});

test("dailyPicks: ログイン済みで存在しない鍵を get すると 404（403 でない）", async () => {
  assert.equal(await getDoc(SIGNED_IN, PICKS, MISSING_KEY), 404);
});

// MARK: - dailyPicks の list（一覧は出さない）

test("dailyPicks: 未ログインでは一覧（list）を取れない", async () => {
  assert.equal(await listDocs(GUEST, PICKS), 403);
});

test("dailyPicks: ログイン済みでも一覧（list）を取れない", async () => {
  assert.equal(await listDocs(SIGNED_IN, PICKS), 403);
});

// 上の 403 が「要求の形が間違っている」でなく「ルールで止まった」ことの証拠
test("dailyPicks の対照: 同じ形の一覧は、ルールを通らない管理者なら取れる", async () => {
  assert.equal(await listDocs(ADMIN, PICKS), 200);
});

// MARK: - dailyPicks の書き込み（Functions の Admin SDK だけ）

test("dailyPicks: ログイン済みでは作れない", async () => {
  assert.equal(await createDoc(SIGNED_IN, PICKS, key("create-signed-in"), pickFields(key("create-signed-in"))), 403);
});

test("dailyPicks: 未ログインでは作れない", async () => {
  assert.equal(await createDoc(GUEST, PICKS, key("create-guest"), pickFields(key("create-guest"))), 403);
});

test("dailyPicks: ログイン済みでは、置いてある文書の postIds を書き換えられない（update）", async () => {
  assert.equal(await updateDoc(SIGNED_IN, PICKS, UPDATE_KEY, { postIds: stringArray([`post-x-${RUN}`]) }), 403);
});

test("dailyPicks: 未ログインでは、置いてある文書の postIds を書き換えられない（update）", async () => {
  assert.equal(await updateDoc(GUEST, PICKS, UPDATE_KEY, { postIds: stringArray([`post-x-${RUN}`]) }), 403);
});

test("dailyPicks: ログイン済みでは、置いてある文書を消せない", async () => {
  assert.equal(await deleteDoc(SIGNED_IN, PICKS, DELETE_SIGNED_IN_KEY), 403);
});

test("dailyPicks: 未ログインでは、置いてある文書を消せない", async () => {
  assert.equal(await deleteDoc(GUEST, PICKS, DELETE_GUEST_KEY), 403);
});

// 上の 403 が「要求の形が間違っている」でなく「ルールで止まった」ことの証拠（同じ形の要求を管理者が送ると通る）
test("dailyPicks の対照: 同じ形の作成は、ルールを通らない管理者なら通る", async () => {
  assert.equal(await createDoc(ADMIN, PICKS, key("create-admin"), pickFields(key("create-admin"))), 200);
});

test("dailyPicks の対照: 同じ形の書き換え（update）は、ルールを通らない管理者なら通る", async () => {
  assert.equal(await updateDoc(ADMIN, PICKS, UPDATE_KEY, { postIds: stringArray([`post-x-${RUN}`]) }), 200);
});

test("dailyPicks の対照: 同じ形の削除は、ルールを通らない管理者なら通る", async () => {
  assert.equal(await deleteDoc(ADMIN, PICKS, DELETE_ADMIN_KEY), 200);
});

// MARK: - dailyPickLog（候補の投稿者 uid・通知の結果。非公開）

test("dailyPickLog: 未ログインでは get できない", async () => {
  assert.equal(await getDoc(GUEST, LOG, LOG_KEY), 403);
});

test("dailyPickLog: ログイン済みでも get できない", async () => {
  assert.equal(await getDoc(SIGNED_IN, LOG, LOG_KEY), 403);
});

test("dailyPickLog: 未ログインでは一覧（list）を取れない", async () => {
  assert.equal(await listDocs(GUEST, LOG), 403);
});

test("dailyPickLog: ログイン済みでも一覧（list）を取れない", async () => {
  assert.equal(await listDocs(SIGNED_IN, LOG), 403);
});

test("dailyPickLog: 未ログインでは作れない", async () => {
  assert.equal(await createDoc(GUEST, LOG, key("log-create-guest"), logFields()), 403);
});

test("dailyPickLog: ログイン済みでも作れない", async () => {
  assert.equal(await createDoc(SIGNED_IN, LOG, key("log-create-signed-in"), logFields()), 403);
});

// MARK: - dailyPickConfig（運営・テスト用 UID の除外一覧など。非公開）

test("dailyPickConfig: 未ログインでは get できない", async () => {
  assert.equal(await getDoc(GUEST, CONFIG, CONFIG_KEY), 403);
});

test("dailyPickConfig: ログイン済みでも get できない", async () => {
  assert.equal(await getDoc(SIGNED_IN, CONFIG, CONFIG_KEY), 403);
});

test("dailyPickConfig: 未ログインでは一覧（list）を取れない", async () => {
  assert.equal(await listDocs(GUEST, CONFIG), 403);
});

test("dailyPickConfig: ログイン済みでも一覧（list）を取れない", async () => {
  assert.equal(await listDocs(SIGNED_IN, CONFIG), 403);
});

test("dailyPickConfig: 未ログインでは作れない", async () => {
  assert.equal(await createDoc(GUEST, CONFIG, key("config-create-guest"), configFields()), 403);
});

test("dailyPickConfig: ログイン済みでも作れない", async () => {
  assert.equal(await createDoc(SIGNED_IN, CONFIG, key("config-create-signed-in"), configFields()), 403);
});
