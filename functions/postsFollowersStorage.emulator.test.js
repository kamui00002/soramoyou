//
// storage.rules のフォロワー限定の画像（posts・thumbnails・originals の followers）を、
// Storage と Firestore のエミュレーターで本物の要求として評価するテスト ⭐️☁️
//
// 実行（functions/ の npm run test:emulator に登録。--project demo-soramoyou-security で起きる）:
//   firebase emulators:exec --only firestore,storage --project demo-soramoyou-security \
//     "NODE_PATH=node_modules node --test postsFollowersStorage.emulator.test.js"
//
// ■ 何を確かめるか
//   - 読み取り（get）は「本人」か「持ち主をフォローしている人」だけ。
//     フォローしている＝Firestore に follows/{読む人}_{持ち主} の文書がある（firestore.rules の isFollowing と同じ条件）
//   - 一覧（list）は本人だけ（Android の退会が、投稿の文書から拾えなかった残りの画像を listAll で探して消す）。
//     フォロワー・他人は一覧できない
//   - 保存・削除・public・private のルールは変わっていない
//
// ■ 書き方の約束
//   - 要求は firebase-admin でなく、アプリの SDK と同じ REST の入口に fetch で送る（firebase-admin はルールを通らない）。
//     ID トークンはエミュレーターが受け付ける署名なしの JWT（rules の request.auth.uid は user_id から入る）
//   - 下ごしらえ（画像を置く・follows を作る・消す）は管理者（Bearer owner）で行い、確かめる対象のルールを通さない
//   - ダウンロードのトークン（URL の token=）は付けない。トークンが合えばルールを通らずに開けてしまうので、
//     付けるとルールを確かめたことにならない
//   - ⚠️ Storage のルールの firestore.exists は、Firestore に届かないと「文書が無い」に倒れる
//     （firebase-tools の emulator/storage/rules/runtime.js の fetchFirestoreDocument）。拒否のケースだけでは
//     「判定が効いている」証拠にならないので、フォロワーが「読める」ケースを必ず一緒に見る
//   - 登場人物の uid は実行ごとに変える（同じエミュレーターで何度流しても前の回と混ざらない）
//
// ⚠️ 本番へ要求を送る事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、または
//    プロジェクト ID が demo- で始まらないときは、何も送らずに終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。soratomoStorage.emulator.test.js の柵と同じ型。
//

"use strict";

// MARK: - 柵（ここより前で通信しない）

const STORAGE_HOST = process.env.FIREBASE_STORAGE_EMULATOR_HOST;
const FIRESTORE_HOST = process.env.FIRESTORE_EMULATOR_HOST;
const PROJECT_ID = process.env.GCLOUD_PROJECT;
const LOOPBACK = /^(127\.0\.0\.1|localhost|\[::1\]):\d+$/;
if (!STORAGE_HOST || !LOOPBACK.test(STORAGE_HOST) || !FIRESTORE_HOST || !LOOPBACK.test(FIRESTORE_HOST)) {
  console.error(
    "Storage と Firestore のエミュレーターを指していないため中止した（本番へ要求を送らないため）。" +
      ` storage=${STORAGE_HOST ?? "(未設定)"} firestore=${FIRESTORE_HOST ?? "(未設定)"}`
  );
  process.exit(1);
}
if (!PROJECT_ID || !PROJECT_ID.startsWith("demo-")) {
  console.error(`プロジェクト ID が demo- で始まらないため中止した: ${PROJECT_ID ?? "(未設定)"}`);
  process.exit(1);
}

const test = require("node:test");
const assert = require("node:assert/strict");

const BUCKET = `${PROJECT_ID}.appspot.com`;
const STORAGE = `http://${STORAGE_HOST}/v0/b/${BUCKET}/o`;
const FIRESTORE = `http://${FIRESTORE_HOST}/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

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
  return who ? { Authorization: `Firebase ${idToken(who)}` } : {};
}

/** 画像を 1 枚保存する（multipart の 1 回の要求。Web の SDK の uploadBytes と同じ入口）。HTTP の状態を返す */
async function upload(path, who) {
  const boundary = "followers-test-boundary";
  const meta = JSON.stringify({ name: path, contentType: "image/jpeg" });
  const body = Buffer.concat([
    Buffer.from(`--${boundary}\r\nContent-Type: application/json; charset=utf-8\r\n\r\n${meta}\r\n`),
    Buffer.from(`--${boundary}\r\nContent-Type: image/jpeg\r\n\r\n`),
    Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00]), // JPEG の頭に見立てたバイト（ルールは中身を見ない）
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const res = await fetch(`${STORAGE}?name=${encodeURIComponent(path)}`, {
    method: "POST",
    headers: {
      ...authHeader(who),
      "x-goog-upload-protocol": "multipart",
      "Content-Type": `multipart/related; boundary=${boundary}`,
    },
    body,
  });
  await res.arrayBuffer();
  return res.status;
}

/** 下ごしらえ: 管理者で画像を置く（失敗したらテストを止める） */
async function seed(path) {
  assert.equal(await upload(path, ADMIN), 200, `下ごしらえ: ${path} を置けなかった`);
}

/** 画像の中身を取る（トークンは付けない＝必ずルールを通る）。HTTP の状態を返す */
async function getStatus(path, who) {
  const res = await fetch(`${STORAGE}/${encodeURIComponent(path)}?alt=media`, { headers: authHeader(who) });
  await res.arrayBuffer();
  return res.status;
}

/** フォルダの中身の一覧（SDK の listAll と同じ入口）。HTTP の状態を返す */
async function listStatus(prefix, who) {
  const res = await fetch(`${STORAGE}?${new URLSearchParams({ prefix, delimiter: "/" })}`, {
    headers: authHeader(who),
  });
  await res.arrayBuffer();
  return res.status;
}

/** フォルダの中身の一覧で返ったファイル名（items の name）。一覧できないときはテストを止める */
async function listNames(prefix, who) {
  const res = await fetch(`${STORAGE}?${new URLSearchParams({ prefix, delimiter: "/" })}`, {
    headers: authHeader(who),
  });
  assert.equal(res.status, 200, `一覧できない: ${prefix}`);
  const body = await res.json();
  return (body.items ?? []).map((item) => item.name);
}

/** 画像を削除する。HTTP の状態を返す */
async function deleteStatus(path, who) {
  const res = await fetch(`${STORAGE}/${encodeURIComponent(path)}`, { method: "DELETE", headers: authHeader(who) });
  await res.arrayBuffer();
  return res.status;
}

/** follows/{followerId}_{followeeId} を管理者で作る（アプリの FollowRepository と同じ文書 ID と項目） */
async function follow(followerId, followeeId) {
  const res = await fetch(`${FIRESTORE}/follows?documentId=${encodeURIComponent(`${followerId}_${followeeId}`)}`, {
    method: "POST",
    headers: { ...authHeader(ADMIN), "Content-Type": "application/json" },
    body: JSON.stringify({
      fields: {
        followerId: { stringValue: followerId },
        followeeId: { stringValue: followeeId },
        createdAt: { timestampValue: new Date().toISOString() },
      },
    }),
  });
  assert.equal(res.status, 200, `下ごしらえ: follows/${followerId}_${followeeId} を作れなかった`);
}

/** follows/{followerId}_{followeeId} を管理者で消す（フォロー解除） */
async function unfollow(followerId, followeeId) {
  const res = await fetch(`${FIRESTORE}/follows/${encodeURIComponent(`${followerId}_${followeeId}`)}`, {
    method: "DELETE",
    headers: authHeader(ADMIN),
  });
  assert.equal(res.status, 200, `下ごしらえ: follows/${followerId}_${followeeId} を消せなかった`);
}

// MARK: - 登場人物（実行ごとに uid を変える）

const RUN = Date.now().toString(36);
const OWNER = `owner-${RUN}`; // 写真の持ち主
const FOLLOWER = `follower-${RUN}`; // 持ち主をフォローしている
const STRANGER = `stranger-${RUN}`; // フォローしていない（ログインはしている）
const UNFOLLOWED = `unfollowed-${RUN}`; // フォローしてから解除した
const REVERSE = `reverse-${RUN}`; // 持ち主の方が REVERSE をフォローしているだけ（逆向き）

/** フォロワー限定の画像を置く 3 つの場所 */
const FOLLOWERS_DIRS = ["posts", "thumbnails", "originals"];

// 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろのケースの結果が見えない）
test.before(async () => {
  await follow(FOLLOWER, OWNER);
  await follow(OWNER, REVERSE);
  for (const dir of FOLLOWERS_DIRS) {
    await seed(`${dir}/${OWNER}/followers/p1.jpg`);
    await seed(`${dir}/${OWNER}/followers/p2.jpg`);
  }
});

// MARK: - 読み取り（3 つの場所それぞれ）

for (const dir of FOLLOWERS_DIRS) {
  const path = `${dir}/${OWNER}/followers/p1.jpg`;
  const prefix = `${dir}/${OWNER}/followers/`;

  test(`${dir}: 本人は読める`, async () => {
    assert.equal(await getStatus(path, OWNER), 200);
  });

  // フォロワーが「読める」ことが、firestore.exists が本当に Firestore を読んでいる証拠（届かなければ拒否に倒れる）
  test(`${dir}: フォロワーは読める`, async () => {
    assert.equal(await getStatus(path, FOLLOWER), 200);
  });

  test(`${dir}: フォローしていない他人は読めない`, async () => {
    assert.equal(await getStatus(path, STRANGER), 403);
  });

  test(`${dir}: フォローを解除した人は読めない`, async () => {
    const own = `${dir}/${OWNER}/followers/p2.jpg`;
    await follow(UNFOLLOWED, OWNER);
    assert.equal(await getStatus(own, UNFOLLOWED), 200, "下ごしらえ: フォロー中に読めない");
    await unfollow(UNFOLLOWED, OWNER);
    assert.equal(await getStatus(own, UNFOLLOWED), 403, "フォロー解除の後も読めてしまう");
  });

  test(`${dir}: 逆向き（持ち主がフォローしているだけ）の人は読めない`, async () => {
    assert.equal(await getStatus(path, REVERSE), 403);
  });

  test(`${dir}: 未ログインは読めない`, async () => {
    assert.equal(await getStatus(path, null), 403);
  });

  test(`${dir}: フォローしていない他人は一覧できない`, async () => {
    assert.equal(await listStatus(prefix, STRANGER), 403);
  });

  test(`${dir}: フォロワーも一覧できない`, async () => {
    assert.equal(await listStatus(prefix, FOLLOWER), 403);
  });

  test(`${dir}: 本人は一覧できる（Android の退会が残りの画像を探す）`, async () => {
    assert.equal(await listStatus(prefix, OWNER), 200);
  });

  // 退会に要るのは名前が返ること（空の 200 では残りの画像を消せない）
  test(`${dir}: 本人の一覧に置いた画像の名前が出る`, async () => {
    const names = await listNames(prefix, OWNER);
    assert.ok(names.includes(`${prefix}p1.jpg`), `p1.jpg が無い: ${JSON.stringify(names)}`);
    assert.ok(names.includes(`${prefix}p2.jpg`), `p2.jpg が無い: ${JSON.stringify(names)}`);
  });
}

// MARK: - 変えていないルール（posts だけで代表して見る）

test("posts の followers: 保存と削除は本人だけ（今までどおり）", async () => {
  const path = `posts/${OWNER}/followers/w1.jpg`;
  assert.equal(await upload(path, FOLLOWER), 403, "フォロワーが他人の場所へ保存できてしまう");
  assert.equal(await upload(path, OWNER), 200, "本人が保存できない");
  assert.equal(await deleteStatus(path, FOLLOWER), 403, "フォロワーが他人の画像を消せてしまう");
  assert.ok((await deleteStatus(path, OWNER)) < 300, "本人が消せない");
});

test("posts の public は未ログインでも読める・private は本人だけ（今までどおり）", async () => {
  const pub = `posts/${OWNER}/public/p1.jpg`;
  const priv = `posts/${OWNER}/private/p1.jpg`;
  await seed(pub);
  await seed(priv);
  assert.equal(await getStatus(pub, null), 200, "public を未ログインで読めない");
  assert.equal(await getStatus(priv, OWNER), 200, "private を本人が読めない");
  assert.equal(await getStatus(priv, FOLLOWER), 403, "private をフォロワーが読めてしまう");
});
