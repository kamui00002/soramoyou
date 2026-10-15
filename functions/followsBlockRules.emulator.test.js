//
// firestore.rules の follows の作成に「ブロックされた人は、ブロックした人をフォローできない」を足したことを、
// Firestore のエミュレーターで本物の要求として評価するテスト ⭐️☁️（監査 2-3）
//
// 実行（functions/ の npm run test:emulator に登録。--project demo-soramoyou-security で起きる）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "node --test functions/followsBlockRules.emulator.test.js"
//
// ■ 何を確かめるか
//   - follows/{自分}_{相手} を作れないのは、相手の users/{相手}.blockedUserIds に自分がいるときだけ
//   - 見るのは相手の一覧だけ。ブロックした本人が、ブロックした相手をフォローするのは今までどおり作れる
//   - 相手の users 文書が無い・blockedUserIds の項目が無い・空のときは作れる
//     （一覧は users 文書の中にあるので、文書や項目が無い＝誰もブロックしていない。
//       登録の途中で users を作りそこねた人もいるので、文書が無い相手を拒否にはしない）
//   - 他人の名義・文書の ID と中身の食い違い・未ログイン・欄の不足は今までどおり拒否
//   - ブロックの確認が頼っている約束（緩めると確認をすり抜けられるので、守っていることをここで見る）:
//     本人以外は他人の blockedUserIds を書き換えられない（ブロックされた人が自分を一覧から消せない）・
//     本人以外は他人の users 文書を消せない（文書が無い＝許可に持ち込めない）・
//     follows は作ったあとに書き換えられない（followeeId を変えて確認を迂回できない）
//
// ■ 書き方の約束
//   - 要求は firebase-admin でなく、アプリの SDK と同じ REST の入口に fetch で送る（firebase-admin はルールを通らない）。
//     ID トークンはエミュレーターが受け付ける署名なしの JWT（rules の request.auth.uid は user_id から入る）
//   - 下ごしらえ（users を置く・ブロックを解除する）は管理者（Bearer owner）で行い、確かめる対象のルールを通さない
//   - アプリ（FollowRepository.follow）はトランザクションの set で作る。前提の無い set も、文書が無ければ
//     ルールでは create として評価されるので、commit の入口でも同じ結果になることを見る
//   - 拒否のケースだけでは「判定が効いている」証拠にならない（トークンの作り間違いでも 403 になる）。
//     同じ入口で「ブロックされていない人は作れる」を必ず一緒に見る
//   - 作れたフォローは残るので、登場人物の uid はテストごとに別にし、実行ごとにも変える
//     （同じ文書 ID に 2 回目を送ると、create でなく update として評価されて別の理由で拒否される）
//
// ⚠️ 本番へ要求を送る事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、または
//    プロジェクト ID が demo- で始まらないときは、何も送らずに終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。postsFollowersStorage.emulator.test.js の柵と同じ型。
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

/**
 * 下ごしらえ: users/{uid} を管理者で置く（置き直しも同じ）。
 * blockedUserIds が undefined なら項目そのものを持たない（User.swift の blockedUserIds は Optional で、
 * ブロックしたことの無い人の文書にはこの項目が無い）
 */
async function putUser(uid, blockedUserIds) {
  const fields = { id: { stringValue: uid }, createdAt: { timestampValue: new Date().toISOString() } };
  if (blockedUserIds !== undefined) fields.blockedUserIds = stringArray(blockedUserIds);
  const res = await fetch(`${FIRESTORE}/users/${encodeURIComponent(uid)}`, {
    method: "PATCH",
    headers: { ...authHeader(ADMIN), "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  assert.equal(res.status, 200, `下ごしらえ: users/${uid} を置けなかった`);
}

/** follows の文書の中身（アプリの Follow.toFirestoreData と同じ 3 項目）。omit に書いた項目は入れない */
function followFields(followerId, followeeId, omit = []) {
  const fields = {
    followerId: { stringValue: followerId },
    followeeId: { stringValue: followeeId },
    createdAt: { timestampValue: new Date().toISOString() },
  };
  for (const key of omit) delete fields[key];
  return fields;
}

/** follows/{docId} を作る（SDK の addDocument・setData と同じ createDocument の入口）。HTTP の状態を返す */
async function createFollow(who, docId, fields) {
  const res = await fetch(`${FIRESTORE}/follows?documentId=${encodeURIComponent(docId)}`, {
    method: "POST",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  return res.status;
}

/** follows/{docId} を前提の無い set で書く（アプリのトランザクションの set と同じ commit の入口）。HTTP の状態を返す */
async function commitFollow(who, docId, fields) {
  const res = await fetch(`${FIRESTORE}:commit`, {
    method: "POST",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ writes: [{ update: { name: `${DOCUMENTS}/follows/${docId}`, fields } }] }),
  });
  await res.arrayBuffer();
  return res.status;
}

/** follower が followee をフォローする（ふつうの形）。HTTP の状態を返す */
function follow(follower, followee) {
  return createFollow(follower, `${follower}_${followee}`, followFields(follower, followee));
}

/**
 * users/{owner}.blockedUserIds から values を取り除く（アプリの FieldValue.arrayRemove と同じ、
 * 文書がある前提の commit。updateData と同じく項目を指定しない更新＋変換の形）。HTTP の状態を返す
 */
async function arrayRemoveBlocked(who, owner, values) {
  const res = await fetch(`${FIRESTORE}:commit`, {
    method: "POST",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({
      writes: [{
        update: { name: `${DOCUMENTS}/users/${owner}`, fields: {} },
        updateMask: { fieldPaths: [] },
        updateTransforms: [{ fieldPath: "blockedUserIds", removeAllFromArray: stringArray(values).arrayValue }],
        currentDocument: { exists: true },
      }],
    }),
  });
  await res.arrayBuffer();
  return res.status;
}

/** users/{owner} を消す（SDK の delete と同じ入口）。HTTP の状態を返す */
async function deleteUser(who, owner) {
  const res = await fetch(`${FIRESTORE}/users/${encodeURIComponent(owner)}`, { method: "DELETE", headers: authHeader(who) });
  await res.arrayBuffer();
  return res.status;
}

/** follows/{docId} の followeeId だけを書き換える（SDK の updateData と同じ、項目を指定した PATCH）。HTTP の状態を返す */
async function patchFolloweeId(who, docId, followeeId) {
  const params = new URLSearchParams({ "updateMask.fieldPaths": "followeeId", "currentDocument.exists": "true" });
  const res = await fetch(`${FIRESTORE}/follows/${encodeURIComponent(docId)}?${params}`, {
    method: "PATCH",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ fields: { followeeId: { stringValue: followeeId } } }),
  });
  await res.arrayBuffer();
  return res.status;
}

// MARK: - 登場人物（実行ごとに uid を変える。フォローする側はテストごとに別の人）

const RUN = Date.now().toString(36);
const uid = (name) => `${name}-${RUN}`;

const BLOCKER = uid("blocker"); // BLOCKED・BLOCKED2 をブロックしている
const BLOCKED = uid("blocked"); // BLOCKER にブロックされている（自分の文書に blockedUserIds の項目は無い）
const BLOCKED2 = uid("blocked2"); // BLOCKER にブロックされている（commit の入口で使う）
const NO_FIELD = uid("nofield"); // users はあるが blockedUserIds の項目が無い
const EMPTY_LIST = uid("emptylist"); // blockedUserIds が空の配列
const BLOCKS_OTHERS = uid("blocksothers"); // 関係の無い人だけをブロックしている
const NO_DOC = uid("nodoc"); // users 文書が無い（登録の途中で作りそこねた人など）
const UNBLOCKER = uid("unblocker"); // UNBLOCKED をブロックして、あとで解除する
const UNBLOCKED = uid("unblocked");
// 約束のテスト用（ほかのテストの文書を書き換えないよう、別の人にする）
const GUARD_OWNER = uid("guard-owner"); // GUARD_BLOCKED をブロックしている
const GUARD_BLOCKED = uid("guard-blocked");
const SELF_EDITOR = uid("self-editor"); // 自分の一覧を自分で書き換える（対照）
const SELF_DELETER = uid("self-deleter"); // 自分の users を自分で消す（対照）

test.before(async () => {
  await putUser(GUARD_OWNER, [GUARD_BLOCKED]);
  await putUser(GUARD_BLOCKED);
  await putUser(SELF_EDITOR, [GUARD_BLOCKED]);
  await putUser(SELF_DELETER, [GUARD_BLOCKED]);
  await putUser(BLOCKER, [BLOCKED, BLOCKED2]);
  await putUser(BLOCKED);
  await putUser(BLOCKED2);
  await putUser(NO_FIELD);
  await putUser(EMPTY_LIST, []);
  await putUser(BLOCKS_OTHERS, [uid("someone")]);
  await putUser(UNBLOCKER, [UNBLOCKED]);
  await putUser(UNBLOCKED);
});

// 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろのケースの結果が見えない）

// MARK: - ブロック

test("ブロックされた人は、ブロックした人をフォローできない", async () => {
  assert.equal(await follow(BLOCKED, BLOCKER), 403);
});

test("ブロックされた人は、アプリと同じ set（commit）でもフォローできない", async () => {
  assert.equal(await commitFollow(BLOCKED2, `${BLOCKED2}_${BLOCKER}`, followFields(BLOCKED2, BLOCKER)), 403);
});

// 上の 2 つの 403 が「一覧を読んで拒否した」ことの証拠（同じ入口・同じ相手で、ブロックされていない人は通る）
test("ブロックされていない人は、ブロックしている人（ほかの人を）をフォローできる", async () => {
  assert.equal(await follow(uid("stranger"), BLOCKER), 200);
});

test("ブロックされていない人は、アプリと同じ set（commit）でもフォローできる", async () => {
  const me = uid("stranger2");
  assert.equal(await commitFollow(me, `${me}_${BLOCKER}`, followFields(me, BLOCKER)), 200);
});

test("ブロックした本人は、ブロックした相手をフォローできる（見るのは相手の一覧だけ）", async () => {
  assert.equal(await follow(BLOCKER, BLOCKED), 200);
});

test("ブロックを解除されたら、またフォローできる", async () => {
  assert.equal(await follow(UNBLOCKED, UNBLOCKER), 403, "ブロック中にフォローできてしまう（解除を確かめる前提が崩れている）");
  await putUser(UNBLOCKER, []);
  assert.equal(await follow(UNBLOCKED, UNBLOCKER), 200, "ブロックを解除してもフォローできない");
});

// MARK: - 相手の一覧が無い・空

test("相手の users に blockedUserIds の項目が無ければフォローできる", async () => {
  assert.equal(await follow(uid("f-nofield"), NO_FIELD), 200);
});

test("相手の blockedUserIds が空ならフォローできる", async () => {
  assert.equal(await follow(uid("f-emptylist"), EMPTY_LIST), 200);
});

test("相手が関係の無い人だけをブロックしていればフォローできる", async () => {
  assert.equal(await follow(uid("f-blocksothers"), BLOCKS_OTHERS), 200);
});

test("相手の users 文書が無くてもフォローできる（一覧が無い＝誰もブロックしていない）", async () => {
  assert.equal(await follow(uid("f-nodoc"), NO_DOC), 200);
});

// MARK: - 変えていないルール

// 文書の ID は自分のものにして、中身のフォロワーだけを他人にする（ID の確認でなく、名義の確認で落ちることを見る）
test("中身のフォロワーが他人だと作れない（今までどおり）", async () => {
  const me = uid("impostor");
  assert.equal(await createFollow(me, `${me}_${NO_FIELD}`, followFields(uid("someone-else"), NO_FIELD)), 403);
});

test("文書の ID と中身の相手が食い違うと作れない（今までどおり）", async () => {
  const me = uid("mismatch");
  assert.equal(await createFollow(me, `${me}_${NO_FIELD}`, followFields(me, EMPTY_LIST)), 403);
});

test("未ログインではフォローを作れない（今までどおり）", async () => {
  const me = uid("anon");
  assert.equal(await createFollow(null, `${me}_${NO_FIELD}`, followFields(me, NO_FIELD)), 403);
});

test("createdAt が無いと作れない（今までどおり）", async () => {
  const me = uid("nocreatedat");
  assert.equal(await createFollow(me, `${me}_${NO_FIELD}`, followFields(me, NO_FIELD, ["createdAt"])), 403);
});

// MARK: - ブロックの確認が頼っている約束（firestore.rules の users の update・delete と、follows の update）

test("約束: ブロックされた人は、相手の blockedUserIds から自分を消せない", async () => {
  assert.equal(await arrayRemoveBlocked(GUARD_BLOCKED, GUARD_OWNER, [GUARD_BLOCKED]), 403);
});

// 上の 403 が「要求の形が間違っている」でなく「本人でないから止まった」ことの証拠（同じ形の要求を本人が送ると通る）
test("約束の対照: 本人は、自分の blockedUserIds から取り除ける（アプリのブロック解除）", async () => {
  assert.equal(await arrayRemoveBlocked(SELF_EDITOR, SELF_EDITOR, [GUARD_BLOCKED]), 200);
});

test("約束: ブロックされた人は、相手の users 文書を消せない（文書が無い＝許可に持ち込めない）", async () => {
  assert.equal(await deleteUser(GUARD_BLOCKED, GUARD_OWNER), 403);
});

test("約束の対照: 本人は、自分の users 文書を消せる（アプリの退会）", async () => {
  assert.equal(await deleteUser(SELF_DELETER, SELF_DELETER), 200);
});

// 下ごしらえのフォローは管理者で作る（作成のルールを壊したときに、こちらまで下ごしらえで落ちて見分けがつかなくならないように）
test("約束: 作ったフォローの followeeId を、作った本人も書き換えられない", async () => {
  const me = uid("patcher");
  const docId = `${me}_${NO_FIELD}`;
  assert.equal(await createFollow(ADMIN, docId, followFields(me, NO_FIELD)), 200, "下ごしらえ: フォローを置けなかった");
  assert.equal(await patchFolloweeId(me, docId, GUARD_OWNER), 403);
});

// 上の 403 が「要求の形が間違っている」でないことの証拠（ルールを通らない管理者なら、同じ形の要求が通る）
test("約束の対照: 同じ形の書き換えは、ルールを通らない管理者なら通る", async () => {
  const me = uid("patcher-admin");
  const docId = `${me}_${NO_FIELD}`;
  assert.equal(await createFollow(ADMIN, docId, followFields(me, NO_FIELD)), 200, "下ごしらえ: フォローを置けなかった");
  assert.equal(await patchFolloweeId(ADMIN, docId, GUARD_OWNER), 200);
});
