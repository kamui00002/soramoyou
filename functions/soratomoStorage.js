//
// そらもよう Cloud Functions — 「そらとも」の Storage ゲートウェイ ⭐️☁️
//
// 退会・定期掃除・管理スクリプト・利用停止の共通の削除（soratomoDeletion.js）が使う、Cloud Storage への
// 薄い入口。口は 2 つだけ（design.md「soratomoDeletion」の SoratomoStorageGateway）。
//   - listFiles(prefix)  : 接頭辞の下のファイル名（パス）を、ページごとに取りながら 1 つずつ返す（AsyncIterable）
//   - deleteFile(path)   : 1 件を消す。消したら "deleted"、もう無かったら（404）"absent"。ほかの失敗は投げ直す
// 呼び手は、"deleted" の数だけを消した数（imagesDeleted）に数える（無かったものは数えない・要件 3.3 の冪等）。
// 呼び手はこの 2 つの口だけを受け取るので、テストでは偽物へ差し替えて、途中の失敗を作れる。
//
// - 作り方: createStorageGateway(bucket, { pageSize })。bucket は @google-cloud/storage の Bucket
//   （firebase-admin の getStorage().bucket() の戻り値）。省略すると、最初に使うときに既定のバケットを取る。
// - テスト: 偽の bucket で回す単体テストが soratomoStorage.test.js、Storage のエミュレーターに対して本物を流す
//   テストが soratomoStorage.emulator.test.js（要確認 2 の実測の記録もそちら）。
//
// ⚠️ モジュールを読み込んだだけでは firebase-admin を読み込まない（初期化もしない）。既定のバケットは、
//    bucket を省略したゲートウェイが初めて使われたときに getStorage().bucket() で取る。
//    （initializeApp() は index.js 側で 1 回だけ実行される。skyMotion.js と同じ前提。）
// ⚠️ 接頭辞は末尾が "/" のものだけ受け付ける。Cloud Storage の接頭辞は文字列の前方一致なので、
//    "soratomo/g1/u1" は "soratomo/g1/u10/…" まで拾い、ほかの人の画像を消してしまう（要件 1.5 の違反）。
//    "soratomo/g1/u1/" のように末尾の "/" で区切る。空の接頭辞はバケット全体の一覧になるので拒否する。
// ⚠️ 削除に ignoreNotFound: true を使わない。使うと本物は 404 でも成功を返し、"deleted" と "absent" を
//    区別できなくなる（消した数に無かったものが混ざる）。404 はここで自分で判定する。
// ⚠️ 404 の判定は err.code === 404（数値）だけ。@google-cloud/storage が ApiError の code に HTTP ステータスの
//    数値を入れ、ライブラリ自身の ignoreNotFound も同じ判定（nodejs-common/service-object.js）をしているため、
//    それに合わせる。403・429・500・通信エラー（code が無い・文字列）は "absent" にせず、同じエラーのまま投げ直す
//    （権限や一時的な失敗を「もう無かった」と取り違えると、画像が残ったまま削除済みと扱われる）。
//
// ⚠️ package.json の lint に登録してある。テストは test（soratomoStorage.test.js）と test:emulator（soratomoStorage.emulator.test.js）。
//

"use strict";

// MARK: - 定数

/**
 * 1 回の getFiles で取る件数の既定。Cloud Storage の一覧の 1 ページの既定（と上限）が 1000 件のため、それに合わせる。
 * テストでは小さくして、ページ送りを確かめる。
 */
const DEFAULT_PAGE_SIZE = 1000;

// MARK: - 型

/**
 * @typedef {{
 *   listFiles(prefix: string): AsyncIterable<string>,
 *   deleteFile(path: string): Promise<"deleted"|"absent">
 * }} SoratomoStorageGateway
 */

// MARK: - ゲートウェイ

/**
 * Storage のゲートウェイを作る。
 *
 * @param {{ getFiles: Function, file: (path: string) => { delete: Function } }} [bucket]
 *   @google-cloud/storage の Bucket（テストでは偽物）。省略すると、最初に使うときに
 *   firebase-admin の getStorage().bucket()（既定のバケット）を取る。
 * @param {{ pageSize?: number }} [options] pageSize: 1 回の getFiles で取る件数（正の整数。既定 1000）
 * @returns {SoratomoStorageGateway}
 */
function createStorageGateway(bucket, { pageSize = DEFAULT_PAGE_SIZE } = {}) {
  if (!Number.isInteger(pageSize) || pageSize < 1) {
    throw new TypeError(`soratomoStorage: pageSize は正の整数にする（受け取った値: ${String(pageSize)}）`);
  }

  /** 使うときまで bucket を取らない（require しただけで firebase-admin を触らないため）。 */
  let resolvedBucket = bucket;
  const getBucket = () => {
    if (!resolvedBucket) {
      resolvedBucket = require("firebase-admin/storage").getStorage().bucket();
    }
    return resolvedBucket;
  };

  return {
    /**
     * 接頭辞の下のファイル名（バケット内のパス）を、1 ページ取るごとに順に返す。
     * nextQuery が無くなる（null になる）まで、返ってきた nextQuery をそのまま渡して続きを取る。
     * 失敗（権限・通信）は握りつぶさず、そのまま投げる。接頭辞が不正なときも、最初の next() で TypeError を投げる。
     *
     * @param {string} prefix 末尾が "/" の接頭辞。例: "soratomo/{groupId}/{uid}/"
     * @returns {AsyncIterable<string>}
     */
    async *listFiles(prefix) {
      if (typeof prefix !== "string" || !prefix.endsWith("/")) {
        throw new TypeError(
          `soratomoStorage: 接頭辞は末尾が "/" の文字列にする（受け取った値: ${String(prefix)}）`
        );
      }
      const currentBucket = getBucket();
      // autoPaginate: false にすると、1 ページ分の [files, nextQuery, apiResponse] が返る。
      let query = { prefix, autoPaginate: false, maxResults: pageSize };
      while (query) {
        const [files, nextQuery] = await currentBucket.getFiles(query);
        for (const file of files) yield file.name;
        query = nextQuery || null;
      }
    },

    /**
     * 1 件を消す。消したら "deleted"、もう無かった（404）なら "absent"。それ以外の失敗は投げ直す。
     *
     * @param {string} path バケット内のパス。例: "soratomo/{groupId}/{uid}/{skyId}/display.jpg"
     * @returns {Promise<"deleted"|"absent">}
     */
    async deleteFile(path) {
      if (typeof path !== "string" || path === "") {
        throw new TypeError(`soratomoStorage: パスは空でない文字列にする（受け取った値: ${String(path)}）`);
      }
      try {
        await getBucket().file(path).delete();
        return "deleted";
      } catch (err) {
        if (err && err.code === 404) return "absent";
        throw err;
      }
    },
  };
}

module.exports = {
  DEFAULT_PAGE_SIZE,
  createStorageGateway,
};
