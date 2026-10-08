//
// そらもよう Cloud Functions — 「そらとも」のNGワードの語のリストを読む（キャッシュつき）⭐️☁️
//
// 語のリストは Firestore の soratomoConfig/ngWords の words（文字列の配列）に置く（release-gate 要件11.10）。
// ルールは読み書きとも拒否なので、読めるのは Admin SDK（Functions と投入スクリプト）だけ。
// 関数のインスタンスごとに5分キャッシュし、アプリの新しい版を出さずに語を変えられるようにする（要件11.11）。
// 照合（正規化と部分一致）は soratomoCore.js の純関数（prepareNgWords・containsNgWord）が行う。
//
// 読めなかったときの決まり（design.md の「ユーザーの判断が要る点」・2026-10-08 に利用者が決定）:
// - 一度でも読めていれば、読み直しの失敗では古いリストで検査を続け、警告をログに出す。
// - 一度も読めていない（文書が無い・壊れているを含む）なら、検査を飛ばさずに失敗として返す
//   （作成と投稿は internal で止まる。可用性より、検査を黙って止めないことを取る）。
// - 空の配列は「語が無い」として通す（文書が無いのとは区別する）。
//
// ⚠️ 語の中身は、ログ・応答・エラーのどこにも出さない（要件11.9・14.2）。ログは件数と経過時間だけ。
//    照合の結果も真偽値だけで、どの語に該当したかは返さない。
// ⚠️ テストは soratomoNgWords.test.js（Firestore のエミュレーター・ダミーの語だけ）。
//

"use strict";

const defaultLogger = require("firebase-functions/logger");
const core = require("./soratomoCore");

/** 語のリストの文書（soratomoConfig/ngWords）。 */
const NG_WORDS_COLLECTION = "soratomoConfig";
const NG_WORDS_DOC = "ngWords";
/** 語のリストのキャッシュの長さ（5分・要件11.11）。 */
const NG_WORDS_TTL_MS = 5 * 60 * 1000;

/** 語のリストを一度も読めていないときの失敗。配線（soratomo.js）は internal に写す（理由を利用者に返さない）。 */
class NgWordsUnavailableError extends Error {
  /** @param {"missing"|"malformed"|"read_failed"} kind 読めなかった理由（ログ用。語は含まない） */
  constructor(kind) {
    super(`soratomo: NGワードの語のリストを読めない（${kind}）`);
    this.name = "NgWordsUnavailableError";
    this.kind = kind;
  }
}

/**
 * 語のリストの提供口を作る。関数のインスタンスごとに1つ作って使い回す（キャッシュはこの中に持つ）。
 * @param {{ db: FirebaseFirestore.Firestore, ttlMs?: number, nowMs?: () => number,
 *   logger?: { info: Function, warn: Function, error: Function } }} deps
 *   nowMs と logger はテストでだけ差し替える
 * @returns {{ matcher(): Promise<(text: unknown) => boolean> }} 一度も読めていなければ matcher() が
 *   NgWordsUnavailableError で失敗する
 */
function createNgWordProvider({ db, ttlMs = NG_WORDS_TTL_MS, nowMs = Date.now, logger = defaultLogger }) {
  /** 読めたリスト（正規化済み）と読めた時刻。一度も読めていなければ null。 */
  let cache = null;
  /** 読み込み中の Promise。同時の呼び出しで、読み込みを1回にまとめる。 */
  let inflight = null;

  /** 文書を読んで cache を新しくする。読めなければ投げる。 */
  async function load() {
    const startedMs = nowMs();
    let snap;
    try {
      snap = await db.collection(NG_WORDS_COLLECTION).doc(NG_WORDS_DOC).get();
    } catch (err) {
      throw Object.assign(new NgWordsUnavailableError("read_failed"), { errorName: err && err.name, errorCode: err && err.code });
    }
    if (!snap.exists) throw new NgWordsUnavailableError("missing");
    const raw = snap.get("words");
    if (!Array.isArray(raw)) throw new NgWordsUnavailableError("malformed");
    // 要素に文字列でないものが混ざる・空でないのに使える語が0個（空・空白だけ）も壊れた文書として扱う。
    // prepareNgWords はそれらを黙って落とすので、ここで止めないと検査が弱まるか、空のリストで全部通ってしまう
    // （確かめられないときは閉じる・レビュー #11）。空の配列だけは「語が無い」として通す
    if (!raw.every((word) => typeof word === "string")) throw new NgWordsUnavailableError("malformed");
    const words = core.prepareNgWords(raw);
    if (raw.length > 0 && words.length === 0) throw new NgWordsUnavailableError("malformed");
    cache = { words, loadedAtMs: nowMs() };
    logger.info("soratomoNgWords: loaded", { count: words.length, elapsedMs: nowMs() - startedMs });
  }

  /**
   * 読み直す。失敗したら、読めたリストがあれば警告だけで古いリストを残し、無ければ失敗を投げる。
   * 古いリストの時刻は新しくしない（次の呼び出しでまた読み直しを試みる）。
   */
  async function refresh() {
    try {
      await load();
    } catch (err) {
      const fields = { kind: err.kind, errorName: err.errorName, errorCode: err.errorCode };
      if (cache) {
        logger.warn("soratomoNgWords: stale", { ageMs: nowMs() - cache.loadedAtMs, ...fields });
        return;
      }
      logger.error("soratomoNgWords: unavailable", fields);
      // 想定外の例外も同じ型にそろえ、配線が internal に写せるようにする（検査を飛ばさない）
      throw err instanceof NgWordsUnavailableError ? err : new NgWordsUnavailableError("read_failed");
    }
  }

  return {
    async matcher() {
      if (!cache || nowMs() - cache.loadedAtMs >= ttlMs) {
        if (!inflight) {
          inflight = refresh().finally(() => {
            inflight = null;
          });
        }
        await inflight;
      }
      // 読み込みが成功で終われば cache はある。無いなら、検査を飛ばさずに失敗にする（念のための柵）
      if (!cache) throw new NgWordsUnavailableError("missing");
      const { words } = cache;
      return (text) => core.containsNgWord(text, words);
    },
  };
}

module.exports = {
  NG_WORDS_COLLECTION,
  NG_WORDS_DOC,
  NG_WORDS_TTL_MS,
  NgWordsUnavailableError,
  createNgWordProvider,
};
