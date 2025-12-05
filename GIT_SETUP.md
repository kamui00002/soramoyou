# Gitリポジトリ設定手順

## 現在の状態
- ✅ ローカルGitリポジトリは初期化済み
- ✅ 初回コミット完了（3ファイル: SESSION_SUMMARY.md, init.json, requirements.md）
- ⏳ GitHubリモートリポジトリは未設定

## GitHubにpushする手順

### 方法1: GitHub CLIを使用（推奨）

```bash
cd /Users/yoshidometoru/そらもよう

# GitHub CLIでリポジトリを作成してpush
gh repo create そらもよう --public --source=. --remote=origin --push
```

### 方法2: GitHub Web UIを使用

1. **GitHubでリポジトリを作成**
   - https://github.com/new にアクセス
   - Repository name: `そらもよう`
   - Description: `空の写真を投稿・編集・共有するSNSアプリ`
   - Public/Privateを選択
   - **「Initialize this repository with a README」はチェックしない**
   - 「Create repository」をクリック

2. **リモートを追加してpush**
   ```bash
   cd /Users/yoshidometoru/そらもよう
   
   # リモートを追加（YOUR_USERNAMEを自分のGitHubユーザー名に置き換え）
   git remote add origin https://github.com/YOUR_USERNAME/そらもよう.git
   
   # ブランチ名をmainに設定（既にmainの場合は不要）
   git branch -M main
   
   # push
   git push -u origin main
   ```

### 方法3: SSHを使用

```bash
cd /Users/yoshidometoru/そらもよう

# SSH URLでリモートを追加（YOUR_USERNAMEを自分のGitHubユーザー名に置き換え）
git remote add origin git@github.com:YOUR_USERNAME/そらもよう.git

# ブランチ名をmainに設定
git branch -M main

# push
git push -u origin main
```

## 現在のコミット履歴

```
5c63cb8 初期化: そらもようプロジェクトの要件定義を作成
```

## 今後のコミット例

```bash
# 要件定義の更新
git add requirements.md init.json
git commit -m "更新: 要件定義を修正"

# 設計ドキュメント追加
git add design.md research.md
git commit -m "追加: 設計ドキュメントを作成"

# タスクリスト追加
git add tasks.md
git commit -m "追加: 実装タスクリストを作成"
```

## 注意事項
- リポジトリ名に日本語（「そらもよう」）を使用しているため、一部のツールで問題が発生する可能性があります
- 問題が発生する場合は、リポジトリ名を `soramoyou` などの英数字に変更することを検討してください

