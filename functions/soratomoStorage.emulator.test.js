//
// soratomoStorage.js のテスト（Storage のエミュレーターに対して、本物のゲートウェイを流す）⭐️☁️
//
// 実行（リポジトリの根で。Storage のエミュレーターも Java が要る＝rules の実行環境が jar のため）:
//   JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" PATH="$JAVA_HOME/bin:$PATH" \
//     firebase emulators:exec --only storage --project demo-soratomo-gate \
//     "cd functions && node --test soratomoStorage.emulator.test.js"
//   （リポジトリ根の firebase.json は Storage を 9199 に置く。ほかのエミュレーターが 9199 を使っているときは、
//    ポートを変えた最小の firebase.json を --config で渡す。）
//
// ⚠️ 本番へ書く事故の柵: この Mac の firebase-admin は資格情報を持っている。FIREBASE_STORAGE_EMULATOR_HOST が
//    無いと、firebase-admin は本番のバケットへ書いてしまう。そこで、エミュレーター（127.0.0.1・localhost・[::1]）を
//    指していなければ、firebase-admin を読み込む前に理由を出して終了コード 1 で止める。
//    skip にはしない（skip は「何も確かめていない緑」に化けるため）。soratomoStore.test.js の柵と同じ型。
// ⚠️ プロジェクトIDは demo- で始まるものを使う（demo- はエミュレーターだけで動き、本番に触れない）。
// ⚠️ 各テストは自分のグループ（soratomo/gNN/）の下だけを使い、始めに消す（再実行しても、並べて走らせても壊れない）。
//
// ■ 要確認 2（design.md「StorageのエミュレーターでAdmin SDKの getFiles({ prefix }) と delete() の404が本番と同じか」）
//   この Mac（firebase-tools 15.0.0・firebase-admin 14.5.0・@google-cloud/storage 8.2.0・2026-10-08）で実測した事実:
//   - 接頭辞の一覧: getFiles({ prefix, autoPaginate: false, maxResults }) は [files, nextQuery, apiResponse] を返し、
//     ページが残るあいだ nextQuery が非 null（pageToken つき）、最後のページで null。接頭辞は文字列の前方一致なので
//     "soratomo/g1/u1" は u10 も拾う（末尾が "/" のときだけ u1 の下に限られる）。
//   - 存在しないオブジェクトの delete() は、ApiError（constructor.name は "ApiError"・err.name は "Error"）を投げる。
//     err.code は **数値の 404**、err.errors[0].reason は "notFound"、
//     err.message は "No such object: <バケット>/<パス>"。
//   - 本番との照合: 本番の Cloud Storage JSON API の 404 も、同じライブラリが ApiError にして code に HTTP ステータスの
//     数値を入れる。ライブラリ自身の ignoreNotFound の判定も err.code === 404（@google-cloud/storage の
//     nodejs-common/service-object.js）なので、ゲートウェイの判定（code === 404 だけを "absent"）は同じ根拠に立つ。
//   - 要確認として残るもの: エミュレーターの 404 の応答の JSON の中身が本番と一字一句同じかは、公開文書では確かめられない
//     （code と reason の2つが同じことだけを確かめた）。本物の Cloud Storage での確認は、実機の退会（tasks 16.1）で行う。
//

"use strict";

// MARK: - 柵（ここより前で firebase-admin を読み込まない）

const EMULATOR_HOST = process.env.FIREBASE_STORAGE_EMULATOR_HOST;
if (!EMULATOR_HOST || !/^(127\.0\.0\.1|localhost|\[::1\]):\d+$/.test(EMULATOR_HOST)) {
  console.error(
    "FIREBASE_STORAGE_EMULATOR_HOST がエミュレーターを指していないため中止した（本番のバケットへ書かないため）。" +
      " firebase emulators:exec --only storage --project demo-soratomo-gate の中で実行すること。" +
      ` 現在の値: ${EMULATOR_HOST ?? "(未設定)"}`
  );
  process.exit(1);
}

const test = require("node:test");
const assert = require("node:assert/strict");
const { initializeApp, deleteApp } = require("firebase-admin/app");
const { getStorage } = require("firebase-admin/storage");

const { createStorageGateway } = require("./soratomoStorage");

/** エミュレーターのプロジェクトID（emulators:exec の --project が GCLOUD_PROJECT に入る）。 */
const PROJECT_ID = process.env.GCLOUD_PROJECT || "demo-soratomo-gate";
const app = initializeApp(
  { projectId: PROJECT_ID, storageBucket: `${PROJECT_ID}.appspot.com` },
  "soratomoStorageTest"
);
const bucket = getStorage(app).bucket();

// MARK: - 下ごしらえ

/** 画像に見立てた小さなファイルを置く（本物の画像でなくてよい。一覧と削除の動きだけを見る）。 */
async function put(filePath) {
  await bucket.file(filePath).save(Buffer.from("x"), { contentType: "image/jpeg", resumable: false });
}

/** 1 つの投稿の画像 2 枚（display.jpg と thumb.jpg）を置いて、パスを返す。 */
async function putSky(groupId, uid, skyId) {
  const base = `soratomo/${groupId}/${uid}/${skyId}`;
  const paths = [`${base}/display.jpg`, `${base}/thumb.jpg`];
  for (const p of paths) await put(p);
  return paths;
}

/** そのグループの下を全部消す（始めに呼ぶ）。ゲートウェイでなくライブラリ自身で消す（確かめる対象を使わない）。 */
async function resetGroup(groupId) {
  await bucket.deleteFiles({ prefix: `soratomo/${groupId}/`, force: true });
  const [left] = await bucket.getFiles({ prefix: `soratomo/${groupId}/` });
  assert.equal(left.length, 0, `下ごしらえ: soratomo/${groupId}/ が空になっていない`);
}

/** AsyncIterable を配列に集める。 */
async function collect(iterable) {
  const out = [];
  for await (const item of iterable) out.push(item);
  return out;
}

/** getFiles の呼び出し回数を数える以外は本物の bucket そのもの（ページ送りが本当に起きたかを見る）。 */
function countingBucket() {
  const stats = { getFilesCalls: 0 };
  const wrapped = {
    stats,
    getFiles: (query) => {
      stats.getFilesCalls += 1;
      return bucket.getFiles(query);
    },
    file: (p) => bucket.file(p),
  };
  return wrapped;
}

test.after(async () => {
  await deleteApp(app);
});

// MARK: - 接頭辞の一覧

test("接頭辞 soratomo/g1/u1/ の一覧は u1 の分だけを返し、u10 も u2 も拾わない", async (t) => {
  await resetGroup("g1");
  const u1 = [...(await putSky("g1", "u1", "s1")), ...(await putSky("g1", "u1", "s2"))];
  await putSky("g1", "u10", "s1"); // u1 の接頭辞（スラッシュ無し）で拾ってしまう相手
  await putSky("g1", "u2", "s1");

  const gateway = createStorageGateway(bucket);
  const names = await collect(gateway.listFiles("soratomo/g1/u1/"));
  assert.deepEqual([...names].sort(), [...u1].sort());

  // 事実の記録: 末尾の "/" が無いと u10 まで拾う（だからゲートウェイは末尾が "/" でない接頭辞を拒否する）。
  const [noSlash] = await bucket.getFiles({ prefix: "soratomo/g1/u1" });
  assert.equal(
    noSlash.some((f) => f.name.startsWith("soratomo/g1/u10/")),
    true,
    "スラッシュ無しの接頭辞は u10 も拾う（実測）"
  );
  t.diagnostic(`スラッシュ無し soratomo/g1/u1 の一覧: ${noSlash.length} 件（u1 は ${u1.length} 件）`);

  await resetGroup("g1");
});

test("pageSize 2 で 5 枚を 3 ページに分けて、本物でも全件が返る（nextQuery が本物でも動く）", async () => {
  await resetGroup("g2");
  const orphan = "soratomo/g2/u1/orphan/display.jpg"; // 取り残しの 1 枚（thumb は無い）
  await put(orphan);
  const placed = [...(await putSky("g2", "u1", "s1")), ...(await putSky("g2", "u1", "s2")), orphan];
  assert.equal(placed.length, 5);

  const counting = countingBucket();
  const gateway = createStorageGateway(counting, { pageSize: 2 });
  const names = await collect(gateway.listFiles("soratomo/g2/u1/"));

  assert.deepEqual([...names].sort(), [...placed].sort(), "5 枚すべて、重複なし");
  assert.equal(new Set(names).size, 5);
  assert.equal(counting.stats.getFilesCalls, 3, "2+2+1 の 3 ページに実際に分かれた");

  await resetGroup("g2");
});

test("一覧は取れた分から順に返す（全ページを読み切ってから返さない）", async () => {
  await resetGroup("g3");
  for (const s of ["s1", "s2", "s3"]) await putSky("g3", "u1", s); // 6 枚

  const counting = countingBucket();
  const gateway = createStorageGateway(counting, { pageSize: 2 });
  const it = gateway.listFiles("soratomo/g3/u1/")[Symbol.asyncIterator]();
  const first = await it.next();
  assert.equal(first.done, false);
  assert.equal(counting.stats.getFilesCalls, 1, "最初の 1 件を取るのに読んだのは 1 ページ");
  await it.return();

  await resetGroup("g3");
});

test("該当が無い接頭辞の一覧は空", async () => {
  await resetGroup("g4");
  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  assert.deepEqual(await collect(gateway.listFiles("soratomo/g4/u1/")), []);
});

// MARK: - 削除

test("置いた枚数を全部消すと \"deleted\" の数が置いた枚数と一致し、もう一度一覧すると空。ほかの人の分は残る", async () => {
  await resetGroup("g5");
  const u1 = [
    ...(await putSky("g5", "u1", "s1")),
    ...(await putSky("g5", "u1", "s2")),
    ...(await putSky("g5", "u1", "s3")),
  ];
  const others = [...(await putSky("g5", "u10", "s1")), ...(await putSky("g5", "u2", "s1"))];

  const gateway = createStorageGateway(bucket, { pageSize: 2 });
  let deleted = 0;
  let absent = 0;
  // 一覧を読み進めながら、読み終えた分をすぐ消す（本番の削除の手順と同じ使い方）。
  // pageSize 2 なので 3 ページに分かれ、2 ページ目以降は「前のページの分が既に消えた後」に取りに行く。
  for await (const name of gateway.listFiles("soratomo/g5/u1/")) {
    const result = await gateway.deleteFile(name);
    if (result === "deleted") deleted += 1;
    else absent += 1;
  }
  assert.equal(deleted, u1.length, "消した数が置いた枚数と一致");
  assert.equal(absent, 0);

  assert.deepEqual(await collect(gateway.listFiles("soratomo/g5/u1/")), [], "もう一度一覧すると空");
  const rest = await collect(gateway.listFiles("soratomo/g5/"));
  assert.deepEqual([...rest].sort(), [...others].sort(), "u10・u2 の分は残る");

  await resetGroup("g5");
});

test("同じファイルを 2 回消すと、1 回目は deleted・2 回目は absent", async () => {
  await resetGroup("g6");
  const [display] = await putSky("g6", "u1", "s1");
  const gateway = createStorageGateway(bucket);
  assert.equal(await gateway.deleteFile(display), "deleted");
  assert.equal(await gateway.deleteFile(display), "absent");
  await resetGroup("g6");
});

test("存在しないパスの削除は absent（404 のエラーの形も実測して確かめる）", async (t) => {
  await resetGroup("g7");
  const missing = "soratomo/g7/u1/s1/display.jpg";

  // 実測: ライブラリ自身が投げる 404 のエラーの形（要確認 2 の中身。冒頭コメントに事実として書いた）。
  let caught;
  try {
    await bucket.file(missing).delete();
  } catch (err) {
    caught = err;
  }
  assert.ok(caught, "存在しないオブジェクトの delete() は投げる");
  t.diagnostic(
    `404 の形: constructor=${caught.constructor.name} name=${caught.name} code=${String(caught.code)}` +
      `(${typeof caught.code}) errors[0].reason=${caught.errors?.[0]?.reason} message=${caught.message}`
  );
  assert.equal(caught.code, 404, "code は数値の 404（ライブラリ自身の ignoreNotFound の判定と同じ形）");
  assert.equal(caught.errors?.[0]?.reason, "notFound");

  // ゲートウェイは、その 404 を absent に写す。
  const gateway = createStorageGateway(bucket);
  assert.equal(await gateway.deleteFile(missing), "absent");
});

test("一覧の後で誰かに消された 1 枚（404）は、消した数から除かれる", async () => {
  await resetGroup("g8");
  const placed = [...(await putSky("g8", "u1", "s1")), ...(await putSky("g8", "u1", "s2"))]; // 4 枚
  const gateway = createStorageGateway(bucket, { pageSize: 2 });

  const names = await collect(gateway.listFiles("soratomo/g8/u1/"));
  assert.equal(names.length, placed.length);
  await bucket.file(names[2]).delete(); // 一覧の後に、ほかの経路が 1 枚消した状況

  const results = [];
  for (const name of names) results.push(await gateway.deleteFile(name));
  assert.equal(results.filter((r) => r === "deleted").length, placed.length - 1);
  assert.equal(results.filter((r) => r === "absent").length, 1);

  await resetGroup("g8");
});
