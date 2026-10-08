//
// そらもよう Cloud Functions — 「そらとも」の配線（Callable 7本と onSoratomoSkyCreated）⭐️☁️
//
// - soratomoCreateGroup・soratomoJoinGroup・soratomoRegenerateInviteCode（tasks 8.1）:
//   ログインと soratomoBeta のクレームを確かめ、soratomoStore.js のトランザクションを呼び、
//   ドメインのエラー（SoratomoDomainError）を理由つきの HttpsError（code と details.reason）に写す。
//   グループ名の検証と招待コードの正規化は、トランザクション（soratomoStore.js）の入口でも必ず通る。
// - soratomoCreateSky・soratomoReportSky・soratomoAgreeGuideline（release-gate 4.2）: 投稿の作成・通報・
//   ガイドラインへの同意。作りは上の3本と同じ（クレームを確かめ、トランザクションを呼ぶ）。
// - soratomoDeleteMyData（release-gate 4.1）: 退会の前に、本人のそらとものデータを soratomoDeletion.js の
//   共通の削除で消す。クレームは確かめない（ログインは求める）。
// - onSoratomoSkyCreated（tasks 8.2）: グループの新しい投稿を、投稿者以外のメンバーへ知らせる。
//   既存の onPostCreated とは名前も対象（soratomoGroups/{groupId}/skies/{skyId}）も別。
// - onSoratomoReportCreated（release-gate 4.3）: 通報の記録を、開発者の Discord（フィードバックとは別の送り先）へ
//   ID・理由・時刻だけで送る。失敗は記録の状態で追い、例外を投げない。
//
// index.js の末尾の Object.assign(exports, require("./soratomo")) で公開する（tasks 8.3）。
// ここで公開するのは Cloud Functions の 9 本だけにする（ほかの値を exports に混ぜない）。
//
// ⚠️ ログと個人情報（要件15.2・15.3）: ログに出すのは uid・groupId・skyId・結果の理由・件数だけ。
//    グループ名・表示名・キャプション・招待コード・通知トークン・エラーの本文（文書のパスに招待コードが
//    含まれることがある）は出さない。
// ⚠️ テストは soratomo.test.js（Firestore のエミュレーター＋Auth・送信・ログの偽物）。
//

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const core = require("./soratomoCore");
const store = require("./soratomoStore");
const { createNgWordProvider } = require("./soratomoNgWords");
const { createStorageGateway } = require("./soratomoStorage");
const { deleteSoratomoUserData } = require("./soratomoDeletion");
const { sendToTokenGrouped } = require("./pushHelpers");

/** 既存の Functions と同じリージョン（index.js の setGlobalOptions と同じ値を明示する）。 */
const REGION = "asia-northeast1";

const db = getFirestore();

/** NGワードの語のリスト。関数のインスタンスごとに1つで、5分キャッシュする（release-gate 1.3・要件11.11）。 */
const ngWords = createNgWordProvider({ db });

/** 画像の削除に使う Storage のゲートウェイ。既定のバケットは、初めて使うときに取る（soratomoStorage.js）。 */
const storage = createStorageGateway();

// MARK: - Callable の共通部分

/** ドメインのエラーの理由 → HttpsError の code（design.md の API Contract）。ここに無い理由は internal になる。 */
const REASON_TO_CODE = Object.freeze({
  flag_off: "permission-denied",
  invalid_name: "invalid-argument",
  invalid_format: "invalid-argument",
  not_found: "not-found",
  group_full: "resource-exhausted",
  user_limit: "resource-exhausted",
  not_owner: "permission-denied",
  // release-gate（利用停止・同意・NGワード・投稿・通報）
  suspended: "permission-denied",
  consent_required: "failed-precondition",
  ng_word: "invalid-argument",
  invalid_input: "invalid-argument",
  not_member: "permission-denied",
  invalid_reason: "invalid-argument",
  sky_not_found: "not-found",
  self_report: "failed-precondition",
  outdated_guideline: "failed-precondition",
});

/**
 * ログイン（匿名を含む）と、requireFlag のときは soratomoBeta のクレームを確かめ、呼び出し元の uid を返す（要件1.6）。
 * @param {import("firebase-functions/v2/https").CallableRequest} request
 * @param {{ requireFlag: boolean }} options
 * @returns {string}
 */
function requireSoratomoUser(request, { requireFlag }) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "ログインが必要です");
  }
  if (requireFlag && (!request.auth.token || request.auth.token.soratomoBeta !== true)) {
    throw new HttpsError("permission-denied", "flag_off", { reason: "flag_off" });
  }
  return request.auth.uid;
}

/**
 * 失敗を HttpsError に写す。理由を持つドメインのエラーは code と details（reason と、エラーが持つ詳細）に、
 * それ以外は internal にする。詳細は利用者へ返してよいものだけ（いまは consent_required・outdated_guideline の
 * currentVersion。soratomoStore.SoratomoDomainError）。reason を後に置き、詳細が reason を持っていても上書きさせない。
 * @param {unknown} err
 * @returns {HttpsError}
 */
function toHttpsError(err) {
  if (err instanceof HttpsError) return err;
  if (err instanceof store.SoratomoDomainError && REASON_TO_CODE[err.reason]) {
    return new HttpsError(REASON_TO_CODE[err.reason], err.reason, { ...(err.details || {}), reason: err.reason });
  }
  return new HttpsError("internal", "internal");
}

/**
 * 拒否と想定外の失敗のログに添える、要求の groupId と skyId（自動IDの形のときだけ・design の Monitoring）。
 * 要求の値は利用者が自由に書けるので、形を確かめずに出すと、名前やキャプションをログに書かせられる（要件14.2）。
 * @param {Object} data 要求の本文
 * @returns {{ groupId?: string, skyId?: string }}
 */
function requestIdFields(data) {
  const fields = {};
  if (core.isAutoId(data.groupId)) fields.groupId = data.groupId;
  if (core.isAutoId(data.skyId)) fields.skyId = data.skyId;
  return fields;
}

/**
 * Callable の本体を包む: ログインとクレームの確認 → 本体 → 結果のログ。失敗は HttpsError に写して投げ直す。
 * @param {string} name ログに出す Callable の名前
 * @param {(uid: string, data: Object) => Promise<Object>} body
 * @param {{ requireFlag?: boolean, runtime?: Object, respond?: (result: Object) => Object,
 *   okLogFields?: (result: Object, data: Object) => Object }} [options]
 *   - requireFlag: soratomoBeta のクレームを確かめるか（既定 true）。false にしてよいのは退会の削除
 *     （soratomoDeleteMyData）だけ。フラグを取り消された人と、一度も ON になっていない人のデータも消すため（要件1.4）。
 *     false でもログイン（匿名を含む）は求める
 *   - runtime: onCall の設定（timeoutSeconds・memory など）。リージョンは REGION に固定する
 *   - respond: 本体の結果から、利用者へ返す応答を作る（既定はそのまま返す）
 *   - okLogFields: 成功のログに uid と一緒に出す項目（既定は groupId）。内部IDと件数だけにする（要件14.2・14.3）
 */
function soratomoCallable(name, body, options = {}) {
  const {
    requireFlag = true,
    runtime = {},
    respond = (result) => result,
    okLogFields = (result, data) => ({ groupId: result.groupId || data.groupId || null }),
  } = options;
  return onCall({ ...runtime, region: REGION }, async (request) => {
    let uid = null;
    const data = request.data && typeof request.data === "object" ? request.data : {};
    try {
      uid = requireSoratomoUser(request, { requireFlag });
      const result = await body(uid, data);
      logger.info(`${name}: ok`, { uid, ...okLogFields(result, data) });
      return respond(result);
    } catch (err) {
      const httpsError = toHttpsError(err);
      const reason = (httpsError.details && httpsError.details.reason) || httpsError.code;
      const fields = { uid, ...requestIdFields(data), reason };
      if (httpsError.code === "internal") {
        // 想定外の失敗。本文は出さない（文書のパスに招待コードが含まれることがあるため）。名前と code だけ。
        logger.error(`${name}: internal`, { ...fields, errorName: err && err.name, errorCode: err && err.code });
      } else {
        logger.info(`${name}: rejected`, fields);
      }
      throw httpsError;
    }
  });
}

// MARK: - Callable 3本（8.1）

/**
 * グループを作る。{ name, requestId } → { groupId, name, inviteCode, memberCount }
 * 方針として、現行のガイドラインの版と語のリストの判定を渡す（release-gate 2.1）。語のリストが一度も読めていなければ
 * matcher() が失敗し、internal で止まる（検査を飛ばさない・要件11.5）。
 */
const soratomoCreateGroup = soratomoCallable("soratomoCreateGroup", async (uid, data) =>
  store.createGroupTx(db, {
    uid,
    name: data.name,
    requestId: data.requestId,
    policy: { guidelineVersion: core.GUIDELINE_VERSION, containsNgWord: await ngWords.matcher() },
  })
);

/**
 * 招待コードで参加する。{ code } → { groupId, alreadyMember }
 * 方針は現行のガイドラインの版だけ（参加は NGワードを検査しないので、語のリストが読めなくても止めない）。
 */
const soratomoJoinGroup = soratomoCallable("soratomoJoinGroup", (uid, data) =>
  store.joinGroupTx(db, { uid, code: data.code, policy: { guidelineVersion: core.GUIDELINE_VERSION } })
);

/** 招待コードを再発行する（オーナーだけ）。{ groupId } → { inviteCode } */
const soratomoRegenerateInviteCode = soratomoCallable("soratomoRegenerateInviteCode", (uid, data) =>
  store.regenerateInviteCodeTx(db, { uid, groupId: data.groupId })
);

// MARK: - 投稿・通報・同意（release-gate 4.2）

/**
 * そらとも投稿の文書を作る。{ groupId, skyId, caption?, width, height } → { skyId, created }
 * - 判定の順: 入力の検査 → 語のリストの取得 → トランザクション（利用停止→メンバー→既存の文書→NGワード→作成・
 *   soratomoStore.createSkyTx）。入力を先に確かめるので、語のリストが読めないときも入力の誤りは invalid_input になる
 * - 語のリストが一度も読めていなければ matcher() が失敗し、internal で止まる（検査を飛ばさない・要件11.5）
 * - 同じ投稿IDの送り直しは created: false の成功（通信の失敗でアプリが送り直しても1件で済む）
 * - 同意は確かめない（決定事項14）。利用停止はトランザクションの中で確かめる（要件8.6）
 */
const soratomoCreateSky = soratomoCallable(
  "soratomoCreateSky",
  async (uid, data) => {
    if (!core.validateSkyInput(data).ok) throw new store.SoratomoDomainError("invalid_input");
    return store.createSkyTx(db, { uid, input: data, policy: { containsNgWord: await ngWords.matcher() } });
  },
  { okLogFields: (result, data) => ({ groupId: data.groupId, skyId: result.skyId, created: result.created }) }
);

/**
 * そらとも投稿を通報する。{ groupId, skyId, reason } → { accepted: true }
 * - 通報者は認証の uid（要件6.2）。投稿者は投稿の文書から取る（要件6.8・soratomoStore.reportSkyTx）
 * - 同じ人の同じ投稿への2回目も同じ応答にする（要件6.7）。記録のIDと重複かどうかは、利用者へ返さずログにだけ出す
 * - 通報者・投稿者・ほかのメンバーには何も送らない（要件5.9）。開発者への転送は記録の作成のトリガーが行う
 */
const soratomoReportSky = soratomoCallable("soratomoReportSky", (uid, data) => store.reportSkyTx(db, { uid, input: data }), {
  respond: (result) => ({ accepted: result.accepted }),
  okLogFields: (result) => ({ reportId: result.reportId, duplicate: result.duplicate }),
});

/**
 * 現行の版のガイドラインへの同意を記録する。{ version } → { version }
 * 現行と違う版は outdated_guideline（details に現行の版）。記録するのは認証の uid の文書だけ（要件10.6・10.9・10.14）。
 */
const soratomoAgreeGuideline = soratomoCallable(
  "soratomoAgreeGuideline",
  (uid, data) => store.agreeGuidelineTx(db, { uid, input: data, policy: { guidelineVersion: core.GUIDELINE_VERSION } }),
  { okLogFields: (result) => ({ version: result.version }) }
);

// MARK: - 退会の削除（release-gate 4.1）

/** 退会の削除の1回の予算（ミリ秒）。関数の制限時間（120秒）より短くし、残りで件数のログと応答を返す（design）。 */
const DELETE_BUDGET_MS = 45_000;

/**
 * 本人のそらとものデータを消す。{} → { done }（アプリは退会の前に、done が true になるまで呼ぶ）。
 * - 機能フラグのクレームを確かめない（requireFlag: false）。フラグを取り消された人と、一度も ON になっていない人
 *   （匿名を含む）のデータも消すため（要件1.4）。そらともを使っていない人は、何も書かずに done: true（要件3.8）
 * - 消す相手は認証の uid だけ。要求の本文は読まない（uid を書かれても使わない・要件3.5）
 * - 1回の予算は45秒。終わらなければ done: false を返す。所属の写しが残るので、次の呼び出しが続ける（要件3.3）
 * - 応答は done だけ。件数は利用者へ返さず、ログに内部IDと件数だけで残す（要件14.3・14.4・design の Monitoring）
 * - 停止中の人の利用者の文書は消さずに残る（soratomoDeletion.finishUserTx）。アカウントを消した後に定期実行が消す
 */
const soratomoDeleteMyData = soratomoCallable(
  "soratomoDeleteMyData",
  (uid) =>
    deleteSoratomoUserData(
      { db, storage, nowMs: Date.now },
      { uid, trigger: "self", deadlineMs: Date.now() + DELETE_BUDGET_MS }
    ),
  {
    // クレームを確かめない理由: フラグを取り消された人・一度も ON になっていない人のデータも消すため（要件1.4）
    requireFlag: false,
    runtime: { timeoutSeconds: 120, memory: "512MiB" },
    respond: (totals) => ({ done: totals.done }),
    okLogFields: (totals) => ({
      done: totals.done,
      skiesDeleted: totals.skiesDeleted,
      imagesDeleted: totals.imagesDeleted,
      groupsLeft: totals.groupsLeft,
      ownersTransferred: totals.ownersTransferred,
      groupsDeleted: totals.groupsDeleted,
    }),
  }
);

// MARK: - 新着投稿の通知（8.2）

/**
 * 宛先の soratomoBeta のクレームを、getUsers でまとめて1回で確かめる（要件1.7）。
 * 失敗したら全員を「フラグOFF」とみなす（送らない側に倒す。集計の flagOff に出る）。
 * @param {string[]} uids 最大19人（メンバーの上限20人から投稿者を除く）
 * @returns {Promise<Set<string>>} クレームが true の uid
 */
async function fetchFlaggedUids(uids) {
  const flagged = new Set();
  if (uids.length === 0) return flagged;
  try {
    const { users } = await getAuth().getUsers(uids.map((uid) => ({ uid })));
    for (const user of users) {
      if (user.customClaims && user.customClaims.soratomoBeta === true) flagged.add(user.uid);
    }
  } catch (err) {
    logger.warn("onSoratomoSkyCreated: フラグの確認に失敗", { errorName: err && err.name, errorCode: err && err.code });
  }
  return flagged;
}

/**
 * Firestore の時刻をミリ秒で読む（Timestamp 以外は null）。
 * @param {unknown} value
 * @returns {number|null}
 */
function millisOf(value) {
  return value && typeof value.toMillis === "function" ? value.toMillis() : null;
}

/**
 * グループの最新の活動時刻を、投稿の作成日時との大きいほうにする（要件5.3・一覧の並び順）。
 * 同時の投稿で古い値に戻さないよう、トランザクションで読んで比べてから書く。
 */
async function bumpLastActivity(groupRef, createdAt) {
  const createdMs = millisOf(createdAt);
  if (createdMs === null) return;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(groupRef);
    if (!snap.exists) return;
    const currentMs = millisOf(snap.get("lastActivityAt"));
    if (currentMs === null || currentMs < createdMs) tx.update(groupRef, { lastActivityAt: createdAt });
  });
}

/**
 * 新しいそらとも投稿を、投稿者以外のメンバーへ知らせる（要件9.1〜9.15）。
 * 分類の順は「フラグOFF→通知設定OFF→ブロック→トークン無し→（枠の確保で）重複か間引き→送信」。
 * 1人の失敗で残りを止めず、例外を投げずに終える（再試行で二重に送らないため）。投稿は消さない。
 * @param {{ params: { groupId: string, skyId: string }, data?: FirebaseFirestore.DocumentSnapshot }} event
 */
async function handleSoratomoSkyCreated(event) {
  const { groupId, skyId } = event.params;
  const sky = event.data ? event.data.data() : null;
  if (!sky) return;

  const groupRef = db.collection("soratomoGroups").doc(groupId);
  try {
    const posterId = typeof sky.authorId === "string" ? sky.authorId : "";
    const [groupSnap, membersSnap] = await Promise.all([groupRef.get(), groupRef.collection("members").get()]);
    if (!groupSnap.exists) {
      logger.warn("onSoratomoSkyCreated: グループが無い", { groupId, skyId });
      return;
    }

    const recipientIds = membersSnap.docs.map((doc) => doc.id).filter((uid) => uid !== posterId);
    const posterSnap = posterId ? await db.collection("users").doc(posterId).get() : null;
    const notification = core.buildNotification({
      groupName: groupSnap.get("name"),
      posterName: posterSnap && posterSnap.exists ? posterSnap.get("displayName") : null,
      caption: sky.caption,
    });
    const flagged = await fetchFlaggedUids(recipientIds);
    const userSnaps =
      recipientIds.length > 0 ? await db.getAll(...recipientIds.map((uid) => db.collection("users").doc(uid))) : [];

    // FCM の data の値はすべて文字列
    const data = { type: "soratomoPost", groupId, postId: skyId };
    const grouping = { threadId: `soratomo-${groupId}`, collapseId: `soratomo-${groupId}` };
    const nowMs = Date.now();

    const outcomes = await Promise.all(
      recipientIds.map(async (uid, i) => {
        try {
          const userData = userSnaps[i].exists ? userSnaps[i].data() : null;
          const kind = core.classifyRecipient({ hasFlag: flagged.has(uid), userData, posterId });
          if (kind !== "eligible") return kind;
          const slot = await store.claimNotifySlot(db, { groupId, uid, skyId, nowMs });
          if (slot !== "send") return slot;
          return await sendToTokenGrouped(uid, userData.fcmToken, notification, data, grouping);
        } catch (err) {
          logger.warn("onSoratomoSkyCreated: 宛先1人の処理に失敗", {
            groupId,
            skyId,
            uid,
            errorName: err && err.name,
            errorCode: err && err.code,
          });
          return "failed";
        }
      })
    );

    // 投稿1件ごとの集計（IDと件数だけ・要件9.11）
    logger.info("onSoratomoSkyCreated: summary", core.summarizeNotifyOutcomes(groupId, skyId, outcomes));
  } catch (err) {
    logger.error("onSoratomoSkyCreated: 失敗", { groupId, skyId, errorName: err && err.name, errorCode: err && err.code });
  } finally {
    // 通知の準備（投稿者・宛先の読み取りなど）のどこで失敗しても、一覧の並び順（要件5.3）のために必ず更新する。
    // 最新の活動時刻を書くのはこのトリガーだけなので、ここで飛ばすと次の投稿まで古いままになる（レビューで直した）。
    // グループが無いときは bumpLastActivity の中で何もしない。
    try {
      await bumpLastActivity(groupRef, sky.createdAt);
    } catch (err) {
      logger.warn("onSoratomoSkyCreated: 最新の活動時刻の更新に失敗", { groupId, skyId, errorName: err && err.name });
    }
  }
}

const onSoratomoSkyCreated = onDocumentCreated(
  { document: "soratomoGroups/{groupId}/skies/{skyId}", region: REGION },
  handleSoratomoSkyCreated
);

// MARK: - 通報の転送（release-gate 4.3）

/**
 * 通報の送り先（Discord の Webhook URL）。フィードバックの送り先（index.js の DISCORD_WEBHOOK_URL）とは別の秘密の値。
 * 値は `firebase functions:secrets:set DISCORD_REPORT_WEBHOOK_URL` の対話の入力で設定し、リポジトリとログに置かない（要件7.6）。
 */
const DISCORD_REPORT_WEBHOOK_URL = defineSecret("DISCORD_REPORT_WEBHOOK_URL");

/**
 * 本文を Webhook へ POST し、結果を返す。成功は "ok"、HTTP の失敗はその状態（数値）、送り先が無い・通信の失敗は種類の文字列。
 * 応答の本文とエラーの本文は読まずに捨てる（エラーの本文には送り先の URL が入ることがある）。
 * @param {string} webhookUrl
 * @param {Object} payload
 * @returns {Promise<"ok"|number|"not_configured"|"fetch_failed">}
 */
async function postToWebhook(webhookUrl, payload) {
  if (typeof webhookUrl !== "string" || webhookUrl === "") return "not_configured";
  try {
    const res = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    return res.ok ? "ok" : res.status;
  } catch (_err) {
    return "fetch_failed";
  }
}

/**
 * 通報の記録を1件、開発者の Discord へ送り、記録の転送の状態を書く（要件7.1〜7.4・7.6）。
 * トリガー（作成のとき）と定期実行（送り直し・tasks 4.4）の両方から呼ぶ。
 * - 記録をいま読み直し、無い・送信済みなら送らない。作成のイベントの再配信（スナップショットは未送信のまま届く）と、
 *   送り直しが重なっても二重に送らないため。送った後で状態の書き込みに失敗したときだけ、次の送り直しで二重になりうる
 *   （内容が ID だけなので受け入れる・design の Event Contract）
 * - 本文は soratomoCore.buildReportForwardPayload（ID・理由・時刻だけ。キャプション・名前・コード・画像は載せない）
 * - 成功: 送信済みと送信日時を書く。失敗: 失敗の回数を1増やし、error のログに記録のIDと状態だけを出す
 * - 例外は投げない（送り直しは定期実行が行う）。記録の読み書きの失敗も、名前と code だけをログに出して終える
 * @param {FirebaseFirestore.DocumentReference} reportRef
 * @param {string} webhookUrl
 * @returns {Promise<"sent"|"skipped"|"failed">}
 */
async function forwardReport(reportRef, webhookUrl) {
  const reportId = reportRef.id;
  try {
    const snap = await reportRef.get();
    if (!snap.exists || snap.get("forwardStatus") === "sent") return "skipped";
    const status = await postToWebhook(webhookUrl, core.buildReportForwardPayload({ ...snap.data(), reportId }));
    if (status === "ok") {
      await reportRef.update({ forwardStatus: "sent", forwardedAt: FieldValue.serverTimestamp() });
      logger.info("soratomoReport: forwarded", { reportId });
      return "sent";
    }
    logger.error("soratomoReport: forward_failed", { reportId, status });
    await reportRef.update({ forwardAttempts: FieldValue.increment(1) });
    return "failed";
  } catch (err) {
    logger.error("soratomoReport: forward_failed", {
      reportId,
      status: "store_failed",
      errorName: err && err.name,
      errorCode: err && err.code,
    });
    return "failed";
  }
}

/** 通報の記録の作成で、開発者の Discord へ送る（要件7.1・7.3）。失敗しても例外を投げない（forwardReport）。 */
const onSoratomoReportCreated = onDocumentCreated(
  { document: "soratomoReports/{reportId}", region: REGION, secrets: [DISCORD_REPORT_WEBHOOK_URL] },
  async (event) => {
    if (!event.data) return;
    await forwardReport(event.data.ref, DISCORD_REPORT_WEBHOOK_URL.value());
  }
);

module.exports = {
  soratomoCreateGroup,
  soratomoJoinGroup,
  soratomoRegenerateInviteCode,
  soratomoCreateSky,
  soratomoReportSky,
  soratomoAgreeGuideline,
  soratomoDeleteMyData,
  onSoratomoSkyCreated,
  onSoratomoReportCreated,
};
