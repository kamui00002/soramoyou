//
// そらもよう Cloud Functions — 「そらとも」の共通の削除 ⭐️
//
// 1人のそらとものデータを、release-gate の要件1・2の規則で冪等に消す（design.md の soratomoDeletion）。
// 呼び手は4つ（本人の退会・アカウントの無い人の後始末・管理・利用停止）で、どれも同じ手順を通る。
//
// - 手順1（このファイルの leaveOrDeleteGroupTx・タスク 3.1）: グループ1つ分の「メンバーを外す・オーナーの引き継ぎ・
//   グループごとの削除」をトランザクションで行う。
// - 手順2〜4（投稿と画像・通知の間引き・所属の写し）と時間の予算はタスク 3.2、利用者単位の束ねはタスク 3.3 で足す。
// - 手順1を最初に行う理由: メンバーの文書が消えると、ルール（isSoratomoMember）で画像のアップロードが止まり、
//   soratomoStore.createSkyTx のメンバーの確認で投稿の作成も止まる。以後の新しい投稿は増えない。
// - だれを外し、だれをオーナーにし、人数をいくつにするかは soratomoCore.planMembershipRemoval（純関数）が決める。
//   ここはトランザクションで読んで、その計画どおりに書くだけ。
// - テストは soratomoDeletion.test.js（Firestore のエミュレーター）。
//
// ⚠️ Firestore のトランザクションは「読みを全部終えてから書く」決まり（soratomoStore.js と同じ）。
// ⚠️ 招待コードには、グループごと消すときだけ触れる。引き継いでもコードは変えない（要件2.7）。
// ⚠️ グループの最新の投稿日時（lastActivityAt）は戻さない（要件2の補足）。
//

"use strict";

const core = require("./soratomoCore");

// MARK: - 定数

/** コレクションの名前（soratomoStore.js と同じ）。 */
const GROUPS = "soratomoGroups";
const MEMBERS = "members";
const INVITE_CODES = "soratomoInviteCodes";

// MARK: - 下まわり

/**
 * uid として使えるか（空でない・「/」を含まない・Firebase Auth の上限の128文字以下）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isUid(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 && !value.includes("/");
}

/**
 * Firestore の時刻をミリ秒で読む（Timestamp 以外は null）。
 * @param {unknown} value
 * @returns {number|null}
 */
function millisOf(value) {
  return value && typeof value.toMillis === "function" ? value.toMillis() : null;
}

// MARK: - 手順1: メンバーを外す・オーナーの引き継ぎ・グループごとの削除

/**
 * グループ1つ分の手順1（release-gate 要件2.1・2.2・2.5・2.6・2.7・2.9・2.11・3.4）。
 * グループの文書・メンバーの全文書・（グループごと消すときは）招待コードの文書をトランザクションで読み、
 * planMembershipRemoval の計画どおりに書く。
 * - 残るメンバーがいる（leave）: 自分のメンバーの文書を消し、人数を残りの数で代入し（1減らすのではなく数え直す・2.11）、
 *   オーナーを1人にそろえる（役割が変わる人の分だけ更新）。招待コードは変えない
 * - 残るメンバーがいない（delete_group）: 招待コード（このグループを指しているときだけ）・グループの文書・
 *   自分のメンバーの文書を一緒に消す。同時の参加は、コードかグループの文書が無いので not_found になる。
 *   子（投稿・通知の間引き）と画像は手順2が消す
 * - すでにメンバーでない再実行でも、人数とオーナーを整えるだけで同じ結果になる（removed: false・3.4）
 * - グループの文書が無い（壊れた状態か、グループごとの削除の途中で止まった後）: オーナーも招待コードもわからないので、
 *   自分のメンバーの文書だけを消し、ほかには書かない（groupExisted: false）。子を消すかは手順2が kind で決める
 *   （delete_group＝ほかのメンバーがいないときだけ、子を消してよい）
 * @param {FirebaseFirestore.Firestore} db
 * @param {{ uid: string, groupId: string }} params
 * @returns {Promise<{ kind: "leave"|"delete_group", removed: boolean, ownerTransferred: boolean, groupExisted: boolean }>}
 *   removed はこの実行で自分のメンバーの文書を消したか。ownerTransferred はオーナーを別の人に替えたか
 */
async function leaveOrDeleteGroupTx(db, { uid, groupId }) {
  if (!isUid(uid)) throw new TypeError("soratomo: uid が文書IDとして使えない");
  if (!core.isAutoId(groupId)) throw new TypeError("soratomo: groupId が自動IDの形でない");

  const groupRef = db.collection(GROUPS).doc(groupId);
  const selfRef = groupRef.collection(MEMBERS).doc(uid);

  return db.runTransaction(async (tx) => {
    const groupSnap = await tx.get(groupRef);
    const membersSnap = await tx.get(groupRef.collection(MEMBERS));
    const members = membersSnap.docs.map((doc) => ({
      uid: doc.id,
      role: doc.get("role"),
      joinedAtMs: millisOf(doc.get("joinedAt")),
    }));
    const plan = core.planMembershipRemoval({
      uid,
      ownerId: groupSnap.exists ? groupSnap.get("ownerId") : null,
      members,
    });

    if (!groupSnap.exists) {
      if (plan.removed) tx.delete(selfRef);
      return { kind: plan.kind, removed: plan.removed, ownerTransferred: false, groupExisted: false };
    }

    if (plan.kind === "delete_group") {
      // 招待コードの文書は、このグループを指しているときだけ消す（他のグループのコードを消さないため・再発行と同じ）
      const code = groupSnap.get("inviteCode");
      const codeRef = isUid(code) ? db.collection(INVITE_CODES).doc(code) : null;
      const codeSnap = codeRef ? await tx.get(codeRef) : null;

      // ここから書き込み
      if (codeSnap && codeSnap.exists && codeSnap.get("groupId") === groupId) tx.delete(codeRef);
      tx.delete(groupRef);
      if (plan.removed) tx.delete(selfRef);
      return { kind: "delete_group", removed: plan.removed, ownerTransferred: false, groupExisted: true };
    }

    // ここから書き込み（leave）
    if (plan.removed) tx.delete(selfRef);
    tx.update(groupRef, { memberCount: plan.memberCount, ownerId: plan.ownerId });
    for (const update of plan.roleUpdates) {
      tx.update(groupRef.collection(MEMBERS).doc(update.uid), { role: update.role });
    }
    return { kind: "leave", removed: plan.removed, ownerTransferred: plan.ownerTransferred, groupExisted: true };
  });
}

module.exports = {
  leaveOrDeleteGroupTx,
};
