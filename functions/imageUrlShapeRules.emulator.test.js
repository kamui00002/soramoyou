//
// firestore.rules の「画像の URL の書く形」を、Firestore のエミュレーターで本物の要求として評価するテスト ⭐️☁️
//   - posts: images[].url・images[].thumbnail・originalImages[].url
//   - users・publicProfiles: photoURL
//   - comments: authorPhotoURL
//   形は Storage のダウンロード URL
//   （https://firebasestorage.googleapis.com[:443]/v0/b/soramoyou-ios.firebasestorage.app/o/<名前>[?<クエリ>]）か、
//   空（項目なし・null・""）。更新では、その項目が変わったときだけ見る
//
// 実行（functions/ の npm run test:emulator に登録済み。--project demo-soramoyou-security で起きる。単体ならリポジトリの根で）:
//   firebase emulators:exec --only firestore --project demo-soramoyou-security \
//     "node --test functions/imageUrlShapeRules.emulator.test.js"
//
// ■ 何を確かめるか（テスト名の頭の「検証N:」は下の番号）
//   検証1: posts の作成で通る形（:443 あり・なし／URL を書かない投稿の形＝url ""・thumbnail なし・原画像の url ""／
//          url が null／写真 10 枚＋原画像 10 枚）
//   検証2: posts の作成で通らない形。images[0].url の 1 か所だけを変える（対照は検証1 の同じ形の作成）
//   検証3: posts の作成で、見る位置（thumbnail・原画像・10 番目）と原画像の数（11 個）
//   検証4: posts の更新。images・originalImages を変える更新は形を見る／変えない更新
//          （持ち主のキャプションだけ・他人のいいね +1）は、既にある URL の形に関係なく通る。
//          写真 10 枚と原画像 10 個（ルールの許す最大の数）に替える更新も通る
//   検証5: users の作成と更新（photoURL）。名前だけの更新・photoURL を消す更新・他人のフォロー数 +1 も
//   検証6: publicProfiles の作成と更新（photoURL）
//   検証7: comments の作成と更新（authorPhotoURL）
//   検証8: posts の作成で、公開範囲が public でないときの写真の形（url・thumbnail は空。対照は同じ形の public）
//   検証9: posts の更新で、公開範囲が public でないときの写真の形。images を変える更新と、公開範囲を public 以外へ
//          変える更新は形を見る／どちらも変えない更新（持ち主のキャプションだけ・他人のいいね +1）は通る。
//          写真 10 枚と原画像 10 個（ルールの許す最大の数）を空の形に替える更新も通る
//
// ■ 書き方の約束（profileVisibilityRules.emulator.test.js・followsBlockRules.emulator.test.js と同じ型）
//   - 要求は firebase-admin でなく、アプリの SDK と同じ REST の入口に fetch で送る（firebase-admin はルールを通らない）。
//     ID トークンはエミュレーターが受け付ける署名なしの JWT（rules の request.auth.uid は user_id から入る）
//   - 下ごしらえ（更新の的になる文書を置く）は管理者（Bearer owner）で行い、確かめる対象のルールを通さない
//   - 拒否のケースだけでは「判定が効いている」証拠にならない（要求の形の間違いでも 4xx になる）。
//     拒否のケースは、URL の 1 か所だけが違う「通る側」と必ず対にする
//   - 文書 ID・uid は実行ごと・テストごとに変える（陽性対照で書けてしまっても、ほかのテストに響かないように）
//   - 1 つの test に 1 つの確かめだけを置く（assert は最初の失敗で止まるので、まとめると後ろのケースの結果が見えない）
//
// ⚠️ 本番へ要求を送る事故の柵: 宛先がエミュレーター（127.0.0.1・localhost・[::1]）でない、または
//    プロジェクト ID が demo- で始まらないときは、何も送らずに終了コード 1 で止める。skip にはしない
//    （skip は「何も確かめていない緑」に化けるため）。followsBlockRules.emulator.test.js の柵と同じ型。
//
// ⚠️ 陽性対照（実施日を書く）: 先に「わざと壊した firestore.rules」で赤になるのを確かめてから通す。
//    リポジトリの firestore.rules は触らず、一時フォルダの写しを壊して読ませる。壊し方と、赤になるはずのもの:
//    ① 正規表現のホストの部分（firebasestorage[.]googleapis[.]com）を .* にする
//       （赤になるはず: 16 件。検証2 の別のホスト・@ を挟む・ポート違い・前の方だけ同じ の 4 件、
//        検証3 の別のホストを使う 4 件、検証4 の通らない 2 件、検証5〜7 の作成と更新の通らない 6 件）→ 結果を書く
//    ② 正規表現の頭の https を https? にする（赤になるはず: 検証2 の http の 1 件）→ 結果を書く
//    ③ 正規表現のバケットの部分を [^/]+ にする（赤になるはず: 検証2 のバケット違いの 1 件）→ 結果を書く
//    ④ 形を見る写真の配列（isValidImageList）と原画像の配列で、0〜9 番目を並べた行のうち 9（10 個目）の行をそれぞれ消す
//       （赤になるはず: 検証3 の写真の 10 番目・原画像の 10 番目の 2 件）→ 結果を書く
//    ⑤ 配列の数の上限（size() <= 10）を 3 か所とも消す（形を見る写真の配列・空の配列・原画像の配列）
//       （赤になるはず: 検証3 の原画像 11 個の 1 件。写真の枚数は投稿の作成・更新の条件でも 10 枚までなので、
//        写真の 11 枚は赤にならない）→ 結果を書く
//    ⑥ 4 か所の更新で、見る鍵を diff の affectedKeys() から request.resource.data.keys() に替える
//       （赤になるはず: 6 件。検証4 のキャプションだけ・検証5 と検証6 の名前だけ・検証7 の本文だけ・検証9 のキャプションだけ・
//        検証9 の public へ変える更新が写真の形に関係なく通る 1 件）→ 結果を書く
//    ⑦ 正規表現の (:443)? を消す（赤になるはず: 8 件。検証1 の :443 付きの作成と 10 枚＋10 個の作成の 2 件、
//       検証5〜7 の :443 付きの作成の 3 件、検証4 の 10 枚＋10 個に替える更新の 1 件、検証8 の public の対照の 1 件、
//       検証9 の public へ変えて url を書く更新の 1 件）→ 結果を書く
//    ⑧ 空として通す値から "" を外す（形の全体を包む (…)? を外す）
//       （赤になるはず: 9 件。検証1 の URL を書かない投稿の形の 1 件、原画像の url が "" の検証8 の通る形 5 件と public の対照の 1 件、
//        検証9 の 10 枚＋10 個に替える更新の 2 件）→ 結果を書く
//    ⑨ users・publicProfiles・comments の作成から、URL の形を見る条件を外す
//       （赤になるはず: 検証5・検証6・検証7 の作成の断る側の 3 件）→ 結果を書く
//    【結果 2026-11-10】リポジトリの firestore.rules は触らず、一時フォルダの写しを壊して読ませた
//      （壊し方ごとにエミュレーターを起こし直した。赤のテスト名も予言と 1 件ずつ照らした）
//      ① 赤 16 件＝予言どおり
//      ② 赤 1 件＝予言どおり
//      ③ 赤 1 件＝予言どおり
//      ④ 赤 2 件＝予言どおり
//      ⑤ 赤 1 件＝予言どおり
//      ⑥ 赤 6 件＝予言どおり
//      ⑦ 赤 8 件＝予言どおり
//      ⑧ 赤 9 件＝予言どおり
//      ⑨ 赤 3 件＝予言どおり
//      どの壊し方でも、予言に無い赤は 0 件
//
//    検証8・検証9 の陽性対照（壊し方と、赤になるはずのもの。ここに書いたもの以外の赤は 0 件のはず）:
//    ⑩ 写真の配列の分岐・公開範囲の門の足し・空の配列の関数を外す（＝足す前のルール）
//       （赤になるはず: 12 件。検証8 の通らない 6 件、検証9 の通らない 6 件）→ 結果を書く
//    ⑪ 門から公開範囲の条件を外す（images が変わったときだけ見る形に戻す）
//       （赤になるはず: 3 件。検証9 の公開範囲だけを変えて通らない 3 件）→ 結果を書く
//    ⑫ 門の visibility != 'public' を外す（public へ変える更新でも images を見る）
//       （赤になるはず: 検証9 の public へ変える更新が写真の形に関係なく通る 1 件）→ 結果を書く
//    ⑬ 空の配列の 1 個の条件から url の行を外す
//       （赤になるはず: 5 件。検証8 の url だけに値がある 3 件、検証9 の url だけに値がある 2 件）→ 結果を書く
//    ⑭ 空の配列の 1 個の条件から thumbnail の行を外す
//       （赤になるはず: 3 件。検証8 の thumbnail だけに値がある 2 件、検証9 の 1 件）→ 結果を書く
//    ⑮ 写真の配列の分岐の visibility == 'public' を visibility != 'private' にする
//       （赤になるはず: 8 件。検証8 の followers で通らない 4 件、検証9 の followers で通らない 4 件）→ 結果を書く
//    ⑯ 空の判定から value == '' を外す
//       （赤になるはず: 9 件。検証8 の通る形のうち空文字を使う 4 件、検証9 の 5 件）→ 結果を書く
//    ⑰ 空の判定から value == null を外す
//       （赤になるはず: 10 件。検証8 の通る形のうち public でない 5 件、検証9 の 5 件）→ 結果を書く
//    ⑱ 形を見る写真の配列（isValidImageList）で 0〜9 番目を並べた行のうち 9（10 個目）の行を消す
//       （赤になるはず: 検証3 の写真の 10 番目の 1 件）→ 結果を書く
//    ⑲ posts の更新で、見る鍵を diff の affectedKeys() から request.resource.data.keys() に替える
//       （赤になるはず: 3 件。検証4 のキャプションだけ、検証9 のキャプションだけ、検証9 の public へ変える更新が
//        写真の形に関係なく通る 1 件）→ 結果を書く
//    ⑳ 写真の配列の分岐で public の側を外す（どの公開範囲でも空の配列を求める）
//       （赤になるはず: 7 件。検証1 の :443 付き・:443 なし・10 枚＋10 個の 3 件、検証4 の写真を :443 なしへ替える 1 件と
//        10 枚＋10 個に替える 1 件、検証8 の public の対照 1 件、検証9 の public へ変えて url を書く 1 件）→ 結果を書く
//    ㉑ 空の配列（isEmptyImageList）で 0〜9 番目を並べた行のうち 9（10 個目）の行を消す
//       （赤になるはず: 検証8 の 10 番目の 1 件）→ 結果を書く
//    【結果 2026-11-10】リポジトリの firestore.rules は触らず、一時フォルダの写しを壊して読ませた
//      （壊し方ごとにエミュレーターを起こし直した。赤のテスト名も予言と 1 件ずつ照らした）
//      壊さないルールでは 78/78 緑（隣の profileVisibilityRules 35/35・followsBlockRules 20/20 も緑）
//      ⑩ 赤 12 件＝予言どおり
//      ⑪ 赤 3 件＝予言どおり
//      ⑫ 赤 1 件＝予言どおり
//      ⑬ 赤 5 件＝予言どおり
//      ⑭ 赤 3 件＝予言どおり
//      ⑮ 赤 8 件＝予言どおり
//      ⑯ 赤 9 件＝予言どおり
//      ⑰ 赤 10 件＝予言どおり
//      ⑱ 赤 1 件＝予言どおり
//      ⑲ 赤 3 件＝予言どおり
//      ⑳ 赤 7 件＝予言どおり
//      ㉑ 赤 1 件＝予言どおり
//      どの壊し方でも、予言に無い赤は 0 件
//      写真と原画像を 1〜10 個にした作成と更新は、public・followers・private のどれでも 200
//      最大の数（写真 10 枚・原画像 10 個・キャプションとハッシュタグあり）での、ルールの式の数の余裕（上限 1000）:
//        public は作成 約 100・更新 約 60、followers と private は作成 約 115・更新 約 80
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

/** 認証のヘッダー。ADMIN はエミュレーターの管理者（ルールを通らない） */
const ADMIN = Symbol("admin");
function authHeader(who) {
  if (who === ADMIN) return { Authorization: "Bearer owner" };
  return who ? { Authorization: `Bearer ${idToken(who)}` } : {};
}

/** 文書へのパス */
function docPath(collection, docId) {
  return `${collection}/${encodeURIComponent(docId)}`;
}

/** 下ごしらえ: collection/docId を管理者で置く */
async function seed(collection, docId, fields) {
  const res = await fetch(`${FIRESTORE}/${docPath(collection, docId)}`, {
    method: "PATCH",
    headers: { ...authHeader(ADMIN), "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  assert.equal(res.status, 200, `下ごしらえ: ${collection}/${docId} を置けなかった`);
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
 * - mask は書き換える項目の名前。既定は fields の鍵。mask にあって fields に無い項目は消える
 *   （SDK の FieldValue.delete() と同じ形）
 */
async function updateDoc(who, collection, docId, fields, mask = Object.keys(fields)) {
  const params = new URLSearchParams({ "currentDocument.exists": "true" });
  for (const field of mask) params.append("updateMask.fieldPaths", field);
  const res = await fetch(`${FIRESTORE}/${docPath(collection, docId)}?${params}`, {
    method: "PATCH",
    headers: { ...authHeader(who), "Content-Type": "application/json" },
    body: JSON.stringify({ fields }),
  });
  await res.arrayBuffer();
  return res.status;
}

// MARK: - 実行ごとに変える印

const RUN = Date.now().toString(36);
/** 実行ごとの uid・文書 ID（取り違えないよう用途の名前を付ける） */
const key = (name) => `${name}-${RUN}`;

// MARK: - REST の値

const str = (v) => ({ stringValue: v });
const int = (n) => ({ integerValue: String(n) });
const NULL = { nullValue: null };
const arr = (values) => ({ arrayValue: { values } });
const map = (fields) => ({ mapValue: { fields } });
const now = () => ({ timestampValue: new Date().toISOString() });

// MARK: - URL（通る形は本番の現物と同じ形。通らない形は GOOD から 1 か所だけ変える）

const NAME_AND_QUERY = "posts%2Fu1%2Fpublic%2Fa.jpg?alt=media&token=0a1b2c3d-4e5f";
const BUCKET = "/v0/b/soramoyou-ios.firebasestorage.app/o/";

/** 本番の現物と同じ :443 付きの形 */
const GOOD = `https://firebasestorage.googleapis.com:443${BUCKET}${NAME_AND_QUERY}`;
/** :443 の無い形 */
const GOOD_NO_PORT = `https://firebasestorage.googleapis.com${BUCKET}${NAME_AND_QUERY}`;

/** 通らない形（GOOD からの違いを名前にする） */
const BAD = {
  otherHost: `https://example.com:443${BUCKET}${NAME_AND_QUERY}`,
  http: `http://firebasestorage.googleapis.com:443${BUCKET}${NAME_AND_QUERY}`,
  otherBucket: `https://firebasestorage.googleapis.com:443/v0/b/other-bucket.appspot.com/o/${NAME_AND_QUERY}`,
  atSign: `https://firebasestorage.googleapis.com@example.com:443${BUCKET}${NAME_AND_QUERY}`,
  otherPort: `https://firebasestorage.googleapis.com:8443${BUCKET}${NAME_AND_QUERY}`,
  rawSlash: `https://firebasestorage.googleapis.com:443${BUCKET}posts/u1/public/a.jpg?alt=media&token=0a1b2c3d-4e5f`,
  space: `https://firebasestorage.googleapis.com:443${BUCKET}posts%2Fu1%2Fpublic%2Fa b.jpg?alt=media&token=0a1b2c3d-4e5f`,
  file: "file:///var/mobile/a.jpg",
  data: "data:image/jpeg;base64,AAAA",
  longerHost: `https://firebasestorage.googleapis.com.example.com${BUCKET}${NAME_AND_QUERY}`,
};

// MARK: - 文書の中身

/** 「その項目を入れない」の印 */
const OMIT = Symbol("omit");

/** images・originalImages の 1 個（アプリの ImageInfo.toFirestoreData と同じ項目。url・thumbnail は REST の値か OMIT） */
function imageEntry(url, thumbnail, order = 0) {
  const fields = {
    width: int(1080),
    height: int(1440),
    order: int(order),
    storagePath: str(`posts/u1/public/${order}.jpg`),
  };
  if (url !== OMIT) fields.url = url;
  if (thumbnail !== OMIT) fields.thumbnail = thumbnail;
  return map(fields);
}

/** n 個の配列。全部 GOOD で、override(i) が値を返した位置だけ差し替える */
function imageList(n, { thumbnail = true, override = () => undefined } = {}) {
  const values = [];
  for (let i = 0; i < n; i++) {
    values.push(override(i) ?? imageEntry(str(GOOD), thumbnail ? str(GOOD) : OMIT, i));
  }
  return arr(values);
}

/**
 * 公開範囲が public でない投稿でアプリが書く写真の形（url は ""・thumbnail の項目なし・置き場あり）。
 * url・thumbnail は REST の値か OMIT で差し替える
 */
function pathOnlyEntry(visibility, order = 0, { url = str(""), thumbnail = OMIT } = {}) {
  const fields = {
    width: int(1080),
    height: int(1440),
    order: int(order),
    storagePath: str(`posts/u1/${visibility}/${order}.jpg`),
    thumbnailStoragePath: str(`thumbnails/u1/${visibility}/${order}_thumb.jpg`),
  };
  if (url !== OMIT) fields.url = url;
  if (thumbnail !== OMIT) fields.thumbnail = thumbnail;
  return map(fields);
}

/** 投稿の中身（アプリの Post.toFirestoreData と同じ主な項目）。images・originalImages は REST の値。originalImages は OMIT で入れない */
function postFields(uid, postId, { images = imageList(1), originalImages = imageList(1), visibility = "public" } = {}) {
  const fields = {
    postId: str(postId),
    userId: str(uid),
    images,
    visibility: str(visibility),
    likesCount: int(3),
    commentsCount: int(2),
    createdAt: now(),
    updatedAt: now(),
    caption: str("c"),
  };
  if (originalImages !== OMIT) fields.originalImages = originalImages;
  return fields;
}

/** users・publicProfiles の中身（ルールが create で見る id・createdAt を必ず入れる）。photoURL は REST の値か OMIT */
function profileFields(uid, photoURL = OMIT) {
  const fields = {
    id: str(uid),
    displayName: str("そら"),
    followersCount: int(0),
    followingCount: int(0),
    createdAt: now(),
    updatedAt: now(),
  };
  if (photoURL !== OMIT) fields.photoURL = photoURL;
  return fields;
}

/** comments の中身（アプリの Comment.toFirestoreData と同じ項目）。authorPhotoURL は REST の値か OMIT */
function commentFields(uid, authorPhotoURL = OMIT) {
  const fields = {
    userId: str(uid),
    postId: str(key("post-commented")),
    content: str("きれい"),
    createdAt: now(),
    authorName: str("そら"),
  };
  if (authorPhotoURL !== OMIT) fields.authorPhotoURL = authorPhotoURL;
  return fields;
}

// MARK: - 登場人物

const POSTER = key("poster"); // 投稿の持ち主（投稿は文書 ID を毎回変えるので 1 人でよい）
const OTHER = key("other"); // 他人（いいね +1・フォロー数 +1 をする人）
const COMMENTER = key("commenter"); // コメントを書く人（コメントは文書 ID を毎回変えるので 1 人でよい）

const POSTS = "posts";
const USERS = "users";
const PROFILES = "publicProfiles";
const COMMENTS = "comments";

/** 投稿を作る（文書 ID はテストごとに変える） */
async function createPost(name, options) {
  const postId = key(name);
  return createDoc(POSTER, POSTS, postId, postFields(POSTER, postId, options));
}

/** images[0].url だけを url にした 1 枚の投稿を作る */
async function createPostWithFirstUrl(name, url) {
  return createPost(name, { images: arr([imageEntry(url, str(GOOD))]) });
}

/** 写真 1 枚の投稿を、公開範囲を指定して作る（原画像はアプリの書く形に固定し、写真の 1 個だけを変える） */
async function createPostWithEntry(name, visibility, entry) {
  return createPost(name, { visibility, images: arr([entry]), originalImages: arr([pathOnlyEntry(visibility)]) });
}

// MARK: - 下ごしらえ（更新の的）

// 検証4: 投稿
const POST_BAD_EXISTING_CAPTION = key("post-bad-existing-caption"); // 既にある images の url が別のホスト
const POST_BAD_EXISTING_LIKE = key("post-bad-existing-like"); // 同じ形（他人のいいね +1 の的）
const POST_EDIT_IMAGES_GOOD = key("post-edit-images-good");
const POST_EDIT_IMAGES_BAD = key("post-edit-images-bad");
const POST_EDIT_ORIGINALS_GOOD = key("post-edit-originals-good");
const POST_EDIT_ORIGINALS_BAD = key("post-edit-originals-bad");
const POST_EDIT_10 = key("post-edit-10");

// 検証9: 公開範囲ごとの投稿（名前は 今の公開範囲 → 更新の中身）
const POST_F_URL_CAPTION = key("post-f-url-caption");
const POST_F_URL_LIKE = key("post-f-url-like");
const POST_F_URL_TO_PRIVATE = key("post-f-url-to-private");
const POST_F_EDIT_GOOD = key("post-f-edit-good");
const POST_F_EDIT_BAD_URL = key("post-f-edit-bad-url");
const POST_F_EDIT_BAD_THUMBNAIL = key("post-f-edit-bad-thumbnail");
const POST_F_TO_PRIVATE = key("post-f-to-private");
const POST_F_TO_PUBLIC = key("post-f-to-public");
const POST_F_TO_PUBLIC_URL = key("post-f-to-public-url");
const POST_F_OTHER_SHAPE_TO_PUBLIC = key("post-f-other-shape-to-public");
const POST_P_TO_F_PATH_ONLY = key("post-p-to-f-path-only");
const POST_P_TO_F_KEEP = key("post-p-to-f-keep");
const POST_P_TO_PRIVATE_KEEP = key("post-p-to-private-keep");
const POST_P_TO_F_URL = key("post-p-to-f-url");
const POST_F_EDIT_10 = key("post-f-edit-10");
const POST_PRIVATE_EDIT_10 = key("post-private-edit-10");

// 検証5・検証6: users・publicProfiles（文書 ID = uid なので、的ごとに別の人）
const USER_EDIT_GOOD = key("user-edit-good");
const USER_EDIT_BAD = key("user-edit-bad");
const USER_BAD_EXISTING_NAME = key("user-bad-existing-name");
const USER_BAD_EXISTING_DELETE = key("user-bad-existing-delete");
const USER_BAD_EXISTING_FOLLOW = key("user-bad-existing-follow");
const PROFILE_EDIT_GOOD = key("profile-edit-good");
const PROFILE_EDIT_BAD = key("profile-edit-bad");
const PROFILE_BAD_EXISTING_NAME = key("profile-bad-existing-name");
const PROFILE_BAD_EXISTING_DELETE = key("profile-bad-existing-delete");

// 検証7: comments
const COMMENT_BAD_EXISTING = key("comment-bad-existing");
const COMMENT_EDIT_GOOD = key("comment-edit-good");
const COMMENT_EDIT_BAD = key("comment-edit-bad");

test.before(async () => {
  const badImages = arr([imageEntry(str(BAD.otherHost), str(BAD.otherHost))]);
  for (const postId of [POST_BAD_EXISTING_CAPTION, POST_BAD_EXISTING_LIKE]) {
    await seed(POSTS, postId, postFields(POSTER, postId, { images: badImages, originalImages: badImages }));
  }
  for (const postId of [
    POST_EDIT_IMAGES_GOOD,
    POST_EDIT_IMAGES_BAD,
    POST_EDIT_ORIGINALS_GOOD,
    POST_EDIT_ORIGINALS_BAD,
    POST_EDIT_10,
  ]) {
    await seed(POSTS, postId, postFields(POSTER, postId));
  }

  const seedPost = (postId, visibility, images) =>
    seed(POSTS, postId, postFields(POSTER, postId, { visibility, images, originalImages: OMIT }));
  const withUrls = arr([imageEntry(str(GOOD), str(GOOD))]);
  const pathOnly = (visibility) => arr([pathOnlyEntry(visibility)]);
  for (const postId of [POST_F_URL_CAPTION, POST_F_URL_LIKE, POST_F_URL_TO_PRIVATE]) {
    await seedPost(postId, "followers", withUrls);
  }
  for (const postId of [
    POST_F_EDIT_GOOD,
    POST_F_EDIT_BAD_URL,
    POST_F_EDIT_BAD_THUMBNAIL,
    POST_F_TO_PRIVATE,
    POST_F_TO_PUBLIC,
    POST_F_TO_PUBLIC_URL,
    POST_F_EDIT_10,
  ]) {
    await seedPost(postId, "followers", pathOnly("followers"));
  }
  await seedPost(POST_PRIVATE_EDIT_10, "private", pathOnly("private"));
  await seedPost(POST_F_OTHER_SHAPE_TO_PUBLIC, "followers", badImages);
  for (const postId of [POST_P_TO_F_PATH_ONLY, POST_P_TO_F_KEEP, POST_P_TO_PRIVATE_KEEP, POST_P_TO_F_URL]) {
    await seedPost(postId, "public", withUrls);
  }

  for (const uid of [USER_EDIT_GOOD, USER_EDIT_BAD]) {
    await seed(USERS, uid, profileFields(uid, str(GOOD)));
  }
  for (const uid of [USER_BAD_EXISTING_NAME, USER_BAD_EXISTING_DELETE, USER_BAD_EXISTING_FOLLOW]) {
    await seed(USERS, uid, profileFields(uid, str(BAD.otherHost)));
  }
  for (const uid of [PROFILE_EDIT_GOOD, PROFILE_EDIT_BAD]) {
    await seed(PROFILES, uid, profileFields(uid, str(GOOD)));
  }
  for (const uid of [PROFILE_BAD_EXISTING_NAME, PROFILE_BAD_EXISTING_DELETE]) {
    await seed(PROFILES, uid, profileFields(uid, str(BAD.otherHost)));
  }

  await seed(COMMENTS, COMMENT_BAD_EXISTING, commentFields(COMMENTER, str(BAD.otherHost)));
  for (const commentId of [COMMENT_EDIT_GOOD, COMMENT_EDIT_BAD]) {
    await seed(COMMENTS, commentId, commentFields(COMMENTER, str(GOOD)));
  }
});

// MARK: - 検証1: posts の作成で通る形

// 写真・原画像の url と thumbnail の 4 か所すべてが :443 付き（検証2・検証3 の断る側の対照）
test("検証1: posts の作成で、写真と原画像の url・thumbnail が :443 付きの形なら作れる", async () => {
  assert.equal(await createPost("create-good", { originalImages: imageList(1) }), 200);
});

test("検証1: posts の作成で、写真と原画像の url・thumbnail が :443 なしの形なら作れる", async () => {
  const entry = imageEntry(str(GOOD_NO_PORT), str(GOOD_NO_PORT));
  assert.equal(await createPost("create-good-no-port", { images: arr([entry]), originalImages: arr([entry]) }), 200);
});

// アプリが URL を書かない投稿の形（写真の url ""・thumbnail の項目なし・原画像の url ""）
test("検証1: posts の作成で、写真の url が \"\"・thumbnail なし・原画像の url が \"\" なら作れる", async () => {
  const entry = imageEntry(str(""), OMIT);
  assert.equal(await createPost("create-empty-url", { images: arr([entry]), originalImages: arr([entry]) }), 200);
});

test("検証1: posts の作成で、写真の url が null なら作れる", async () => {
  assert.equal(await createPost("create-null-url", { images: arr([imageEntry(NULL, OMIT)]), originalImages: OMIT }), 200);
});

// 検証3 の 10 番目・11 個の対照（10 個までなら全部見ても通る）
test("検証1: posts の作成で、写真 10 枚と原画像 10 個がすべて正しい形なら作れる", async () => {
  assert.equal(await createPost("create-10-10", { images: imageList(10), originalImages: imageList(10, { thumbnail: false }) }), 200);
});

// MARK: - 検証2: posts の作成で通らない形（images[0].url の 1 か所だけを変える）

test("検証2: posts の作成で、写真の url のホストが違うと作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-other-host", str(BAD.otherHost)), 403);
});

test("検証2: posts の作成で、写真の url が http だと作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-http", str(BAD.http)), 403);
});

test("検証2: posts の作成で、写真の url のバケットが違うと作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-other-bucket", str(BAD.otherBucket)), 403);
});

test("検証2: posts の作成で、写真の url のホストの後ろに @ があると作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-at-sign", str(BAD.atSign)), 403);
});

test("検証2: posts の作成で、写真の url のポートが 443 でないと作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-other-port", str(BAD.otherPort)), 403);
});

test("検証2: posts の作成で、写真の url の名前に / がそのまま入っていると作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-raw-slash", str(BAD.rawSlash)), 403);
});

test("検証2: posts の作成で、写真の url の名前に空白があると作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-space", str(BAD.space)), 403);
});

test("検証2: posts の作成で、写真の url が file: だと作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-file", str(BAD.file)), 403);
});

test("検証2: posts の作成で、写真の url が data: だと作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-data", str(BAD.data)), 403);
});

test("検証2: posts の作成で、写真の url のホストが前の方だけ同じ（後ろに続きがある）と作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-longer-host", str(BAD.longerHost)), 403);
});

test("検証2: posts の作成で、写真の url が文字列でない（数値）と作れない", async () => {
  assert.equal(await createPostWithFirstUrl("create-number-url", int(1)), 403);
});

test("検証2: posts の作成で、写真の要素が map でない（URL の文字列そのもの）と作れない", async () => {
  assert.equal(await createPost("create-entry-not-map", { images: arr([str(GOOD)]) }), 403);
});

// MARK: - 検証3: posts の作成で、見る位置と原画像の数

test("検証3: posts の作成で、写真の thumbnail だけホストが違うと作れない", async () => {
  assert.equal(await createPost("create-bad-thumbnail", { images: arr([imageEntry(str(GOOD), str(BAD.otherHost))]) }), 403);
});

test("検証3: posts の作成で、原画像の url だけホストが違うと作れない", async () => {
  assert.equal(await createPost("create-bad-original-url", { originalImages: arr([imageEntry(str(BAD.otherHost), OMIT)]) }), 403);
});

test("検証3: posts の作成で、原画像の要素が map でない（URL の文字列そのもの）と作れない", async () => {
  assert.equal(await createPost("create-original-not-map", { originalImages: arr([str(GOOD)]) }), 403);
});

test("検証3: posts の作成で、写真 10 枚の 10 番目の url だけホストが違うと作れない", async () => {
  const images = imageList(10, { override: (i) => (i === 9 ? imageEntry(str(BAD.otherHost), str(GOOD), i) : undefined) });
  assert.equal(await createPost("create-bad-10th-image", { images }), 403);
});

test("検証3: posts の作成で、原画像 10 個の 10 番目の url だけホストが違うと作れない", async () => {
  const originalImages = imageList(10, { override: (i) => (i === 9 ? imageEntry(str(BAD.otherHost), OMIT, i) : undefined) });
  assert.equal(await createPost("create-bad-10th-original", { originalImages }), 403);
});

test("検証3: posts の作成で、原画像が 11 個（すべて正しい形）だと作れない", async () => {
  assert.equal(await createPost("create-11-originals", { originalImages: imageList(11, { thumbnail: false }) }), 403);
});

// MARK: - 検証4: posts の更新

// 既にある images・originalImages の url が別のホストでも、変えない更新は通る
test("検証4: 持ち主がキャプションだけを変える更新は、既にある写真の URL の形に関係なく通る", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_BAD_EXISTING_CAPTION, { caption: str("書き直した") }), 200);
});

test("検証4: 他人のいいね +1 は、既にある写真の URL の形に関係なく通る", async () => {
  assert.equal(await updateDoc(OTHER, POSTS, POST_BAD_EXISTING_LIKE, { likesCount: int(4) }), 200);
});

test("検証4: 持ち主が写真を :443 なしの形に替える更新は通る", async () => {
  const images = arr([imageEntry(str(GOOD_NO_PORT), str(GOOD_NO_PORT))]);
  assert.equal(await updateDoc(POSTER, POSTS, POST_EDIT_IMAGES_GOOD, { images }), 200);
});

test("検証4: 持ち主が写真を、url のホストが違うものに替える更新は通らない", async () => {
  const images = arr([imageEntry(str(BAD.otherHost), str(GOOD))]);
  assert.equal(await updateDoc(POSTER, POSTS, POST_EDIT_IMAGES_BAD, { images }), 403);
});

test("検証4: 持ち主が原画像を :443 なしの形に替える更新は通る", async () => {
  const originalImages = arr([imageEntry(str(GOOD_NO_PORT), OMIT)]);
  assert.equal(await updateDoc(POSTER, POSTS, POST_EDIT_ORIGINALS_GOOD, { originalImages }), 200);
});

test("検証4: 持ち主が原画像を、url のホストが違うものに替える更新は通らない", async () => {
  const originalImages = arr([imageEntry(str(BAD.otherHost), OMIT)]);
  assert.equal(await updateDoc(POSTER, POSTS, POST_EDIT_ORIGINALS_BAD, { originalImages }), 403);
});

// ルールの許す最大の数（写真 10 枚・原画像 10 個）に替える更新
test("検証4: 持ち主が写真 10 枚と原画像 10 個をすべて正しい形に替える更新は通る", async () => {
  const fields = { images: imageList(10), originalImages: imageList(10) };
  assert.equal(await updateDoc(POSTER, POSTS, POST_EDIT_10, fields), 200);
});

// MARK: - 検証5: users（photoURL）

test("検証5: users の作成で、photoURL が :443 付きの形なら作れる", async () => {
  const uid = key("user-create-good");
  assert.equal(await createDoc(uid, USERS, uid, profileFields(uid, str(GOOD))), 200);
});

test("検証5: users の作成で、photoURL のホストが違うと作れない", async () => {
  const uid = key("user-create-bad");
  assert.equal(await createDoc(uid, USERS, uid, profileFields(uid, str(BAD.otherHost))), 403);
});

test("検証5: users の作成で、photoURL が無くても作れる", async () => {
  const uid = key("user-create-none");
  assert.equal(await createDoc(uid, USERS, uid, profileFields(uid)), 200);
});

test("検証5: users の更新で、photoURL を :443 なしの形に替えられる", async () => {
  assert.equal(await updateDoc(USER_EDIT_GOOD, USERS, USER_EDIT_GOOD, { photoURL: str(GOOD_NO_PORT) }), 200);
});

test("検証5: users の更新で、photoURL をホストが違うものに替えられない", async () => {
  assert.equal(await updateDoc(USER_EDIT_BAD, USERS, USER_EDIT_BAD, { photoURL: str(BAD.otherHost) }), 403);
});

test("検証5: users の更新で、名前だけを変える更新は、既にある photoURL の形に関係なく通る", async () => {
  assert.equal(
    await updateDoc(USER_BAD_EXISTING_NAME, USERS, USER_BAD_EXISTING_NAME, { displayName: str("くも") }),
    200
  );
});

// mask にだけ photoURL を入れる＝項目ごと消す（アプリのアイコン削除の FieldValue.delete() と同じ形）
test("検証5: users の更新で、photoURL を項目ごと消せる", async () => {
  assert.equal(await updateDoc(USER_BAD_EXISTING_DELETE, USERS, USER_BAD_EXISTING_DELETE, {}, ["photoURL"]), 200);
});

test("検証5: 他人のフォロー数 +1 は、既にある photoURL の形に関係なく通る", async () => {
  assert.equal(await updateDoc(OTHER, USERS, USER_BAD_EXISTING_FOLLOW, { followersCount: int(1) }), 200);
});

// MARK: - 検証6: publicProfiles（photoURL）

test("検証6: publicProfiles の作成で、photoURL が :443 付きの形なら作れる", async () => {
  const uid = key("profile-create-good");
  assert.equal(await createDoc(uid, PROFILES, uid, profileFields(uid, str(GOOD))), 200);
});

test("検証6: publicProfiles の作成で、photoURL のホストが違うと作れない", async () => {
  const uid = key("profile-create-bad");
  assert.equal(await createDoc(uid, PROFILES, uid, profileFields(uid, str(BAD.otherHost))), 403);
});

test("検証6: publicProfiles の更新で、photoURL を :443 なしの形に替えられる", async () => {
  assert.equal(await updateDoc(PROFILE_EDIT_GOOD, PROFILES, PROFILE_EDIT_GOOD, { photoURL: str(GOOD_NO_PORT) }), 200);
});

test("検証6: publicProfiles の更新で、photoURL をホストが違うものに替えられない", async () => {
  assert.equal(await updateDoc(PROFILE_EDIT_BAD, PROFILES, PROFILE_EDIT_BAD, { photoURL: str(BAD.otherHost) }), 403);
});

test("検証6: publicProfiles の更新で、名前だけを変える更新は、既にある photoURL の形に関係なく通る", async () => {
  assert.equal(
    await updateDoc(PROFILE_BAD_EXISTING_NAME, PROFILES, PROFILE_BAD_EXISTING_NAME, { displayName: str("くも") }),
    200
  );
});

test("検証6: publicProfiles の更新で、photoURL を項目ごと消せる", async () => {
  assert.equal(await updateDoc(PROFILE_BAD_EXISTING_DELETE, PROFILES, PROFILE_BAD_EXISTING_DELETE, {}, ["photoURL"]), 200);
});

// MARK: - 検証7: comments（authorPhotoURL）

test("検証7: comments の作成で、authorPhotoURL が :443 付きの形なら作れる", async () => {
  assert.equal(await createDoc(COMMENTER, COMMENTS, key("comment-create-good"), commentFields(COMMENTER, str(GOOD))), 200);
});

test("検証7: comments の作成で、authorPhotoURL のホストが違うと作れない", async () => {
  assert.equal(
    await createDoc(COMMENTER, COMMENTS, key("comment-create-bad"), commentFields(COMMENTER, str(BAD.otherHost))),
    403
  );
});

test("検証7: comments の作成で、authorPhotoURL が無くても作れる", async () => {
  assert.equal(await createDoc(COMMENTER, COMMENTS, key("comment-create-none"), commentFields(COMMENTER)), 200);
});

test("検証7: comments の更新で、本文だけを変える更新は、既にある authorPhotoURL の形に関係なく通る", async () => {
  assert.equal(await updateDoc(COMMENTER, COMMENTS, COMMENT_BAD_EXISTING, { content: str("やっぱりきれい") }), 200);
});

test("検証7: comments の更新で、authorPhotoURL を :443 なしの形に替えられる", async () => {
  assert.equal(await updateDoc(COMMENTER, COMMENTS, COMMENT_EDIT_GOOD, { authorPhotoURL: str(GOOD_NO_PORT) }), 200);
});

test("検証7: comments の更新で、authorPhotoURL をホストが違うものに替えられない", async () => {
  assert.equal(await updateDoc(COMMENTER, COMMENTS, COMMENT_EDIT_BAD, { authorPhotoURL: str(BAD.otherHost) }), 403);
});

// MARK: - 検証8: posts の作成で、公開範囲が public でないときの写真の形

test("検証8: followers の投稿の作成で、写真の url が空文字・thumbnail なしで置き場があれば作れる", async () => {
  assert.equal(await createPostWithEntry("create-f-path-only", "followers", pathOnlyEntry("followers")), 200);
});

test("検証8: private の投稿の作成で、写真の url が空文字・thumbnail なしで置き場があれば作れる", async () => {
  assert.equal(await createPostWithEntry("create-p-path-only", "private", pathOnlyEntry("private")), 200);
});

test("検証8: followers の投稿の作成で、写真の url が null・thumbnail なしなら作れる", async () => {
  assert.equal(await createPostWithEntry("create-f-null", "followers", pathOnlyEntry("followers", 0, { url: NULL })), 200);
});

test("検証8: followers の投稿の作成で、写真の url なし・thumbnail が空文字なら作れる", async () => {
  const entry = pathOnlyEntry("followers", 0, { url: OMIT, thumbnail: str("") });
  assert.equal(await createPostWithEntry("create-f-omit-empty", "followers", entry), 200);
});

// 10 番目の断る側の対照（10 個まで全部見ても通る）
test("検証8: followers の投稿の作成で、写真 10 枚と原画像 10 個がすべて url 空文字なら作れる", async () => {
  const list = (n) => arr(Array.from({ length: n }, (_, i) => pathOnlyEntry("followers", i)));
  assert.equal(await createPost("create-f-10-10", { visibility: "followers", images: list(10), originalImages: list(10) }), 200);
});

// 検証8・検証9 の断る側の対照（公開範囲だけが違う）
test("検証8: public の投稿の作成で、写真の url・thumbnail に値があれば作れる", async () => {
  const entry = pathOnlyEntry("public", 0, { url: str(GOOD), thumbnail: str(GOOD) });
  assert.equal(await createPostWithEntry("create-public-urls", "public", entry), 200);
});

test("検証8: followers の投稿の作成で、写真の url に値があると作れない", async () => {
  const entry = pathOnlyEntry("followers", 0, { url: str(GOOD) });
  assert.equal(await createPostWithEntry("create-f-url", "followers", entry), 403);
});

test("検証8: followers の投稿の作成で、写真の thumbnail に値があると作れない", async () => {
  const entry = pathOnlyEntry("followers", 0, { thumbnail: str(GOOD) });
  assert.equal(await createPostWithEntry("create-f-thumbnail", "followers", entry), 403);
});

test("検証8: followers の投稿の作成で、写真の url・thumbnail の両方に値があると作れない", async () => {
  const entry = pathOnlyEntry("followers", 0, { url: str(GOOD), thumbnail: str(GOOD) });
  assert.equal(await createPostWithEntry("create-f-both", "followers", entry), 403);
});

test("検証8: private の投稿の作成で、写真の url に値があると作れない", async () => {
  const entry = pathOnlyEntry("private", 0, { url: str(GOOD) });
  assert.equal(await createPostWithEntry("create-p-url", "private", entry), 403);
});

test("検証8: private の投稿の作成で、写真の thumbnail に値があると作れない", async () => {
  const entry = pathOnlyEntry("private", 0, { thumbnail: str(GOOD) });
  assert.equal(await createPostWithEntry("create-p-thumbnail", "private", entry), 403);
});

test("検証8: followers の投稿の作成で、写真 10 枚の 10 番目の url にだけ値があると作れない", async () => {
  const images = arr(
    Array.from({ length: 10 }, (_, i) =>
      i === 9 ? pathOnlyEntry("followers", i, { url: str(GOOD) }) : pathOnlyEntry("followers", i)
    )
  );
  assert.equal(await createPost("create-f-10th-url", { visibility: "followers", images, originalImages: OMIT }), 403);
});

// MARK: - 検証9: posts の更新で、公開範囲が public でないときの写真の形

test("検証9: 持ち主がキャプションだけを変える更新は、公開範囲が followers でも通る", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_URL_CAPTION, { caption: str("書き直した") }), 200);
});

test("検証9: 他人のいいね +1 は、公開範囲が followers でも通る", async () => {
  assert.equal(await updateDoc(OTHER, POSTS, POST_F_URL_LIKE, { likesCount: int(4) }), 200);
});

test("検証9: followers の投稿の写真を、url 空文字の形に替える更新は通る", async () => {
  const images = arr([pathOnlyEntry("followers", 1)]);
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_EDIT_GOOD, { images }), 200);
});

test("検証9: followers の投稿の写真を、url に値がある形に替える更新は通らない", async () => {
  const images = arr([pathOnlyEntry("followers", 1, { url: str(GOOD) })]);
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_EDIT_BAD_URL, { images }), 403);
});

test("検証9: followers の投稿の写真を、thumbnail に値がある形に替える更新は通らない", async () => {
  const images = arr([pathOnlyEntry("followers", 1, { thumbnail: str(GOOD) })]);
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_EDIT_BAD_THUMBNAIL, { images }), 403);
});

test("検証9: public から followers へ変えて、写真も url 空文字の形に替える更新は通る", async () => {
  const fields = { visibility: str("followers"), images: arr([pathOnlyEntry("followers")]) };
  assert.equal(await updateDoc(POSTER, POSTS, POST_P_TO_F_PATH_ONLY, fields), 200);
});

test("検証9: public から followers へ変えて、写真を url に値がある形に替える更新は通らない", async () => {
  const fields = { visibility: str("followers"), images: arr([pathOnlyEntry("followers", 0, { url: str(GOOD) })]) };
  assert.equal(await updateDoc(POSTER, POSTS, POST_P_TO_F_URL, fields), 403);
});

test("検証9: 写真の url に値がある投稿を、公開範囲だけ public から followers へ変える更新は通らない", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_P_TO_F_KEEP, { visibility: str("followers") }), 403);
});

test("検証9: 写真の url に値がある投稿を、公開範囲だけ public から private へ変える更新は通らない", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_P_TO_PRIVATE_KEEP, { visibility: str("private") }), 403);
});

test("検証9: 写真の url に値がある投稿を、公開範囲だけ followers から private へ変える更新は通らない", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_URL_TO_PRIVATE, { visibility: str("private") }), 403);
});

test("検証9: 写真の url が空文字の投稿を、公開範囲だけ followers から private へ変える更新は通る", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_TO_PRIVATE, { visibility: str("private") }), 200);
});

test("検証9: 写真の url が空文字の投稿を、公開範囲だけ followers から public へ変える更新は通る", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_TO_PUBLIC, { visibility: str("public") }), 200);
});

test("検証9: followers から public へ変えて、写真を url・thumbnail に値がある形に替える更新は通る", async () => {
  const fields = {
    visibility: str("public"),
    images: arr([pathOnlyEntry("public", 0, { url: str(GOOD), thumbnail: str(GOOD) })]),
  };
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_TO_PUBLIC_URL, fields), 200);
});

test("検証9: 公開範囲だけ followers から public へ変える更新は、既にある写真の URL の形に関係なく通る", async () => {
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_OTHER_SHAPE_TO_PUBLIC, { visibility: str("public") }), 200);
});

// ルールの許す最大の数（写真 10 枚・原画像 10 個）に替える更新
test("検証9: followers の投稿の写真 10 枚と原画像 10 個を、すべて url 空文字の形に替える更新は通る", async () => {
  const list = () => arr(Array.from({ length: 10 }, (_, i) => pathOnlyEntry("followers", i)));
  assert.equal(await updateDoc(POSTER, POSTS, POST_F_EDIT_10, { images: list(), originalImages: list() }), 200);
});

test("検証9: private の投稿の写真 10 枚と原画像 10 個を、すべて url 空文字の形に替える更新は通る", async () => {
  const list = () => arr(Array.from({ length: 10 }, (_, i) => pathOnlyEntry("private", i)));
  assert.equal(await updateDoc(POSTER, POSTS, POST_PRIVATE_EDIT_10, { images: list(), originalImages: list() }), 200);
});
