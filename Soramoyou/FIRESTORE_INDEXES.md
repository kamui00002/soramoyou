# Firestore インデックス設定

このドキュメントでは、そらもようアプリで使用するFirestoreインデックスの設定について説明します。

## インデックス設定方法

Firestoreコンソールでインデックスを設定するか、`firestore.indexes.json`ファイルをFirebase CLIでデプロイしてください。

```bash
firebase deploy --only firestore:indexes
```

## 必要なインデックス一覧

### 1. フィード取得用インデックス（posts）

**用途**: 公開投稿の一覧取得（`fetchPosts`）

**フィールド**:
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

**クエリ例**:
```swift
postsCollection
    .whereField("visibility", isEqualTo: Visibility.public.rawValue)
    .order(by: "createdAt", descending: true)
```

### 2. ユーザー投稿一覧用インデックス（posts）

**用途**: 特定ユーザーの投稿一覧取得（`fetchUserPosts`）

**フィールド**:
- `userId` (ASCENDING)
- `createdAt` (DESCENDING)

**クエリ例**:
```swift
postsCollection
    .whereField("userId", isEqualTo: userId)
    .order(by: "createdAt", descending: true)
```

### 3. ハッシュタグ検索用インデックス（posts）

**用途**: ハッシュタグによる検索（`searchByHashtag`）

**フィールド**:
- `hashtags` (ARRAY_CONTAINS)
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

**クエリ例**:
```swift
postsCollection
    .whereField("hashtags", arrayContains: hashtag)
    .whereField("visibility", isEqualTo: Visibility.public.rawValue)
    .order(by: "createdAt", descending: true)
```

### 4. 色検索用インデックス（posts）

**用途**: 色による検索（`searchByColor`）

**フィールド**:
- `skyColors` (ARRAY_CONTAINS)
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

**クエリ例**:
```swift
postsCollection
    .whereField("skyColors", arrayContains: color)
    .whereField("visibility", isEqualTo: Visibility.public.rawValue)
    .order(by: "createdAt", descending: true)
```

### 5. 時間帯検索用インデックス（posts）

**用途**: 時間帯による検索（`searchByTimeOfDay`）

**フィールド**:
- `timeOfDay` (ASCENDING)
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

**クエリ例**:
```swift
postsCollection
    .whereField("timeOfDay", isEqualTo: timeOfDay.rawValue)
    .whereField("visibility", isEqualTo: Visibility.public.rawValue)
    .order(by: "createdAt", descending: true)
```

### 6. 空の種類検索用インデックス（posts）

**用途**: 空の種類による検索（`searchBySkyType`）

**フィールド**:
- `skyType` (ASCENDING)
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

**クエリ例**:
```swift
postsCollection
    .whereField("skyType", isEqualTo: skyType.rawValue)
    .whereField("visibility", isEqualTo: Visibility.public.rawValue)
    .order(by: "createdAt", descending: true)
```

### 7. 複合検索用インデックス（posts - ハッシュタグ + 時間帯）

**用途**: ハッシュタグと時間帯の複合検索

**フィールド**:
- `hashtags` (ARRAY_CONTAINS)
- `timeOfDay` (ASCENDING)
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

### 8. 複合検索用インデックス（posts - ハッシュタグ + 空の種類）

**用途**: ハッシュタグと空の種類の複合検索

**フィールド**:
- `hashtags` (ARRAY_CONTAINS)
- `skyType` (ASCENDING)
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

### 9. 複合検索用インデックス（posts - 時間帯 + 空の種類）

**用途**: 時間帯と空の種類の複合検索

**フィールド**:
- `timeOfDay` (ASCENDING)
- `skyType` (ASCENDING)
- `visibility` (ASCENDING)
- `createdAt` (DESCENDING)

### 10. 下書き一覧用インデックス（drafts）

**用途**: ユーザーの下書き一覧取得（`fetchDrafts`）

**フィールド**:
- `userId` (ASCENDING)
- `updatedAt` (DESCENDING)

**クエリ例**:
```swift
draftsCollection
    .whereField("userId", isEqualTo: userId)
    .order(by: "updatedAt", descending: true)
```

## インデックスの自動作成

Firestoreは、クエリを実行した際に必要なインデックスが存在しない場合、エラーメッセージにインデックス作成用のリンクを表示します。そのリンクをクリックすると、Firestoreコンソールでインデックスを作成できます。

## 注意事項

- インデックスの作成には時間がかかる場合があります（数分から数時間）
- 複合インデックスは、使用するクエリの組み合わせに応じて追加で作成する必要があります
- インデックスが作成されるまで、該当するクエリは実行できません


