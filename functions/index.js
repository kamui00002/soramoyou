//
// そらもよう Cloud Functions（プッシュ通知の送信側）
//
// トリガー（Firestore ドキュメント作成 / 削除）:
//   - onLikeCreated           likes/{likeId}      → 投稿者へ「いいねされました」
//   - onCommentCreated        comments/{commentId}→ 投稿者へ「コメントされました」
//   - onPostCreated           posts/{postId}      → フォロワー / 全員（オプトイン）へ「新しい空」
//   - onFollowCreated         follows/{followId}  → フォローカウンタを整合 ＋ 相手へ「フォローされました」
//   - onFollowDeleted         follows/{followId}  → フォローカウンタを整合（通知はしない）
//   - notifyFeedbackToDiscord feedback/{id}       → 開発者の Discord へ「ご意見・ご要望が届いた」（Webhook）
//
// 設計メモ:
//   - 配信プレフは users/{uid} の notifyReactions / notifyNewPostsFromFollowing /
//     notifyNewPostsFromEveryone を読む。フィールド欠落（旧ユーザー）は PREF_DEFAULTS で補う。
//     ⚠️ この既定は iOS の User.swift と必ず一致させること（reactions=true / following=true / everyone=false）。
//   - 自分自身の操作（自分の投稿への自いいね等）は通知しない。
//   - 送信トークンが無い（未登録/未許可）ユーザーはスキップ。
//   - 無効トークン（registration-token-not-registered 等）は users/{uid}.fcmToken を掃除する。
//   - 新規投稿の配信は重複排除のうえ 500 件ずつ multicast。
//   - フォローカウンタは follows を「数え直して代入」する（±1 の increment ではない）。冪等なので
//     再実行しても壊れず、旧バージョンのアプリがクライアント側で ±1 しても真値で上書きされる。
//     ＝二重計上が原理的に起きないため、アプリ配信を待たずにこの Functions だけ先行デプロイできる。
//
// ⚠️ デプロイ前提:
//   1. Firebase を Blaze プランにする（Cloud Functions は無料 Spark 不可）。
//   2. Cloud Functions API を有効化（初回 deploy で案内される）。
//   3. REGION は Firestore データベースと同一リージョンにすること（不一致だと deploy で失敗する）。
//

const { setGlobalOptions } = require("firebase-functions/v2");
const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
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

/** userData が otherId をブロックしているか（ブロック相手の通知をプッシュで再浮上させない）。 */
function isBlocked(userData, otherId) {
  return !!(userData && Array.isArray(userData.blockedUserIds) && userData.blockedUserIds.includes(otherId));
}

// 送信・無効トークン掃除の実体は pushHelpers.js に集約（skyMotion.js と共有）。
const { isInvalidTokenError, sendToToken } = require("./pushHelpers");

/** 単一ユーザーへ送る（リアクション通知用）。無効トークンは掃除する。 */
async function sendToUser(uid, userData, notification, data) {
  await sendToToken(uid, userData && userData.fcmToken, notification, data);
}

/** multicast の失敗レスポンスから無効トークンを掃除する。 */
async function cleanupInvalidTokens(tokens, tokenToUid, responses) {
  const removals = [];
  responses.forEach((resp, i) => {
    if (!resp.success && isInvalidTokenError(resp.error && resp.error.code)) {
      const uid = tokenToUid[tokens[i]];
      if (uid) {
        removals.push(
          db.collection("users").doc(uid).update({ fcmToken: FieldValue.delete() })
            .catch((e) => logger.warn("fcmToken cleanup failed", { uid, code: String(e && e.code) }))
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
  // 投稿者が いいねした人 をブロックしているなら通知しない。
  if (isBlocked(owner, likerId)) return;

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
  // 投稿者が コメントした人 をブロックしているなら通知しない。
  if (isBlocked(owner, commenterId)) return;

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

  // 公開範囲を尊重する。private は誰にも通知しない（受信者は本来その投稿を開けない＝漏洩）。
  // followers はフォロワー枝のみ（読める相手）に送り、全員枝（非フォロワー）はスキップ。
  // public のみ全員枝も対象。visibility 欠落は public 扱い。
  const visibility = post.visibility || "public";
  if (visibility === "private") return;
  const allowEveryone = visibility === "public";

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
      // 投稿者をブロックしている受信者には送らない。
      if (u && u.fcmToken && prefEnabled(u, "notifyNewPostsFromFollowing") && !isBlocked(u, posterId)) {
        tokenByUid.set(uid, u.fcmToken);
      }
    })
  );

  // (b) 全員: public 投稿のみ。users where notifyNewPostsFromEveryone == true（欠落=false で旧ユーザーは入らない）
  if (allowEveryone) {
    const everyoneSnap = await db
      .collection("users")
      .where("notifyNewPostsFromEveryone", "==", true)
      .get();
    everyoneSnap.docs.forEach((d) => {
      const uid = d.id;
      if (uid === posterId || tokenByUid.has(uid)) return;
      const u = d.data();
      // 投稿者をブロックしている受信者には送らない。
      if (u && u.fcmToken && !isBlocked(u, posterId)) tokenByUid.set(uid, u.fcmToken);
    });
  }

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

// MARK: - フォローカウンタの整合 ＋ 新規フォロー通知

/**
 * 指定ユーザーのフォロー系カウンタを follows から数え直して users / publicProfiles へ代入する。
 *
 * ■ なぜ FieldValue.increment ではなく「数え直して代入」なのか
 *   1. 冪等: Functions が再実行（リトライ・重複配信）されても結果が同じ。
 *   2. 先行デプロイ可能: 旧バージョンのアプリはクライアント側トランザクションで ±1 し続けるが、
 *      その直後にこの関数が真値で上書きするため二重計上が原理的に起きない。
 *      ＝ アプリの配信を待たずに Functions だけ先にデプロイしてバグを止められる。
 *   3. 過去のズレも「その uid に次のイベントが来たとき」に自己修復する（±1 方式は一度
 *      ズレると永久に直らない）。逆に言えばイベントが来ない限り直らないので、
 *      まとめて直すときは scripts/backfill-follow-counters.js を使う。
 *   4. フォロー解除（follows の削除）でも同じ経路を通るので、増減で別実装を持たなくて済む。
 *
 * ■ なぜ publicProfiles にも書くのか
 *   他人のプロフィール画面（UserProfileView）が読むのは publicProfiles 側で、
 *   firestore.rules は publicProfiles の update を所有者のみに限定している。
 *   つまり「相手のフォロワー数」はクライアントからは原理的に書けない＝サーバーでしか直せない。
 *
 * ⚠️ ドキュメントが存在しないユーザーには書かない（users / publicProfiles とも）。
 *    カウンタだけの器を作ると、表示名やアイコンが永久に空のまま固定された
 *    「幽霊プロフィール」が残り、iOS 側の Codable デコードも失敗する。
 *    退会直後の follows 削除で実際にこの経路に入りうる。
 *
 * ⚠️ 冪等ではあるがレースフリーではない。同一ユーザーに対する 2 つのイベントが同時に走ると
 *    双方が同じ count() を読んで同じ値を書き、一時的に 1 件少ない値で止まることがある。
 *    次のフォロー/解除イベントで自動的に直り、手動修復は scripts/backfill-follow-counters.js。
 *    この規模のトラフィックでロック/リトライを足すのは割に合わないため、あえて許容する。
 *
 * @param {string[]} userIds カウンタを直したいユーザー ID（重複・空値は内部で除去する）
 */
async function reconcileFollowCounters(userIds) {
  // フォロー操作は必ず 2 人（follower / followee）が絡むが、自分自身をフォローする等で
  // 同じ ID が 2 回来る可能性があるため重複を除く。
  const uniqueIds = Array.from(new Set((userIds || []).filter(Boolean)));

  for (const uid of uniqueIds) {
    // 1 人失敗しても他のユーザーの修復を止めない（全滅より部分成功のほうが望ましい）。
    try {
      // count() は集計クエリ。ドキュメント本体を読まないので、フォロワーが増えても課金・遅延が伸びにくい。
      const [followersAgg, followingAgg] = await Promise.all([
        db.collection("follows").where("followeeId", "==", uid).count().get(),
        db.collection("follows").where("followerId", "==", uid).count().get(),
      ]);
      const counters = {
        followersCount: followersAgg.data().count, // この人をフォローしている人数
        followingCount: followingAgg.data().count, // この人がフォローしている人数
      };

      const userRef = db.collection("users").doc(uid);
      const publicRef = db.collection("publicProfiles").doc(uid);
      const [userSnap, publicSnap] = await Promise.all([userRef.get(), publicRef.get()]);

      // 存在確認してから書く。set(..., { merge: true }) は存在しなければ「作ってしまう」ため、
      // 退会済みユーザーに対してカウンタだけの不完全なドキュメントを新規作成しないよう防ぐ。
      if (userSnap.exists) {
        await userRef.set(counters, { merge: true });
      } else {
        logger.warn("users が存在しないためカウンタ更新をスキップ", { uid });
      }
      if (publicSnap.exists) {
        await publicRef.set(counters, { merge: true });
      } else {
        // 移行未実施ユーザー（publicProfiles 未作成）もここに来る。作らずに記録だけ残す。
        logger.warn("publicProfiles が存在しないためカウンタ更新をスキップ", { uid });
      }
    } catch (err) {
      // ⚠️ リトライは設定していないため、一過性の障害（Firestore の瞬断など）でここに来ると、
      //    この uid のカウンタは「次のフォロー/解除イベントが来る」か
      //    「scripts/backfill-follow-counters.js を手動実行する」まで ズレたままになる。
      //    このログを見つけたら、どちらかで整合を取り直すこと。
      logger.error("フォローカウンタの整合に失敗", { uid, error: err.message });
    }
  }
}

/**
 * フォローされた人へ「フォローされました」を通知する。
 *
 * 配信プレフは既存の notifyReactions を流用する。
 * ⚠️ ここで新しいプレフを足さないこと。PREF_DEFAULTS（このファイル上部）と
 *    iOS の Models/User.swift は「必ず一致させる」ことを両側のコメントで約束しており、
 *    プレフを増やすと二重管理の対象がもう 1 つ増える。
 *
 * @param {string} followerId フォローした人
 * @param {string} followeeId フォローされた人（通知の宛先）
 */
async function notifyNewFollower(followerId, followeeId) {
  // 自分自身へのフォローは通知しない（いいね・コメントと同じ方針）。
  if (!followerId || !followeeId || followerId === followeeId) return;

  const followee = await getUser(followeeId);
  if (!followee || !followee.fcmToken || !prefEnabled(followee, "notifyReactions")) return;
  // フォローされた側が相手をブロックしているなら、プッシュで再浮上させない。
  if (isBlocked(followee, followerId)) return;

  const follower = await getUser(followerId);
  await sendToUser(
    followeeId,
    followee,
    { title: "そらもよう", body: `${displayNameOf(follower)}さんがあなたをフォローしました` },
    // data の値は文字列必須（FCM の制約）。この通知に postId は無い。
    // rules で followerId は uid 文字列に固定されているが、万一の型崩れで送信全体が
    // 失敗しないよう String() で通す。
    { type: "follow", followerId: String(followerId) }
  );
}

exports.onFollowCreated = onDocumentCreated("follows/{followId}", async (event) => {
  const follow = event.data && event.data.data();
  if (!follow) return;
  const followerId = follow.followerId;
  const followeeId = follow.followeeId;
  if (!followerId || !followeeId) return;

  // カウンタ整合を先に行う。通知は「送れたら嬉しい」おまけで、数字の正しさのほうが優先度が高い。
  await reconcileFollowCounters([followerId, followeeId]);
  await notifyNewFollower(followerId, followeeId);
});

exports.onFollowDeleted = onDocumentDeleted("follows/{followId}", async (event) => {
  // 削除トリガーの event.data は「削除される直前のスナップショット」。
  const follow = event.data && event.data.data();
  if (!follow) return;
  const followerId = follow.followerId;
  const followeeId = follow.followeeId;
  if (!followerId || !followeeId) return;

  // フォロー解除は通知しない（される側にとって嬉しい知らせではない）。カウンタだけ直す。
  await reconcileFollowCounters([followerId, followeeId]);
});

// MARK: - フィードバック → Discord 通知（開発者向け）
//
// アプリ内「ご意見・ご要望」が feedback コレクションに作成されたら、開発者の Discord へ即時通知する。
// Webhook URL は Secret Manager に格納し、コード/リポジトリには実値を絶対に置かない（漏洩防止）。
//   セットアップ: `firebase functions:secrets:set DISCORD_WEBHOOK_URL`（対話で値を入力）
// region は setGlobalOptions（asia-northeast1）を継承するため、ここでは secrets のみ指定する。

const DISCORD_WEBHOOK_URL = defineSecret("DISCORD_WEBHOOK_URL");

// 種別 rawValue → 日本語表示名（iOS 側 FeedbackCategory と対応）。
const FEEDBACK_CATEGORY_LABELS = {
  bug: "不具合 🐛",
  request: "要望 ✨",
  other: "その他 💬",
};

exports.notifyFeedbackToDiscord = onDocumentCreated(
  { document: "feedback/{feedbackId}", secrets: [DISCORD_WEBHOOK_URL] },
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      logger.warn("フィードバックのスナップショットが空でした");
      return;
    }

    const data = snapshot.data() || {};
    const feedbackId = event.params.feedbackId;

    // 各フィールドを取り出す（任意項目は未設定なら代替表記）。message は rules で 1〜1000 文字保証済み。
    const message = (data.message || "(本文なし)").toString();
    const categoryRaw = data.category ? data.category.toString() : null;
    const category = categoryRaw
      ? FEEDBACK_CATEGORY_LABELS[categoryRaw] || categoryRaw
      : "未指定";
    const appVersion = data.appVersion ? data.appVersion.toString() : "不明";
    const deviceInfo = data.deviceInfo ? data.deviceInfo.toString() : "不明";
    const userId = data.userId ? data.userId.toString() : "不明";

    // createdAt（serverTimestamp）を ISO 文字列へ。未到達でも落ちないようにする。
    let timestamp;
    try {
      timestamp =
        data.createdAt && typeof data.createdAt.toDate === "function"
          ? data.createdAt.toDate().toISOString()
          : new Date().toISOString();
    } catch (_e) {
      timestamp = new Date().toISOString();
    }

    // Discord Embed を組み立てる。field.value は最大 1024 文字なので本文は 1000 文字に丸める。
    const payload = {
      username: "そらもよう フィードバック",
      embeds: [
        {
          title: "📮 新しいご意見・ご要望が届きました",
          color: 0x4a90d9, // そらもようの空色
          fields: [
            { name: "種別", value: category, inline: true },
            { name: "アプリ", value: appVersion, inline: true },
            { name: "端末", value: deviceInfo, inline: true },
            { name: "本文", value: message.slice(0, 1000) },
            { name: "ユーザーID", value: userId, inline: false },
          ],
          footer: { text: `feedbackId: ${feedbackId}` },
          timestamp,
        },
      ],
    };

    // Node 20 はグローバル fetch が使えるため外部 HTTP ライブラリ不要。
    const webhookUrl = DISCORD_WEBHOOK_URL.value();
    try {
      const res = await fetch(webhookUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      if (!res.ok) {
        const body = await res.text();
        logger.error("Discord 通知に失敗しました", { status: res.status, body, feedbackId });
        // throw でエラーをメトリクスに可視化（既定ではリトライされない）。
        throw new Error(`Discord webhook responded ${res.status}`);
      }
      logger.info("Discord 通知に成功しました", { feedbackId });
    } catch (err) {
      logger.error("Discord 通知中に例外が発生しました", { feedbackId, error: err.message });
      throw err;
    }
  }
);

// MARK: - 「空を動かす」β（フェーズ1a・DEBUG限定E2E検証用。詳細は functions/skyMotion.js）
Object.assign(exports, require("./skyMotion"));

// MARK: - 「空を動かす」回数パック（消費型IAP）の購入検証。詳細は functions/skyMotionPurchase.js
exports.onSkyMotionPurchaseCreated = require("./skyMotionPurchase").onSkyMotionPurchaseCreated;
// pending詰まりのリコンサイラ（⚠️ Object.assign配線ではないため個別exportが必須。忘れるとdeployされない）
exports.reconcilePendingSkyMotionPurchases =
  require("./skyMotionPurchase").reconcilePendingSkyMotionPurchases;
