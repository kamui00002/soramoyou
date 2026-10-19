//
// そらもよう Cloud Functions — 「そらとも」の配線（Callable 9本・トリガー3本・定期実行1本）⭐️☁️
//
// - soratomoCreateGroup・soratomoJoinGroup・soratomoRegenerateInviteCode（tasks 8.1）:
//   ログインと、登録済みのアカウント（匿名でない）かを確かめ、soratomoStore.js のトランザクションを呼び、
//   ドメインのエラー（SoratomoDomainError）を理由つきの HttpsError（code と details.reason）に写す。
//   グループ名の検証と招待コードの正規化は、トランザクション（soratomoStore.js）の入口でも必ず通る。
// - soratomoCreateSky・soratomoReportSky・soratomoAgreeGuideline（release-gate 4.2）: 投稿の作成・通報・
//   ガイドラインへの同意。作りは上の3本と同じ（登録済みかを確かめ、トランザクションを呼ぶ）。
// - soratomoDeleteMyData（release-gate 4.1）: 退会の前に、本人のそらとものデータを soratomoDeletion.js の
//   共通の削除で消す。匿名も受け付ける（ログインは求める）。
// - soratomoLeaveGroup（leave-group 3.1）: 本人が1つのグループだけを抜ける。soratomoDeletion.js の
//   leaveSoratomoGroup（片づけ中の印つき）で、そのグループの本人のデータを消す。関門はほかの Callable と同じ（匿名は拒否）。
// - soratomoSetReaction（soratomo-reactions 3.1）: 本人のリアクションを付ける・選び直す・外す（soratomoStore.js の
//   setReactionTx）。新しく付いたときだけ、投稿者へ通知する（notifyReaction）。関門はほかの Callable と同じ（匿名は拒否）。
// - onSoratomoSkyCreated（tasks 8.2）: グループの新しい投稿を、投稿者以外のメンバーへ知らせる。
//   既存の onPostCreated とは名前も対象（soratomoGroups/{groupId}/skies/{skyId}）も別。
// - onSoratomoSkyDeleted（soratomo-reactions 3.2）: 投稿が消えたら、その投稿の送った印（reactionNotices/{skyId}）を消し、
//   投稿と一緒に消えたリアクションの数をログに残す。削除の経路（アプリ・抜ける・退会・運用）とアプリの版に依らない。
// - onSoratomoReportCreated（release-gate 4.3）: 通報の記録を、開発者の Discord（フィードバックとは別の送り先）へ
//   ID・理由・時刻だけで送る。失敗は記録の状態で追い、例外を投げない。
// - soratomoHousekeeping（release-gate 4.4）: 6時間ごとの定期実行。仕事A＝Auth のアカウントが無い人のデータを
//   共通の削除で消す。仕事B＝転送に失敗した通報を送り直す。仕事C（leave-group 3.2・仕事Aより先）＝途中で止まった
//   抜けるを、片づけ中の印（soratomoPendingLeaves）から続けて終える。
//
// index.js の末尾の Object.assign(exports, require("./soratomo")) で公開する（tasks 8.3）。
// ここで公開するのは Cloud Functions の 13 本だけにする（ほかの値を exports に混ぜない）。
//
// ⚠️ 関門（1.15.0 の一般公開・public-launch 3.2）: Callable はログインと「登録済みのアカウント（匿名でない）」を求め、
//    先行公開のクレームは読まない。匿名を通すのは退会の削除だけ（allowAnonymous）。ルールの isSoratomoUser() と
//    アプリの SoratomoFeatureGate と同じ条件にしておく（3か所を同時に変える）。新着通知の宛先もクレームで絞らない。
// ⚠️ ログと個人情報（要件15.2・15.3）: ログに出すのは uid・groupId・skyId・結果の理由・件数だけ。
//    グループ名・表示名・キャプション・招待コード・通知トークン・エラーの本文（文書のパスに招待コードが
//    含まれることがある）は出さない。
// ⚠️ テストは soratomo.test.js（Firestore のエミュレーター＋Auth・送信・ログの偽物）。
//

"use strict";

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getAuth } = require("firebase-admin/auth");
const core = require("./soratomoCore");
const store = require("./soratomoStore");
const { createNgWordProvider } = require("./soratomoNgWords");
const { createStorageGateway } = require("./soratomoStorage");
const { deleteSoratomoUserData, leaveSoratomoGroup, PENDING_LEAVES, isUid } = require("./soratomoDeletion");
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
  // public-launch（関門: 匿名・ログインの方式が読めないトークン）
  registration_required: "permission-denied",
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
  // leave-group（抜けるか退会の片づけ中の参加）
  leave_pending: "failed-precondition",
  // soratomo-reactions（自分の投稿へのリアクション・7種類にない絵文字）
  self_reaction: "failed-precondition",
  invalid_reaction: "invalid-argument",
});

/**
 * ログインと、allowAnonymous でなければ登録済みのアカウント（匿名でない）かを確かめ、呼び出し元の uid を返す
 * （public-launch 要件1.6・1.7）。先行公開のクレームは読まない（1.14.x のクレームのある人は、登録済みなのでそのまま通る）。
 * - 未ログイン → unauthenticated（今までどおり）
 * - allowAnonymous が true でなく、isRegisteredToken が偽（匿名・方式の読めないトークン）→ permission-denied・registration_required
 * @param {import("firebase-functions/v2/https").CallableRequest} request
 * @param {{ allowAnonymous: boolean }} options
 * @returns {string}
 */
function requireSoratomoUser(request, { allowAnonymous }) {
  if (!request.auth || !request.auth.uid) {
    throw new HttpsError("unauthenticated", "ログインが必要です");
  }
  if (allowAnonymous !== true && !core.isRegisteredToken(request.auth.token)) {
    throw new HttpsError("permission-denied", "registration_required", { reason: "registration_required" });
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

/** soratomoCallable が受け付ける選択肢の名前。ここに無い名前は、読み込みの時点で止める（soratomoCallable）。 */
const CALLABLE_OPTION_NAMES = Object.freeze(["allowAnonymous", "runtime", "respond", "okLogFields"]);

/**
 * Callable の本体を包む: ログインと登録済みの確認 → 本体 → 結果のログ。失敗は HttpsError に写して投げ直す。
 * 知らない選択肢の名前（1.14 期のクレームの確認の選択肢を含む）を受け取ったら、例外を投げる。Callable はモジュールの最上位で
 * 作るので、消し忘れ・書き間違いは読み込みの時点で（テストもデプロイも）止まる（public-launch 3.2）。
 * @param {string} name ログに出す Callable の名前
 * @param {(uid: string, data: Object) => Promise<Object>} body
 * @param {{ allowAnonymous?: boolean, runtime?: Object, respond?: (result: Object) => Object,
 *   okLogFields?: (result: Object, data: Object) => Object }} [options]
 *   - allowAnonymous: 匿名のログインも通すか（既定 false）。true にしてよいのは退会の削除（soratomoDeleteMyData）だけ。
 *     true でもログインは求める
 *   - runtime: onCall の設定（timeoutSeconds・memory など）。リージョンは REGION に固定する
 *   - respond: 本体の結果から、利用者へ返す応答を作る（既定はそのまま返す）
 *   - okLogFields: 成功のログに uid と一緒に出す項目（既定は groupId）。内部IDと件数だけにする（要件14.2・14.3）
 */
function soratomoCallable(name, body, options = {}) {
  const unknownOptions = Object.keys(options).filter((key) => !CALLABLE_OPTION_NAMES.includes(key));
  if (unknownOptions.length > 0) {
    throw new Error(`soratomoCallable(${name}): 知らない選択肢 ${unknownOptions.join(", ")}（受け付けるのは ${CALLABLE_OPTION_NAMES.join(", ")}）`);
  }
  const {
    allowAnonymous = false,
    runtime = {},
    respond = (result) => result,
    okLogFields = (result, data) => ({ groupId: result.groupId || data.groupId || null }),
  } = options;
  return onCall({ ...runtime, region: REGION }, async (request) => {
    let uid = null;
    const data = request.data && typeof request.data === "object" ? request.data : {};
    try {
      uid = requireSoratomoUser(request, { allowAnonymous });
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
 * - 匿名のログインも受け付ける（allowAnonymous: true。Callable で匿名を通すのはここだけ）。匿名の人と、一度も
 *   そらともを使っていない人のデータも消すため（要件1.4・public-launch 要件1.8）。そらともを使っていない人は、
 *   何も書かずに done: true（要件3.8）
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
    // 匿名も通す理由: 匿名の人と、一度もそらともを使っていない人のデータも消すため（要件1.4・public-launch 要件1.8）
    allowAnonymous: true,
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

// MARK: - グループだけ抜ける（leave-group 3.1）

/**
 * 本人が1つのグループを抜ける。{ groupId } → { done, groupDeleted }（アプリは done が true になるまで呼ぶ・leave-group 要件4.1）。
 * - 関門はほかの Callable と同じ（選択肢を渡さない＝登録済みを求め、匿名は拒否する・public-launch 3.2）。
 *   クレームは確かめない。匿名はグループに参加できないので、抜ける相手もいない（要件9.2）
 * - 抜ける相手は認証の uid だけ。要求の本文からは groupId だけを読む（uid を書かれても使わない・要件3.13）
 * - groupId が自動IDの形でなければ invalid_input（soratomoCreateSky と同じ型）。共通の削除が投げる TypeError を
 *   internal にしないため、呼ぶ前に確かめる
 * - 利用停止・同意は確かめない（要件9.3・9.4）
 * - 1回の予算は退会と同じ45秒。終わらなければ done: false。片づけ中の印と写しが残るので、次の呼び出しが続ける（要件4.1）
 * - メンバーでない人にも { done: true, groupDeleted: false } を返し、not_member は返さない（グループの有無を知らせない・要件3.14）
 * - 応答の groupDeleted は「この抜けるでグループごと消える（消えた）か」＝kind が delete_group（同じ回の再試行でも同じ値）。
 *   ただし再試行の間にほかの人が抜けてグループが消えると、kind を数え直すので true に変わる（影響は iOS の計測の値だけ）。
 *   成功のログの groupDeleted は「この実行でグループの文書を消したか」（退会の groupsDeleted と同じ意味・design の API Contract）
 * - 成功のログは内部IDと件数だけ（要件11.2〜11.4）。グループ名・表示名・キャプション・招待コードは出さない
 */
const soratomoLeaveGroup = soratomoCallable(
  "soratomoLeaveGroup",
  (uid, data) => {
    if (!core.isAutoId(data.groupId)) throw new store.SoratomoDomainError("invalid_input");
    return leaveSoratomoGroup(
      { db, storage, nowMs: Date.now },
      { uid, groupId: data.groupId, deadlineMs: Date.now() + DELETE_BUDGET_MS, origin: "self" }
    );
  },
  {
    runtime: { timeoutSeconds: 120, memory: "512MiB" },
    respond: (result) => ({ done: result.done, groupDeleted: result.kind === "delete_group" }),
    okLogFields: (result, data) => ({
      groupId: data.groupId,
      done: result.done,
      state: result.state,
      kind: result.kind,
      removed: result.removed,
      ownerTransferred: result.ownerTransferred,
      groupDeleted: result.groupDeleted,
      skiesDeleted: result.skiesDeleted,
      imagesDeleted: result.imagesDeleted,
    }),
  }
);

// MARK: - リアクション（soratomo-reactions 3.1）

/**
 * 新しく付いたリアクションを、投稿者へ知らせる（soratomo-reactions 要件5.4・6.1〜6.18・11.3〜11.5・design の Event Contract）。
 * 送ったかどうか・送らなかった理由を、成功のログの notify に出す文字列で返す（要件14.4・要件への差し戻しD2）。
 * - 読む文書は、グループ・投稿者のメンバーの文書・投稿者と付けた人の users の4件（getAll）
 * - 判定の順は新着投稿の通知と同じ: グループが無い（group_missing）・投稿者がもうメンバーでない（author_left）→
 *   classifyRecipient（通知設定OFF→ブロック→トークン無し）→ claimReactionNotifySlot（投稿が消えた sky_gone・
 *   同じ人の2通目 duplicate・5分以内 throttled）→ sendToTokenGrouped（sent・invalid_token・failed）
 * - classifyRecipient の posterId には「付けた人」を渡す（投稿者が付けた人をブロックしていれば送らない・要件5.4）
 * - 既存の3つの通知設定（notifyReactions など）と、宛先のアプリの版は見ない（要件12.4・6.18）
 * - 通知文は枠の確保より前に作る。作る途中で失敗したとき、間引きの記録と送った印を使ったまま何も送らない形にしないため
 * - 例外を投げない。失敗は "failed" にして、warn のログに内部IDと errorName・errorCode だけを出す（要件6.16。
 *   リアクションは確定済みで、送信の失敗で取り消さない）
 * @param {{ groupId: string, skyId: string, authorId: string, reactorUid: string, kind: string }} params
 *   kind は setReactionTx が書いた後の本人のリアクション（7つの名前のどれか）
 * @returns {Promise<"sent"|"invalid_token"|"failed"|"no_token"|"pref_off"|"blocked"|"throttled"|"duplicate"
 *   |"sky_gone"|"author_left"|"group_missing">}
 */
async function notifyReaction({ groupId, skyId, authorId, reactorUid, kind }) {
  try {
    const groupRef = db.collection("soratomoGroups").doc(groupId);
    const [groupSnap, authorMemberSnap, authorUserSnap, reactorUserSnap] = await db.getAll(
      groupRef,
      groupRef.collection("members").doc(authorId),
      db.collection("users").doc(authorId),
      db.collection("users").doc(reactorUid)
    );
    if (!groupSnap.exists) return "group_missing";
    if (!authorMemberSnap.exists) return "author_left";

    const authorData = authorUserSnap.exists ? authorUserSnap.data() : null;
    const recipient = core.classifyRecipient({ userData: authorData, posterId: reactorUid });
    if (recipient !== "eligible") return recipient;

    const notification = core.buildReactionNotification({
      groupName: groupSnap.get("name"),
      reactorName: reactorUserSnap.exists ? reactorUserSnap.get("displayName") : null,
      kind,
    });
    const slot = await store.claimReactionNotifySlot(db, { groupId, skyId, authorId, reactorUid, nowMs: Date.now() });
    if (slot !== "send") return slot;

    // FCM の data の値はすべて文字列。スレッドは新着投稿と同じグループごと、置き換えキーは新着投稿と別（U2 の A）
    const data = { type: "soratomoReaction", groupId, postId: skyId };
    const grouping = { threadId: `soratomo-${groupId}`, collapseId: `soratomo-reaction-${groupId}` };
    return await sendToTokenGrouped(authorId, authorData.fcmToken, notification, data, grouping);
  } catch (err) {
    logger.warn("soratomoSetReaction: notify_failed", {
      uid: reactorUid,
      groupId,
      skyId,
      errorName: err && err.name,
      errorCode: err && err.code,
    });
    return "failed";
  }
}

/**
 * 本人のリアクションを付ける・選び直す・外す。{ groupId, skyId, kind } → { outcome, kind }
 * （kind は7つの名前か null。null は外す・soratomo-reactions design の API Contract）
 * - 関門はほかの Callable と同じ（選択肢を渡さない＝登録済みを求め、匿名は拒否する・要件4.12）
 * - 規則（利用停止・メンバー・投稿の有無・自分の投稿・7種類）と書き込みは soratomoStore.setReactionTx（要件4.1〜4.11）
 * - 新しく付いた（added）ときだけ、応答の前に投稿者への通知を await する。選び直す・外す・同じもの（unchanged。
 *   送り直しで unchanged になった要求も）では送らない（要件6.7）。送信の失敗でリアクションを取り消さない（6.16）
 * - 応答は outcome と kind だけ。投稿者の uid（setReactionTx の authorId）は返さない
 * - 成功のログ（soratomoSetReaction: ok）は uid・groupId・skyId・outcome・kind・notify だけ（要件14.1〜14.4）。
 *   notify は送らなかったとき null、送ろうとしたとき notifyReaction の結果（要件への差し戻しD2）
 */
const soratomoSetReaction = soratomoCallable(
  "soratomoSetReaction",
  async (uid, data) => {
    const result = await store.setReactionTx(db, { uid, input: data });
    const notify =
      result.outcome === "added"
        ? await notifyReaction({ groupId: data.groupId, skyId: data.skyId, authorId: result.authorId, reactorUid: uid, kind: result.kind })
        : null;
    return { ...result, notify };
  },
  {
    respond: (result) => ({ outcome: result.outcome, kind: result.kind }),
    // groupId と skyId は setReactionTx が自動IDの形を確かめた値（形の違う値は invalid_input で、ここに来ない）
    okLogFields: (result, data) => ({
      groupId: data.groupId,
      skyId: data.skyId,
      outcome: result.outcome,
      kind: result.kind,
      notify: result.notify,
    }),
  }
);

// MARK: - 新着投稿の通知（8.2）

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
 * 分類の順は「通知設定OFF→ブロック→トークン無し→（枠の確保で）重複か間引き→送信」。宛先をクレームで絞らない
 * （Auth を読まない・public-launch 要件1.3）。集計の flagOff の項目は 1.14 期のログと同じ形のために残り、いつも0。
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
          const kind = core.classifyRecipient({ userData, posterId });
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

// MARK: - 投稿の削除（soratomo-reactions 3.2）

/**
 * 消えた投稿の送った印（reactionNotices/{skyId}）を消し、投稿と一緒に消えたリアクションの数をログに残す
 * （soratomo-reactions 要件8.1〜8.5・14.5・design の onSoratomoSkyDeleted）。
 * - リアクションそのもの（reactions・reactorIds）は投稿の文書の項目なので、投稿と同時に消える。ここで消すのは
 *   サーバー専用の印だけ（削除の経路とアプリの版に依らない。バッチと recursiveDelete でも1件ずつ発火する＝要確認Q1）
 * - 数えるのは消えた文書（event.data）の reactions の鍵の数。地図でなければ0
 * - 印の削除は何度でも同じ結果（無くても成功する）。再試行は付けない（既存のトリガーと同じ）
 * - 失敗は sky_deleted_failed を error で出し、例外を投げない（印が残っても、その投稿への通知を送らない側にしか効かない）
 * - ログは内部IDと件数だけ（要件14.2）
 * ⚠️ 印のコレクションの名前は soratomoStore.js の REACTION_NOTICES と同じ（書き手は claimReactionNotifySlot）
 * @param {{ params: { groupId: string, skyId: string }, data?: FirebaseFirestore.DocumentSnapshot }} event
 */
async function handleSoratomoSkyDeleted(event) {
  const { groupId, skyId } = event.params;
  try {
    const reactions = event.data ? event.data.get("reactions") : undefined;
    const reactionsDeleted =
      reactions !== null && typeof reactions === "object" && !Array.isArray(reactions) ? Object.keys(reactions).length : 0;
    await db.collection("soratomoGroups").doc(groupId).collection("reactionNotices").doc(skyId).delete();
    logger.info("soratomoReaction: sky_deleted", { groupId, skyId, reactionsDeleted });
  } catch (err) {
    logger.error("soratomoReaction: sky_deleted_failed", { groupId, skyId, errorName: err && err.name, errorCode: err && err.code });
  }
}

const onSoratomoSkyDeleted = onDocumentDeleted(
  { document: "soratomoGroups/{groupId}/skies/{skyId}", region: REGION },
  handleSoratomoSkyDeleted
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

// MARK: - 後始末と再送の定期実行（release-gate 4.4）

/** 仕事Aの締め切り（開始からのミリ秒）。関数の制限時間（540秒）より短くし、仕事Bの時間を残す。 */
const SWEEP_BUDGET_MS = 480_000;
/** getUsers に1回で渡す uid の数（Admin SDK の上限が100）。 */
const AUTH_LOOKUP_BATCH = 100;
/** 仕事Bが1回に読む未送信の通報の数。 */
const REFORWARD_LIMIT = 20;
/** 作成からこの時間を過ぎた未送信の通報だけを送り直す（作成のトリガーが送っている途中のものに重ねないため）。 */
const REFORWARD_MIN_AGE_MS = 10 * 60 * 1000;

/**
 * 仕事A: Auth のアカウントが無いのに、そらとものデータが残っている人を消す（要件4.1）。
 * - soratomoUsers を listDocuments で集める（利用者の文書が無く、所属の写しだけが残った親も含む）
 * - 100件ずつ getUsers に問い合わせ、成功した応答の notFound に入っていた uid だけを、共通の削除（account_deleted）で消す。
 *   問い合わせが失敗した組は飛ばす（失敗を「アカウントが無い」と読むと、アカウントのある人のデータを消してしまう）。
 *   notFound は、問い合わせた組の中の uid に限って使う（それ以外の値を消す相手にしない）
 * - account_deleted は、停止中の人の文書も消す（要件2.3 の「停止の記録も消す」を、アカウントを消した後にここで満たす）
 * - 1人の削除の失敗で残りを止めない。締め切りを過ぎたら、残りは次の実行に回す（共通の削除は冪等で、写しが残る限り続く）
 * - ログ: 1人ごとに soratomoDeletion: summary（内部IDと件数だけ・要件14.4）
 * @param {number} deadlineMs
 * @returns {Promise<{ scanned: number, missingAuth: number, completed: number, unfinished: number }>}
 *   scanned は問い合わせに成功した数、unfinished は missingAuth のうち消し終わらなかった数（失敗・締め切りを含む）
 */
async function sweepUsersWithoutAccount(deadlineMs) {
  const trigger = "account_deleted";
  const summary = { scanned: 0, missingAuth: 0, completed: 0, unfinished: 0 };
  const uids = (await db.collection("soratomoUsers").listDocuments()).map((ref) => ref.id);
  for (let i = 0; i < uids.length && Date.now() < deadlineMs; i += AUTH_LOOKUP_BATCH) {
    const batch = uids.slice(i, i + AUTH_LOOKUP_BATCH);
    let missing;
    try {
      const { notFound } = await getAuth().getUsers(batch.map((uid) => ({ uid })));
      const notFoundUids = new Set(notFound.map((identifier) => identifier && identifier.uid));
      missing = batch.filter((uid) => notFoundUids.has(uid));
    } catch (err) {
      logger.warn("soratomoHousekeeping: lookup_failed", {
        count: batch.length,
        errorName: err && err.name,
        errorCode: err && err.code,
      });
      continue;
    }
    summary.scanned += batch.length;
    summary.missingAuth += missing.length;
    for (const uid of missing) {
      if (Date.now() >= deadlineMs) {
        summary.unfinished += 1;
        continue;
      }
      try {
        const totals = await deleteSoratomoUserData({ db, storage, nowMs: Date.now }, { uid, trigger, deadlineMs });
        logger.info("soratomoDeletion: summary", { uid, trigger, ...totals });
        if (totals.done) summary.completed += 1;
        else summary.unfinished += 1;
      } catch (err) {
        logger.error("soratomoDeletion: failed", { uid, trigger, errorName: err && err.name, errorCode: err && err.code });
        summary.unfinished += 1;
      }
    }
  }
  return summary;
}

/**
 * 仕事B: 転送の状態が未送信の通報を最大20件読み、作成から10分を過ぎたものだけを送り直す（要件7.5）。
 * 状態の単一項目のクエリにして複合インデックスを増やさず、年齢はメモリ上で見る（skyMotionPurchase のリコンサイラと同じ）。
 * 作成日時が読めない記録は古いものとして送り直す（いつまでも埋もれさせない）。
 * @param {string} webhookUrl
 * @returns {Promise<{ attempted: number, sent: number }>}
 */
async function reforwardPendingReports(webhookUrl) {
  const snap = await db.collection("soratomoReports").where("forwardStatus", "==", "pending").limit(REFORWARD_LIMIT).get();
  const cutoffMs = Date.now() - REFORWARD_MIN_AGE_MS;
  const result = { attempted: 0, sent: 0 };
  for (const doc of snap.docs) {
    const createdMs = millisOf(doc.get("createdAt"));
    if (createdMs !== null && createdMs > cutoffMs) continue;
    result.attempted += 1;
    if ((await forwardReport(doc.ref, webhookUrl)) === "sent") result.sent += 1;
  }
  return result;
}

// MARK: - 途中で止まった抜けるを終える（leave-group 3.2）

/** 仕事Cの予算（開始からのミリ秒）。仕事Aの締め切り（開始から480秒）は変えない（仕事Aに残る時間は、仕事Cが使った分だけ減る）。 */
const LEAVE_SWEEP_BUDGET_MS = 120_000;
/** 抜けるの確定（leftAt）からこの時間を過ぎた印だけを扱う。アプリの繰り返し（最大8回×75秒）と同じ回を重ねて進めないため。 */
const LEAVE_SWEEP_MIN_AGE_MS = 30 * 60 * 1000;
/** 1回に読む印の数。 */
const LEAVE_SWEEP_PAGE = 50;
/** 抜けるの確定からこの時間を過ぎても終わらなければ overdue を出す（要件4.8）。 */
const LEAVE_OVERDUE_MS = 24 * 60 * 60 * 1000;

/**
 * 仕事C: 途中で止まった抜けるを、片づけ中の印から続けて終える（leave-group 要件4.6・4.8・11.5）。
 * - 印を leftAt が30分より前のものだけ、古い順に50件ずつ読む（leftAt の単一項目のクエリ。複合インデックスは増やさない）
 * - 印の形（uid が isUid・groupId が自動ID・文書IDが「uid_groupId」）が違えば、消さずに飛ばして malformed_marker を出す
 *   （開発者が確かめる。書き手は Functions だけなので、ふつうは起きない）
 * - 各印で leaveSoratomoGroup を origin: "sweep" で呼ぶ。手順1でメンバーを外さないので、入り直した後の古い印は
 *   印だけを消して終わる（stale_marker・遅れた片づけが入り直した人を外し直さない＝要件8.6）
 * - 1件の失敗で残りを止めない。終わらなかった印は残り、次の実行が拾う。予算を過ぎたら、残りは次の実行に回す
 * - ログは内部IDと件数だけ（要件11.2・11.5）: 1件ごとに swept、終わらないか失敗して24時間を過ぎたものに overdue（warn）、
 *   失敗に sweep_item_failed（error）。グループ名・表示名・キャプション・招待コードは出さない
 * @param {number} startedMs 定期実行の開始の時刻
 * @returns {Promise<{ scanned: number, completed: number, unfinished: number, overdue: number, malformed: number,
 *   failed: number }>} scanned は形を確かめた印の数（malformed を含む）
 */
async function sweepPendingLeaves(startedMs) {
  const deadlineMs = startedMs + LEAVE_SWEEP_BUDGET_MS;
  const cutoff = Timestamp.fromMillis(startedMs - LEAVE_SWEEP_MIN_AGE_MS);
  const summary = { scanned: 0, completed: 0, unfinished: 0, overdue: 0, malformed: 0, failed: 0 };
  let last = null;
  while (Date.now() < deadlineMs) {
    let query = db.collection(PENDING_LEAVES).where("leftAt", "<=", cutoff).orderBy("leftAt").limit(LEAVE_SWEEP_PAGE);
    if (last) query = query.startAfter(last);
    const snap = await query.get();
    for (const doc of snap.docs) {
      if (Date.now() >= deadlineMs) break;
      summary.scanned += 1;
      const uid = doc.get("uid");
      const groupId = doc.get("groupId");
      if (!isUid(uid) || !core.isAutoId(groupId) || doc.id !== `${uid}_${groupId}`) {
        summary.malformed += 1;
        logger.warn("soratomoLeave: malformed_marker", { markerId: doc.id });
        continue;
      }
      const leftAtMs = millisOf(doc.get("leftAt"));
      let done = false;
      try {
        const result = await leaveSoratomoGroup({ db, storage, nowMs: Date.now }, { uid, groupId, deadlineMs, origin: "sweep" });
        done = result.done;
        logger.info("soratomoLeave: swept", {
          uid,
          groupId,
          done: result.done,
          state: result.state,
          kind: result.kind,
          removed: result.removed,
          ownerTransferred: result.ownerTransferred,
          groupDeleted: result.groupDeleted,
          skiesDeleted: result.skiesDeleted,
          imagesDeleted: result.imagesDeleted,
          ageMs: Date.now() - leftAtMs,
        });
        if (done) summary.completed += 1;
        else summary.unfinished += 1;
      } catch (err) {
        summary.failed += 1;
        logger.error("soratomoLeave: sweep_item_failed", { uid, groupId, errorName: err && err.name, errorCode: err && err.code });
      }
      const ageMs = Date.now() - leftAtMs;
      if (!done && ageMs > LEAVE_OVERDUE_MS) {
        summary.overdue += 1;
        logger.warn("soratomoLeave: overdue", { uid, groupId, ageMs });
      }
    }
    if (snap.size < LEAVE_SWEEP_PAGE) break;
    last = snap.docs[snap.docs.length - 1];
  }
  return summary;
}

/**
 * 6時間ごとの後始末と再送（design の soratomoHousekeeping）。同時に1つだけ動く（maxInstances: 1）。
 * 仕事C→仕事A→仕事Bの順に、別々の try で囲む（どれかの失敗で他を止めない）。仕事Aは締め切りを持ち、仕事Bの時間を残す。
 * 6時間ごとなので、Auth の削除から最悪6時間で拾い、途中で止まっても24時間の間に4回の機会がある（要件4.1）。
 * 仕事C（leave-group 3.2）は予算120秒で先に動く。途中で止まった抜けるは、確定から最大6時間30分で最初の機会が来る（要件4.6）。
 */
const soratomoHousekeeping = onSchedule(
  {
    schedule: "every 6 hours",
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    maxInstances: 1,
    secrets: [DISCORD_REPORT_WEBHOOK_URL],
  },
  async () => {
    const startedMs = Date.now();
    try {
      logger.info("soratomoHousekeeping: leave_sweep", await sweepPendingLeaves(startedMs));
    } catch (err) {
      logger.error("soratomoHousekeeping: leave_sweep_failed", { errorName: err && err.name, errorCode: err && err.code });
    }
    try {
      logger.info("soratomoHousekeeping: sweep", await sweepUsersWithoutAccount(startedMs + SWEEP_BUDGET_MS));
    } catch (err) {
      logger.error("soratomoHousekeeping: sweep_failed", { errorName: err && err.name, errorCode: err && err.code });
    }
    try {
      logger.info("soratomoHousekeeping: reforward", await reforwardPendingReports(DISCORD_REPORT_WEBHOOK_URL.value()));
    } catch (err) {
      logger.error("soratomoHousekeeping: reforward_failed", { errorName: err && err.name, errorCode: err && err.code });
    }
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
  soratomoLeaveGroup,
  soratomoSetReaction,
  onSoratomoSkyCreated,
  onSoratomoSkyDeleted,
  onSoratomoReportCreated,
  soratomoHousekeeping,
};
