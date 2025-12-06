# そらもよう iOSアプリ

## セットアップ手順

### 1. Xcodeプロジェクトの作成

1. Xcodeを開く
2. "Create a new Xcode project"を選択
3. "iOS" > "App"を選択
4. プロジェクト情報を入力:
   - Product Name: `Soramoyou`
   - Interface: `SwiftUI`
   - Language: `Swift`
   - Minimum Deployments: `iOS 15.0`
5. このディレクトリ（`Soramoyou`）に保存

### 2. Swift Package Managerで依存関係を追加

1. Xcodeでプロジェクトを開く
2. プロジェクトナビゲーターでプロジェクトを選択
3. "Package Dependencies"タブを開く
4. "+"ボタンをクリック
5. 以下のパッケージを追加:

#### Firebase iOS SDK
- URL: `https://github.com/firebase/firebase-ios-sdk`
- Version: `10.18.0` 以降
- 追加するプロダクト:
  - FirebaseAuth
  - FirebaseFirestore
  - FirebaseStorage

#### Kingfisher
- URL: `https://github.com/onevcat/Kingfisher`
- Version: `7.9.0` 以降

#### Google Mobile Ads SDK
- URL: `https://github.com/googleads/swift-package-manager-google-mobile-ads.git`
- Version: `10.14.0` 以降

### 3. Firebaseプロジェクトの設定

1. [Firebase Console](https://console.firebase.google.com/)にアクセス
2. "プロジェクトを追加"をクリック
3. プロジェクト名を入力（例: `soramoyou`）
4. iOSアプリを追加:
   - バンドルID: `com.yourcompany.Soramoyou`（XcodeプロジェクトのBundle Identifierと一致させる）
   - アプリのニックネーム: `Soramoyou`
5. `GoogleService-Info.plist`をダウンロード
6. ダウンロードした`GoogleService-Info.plist`をXcodeプロジェクトの`Soramoyou`フォルダにドラッグ&ドロップ
7. "Copy items if needed"にチェックを入れる

### 4. Firebaseサービスの有効化

Firebase Consoleで以下を有効化:

1. **Authentication**
   - "Authentication" > "Sign-in method"を開く
   - "メール/パスワード"を有効化

2. **Cloud Firestore**
   - "Firestore Database"を開く
   - "データベースを作成"をクリック
   - セキュリティルール: "テストモードで開始"を選択（後で本番用ルールに更新）

3. **Firebase Storage**
   - "Storage"を開く
   - "始める"をクリック
   - セキュリティルール: "テストモードで開始"を選択（後で本番用ルールに更新）

### 5. セキュリティルールの設定

#### Firestore Security Rules

Firebase Console > Firestore Database > ルール で以下を設定:

```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users collection
    match /users/{userId} {
      allow read: if request.auth != null;
      allow write: if request.auth != null && request.auth.uid == userId;
    }
    
    // Posts collection
    match /posts/{postId} {
      allow read: if resource.data.visibility == 'public' || 
                     (request.auth != null && resource.data.userId == request.auth.uid);
      allow create: if request.auth != null && request.auth.uid == request.resource.data.userId;
      allow update, delete: if request.auth != null && request.auth.uid == resource.data.userId;
    }
    
    // Drafts collection
    match /drafts/{draftId} {
      allow read, write: if request.auth != null && request.auth.uid == resource.data.userId;
    }
  }
}
```

#### Firebase Storage Security Rules

Firebase Console > Storage > ルール で以下を設定:

```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /images/{allPaths=**} {
      allow read: if true;
      allow write: if request.auth != null;
    }
  }
}
```

### 6. Info.plistの確認

`Info.plist`に以下の権限設定が含まれていることを確認:
- `NSPhotoLibraryUsageDescription`
- `NSPhotoLibraryAddUsageDescription`
- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`

### 7. ビルドと実行

1. Xcodeでプロジェクトを開く
2. シミュレーターまたは実機を選択
3. ⌘+R でビルド&実行

## 注意事項

- `GoogleService-Info.plist`は`.gitignore`に追加済みです。Gitにコミットしないでください。
- セキュリティルールは本番環境では適切に設定してください（テストモードは開発時のみ使用）。

