#!/usr/bin/env node

/**
 * データ移行スクリプト: users → publicProfiles
 *
 * 既存のusersコレクションから公開プロフィール情報を抽出し、
 * publicProfilesコレクションに保存します。
 *
 * 実行方法:
 * 1. Firebase Admin SDK の設定:
 *    npm install firebase-admin
 *
 * 2. サービスアカウントキーをダウンロード:
 *    Firebase Console > Project Settings > Service Accounts
 *    > Generate New Private Key
 *    ダウンロードしたJSONファイルを serviceAccountKey.json として保存
 *
 * 3. 実行:
 *    node migrate-public-profiles.js
 */

const admin = require('firebase-admin');
const path = require('path');

// サービスアカウントキーのパス
const serviceAccountPath = path.join(__dirname, 'serviceAccountKey.json');

// Firebase Admin SDK初期化
try {
  const serviceAccount = require(serviceAccountPath);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
  });
  console.log('✅ Firebase Admin SDK initialized');
} catch (error) {
  console.error('❌ Error: serviceAccountKey.json not found');
  console.error('Please download service account key from Firebase Console');
  console.error('Project Settings > Service Accounts > Generate New Private Key');
  process.exit(1);
}

const db = admin.firestore();

/**
 * Userドキュメントから公開プロフィールデータを抽出
 */
function extractPublicProfile(userId, userData) {
  return {
    id: userId,
    displayName: userData.displayName || null,
    photoURL: userData.photoURL || null,
    bio: userData.bio || null,
    customEditTools: userData.customEditTools || null,
    customEditToolsOrder: userData.customEditToolsOrder || null,
    followersCount: userData.followersCount || 0,
    followingCount: userData.followingCount || 0,
    postsCount: userData.postsCount || 0,
    createdAt: userData.createdAt || admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: userData.updatedAt || admin.firestore.FieldValue.serverTimestamp()
  };
}

/**
 * メイン処理: 全ユーザーの公開プロフィールを移行
 */
async function migratePublicProfiles() {
  try {
    console.log('🚀 Starting migration...\n');

    // usersコレクションから全ユーザーを取得
    const usersSnapshot = await db.collection('users').get();

    if (usersSnapshot.empty) {
      console.log('⚠️  No users found in database');
      return;
    }

    console.log(`📊 Found ${usersSnapshot.size} users\n`);

    let successCount = 0;
    let errorCount = 0;
    const batch = db.batch();
    let batchCount = 0;
    const BATCH_SIZE = 500; // Firestoreのバッチ制限

    // 各ユーザーを処理
    for (const doc of usersSnapshot.docs) {
      try {
        const userId = doc.id;
        const userData = doc.data();

        // 公開プロフィールデータを抽出
        const publicProfile = extractPublicProfile(userId, userData);

        // publicProfilesコレクションに追加
        const publicProfileRef = db.collection('publicProfiles').doc(userId);
        batch.set(publicProfileRef, publicProfile, { merge: true });

        batchCount++;
        console.log(`✓ User ${userId} queued (${batchCount})`);

        // バッチサイズに達したらコミット
        if (batchCount >= BATCH_SIZE) {
          await batch.commit();
          console.log(`\n💾 Committed batch of ${batchCount} documents\n`);
          batchCount = 0;
        }

        successCount++;
      } catch (error) {
        errorCount++;
        console.error(`✗ Error processing user ${doc.id}:`, error.message);
      }
    }

    // 残りのバッチをコミット
    if (batchCount > 0) {
      await batch.commit();
      console.log(`\n💾 Committed final batch of ${batchCount} documents\n`);
    }

    // 結果サマリー
    console.log('\n' + '='.repeat(50));
    console.log('📈 Migration Summary:');
    console.log('='.repeat(50));
    console.log(`✅ Successful: ${successCount}`);
    console.log(`❌ Failed: ${errorCount}`);
    console.log(`📊 Total: ${usersSnapshot.size}`);
    console.log('='.repeat(50) + '\n');

    if (errorCount === 0) {
      console.log('🎉 Migration completed successfully!');
    } else {
      console.log('⚠️  Migration completed with some errors');
    }

  } catch (error) {
    console.error('❌ Migration failed:', error);
    process.exit(1);
  }
}

/**
 * 移行前の検証: publicProfilesコレクションの既存ドキュメント数を確認
 */
async function validateBeforeMigration() {
  try {
    const existingProfiles = await db.collection('publicProfiles').get();

    if (!existingProfiles.empty) {
      console.log(`⚠️  Warning: ${existingProfiles.size} documents already exist in publicProfiles collection`);
      console.log('This script will merge/overwrite existing profiles with data from users collection\n');

      // 確認プロンプト（本番環境では readline を使用）
      const readline = require('readline').createInterface({
        input: process.stdin,
        output: process.stdout
      });

      return new Promise((resolve) => {
        readline.question('Continue? (yes/no): ', (answer) => {
          readline.close();
          if (answer.toLowerCase() !== 'yes') {
            console.log('Migration cancelled');
            process.exit(0);
          }
          resolve();
        });
      });
    }
  } catch (error) {
    console.error('Validation error:', error);
  }
}

/**
 * スクリプト実行
 */
async function main() {
  console.log('\n' + '='.repeat(50));
  console.log('🔄 Public Profiles Migration Tool');
  console.log('='.repeat(50) + '\n');

  await validateBeforeMigration();
  await migratePublicProfiles();

  process.exit(0);
}

// 実行
main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
