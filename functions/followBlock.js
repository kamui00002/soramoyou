//
// そらもよう Cloud Functions — ブロックしたら、その相手との両方向のフォローを消す ⭐️☁️（監査 2-3・PR-B）
//
// users/{uid}.blockedUserIds に相手が新しく入ったら、follows/{uid}_{相手} と follows/{相手}_{uid} を消す
// （index.js の onUserBlockListChanged）。
//   - Storage Rules は「follows/{読む人}_{持ち主} がある＝フォロワー限定の写真を見てよい」だけを見る。
//     ブロックした相手のフォローが残ると、その相手は写真を見続けられるので、ここで消す。
//   - 消す文書は ID で決め打ちする（読まない）。follows の ID は firestore.rules の作成の条件で
//     {followerId}_{followeeId} に固定されていて、アプリ（iOS の Follow.makeId）もこの形でしか作らない。
//   - 無い文書を消しても何も起きない（エラーにならず、onFollowDeleted も起きない）＝何回呼んでも同じ結果。
//   - ブロックした本人が、ブロックした相手をフォローするのはルールで止めていない。だから「一覧にいる全員」
//     ではなく「新しく増えた人」だけを消す（前からブロックしている相手へのフォローし直しは消さない）。
//   - そらとものブロック（同じ users/{uid}.blockedUserIds）でも消す。
// ここには firebase-admin / firebase-functions を require しない（db は呼び出し側から渡す）。node:test で検証する。
//

"use strict";

/** フォロー関係のコレクション（iOS の FirestoreService.followsCollection と同じ綴り）。 */
const FOLLOWS = "follows";

/**
 * 1 回の batch で消す組の数。1 組＝両方向の 2 件なので 500 件。Firestore の batch の件数の上限として
 * 知られてきた 500 件に合わせて、保守的に分ける（今の上限の値は、ここでは確かめていない）。
 * ⚠️ 上限で打ち切らない（安全のための削除なので、残すとブロックした相手に写真が見えたままになる）。
 *    超える分は次の batch に回す。
 */
const MAX_PAIRS_PER_BATCH = 250;

/**
 * blockedUserIds の値を「文書の ID に使える相手の uid の配列（重複なし・先に出てきた順）」に正規化する。
 * 項目が無い（ブロックしたことの無い人）・配列でないものは空配列として扱う。
 * @param {unknown} value blockedUserIds の値
 * @param {string} userId 一覧の持ち主（自分自身は捨てる＝自分のフォローを消さない）
 * @returns {string[]}
 */
function normalizeBlockedIds(value, userId) {
  if (!Array.isArray(value)) return [];
  const seen = new Set();
  const result = [];
  for (const id of value) {
    // 文字列でない・空・/ を含む値は捨てる（/ はパスの区切りになり、follows の外の文書を指してしまう）。
    if (typeof id !== "string" || id.length === 0 || id.includes("/")) continue;
    if (id === userId || seen.has(id)) continue;
    seen.add(id);
    result.push(id);
  }
  return result;
}

/**
 * 更新前後の一覧から「新しくブロックした相手」を返す（フォローを消す対象）。
 * ブロック解除（外しただけ）・並べ替え・ほかの項目の更新（数え直し・通知の設定など）では空配列になる。
 * @param {unknown} before 更新前の blockedUserIds（users の作成時は undefined）
 * @param {unknown} after 更新後の blockedUserIds（users の削除時は undefined）
 * @param {string} userId 一覧の持ち主
 * @returns {string[]}
 */
function addedBlockedIds(before, after, userId) {
  const beforeIds = new Set(normalizeBlockedIds(before, userId));
  return normalizeBlockedIds(after, userId).filter((id) => !beforeIds.has(id));
}

/**
 * 新しくブロックした相手との両方向のフォロー（{userId}_{相手} と {相手}_{userId}）を消す。
 * 差分が空なら db に一度も触らずに抜ける（users が書かれるたびに起きるので、ほとんどはここで終わる）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {string} userId ブロックした人（一覧の持ち主）
 * @param {unknown} before 更新前の blockedUserIds
 * @param {unknown} after 更新後の blockedUserIds
 * @returns {Promise<string[]>} 消しに行った follows の文書 ID（無かった文書も含む）
 */
async function removeFollowsForNewBlocks(db, userId, before, after) {
  const added = addedBlockedIds(before, after, userId);
  if (added.length === 0) return [];

  const docIds = [];
  for (let start = 0; start < added.length; start += MAX_PAIRS_PER_BATCH) {
    const batch = db.batch();
    for (const otherId of added.slice(start, start + MAX_PAIRS_PER_BATCH)) {
      // 両方向: 自分 → 相手（自分のフォロー）と、相手 → 自分（相手が自分のフォロワー＝写真を見られる側）。
      for (const docId of [`${userId}_${otherId}`, `${otherId}_${userId}`]) {
        batch.delete(db.collection(FOLLOWS).doc(docId));
        docIds.push(docId);
      }
    }
    await batch.commit();
  }
  return docIds;
}

/**
 * トリガー（onDocumentWritten("users/{userId}")）の中身。
 * 作成（前の文書が無い）・更新・削除（後の文書が無い）のどれでも落ちない。
 * 削除では一覧が「無い」になるので何もしない（退会の follows は退会の処理が消す）。
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ params: { userId: string }, data?: { before?: { data(): any }, after?: { data(): any } } }} event
 * @returns {Promise<string[]>} 消しに行った follows の文書 ID
 */
async function handleUserWritten(db, event) {
  const change = event && event.data;
  const before = change && change.before && change.before.data();
  const after = change && change.after && change.after.data();
  // 持ち主はパスの userId で決める（文書の中の id は、users の作成のルールで userId との一致を確かめていない）。
  return removeFollowsForNewBlocks(
    db,
    event.params.userId,
    before && before.blockedUserIds,
    after && after.blockedUserIds
  );
}

module.exports = {
  MAX_PAIRS_PER_BATCH,
  normalizeBlockedIds,
  addedBlockedIds,
  removeFollowsForNewBlocks,
  handleUserWritten,
};
