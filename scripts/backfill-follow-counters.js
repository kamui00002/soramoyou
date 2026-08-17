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
 *   2. 「No publicProfile」のユーザーが居たら、先に scripts/migrate-public-profiles.js で
 *      publicProfiles を作る（作らないと、そのユーザーは本スクリプトからも Functions からも
 *      永久にスキップされ続ける）
 *   3. Cloud Functions（onFollowCreated / onFollowDeleted）をデプロイする
 *   4. 本スクリプトを本実行する（以後のズレは Functions が面倒を見る）
 *
 * 実行方法:
 * 1. Firebase Admin SDK の設定:
 *    npm install firebase-admin
 *
 * 2. サービスアカウントキーをダウンロード:
 *    Firebase Console > Project Settings > Service Accounts
 *    > Generate New Private Key
 *    ダウンロードした JSON をリポジトリ直下に serviceAccountKey.json として保存
 *    （または環境変数 GOOGLE_APPLICATION_CREDENTIALS にパスを設定）
 *
 * 3. まず dry-run で差分を確認（1 件も書き込みません）:
 *    node scripts/backfill-follow-counters.js --dry-run
 *
 * 4. 内容に納得したら本実行:
 *    node scripts/backfill-follow-counters.js
 *    （確認プロンプトを飛ばしたい場合は --yes を付ける）
 */

const admin = require('firebase-admin');
const path = require('path');

// コマンドライン引数
const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const SKIP_CONFIRM = args.includes('--yes');

// 書き込み先として唯一許可する Firebase プロジェクト。
// ⚠️ このリポジトリは .firebaserc が空で「default project が無い」運用のため、
//    資格情報の取り違え（別プロジェクトの鍵・ADC）に気づく仕組みがスクリプト側に必要。
//    本番一発書き込みスクリプトなので、接続先をここで固定して照合する。
const EXPECTED_PROJECT_ID = 'soramoyou-ios';

// サービスアカウントキーのパス
// ⚠️ このスクリプトは scripts/ 配下にあるため、__dirname はリポジトリ直下ではない。
//    移行スクリプト（migrate-public-profiles.js）と同じ置き場を見るよう '..' を挟む。
const serviceAccountPath = path.join(__dirname, '..', 'serviceAccountKey.json');

// Firebase Admin SDK初期化
// resolvedProjectId: 実際に接続するプロジェクト ID。特定できなければ null のまま（後段のガードで停止する）。
let resolvedProjectId = null;
try {
  const serviceAccount = require(serviceAccountPath);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
  });
  resolvedProjectId = serviceAccount.project_id || null;
  console.log('✅ Firebase Admin SDK initialized (serviceAccountKey.json)');
} catch (error) {
  // 鍵ファイルが無い場合は GOOGLE_APPLICATION_CREDENTIALS 等の既定資格情報にフォールバックする。
  try {
    admin.initializeApp({ credential: admin.credential.applicationDefault() });
    // ADC は鍵ファイルと違って接続先が暗黙的に決まるため、環境変数等から特定できた場合のみ採用する。
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

const db = admin.firestore();

/**
 * 接続先プロジェクトの表示と期待値ガード
 *
 * ⚠️ 実行の最初（確認プロンプトより前）に必ず呼ぶ。別プロジェクトの鍵や ADC のまま
 *    本番書き込みが走る事故を、接続先の照合で止める。
 *    接続先を特定できない（null）場合も安全側に倒して停止する。
 */
function assertExpectedProject() {
  console.log(`🔌 接続先 Firebase プロジェクト: ${resolvedProjectId || '(特定できませんでした)'}`);
  if (resolvedProjectId !== EXPECTED_PROJECT_ID) {
    console.error(`❌ Error: 接続先が期待値 (${EXPECTED_PROJECT_ID}) と一致しません`);
    console.error('   serviceAccountKey.json / GOOGLE_APPLICATION_CREDENTIALS が');
    console.error('   別プロジェクトの資格情報になっていないか確認してください');
    process.exit(1);
  }
}

/**
 * 1 ユーザー分のフォローカウンタを follows から数える
 *
 * count() は集計クエリなので、ドキュメント本体を読まずに件数だけを取得できる
 * （読み取り課金・実行時間ともに有利）。
 */
async function countFollowsFor(userId) {
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
 *   （移行スクリプト migrate-public-profiles.js は commit 後の batch を再利用しており、
 *     500 件を超えると落ちる。ここでは同じ轍を踏まないようにする）
 */
async function backfillFollowCounters() {
  console.log('🚀 Starting backfill...\n');

  const usersSnapshot = await db.collection('users').get();

  if (usersSnapshot.empty) {
    console.log('⚠️  No users found in database');
    return;
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
      const counters = await countFollowsFor(userId);

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

      if (DRY_RUN) {
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
  console.log(`📈 Backfill Summary${DRY_RUN ? ' (dry-run / 書き込みなし)' : ''}:`);
  console.log('='.repeat(50));
  console.log(`📝 Changed:            ${updatedCount}`);
  console.log(`✅ Already correct:    ${unchangedCount}`);
  console.log(`⚠️  No publicProfile:   ${missingProfileCount}`);
  console.log(`❌ Failed:             ${errorCount}`);
  console.log(`📊 Total:              ${usersSnapshot.size}`);
  console.log('='.repeat(50) + '\n');

  if (errorCount === 0) {
    console.log(DRY_RUN ? '🎉 Dry-run completed (何も書き込んでいません)' : '🎉 Backfill completed successfully!');
  } else {
    console.log('⚠️  Backfill completed with some errors');
  }
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

  // dry-run でも読み取り先が別プロジェクトだと差分表示ごと嘘になるため、常にガードを通す。
  assertExpectedProject();
  await confirmBeforeWrite();
  await backfillFollowCounters();

  process.exit(0);
}

// 実行
main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
