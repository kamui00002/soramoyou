# アクセシビリティ識別子 追加ガイド

UIテストを実行するために、各ビューにアクセシビリティ識別子を追加する必要があります。

## ✅ 修正が必要なファイル一覧

### 1. WelcomeView.swift

**ファイルパス**: `Soramoyou/Soramoyou/Views/WelcomeView.swift`

**追加箇所**:

```swift
var body: some View {
    VStack {
        // ... 既存のコード ...
    }
    .accessibilityIdentifier("WelcomeView") // ← 追加
}
```

**詳細**: ウェルカム画面全体に識別子を追加

---

### 2. ContentView.swift

**ファイルパス**: `Soramoyou/Soramoyou/Views/ContentView.swift`

**追加箇所**:

```swift
var body: some View {
    TabView(selection: $selectedTab) {
        // ... 既存のコード ...
    }
    .accessibilityIdentifier("ContentView") // ← 追加
}
```

**詳細**: メインタブビュー全体に識別子を追加

---

### 3. HomeView.swift（最重要）

**ファイルパス**: `Soramoyou/Soramoyou/Views/HomeView.swift`

#### 3-1. PostCard（投稿カード）に識別子を追加

**変更前**:
```swift
private func postCard(for post: Post) -> some View {
    VStack(spacing: 0) {
        // ... 投稿カードのUI ...
    }
}
```

**変更後**:
```swift
private func postCard(for post: Post) -> some View {
    VStack(spacing: 0) {
        // ... 投稿カードのUI ...
    }
    .accessibilityIdentifier("PostCard") // ← 追加
}
```

#### 3-2. PostDetailView（投稿詳細）に識別子を追加

**変更前**:
```swift
private func postDetailView(for post: Post) -> some View {
    ScrollView {
        // ... 詳細画面のUI ...
    }
}
```

**変更後**:
```swift
private func postDetailView(for post: Post) -> some View {
    ScrollView {
        // ... 詳細画面のUI ...
    }
    .accessibilityIdentifier("PostDetailView") // ← 追加
}
```

#### 3-3. メニューボタン（...）に識別子を追加

**変更前**:
```swift
Button(action: { showMenu = true }) {
    Image(systemName: "ellipsis")
        .imageScale(.large)
        .foregroundColor(.primary)
}
```

**変更後**:
```swift
Button(action: { showMenu = true }) {
    Image(systemName: "ellipsis")
        .imageScale(.large)
        .foregroundColor(.primary)
}
.accessibilityIdentifier("PostMenuButton") // ← 追加
```

#### 3-4. 通報ボタンに識別子を追加

**変更前**:
```swift
Button("この投稿を通報する") {
    showReportSheet = true
}
```

**変更後**:
```swift
Button("この投稿を通報する") {
    showReportSheet = true
}
.accessibilityIdentifier("この投稿を通報する") // ← 追加
```

#### 3-5. ブロックボタンに識別子を追加

**変更前**:
```swift
Button("このユーザーをブロック") {
    showBlockAlert = true
}
```

**変更後**:
```swift
Button("このユーザーをブロック") {
    showBlockAlert = true
}
.accessibilityIdentifier("このユーザーをブロック") // ← 追加
```

---

### 4. ProfileView.swift

**ファイルパス**: `Soramoyou/Soramoyou/Views/ProfileView.swift`

#### 4-1. ProfileView全体に識別子を追加

**変更前**:
```swift
var body: some View {
    VStack {
        // ... プロフィール画面のUI ...
    }
}
```

**変更後**:
```swift
var body: some View {
    VStack {
        // ... プロフィール画面のUI ...
    }
    .accessibilityIdentifier("ProfileView") // ← 追加
}
```

#### 4-2. プロフィール画像に識別子を追加

**変更前**:
```swift
AsyncImage(url: URL(string: user.photoURL ?? "")) { image in
    image.resizable().scaledToFill()
} placeholder: {
    Image(systemName: "person.circle.fill")
}
.frame(width: 80, height: 80)
.clipShape(Circle())
```

**変更後**:
```swift
AsyncImage(url: URL(string: user.photoURL ?? "")) { image in
    image.resizable().scaledToFill()
} placeholder: {
    Image(systemName: "person.circle.fill")
}
.frame(width: 80, height: 80)
.clipShape(Circle())
.accessibilityIdentifier("profileImage") // ← 追加
```

#### 4-3. ユーザー名に識別子を追加

**変更前**:
```swift
Text(user.displayName)
    .font(.title2)
    .fontWeight(.bold)
```

**変更後**:
```swift
Text(user.displayName)
    .font(.title2)
    .fontWeight(.bold)
    .accessibilityIdentifier("displayName") // ← 追加
```

---

### 5. SettingsView.swift

**ファイルパス**: `Soramoyou/Soramoyou/Views/SettingsView.swift`

#### 5-1. SettingsView全体に識別子を追加

**変更前**:
```swift
var body: some View {
    List {
        // ... 設定画面のUI ...
    }
}
```

**変更後**:
```swift
var body: some View {
    List {
        // ... 設定画面のUI ...
    }
    .accessibilityIdentifier("SettingsView") // ← 追加
}
```

#### 5-2. アカウント削除ボタンに識別子を追加

**変更前**:
```swift
Button("アカウントを削除") {
    showDeleteAccountAlert = true
}
.foregroundColor(.red)
```

**変更後**:
```swift
Button("アカウントを削除") {
    showDeleteAccountAlert = true
}
.foregroundColor(.red)
.accessibilityIdentifier("アカウントを削除") // ← 追加
```

---

### 6. GalleryDetailView.swift

**ファイルパス**: `Soramoyou/Soramoyou/Views/GalleryDetailView.swift`

#### 6-1. メニューボタンに識別子を追加

**変更前**:
```swift
Button(action: { showMenu = true }) {
    Image(systemName: "ellipsis")
}
```

**変更後**:
```swift
Button(action: { showMenu = true }) {
    Image(systemName: "ellipsis")
}
.accessibilityIdentifier("PostMenuButton") // ← 追加
```

#### 6-2. 通報・ブロックボタンに識別子を追加

HomeView.swiftと同様に、通報ボタンとブロックボタンに識別子を追加してください。

---

### 7. BannerAdView.swift

**ファイルパス**: `Soramoyou/Soramoyou/Views/BannerAdView.swift`

**追加箇所**:

```swift
var body: some View {
    // ... 広告バナーのUI ...
        .accessibilityIdentifier("BannerAdView") // ← 追加
}
```

**詳細**: 広告バナー全体に識別子を追加

---

## 🔍 識別子の確認方法

### Xcodeでアクセシビリティ識別子を確認

1. Xcodeで **Debug** → **View Debugging** → **Capture View Hierarchy** を実行
2. 左サイドバーでビュー階層を確認
3. 各要素の **Accessibility Identifier** が設定されているか確認

### UIテストで識別子を確認

UIテストコード内で以下のように識別子を使用します：

```swift
let welcomeView = app.otherElements["WelcomeView"]
XCTAssertTrue(welcomeView.exists, "WelcomeViewが見つからない")
```

---

## ⚠️ 注意事項

### 1. ボタンテキストと識別子を同じにする

ボタンの場合、`.accessibilityIdentifier()` をボタンテキストと同じにすると、UIテストで見つけやすくなります。

**例**:
```swift
Button("ログイン") {
    // ...
}
.accessibilityIdentifier("ログイン") // ボタンテキストと同じ
```

### 2. ユニークな識別子を使用する

同じ画面内で同じ識別子を使用しないようにしてください。UIテストが誤った要素を検出する可能性があります。

### 3. 識別子の命名規則

- **ビュー全体**: `ViewName` (例: "ProfileView", "SettingsView")
- **ボタン**: ボタンのテキストまたは `ButtonName` (例: "ログイン", "PostMenuButton")
- **テキストフィールド**: フィールド名 (例: "メールアドレス", "パスワード")
- **画像**: `imageName` (例: "profileImage", "postImage")

---

## 📝 修正後の確認手順

1. **ビルドエラーがないか確認**
   ```
   Xcodeでビルド: ⌘ + B (Command + B)
   ```

2. **UIテストを実行**
   ```
   Xcodeでテスト: ⌘ + U (Command + U)
   ```

3. **テスト結果を確認**
   - Test Navigator（左サイドバー、ダイヤモンドアイコン）でテスト結果を確認
   - 全てのテストが成功（✅）していることを確認

---

## 🎯 完了チェックリスト

- [ ] WelcomeView.swift に識別子を追加
- [ ] ContentView.swift に識別子を追加
- [ ] HomeView.swift に識別子を追加（PostCard, PostDetailView, メニューボタン、通報・ブロックボタン）
- [ ] ProfileView.swift に識別子を追加（ProfileView, profileImage, displayName）
- [ ] SettingsView.swift に識別子を追加（SettingsView, アカウント削除ボタン）
- [ ] GalleryDetailView.swift に識別子を追加（メニューボタン、通報・ブロックボタン）
- [ ] BannerAdView.swift に識別子を追加
- [ ] ビルドエラーがないことを確認
- [ ] UIテストを実行して全て成功することを確認
