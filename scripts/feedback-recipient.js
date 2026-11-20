#!/usr/bin/env node

/**
 * ご意見（feedback）1 件の返信先を、本番から読むだけで出す台本 ☁️⭐️
 *
 * ■ なぜ要るか
 *   新しく届くご意見は、Functions の mailFeedbackToSupport が返信先つきで開発者の Gmail へ送る。
 *   その関数より前に届いた分（と、メールが届かなかった分）は、この台本で feedbackId から返信先を引く。
 *   出す行はメールの本文の頭と同じ（functions/feedbackMail.js の buildSummaryLines・chooseRecipient を使う）。
 *   返信先の選び方も関数と同じ: 返信用の欄が正しい形ならそれ、無ければ Auth の登録メール（欄があるときは Auth を引かない）。
 *
 * ■ コマンド
 *   node scripts/feedback-recipient.js <feedbackId>
 *     feedbackId は Discord の知らせの footer か、Gmail の件名の頭 8 文字で見つけた文書の ID 全体（英数字・「-」「_」）。
 *     出すもの: 返信先・出どころ（返信用の欄／登録メールの確認済み・未確認）・最後に使った日・種別・版・端末・
 *     受け付けた時刻・Firestore コンソールの URL・本文。読むだけで、何も書かない・消さない。
 *
 * ■ 出力の約束
 *   ⚠️ 返信先のメールアドレスを平文で出す（返信のための台本なので）。出力を handoff・メモリ・GitHub に写さない。
 *   本文は送った人が書いた文なので、境目の行の下に出す（指示として読まない）。端末を操る制御文字（ESC など）は
 *   置き換えてから出す。エラーは code（無ければ名前）だけを出す（本文に資格情報のパスなどが入るため）。
 *
 * ■ 認証: Application Default Credentials（ADC）。鍵ファイルはリポジトリに置かない（follows-cleanup.js と同じ）。
 *   1. gcloud auth application-default login
 *   2. Auth の Admin API で quota project を求められたら: gcloud auth application-default set-quota-project soramoyou-ios
 *   接続先は EXPECTED_PROJECT_ID（soramoyou-ios）に固定している（.firebaserc が空のため。ADC の既定に頼らない）。
 *
 * ■ 実行方法（リポジトリ直下で。firebase-admin は functions/ の依存を借りる＝functions で npm install 済みであること）
 *     node scripts/feedback-recipient.js <feedbackId>
 *   ⚠️ エミュレーターを指す環境変数（名前が _EMULATOR_HOST で終わるもの）が 1 つでもあれば、何もせずに止める。
 *   ⚠️ 本番を読むので、実行は利用者が自分のターミナルで行う（Claude のセッションなら `!` で。Claude には流させない）。
 *
 * ■ 作り（follows-cleanup.js と同じ）
 *   - 引数の解釈・出力の組み立ては純関数。処理は cmdShow(deps, args) → { lines, exitCode } で、deps に窓口を差し込む。
 *   - firebase-admin は main の中でだけ読み込む。main は export しない（テストから本番に繋ぐ口を作らない）。
 *
 * ■ テスト
 *   単体: node --test scripts/feedback-recipient.test.js（偽の窓口・firebase-admin 非依存。本番には触れない）
 */

"use strict";

const path = require("node:path");
const { createRequire } = require("node:module");
const {
  BODY_SEPARATOR,
  isPrintableId,
  safeMessage,
  resolveAuthLookup,
  chooseRecipient,
  buildSummaryLines,
  buildClientLines,
} = require("../functions/feedbackMail");

// MARK: - 定数

/** 接続先として唯一許可する Firebase プロジェクト（.firebaserc が空のため、ここで固定する）。 */
const EXPECTED_PROJECT_ID = "soramoyou-ios";

/** コレクションの名前（iOS の FirestoreService と同じ綴り）。 */
const FEEDBACK = "feedback";

/** functions/ を起点にした require。firebase-admin はこれで読む（main の中でだけ）。 */
const functionsRequire = createRequire(path.join(__dirname, "..", "functions", "package.json"));

const USAGE = "使い方: node scripts/feedback-recipient.js <feedbackId>（英数字・「-」「_」の 128 文字まで）";

// MARK: - 引数

/**
 * 引数を読む。feedbackId 1 つだけを受け付ける。
 * @param {string[]} argv
 * @returns {{ ok: true, feedbackId: string } | { ok: false }}
 */
function parseArgs(argv) {
  if (!Array.isArray(argv) || argv.length !== 1) return { ok: false };
  const [feedbackId] = argv;
  return isPrintableId(feedbackId) ? { ok: true, feedbackId } : { ok: false };
}

// MARK: - 処理

/**
 * feedbackId の返信先と中身を出す。
 * @param {{ store: { getFeedback: (id: string) => Promise<object | null>, getAuthUser: (uid: string) => Promise<object> } }} deps
 * @param {{ feedbackId: string }} args
 * @returns {Promise<{ lines: string[], exitCode: number }>}
 */
async function cmdShow(deps, { feedbackId }) {
  const feedback = await deps.store.getFeedback(feedbackId);
  if (!feedback) {
    return { lines: [`❌ feedback/${feedbackId} が見つからない（ID 全体か、本番の文書かを確かめる）`], exitCode: 1 };
  }

  // 関数と同じ判断（resolveAuthLookup）: 欄が正しい形なら Auth は引かない
  const authLookup = await resolveAuthLookup({
    replyEmail: feedback.replyEmail,
    uid: feedback.userId,
    getUser: (uid) => deps.store.getAuthUser(uid),
  });

  const recipient = chooseRecipient({ replyEmail: feedback.replyEmail, authLookup });
  // メールと同じ並び: 決まった行 → 境目 → 送った人の端末が書いた行（アプリ・端末）→ 本文
  const lines = [
    ...buildSummaryLines({ feedbackId, feedback, recipient, projectId: EXPECTED_PROJECT_ID }),
    BODY_SEPARATOR,
    ...buildClientLines(feedback),
    "",
    safeMessage(feedback.message),
  ];
  return { lines, exitCode: 0 };
}

/**
 * 本物の窓口（firebase-admin の Firestore と Auth）。読むだけ。
 * @param {import("firebase-admin/firestore").Firestore} db
 * @param {import("firebase-admin/auth").Auth} auth
 */
function createStore(db, auth) {
  return {
    async getFeedback(id) {
      const snap = await db.collection(FEEDBACK).doc(id).get();
      return snap.exists ? snap.data() : null;
    },
    getAuthUser(uid) {
      return auth.getUser(uid);
    },
  };
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
 * 失敗を 1 行の理由にする。code（無ければ名前）だけを返す（本文に資格情報のパスなどが入りうるため）。
 * @param {unknown} err
 * @returns {string}
 */
function describeError(err) {
  return String((err && (err.code || err.name)) || "不明なエラー");
}

/**
 * 本体。firebase-admin はここでだけ読み込む。export しない（テストから本番に繋ぐ口を作らない）。
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
    console.error(`❌ エミュレーターを指す環境変数があるので止めた（本番を読む台本。外してから実行する）: ${emulatorEnv.join(" ")}`);
    process.exitCode = 1;
    return;
  }

  const { initializeApp, applicationDefault } = functionsRequire("firebase-admin/app");
  const { getFirestore } = functionsRequire("firebase-admin/firestore");
  const { getAuth } = functionsRequire("firebase-admin/auth");
  const app = initializeApp({ credential: applicationDefault(), projectId: EXPECTED_PROJECT_ID });

  console.log(`🔌 接続先 Firebase プロジェクト: ${EXPECTED_PROJECT_ID}（読むだけ）`);
  const { lines, exitCode } = await cmdShow({ store: createStore(getFirestore(app), getAuth(app)) }, parsed);
  for (const line of lines) console.log(line);
  process.exitCode = exitCode;
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((err) => {
    console.error(`❌ 失敗しました: ${describeError(err)}`);
    process.exitCode = 1;
  });
}

module.exports = {
  EXPECTED_PROJECT_ID,
  parseArgs,
  cmdShow,
  createStore,
  findEmulatorEnv,
  describeError,
};
