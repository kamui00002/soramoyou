#!/usr/bin/env node

/**
 * 一度きりの修復スクリプト: フォローカウンタの再計算
 *
 * 全ユーザーの followersCount / followingCount を follows コレクションから
 * 数え直し、users と publicProfiles の両方へ「代入」します。
 *
 * なぜ必要か:
 *   これまで publicProfiles 側のカウンタはクライアントから書けず（rules で所有者限定）、
 *   他人のプロフィールに出るフォロワー数が 0 のまま固定されていました。
 *   今後の増減は Cloud Functions（onFollowCreated / onFollowDeleted）が面倒を見ますが、
 *   「これまでに溜まったズレ」は過去のイベントなので Functions では直りません。
 *   そのぶんをこのスクリプトで一度だけ埋めます。
 *
 * ⚠️ 実行は原則 1 回だけ。ただし処理自体は冪等（数え直して代入）なので、
 *    途中で失敗しても安全に再実行できます。
 *
 * ⚠️ count() と書き込みの間に本番のフォロー操作が挟まると、その 1 件ぶん古い値で
 *    一時的に上書きしうるため、なるべく閑散時間帯に実行してください
 *    （ズレても次のフォロー/解除イベントで自己修復されます）。
 *
 * 実行順序（このスクリプトは一連のリリース手順の最後）:
 *   1. --dry-run で差分と「No publicProfile」の件数を確認する
 *   2. 「No publicProfile」のユーザーが居たら、先にリポジトリ直下の migrate-public-profiles.js で
 *      publicProfiles を作る（作らないと、そのユーザーは本スクリプトからも Functions からも
 *      永久にスキップされ続ける）
 *   3. Cloud Functions（onFollowCreated / onFollowDeleted）をデプロイする
 *   4. 本スクリプトを本実行する（以後のズレは Functions が面倒を見る）
 *
 * 実行方法:
 * 1. firebase-admin は functions/ の依存を借りる（functions で npm install 済みであること。
 *    scripts/follows-cleanup.js と同じ。リポジトリ直下の package.json は ^12 で、functions の 14 とずれるため使わない）
 *
 * 2. 認証の準備（ADC＝自分の Google アカウントのログイン。鍵ファイルは作らない）:
 *    gcloud auth application-default login
 *    quota project を求められたら: gcloud auth application-default set-quota-project <EXPECTED_PROJECT_ID の値>
 *    接続先は EXPECTED_PROJECT_ID に固定している（.firebaserc が空のため。ADC の既定に頼らない）
 *
 * 3. まず dry-run で差分を確認（1 件も書き込みません）:
 *    node scripts/backfill-follow-counters.js --dry-run
 *
 * 4. 内容に納得したら本実行:
 *    node scripts/backfill-follow-counters.js
 *    （確認プロンプトを飛ばしたい場合は --yes を付ける）
 *
 * テスト（本番には触れない）:
 *   scripts/backfill-follow-counters.emulator.test.js の冒頭を参照（functions/ の npm run test:emulator に登録）
 */

const path = require('path');
const { createRequire } = require('module');

// firebase-admin は functions/ を起点に読む（scripts/follows-cleanup.js の 121 行目と同じ）。
// リポジトリ直下には firebase-admin が入っていないため、素の require では見つからない
const functionsRequire = createRequire(path.join(__dirname, '..', 'functions', 'package.json'));

// コマンドライン引数
const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const SKIP_CONFIRM = args.includes('--yes');

// 書き込み先として唯一許可する Firebase プロジェクト。
// ⚠️ このリポジトリは .firebaserc が空で「default project が無い」運用のため、
//    ADC の既定に頼らず、initializeApp に projectId として渡して接続先を固定する（migrate-public-profiles.js と同じ）。
const EXPECTED_PROJECT_ID = 'soramoyou-ios';

/**
 * 1 ユーザー分のフォローカウンタを follows から数える
 *
 * count() は集計クエリなので、ドキュメント本体を読まずに件数だけを取得できる
 * （読み取り課金・実行時間ともに有利）。
 */
async function countFollowsFor(db, userId) {
  const [followersAgg, followingAgg] = await Promise.all([
    db.collection('follows').where('followeeId', '==', userId).count().get(),
    db.collection('follows').where('followerId', '==', userId).count().get()
  ]);
  return {
    followersCount: followersAgg.data().count, // この人をフォローしている人数
    followingCount: followingAgg.data().count // この人がフォローしている人数
  };
}

/**
 * メイン処理: 全ユーザーのカウンタを数え直して代入
 *
 * ⚠️ WriteBatch はあえて使わず、ユーザーごとに逐次 await している。理由は 2 つ:
 *   1. 対象が数百件規模で、バッチ化の速度メリットが小さい
 *   2. 1 件の失敗を局所化でき、どのユーザーで失敗したかログに残せる
 *   （batch を使うなら、500 件ごとに新しい batch を作り直す手当てが要る。移行スクリプト
 *     migrate-public-profiles.js は以前これが無く、500 件を超えると落ちていた）
 *
 * db は差し込む（main は本番の db、テストは demo- の Emulator の db を渡す）。
 * @returns 件数のまとめ { changed, unchanged, missingProfile, failed, total }
 */
async function backfill(db, { dryRun = false } = {}) {
  console.log('🚀 Starting backfill...\n');

  const usersSnapshot = await db.collection('users').get();

  if (usersSnapshot.empty) {
    console.log('⚠️  No users found in database');
    return { changed: 0, unchanged: 0, missingProfile: 0, failed: 0, total: 0 };
  }

  console.log(`📊 Found ${usersSnapshot.size} users\n`);

  let updatedCount = 0; // カウンタにズレがあり、書き込んだ（または書き込む予定の）ユーザー数
  let unchangedCount = 0; // 既に正しかったユーザー数
  let missingProfileCount = 0; // publicProfiles が無くスキップしたユーザー数
  let errorCount = 0;

  for (const doc of usersSnapshot.docs) {
    const userId = doc.id;
    try {
      const userData = doc.data();
      const counters = await countFollowsFor(db, userId);

      const beforeFollowers = userData.followersCount || 0;
      const beforeFollowing = userData.followingCount || 0;

      // publicProfiles は存在するときだけ書く。
      // ⚠️ set(..., { merge: true }) は存在しなければ作ってしまうため、
      //    カウンタだけの「表示名もアイコンも無い幽霊プロフィール」を新規作成しないよう防ぐ。
      const publicRef = db.collection('publicProfiles').doc(userId);
      const publicSnap = await publicRef.get();

      // ⚠️ ズレ判定は users と publicProfiles の両方を見る。
      //    このスクリプトの主目的は「users は正しいのに publicProfiles だけ 0」のズレの解消なので、
      //    users 側だけを比較すると dry-run が全員 ✓（Changed: 0）に見えてしまい、
      //    本実行の要否を誤判断させる。
      const publicData = publicSnap.exists ? publicSnap.data() : null;
      const publicChanged =
        publicSnap.exists &&
        ((publicData.followersCount || 0) !== counters.followersCount ||
          (publicData.followingCount || 0) !== counters.followingCount);
      const changed =
        beforeFollowers !== counters.followersCount ||
        beforeFollowing !== counters.followingCount ||
        publicChanged;

      const label =
        `${userId}: followers ${beforeFollowers} → ${counters.followersCount}, ` +
        `following ${beforeFollowing} → ${counters.followingCount}` +
        (publicChanged
          ? ` (publicProfiles 側: ${publicData.followersCount || 0}/${publicData.followingCount || 0} → 要更新)`
          : '');

      if (dryRun) {
        console.log(`${changed ? '📝' : '✓ '} [dry-run] ${label}`);
        if (!publicSnap.exists) {
          console.log(`   ⚠️  publicProfiles/${userId} が存在しないため書き込み対象外`);
        }
      } else {
        await doc.ref.set(counters, { merge: true });
        if (publicSnap.exists) {
          await publicRef.set(counters, { merge: true });
        } else {
          console.log(`   ⚠️  publicProfiles/${userId} が存在しないためスキップ`);
        }
        console.log(`${changed ? '📝' : '✓ '} ${label}`);
      }

      if (!publicSnap.exists) missingProfileCount++;
      if (changed) {
        updatedCount++;
      } else {
        unchangedCount++;
      }
    } catch (error) {
      errorCount++;
      console.error(`✗ Error processing user ${userId}:`, error.message);
    }
  }

  // 結果サマリー
  console.log('\n' + '='.repeat(50));
  console.log(`📈 Backfill Summary${dryRun ? ' (dry-run / 書き込みなし)' : ''}:`);
  console.log('='.repeat(50));
  console.log(`📝 Changed:            ${updatedCount}`);
  console.log(`✅ Already correct:    ${unchangedCount}`);
  console.log(`⚠️  No publicProfile:   ${missingProfileCount}`);
  console.log(`❌ Failed:             ${errorCount}`);
  console.log(`📊 Total:              ${usersSnapshot.size}`);
  console.log('='.repeat(50) + '\n');

  if (errorCount === 0) {
    console.log(dryRun ? '🎉 Dry-run completed (何も書き込んでいません)' : '🎉 Backfill completed successfully!');
  } else {
    console.log('⚠️  Backfill completed with some errors');
  }

  return {
    changed: updatedCount,
    unchanged: unchangedCount,
    missingProfile: missingProfileCount,
    failed: errorCount,
    total: usersSnapshot.size
  };
}

/**
 * 本実行前の確認プロンプト（dry-run と --yes のときは出さない）
 */
async function confirmBeforeWrite() {
  if (DRY_RUN || SKIP_CONFIRM) return;

  console.log('⚠️  本番データの users / publicProfiles に書き込みます');
  console.log('先に --dry-run で差分を確認することを強く推奨します\n');

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
 * スクリプト実行
 */
async function main() {
  console.log('\n' + '='.repeat(50));
  console.log('🔄 Follow Counters Backfill Tool');
  console.log('='.repeat(50) + '\n');

  if (DRY_RUN) {
    console.log('🧪 DRY-RUN モード: 1 件も書き込みません\n');
  }

  // Firebase Admin SDK 初期化（ADC＝Application Default Credentials。鍵ファイルは読まない）。
  // ⚠️ firebase-admin の読み込みと初期化はここでだけ行う（テストが require しただけでは本番につながないため）
  const { initializeApp, applicationDefault } = functionsRequire('firebase-admin/app');
  const { getFirestore } = functionsRequire('firebase-admin/firestore');
  let app;
  try {
    app = initializeApp({ credential: applicationDefault(), projectId: EXPECTED_PROJECT_ID });
    console.log(`✅ Firebase Admin SDK initialized (project: ${EXPECTED_PROJECT_ID})`);
  } catch (error) {
    console.error('❌ Error: Failed to initialize Firebase Admin SDK with Application Default Credentials (ADC)');
    console.error('Log in first: gcloud auth application-default login');
    console.error(`If asked for a quota project: gcloud auth application-default set-quota-project ${EXPECTED_PROJECT_ID}`);
    process.exit(1);
  }
  const db = getFirestore(app);

  // 接続先は initializeApp で固定している。確認の前に、どこへつなぐかを 1 行出す（scripts/follows-cleanup.js と同じ）
  console.log(`🔌 接続先 Firebase プロジェクト: ${EXPECTED_PROJECT_ID}`);
  await confirmBeforeWrite();
  await backfill(db, { dryRun: DRY_RUN });

  process.exit(0);
}

// テストから本体（backfill）だけを使えるようにする。main は export しない（テストから本番に繋ぐ口を作らない）
module.exports = { backfill, countFollowsFor };

// 実行（node で直接起こしたときだけ。require されたときは何もしない）
if (require.main === module) {
  main().catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}
