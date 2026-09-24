//
// そらもよう Cloud Functions — 「私のおすすめの空」通知の純粋関数 ⭐️
//
// publicProfiles/{uid}.recommendedPostIds（表示順の postId 配列・最大 3 件）が更新されたとき、
// 新しく入った投稿の投稿者へ「おすすめの空に選ばれました」と通知する（index.js の onPublicProfileUpdated）。
// ここには firebase-admin / firebase-functions に触れない純粋関数だけを置き、node:test で検証する。
//

"use strict";

/**
 * 1 回の更新で通知を試みる最大件数。
 * ⚠️ iOS の RecommendedSkies.maxCount / firestore.rules の size() <= 3 と一致させること。
 *    rules を通らない書き込み（管理者の手作業など）で配列が長くなっても、通知が膨らまないようにする上限。
 */
const MAX_RECOMMENDATIONS = 3;

/**
 * 値を「空でない文字列の配列（重複なし・先に出てきた順）」に正規化する。
 * フィールド欠落（旧データ）・型違いは空配列として扱う。
 * @param {unknown} value
 * @returns {string[]}
 */
function normalizePostIds(value) {
  if (!Array.isArray(value)) return [];
  const seen = new Set();
  const result = [];
  for (const id of value) {
    if (typeof id !== "string" || id.length === 0 || seen.has(id)) continue;
    seen.add(id);
    result.push(id);
  }
  return result;
}

/**
 * 更新前後の一覧から「新しく入った postId」を返す（通知の対象）。
 * 並べ替えだけ・外しただけ・他フィールドの更新（表示名・フォロー数など）では空配列になる。
 * @param {unknown} before 更新前の recommendedPostIds
 * @param {unknown} after 更新後の recommendedPostIds
 * @returns {string[]}
 */
function addedRecommendationIds(before, after) {
  const beforeIds = new Set(normalizePostIds(before));
  return normalizePostIds(after)
    .filter((id) => !beforeIds.has(id))
    .slice(0, MAX_RECOMMENDATIONS);
}

/**
 * 通知済みマーカー（recommendationNotices）のドキュメント ID。
 * 同じ人が同じ投稿を外して入れ直しても、通知は最初の 1 回だけにするために使う。
 * @param {string} recommenderId おすすめした人
 * @param {string} postId おすすめされた投稿
 * @returns {string}
 */
function noticeId(recommenderId, postId) {
  return `${recommenderId}_${postId}`;
}

/**
 * 通知本文。
 * @param {string} recommenderName おすすめした人の表示名
 * @returns {string}
 */
function noticeBody(recommenderName) {
  return `${recommenderName}さんがあなたの空を「おすすめの空」に選びました`;
}

/**
 * Firestore の create() が「既に存在する」で失敗したか（Admin SDK は gRPC コード 6）。
 * @param {unknown} err
 * @returns {boolean}
 */
function isAlreadyExistsError(err) {
  const code = err && err.code;
  return code === 6 || code === "already-exists" || code === "ALREADY_EXISTS";
}

module.exports = {
  MAX_RECOMMENDATIONS,
  normalizePostIds,
  addedRecommendationIds,
  noticeId,
  noticeBody,
  isAlreadyExistsError,
};
