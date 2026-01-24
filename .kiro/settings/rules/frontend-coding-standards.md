# Frontend Coding Standards

## コンポーネント規約

### Functional Component
- コンポーネントは必ず **Functional Component** で記述する
- Class Componentは使用しない

```tsx
// Good
const UserCard: React.FC<UserCardProps> = ({ name, email }) => {
  return (
    <div>
      <h2>{name}</h2>
      <p>{email}</p>
    </div>
  );
};

// Bad
class UserCard extends React.Component<UserCardProps> {
  render() {
    return <div>...</div>;
  }
}
```

## 命名規則

### 関数名: camelCase
```typescript
// Good
const fetchUserData = async () => { ... };
const handleClick = () => { ... };
const formatDate = (date: Date) => { ... };

// Bad
const FetchUserData = async () => { ... };
const handle_click = () => { ... };
```

### コンポーネント名: PascalCase
```typescript
// Good
const UserProfile: React.FC = () => { ... };
const NavigationBar: React.FC = () => { ... };

// Bad
const userProfile: React.FC = () => { ... };
const navigation_bar: React.FC = () => { ... };
```

## 禁止事項

### 1. `any` 型の使用は最小限に
- 明示的な型定義を優先する
- やむを得ない場合は `unknown` の使用を検討する

```typescript
// Good
interface User {
  id: string;
  name: string;
}
const getUser = (id: string): User => { ... };

// Bad
const getUser = (id: any): any => { ... };
```

### 2. `console.log` を本番コードに残さない
- デバッグ用の `console.log` はコミット前に削除する
- ログが必要な場合は専用のロギングサービスを使用する

```typescript
// Good
logger.info('User logged in', { userId });

// Bad
console.log('User logged in', userId);
```

### 3. 既存のテストを削除しない
- テストの修正は可、削除は不可
- テストが不要になった場合はスキップ（`.skip`）で対応し、理由をコメントで残す

```typescript
// Good - テストを修正
it('should return user data', () => {
  // 修正されたテストコード
});

// Good - 一時的にスキップ（理由付き）
it.skip('should return user data', () => {
  // TODO: API変更後に修正予定
});

// Bad - テストを削除
// (削除されたテスト)
```
