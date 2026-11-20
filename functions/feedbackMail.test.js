//
// feedbackMail.js の単体テスト（node:test = Node 標準）。
// firebase-admin / firebase-functions には触れない。nodemailer は送らない形（streamTransport）でだけ使い、
// 実際の SMTP には繋がない（生のメールの形と、SMTP の宛先＝エンベロープを確かめるため）。
//
// 実行: node --test feedbackMail.test.js
//

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const nodemailer = require("nodemailer");

const {
  SUPPORT_ADDRESS,
  BODY_SEPARATOR,
  REPLY_EMAIL_MIN_LENGTH,
  REPLY_EMAIL_MAX_LENGTH,
  REPLY_EMAIL_PATTERN,
  isValidReplyEmail,
  replyFieldState,
  oneLine,
  safeMessage,
  categoryLabel,
  authLookupFound,
  authLookupFromError,
  chooseRecipient,
  resolveAuthLookup,
  buildSummaryLines,
  buildClientLines,
  buildFeedbackMail,
} = require("./feedbackMail");

const PROJECT_ID = "soramoyou-ios";
const FEEDBACK_ID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const UID = "uidAAAAAAAAAAAAAAAAAAAAAAAAA";

// 期待する URL は関数の中の組み立てを使わず、文字そのもので書く（組み立てが壊れたら落ちるように）。
const CONSOLE_FEEDBACK_URL =
  "https://console.firebase.google.com/project/soramoyou-ios/firestore/databases/-default-/data/~2Ffeedback~2FAAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
const CONSOLE_FEEDBACK_LIST_URL =
  "https://console.firebase.google.com/project/soramoyou-ios/firestore/databases/-default-/data/~2Ffeedback";

/** Firestore Timestamp の代わり（toDate だけ持つ）。 */
function fakeTimestamp(iso) {
  return { toDate: () => new Date(iso) };
}

/** 実際の feedback の文書と同じ鍵（iOS の toFirestoreData・Android の feedbackCreate と同じ組）。 */
function baseFeedback(overrides = {}) {
  return {
    userId: UID,
    message: "写真が保存できません",
    category: "bug",
    appVersion: "1.18.5 (124)",
    deviceInfo: "iOS 26.1 / iPhone",
    createdAt: fakeTimestamp("2026-11-20T05:23:45.000Z"), // 日本時間 14:23
    ...overrides,
  };
}

/** 偽の UserRecord（使うのは email・emailVerified・metadata だけ）。 */
function fakeUser(overrides = {}) {
  return {
    uid: UID,
    email: "registered@example.com",
    emailVerified: true,
    metadata: {
      lastSignInTime: "Mon, 10 Nov 2026 01:00:00 GMT",
      lastRefreshTime: "Wed, 19 Nov 2026 22:30:00 GMT", // 日本時間 11/20 07:30
    },
    ...overrides,
  };
}

/** 決まった行（BODY_SEPARATOR より上）だけを取り出す。 */
function headerPart(text) {
  const at = text.indexOf(BODY_SEPARATOR);
  assert.ok(at >= 0, "境目の行が無い");
  return text.slice(0, at);
}

/** 決まった行のうち「名前: 」で始まる行を返す（1 つだけのはず）。 */
function headerLine(text, name) {
  const lines = headerPart(text).split("\n").filter((l) => l.startsWith(`${name}: `));
  assert.equal(lines.length, 1, `決まった行の「${name}」が ${lines.length} 行ある`);
  return lines[0].slice(name.length + 2);
}

/** nodemailer で生のメールを作る（送らない）。 */
async function render(mail) {
  const transport = nodemailer.createTransport({
    streamTransport: true,
    buffer: true,
    newline: "unix",
    disableFileAccess: true,
    disableUrlAccess: true,
  });
  const info = await transport.sendMail(mail);
  const raw = info.message.toString();
  const headerEnd = raw.indexOf("\n\n");
  return { raw, headers: raw.slice(0, headerEnd).split("\n"), envelope: info.envelope };
}

// ============================================================
// 形（isValidReplyEmail）
// ============================================================

test("形: 半角の見える文字だけの「…@….…」は通す（境目の 3 文字・254 文字も）", () => {
  const ok = [
    "sora@example.com",
    "a.b+tag@sub.example.co.jp",
    "x_y-z@example.jp",
    "a@b.c", // いちばん短い形（5 文字）
    `${"a".repeat(64)}@${"b".repeat(185)}.com`, // 254 文字ちょうど
  ];
  assert.equal(ok[4].length, 254);
  for (const v of ok) assert.equal(isValidReplyEmail(v), true, v);
});

test("形: 長さ・@ の数・点の位置が合わないものは断る", () => {
  const ng = [
    "", // 空
    "ab", // 短すぎる
    `${"a".repeat(64)}@${"b".repeat(186)}.com`, // 255 文字
    "sora.example.com", // @ が無い
    "a@@b.c", // @ が 2 つ
    "a@b@c.d", // @ が 2 つ
    "a@b", // @ の後ろに点が無い
    "a@b.", // 点の後ろが無い
    "@b.c", // @ の前が無い
    "a@.c", // @ と点の間が無い
  ];
  assert.equal(ng[2].length, 255);
  for (const v of ng) assert.equal(isValidReplyEmail(v), false, JSON.stringify(v));
});

test("形: 改行・空白・制御文字・全角・見えない文字が 1 つでもあれば断る", () => {
  const ng = [
    "a@b.c\n", // 末尾の改行
    "a\n@b.c",
    "a@b.c\r",
    "a@b.c\r\nBcc: x@y.z", // ヘッダーの差し込みの形
    " a@b.c", // 前後の空白も削らない（Rules は削れない）
    "a@b.c ",
    "a b@c.d",
    "a\t@b.c",
    "a\u000b@b.c", // 垂直タブ（Rules の \s に入らない文字）
    "a\u0000@b.c",
    "a\u007f@b.c",
    "a\u3000@b.c", // 全角の空白
    "ｓｏｒａ@example.com", // 全角の英字
    "sora＠example.com", // 全角の @
    "sora@example．com", // 全角の点
    "a\u00a0@b.c", // ノーブレークスペース
    "a\u200b@b.c", // ゼロ幅スペース
    "a\u202e@b.c", // 文字の向きを変える制御
    "a\u2028@b.c", // 行の区切り
    "a\ufeff@b.c",
    "日本@例え.jp", // 半角以外の文字（2026-11-20 の決定で断る）
  ];
  for (const v of ng) assert.equal(isValidReplyEmail(v), false, JSON.stringify(v));
});

test("形: 文字列でない値は断る", () => {
  for (const v of [undefined, null, 123, true, ["a@b.c"], { address: "a@b.c" }]) {
    assert.equal(isValidReplyEmail(v), false, JSON.stringify(v));
  }
});

test("欄の状態: 項目なし・null は空、形が合えばあり、ほか（\"\" を含む）は形が合わない", () => {
  assert.equal(replyFieldState(undefined), "absent");
  assert.equal(replyFieldState(null), "absent");
  assert.equal(replyFieldState("sora@example.com"), "valid");
  assert.equal(replyFieldState(""), "invalid");
  assert.equal(replyFieldState("sora"), "invalid");
  assert.equal(replyFieldState(123), "invalid");
});

// ============================================================
// 返信先の選び方（chooseRecipient）
// ============================================================

test("選び方: 欄が正しい形なら欄（登録メールは引かない）", () => {
  const r = chooseRecipient({ replyEmail: "reply@example.com", authLookup: { status: "skipped" } });
  assert.equal(r.address, "reply@example.com");
  assert.equal(r.source, "reply_field");
  assert.equal(r.fieldState, "valid");
  assert.equal(r.authStatus, "skipped");
});

test("選び方: 欄が正しい形なら、登録メールを引いてあっても欄を使う", () => {
  const r = chooseRecipient({ replyEmail: "reply@example.com", authLookup: authLookupFound(fakeUser()) });
  assert.equal(r.address, "reply@example.com");
  assert.equal(r.source, "reply_field");
});

test("選び方: 欄が空なら登録メール（確認済みか未確認かも）", () => {
  const verified = chooseRecipient({ replyEmail: undefined, authLookup: authLookupFound(fakeUser()) });
  assert.equal(verified.address, "registered@example.com");
  assert.equal(verified.source, "auth_email");
  assert.equal(verified.emailVerified, true);
  assert.equal(verified.lastUsedAt.toISOString(), "2026-11-19T22:30:00.000Z"); // トークンの更新を優先

  const unverified = chooseRecipient({ replyEmail: null, authLookup: authLookupFound(fakeUser({ emailVerified: false })) });
  assert.equal(unverified.source, "auth_email");
  assert.equal(unverified.emailVerified, false);
});

test("選び方: 欄の形が合わないときは使わず、登録メールに回す", () => {
  const r = chooseRecipient({ replyEmail: "a@b.c\nBcc: x@y.z", authLookup: authLookupFound(fakeUser()) });
  assert.equal(r.address, "registered@example.com");
  assert.equal(r.source, "auth_email");
  assert.equal(r.fieldState, "invalid");
});

test("選び方: どちらも無ければ「なし」と理由", () => {
  const cases = [
    [authLookupFound(fakeUser({ email: undefined })), "no_auth_email"],
    [authLookupFound(fakeUser({ email: "" })), "no_auth_email"],
    [authLookupFound(fakeUser({ email: "a b@c.d" })), "auth_email_invalid"],
    [{ status: "not_found" }, "not_found"],
    [{ status: "error", code: "auth/internal-error" }, "lookup_error"],
    [{ status: "no_uid" }, "no_uid"],
    [{ status: "skipped" }, "not_looked_up"], // 欄が空なのに引いていない＝宛先を推測しない
    [undefined, "not_looked_up"],
  ];
  for (const [authLookup, reason] of cases) {
    const r = chooseRecipient({ replyEmail: undefined, authLookup });
    assert.equal(r.address, null, reason);
    assert.equal(r.source, "none", reason);
    assert.equal(r.noneReason, reason);
  }
});

test("登録メールの引き方: user-not-found は「アカウントが無い」、ほかは形の合う code だけを残す", () => {
  assert.deepEqual(authLookupFromError({ code: "auth/user-not-found", message: "x" }), { status: "not_found" });
  assert.deepEqual(authLookupFromError({ code: "auth/internal-error", message: "秘密の道 /Users/x" }), {
    status: "error",
    code: "auth/internal-error",
  });
  assert.deepEqual(authLookupFromError({ code: "bad code with spaces" }), { status: "error", code: "不明" });
  assert.deepEqual(authLookupFromError(new Error("no code")), { status: "error", code: "不明" });
  assert.deepEqual(authLookupFromError(null), { status: "error", code: "不明" });
});

// ============================================================
// 1 行にする・本文
// ============================================================

test("1 行: 改行・制御文字・見えない文字は空白にして 1 つにまとめ、100 文字で切る", () => {
  assert.equal(oneLine("1.18.5\n返信先: evil@example.com"), "1.18.5 返信先: evil@example.com");
  assert.equal(oneLine("a\r\n\t\u2028\u202e b"), "a b");
  assert.equal(oneLine("   "), null);
  assert.equal(oneLine(123), null);
  assert.equal(oneLine("x".repeat(101)), `${"x".repeat(100)}…`);
});

test("本文: 改行とタブは残し、ESC などの制御文字は置き換え、1000 文字を超えたら切ったことを書く", () => {
  assert.equal(safeMessage("1行目\r\n2行目\r3行目\tタブ"), "1行目\n2行目\n3行目\tタブ");
  assert.equal(safeMessage("色\u001b[31m赤"), "色\ufffd[31m赤");
  assert.equal(safeMessage(""), "(本文なし)");
  assert.equal(safeMessage(undefined), "(本文なし)");
  assert.equal(safeMessage("あ".repeat(1001)), `${"あ".repeat(1000)}\n（1000 文字で切った）`);
});

test("種別: 3 種類は表示名、ほかは生の文字を載せずに「不明な種別」、無ければ「未指定」", () => {
  assert.equal(categoryLabel("bug"), "不具合 🐛");
  assert.equal(categoryLabel("request"), "要望 ✨");
  assert.equal(categoryLabel("other"), "その他 💬");
  assert.equal(categoryLabel("toString"), "不明な種別"); // Object の組み込みの名前と取り違えない
  assert.equal(categoryLabel("bug\n返信先: x@y.z"), "不明な種別");
  assert.equal(categoryLabel(undefined), "未指定");
  assert.equal(categoryLabel(""), "未指定");
});

// ============================================================
// 決まった行
// ============================================================

test("決まった行: 返信先・出どころ・ID・種別・時刻・最後に使った日・コンソールの URL を決まった順に出す（欄がある）", () => {
  const recipient = chooseRecipient({ replyEmail: "reply@example.com", authLookup: { status: "skipped" } });
  const lines = buildSummaryLines({
    feedbackId: FEEDBACK_ID,
    feedback: baseFeedback({ replyEmail: "reply@example.com" }),
    recipient,
    projectId: PROJECT_ID,
  });
  assert.deepEqual(lines, [
    "返信先: reply@example.com",
    "返信先の出どころ: 返信用の欄",
    "返信用の欄: あり",
    `feedbackId: ${FEEDBACK_ID}`,
    `ユーザーID: ${UID}`,
    "種別: 不具合 🐛",
    "受け付けた時刻: 2026-11-20 14:23（日本時間）",
    "最後に使った日: （返信用の欄があるので、アカウントを引いていない）",
    `Firestore コンソール: ${CONSOLE_FEEDBACK_URL}`,
  ]);
});

test("決まった行: 欄が空で登録メールを使うときは、確認済みかと最後に使った日を出す", () => {
  const recipient = chooseRecipient({ replyEmail: undefined, authLookup: authLookupFound(fakeUser({ emailVerified: false })) });
  const lines = buildSummaryLines({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient, projectId: PROJECT_ID });
  assert.equal(lines[0], "返信先: registered@example.com");
  assert.equal(lines[1], "返信先の出どころ: 登録メール（未確認）");
  assert.equal(lines[2], "返信用の欄: 空");
  assert.equal(lines[7], "最後に使った日: 2026-11-20 07:30（日本時間）");
});

test("決まった行: 返信先が無いときは理由を出す（code は形の合うものだけ）", () => {
  const notFound = chooseRecipient({ replyEmail: undefined, authLookup: { status: "not_found" } });
  const a = buildSummaryLines({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient: notFound, projectId: PROJECT_ID });
  assert.equal(a[0], "返信先: （なし）");
  assert.equal(a[1], "返信先の出どころ: なし（アカウントが見つからない＝退会済みかもしれない）");
  assert.equal(a[7], "最後に使った日: （アカウントが無い）");

  const failed = chooseRecipient({ replyEmail: undefined, authLookup: authLookupFromError({ code: "auth/internal-error" }) });
  const b = buildSummaryLines({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient: failed, projectId: PROJECT_ID });
  assert.equal(b[1], "返信先の出どころ: なし（登録メールを引けなかった: auth/internal-error）");
  assert.equal(b[7], "最後に使った日: （引けなかった）");
});

test("決まった行: 形が合わない欄の中身は、どこにも載らない", () => {
  const odd = "evil@example.com\nBcc: other@example.com";
  const recipient = chooseRecipient({ replyEmail: odd, authLookup: authLookupFound(fakeUser()) });
  const text = buildSummaryLines({ feedbackId: FEEDBACK_ID, feedback: baseFeedback({ replyEmail: odd }), recipient, projectId: PROJECT_ID }).join("\n");
  assert.ok(!text.includes("evil@example.com"));
  assert.ok(!text.includes("other@example.com"));
  assert.ok(text.includes("返信用の欄: 形が合わないので使っていない（中身は載せない）"));
});

test("決まった行: ID の形が合わないときは載せずに、コンソールは一覧へ", () => {
  const recipient = chooseRecipient({ replyEmail: "reply@example.com", authLookup: { status: "skipped" } });
  for (const feedbackId of ["a/b", "ID\n返信先: x@y.z", "x".repeat(129)]) {
    const lines = buildSummaryLines({ feedbackId, feedback: baseFeedback({ userId: "u/1" }), recipient, projectId: PROJECT_ID });
    assert.equal(lines[3], "feedbackId: (形が正しくありません)");
    assert.equal(lines[4], "ユーザーID: (形が正しくありません)");
    assert.equal(lines[8], `Firestore コンソール: ${CONSOLE_FEEDBACK_LIST_URL} （ID の形が合わないので一覧）`);
  }
});

test("決まった行: 文書が空でも落ちず、代わりの文字で埋まる", () => {
  const recipient = chooseRecipient({ replyEmail: undefined, authLookup: { status: "no_uid" } });
  for (const feedback of [{}, null, undefined]) {
    const lines = buildSummaryLines({ feedbackId: FEEDBACK_ID, feedback, recipient, projectId: PROJECT_ID });
    assert.equal(lines[4], "ユーザーID: (なし)");
    assert.equal(lines[5], "種別: 未指定");
    assert.equal(lines[6], "受け付けた時刻: （記録に無い）");
    assert.deepEqual(buildClientLines(feedback), ["アプリ: 不明", "端末: 不明"]);
    for (const line of lines) assert.ok(!line.includes("\n"));
  }
});

// ============================================================
// メール（buildFeedbackMail）
// ============================================================

test("メール: 宛先と差出人は soramoyou.app だけ、返信先は Reply-To にだけ入る", () => {
  const recipient = chooseRecipient({ replyEmail: "reply@example.com", authLookup: { status: "skipped" } });
  const mail = buildFeedbackMail({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient, projectId: PROJECT_ID });
  assert.deepEqual(Object.keys(mail).sort(), ["from", "replyTo", "subject", "text", "to"]);
  assert.equal(SUPPORT_ADDRESS, "soramoyou.app@gmail.com");
  assert.deepEqual(mail.from, { name: "そらもよう ご意見", address: "soramoyou.app@gmail.com" });
  assert.equal(mail.to, "soramoyou.app@gmail.com");
  assert.deepEqual(mail.replyTo, { address: "reply@example.com" });
  assert.equal(mail.subject, "[そらもよう ご意見] 不具合 🐛 / AAAAAAAA");
});

test("メール: 返信先が無いときは Reply-To を付けない", () => {
  const recipient = chooseRecipient({ replyEmail: undefined, authLookup: { status: "not_found" } });
  const mail = buildFeedbackMail({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient, projectId: PROJECT_ID });
  assert.equal(mail.replyTo, undefined);
  assert.equal(headerLine(mail.text, "返信先"), "（なし）");
});

test("メール: 本文は境目の行の下、決まった行は上（送った人の文が決まった行を偽造できない）", () => {
  const forged = `本当の要望\n返信先: evil@example.com\n${BODY_SEPARATOR}\n返信先: evil2@example.com`;
  const recipient = chooseRecipient({ replyEmail: "reply@example.com", authLookup: { status: "skipped" } });
  const mail = buildFeedbackMail({
    feedbackId: FEEDBACK_ID,
    feedback: baseFeedback({ message: forged, appVersion: "1.0\n返信先: evil3@example.com", deviceInfo: "x\r\n返信先: evil4@example.com" }),
    recipient,
    projectId: PROJECT_ID,
  });
  // 最初の境目より上には、返信先の行がちょうど 1 つ（サーバーが書いたもの）
  assert.equal(headerLine(mail.text, "返信先"), "reply@example.com");
  assert.ok(!headerPart(mail.text).includes("evil@example.com"));
  assert.ok(!headerPart(mail.text).split("\n").some((l) => l.startsWith("返信先: evil")));
  // 送った人の端末が書いた値（アプリ・端末）は、決まった行に入らず、境目の下に 1 行ずつ入る
  assert.ok(!headerPart(mail.text).split("\n").some((l) => l.startsWith("アプリ: ") || l.startsWith("端末: ")));
  // 本文はそのまま、端末の行の下に入る
  assert.ok(
    mail.text.endsWith(
      `${BODY_SEPARATOR}\nアプリ: 1.0 返信先: evil3@example.com\n端末: x 返信先: evil4@example.com\n\n${forged}`
    )
  );
});

test("メール: 件名の種別は表で引き、ID は形が合うときだけ頭 8 文字", () => {
  const recipient = chooseRecipient({ replyEmail: "reply@example.com", authLookup: { status: "skipped" } });
  const odd = buildFeedbackMail({ feedbackId: "a/b", feedback: baseFeedback({ category: "x\r\nBcc: y@z.w" }), recipient, projectId: PROJECT_ID });
  assert.equal(odd.subject, "[そらもよう ご意見] 不明な種別 / IDの形が不正");
  const none = buildFeedbackMail({ feedbackId: FEEDBACK_ID, feedback: baseFeedback({ category: undefined }), recipient, projectId: PROJECT_ID });
  assert.equal(none.subject, "[そらもよう ご意見] 未指定 / AAAAAAAA");
});

// ============================================================
// nodemailer で作った生のメール（送らない）
// ============================================================

test("生のメール: SMTP の宛先は soramoyou.app だけ、Reply-To は欄のアドレス", async () => {
  const recipient = chooseRecipient({ replyEmail: "reply+tag@example.co.jp", authLookup: { status: "skipped" } });
  const { headers, envelope } = await render(
    buildFeedbackMail({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient, projectId: PROJECT_ID })
  );
  assert.deepEqual(envelope.to, ["soramoyou.app@gmail.com"]);
  assert.equal(envelope.from, "soramoyou.app@gmail.com");
  assert.ok(headers.includes("To: soramoyou.app@gmail.com"), headers.join("\n"));
  assert.ok(headers.includes("Reply-To: reply+tag@example.co.jp"), headers.join("\n"));
  assert.ok(!headers.some((h) => /^(Cc|Bcc):/i.test(h)));
});

test("生のメール: 記号を含むアドレスでも、SMTP の宛先は soramoyou.app だけ（Reply-To は 1 つ）", async () => {
  // 形の確かめを通る記号入りのアドレス。nodemailer は引用符で包むので、決まった行と文字が変わることがある
  //（そのときは runbook の「決まった行と Reply-To が同じときだけ使う」で止まる）。
  for (const address of ["a,b@x.yz", "a;b@x.yz", "a<b@x.yz", '"a"@x.yz', "a(c)b@x.yz"]) {
    assert.equal(isValidReplyEmail(address), true, address);
    const recipient = chooseRecipient({ replyEmail: address, authLookup: { status: "skipped" } });
    const { headers, envelope } = await render(
      buildFeedbackMail({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient, projectId: PROJECT_ID })
    );
    assert.deepEqual(envelope.to, ["soramoyou.app@gmail.com"], address);
    const replyTo = headers.filter((h) => h.startsWith("Reply-To:"));
    assert.equal(replyTo.length, 1, address);
    assert.equal((replyTo[0].match(/@/g) || []).length, 1, `${address} → ${replyTo[0]}`);
    assert.ok(!headers.some((h) => /^(Cc|Bcc):/i.test(h)), address);
  }
});

test("生のメール: 返信先が無いときは Reply-To の行が無い", async () => {
  const recipient = chooseRecipient({ replyEmail: undefined, authLookup: { status: "not_found" } });
  const { headers, envelope } = await render(
    buildFeedbackMail({ feedbackId: FEEDBACK_ID, feedback: baseFeedback(), recipient, projectId: PROJECT_ID })
  );
  assert.deepEqual(envelope.to, ["soramoyou.app@gmail.com"]);
  assert.ok(!headers.some((h) => h.startsWith("Reply-To:")));
});

test("生のメール: nodemailer はドメインを小文字にし、点が続くローカル部を引用符で包む（決まった行とずれる＝手順書で止まる）", async () => {
  // 決まった行は元の文字のまま、Reply-To は nodemailer が書き換える。ずれたら返信に使わない（手順書の約束）。
  // ここが変わったら（nodemailer の版上げなど）、手順書の「ずれる理由」も見直す
  const cases = [
    { address: "Taro@Gmail.COM", replyTo: "Reply-To: Taro@gmail.com" },
    // 引用符で包んだうえで < > でも囲む（2026-11-21 に nodemailer 10.3.1 で実測）
    { address: "taro..hanako@docomo.ne.jp", replyTo: 'Reply-To: <"taro..hanako"@docomo.ne.jp>' },
  ];
  for (const { address, replyTo } of cases) {
    const recipient = chooseRecipient({ replyEmail: address, authLookup: { status: "skipped" } });
    const mail = buildFeedbackMail({ feedbackId: FEEDBACK_ID, feedback: baseFeedback({ replyEmail: address }), recipient, projectId: PROJECT_ID });
    assert.equal(headerLine(mail.text, "返信先"), address);
    const { headers, envelope } = await render(mail);
    assert.deepEqual(headers.filter((h) => h.startsWith("Reply-To:")), [replyTo]);
    assert.notEqual(replyTo, `Reply-To: ${address}`);
    assert.deepEqual(envelope.to, ["soramoyou.app@gmail.com"]);
  }
});

// ============================================================
// 登録メールの引き方（resolveAuthLookup。関数と台本が同じものを使う）
// ============================================================

/** 呼ばれた uid を覚える偽の getUser。 */
function fakeGetUser(result) {
  const calls = [];
  const getUser = async (uid) => {
    calls.push(uid);
    if (result instanceof Error) throw result;
    return result;
  };
  return { calls, getUser };
}

test("引き方: 欄が正しい形なら Auth を呼ばない（skipped）", async () => {
  const { calls, getUser } = fakeGetUser(fakeUser());
  assert.deepEqual(await resolveAuthLookup({ replyEmail: "reply@example.com", uid: UID, getUser }), { status: "skipped" });
  assert.deepEqual(calls, []);
});

test("引き方: 欄が空か形が合わないときだけ、その uid で Auth を呼ぶ", async () => {
  for (const replyEmail of [undefined, null, "", "bad\n@example.com"]) {
    const { calls, getUser } = fakeGetUser(fakeUser());
    const lookup = await resolveAuthLookup({ replyEmail, uid: UID, getUser });
    assert.equal(lookup.status, "found", String(replyEmail));
    assert.equal(lookup.user.email, "registered@example.com");
    assert.deepEqual(calls, [UID]);
  }
});

test("引き方: uid が無いときは Auth を呼ばない（no_uid）", async () => {
  for (const uid of [undefined, null, "", 123]) {
    const { calls, getUser } = fakeGetUser(fakeUser());
    assert.deepEqual(await resolveAuthLookup({ replyEmail: undefined, uid, getUser }), { status: "no_uid" });
    assert.deepEqual(calls, []);
  }
});

test("引き方: 失敗は not_found と code だけにまとめる（エラーの本文を持たない）", async () => {
  const notFound = Object.assign(new Error("no user: registered@example.com"), { code: "auth/user-not-found" });
  assert.deepEqual(await resolveAuthLookup({ replyEmail: undefined, uid: UID, getUser: fakeGetUser(notFound).getUser }), {
    status: "not_found",
  });
  const other = Object.assign(new Error("秘密の本文 registered@example.com"), { code: "auth/internal-error" });
  const lookup = await resolveAuthLookup({ replyEmail: undefined, uid: UID, getUser: fakeGetUser(other).getUser });
  assert.deepEqual(lookup, { status: "error", code: "auth/internal-error" });
  assert.ok(!JSON.stringify(lookup).includes("registered@example.com"));
});

// MARK: - 見張り: firestore.rules の isValidReplyEmail と形・長さが同じか

// ⚠️ Rules（firestore.rules の isValidReplyEmail）と関数（REPLY_EMAIL_PATTERN・長さ）の片方だけを変えたら、ここが落ちる。
//    reportDiscord.test.js の Swift の見張りと同じ型。期待する文字は手で打たず、JS の定数から作る
//    （rules のファイル上はバックスラッシュが 2 個・JS のソースでは 4 個要り、手で写すと食い違いに気づけないため）。
const RULES_PATH = path.join(__dirname, "..", "firestore.rules");
const RULES_CALL = "isValidReplyEmail(request.resource.data.get('replyEmail', null))";

/**
 * firestore.rules の文字から isValidReplyEmail の中身だけを切り出し、長さの下限・上限と matches の形を取り出す。
 * ファイル全体から探さないのは、isValidEmail（users の email）にも `size() <= 254` があり、
 * そちらに当たると isValidReplyEmail の数字を変えても緑のままになるため。
 * - 関数が見つからなければ null。項目が読めなければその項目が null
 */
function readRulesReplyEmailShape(rulesText) {
  const start = rulesText.indexOf("function isValidReplyEmail(");
  if (start < 0) return null;
  const end = rulesText.indexOf("\n    }", start); // 関数の閉じ括弧（字下げ 4）
  if (end < 0) return null;
  const body = rulesText.slice(start, end);
  const min = body.match(/value\.size\(\) >= (\d+)/);
  const max = body.match(/value\.size\(\) <= (\d+)/);
  const pattern = body.match(/value\.matches\('([^']*)'\)/);
  return {
    min: min ? Number(min[1]) : null,
    max: max ? Number(max[1]) : null,
    pattern: pattern ? pattern[1] : null,
  };
}

/**
 * REPLY_EMAIL_PATTERN（JS の正規表現）を、firestore.rules の文字列に書くときの形に直す。
 * - Rules の matches は全体一致なので、頭の ^ と末尾の $ は外す
 * - 点は `\.` でなく `[.]` で書く（rules の文字列のエスケープを 1 つ減らすため）
 * - rules の文字列の中ではバックスラッシュを 2 個にする（`\x21` → `\\x21`）
 */
function rulesLiteralFromJsPattern(re) {
  const source = re.source;
  assert.ok(source.startsWith("^") && source.endsWith("$"), `頭が ^・末尾が $ でない: ${source}`);
  return source
    .slice(1, -1)
    .replace(/\\\./g, "[.]")
    .replace(/\\/g, "\\\\");
}

/** 見張りの本体。食い違いがあれば、その中身を並べて返す（無ければ空の配列） */
function rulesReplyEmailMismatches(rulesText) {
  const shape = readRulesReplyEmailShape(rulesText);
  if (shape === null) return ["firestore.rules に function isValidReplyEmail( が見つからない"];
  const want = {
    min: REPLY_EMAIL_MIN_LENGTH,
    max: REPLY_EMAIL_MAX_LENGTH,
    pattern: rulesLiteralFromJsPattern(REPLY_EMAIL_PATTERN),
  };
  const out = [];
  for (const key of ["min", "max", "pattern"]) {
    if (shape[key] !== want[key]) out.push(`${key}: rules=${shape[key]} / 関数=${want[key]}`);
  }
  if (!rulesText.includes(RULES_CALL)) out.push(`feedback の create に ${RULES_CALL} が無い`);
  return out;
}

test("見張り: firestore.rules の isValidReplyEmail は、関数と同じ長さ（3〜254）と同じ形", () => {
  const rules = fs.readFileSync(RULES_PATH, "utf8");
  // 読めたこと自体を確かめる（書き方が変わって何も取れないまま緑になるのを防ぐ）
  const shape = readRulesReplyEmailShape(rules);
  assert.ok(shape !== null, "isValidReplyEmail が見つからない（名前が変わった？）");
  assert.ok(shape.min !== null && shape.max !== null && shape.pattern !== null, JSON.stringify(shape));
  assert.deepEqual(rulesReplyEmailMismatches(rules), []);
});

test("見張りの陽性対照: Rules の数字・形・呼び出しを 1 か所変えた写しでは、食い違いを見つける", () => {
  const rules = fs.readFileSync(RULES_PATH, "utf8");
  const start = rules.indexOf("function isValidReplyEmail(");
  assert.ok(start >= 0);
  const head = rules.slice(0, start);
  const tail = rules.slice(start);
  const broken = (from, to) => {
    assert.ok(tail.includes(from), `写しを壊せない（${from} が無い）`);
    return head + tail.replace(from, to);
  };

  // 上限を 255 に（isValidEmail の 254 に当たって緑のままにならないこと）
  assert.deepEqual(rulesReplyEmailMismatches(broken("value.size() <= 254", "value.size() <= 255")), [
    `max: rules=255 / 関数=${REPLY_EMAIL_MAX_LENGTH}`,
  ]);
  // 上限の行を丸ごと消す（同上）
  assert.deepEqual(rulesReplyEmailMismatches(broken("&& value.size() <= 254", "")), [
    `max: rules=null / 関数=${REPLY_EMAIL_MAX_LENGTH}`,
  ]);
  // 下限を 1 に
  assert.equal(rulesReplyEmailMismatches(broken("value.size() >= 3", "value.size() >= 1")).length, 1);
  // 形の範囲を 1 文字ずらす（@ の 1 つ前までを、@ まで含める）
  assert.equal(rulesReplyEmailMismatches(broken("\\\\x21-\\\\x3F", "\\\\x21-\\\\x40")).length, 1);
  // feedback の create から呼び出しを外す
  assert.deepEqual(rulesReplyEmailMismatches(rules.replace(RULES_CALL, "true")), [
    `feedback の create に ${RULES_CALL} が無い`,
  ]);
  // 関数の名前が変わった
  assert.deepEqual(rulesReplyEmailMismatches(rules.replace("function isValidReplyEmail(", "function x(")), [
    "firestore.rules に function isValidReplyEmail( が見つからない",
  ]);
});
