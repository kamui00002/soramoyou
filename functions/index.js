//
// そらもよう Cloud Functions（プッシュ通知の送信側）
//
// トリガー（Firestore ドキュメント作成）:
//   - onLikeCreated    likes/{likeId}      → 投稿者へ「いいねされました」
//   - onCommentCreated comments/{commentId}→ 投稿者へ「コメントされました」
//   - onPostCreated    posts/{postId}      → フォロワー / 全員（オプトイン）へ「新しい空」
//
// 設計メモ:
//   - 配信プレフは users/{uid} の notifyReactions / notifyNewPostsFromFollowing /
//     notifyNewPostsFromEveryone を読む。フィールド欠落（旧ユーザー）は PREF_DEFAULTS で補う。
//     ⚠️ この既定は iOS の User.swift と必ず一致させること（reactions=true / following=true / everyone=false）。
//   - 自分自身の操作（自分の投稿への自いいね等）は通知しない。
//   - 送信トークンが無い（未登録/未許可）ユーザーはスキップ。
//   - 無効トークン（registration-token-not-registered 等）は users/{uid}.fcmToken を掃除する。
//   - 新規投稿の配信は重複排除のうえ 500 件ずつ multicast。
//
// ⚠️ デプロイ前提:
//   1. Firebase を Blaze プランにする（Cloud Functions は無料 Spark 不可）。
//   2. Cloud Functions API を有効化（初回 deploy で案内される）。
//   3. REGION は Firestore データベースと同一リージョンにすること（不一致だと deploy で失敗する）。
//

const { setGlobalOptions } = require("firebase-functions/v2");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const logger = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();
const db = getFirestore();
const messaging = getMessaging();

// Functions のリージョン。Firestore DB と同一リージョン必須（このプロジェクトの DB は asia-northeast1=東京）。
// firebase.json の firestore.location が asia-northeast1 のため、ここも合わせる（不一致だと deploy 失敗）。
const REGION = "asia-northeast1";
setGlobalOptions({ region: REGION, maxInstances: 10 });

// 通知プレフの既定（iOS User.swift と一致させること）。
const PREF_DEFAULTS = {
  notifyReactions: true,
  notifyNewPostsFromFollowing: true,
  notifyNewPostsFromEveryone: false,
};

/** users ドキュメントの配信プレフを既定込みで読む。 */
function prefEnabled(userData, key) {
  const v = userData ? userData[key] : undefined;
  return typeof v === "boolean" ? v : PREF_DEFAULTS[key];
}

/** users/{uid} を取得（存在しなければ null）。 */
async function getUser(uid) {
  const snap = await db.collection("users").doc(uid).get();
  return snap.exists ? snap.data() : null;
}

/** 通知本文に使う表示名（無ければ「だれか」）。email など PII は使わない。 */
function displayNameOf(userData) {
  return userData && userData.displayName ? userData.displayName : "だれか";
}

/** 無効トークンエラーか。 */
function isInvalidTokenError(code) {
  return (
    code === "messaging/registration-token-not-registered" ||
    code === "messaging/invalid-registration-token" ||
    code === "messaging/invalid-argument"
  );
}

/** 単一ユーザーへ送る（リアクション通知用）。無効トークンは掃除する。 */
async function sendToUser(uid, userData, notification, data) {
  const token = userData && userData.fcmToken;
  if (!token) return;
  try {
    await messaging.send({
      token,
      notification,
      data,
      apns: { payload: { aps: { sound: "default" } } },
    });
  } catch (err) {
    const code = err && err.code;
    if (isInvalidTokenError(code)) {
      await db.collection("users").doc(uid).update({ fcmToken: FieldValue.delete() }).catch(() => {});
    } else {
      logger.error("FCM send failed", { uid, code: String(code) });
    }
  }
}

/** multicast の失敗レスポンスから無効トークンを掃除する。 */
async function cleanupInvalidTokens(tokens, tokenToUid, responses) {
  const removals = [];
  responses.forEach((resp, i) => {
    if (!resp.success && isInvalidTokenError(resp.error && resp.error.code)) {
      const uid = tokenToUid[tokens[i]];
      if (uid) {
        removals.push(
          db.collection("users").doc(uid).update({ fcmToken: FieldValue.delete() }).catch(() => {})
        );
      }
    }
  });
  await Promise.all(removals);
}

// MARK: - リアクション通知（いいね）

exports.onLikeCreated = onDocumentCreated("likes/{likeId}", async (event) => {
  const like = event.data && event.data.data();
  if (!like) return;
  const likerId = like.userId;
  const postId = like.postId;
  if (!likerId || !postId) return;

  const postSnap = await db.collection("posts").doc(postId).get();
  if (!postSnap.exists) return;
  const ownerId = postSnap.data().userId;
  // 自分の投稿への自いいねは通知しない。
  if (!ownerId || ownerId === likerId) return;

  const owner = await getUser(ownerId);
  if (!owner || !owner.fcmToken || !prefEnabled(owner, "notifyReactions")) return;

  const liker = await getUser(likerId);
  await sendToUser(
    ownerId,
    owner,
    { title: "そらもよう", body: `${displayNameOf(liker)}さんがあなたの空にいいねしました` },
    { type: "like", postId }
  );
});

// MARK: - リアクション通知（コメント）

exports.onCommentCreated = onDocumentCreated("comments/{commentId}", async (event) => {
  const comment = event.data && event.data.data();
  if (!comment) return;
  const commenterId = comment.userId;
  const postId = comment.postId;
  if (!commenterId || !postId) return;

  const postSnap = await db.collection("posts").doc(postId).get();
  if (!postSnap.exists) return;
  const ownerId = postSnap.data().userId;
  if (!ownerId || ownerId === commenterId) return;

  const owner = await getUser(ownerId);
  if (!owner || !owner.fcmToken || !prefEnabled(owner, "notifyReactions")) return;

  // 表示名はコメントに非正規化保存された authorName を優先（無ければ users から）。
  const name = comment.authorName || displayNameOf(await getUser(commenterId));
  const snippet = String(comment.content || "").slice(0, 40);
  await sendToUser(
    ownerId,
    owner,
    { title: "そらもよう", body: `${name}さんがコメントしました${snippet ? `: ${snippet}` : ""}` },
    { type: "comment", postId }
  );
});

// MARK: - 新着投稿通知（フォロワー / 全員）

exports.onPostCreated = onDocumentCreated("posts/{postId}", async (event) => {
  const post = event.data && event.data.data();
  if (!post) return;
  const posterId = post.userId;
  const postId = event.params.postId;
  if (!posterId) return;

  const poster = await getUser(posterId);
  const name = displayNameOf(poster);

  // 受信者の uid -> token（本人除外・重複排除）。
  const tokenByUid = new Map();

  // (a) フォロワー: follows where followeeId == 投稿者 → 各フォロワーがプレフON & トークンあり
  const followSnap = await db.collection("follows").where("followeeId", "==", posterId).get();
  const followerIds = followSnap.docs.map((d) => d.data().followerId).filter(Boolean);
  await Promise.all(
    followerIds.map(async (uid) => {
      if (uid === posterId || tokenByUid.has(uid)) return;
      const u = await getUser(uid);
      if (u && u.fcmToken && prefEnabled(u, "notifyNewPostsFromFollowing")) {
        tokenByUid.set(uid, u.fcmToken);
      }
    })
  );

  // (b) 全員: users where notifyNewPostsFromEveryone == true（欠落=false なので旧ユーザーは入らない）
  const everyoneSnap = await db
    .collection("users")
    .where("notifyNewPostsFromEveryone", "==", true)
    .get();
  everyoneSnap.docs.forEach((d) => {
    const uid = d.id;
    if (uid === posterId || tokenByUid.has(uid)) return;
    const u = d.data();
    if (u && u.fcmToken) tokenByUid.set(uid, u.fcmToken);
  });

  if (tokenByUid.size === 0) return;

  const uids = Array.from(tokenByUid.keys());
  const tokens = uids.map((uid) => tokenByUid.get(uid));
  const tokenToUid = {};
  uids.forEach((uid) => {
    tokenToUid[tokenByUid.get(uid)] = uid;
  });

  const notification = { title: "そらもよう", body: `${name}さんが新しい空を投稿しました` };
  const data = { type: "newPost", postId };

  // 500 件ずつ multicast（FCM の上限）。
  for (let i = 0; i < tokens.length; i += 500) {
    const batch = tokens.slice(i, i + 500);
    const resp = await messaging.sendEachForMulticast({
      tokens: batch,
      notification,
      data,
      apns: { payload: { aps: { sound: "default" } } },
    });
    await cleanupInvalidTokens(batch, tokenToUid, resp.responses);
  }
});
