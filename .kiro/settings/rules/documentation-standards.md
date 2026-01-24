# Documentation Standards

## 見出し規約

### 見出しは名詞句で始める
- 動詞ではなく名詞句で見出しを構成する
- 簡潔で内容を的確に表す

```markdown
<!-- Good -->
## ユーザー認証の設定
## API エンドポイント一覧
## エラーハンドリング

<!-- Bad -->
## ユーザー認証を設定する
## API エンドポイントを一覧する
## エラーをハンドリングする
```

## コード例規約

### コード例には必ず説明を添える
- コードブロックの前後に説明文を記載する
- 何をするコードか、なぜそう書くのかを明記する

```markdown
<!-- Good -->
ユーザー情報を取得するには、`fetchUser` 関数を使用します。
引数にユーザーIDを渡すと、該当するユーザーオブジェクトを返します。

\`\`\`typescript
const user = await fetchUser(userId);
\`\`\`

<!-- Bad -->
\`\`\`typescript
const user = await fetchUser(userId);
\`\`\`
```

## 画像規約

### 画像にはalt属性を付ける
- すべての画像に説明的なalt属性を設定する
- スクリーンリーダー対応とSEOのために必須

```markdown
<!-- Good -->
![ログイン画面のスクリーンショット](./images/login-screen.png)
![システム構成図：フロントエンドからバックエンドへのデータフロー](./images/architecture.png)

<!-- Bad -->
![](./images/login-screen.png)
![image](./images/architecture.png)
```

### JSX/TSXでの画像
```tsx
// Good
<img src={loginImage} alt="ログイン画面のスクリーンショット" />

// Bad
<img src={loginImage} />
<img src={loginImage} alt="" />
```
