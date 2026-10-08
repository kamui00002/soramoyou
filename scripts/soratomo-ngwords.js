#!/usr/bin/env node

/**
 * そらともの NG ワードの語のリストを、Firestore の soratomoConfig/ngWords に書くスクリプト ☁️⭐️
 * spec: .kiro/specs/soratomo-release-gate/（tasks.md 6.2・design.md「運用: 管理スクリプト」・要件11.10・11.11）
 *
 * アプリの新しい版を出さずに語を変えるための入口（要件11.11）。Functions は関数のインスタンスごとに5分キャッシュするので、
 * 書いてから最大5分で効く（functions/soratomoNgWords.js）。
 *
 * ■ 語のファイル
 *   1行1語の UTF-8 のテキスト。前後の空白（全角の空白を含む）を除き、空行と「#」で始まる行を飛ばし、重複を除く。
 *   UTF-8 として正しくないバイト列（Shift_JIS・BOM つきの UTF-16 など）は、置換文字に置き換えずに拒否する
 *   （置き換えて読むと、文字化けした語が検査を通って書かれ、元の語に一致しないまま「書いた」と出るため）。
 *   ⚠️ 語のファイルはリポジトリに置かない（要件11.10・公開リポジトリの閲覧者に読ませない）。
 *      このスクリプトは、実体のパス（シンボリックリンクをたどった先）が、このリポジトリの中か、Git の作業ツリーの中
 *      （祖先のどこかに .git がある）なら拒否する。worktree の外の本体の checkout に置いたファイルも拒否する。
 *
 * ■ 書かずに止める場合（どれも語の中身は出さない）
 *   - 語が0個（空のリストを書くと、検査が実質止まるため。空にしたいときはコンソールで行う）
 *   - 語のファイルが UTF-8 として正しくない（上の「語のファイル」）
 *   - 照合に使えない語がある（正規化すると空白だけになる語と、置換文字 U+FFFD・制御文字を含む文字化けした語）。
 *     提供口（functions/soratomoNgWords.js）は、使えない語を黙って落とすので、書いたつもりの語が効かない。
 *     全部が使えない語なら、文書全体を壊れたものと扱い、作成と投稿が止まる。どちらも書く前に止める
 *   - 5,000語を超える
 *
 * ■ 出力: 件数だけ（読んだ行・空行・コメント・重複・書いた語の数）。語の中身は、画面・ログ・エラーのどこにも出さない
 *   （要件11.9・14.2）。エラーは code（無ければ名前）だけ。
 *
 * ■ 認証: Application Default Credentials（ADC）。鍵ファイルはリポジトリに置かない（scripts/soratomo-admin.js と同じ）。
 *   接続先は EXPECTED_PROJECT_ID（soramoyou-ios）に固定している。
 *
 * ■ 実行方法（リポジトリ直下で）
 *   firebase-admin は functions/ の依存を、functions/ を起点に解決する（functions で npm install 済みであること。NODE_PATH は要らない）。
 *     node scripts/soratomo-ngwords.js <語のファイル> --dry-run      # 数えるだけ（Firestore に触れない）
 *     node scripts/soratomo-ngwords.js <語のファイル>                # 書いて読み返す
 *   ⚠️ 書く前に、エミュレーターを指す環境変数（名前が _EMULATOR_HOST で終わるもの）が1つでもあれば止める
 *      （本番専用のスクリプト。scripts/soratomo-admin.js と同じ柵。--dry-run は Firestore に触れないので止めない）。
 *   ⚠️ 本番への投入は tasks 14.2 で、利用者の GO を取ってから行う。
 *
 * ■ テスト: node --test scripts/soratomo-ngwords.test.js（firebase-admin 非依存。本番には触れない。語はダミーだけ）
 */

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
const core = require("../functions/soratomoCore");

// MARK: - 定数

/** 書き込み先として唯一許可する Firebase プロジェクト（.firebaserc が空のため、ここで固定する）。 */
const EXPECTED_PROJECT_ID = "soramoyou-ios";
/** 語の数の上限（design.md の 5,000語）。 */
const MAX_WORDS = 5000;
/** このスクリプトのリポジトリの根（scripts/ の1つ上）。 */
const REPOSITORY_ROOT = path.resolve(__dirname, "..");
/** functions/ を起点にした require。firebase-admin はこれで読む（main の中でだけ。NODE_PATH に頼らない）。 */
const functionsRequire = createRequire(path.join(REPOSITORY_ROOT, "functions", "package.json"));

const USAGE = "使い方: node scripts/soratomo-ngwords.js <語のファイル> [--dry-run]";

// MARK: - 引数

/**
 * コマンドラインの引数を読む。語のファイルはちょうど1つ、オプションは --dry-run だけ。
 * @param {string[]} argv process.argv.slice(2)
 * @returns {{ ok: true, file: string, dryRun: boolean } | { ok: false }}
 */
function parseArgs(argv) {
  const dryRun = argv.includes("--dry-run");
  const rest = argv.filter((a) => a !== "--dry-run");
  if (rest.length !== 1 || rest[0] === "" || rest[0].startsWith("-")) return { ok: false };
  return { ok: true, file: rest[0], dryRun };
}

// MARK: - パスの検査

/**
 * 語のファイルが、リポジトリと Git の作業ツリーの外にあるかを、実体のパスで確かめる（要件11.10）。
 * - シンボリックリンク（ファイル・途中のディレクトリとも）をたどった先で比べる。リンクで外に見せかけても抜けられない
 * - このリポジトリの根の中か、祖先のどこかに .git（ディレクトリでも、worktree のファイルでも）があれば拒否する
 * @param {string} file 語のファイルのパス
 * @param {{ repositoryRoot?: string }} [options] テストでだけ根を差し替える
 * @returns {{ ok: true, realPath: string } | { ok: false, reason: "not_found"|"not_file"|"inside_repository" }}
 */
function checkWordFilePath(file, { repositoryRoot = REPOSITORY_ROOT } = {}) {
  let realPath;
  try {
    realPath = fs.realpathSync(file);
  } catch (_err) {
    return { ok: false, reason: "not_found" };
  }
  if (!fs.statSync(realPath).isFile()) return { ok: false, reason: "not_file" };

  const realRoot = fs.realpathSync(repositoryRoot);
  if (realPath === realRoot || realPath.startsWith(realRoot + path.sep)) return { ok: false, reason: "inside_repository" };
  for (let dir = path.dirname(realPath); ; dir = path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, ".git"))) return { ok: false, reason: "inside_repository" };
    if (path.dirname(dir) === dir) break;
  }
  return { ok: true, realPath };
}

// MARK: - 語のファイルの読み方

/** 文字化けの名残り（置換文字 U+FFFD・C0 と C1 の制御文字・DEL）。行の前後のタブは trim で除いた後に見る。 */
const GARBLED = /[\u0000-\u001F\u007F-\u009F\uFFFD]/;

/**
 * 語のファイルを UTF-8 として厳密に読む。正しくないバイト列は置換文字に置き換えずに拒否する。
 * 先頭の BOM は TextDecoder が除く。
 * @param {string} file 語のファイルの実体のパス（checkWordFilePath の realPath）
 * @returns {{ ok: true, text: string } | { ok: false, reason: "not_utf8" }}
 */
function readWordFile(file) {
  const bytes = fs.readFileSync(file);
  try {
    return { ok: true, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) };
  } catch (_err) {
    return { ok: false, reason: "not_utf8" };
  }
}

/**
 * 語のファイルの本文を、書く語の配列にする。前後の空白を除き、空行・「#」で始まる行を飛ばし、重複を除く（最初の1つを残す）。
 * @param {string} text
 * @returns {{ words: string[], stats: { lines: number, blank: number, comments: number, duplicates: number } }}
 */
function parseWordList(text) {
  const stats = { lines: 0, blank: 0, comments: 0, duplicates: 0 };
  const seen = new Set();
  const words = [];
  for (const line of text.split(/\r\n|\r|\n/)) {
    stats.lines += 1;
    const word = line.trim();
    if (word === "") {
      stats.blank += 1;
    } else if (word.startsWith("#")) {
      stats.comments += 1;
    } else if (seen.has(word)) {
      stats.duplicates += 1;
    } else {
      seen.add(word);
      words.push(word);
    }
  }
  return { words, stats };
}

/**
 * 書いてよい語のリストかを確かめる。だめなら理由を返す（語の中身は返さない）。
 * - empty: 語が0個 / unusable: 正規化すると空白だけになる語か、文字化けした語（置換文字・制御文字を含む）がある
 *   （数を返す） / too_many: 5,000語を超える
 * @param {string[]} words parseWordList の words
 * @returns {{ ok: true, matchable: number } | { ok: false, reason: "empty"|"unusable"|"too_many", count: number }}
 *   matchable は、正規化して重複を除いた後の、照合に使える語の数（提供口と同じ prepareNgWords で数える）
 */
function validateWordList(words) {
  if (words.length === 0) return { ok: false, reason: "empty", count: 0 };
  if (words.length > MAX_WORDS) return { ok: false, reason: "too_many", count: words.length };
  const unusable = words.filter((word) => GARBLED.test(word) || core.prepareNgWords([word]).length === 0).length;
  if (unusable > 0) return { ok: false, reason: "unusable", count: unusable };
  return { ok: true, matchable: core.prepareNgWords(words).length };
}

/** 止めた理由を、件数だけの1行にする。 */
function describeRejection(result) {
  switch (result.reason) {
    case "not_found":
      return "❌ 語のファイルが見つからない";
    case "not_file":
      return "❌ 語のファイルがふつうのファイルでない";
    case "inside_repository":
      return "❌ 語のファイルがリポジトリか Git の作業ツリーの中にある（外に置く。シンボリックリンクの先も見ている）";
    case "not_utf8":
      return "❌ 語のファイルが UTF-8 として正しくない（Shift_JIS や UTF-16 なら UTF-8 で保存し直す）";
    case "empty":
      return "❌ 語が0個（空のリストは書かない）";
    case "unusable":
      return `❌ 照合に使えない語（正規化すると空白だけになる語・置換文字や制御文字を含む語）が ${result.count} 個ある`;
    case "too_many":
      return `❌ 語が ${result.count} 個で、上限の ${MAX_WORDS} を超える`;
    default:
      return "❌ 書けない";
  }
}

/**
 * 読んだ結果の件数の行（語の中身は含まない）。
 * @param {{ lines: number, blank: number, comments: number, duplicates: number }} stats
 * @param {number} wordCount
 * @returns {string}
 */
function formatStats(stats, wordCount) {
  return `読んだ行: ${stats.lines}・空行: ${stats.blank}・コメント: ${stats.comments}・重複: ${stats.duplicates}・語: ${wordCount}`;
}

// MARK: - 本体

/**
 * エミュレーターを指す環境変数（名前が _EMULATOR_HOST で終わり、値が空でないもの）の名前を並べる
 * （scripts/soratomo-admin.js の findEmulatorEnv と同じ）。
 * @param {Record<string, string|undefined>} env
 * @returns {string[]} 名前の昇順
 */
function findEmulatorEnv(env) {
  return Object.keys(env)
    .filter((name) => name.endsWith("_EMULATOR_HOST") && env[name])
    .sort();
}

/**
 * 本体。firebase-admin はここでだけ読み込む（テストと --dry-run に依存を持ち込まないため）。
 * @param {string[]} argv
 */
async function main(argv) {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    console.error(USAGE);
    process.exitCode = 2;
    return;
  }

  const location = checkWordFilePath(parsed.file);
  if (!location.ok) {
    console.error(describeRejection(location));
    process.exitCode = 1;
    return;
  }
  const file = readWordFile(location.realPath);
  if (!file.ok) {
    console.error(describeRejection(file));
    process.exitCode = 1;
    return;
  }
  const { words, stats } = parseWordList(file.text);
  console.log(formatStats(stats, words.length));
  const validation = validateWordList(words);
  if (!validation.ok) {
    console.error(describeRejection(validation));
    process.exitCode = 1;
    return;
  }
  console.log(`照合に使える語（正規化して重複を除いた後）: ${validation.matchable}`);
  if (parsed.dryRun) {
    console.log("--dry-run: 書いていない");
    return;
  }
  const emulatorEnv = findEmulatorEnv(process.env);
  if (emulatorEnv.length > 0) {
    // 値（ホストとポート）は出さず、名前だけ
    console.error(`❌ エミュレーターを指す環境変数があるので書かずに止めた（本番専用のスクリプト。外してから実行する）: ${emulatorEnv.join(" ")}`);
    process.exitCode = 1;
    return;
  }

  const { initializeApp, applicationDefault } = functionsRequire("firebase-admin/app");
  const { getFirestore, FieldValue } = functionsRequire("firebase-admin/firestore");
  const { NG_WORDS_COLLECTION, NG_WORDS_DOC } = require("../functions/soratomoNgWords");
  const app = initializeApp({ credential: applicationDefault(), projectId: EXPECTED_PROJECT_ID });
  const ref = getFirestore(app).collection(NG_WORDS_COLLECTION).doc(NG_WORDS_DOC);

  console.log(`🔌 接続先 Firebase プロジェクト: ${EXPECTED_PROJECT_ID}`);
  await ref.set({ words, updatedAt: FieldValue.serverTimestamp() });
  const stored = (await ref.get()).get("words");
  const same = Array.isArray(stored) && stored.length === words.length && stored.every((w, i) => w === words[i]);
  if (!same) {
    console.error("❌ 読み返した語のリストが、書いたものと一致しません");
    process.exitCode = 1;
    return;
  }
  console.log(`✅ 書いた語: ${words.length}（読み返して一致。Functions には最大5分で効く）`);
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
  MAX_WORDS,
  REPOSITORY_ROOT,
  parseArgs,
  checkWordFilePath,
  readWordFile,
  parseWordList,
  validateWordList,
  describeRejection,
  formatStats,
  findEmulatorEnv,
  functionsRequire,
  main,
};
