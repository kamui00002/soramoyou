# セキュリティガイド

## 重要な注意事項

### APIキーと機密情報の管理

**⚠️ 警告**: `GoogleService-Info.plist`にはFirebase APIキーなどの機密情報が含まれています。このファイルは**絶対にgitリポジトリにコミットしないでください**。

### 現在の状況

- `GoogleService-Info.plist`は`.gitignore`に含まれています
- 過去に誤ってコミットされた可能性があるため、git履歴から削除が必要です

### 対応手順

#### 1. Google Cloud Consoleでの対応

1. [Google Cloud Console](https://console.cloud.google.com/)にアクセス
2. プロジェクト「Soramoyou (soramoyou-ios)」を選択
3. **APIとサービス > 認証情報**に移動
4. 公開されているAPIキー（`AIzaSyC4BrIDzZz6kgGiOrqfIp2nwKNhR5X1QkQ`）を確認
5. 以下のいずれかを実行：
   - **推奨**: APIキーに制限を設定（iOSアプリのバンドルID、Firebaseプロジェクトなど）
   - **代替**: 古いAPIキーを削除し、新しいAPIキーを生成

#### 2. 新しいAPIキーの生成（必要な場合）

1. Firebase Consoleで新しい`GoogleService-Info.plist`をダウンロード
2. プロジェクトの`Soramoyou/Soramoyou/`ディレクトリに配置
3. **このファイルはgitにコミットしない**

#### 3. チームメンバーへの共有方法

`GoogleService-Info.plist`を共有する必要がある場合：

- **推奨**: 暗号化された共有サービス（1Password、Bitwardenなど）を使用
- **代替**: 直接メールやチャットで共有（リポジトリには含めない）

### Git履歴からの削除

過去にコミットされた機密情報を削除するには：

```bash
# git filter-branchを使用（注意: 履歴を書き換えます）
git filter-branch --force --index-filter \
  "git rm --cached --ignore-unmatch Soramoyou/Soramoyou/GoogleService-Info.plist" \
  --prune-empty --tag-name-filter cat -- --all

# または BFG Repo-Cleaner を使用（より高速）
# https://rtyley.github.io/bfg-repo-cleaner/
```

**注意**: 履歴を書き換えると、リモートリポジトリにforce pushが必要になります。チームメンバーと調整してください。

### ベストプラクティス

1. **`.gitignore`の確認**: 機密情報を含むファイルが確実に無視されているか確認
2. **コミット前の確認**: `git status`で機密ファイルが含まれていないか確認
3. **APIキーの制限**: Google Cloud ConsoleでAPIキーに適切な制限を設定
4. **定期的な監査**: 定期的にリポジトリをスキャンして機密情報が漏洩していないか確認

### 参考リンク

- [Firebase: アプリにFirebaseを追加する](https://firebase.google.com/docs/ios/setup)
- [Google Cloud: APIキーの制限](https://cloud.google.com/docs/authentication/api-keys#restricting_apis)
- [GitHub: 機密情報の削除](https://docs.github.com/ja/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
