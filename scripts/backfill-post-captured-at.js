#!/usr/bin/env node

/**
 * 一度きりの修復スクリプト: 投稿の capturedAt / timeOfDay バックフィル
 *
 * 背景（なぜ必要か）:
 *   `ImageService.extractEXIFData(_ image: UIImage)` が UIImage を jpegData で
 *   再エンコードしてから EXIF を読んでいたため、EXIF が構造的に常に空になっていた
 *   （初回実装 2025-12-06 から同じ形＝全期間）。2026-09-15 に本番 Firestore の公開投稿
 *   12 件（09-08〜09-14）を直接確認し、`capturedAt` / `timeOfDay` が 12/12 件で欠落
 *   していることが分かった。EXIF 読み出し経路自体は PR-A（撮影日時を元ファイルの
 *   EXIF から取得する）で修正済みだが、それは「今後の新規投稿」にしか効かない。
 *   既に Firestore に溜まっている過去投稿のぶんは、このスクリプトで一度だけ埋める。
 *
 * 復元できる範囲（できない範囲も明記）:
 *   - Cloud Storage に保存済みの JPEG は `StorageService.encodeJPEG` の時点で EXIF が
 *     剥離済み。サーバ側（このスクリプトを含む）で画像そのものから EXIF を読み直す
 *     ことはできない＝「画像から復元」は原理的に不可能。
 *   - 代わりに `images[0].externalEditInfo.creationDate`（PHAsset.creationDate、
 *     2026-04-30 以降の投稿に永続化済み）を撮影日時の代用として使う。
 *   - PR-A 以降に投稿されたものは `images[0].externalEditInfo.exifCapturedAt` が
 *     付くので、そちらを優先して使う（EXIF > PHAsset の順）。
 *   - どちらも無い投稿（2026-04-30 より前 かつ EXIF 無し）は復元不可としてスキップする。
 *   - skyColors / colorTemperature（PR-B の対象）はこのスクリプトの対象外。
 *
 * 対象外・安全策:
 *   - `capturedAt` が既にある doc はスキップする（冪等。何度実行しても安全）。
 *   - `postKind` が collage / panorama の合成投稿はスキップする（先頭 1 枚の撮影日時が
 *     投稿全体を代表しないため。PR-A の「合成種別は capturedAt を nil のまま」という
 *     方針と合わせている）。
 *   - 書き込むのは `capturedAt` と `timeOfDay` の 2 フィールドのみ。`updatedAt` や
 *     `likesCount` / `commentsCount` などのカウンタには一切触れない。
 *
 * timeOfDay の算出方法（Asia/Tokyo 固定の理由）:
 *   アプリ側の判定ロジック `TimeOfDay.from(date:)`（Models/TimeOfDay.swift）は
 *   `Calendar.current` の時（＝端末のタイムゾーン）で朝/昼/夕方/夜を決めている。
 *   このスクリプトは Admin SDK（サーバー環境）で動くため端末タイムゾーンが無く、
 *   ユーザーのほぼ全員が日本語圏であることから `Asia/Tokyo` を固定で使う
 *   （`Intl.DateTimeFormat` の `timeZone` オプションで JST の時刻を取り出す）。
 *   境界は同じ実装に揃えている: 5-11 時=morning / 12-16 時=afternoon /
 *   17-19 時=evening / それ以外=night。
 *
 * 実行手順:
 * 1. 依存関係のインストール（root package.json に firebase-admin ^12 あり）:
 *    npm install
 *
 * 2. サービスアカウントキーをダウンロード:
 *    Firebase Console > Project Settings > Service Accounts > Generate New Private Key
 *    ダウンロードした JSON をリポジトリ直下に serviceAccountKey.json として保存する
 *    （.gitignore 済み。中身を表示したり引数に渡したりしないこと）。
 *    鍵が無ければ GOOGLE_APPLICATION_CREDENTIALS の既定資格情報にフォールバックする。
 *
 * 3. まず dry-run で件数内訳を確認する（既定が dry-run。1 件も書き込まない）:
 *    node scripts/backfill-post-captured-at.js
 *
 * 4. 内容に納得したら少数件で試し運転する:
 *    node scripts/backfill-post-captured-at.js --apply --limit 3
 *    → Firebase Console で対象 doc の capturedAt（Timestamp）/ timeOfDay と、
 *      updatedAt・likesCount・commentsCount が変わっていないことを確認する。
 *
 * 5. 問題なければ全件を本実行する（確認プロンプトを飛ばすには --yes を付ける）:
 *    node scripts/backfill-post-captured-at.js --apply
 *    → 再実行して candidates が 0 になれば完了。
 *
 * 6. PR-A（EXIF 修正）が全ユーザーに配布された後、もう一度 dry-run → --apply で
 *    実行すると良い。PR-A 配布前後の狭間で（未更新の端末から）作成され、まだ
 *    capturedAt が付いていない投稿を追加で拾えるため、取りこぼしが減る。
 *
 * ⚠️ 処理自体は冪等（capturedAt が無い doc だけを対象に代入する）なので、
 *    途中で失敗しても安全に再実行できる。
 *
 * ⚠️ --apply 後に確認すること: capturedAt は `capturedAt ?? createdAt` という形で
 *    複数画面から参照されている（Services/OnThisDayService.swift、
 *    Services/CalendarDiaryService.swift、Models/SkyCollection.swift、
 *    Views/Components/ShareCardView.swift）。バックフィルで既存投稿に capturedAt が
 *    付くと、これらの画面（空図鑑・On This Day・空カレンダー・共有カード）に出る
 *    日付・季節・時間帯が「投稿日」から「撮影日」に変わりうる（意図した変化だが、
 *    ユーザーには見える変化なので目視確認しておく）。
 */

'use strict';

const path = require('path');

// コマンドライン引数の解析。呼び出し側の process.argv に依存するため main() からのみ呼ぶ
// （require されただけではテストのために argv を触りたくない＝副作用を避ける）。
// 認識する引数はこの3つだけ（--limit は値と対で1トークン扱いにする）。
// ⚠️ ここに無いトークンは「タイプミス・別記法（例: --limit=3）を黙って無視して
//    本番全件書き込みが走ってしまう」事故を防ぐため、下の未知引数チェックで弾く。
const KNOWN_FLAGS = new Set(['--apply', '--yes', '--limit']);

function parseArgs(argv) {
  const apply = argv.includes('--apply');
  const skipConfirm = argv.includes('--yes');

  let limit = null;
  const limitIndex = argv.indexOf('--limit');
  if (limitIndex !== -1) {
    const raw = argv[limitIndex + 1];
    const parsed = Number.parseInt(raw, 10);
    if (!Number.isInteger(parsed) || parsed <= 0) {
      console.error('❌ Error: --limit には正の整数を指定してください（例: --limit 3）');
      process.exit(1);
    }
    limit = parsed;
  }

  // 未知の引数を検出する。「--limit=3」のような別記法や打ち間違いは、
  // 黙って無視すると limit が効かないまま --apply だけが通ってしまい、
  // 「少数件で試し運転」のつもりが本番全件書き込みになる事故につながる。
  for (let i = 0; i < argv.length; i++) {
    if (limitIndex !== -1 && i === limitIndex + 1) continue; // --limit の値トークンはスキップ
    if (!KNOWN_FLAGS.has(argv[i])) {
      console.error(`❌ Error: 認識できない引数です: ${argv[i]}`);
      console.error('   使える引数: --apply / --yes / --limit <正の整数>');
      process.exit(1);
    }
  }

  return { apply, skipConfirm, limit };
}

// 書き込み先として唯一許可する Firebase プロジェクト。
// ⚠️ このリポジトリは .firebaserc が空で「default project が無い」運用のため、
//    資格情報の取り違え（別プロジェクトの鍵・ADC）に気づく仕組みがスクリプト側に必要。
//    本番書き込みスクリプトなので、接続先をここで固定して照合する
//    （scripts/backfill-follow-counters.js と同じパターン）。
const EXPECTED_PROJECT_ID = 'soramoyou-ios';

// posts コレクションを documentId() 順にページングする際の 1 ページあたりの件数。
const PAGE_SIZE = 500;

// WriteBatch を commit してから作り直す間隔。
// ⚠️ commit 後の WriteBatch インスタンスは再利用できない
//    （scripts/backfill-follow-counters.js:136-137 の指摘と同じ罠）。
//    Firestore の 1 バッチ上限 500 件に対して余裕を持たせて 400 件ごとに commit する。
const BATCH_FLUSH_SIZE = 400;

/**
 * 時刻（Date）から Asia/Tokyo の時間帯を判定する。
 *
 * アプリ側 `TimeOfDay.from(date:)`（Models/TimeOfDay.swift）と同じ境界:
 *   5-11 時 = morning / 12-16 時 = afternoon / 17-19 時 = evening / それ以外 = night
 *
 * サーバー環境には端末タイムゾーンが無いため、ユーザーのほぼ全員が日本語圏であることから
 * Asia/Tokyo を固定で使う。`Intl.DateTimeFormat` の `formatToParts` で JST の時だけを
 * 取り出す（`hourCycle: 'h23'` で 0-23 表現に揃える。実装によって深夜 0 時が "24" と
 * 出力される既知の ICU 差異があるため、念のため % 24 で正規化している）。
 *
 * @param {Date} date
 * @returns {'morning'|'afternoon'|'evening'|'night'}
 */
function timeOfDayInTokyo(date) {
  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Tokyo',
    hour: 'numeric',
    hourCycle: 'h23'
  });
  const hourPart = formatter.formatToParts(date).find((part) => part.type === 'hour');
  const hour = hourPart ? Number.parseInt(hourPart.value, 10) % 24 : Number.NaN;

  if (hour >= 5 && hour < 12) return 'morning';
  if (hour >= 12 && hour < 17) return 'afternoon';
  if (hour >= 17 && hour < 20) return 'evening';
  return 'night';
}

/**
 * 投稿ドキュメント（Firestore の生データ）から capturedAt の代用として使う
 * タイムスタンプを決める。
 *
 * 優先順位: 先頭画像（images を order 昇順に並べた先頭要素）の
 *   externalEditInfo.exifCapturedAt（PR-A 以降の投稿に付く）
 *   → externalEditInfo.creationDate（PHAsset.creationDate、2026-04-30 以降）
 *   → どちらも無ければ null（復元不可）。
 *
 * images が空・externalEditInfo が無い場合も null を返す。
 *
 * @param {{ images?: Array<{ order?: number, externalEditInfo?: { exifCapturedAt?: unknown, creationDate?: unknown } }> }} postData
 * @returns {{ timestamp: unknown, source: 'exif'|'asset' } | null}
 */
function sourceTimestamp(postData) {
  const images = Array.isArray(postData && postData.images) ? postData.images : [];
  if (images.length === 0) return null;

  const sortedByOrder = [...images].sort((a, b) => {
    const orderA = a && typeof a.order === 'number' ? a.order : 0;
    const orderB = b && typeof b.order === 'number' ? b.order : 0;
    return orderA - orderB;
  });

  const externalEditInfo = sortedByOrder[0] && sortedByOrder[0].externalEditInfo;
  if (!externalEditInfo) return null;

  if (externalEditInfo.exifCapturedAt) {
    return { timestamp: externalEditInfo.exifCapturedAt, source: 'exif' };
  }
  if (externalEditInfo.creationDate) {
    return { timestamp: externalEditInfo.creationDate, source: 'asset' };
  }
  return null;
}

/**
 * Firebase Admin SDK を初期化する。
 *
 * serviceAccountKey.json（リポジトリ直下・gitignore 済み）を優先し、
 * 無ければ GOOGLE_APPLICATION_CREDENTIALS 等の既定資格情報にフォールバックする
 * （scripts/backfill-follow-counters.js:68-92 と同じパターン）。
 *
 * ⚠️ この関数は main() からのみ呼ぶ。モジュールを require しただけの時（テスト時）に
 *    Firebase 初期化や資格情報探索が走らないようにするため。
 */
function initializeFirebase() {
  const admin = require('firebase-admin');
  // このスクリプトは scripts/ 配下にあるため、__dirname はリポジトリ直下ではない。
  const serviceAccountPath = path.join(__dirname, '..', 'serviceAccountKey.json');

  let resolvedProjectId = null;
  try {
    const serviceAccount = require(serviceAccountPath);
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    resolvedProjectId = serviceAccount.project_id || null;
    console.log('✅ Firebase Admin SDK initialized (serviceAccountKey.json)');
  } catch (error) {
    try {
      admin.initializeApp({ credential: admin.credential.applicationDefault() });
      resolvedProjectId =
        process.env.GOOGLE_CLOUD_PROJECT || process.env.GCLOUD_PROJECT || admin.app().options.projectId || null;
      console.log('✅ Firebase Admin SDK initialized (application default credentials)');
    } catch (fallbackError) {
      console.error('❌ Error: 認証情報が見つかりません');
      console.error('serviceAccountKey.json をリポジトリ直下に置くか、');
      console.error('GOOGLE_APPLICATION_CREDENTIALS を設定してください');
      process.exit(1);
    }
  }

  return { admin, db: admin.firestore(), resolvedProjectId };
}

/**
 * 接続先プロジェクトの表示と期待値ガード
 *
 * ⚠️ 実行の最初（確認プロンプトより前）に必ず呼ぶ。別プロジェクトの鍵や ADC のまま
 *    本番書き込みが走る事故を、接続先の照合で止める。dry-run でも候補表示が別
 *    プロジェクトのものだと意味が無いため、モードに関わらず常に通す。
 */
function assertExpectedProject(resolvedProjectId) {
  console.log(`🔌 接続先 Firebase プロジェクト: ${resolvedProjectId || '(特定できませんでした)'}`);
  if (resolvedProjectId !== EXPECTED_PROJECT_ID) {
    console.error(`❌ Error: 接続先が期待値 (${EXPECTED_PROJECT_ID}) と一致しません`);
    console.error('   serviceAccountKey.json / GOOGLE_APPLICATION_CREDENTIALS が');
    console.error('   別プロジェクトの資格情報になっていないか確認してください');
    process.exit(1);
  }
}

/**
 * 本実行前の確認プロンプト（dry-run と --yes のときは出さない）
 */
async function confirmBeforeWrite(apply, skipConfirm) {
  if (!apply || skipConfirm) return;

  console.log('⚠️  本番データの posts に capturedAt / timeOfDay を書き込みます');
  console.log('先に dry-run（--apply を付けない）で候補を確認することを強く推奨します\n');

  const readline = require('readline').createInterface({
    input: process.stdin,
    output: process.stdout
  });

  return new Promise((resolve) => {
    readline.question('Continue? (yes/no): ', (answer) => {
      readline.close();
      if (answer.toLowerCase() !== 'yes') {
        console.log('Backfill cancelled');
        process.exit(0);
      }
      resolve();
    });
  });
}

/**
 * メイン処理: posts を documentId 順にページングしながら candidates を集め、
 * apply モードのときだけ実際に書き込む。
 */
async function backfillCapturedAt({ admin, db, apply, limit }) {
  console.log(`🚀 Starting capturedAt backfill...${limit ? ` (--limit ${limit})` : ''}\n`);

  const stats = {
    scanned: 0,
    alreadyHasCapturedAt: 0,
    skippedComposite: 0,
    skippedNoSource: 0,
    candidates: 0,
    updated: 0,
    failed: 0,
    timeOfDayMismatch: 0
  };

  let batch = db.batch();
  let pending = 0;
  let lastDoc = null;

  // 現在のバッチを commit し、成功したら updated に積んで新しい batch を用意する。
  // 失敗したら failed に積んで false を返す（呼び出し側はここで処理を打ち切る）。
  const flush = async () => {
    if (pending === 0) return true;
    const flushedCount = pending;
    try {
      await batch.commit();
      stats.updated += flushedCount;
      pending = 0;
      batch = db.batch();
      return true;
    } catch (error) {
      stats.failed += flushedCount;
      pending = 0;
      console.error(`❌ commit に失敗しました: ${error.message}`);
      console.error('   冪等なスクリプトなので、そのまま再実行すれば失敗分から再開できます。');
      return false;
    }
  };

  outer: while (true) {
    let query = db.collection('posts').orderBy(admin.firestore.FieldPath.documentId()).limit(PAGE_SIZE);
    if (lastDoc) {
      query = query.startAfter(lastDoc);
    }

    const snapshot = await query.get();
    if (snapshot.empty) break;

    for (const doc of snapshot.docs) {
      lastDoc = doc;
      const data = doc.data();
      stats.scanned++;

      // 既に capturedAt がある doc はスキップ（冪等）。
      // ついでに、既存の timeOfDay が今の判定ロジックとズレていないかも確認しておく
      // （想定は常に 0 件。ズレがあれば境界値の実装差異などを疑う手がかりになる）。
      if (data.capturedAt) {
        stats.alreadyHasCapturedAt++;
        if (data.timeOfDay) {
          const expected = timeOfDayInTokyo(data.capturedAt.toDate());
          if (expected !== data.timeOfDay) {
            stats.timeOfDayMismatch++;
          }
        }
        continue;
      }

      // 合成投稿（配置写真・広角合成）は先頭 1 枚の撮影日時が投稿全体を代表しないためスキップ。
      if (data.postKind === 'collage' || data.postKind === 'panorama') {
        stats.skippedComposite++;
        continue;
      }

      const source = sourceTimestamp(data);
      if (!source) {
        stats.skippedNoSource++;
        continue;
      }

      const capturedAtDate = source.timestamp.toDate();
      const computedTimeOfDay = timeOfDayInTokyo(capturedAtDate);
      stats.candidates++;

      const label = `${doc.id}: capturedAt=${capturedAtDate.toISOString()} (${source.source}) timeOfDay=${computedTimeOfDay}`;

      if (apply) {
        batch.update(doc.ref, { capturedAt: source.timestamp, timeOfDay: computedTimeOfDay });
        pending++;
        console.log(`📝 ${label}`);

        if (pending >= BATCH_FLUSH_SIZE) {
          const ok = await flush();
          if (!ok) {
            break outer;
          }
        }
      } else {
        console.log(`🧪 ${label}`);
      }

      if (limit && stats.candidates >= limit) {
        break outer;
      }
    }

    if (snapshot.docs.length < PAGE_SIZE) break;
  }

  // 最後の半端なバッチを commit する。commit 失敗で止まった場合は pending が
  // 既に 0 にリセットされているため、ここでの呼び出しは無害（no-op）。
  if (apply && pending > 0) {
    await flush();
  }

  printSummary(stats, apply);
  return stats;
}

function printSummary(stats, apply) {
  console.log('\n' + '='.repeat(50));
  console.log(`📈 Backfill Summary${apply ? '' : ' (dry-run / 書き込みなし)'}:`);
  console.log('='.repeat(50));
  console.log(`🔍 Scanned:                 ${stats.scanned}`);
  console.log(`✅ Already has capturedAt:  ${stats.alreadyHasCapturedAt}`);
  console.log(`⏭️  Skipped (composite):     ${stats.skippedComposite}`);
  console.log(`⏭️  Skipped (no source):     ${stats.skippedNoSource}`);
  console.log(`🎯 Candidates:              ${stats.candidates}`);
  console.log(`📝 Updated:                 ${stats.updated}`);
  console.log(`❌ Failed:                  ${stats.failed}`);
  console.log(`⚠️  timeOfDay mismatch:      ${stats.timeOfDayMismatch}`);
  console.log('='.repeat(50) + '\n');

  if (stats.failed > 0) {
    console.log('⚠️  一部のコミットに失敗しました。処理はこの時点で終了しています。');
    console.log('   冪等なスクリプトなので、そのまま再実行すれば失敗分から再開できます。');
  } else if (apply) {
    console.log('🎉 Backfill completed successfully!');
  } else {
    console.log('🎉 Dry-run completed (何も書き込んでいません)');
  }
}

async function main() {
  console.log('\n' + '='.repeat(50));
  console.log('🔄 Post capturedAt / timeOfDay Backfill Tool');
  console.log('='.repeat(50) + '\n');

  const { apply, skipConfirm, limit } = parseArgs(process.argv.slice(2));

  if (!apply) {
    console.log('🧪 DRY-RUN モード: 1 件も書き込みません（--apply で書き込みを有効化）\n');
  }

  const { admin, db, resolvedProjectId } = initializeFirebase();

  assertExpectedProject(resolvedProjectId);
  await confirmBeforeWrite(apply, skipConfirm);
  await backfillCapturedAt({ admin, db, apply, limit });

  process.exit(0);
}

// timeOfDayInTokyo / sourceTimestamp はユニットテストのために公開する。
// require.main === module のときだけ main() を実行し、テストのために require された
// だけの時に Firebase 初期化・process.exit が走らないようにする。
module.exports = { timeOfDayInTokyo, sourceTimestamp };

if (require.main === module) {
  main().catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}
