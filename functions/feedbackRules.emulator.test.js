//
// firestore.rules の feedback（ご意見）の「返信用のメールアドレス（replyEmail・任意）」の形を、
// Firestore のエミュレーターで本物の要求として評価するテスト ⭐️☁️
//   - 項目なし・null は通す（古い iOS と Android は replyEmail を書かない＝今までどおり通る）
//   - あるときは「文字列・3〜254 文字・@ 以外の半角の見える文字（! から ~）だけの …@….…」
//     （functions/feedbackMail.js の REPLY_EMAIL_PATTERN と同じ形。2026-11-20 に利用者が決めた）
//
// 実行（functions/ の npm run test:emulator に登録済み。--project demo-soramoyou-security で起きる。単体ならリポジトリの根で）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "node --test functions/feedbackRules.emulator.test.js"
//
// ■ 何を確かめるか（テスト名の頭の「検証N:」は下の番号）
//   検証0: ルールが読まれている（他人の userId では作れない。読まれていないと全部通って、検証2 の緑が嘘になる）
//   検証1: 通る形（欄なしの iOS・Android と同じ鍵の組／いちばん少ない鍵の組／null／正しい形／記号入り／
//          いちばん短い形／254 文字ちょうど）
//   検証2: 通らない形（改行・255 文字・@ なし・@ が 2 つ・空・前後の空白・全角の空白・全角の英字・垂直タブ・
//          ゼロ幅スペース・数値・配列）。どれも検証1 の「正しい形」と replyEmail の 1 か所だけが違う
//
// ■ 書き方の約束（imageUrlShapeRules.emulator.test.js と同じ型）
//   - 要求は firebase-admin でなく、アプリの SDK と同じ REST の入口に fetch で送る（firebase-admin はルールを通らない）。
//     ID トークンはエミュレーターが受け付ける署名なしの JWT（rules の request.auth.uid は user_id から入る）
//   - 拒否のケースは、replyEmail の 1 か所だけが違う「通る側」（検証1）と必ず対にする
//   - 文書 ID・uid は実行ごと・テストごとに変える
//   - 1 つの test に 1 つの確かめだけを置く
//
// ⚠️ 本番へ要求を送る事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、または
//    プロジェクト ID が demo- で始まらないときは、何も送らずに終了コード 1 で止める。skip にはしない。
//
// ⚠️ 直す前の赤: firestore.rules に replyEmail の確かめが無い状態で流すと、検証0 と検証1 は全部緑・
//    検証2 は全部赤になるはず（feedback の create は hasAll なので、余分な鍵の値を見ていない）
//    【結果 2026-11-20】リポジトリの firestore.rules（main と同じ・replyEmail の確かめなし）で流した:
//      検証0 緑 1 件・検証1 緑 7 件・検証2 赤 12 件＝予言どおり（20 件中 緑 8・赤 12）
//
// ⚠️ 陽性対照（Rules を直した後に。実施日を書く）: リポジトリの firestore.rules は触らず、一時フォルダの写しを壊して読ませる。
//    ① feedback の create から isValidReplyEmail(…) の呼び出しを外す（赤になるはず: 検証2 の 12 件）→ 結果を書く
//    ② size() <= 254 を外す（赤になるはず: 検証2 の 255 文字の 1 件）→ 結果を書く
//    ③ 正規表現の 3 つの文字の組を [^@] にする（赤になるはず: 検証2 の改行・前後の空白・全角の空白・全角の英字・
//       垂直タブ・ゼロ幅スペースの 6 件）→ 結果を書く
//    ④ value == null || を外す（赤になるはず: 検証1 の欄なしの 2 件と null の 1 件の 3 件）→ 結果を書く
//    【結果 2026-11-20】直した firestore.rules で 20 件すべて緑。写しを 1 か所ずつ壊して流した（どれも元との差は 1 か所だけ）:
//      ① 赤 12（検証2 の 12 件すべて）・② 赤 1（255 文字）・③ 赤 6（改行・前後の空白・全角の空白・全角の英字・
//      垂直タブ・ゼロ幅スペース）・④ 赤 3（欄なしの 2 件と null）＝ 4 つとも件数とテスト名が予言どおり
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

/** 実行ごと・テストごとに変わる ID */
let seq = 0;
const RUN = Date.now().toString(36);
function freshId(prefix) {
  seq += 1;
  return `${prefix}-${RUN}-${seq}`;
}

/** feedback/{id} を作る（SDK の setData と同じ createDocument の入口）。HTTP の状態を返す */
async function createFeedback(uid, fields) {
  const docId = freshId("FB");
  const res = await fetch(`${FIRESTORE}/feedback?documentId=${encodeURIComponent(docId)}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${idToken(uid)}`, "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  return res.status;
}

const str = (v) => ({ stringValue: v });

/** iOS（Feedback.toFirestoreData）と Android（DocumentBuilders.feedbackCreate）が書く鍵の組 */
function appFields(uid, extra = {}) {
  return {
    userId: str(uid),
    message: str("写真が保存できません"),
    createdAt: { timestampValue: "2026-11-20T05:23:45Z" },
    category: str("bug"),
    appVersion: str("1.18.5 (124)"),
    deviceInfo: str("iOS 26.1 / iPhone"),
    ...extra,
  };
}

/** replyEmail だけを変えて作る */
async function createWithReply(replyEmailValue) {
  const uid = freshId("u");
  return createFeedback(uid, appFields(uid, { replyEmail: replyEmailValue }));
}

const OK = 200;
const DENIED = 403;

// MARK: - 検証0: ルールが読まれている証拠

test("検証0: 他人の userId では作れない（ルールが読まれていなければ通ってしまう）", async () => {
  const uid = freshId("u");
  assert.equal(await createFeedback(uid, appFields(freshId("other"))), DENIED);
});

// MARK: - 検証1: 通る形

test("検証1: 欄なし（iOS・Android の今の鍵の組）は通る", async () => {
  const uid = freshId("u");
  assert.equal(await createFeedback(uid, appFields(uid)), OK);
});

test("検証1: 欄なし（いちばん少ない鍵の組 userId・message・createdAt）は通る", async () => {
  const uid = freshId("u");
  const { userId, message, createdAt } = appFields(uid);
  assert.equal(await createFeedback(uid, { userId, message, createdAt }), OK);
});

test("検証1: null は欄なしと同じに通る", async () => {
  assert.equal(await createWithReply({ nullValue: null }), OK);
});

test("検証1: 正しい形は通る", async () => {
  assert.equal(await createWithReply(str("sora@example.com")), OK);
});

test("検証1: 記号入り（+ . _ -）の正しい形は通る", async () => {
  assert.equal(await createWithReply(str("a.b+tag_x-y@sub.example.co.jp")), OK);
});

test("検証1: いちばん短い形（a@b.c）は通る", async () => {
  assert.equal(await createWithReply(str("a@b.c")), OK);
});

test("検証1: 254 文字ちょうどは通る", async () => {
  const v = `${"a".repeat(64)}@${"b".repeat(185)}.com`;
  assert.equal(v.length, 254);
  assert.equal(await createWithReply(str(v)), OK);
});

// MARK: - 検証2: 通らない形（検証1 の「正しい形」と replyEmail だけが違う）

test("検証2: 末尾の改行は断る", async () => {
  assert.equal(await createWithReply(str("sora@example.com\n")), DENIED);
});

test("検証2: 255 文字は断る", async () => {
  const v = `${"a".repeat(64)}@${"b".repeat(186)}.com`;
  assert.equal(v.length, 255);
  assert.equal(await createWithReply(str(v)), DENIED);
});

test("検証2: @ が無いものは断る", async () => {
  assert.equal(await createWithReply(str("sora.example.com")), DENIED);
});

test("検証2: @ が 2 つのものは断る", async () => {
  assert.equal(await createWithReply(str("sora@x@example.com")), DENIED);
});

test("検証2: 空の文字列は断る", async () => {
  assert.equal(await createWithReply(str("")), DENIED);
});

test("検証2: 前後の空白は断る", async () => {
  assert.equal(await createWithReply(str(" sora@example.com")), DENIED);
});

test("検証2: 全角の空白は断る", async () => {
  assert.equal(await createWithReply(str("sora\u3000@example.com")), DENIED);
});

test("検証2: 全角の英字は断る", async () => {
  assert.equal(await createWithReply(str("\uff53\uff4f\uff52\uff41@example.com")), DENIED);
});

test("検証2: 垂直タブ（Rules の \\s に入らない制御文字）は断る", async () => {
  assert.equal(await createWithReply(str("sora\u000b@example.com")), DENIED);
});

test("検証2: ゼロ幅スペースは断る", async () => {
  assert.equal(await createWithReply(str("sora\u200b@example.com")), DENIED);
});

test("検証2: 数値は断る", async () => {
  assert.equal(await createWithReply({ integerValue: "123" }), DENIED);
});

test("検証2: 配列は断る", async () => {
  assert.equal(await createWithReply({ arrayValue: { values: [str("sora@example.com")] } }), DENIED);
});
