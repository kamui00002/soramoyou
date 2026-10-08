#!/usr/bin/env node

/**
 * そらともの開発者の運用スクリプト（確認・削除・利用停止・一覧）☁️⭐️
 * spec: .kiro/specs/soratomo-release-gate/（tasks.md 6.1・design.md「運用: 管理スクリプト」）
 *
 * ■ 通報への対応（24時間以内・要件8.1〜8.3）
 *   1. Discord の通報のチャンネルで、通報が届いたことに気づく（届くのは内部IDと理由と時刻だけ）
 *   2. `show-report <reportId>` で、通報の記録の項目と、コンソールで開く文書のパス・Storage の画像のパスを出す
 *   3. Firebase のコンソールで、その投稿のキャプションと画像を見て、そらともガイドラインへの違反かを判断する
 *      （このスクリプトはキャプションと画像を出さない。中身はコンソールでだけ見る）
 *   4. `review-report <reportId> --result no_violation` か `--result violation` で結果を記録する。
 *      violation なら、投稿を消し、投稿者を利用停止にしてから記録を書く（途中で止まったら、同じコマンドをもう一度）
 *   転送が届いていないかもしれないときは `list-unforwarded` で未送信の通報を探す（再送は定期実行が6時間ごとに行う）。
 *
 * ■ コマンド
 *   find-orphans [--deep]                          アカウントの無い uid を並べる（要件4.3）。--deep はグループの下の
 *                                                  メンバー・投稿者・画像のパスからも集め、データの残るグループIDも並べる
 *   delete-user <uid> [--group <groupId>]...       アカウントの無い利用者のそらとものデータを消す（要件4.2）。
 *                                                  アカウントがあれば拒否する。--group は find-orphans --deep の出力を渡す
 *   show-report <reportId>                         通報の記録を出す（要件8.1）
 *   review-report <reportId> --result <結果>       確認の日時と結果（no_violation / violation）を記録する（要件8.2・8.3）
 *   delete-sky <groupId> <skyId>                   投稿1件の文書と画像を消す（要件8.4）
 *   suspend <uid>                                  利用を停止し、投稿と所属を消す（要件8.2・8.5）
 *   unsuspend <uid>                                利用停止を解く。消した投稿と所属は戻らない（要件8.8）
 *   list-unforwarded                               転送の状態が未送信の通報を並べる（要件7.5）
 *
 * ■ 出力の約束（要件14.3）
 *   内部ID（uid・グループID・投稿ID・通報の記録のID）と件数・理由・時刻・状態だけを出す。
 *   キャプション・グループ名・表示名・招待コード・画像・メールアドレスは出さない。記録の値がIDの形に合わないときは
 *   値を出さずに「（壊れた値）」と出す。エラーは code（無ければ名前）だけを出す（本文に資格情報のパスなどが入るため）。
 *
 * ■ 認証: Application Default Credentials（ADC）。鍵ファイルはリポジトリに置かない。
 *   1. gcloud auth application-default login
 *   2. Auth の Admin API で quota project を求められたら:
 *        gcloud auth application-default set-quota-project soramoyou-ios
 *   接続先は EXPECTED_PROJECT_ID（soramoyou-ios）と EXPECTED_BUCKET に固定している（ADC の既定に頼らない）。
 *
 * ■ 実行方法（リポジトリ直下で）
 *   firebase-admin は functions/ の依存を借りる（functions で npm install 済みであること）。functions/ を起点に解決するので、
 *   共通の削除のモジュール（functions/soratomoDeletion.js）と同じ実体になる（NODE_PATH は要らない）。
 *     node scripts/soratomo-admin.js <コマンド> ...
 *   ⚠️ エミュレーターを指す環境変数（名前が _EMULATOR_HOST で終わるもの）が1つでもあれば、何もせずに止める。
 *      Auth だけエミュレーター・Firestore は本番という混在だと、delete-user の「アカウントが無い」の判定が
 *      本番のデータの削除に直結するため（エミュレーターでの確かめは soratomo-admin.emulator.test.js で cmd* を直接呼ぶ）。
 *   ⚠️ 本番に対する実行は、利用者の GO を取ってから行う（読み取りだけの find-orphans・show-report・list-unforwarded を含む）。
 *
 * ■ 作り（scripts/set-soratomo-beta-claim.js と同じ）
 *   - 引数の解釈と出力の組み立ては純関数。処理は cmd*(deps, args) → { lines, exitCode } で、deps に db・auth・Storage の
 *     ゲートウェイ・共通の削除のモジュール・時計を差し込む。firebase-admin は main の中でだけ読み込む
 *     （単体テストと引数の確認に依存を持ち込まないため）。
 *   - 削除は functions/soratomoDeletion.js（退会・定期実行と同じ実装）を使う。手順を二重に書かない。
 *
 * ■ テスト
 *   単体: node --test scripts/soratomo-admin.test.js（firebase-admin 非依存。本番には触れない）
 *   エミュレーター: scripts/soratomo-admin.emulator.test.js の冒頭を参照
 */

"use strict";

const path = require("node:path");
const { createRequire } = require("node:module");
const core = require("../functions/soratomoCore");

// MARK: - 定数

/** 接続先として唯一許可する Firebase プロジェクト（.firebaserc が空のため、ここで固定する）。 */
const EXPECTED_PROJECT_ID = "soramoyou-ios";
/** 画像のバケット（scripts/check-soratomo-download-tokens.js と同じ。バケット名は秘密ではない）。 */
const EXPECTED_BUCKET = "soramoyou-ios.firebasestorage.app";

/**
 * functions/ を起点にした require。firebase-admin はこれで読む（main の中でだけ）。
 * 素の require は NODE_PATH 次第で別の firebase-admin を拾い、共通の削除のモジュールが持つ FieldValue と
 * db の実体が食い違って、削除の途中で失敗しうるため。
 */
const functionsRequire = createRequire(path.join(__dirname, "..", "functions", "package.json"));

/** コレクションの名前（functions/soratomoStore.js・soratomoDeletion.js と同じ）。 */
const GROUPS = "soratomoGroups";
const MEMBERS = "members";
const SKIES = "skies";
const USERS = "soratomoUsers";
const REPORTS = "soratomoReports";

/** 1回の削除の予算。過ぎたら未完了で返るので、同じコマンドをもう一度実行する（共通の削除は冪等）。 */
const DELETE_BUDGET_MS = 10 * 60 * 1000;
/** getUsers に1回で渡す uid の数（Admin SDK の上限が100）。 */
const AUTH_LOOKUP_BATCH = 100;
/** 確認の結果（要件8.3）。違反なしと、削除と利用停止。 */
const REVIEW_RESULTS = Object.freeze(["no_violation", "violation"]);
/** 転送の状態（functions/soratomo.js の forwardReport が書く値）。 */
const FORWARD_STATUSES = Object.freeze(["pending", "sent"]);

const USAGE = [
  "使い方: node scripts/soratomo-admin.js <コマンド> ...",
  "  find-orphans [--deep]",
  "  delete-user <uid> [--group <groupId>]...",
  "  show-report <reportId>",
  "  review-report <reportId> --result no_violation|violation",
  "  delete-sky <groupId> <skyId>",
  "  suspend <uid>",
  "  unsuspend <uid>",
  "  list-unforwarded",
].join("\n");

// MARK: - 値の形

/**
 * uid として使えるか（空でない・「/」を含まない・Firebase Auth の上限の128文字以下）。
 * 先頭の「-」はオプションと取り違えないよう、引数としては受け付けない（parseArgs で別に見る）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isUid(value) {
  return typeof value === "string" && value.length > 0 && value.length <= 128 && !value.includes("/");
}

/** 出力してよい ID の形（英数字と「_」「-」）。Firebase が作る uid（28文字の英数字）と自動IDはここに入る。 */
const PRINTABLE_ID = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * 出力してよい ID か。isUid は「/」と長さしか見ない（Auth の制約と同じ）ので、名前などの文字列も通る。
 * 記録から読んだ値を出す前には、こちらで確かめる（合わなければ値を出さない・要件14.3）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isPrintableId(value) {
  return typeof value === "string" && PRINTABLE_ID.test(value);
}

/**
 * 通報の記録のIDの形か（「グループID_投稿ID_通報者」・soratomoCore.reportDocId）。
 * @param {unknown} value
 * @returns {boolean}
 */
function isReportId(value) {
  if (typeof value !== "string") return false;
  const [groupId, skyId, ...rest] = value.split("_");
  return core.isAutoId(groupId) && core.isAutoId(skyId) && isPrintableId(rest.join("_"));
}

/** 引数として受け付ける uid（形が正しく、オプションと紛れない）。 */
function isUidArg(value) {
  return isUid(value) && !value.startsWith("-");
}

/**
 * 記録の値を、形が正しいときだけそのまま、そうでなければ「（壊れた値）」にする（出力に内部ID以外を混ぜない）。
 * @param {unknown} value
 * @param {(v: unknown) => boolean} isValid
 * @returns {string}
 */
function shown(value, isValid) {
  if (value === undefined || value === null) return "（無い）";
  return isValid(value) ? String(value) : "（壊れた値）";
}

/**
 * Firestore の時刻（Timestamp）か Date を ISO 8601 の文字列にする。無い・読めないときは「（無い）」。
 * @param {unknown} value
 * @returns {string}
 */
function isoOf(value) {
  if (value && typeof value.toMillis === "function") return new Date(value.toMillis()).toISOString();
  if (value instanceof Date && !Number.isNaN(value.getTime())) return value.toISOString();
  return "（無い）";
}

/** 時刻を並べ替え用のミリ秒にする（無ければ最後に回す）。 */
function millisForSort(value) {
  return value && typeof value.toMillis === "function" ? value.toMillis() : Number.MAX_SAFE_INTEGER;
}

// MARK: - 引数の解釈

/**
 * コマンドラインの引数を読む。足りない・余る・形の違う引数は、何も読み書きする前に { ok: false } で止める。
 * @param {string[]} argv process.argv.slice(2)
 * @returns {{ ok: false } | ({ ok: true, command: string } & Object)}
 */
function parseArgs(argv) {
  const [command, ...rest] = argv;
  switch (command) {
    case "find-orphans":
      if (rest.length === 0) return { ok: true, command, deep: false };
      if (rest.length === 1 && rest[0] === "--deep") return { ok: true, command, deep: true };
      return { ok: false };
    case "delete-user": {
      const [uid, ...options] = rest;
      if (!isUidArg(uid) || options.length % 2 !== 0) return { ok: false };
      const groupIds = [];
      for (let i = 0; i < options.length; i += 2) {
        if (options[i] !== "--group" || !core.isAutoId(options[i + 1])) return { ok: false };
        groupIds.push(options[i + 1]);
      }
      return { ok: true, command, uid, groupIds: [...new Set(groupIds)] };
    }
    case "show-report":
      if (rest.length !== 1 || !isReportId(rest[0])) return { ok: false };
      return { ok: true, command, reportId: rest[0] };
    case "review-report":
      if (rest.length !== 3 || !isReportId(rest[0]) || rest[1] !== "--result" || !REVIEW_RESULTS.includes(rest[2])) {
        return { ok: false };
      }
      return { ok: true, command, reportId: rest[0], result: rest[2] };
    case "delete-sky":
      if (rest.length !== 2 || !core.isAutoId(rest[0]) || !core.isAutoId(rest[1])) return { ok: false };
      return { ok: true, command, groupId: rest[0], skyId: rest[1] };
    case "suspend":
    case "unsuspend":
      if (rest.length !== 1 || !isUidArg(rest[0])) return { ok: false };
      return { ok: true, command, uid: rest[0] };
    case "list-unforwarded":
      if (rest.length !== 0) return { ok: false };
      return { ok: true, command };
    default:
      return { ok: false };
  }
}

// MARK: - 出力の組み立て

/**
 * 共通の削除の件数を、出力の行にする（内部IDを含まない）。
 * @param {{ done: boolean, skiesDeleted: number, imagesDeleted: number, groupsLeft: number,
 *   ownersTransferred: number, groupsDeleted: number }} totals
 * @returns {string[]}
 */
function formatTotals(totals) {
  return [
    totals.done ? "完了: はい" : "完了: いいえ（予算の時間で止めた。同じコマンドをもう一度実行する）",
    `消した投稿: ${totals.skiesDeleted} 件・画像: ${totals.imagesDeleted} 枚`,
    `外したグループ: ${totals.groupsLeft} 個（うちオーナーを引き継いだ: ${totals.ownersTransferred} 個）・` +
      `消したグループ: ${totals.groupsDeleted} 個`,
  ];
}

/**
 * Auth のアカウントがあるかを確かめる。無い（auth/user-not-found）ときだけ "missing" を返す。
 * それ以外の失敗（通信・権限・quota）は「無い」と読まずに投げ直す（アカウントのある人のデータを消さないため。
 * functions/soratomo.js の仕事Aが、問い合わせに失敗した組を飛ばすのと同じ理由）。
 * @param {{ getUser: (uid: string) => Promise<unknown> }} auth
 * @param {string} uid
 * @returns {Promise<"exists"|"missing">}
 */
async function lookupAccount(auth, uid) {
  try {
    await auth.getUser(uid);
    return "exists";
  } catch (err) {
    if (err && err.code === "auth/user-not-found") return "missing";
    throw err;
  }
}

/** 削除の依存に渡す締め切り。 */
function deadlineOf(deps) {
  return deps.nowMs() + DELETE_BUDGET_MS;
}

// MARK: - コマンド

/**
 * find-orphans（要件4.3）: アカウントの無い uid を並べる。
 * - soratomoUsers を listDocuments で集める（利用者の文書が無く、所属の写しだけが残った親も含む）
 * - --deep: soratomoGroups を listDocuments で集め（文書の無い親を含む）、メンバーの文書ID・投稿の authorId・
 *   Storage の soratomo/{groupId}/{uid}/{skyId}/{ファイル} のパスから uid とグループIDを集める
 * - 100件ずつ getUsers に問い合わせ、notFound は問い合わせた組の中の uid だけに使う。
 *   問い合わせが1組でも失敗したら、途中までの一覧を出さずに投げる（失敗を「アカウントが無い」と読まない）
 * - 出力できる ID の形（isPrintableId）でない値は、問い合わせず・表示せず、数だけを出す（名前などを出さないため。
 *   getUsers は形の違う識別子が1つでも混ざると組ごと失敗するので、その柵も兼ねる）
 * - --deep のグループIDも、自動IDの形（core.isAutoId）のときだけ並べる。形の違う文書IDは数えるだけで、その下の uid は
 *   集める（アカウントの無い人は見つけるが、データの残るグループには入れない。delete-user の --group も自動IDしか受け付けない）
 * @param {{ db: FirebaseFirestore.Firestore, auth: { getUsers: Function },
 *   storage: { listFiles: (prefix: string) => AsyncIterable<string> } }} deps
 * @param {{ deep: boolean }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdFindOrphans(deps, { deep }) {
  const { db, auth, storage } = deps;
  /** uid → データの残るグループIDの集合（--deep のときだけ埋まる） */
  const found = new Map();
  let malformed = 0;
  let oddPaths = 0;
  let oddGroups = 0;
  const add = (uid, groupId) => {
    if (!isPrintableId(uid)) {
      malformed += 1;
      return;
    }
    if (!found.has(uid)) found.set(uid, new Set());
    if (groupId) found.get(uid).add(groupId);
  };

  for (const ref of await db.collection(USERS).listDocuments()) add(ref.id, null);
  if (deep) {
    for (const groupRef of await db.collection(GROUPS).listDocuments()) {
      const groupId = core.isAutoId(groupRef.id) ? groupRef.id : null;
      if (groupId === null) oddGroups += 1;
      for (const memberRef of await groupRef.collection(MEMBERS).listDocuments()) add(memberRef.id, groupId);
      const skies = await groupRef.collection(SKIES).select("authorId").get();
      for (const doc of skies.docs) add(doc.get("authorId"), groupId);
    }
    for await (const path of storage.listFiles("soratomo/")) {
      const parts = path.split("/");
      if (parts.length === 5 && core.isAutoId(parts[1]) && isPrintableId(parts[2])) add(parts[2], parts[1]);
      else oddPaths += 1;
    }
  }

  const uids = [...found.keys()].sort();
  const missing = [];
  for (let i = 0; i < uids.length; i += AUTH_LOOKUP_BATCH) {
    const batch = uids.slice(i, i + AUTH_LOOKUP_BATCH);
    const { notFound } = await auth.getUsers(batch.map((uid) => ({ uid })));
    const notFoundUids = new Set(notFound.map((identifier) => identifier && identifier.uid));
    missing.push(...batch.filter((uid) => notFoundUids.has(uid)));
  }

  const lines = [
    `調べた uid: ${uids.length} 人（${deep ? "利用者の文書・メンバー・投稿者・画像のパス" : "利用者の文書"}から）`,
    `アカウントの無い uid: ${missing.length} 人`,
  ];
  for (const uid of missing) {
    const groups = [...found.get(uid)].sort();
    lines.push(deep ? `  ${uid}  データの残るグループ: ${groups.length > 0 ? groups.join(" ") : "（なし）"}` : `  ${uid}`);
  }
  if (malformed > 0) lines.push(`ID の形でない値: ${malformed} 件（数えるだけ・表示しない。コンソールで探す）`);
  if (oddPaths > 0) lines.push(`soratomo/ の下で形の違うパス: ${oddPaths} 件（数えるだけ・表示しない）`);
  if (oddGroups > 0) lines.push(`soratomoGroups の下で ID の形でないグループ: ${oddGroups} 個（数えるだけ・表示しない。コンソールで探す）`);
  if (missing.length > 0) lines.push("消すには: delete-user <uid>（--deep のグループは --group <groupId> で足す）");
  return { lines, exitCode: 0 };
}

/**
 * delete-user（要件4.2）: アカウントの無い利用者のそらとものデータを、退会と同じ手順（trigger "admin"）で消す。
 * アカウントがあれば拒否する（要件4はアカウントの無い利用者が対象。違反した利用者には suspend を使う）。
 * @param {{ auth: { getUser: Function }, deletion: { deleteSoratomoUserData: Function }, nowMs: () => number }} deps
 * @param {{ uid: string, groupIds: string[] }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdDeleteUser(deps, { uid, groupIds }) {
  if ((await lookupAccount(deps.auth, uid)) === "exists") {
    return {
      lines: [`uid: ${uid}`, "❌ Auth のアカウントがあるので消さない（アカウントの無い利用者だけが対象。違反なら suspend を使う）"],
      exitCode: 1,
    };
  }
  const totals = await deps.deletion.deleteSoratomoUserData(deps, {
    uid,
    trigger: "admin",
    deadlineMs: deadlineOf(deps),
    extraGroupIds: groupIds,
  });
  return { lines: [`uid: ${uid}`, ...formatTotals(totals)], exitCode: totals.done ? 0 : 1 };
}

/**
 * show-report（要件8.1）: 通報の記録の項目と、コンソールで開く文書のパス・画像のパスを出す。
 * 投稿の文書は有無だけを見る（キャプションは出さない）。
 * @param {{ db: FirebaseFirestore.Firestore }} deps
 * @param {{ reportId: string }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdShowReport({ db }, { reportId }) {
  const snap = await db.collection(REPORTS).doc(reportId).get();
  if (!snap.exists) return { lines: [`通報の記録が無い: ${reportId}`], exitCode: 1 };
  const r = snap.data();
  const idsOk = core.isAutoId(r.groupId) && core.isAutoId(r.skyId) && isPrintableId(r.authorId);

  const lines = [
    `通報の記録: ${reportId}`,
    `理由: ${shown(r.reason, (v) => core.REPORT_REASONS.includes(v))}`,
    `受け付けた時刻: ${isoOf(r.createdAt)}`,
    `グループ: ${shown(r.groupId, core.isAutoId)}`,
    `投稿: ${shown(r.skyId, core.isAutoId)}`,
    `投稿者: ${shown(r.authorId, isPrintableId)}`,
    `通報者: ${shown(r.reporterId, isPrintableId)}`,
    `転送: ${shown(r.forwardStatus, (v) => FORWARD_STATUSES.includes(v))}・失敗の回数: ` +
      `${shown(r.forwardAttempts, Number.isInteger)}・送信日時: ${isoOf(r.forwardedAt)}`,
    `確認: ${r.reviewResult === undefined ? "未確認" : shown(r.reviewResult, (v) => REVIEW_RESULTS.includes(v))}` +
      `・確認日時: ${isoOf(r.reviewedAt)}`,
  ];
  if (!idsOk) {
    lines.push("⚠️ 記録の ID が壊れているので、投稿の場所を出せない");
    return { lines, exitCode: 1 };
  }
  const skyPath = `${GROUPS}/${r.groupId}/${SKIES}/${r.skyId}`;
  const imagePrefix = `soratomo/${r.groupId}/${r.authorId}/${r.skyId}/`;
  const skyExists = (await db.doc(skyPath).get()).exists;
  lines.push(
    `投稿の文書: ${skyExists ? "あり" : "無い（投稿者が消したか、削除済み）"}`,
    `コンソールで開く文書: ${skyPath}`,
    `Storage の画像: ${imagePrefix}display.jpg と ${imagePrefix}thumb.jpg`,
    `記録する: review-report ${reportId} --result no_violation|violation`
  );
  return { lines, exitCode: 0 };
}

/**
 * review-report（要件8.2・8.3）: 確認の日時と結果を記録する。
 * violation なら、投稿を消し（画像も）、記録の投稿者（受け付けたときの実際の投稿者・要件6.8）を利用停止にしてから記録を書く。
 * 停止が予算の時間で止まったら記録を書かない（同じコマンドの再実行で続きから。削除と停止は冪等）。
 * 前回の結果があれば出して上書きする。violation から no_violation に変えても、削除と停止は戻さない。
 * @param {{ db: FirebaseFirestore.Firestore, deletion: { deleteSoratomoSky: Function, suspendSoratomoUser: Function },
 *   nowMs: () => number, serverTimestamp: () => unknown }} deps
 * @param {{ reportId: string, result: "no_violation"|"violation" }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdReviewReport(deps, { reportId, result }) {
  const ref = deps.db.collection(REPORTS).doc(reportId);
  const snap = await ref.get();
  if (!snap.exists) return { lines: [`通報の記録が無い: ${reportId}`], exitCode: 1 };
  const r = snap.data();
  const lines = [`通報の記録: ${reportId}`];
  if (r.reviewResult !== undefined) {
    lines.push(
      `前回の結果: ${shown(r.reviewResult, (v) => REVIEW_RESULTS.includes(v))}（上書きする。消した投稿と停止は戻さない）`
    );
  }

  if (result === "violation") {
    if (!core.isAutoId(r.groupId) || !core.isAutoId(r.skyId) || !isPrintableId(r.authorId)) {
      lines.push("❌ 記録の ID が壊れているので、推測で消さずに止めた（コンソールで確かめ、delete-sky と suspend を使う）");
      return { lines, exitCode: 1 };
    }
    const sky = await deps.deletion.deleteSoratomoSky(deps, { groupId: r.groupId, skyId: r.skyId });
    lines.push(`投稿 ${r.skyId}: ${sky.skyDeleted ? "消した" : "もう無かった"}・画像: ${sky.imagesDeleted} 枚`);
    const totals = await deps.deletion.suspendSoratomoUser(deps, { uid: r.authorId, deadlineMs: deadlineOf(deps) });
    lines.push(`投稿者 ${r.authorId} を利用停止にした`, ...formatTotals(totals));
    if (!totals.done) {
      lines.push("確認の記録はまだ書いていない（同じコマンドをもう一度実行する）");
      return { lines, exitCode: 1 };
    }
  }

  await ref.update({ reviewedAt: deps.serverTimestamp(), reviewResult: result });
  lines.push(`確認の記録を書いた: ${result}`);
  return { lines, exitCode: 0 };
}

/**
 * delete-sky（要件8.4）: 投稿1件の文書と画像（display.jpg と thumb.jpg）を消す。
 * @param {{ deletion: { deleteSoratomoSky: Function } }} deps
 * @param {{ groupId: string, skyId: string }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdDeleteSky(deps, { groupId, skyId }) {
  const result = await deps.deletion.deleteSoratomoSky(deps, { groupId, skyId });
  return {
    lines: [
      `投稿: ${GROUPS}/${groupId}/${SKIES}/${skyId}`,
      result.skyDeleted ? `消した（画像: ${result.imagesDeleted} 枚）` : "文書が無かった（何もしていない）",
    ],
    exitCode: 0,
  };
}

/**
 * suspend（要件8.2・8.5）: 利用停止の日時を書き、投稿と画像を消し、所属するすべてのグループから外す。
 * アカウントの有無は、打ち間違いに気づくための読み取りだけ（結果で動きは変えない。停止はアカウントが無くても書く）。
 * @param {{ auth: { getUser: Function }, deletion: { suspendSoratomoUser: Function }, nowMs: () => number }} deps
 * @param {{ uid: string }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdSuspend(deps, { uid }) {
  let account;
  try {
    account = (await lookupAccount(deps.auth, uid)) === "exists" ? "あり" : "無い（uid の打ち間違いでないか確かめる）";
  } catch (err) {
    account = `確かめられなかった（${(err && (err.code || err.name)) || "不明"}）`;
  }
  const totals = await deps.deletion.suspendSoratomoUser(deps, { uid, deadlineMs: deadlineOf(deps) });
  return {
    lines: [`uid: ${uid}`, `Auth のアカウント: ${account}`, "利用停止の日時を書いた", ...formatTotals(totals)],
    exitCode: totals.done ? 0 : 1,
  };
}

/**
 * unsuspend（要件8.8）: 利用停止を解く。停止の記録が無ければ何もしない。
 * @param {{ db: FirebaseFirestore.Firestore, deletion: { unsuspendSoratomoUser: Function } }} deps
 * @param {{ uid: string }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdUnsuspend(deps, { uid }) {
  const snap = await deps.db.collection(USERS).doc(uid).get();
  if (!snap.exists || !core.isSuspended(snap.get("suspendedAt"))) {
    return { lines: [`uid: ${uid}`, "停止の記録が無い（何もしていない）"], exitCode: 0 };
  }
  await deps.deletion.unsuspendSoratomoUser(deps.db, { uid });
  return { lines: [`uid: ${uid}`, "利用停止を解いた（消した投稿と所属は戻らない）"], exitCode: 0 };
}

/**
 * list-unforwarded（要件7.5）: 転送の状態が未送信の通報を、受け付けた時刻の古い順に並べる。
 * 状態の単一項目のクエリなので、複合インデックスは要らない（functions/soratomo.js の仕事Bと同じ）。
 * @param {{ db: FirebaseFirestore.Firestore }} deps
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdListUnforwarded({ db }) {
  const snap = await db.collection(REPORTS).where("forwardStatus", "==", "pending").get();
  const docs = [...snap.docs].sort((a, b) => millisForSort(a.get("createdAt")) - millisForSort(b.get("createdAt")));
  const lines = [`未送信の通報: ${docs.length} 件`];
  for (const doc of docs) {
    lines.push(
      `  ${shown(doc.id, isReportId)}  失敗の回数: ${shown(doc.get("forwardAttempts"), Number.isInteger)}` +
        `  受け付けた時刻: ${isoOf(doc.get("createdAt"))}`
    );
  }
  if (docs.length > 0) lines.push("中身を見るには: show-report <reportId>（再送は定期実行が6時間ごとに行う）");
  return { lines, exitCode: 0 };
}

/** コマンド名 → 処理。 */
const COMMANDS = Object.freeze({
  "find-orphans": cmdFindOrphans,
  "delete-user": cmdDeleteUser,
  "show-report": cmdShowReport,
  "review-report": cmdReviewReport,
  "delete-sky": cmdDeleteSky,
  suspend: cmdSuspend,
  unsuspend: cmdUnsuspend,
  "list-unforwarded": cmdListUnforwarded,
});

/**
 * 解釈済みの引数で、コマンドを1つ実行する。
 * @param {Object} deps
 * @param {{ ok: true, command: string }} parsed
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
function run(deps, parsed) {
  return COMMANDS[parsed.command](deps, parsed);
}

// MARK: - 本体

/**
 * エミュレーターを指す環境変数（名前が _EMULATOR_HOST で終わり、値が空でないもの）の名前を並べる。
 * @param {Record<string, string|undefined>} env
 * @returns {string[]} 名前の昇順
 */
function findEmulatorEnv(env) {
  return Object.keys(env)
    .filter((name) => name.endsWith("_EMULATOR_HOST") && env[name])
    .sort();
}

/**
 * 本体。firebase-admin と共通の削除のモジュールはここでだけ読み込む。
 * @param {string[]} argv
 */
async function main(argv) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    console.error(USAGE);
    process.exitCode = 2;
    return;
  }
  const emulatorEnv = findEmulatorEnv(process.env);
  if (emulatorEnv.length > 0) {
    // 値（ホストとポート）は出さず、名前だけ
    console.error(`❌ エミュレーターを指す環境変数があるので止めた（本番専用のスクリプト。外してから実行する）: ${emulatorEnv.join(" ")}`);
    process.exitCode = 1;
    return;
  }

  const { initializeApp, applicationDefault } = functionsRequire("firebase-admin/app");
  const { getFirestore, FieldValue } = functionsRequire("firebase-admin/firestore");
  const { getAuth } = functionsRequire("firebase-admin/auth");
  const { getStorage } = functionsRequire("firebase-admin/storage");
  const deletion = require("../functions/soratomoDeletion");
  const { createStorageGateway } = require("../functions/soratomoStorage");

  const app = initializeApp({ credential: applicationDefault(), projectId: EXPECTED_PROJECT_ID });
  const deps = {
    db: getFirestore(app),
    auth: getAuth(app),
    storage: createStorageGateway(getStorage(app).bucket(EXPECTED_BUCKET)),
    deletion,
    nowMs: Date.now,
    serverTimestamp: () => FieldValue.serverTimestamp(),
  };

  console.log(`🔌 接続先 Firebase プロジェクト: ${EXPECTED_PROJECT_ID}`);
  const { lines, exitCode } = await run(deps, parsed);
  for (const line of lines) console.log(line);
  process.exitCode = exitCode;
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((err) => {
    // エラーの本文（資格情報のパスなど）をそのまま出さず、code（無ければ名前）だけにする。
    console.error(`❌ 失敗しました: ${(err && (err.code || err.name)) || "不明なエラー"}`);
    process.exitCode = 1;
  });
}

module.exports = {
  EXPECTED_PROJECT_ID,
  EXPECTED_BUCKET,
  DELETE_BUDGET_MS,
  REVIEW_RESULTS,
  isUid,
  isPrintableId,
  isReportId,
  isoOf,
  parseArgs,
  formatTotals,
  lookupAccount,
  cmdFindOrphans,
  cmdDeleteUser,
  cmdShowReport,
  cmdReviewReport,
  cmdDeleteSky,
  cmdSuspend,
  cmdUnsuspend,
  cmdListUnforwarded,
  run,
  findEmulatorEnv,
  functionsRequire,
  main,
};
