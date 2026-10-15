//
// followBlock.js の単体テスト（node:test = Node標準・新規npm依存なし）⭐️
// firebase-admin/firebase-functions には一切触れない。db は偽物（消した文書のパスを記録するだけ）。
// 本物の Firestore で消えることは followBlock.emulator.test.js で確かめる。
//
// 実行: node --test followBlock.test.js
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const followBlock = require("./followBlock");

// MARK: - 偽物

/**
 * 消した文書を batch ごとに記録する偽物の db。
 * followBlock.js が使う形（collection(名前).doc(ID) と batch().delete / commit）だけを持つ。
 */
function recordingDb() {
  const batches = [];
  return {
    batches,
    collection(name) {
      return { doc: (id) => ({ path: `${name}/${id}` }) };
    },
    batch() {
      const deleted = [];
      return {
        delete(ref) {
          deleted.push(ref.path);
        },
        async commit() {
          batches.push(deleted);
        },
      };
    },
  };
}

/** 触ったら投げる db（「差分が空なら何も読まず・書かずに抜ける」を確かめるため） */
const untouchableDb = new Proxy(
  {},
  {
    get(_target, prop) {
      throw new Error(`差分が空なのに db.${String(prop)} に触った`);
    },
  }
);

/** トリガーの event の形（onDocumentWritten）。data が undefined の側は「文書が無い」 */
function writtenEvent(userId, beforeData, afterData) {
  return {
    params: { userId },
    data: { before: { data: () => beforeData }, after: { data: () => afterData } },
  };
}

// ============================================================
// addedBlockedIds
// ============================================================

test("addedBlockedIds: 新しく増えた相手だけを返す（前からいた相手は返さない）", () => {
  assert.deepEqual(followBlock.addedBlockedIds(["C"], ["C", "B"], "A"), ["B"]);
});

test("addedBlockedIds: 前に項目が無い（users の作成・初めてのブロック）なら、一覧の全員を返す", () => {
  assert.deepEqual(followBlock.addedBlockedIds(undefined, ["B", "C"], "A"), ["B", "C"]);
});

test("addedBlockedIds: 外しただけ（ブロック解除）・並べ替えだけなら空", () => {
  assert.deepEqual(followBlock.addedBlockedIds(["B", "C"], ["C"], "A"), []);
  assert.deepEqual(followBlock.addedBlockedIds(["B", "C"], ["C", "B"], "A"), []);
});

test("addedBlockedIds: 項目が無い・配列でない（数え直しなど、ほかの項目の更新）なら空", () => {
  assert.deepEqual(followBlock.addedBlockedIds(undefined, undefined, "A"), []);
  assert.deepEqual(followBlock.addedBlockedIds(undefined, "B", "A"), []);
  assert.deepEqual(followBlock.addedBlockedIds(["B"], null, "A"), []);
});

test("addedBlockedIds: 自分自身は捨てる（自分のフォローを消さない）", () => {
  assert.deepEqual(followBlock.addedBlockedIds(undefined, ["A", "B"], "A"), ["B"]);
});

test("addedBlockedIds: / を含む・空文字・文字列でない値は捨てる（文書のパスにできない）", () => {
  assert.deepEqual(followBlock.addedBlockedIds(undefined, ["x/y", "", 3, null, "B"], "A"), ["B"]);
});

test("addedBlockedIds: 重複は 1 つにする（同じ文書を 2 回消しに行かない）", () => {
  assert.deepEqual(followBlock.addedBlockedIds(undefined, ["B", "B", "C"], "A"), ["B", "C"]);
});

// ============================================================
// removeFollowsForNewBlocks
// ============================================================

test("removeFollowsForNewBlocks: 差分が空なら db に一度も触らない（数え直しのたびに起きても読まない）", async () => {
  assert.deepEqual(await followBlock.removeFollowsForNewBlocks(untouchableDb, "A", ["B"], ["B"]), []);
});

test("removeFollowsForNewBlocks: 新しくブロックした 1 人との両方向（A_B・B_A）を 1 回の batch で消す", async () => {
  const db = recordingDb();
  await followBlock.removeFollowsForNewBlocks(db, "A", ["C"], ["C", "B"]);
  assert.deepEqual(db.batches, [["follows/A_B", "follows/B_A"]]);
});

test("removeFollowsForNewBlocks: 戻り値は消しに行った文書の ID", async () => {
  const db = recordingDb();
  assert.deepEqual(await followBlock.removeFollowsForNewBlocks(db, "A", ["C"], ["C", "B"]), ["A_B", "B_A"]);
});

test("removeFollowsForNewBlocks: 251 人増えたら batch を 2 回に分け、どれも 500 件以下", async () => {
  const db = recordingDb();
  const added = Array.from({ length: 251 }, (_, i) => `U${i}`);
  await followBlock.removeFollowsForNewBlocks(db, "A", [], added);
  assert.deepEqual(db.batches.map((b) => b.length), [500, 2]);
  assert.equal(followBlock.MAX_PAIRS_PER_BATCH, 250);
});

// ============================================================
// handleUserWritten（トリガーの中身）
// ============================================================

test("handleUserWritten: users の作成（前の文書が無い）で一覧があれば、その相手との両方向を消す", async () => {
  const db = recordingDb();
  await followBlock.handleUserWritten(db, writtenEvent("A", undefined, { blockedUserIds: ["B"] }));
  assert.deepEqual(db.batches, [["follows/A_B", "follows/B_A"]]);
});

// 中の id はパスと違う値にする（users の作成のルールは id と userId の一致を確かめていない。中の id を読む実装を落とすため）
test("handleUserWritten: 更新で増えた相手だけを、パスの userId を持ち主として消す", async () => {
  const db = recordingDb();
  await followBlock.handleUserWritten(
    db,
    writtenEvent("A", { id: "not-A", blockedUserIds: ["C"] }, { id: "not-A", blockedUserIds: ["C", "B"] })
  );
  assert.deepEqual(db.batches, [["follows/A_B", "follows/B_A"]]);
});

test("handleUserWritten: ブロック解除（一覧から減った）なら db に触らない", async () => {
  assert.deepEqual(
    await followBlock.handleUserWritten(
      untouchableDb,
      writtenEvent("A", { blockedUserIds: ["B", "C"] }, { blockedUserIds: ["C"] })
    ),
    []
  );
});

test("handleUserWritten: users の削除（後の文書が無い）なら db に触らない", async () => {
  assert.deepEqual(
    await followBlock.handleUserWritten(untouchableDb, writtenEvent("A", { blockedUserIds: ["B"] }, undefined)),
    []
  );
});
