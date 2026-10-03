//
// pushHelpers.js の単体テスト（sendToTokenGrouped・そらとも用のまとめ指定つき送信）☁️
//
// 実行: node --test pushHelpers.test.js
//
// ⚠️ pushHelpers.js は読み込んだ時点で firebase-admin の getFirestore() / getMessaging() を呼ぶ。
//    既存の行（読み込み時の初期化）は変えずにテストするため、他のテストのような注入（verifierFactory）ではなく、
//    require の前に Module._load を差し替えて、次の 3 つを偽物にしてから読み込む:
//      firebase-admin/firestore・firebase-admin/messaging・firebase-functions/logger
//    偽物は「送ったメッセージ」と「users への update」と「ログ」を記録するだけ。npm install も不要。
//    FCM が実際にこの形を受け付けるか（thread-id・apns-collapse-id の効き目）は、実機の 15.1 で確かめる。
//
// ⚠️ package.json の lint / test への登録は tasks 8.3 でまとめて行う（それまでは単体で実行する）。
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const Module = require("node:module");

// MARK: - 偽物の firebase-admin

/** FieldValue.delete() が返す目印（update に渡されたかを見分ける）。 */
const DELETE_SENTINEL = Object.freeze({ fake: "FieldValue.delete" });

const record = { sent: [], updates: [], logs: [] };
/** messaging.send の振る舞い（テストごとに差し替える）。 */
let sendImpl = async () => "projects/soramoyou-ios/messages/1";
/** users への update の振る舞い（テストごとに差し替える）。 */
let updateImpl = async () => undefined;

const fakeDb = {
  collection: (collection) => ({
    doc: (id) => ({
      update: (payload) => {
        record.updates.push({ collection, id, payload });
        return updateImpl(payload);
      },
      set: () => {
        throw new Error("set は使わない（文書が無いときに作り直してしまうため）");
      },
    }),
  }),
};

const fakes = {
  "firebase-admin/firestore": {
    getFirestore: () => fakeDb,
    FieldValue: { delete: () => DELETE_SENTINEL },
  },
  "firebase-admin/messaging": {
    getMessaging: () => ({
      send: (message) => {
        record.sent.push(message);
        return sendImpl(message);
      },
    }),
  },
  "firebase-functions/logger": {
    info: (...args) => record.logs.push(["info", ...args]),
    warn: (...args) => record.logs.push(["warn", ...args]),
    error: (...args) => record.logs.push(["error", ...args]),
  },
};

const originalLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (Object.prototype.hasOwnProperty.call(fakes, request)) return fakes[request];
  return originalLoad.call(this, request, parent, isMain);
};
const push = require("./pushHelpers");
// 読み込みが終わったら元に戻す（pushHelpers.js は読み込み時に偽物を受け取り済み）。
Module._load = originalLoad;

test.beforeEach(() => {
  record.sent.length = 0;
  record.updates.length = 0;
  record.logs.length = 0;
  sendImpl = async () => "projects/soramoyou-ios/messages/1";
  updateImpl = async () => undefined;
});

// MARK: - テスト用の値

const UID = "recipient-uid";
const TOKEN = "fcm-token-of-recipient";
const NOTIFICATION = { title: "空の会", body: "はるとさんが空を投稿しました" };
const DATA = { type: "soratomoPost", groupId: "g1", postId: "s1" };
const GROUPING = { threadId: "soratomo-g1", collapseId: "soratomo-g1" };

/** ログの引数のどこかにトークンの文字列が入っていないか。 */
function logsContain(text) {
  return JSON.stringify(record.logs).includes(text);
}

// MARK: - 送るメッセージの形

test("sendToTokenGrouped: 送れたら sent を返し、まとめ指定つきの形で1通送る", async () => {
  const outcome = await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING);
  assert.equal(outcome, "sent");
  assert.equal(record.sent.length, 1);
  // 形をまるごと固定する（置き換えキーのヘッダー・スレッドID・既定の音・バッジ無し）。
  assert.deepEqual(record.sent[0], {
    token: TOKEN,
    notification: { title: "空の会", body: "はるとさんが空を投稿しました" },
    data: { type: "soratomoPost", groupId: "g1", postId: "s1" },
    apns: {
      headers: { "apns-collapse-id": "soratomo-g1" },
      payload: { aps: { sound: "default", threadId: "soratomo-g1" } },
    },
  });
  assert.equal(record.updates.length, 0);
});

test("sendToTokenGrouped: バッジを付けない（要件9.12）", async () => {
  await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING);
  assert.ok(!("badge" in record.sent[0].apns.payload.aps), "aps に badge がある");
});

test("sendToTokenGrouped: スレッドIDと置き換えキーは渡された値をそのまま使う", async () => {
  await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, { threadId: "soratomo-gX", collapseId: "soratomo-gY" });
  assert.equal(record.sent[0].apns.payload.aps.threadId, "soratomo-gX");
  assert.equal(record.sent[0].apns.headers["apns-collapse-id"], "soratomo-gY");
});

test("sendToTokenGrouped: データの値はすべて文字列にする・null と undefined の項目は送らない", async () => {
  await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, { a: 1, b: true, c: "x", d: null, e: undefined }, GROUPING);
  assert.deepEqual(record.sent[0].data, { a: "1", b: "true", c: "x" });
});

// MARK: - 結果の分類

test("sendToTokenGrouped: トークンが無ければ送らずに no_token", async () => {
  for (const token of [null, undefined, ""]) {
    assert.equal(await push.sendToTokenGrouped(UID, token, NOTIFICATION, DATA, GROUPING), "no_token");
  }
  assert.equal(record.sent.length, 0);
  assert.equal(record.updates.length, 0);
});

test("sendToTokenGrouped: 無効なトークンなら invalid_token を返し、users/{uid} の fcmToken を update で消す", async () => {
  for (const code of [
    "messaging/registration-token-not-registered",
    "messaging/invalid-registration-token",
    "messaging/invalid-argument",
  ]) {
    record.updates.length = 0;
    sendImpl = async () => {
      throw Object.assign(new Error("invalid"), { code });
    };
    assert.equal(await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING), "invalid_token", code);
    assert.deepEqual(record.updates, [{ collection: "users", id: UID, payload: { fcmToken: DELETE_SENTINEL } }], code);
  }
});

test("sendToTokenGrouped: トークンの掃除が失敗しても例外を投げず invalid_token（文書が無いときも作り直さない）", async () => {
  sendImpl = async () => {
    throw Object.assign(new Error("invalid"), { code: "messaging/registration-token-not-registered" });
  };
  updateImpl = async () => {
    throw Object.assign(new Error("no document"), { code: 5 });
  };
  assert.equal(await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING), "invalid_token");
  assert.ok(record.logs.some(([level]) => level === "warn"), "掃除の失敗が警告として残っていない");
});

test("sendToTokenGrouped: そのほかの送信の失敗は failed を返し、トークンは消さない", async () => {
  sendImpl = async () => {
    throw Object.assign(new Error("unavailable"), { code: "messaging/server-unavailable" });
  };
  assert.equal(await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING), "failed");
  assert.equal(record.updates.length, 0);
  assert.ok(record.logs.some(([level]) => level === "error"), "送信の失敗がエラーとして残っていない");
});

test("sendToTokenGrouped: 送信の関数が同期的に例外を投げても failed で返す（例外を投げない）", async () => {
  sendImpl = () => {
    throw new Error("sync throw");
  };
  assert.equal(await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING), "failed");
});

test("sendToTokenGrouped: 組み立てに失敗する入力（data が null）でも例外を投げない", async () => {
  const outcome = await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, null, GROUPING);
  assert.ok(["sent", "failed"].includes(outcome), `想定外の結果 ${outcome}`);
});

test("sendToTokenGrouped: ログにトークン・通知の文面を出さない（15.2）", async () => {
  sendImpl = async () => {
    throw Object.assign(new Error("unavailable"), { code: "messaging/server-unavailable" });
  };
  await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING);
  sendImpl = async () => {
    throw Object.assign(new Error("invalid"), { code: "messaging/invalid-argument" });
  };
  updateImpl = async () => {
    throw new Error("no document");
  };
  await push.sendToTokenGrouped(UID, TOKEN, NOTIFICATION, DATA, GROUPING);
  assert.ok(record.logs.length >= 2);
  for (const secret of [TOKEN, NOTIFICATION.title, NOTIFICATION.body]) {
    assert.ok(!logsContain(secret), `ログに ${secret} が出ている`);
  }
});

// MARK: - 既存の送信の関数が変わっていないこと

test("既存の sendToToken: 送る形はまとめ指定なし（スレッドID・置き換えキーを持たない）のまま", async () => {
  await push.sendToToken(UID, TOKEN, NOTIFICATION, DATA);
  assert.deepEqual(record.sent[0], {
    token: TOKEN,
    notification: NOTIFICATION,
    data: DATA,
    apns: { payload: { aps: { sound: "default" } } },
  });
});

test("既存の isInvalidTokenError: 判定の規則は変わっていない", () => {
  assert.equal(push.isInvalidTokenError("messaging/registration-token-not-registered"), true);
  assert.equal(push.isInvalidTokenError("messaging/invalid-registration-token"), true);
  assert.equal(push.isInvalidTokenError("messaging/invalid-argument"), true);
  assert.equal(push.isInvalidTokenError("messaging/server-unavailable"), false);
  assert.equal(push.isInvalidTokenError(undefined), false);
});
