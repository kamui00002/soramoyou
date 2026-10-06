#!/usr/bin/env node

/**
 * ⭐️☁️ そらともの画像（Storage の soratomo/ 以下）に、ダウンロードトークンが自動で付いたかを数えるスクリプト
 *
 * 何を確かめるのか（tasks 3.2・design.md「要確認」の 3）:
 *   クライアントの SDK でアップロードしたオブジェクトには、メタデータの firebaseStorageDownloadTokens
 *   （ダウンロードトークン）が自動で付くことがある。付いていると、メンバーは改造したアプリから
 *   「トークン付きの共有用 URL」を作って外へ渡せる（このURLは Storage のルールを通らない）。
 *   そこで、本物のアップロード済みオブジェクトのメタデータを Admin SDK で読み、トークンの項目があるかだけを数える。
 *
 * ⚠️ 出すのは「調べた件数・トークンありの件数・トークン無しの件数」の 3 つだけ。
 *   トークンの値・URL・オブジェクトのパス（uid とグループ ID が入る）・エラーの本文は、画面にもログにも出さない。
 * ⚠️ 読み取り専用。メタデータの書き換え・削除・URL の発行は一切しない。
 *
 * いつ実行するのか:
 *   本番でクライアントの SDK から実際にアップロードした後でないと確かめられない。
 *   iOS のアップロード（tasks 11.4）ができてから、実機の E2E（tasks 15.1）の中で、ユーザーと一緒に実行する。
 *   それまでは本番に対して実行しない（node --check と単体テストだけを回す）。
 *
 * 実行の前に確かめること:
 *   soratomo/ の下に、iOS から上げたもの以外（Admin SDK・コンソール・種データで置いたテスト用の画像）が無いこと。
 *   あると「トークン無し」に混ざり、クライアントの SDK の挙動を正しく読めない。
 *
 * 認証: Application Default Credentials（ADC）を使う。鍵ファイルはリポジトリに置かない。
 *   1. gcloud auth application-default login
 *   2. quota project を求められたら:
 *        gcloud auth application-default set-quota-project soramoyou-ios
 *   接続先は EXPECTED_PROJECT_ID（soramoyou-ios）と EXPECTED_BUCKET に固定している（ADC の既定に頼らない）。
 *
 * 実行方法（リポジトリ直下で）:
 *   firebase-admin は functions/ の依存を借りる（functions で npm install 済みであること）。
 *     NODE_PATH=functions/node_modules node scripts/check-soratomo-download-tokens.js
 *
 * 数え方:
 *   - 「トークンあり」= メタデータの firebaseStorageDownloadTokens が、空でない文字列（カンマ区切りで 1 つ以上）。
 *     項目が無い・null・空文字・空白とカンマだけ、は「トークン無し」。
 *     文字列以外の想定外の型が入っていたときは、見落とさないよう「トークンあり」に倒す。
 *   - 名前が「/」で終わるもの（コンソールが作るフォルダの印）は画像ではないので、調べた件数に含めない。
 *   - 調べた件数が 0 のときは、判定できない（まだアップロードが無い・接続先か接頭辞が違う）ので、終了コード 1 にする。
 *
 * 結果の扱い（tasks 3.2 の本文）:
 *   - 1 件でも「トークンあり」だった場合:
 *       メンバーが改造したアプリでトークン付きの URL を作れる残余リスクとして受け入れ、そう記録する
 *       （design.md の Security Considerations）。あわせて、アプリが URL を作らず・保存しないことを確かめる
 *       （そらともの画像は getData だけで取得し、downloadURL() を呼ばない）。
 *   - 「トークンあり」が 0 件で「トークン無し」だけだった場合: 追加の対応はしない。
 *   - どちらの場合も、結果（件数）を記録して tasks 3.2 を完了にする。
 *
 * テスト: node --test scripts/check-soratomo-download-tokens.test.js（firebase-admin 非依存。本番には触れない）
 */

"use strict";

/** 読み取り先として唯一許可する Firebase プロジェクト（.firebaserc が空のため、ここで固定する）。 */
const EXPECTED_PROJECT_ID = "soramoyou-ios";
/** 読み取り先のバケット（GoogleService-Info.plist の STORAGE_BUCKET と同じ。バケット名は秘密ではない）。 */
const EXPECTED_BUCKET = "soramoyou-ios.firebasestorage.app";
/** 調べる範囲。末尾の「/」まで含めて、soratomo-xxx のような別の接頭辞を巻き込まない。 */
const PREFIX = "soratomo/";
/** オブジェクトのカスタムメタデータの中で、ダウンロードトークンが入る項目名。 */
const TOKEN_KEY = "firebaseStorageDownloadTokens";

/** 調べた件数が 0 のときに、標準エラーへ出す固定の文言（名前・パスは含めない）。 */
const NO_OBJECTS_HINT =
  "⚠️ 調べた件数が 0 です。判定できません（まだアップロードが無いか、接続先のバケットか接頭辞が違う可能性があります）";

const USAGE = "使い方: node scripts/check-soratomo-download-tokens.js（引数はありません）";

/**
 * コマンドラインの引数を読む。このスクリプトは引数を取らない（接続先と範囲は固定）。
 * @param {string[]} argv process.argv.slice(2)
 * @returns {{ ok: boolean }}
 */
function parseArgs(argv) {
  return { ok: argv.length === 0 };
}

/**
 * 1 つのオブジェクトに、ダウンロードトークンが付いているか。
 * カスタムメタデータは、オブジェクトのメタデータの中の `metadata` に入る（metadata が 2 重になる）。
 * @param {Object|null|undefined} objectMetadata Storage のオブジェクトのメタデータ（file.metadata）
 * @returns {boolean}
 */
function hasDownloadToken(objectMetadata) {
  const custom = objectMetadata && objectMetadata.metadata;
  const value = custom ? custom[TOKEN_KEY] : undefined;
  if (value === undefined || value === null) return false;
  if (typeof value === "string") {
    // トークンは複数あるとカンマ区切りで入る。空白とカンマだけなら、付いていないのと同じ。
    return value.split(",").some((token) => token.trim() !== "");
  }
  // 文字列以外の想定外の型は、見落とさないように「付いている」側に倒す。
  return true;
}

/**
 * フォルダの印（名前が「/」で終わるオブジェクト）か。画像ではないので数えない。
 * @param {Object|null|undefined} objectMetadata
 * @returns {boolean}
 */
function isFolderMarker(objectMetadata) {
  const name = objectMetadata && objectMetadata.name;
  return typeof name === "string" && name.endsWith("/");
}

/**
 * オブジェクトのメタデータの配列から、件数だけを数える。渡した配列・オブジェクトは書き換えない。
 * 戻り値には件数だけを入れる（トークンの値・名前・パスは持ち出さない）。
 * @param {Array<Object|null|undefined>} metadataList file.metadata の配列
 * @returns {{ checked: number, withToken: number, withoutToken: number }}
 */
function countDownloadTokens(metadataList) {
  let withToken = 0;
  let withoutToken = 0;
  for (const objectMetadata of metadataList) {
    if (isFolderMarker(objectMetadata)) continue;
    if (hasDownloadToken(objectMetadata)) {
      withToken += 1;
    } else {
      withoutToken += 1;
    }
  }
  return { checked: withToken + withoutToken, withToken, withoutToken };
}

/**
 * 画面に出す結果。件数 3 つだけ（トークンの値・URL・パスは出さない）。
 * @param {{ checked: number, withToken: number, withoutToken: number }} counts
 * @returns {string}
 */
function formatResult(counts) {
  return [`調べた件数: ${counts.checked}`, `トークンあり: ${counts.withToken}`, `トークン無し: ${counts.withoutToken}`].join("\n");
}

/**
 * 本体。firebase-admin はここでだけ読み込む（テストと引数の確認に依存を持ち込まないため）。
 * @param {string[]} argv
 */
async function main(argv) {
  if (!parseArgs(argv).ok) {
    console.error(USAGE);
    process.exitCode = 2;
    return;
  }

  const { initializeApp, applicationDefault } = require("firebase-admin/app");
  const { getStorage } = require("firebase-admin/storage");
  initializeApp({ credential: applicationDefault(), projectId: EXPECTED_PROJECT_ID });

  console.log(`🔌 接続先 Firebase プロジェクト: ${EXPECTED_PROJECT_ID}`);
  console.log(`🔌 読み取り専用で ${PREFIX} 以下のメタデータを数えます`);

  // ライブラリは、一覧の各項目（オブジェクトの資源）をそのまま file.metadata に入れる（1 件ずつ読み直さない）。
  // 一覧の応答にカスタムメタデータが含まれることは、15.1 の実行結果で確かめる（下の注意を参照）。
  // ⚠️ 「トークンあり: 0」は、トークンが付いていないのか、一覧に含まれていないのかを、この結果だけでは区別できない。
  //    0 だったときは、1 件の file.getMetadata() の結果と照らして確かめてから「付いていない」と記録する。
  const [files] = await getStorage().bucket(EXPECTED_BUCKET).getFiles({ prefix: PREFIX });
  const counts = countDownloadTokens(files.map((file) => file.metadata));

  console.log(formatResult(counts));
  if (counts.checked === 0) {
    console.error(NO_OBJECTS_HINT);
    process.exitCode = 1;
  }
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((err) => {
    // エラーの本文にはバケットやパス・権限の情報が入りうるため出さず、コード（数値なら HTTP の状態）だけにする。
    const code = err && err.code !== undefined && err.code !== null ? String(err.code) : "不明なエラー";
    console.error(`❌ 失敗しました: ${code}（認証（ADC）・権限・接続先を確認してください）`);
    process.exitCode = 1;
  });
}

module.exports = {
  EXPECTED_PROJECT_ID,
  EXPECTED_BUCKET,
  PREFIX,
  TOKEN_KEY,
  NO_OBJECTS_HINT,
  parseArgs,
  hasDownloadToken,
  isFolderMarker,
  countDownloadTokens,
  formatResult,
};
