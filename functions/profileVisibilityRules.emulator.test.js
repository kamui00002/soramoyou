//
// firestore.rules の「プロフィールの見せる/見せない切り替え」（1.18.0）の 2 か所を、
// Firestore のエミュレーターで本物の要求として評価するテスト ⭐️☁️
//   - users/{userId}/favorites の読み取り: 持ち主が publicProfiles.showsFavorites を true にしたときだけ、フォロワーも読める
//   - publicProfiles の作成・更新: showsRecommendedSkies・showsSkyCalendar・showsFavorites は「無い」か Bool だけ
//
// 実行（functions/ の npm run test:emulator に登録済み。--project demo-soramoyou-security で起きる。単体ならリポジトリの根で）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "node --test functions/profileVisibilityRules.emulator.test.js"
//
// ■ 何を確かめるか（テスト名の頭の「検証N:」は計画書の「検証」節の番号）
//   検証1: 持ち主は自分のお気に入りを get・list できる（ON・OFF とも）。持ち主は limit なしの一覧も取れる（上限に縛られない）
//   検証2: フォロワー＋ON は list（limit 30）と get ができる。存在しない postId の get は 404
//          （403 でなく 404 が返る＝許可が効いて、文書が無いところまで届いている）
//   検証3: フォロワー＋OFF・フォロワー＋項目なし（showsFavorites が無い）は get・list とも拒否
//   検証4: フォロワーでない人＋ON は get・list とも拒否
//   検証5: 未ログイン＋ON は get・list とも拒否
//   検証6: フォロワー＋publicProfiles が無い持ち主は get・list とも拒否（get() が失敗して閉じる側に倒れる）
//   検証7: フォロワー＋ON でも limit 31 の一覧は拒否
//   検証8: 他人（ON の持ち主のフォロワー）の作成・更新・削除は今どおり拒否。持ち主本人は同じ形の作成・削除ができる（対照）
//   検証9: publicProfiles の作成・更新で 3 つの項目に文字列を書くと拒否。Bool なら通る（対照）
//   検証10: フォロワー＋ON でも limit なしの一覧は拒否（アプリは常に limit を付けるが、ルールの意図を固定する）
//   レビューで足した 4 本（node --test の番号 32〜35。1〜31 を動かさないよう末尾に置いた）:
//     32 検証8 の対照: 持ち主本人の update（21 のフォロワーの update 403 の対照。set(冪等) の書き直しが通ることの回帰）
//     33 検証9 の対照: 3 つとも無い作成（今のアプリの createPublicProfile の形。項目が無い作成を拒否しないことの回帰）
//     34 検証1: publicProfiles が無い持ち主も自分のお気に入りを get できる（持ち主の読み取りが publicProfiles に依らないことの回帰）
//     35 検証1: 持ち主は並べ替えなし・limit なしの一覧を取れる（退会 deleteUserData の favorites の全件読みが止まらないことの回帰）
//
// ■ 書き方の約束（dailyPickRules.emulator.test.js・followsBlockRules.emulator.test.js と同じ型）
//   - 要求は firebase-admin でなく、アプリの SDK と同じ REST の入口に fetch で送る（firebase-admin はルールを通らない）。
//     ID トークンはエミュレーターが受け付ける署名なしの JWT（rules の request.auth.uid は user_id から入る）
//   - 下ごしらえ（publicProfiles・follows・favorites を置く）は管理者（Bearer owner）で行い、確かめる対象のルールを通さない
//   - 拒否のケースだけでは「判定が効いている」証拠にならない（要求の形の間違いでも 4xx になる）。
//     読み取りの拒否は、同じ形の要求が「フォロワー＋ON」「持ち主」なら通ることを対照として一緒に見る。
//     書き込みの拒否は、同じ形の要求が持ち主本人なら通ることを対照として一緒に見る
//   - ⚠️ favorites はサブコレクション。一覧は親の文書（users/{持ち主}）の :runQuery に送り、from は collectionId だけにする
//     （アプリの fetchFavorites と同じ order(by: createdAt, descending) ＋ limit の形）。
//     ルート直下の :runQuery に送ると、存在しないトップの favorites への要求になって 403 が返り、
//     拒否のテストが全部「何も確かめていない緑」に化ける。持ち主の一覧が 200 になること＝親のパスが正しい証拠
//   - 登場人物の uid は実行ごとに変える。書き込み系・publicProfiles の更新系のテストは、読み取りのテストの持ち主とは
//     別の uid を使う（陽性対照で書けてしまっても、ほかのテストに響かないように）
//   - 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろのケースの結果が見えない）
//
// ⚠️ 本番へ要求を送る事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、または
//    プロジェクト ID が demo- で始まらないときは、何も送らずに終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。followsBlockRules.emulator.test.js の柵と同じ型。
//
// ⚠️ 陽性対照（実施日を書く）: 先に「わざと壊した firestore.rules」で赤になるのを確かめてから通す。
//    リポジトリの firestore.rules は触らず、一時フォルダの写しを壊して読ませる。
//    拒否のテストは「&& のどれかで落ちた」としか言えない（Firestore のルールは && の片方が false なら、
//    もう片方のエラーを捨てる）ので、陽性対照は許可側を緩める形で取る。壊し方は 5 つ:
//    ① canReadFavoritesOf から `isFollowing(userId) &&` を外す
//       （赤になるはず: 検証4 の 2 件と検証5 の 2 件。未ログインでも get() で ON が読めて許可されるため）→ 結果を書く
//    ② canReadFavoritesOf から showsFavorites の比較を外す（isFollowing だけにする）
//       （赤になるはず: 検証3 の 4 件と検証6 の 2 件）→ 結果を書く
//    ③ favorites の allow list から `request.query.limit <= 30 &&` を外す
//       （赤になるはず: 検証7 と検証10 の 2 件）→ 結果を書く
//    ④ publicProfiles の create と update から `isValidProfileVisibility` を外す
//       （赤になるはず: 検証9 の文字列の 4 件）→ 結果を書く
//    ⑤ isValidProfileVisibility の showsFavorites の行の `!` を外す
//       （`(!('showsFavorites' in data) || …)` → `(('showsFavorites' in data) || …)`）
//       （赤になるはず: 25・29・33。33 は「項目が無い」側の枝を通ることの証拠）→ 結果を書く
//    【結果 2026-10-24】リポジトリの firestore.rules は触らず、一時フォルダの写しを壊して読ませた（番号は node --test の番号）
//      ① 赤 4 件（13〜16）＝予言どおり
//      ② 赤 6 件（9〜12・17・18）＝予言どおり
//      ③ 赤 2 件（19・31）＝予言どおり
//      ④ 赤 4 件（25・27・28・29）＝予言どおり
//      ⑤ 赤 3 件（25・29・33）＝予言どおり
//      レビューで 32〜35 を足したあと、①〜⑤ をすべて流し直した（①〜④ の赤は上と同じ番号のまま・32〜35 は ①〜④ で緑）
//      壊さないルールでは 35/35 緑
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

/** 持ち主のお気に入りのコレクションのパス（サブコレクションなので親の文書を含む） */
function favoritesOf(owner) {
  return `users/${encodeURIComponent(owner)}/favorites`;
}

/** 文書へのパス（collection/docId。collection はサブコレクションなら favoritesOf(owner) を渡す） */
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
 * 持ち主のお気に入りの一覧を取る（アプリの fetchFavorites と同じ order(by: createdAt, descending) ＋ limit の runQuery。
 * ルールでは list として評価される）。HTTP の状態を返す。
 * - 親の文書（users/{owner}）の :runQuery に送る（ルート直下に送ると、存在しないトップの favorites への要求になる）
 * - limit は数値か undefined。undefined なら structuredQuery に limit を入れない（request.query.limit が無い要求）
 * - runQuery の応答は配列のストリームなので、状態が 200 でも中に error があればその code を返す
 *   （拒否が「200 の中の error」の形で返っても、403 として数えるため）
 * - options.orderBy は既定 true（fetchFavorites と同じ並べ替え）。false なら structuredQuery に orderBy を入れない
 *   （アプリの退会処理 deleteUserData の favorites の getDocuments と同じ、並べ替えなしの一覧）
 */
async function listFavorites(who, owner, limit, { orderBy = true } = {}) {
  const structuredQuery = { from: [{ collectionId: "favorites" }] };
  if (orderBy) structuredQuery.orderBy = [{ field: { fieldPath: "createdAt" }, direction: "DESCENDING" }];
  if (limit !== undefined) structuredQuery.limit = limit;
  const res = await fetch(`${FIRESTORE}/users/${encodeURIComponent(owner)}:runQuery`, {
    method: "POST",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ structuredQuery }),
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
/** 実行ごとの uid・文書 ID（取り違えないよう用途の名前を付ける） */
const key = (name) => `${name}-${RUN}`;

// MARK: - 文書の中身

/**
 * publicProfiles の中身。ルールが create で hasAll(['id','createdAt']) と id == userId を見るので、id と createdAt は必ず入れる。
 * extra に渡した項目（showsFavorites など。値は REST の形）を足す
 */
function profileFields(uid, extra = {}) {
  return {
    id: { stringValue: uid },
    createdAt: { timestampValue: new Date().toISOString() },
    ...extra,
  };
}

/** favorites の中身（アプリの Favorite と同じ postId・createdAt の 2 項目。文書 ID は postId と同じにする） */
function favoriteFields(postId) {
  return {
    postId: { stringValue: postId },
    createdAt: { timestampValue: new Date().toISOString() },
  };
}

/** follows の中身（アプリの Follow.toFirestoreData と同じ 3 項目） */
function followFields(followerId, followeeId) {
  return {
    followerId: { stringValue: followerId },
    followeeId: { stringValue: followeeId },
    createdAt: { timestampValue: new Date().toISOString() },
  };
}

const bool = (v) => ({ booleanValue: v });
const str = (v) => ({ stringValue: v });

// MARK: - 登場人物と鍵

const PROFILES = "publicProfiles";

// 読み取りのテストの持ち主（それぞれお気に入りを 1 件持つ）
const OWNER_ON = key("owner-on"); // showsFavorites: true
const OWNER_OFF = key("owner-off"); // showsFavorites: false
const OWNER_NOFIELD = key("owner-nofield"); // publicProfiles はあるが showsFavorites の項目が無い
const OWNER_NOPROFILE = key("owner-noprofile"); // publicProfiles が無い

const FAV_ON = key("post-on"); // 各持ち主のお気に入り（文書 ID = postId）
const FAV_OFF = key("post-off");
const FAV_NOFIELD = key("post-nofield");
const FAV_NOPROFILE = key("post-noprofile");
const FAV_MISSING = key("post-missing"); // どこにも置かない postId

// 閲覧する人
const FOLLOWER = key("follower"); // 持ち主全員（書き込み用の持ち主も）をフォローしている
const STRANGER = key("stranger"); // だれもフォローしない
const GUEST = null; // 未ログイン（ゲスト）

// 書き込みのテストの持ち主（ON の持ち主と同じ設定・FOLLOWER がフォローしている。読み取りのテストとは別の人）
const WRITE_OWNER = key("write-owner");
const FAV_UPDATE = key("post-write-update"); // 更新の的（置いておく）
const FAV_DELETE_FOLLOWER = key("post-write-delete-follower"); // 削除の的（壊したルールで消えても、ほかに響かないよう別々）
const FAV_DELETE_OWNER = key("post-write-delete-owner");

// publicProfiles の型の検査（テストごとに別の人。陽性対照で文字列を書けてしまっても、ほかのテストに響かないように）
const EDIT_FAV_STRING = key("edit-fav-string"); // 更新: showsFavorites に文字列
const EDIT_FAV_BOOL = key("edit-fav-bool"); // 更新: showsFavorites に Bool（対照）
const EDIT_CALENDAR_STRING = key("edit-calendar-string"); // 更新: showsSkyCalendar に文字列
const EDIT_RECOMMENDED_STRING = key("edit-recommended-string"); // 更新: showsRecommendedSkies に文字列
const CREATE_FAV_STRING = key("create-fav-string"); // 作成: showsFavorites に文字列
const CREATE_ALL_BOOL = key("create-all-bool"); // 作成: 3 つとも Bool（対照）

test.before(async () => {
  // 読み取りのテストの持ち主
  await seed(PROFILES, OWNER_ON, profileFields(OWNER_ON, { showsFavorites: bool(true) }));
  await seed(PROFILES, OWNER_OFF, profileFields(OWNER_OFF, { showsFavorites: bool(false) }));
  await seed(PROFILES, OWNER_NOFIELD, profileFields(OWNER_NOFIELD));
  // OWNER_NOPROFILE の publicProfiles は置かない
  await seed(favoritesOf(OWNER_ON), FAV_ON, favoriteFields(FAV_ON));
  await seed(favoritesOf(OWNER_OFF), FAV_OFF, favoriteFields(FAV_OFF));
  await seed(favoritesOf(OWNER_NOFIELD), FAV_NOFIELD, favoriteFields(FAV_NOFIELD));
  await seed(favoritesOf(OWNER_NOPROFILE), FAV_NOPROFILE, favoriteFields(FAV_NOPROFILE));

  // 書き込みのテストの持ち主（ON と同じ設定）
  await seed(PROFILES, WRITE_OWNER, profileFields(WRITE_OWNER, { showsFavorites: bool(true) }));
  await seed(favoritesOf(WRITE_OWNER), FAV_UPDATE, favoriteFields(FAV_UPDATE));
  await seed(favoritesOf(WRITE_OWNER), FAV_DELETE_FOLLOWER, favoriteFields(FAV_DELETE_FOLLOWER));
  await seed(favoritesOf(WRITE_OWNER), FAV_DELETE_OWNER, favoriteFields(FAV_DELETE_OWNER));

  // FOLLOWER は持ち主全員をフォローする（follows/{followerId}_{followeeId}。作成のルールを通さないよう管理者で置く）
  for (const owner of [OWNER_ON, OWNER_OFF, OWNER_NOFIELD, OWNER_NOPROFILE, WRITE_OWNER]) {
    await seed("follows", `${FOLLOWER}_${owner}`, followFields(FOLLOWER, owner));
  }

  // publicProfiles の更新の的（本人の update は文書がある前提）
  for (const uid of [EDIT_FAV_STRING, EDIT_FAV_BOOL, EDIT_CALENDAR_STRING, EDIT_RECOMMENDED_STRING]) {
    await seed(PROFILES, uid, profileFields(uid));
  }
});

// MARK: - 検証1: 持ち主は自分のお気に入りを読める（ON・OFF とも）

test("検証1: 持ち主（ON）は自分のお気に入りを get できる", async () => {
  assert.equal(await getDoc(OWNER_ON, favoritesOf(OWNER_ON), FAV_ON), 200);
});

// 200 になること＝一覧の要求の親のパス（users/{持ち主}）が正しい証拠（間違っていれば存在しないトップの favorites への 403）
test("検証1: 持ち主（ON）は自分のお気に入りの一覧（limit 30）を取れる", async () => {
  assert.equal(await listFavorites(OWNER_ON, OWNER_ON, 30), 200);
});

test("検証1: 持ち主（OFF）も自分のお気に入りを get できる", async () => {
  assert.equal(await getDoc(OWNER_OFF, favoritesOf(OWNER_OFF), FAV_OFF), 200);
});

test("検証1: 持ち主（OFF）も自分のお気に入りの一覧（limit 30）を取れる", async () => {
  assert.equal(await listFavorites(OWNER_OFF, OWNER_OFF, 30), 200);
});

// 持ち主は上限に縛られない（上限はフォロワーにだけ掛ける）意図を固定する
test("検証1: 持ち主は limit なしでも自分のお気に入りの一覧を取れる", async () => {
  assert.equal(await listFavorites(OWNER_OFF, OWNER_OFF, undefined), 200);
});

// MARK: - 検証2: フォロワー＋ON は読める（下の拒否のテストの対照も兼ねる）

test("検証2: フォロワーは、ON の持ち主のお気に入りの一覧（limit 30）を取れる", async () => {
  assert.equal(await listFavorites(FOLLOWER, OWNER_ON, 30), 200);
});

test("検証2: フォロワーは、ON の持ち主のお気に入りを get できる", async () => {
  assert.equal(await getDoc(FOLLOWER, favoritesOf(OWNER_ON), FAV_ON), 200);
});

// 403 でなく 404 が返る＝許可が効いて、文書が無いところまで届いている
test("検証2: フォロワーが ON の持ち主の存在しない postId を get すると 404（403 でない）", async () => {
  assert.equal(await getDoc(FOLLOWER, favoritesOf(OWNER_ON), FAV_MISSING), 404);
});

// MARK: - 検証3: フォロワーでも、持ち主が OFF・項目なしなら読めない

test("検証3: フォロワーでも、OFF の持ち主のお気に入りは get できない", async () => {
  assert.equal(await getDoc(FOLLOWER, favoritesOf(OWNER_OFF), FAV_OFF), 403);
});

test("検証3: フォロワーでも、OFF の持ち主のお気に入りの一覧（limit 30）は取れない", async () => {
  assert.equal(await listFavorites(FOLLOWER, OWNER_OFF, 30), 403);
});

test("検証3: フォロワーでも、showsFavorites の項目が無い持ち主のお気に入りは get できない", async () => {
  assert.equal(await getDoc(FOLLOWER, favoritesOf(OWNER_NOFIELD), FAV_NOFIELD), 403);
});

test("検証3: フォロワーでも、showsFavorites の項目が無い持ち主のお気に入りの一覧（limit 30）は取れない", async () => {
  assert.equal(await listFavorites(FOLLOWER, OWNER_NOFIELD, 30), 403);
});

// MARK: - 検証4: フォロワーでない人は、ON でも読めない

test("検証4: フォロワーでない人は、ON の持ち主のお気に入りを get できない", async () => {
  assert.equal(await getDoc(STRANGER, favoritesOf(OWNER_ON), FAV_ON), 403);
});

test("検証4: フォロワーでない人は、ON の持ち主のお気に入りの一覧（limit 30）を取れない", async () => {
  assert.equal(await listFavorites(STRANGER, OWNER_ON, 30), 403);
});

// MARK: - 検証5: 未ログインは、ON でも読めない

test("検証5: 未ログインでは、ON の持ち主のお気に入りを get できない", async () => {
  assert.equal(await getDoc(GUEST, favoritesOf(OWNER_ON), FAV_ON), 403);
});

test("検証5: 未ログインでは、ON の持ち主のお気に入りの一覧（limit 30）を取れない", async () => {
  assert.equal(await listFavorites(GUEST, OWNER_ON, 30), 403);
});

// MARK: - 検証6: publicProfiles が無い持ち主は、フォロワーでも読めない（閉じる側に倒れる）

test("検証6: フォロワーでも、publicProfiles が無い持ち主のお気に入りは get できない", async () => {
  assert.equal(await getDoc(FOLLOWER, favoritesOf(OWNER_NOPROFILE), FAV_NOPROFILE), 403);
});

test("検証6: フォロワーでも、publicProfiles が無い持ち主のお気に入りの一覧（limit 30）は取れない", async () => {
  assert.equal(await listFavorites(FOLLOWER, OWNER_NOPROFILE, 30), 403);
});

// MARK: - 検証7: 上限を超える一覧は、フォロワー＋ON でも取れない

test("検証7: フォロワーでも、ON の持ち主のお気に入りを limit 31 では一覧で取れない", async () => {
  assert.equal(await listFavorites(FOLLOWER, OWNER_ON, 31), 403);
});

// MARK: - 検証8: 他人の書き込みは今どおり拒否（読めるようにしても書けるようにはならない）

test("検証8: フォロワーは、ON の持ち主のお気に入りを作れない", async () => {
  const postId = key("post-write-create-follower");
  assert.equal(await createDoc(FOLLOWER, favoritesOf(WRITE_OWNER), postId, favoriteFields(postId)), 403);
});

test("検証8: フォロワーは、ON の持ち主の既存のお気に入りを書き換えられない（update）", async () => {
  assert.equal(await updateDoc(FOLLOWER, favoritesOf(WRITE_OWNER), FAV_UPDATE, favoriteFields(FAV_UPDATE)), 403);
});

test("検証8: フォロワーは、ON の持ち主の既存のお気に入りを消せない", async () => {
  assert.equal(await deleteDoc(FOLLOWER, favoritesOf(WRITE_OWNER), FAV_DELETE_FOLLOWER), 403);
});

// 上の 403 が「要求の形が間違っている」でなく「本人でないから止まった」ことの証拠（同じ形の要求を本人が送ると通る）
test("検証8 の対照: 持ち主本人は、同じ形でお気に入りを作れる", async () => {
  const postId = key("post-write-create-owner");
  assert.equal(await createDoc(WRITE_OWNER, favoritesOf(WRITE_OWNER), postId, favoriteFields(postId)), 200);
});

test("検証8 の対照: 持ち主本人は、同じ形でお気に入りを消せる", async () => {
  assert.equal(await deleteDoc(WRITE_OWNER, favoritesOf(WRITE_OWNER), FAV_DELETE_OWNER), 200);
});

// MARK: - 検証9: publicProfiles の 3 つの項目は Bool だけ

test("検証9: 本人の更新でも、showsFavorites に文字列 \"true\" は書けない", async () => {
  assert.equal(await updateDoc(EDIT_FAV_STRING, PROFILES, EDIT_FAV_STRING, { showsFavorites: str("true") }), 403);
});

// 上の 403 が「要求の形が間違っている」でなく「型の検査で止まった」ことの証拠
test("検証9 の対照: 本人の更新で、showsFavorites に Bool の true は書ける", async () => {
  assert.equal(await updateDoc(EDIT_FAV_BOOL, PROFILES, EDIT_FAV_BOOL, { showsFavorites: bool(true) }), 200);
});

test("検証9: 本人の更新でも、showsSkyCalendar に文字列は書けない", async () => {
  assert.equal(
    await updateDoc(EDIT_CALENDAR_STRING, PROFILES, EDIT_CALENDAR_STRING, { showsSkyCalendar: str("true") }),
    403
  );
});

test("検証9: 本人の更新でも、showsRecommendedSkies に文字列は書けない", async () => {
  assert.equal(
    await updateDoc(EDIT_RECOMMENDED_STRING, PROFILES, EDIT_RECOMMENDED_STRING, { showsRecommendedSkies: str("true") }),
    403
  );
});

test("検証9: 本人の作成でも、showsFavorites に文字列は書けない", async () => {
  assert.equal(
    await createDoc(CREATE_FAV_STRING, PROFILES, CREATE_FAV_STRING, profileFields(CREATE_FAV_STRING, { showsFavorites: str("true") })),
    403
  );
});

// 上の 403 が「要求の形が間違っている」でなく「型の検査で止まった」ことの証拠
test("検証9 の対照: 本人の作成で、3 つとも Bool なら作れる", async () => {
  const fields = profileFields(CREATE_ALL_BOOL, {
    showsRecommendedSkies: bool(true),
    showsSkyCalendar: bool(false),
    showsFavorites: bool(false),
  });
  assert.equal(await createDoc(CREATE_ALL_BOOL, PROFILES, CREATE_ALL_BOOL, fields), 200);
});

// MARK: - 検証10: limit なしの一覧は、フォロワー＋ON でも取れない

test("検証10: フォロワーでも、ON の持ち主のお気に入りを limit なしでは一覧で取れない", async () => {
  assert.equal(await listFavorites(FOLLOWER, OWNER_ON, undefined), 403);
});

// MARK: - レビューで足した回帰（32〜35。node --test の番号 1〜31 を動かさないよう末尾に置く）

// 検証8 のフォロワーの update 403 の対照（同じ形の要求を本人が送ると通る）。
// アプリは set(冪等) で書くので、既にある文書への書き込みは update として評価される
test("検証8 の対照: 持ち主本人は、同じ形で既存のお気に入りを書き換えられる（update）", async () => {
  assert.equal(await updateDoc(WRITE_OWNER, favoritesOf(WRITE_OWNER), FAV_UPDATE, favoriteFields(FAV_UPDATE)), 200);
});

// 今のアプリの createPublicProfile は 3 つの項目を書かない。項目が無い作成を拒否しないことの回帰
test("検証9 の対照: 本人の作成で、3 つとも無い（今のアプリの createPublicProfile の形）なら作れる", async () => {
  const uid = key("create-no-fields");
  assert.equal(await createDoc(uid, PROFILES, uid, profileFields(uid)), 200);
});

// canReadFavoritesOf の get() の失敗（publicProfiles が無い）が、持ち主本人の読み取りに響かないことの回帰
test("検証1: publicProfiles が無い持ち主も、自分のお気に入りを get できる", async () => {
  assert.equal(await getDoc(OWNER_NOPROFILE, favoritesOf(OWNER_NOPROFILE), FAV_NOPROFILE), 200);
});

// アプリの退会処理（FirestoreService.deleteUserData の favorites）は orderBy も limit も無い getDocuments で全件を読む。
// 持ち主がこれを取れないと退会が止まる
test("検証1: 持ち主は、退会のときと同じ並べ替えなし・limit なしの一覧を取れる", async () => {
  assert.equal(await listFavorites(OWNER_OFF, OWNER_OFF, undefined, { orderBy: false }), 200);
});
