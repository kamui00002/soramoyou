# Research & Design Decisions Template

---
**Purpose**: Capture discovery findings, architectural investigations, and rationale that inform the technical design.

**Usage**:
- Log research activities and outcomes during the discovery phase.
- Document design decision trade-offs that are too detailed for `design.md`.
- Provide references and evidence for future audits or reuse.
---

## Summary
- **Feature**: そらもよう
- **Discovery Scope**: New Feature (Greenfield iOS SNS Application)
- **Key Findings**:
  - SwiftUI + MVVMアーキテクチャパターンが最適（SwiftUIの標準的な状態管理パターン）
  - Firebase Authentication, Firestore, Storageの統合が要件を満たす
  - Core Image / CIFilterによるリアルタイム画像編集が可能
  - 画像処理のパフォーマンス最適化が重要（メモリ管理、非同期処理）

## Research Log

### iOSアプリケーションアーキテクチャパターン
- **Context**: SwiftUIアプリケーションに適したアーキテクチャパターンの選定
- **Sources Consulted**: 
  - SwiftUI公式ドキュメント
  - iOS開発ベストプラクティス
  - MVVMパターンのiOS実装
- **Findings**: 
  - SwiftUIは宣言的UIフレームワークで、MVVMパターンと自然に適合
  - `@StateObject`, `@ObservedObject`, `@State`による状態管理が標準
  - ViewModelがビジネスロジックと状態を管理し、Viewは表示のみに集中
  - Combineフレームワークとの統合でリアクティブなデータフローを実現
- **Implications**: 
  - 各機能モジュールにViewModelを配置
  - ViewModelはFirebaseサービスと通信し、Viewに状態を公開
  - 状態の変更は`@Published`プロパティを通じて自動的にViewに反映

### Firebase統合アーキテクチャ
- **Context**: Firebase Authentication, Firestore, Storageの統合方法
- **Sources Consulted**:
  - Firebase iOS SDK公式ドキュメント
  - Firestoreセキュリティルール設計
  - Firebase Storageベストプラクティス
- **Findings**:
  - Firebase Authentication: メール/パスワード認証が標準的
  - Firestore: NoSQLドキュメントデータベース、リアルタイム同期対応
  - Firebase Storage: 画像ファイルの保存、セキュリティルールでアクセス制御
  - Firestore Security Rulesでユーザー認証とデータアクセス制御を実現
- **Implications**:
  - 認証状態はFirebase Authの`AuthStateDidChangeListener`で監視
  - Firestoreクエリはインデックス設計が重要（検索機能のパフォーマンス）
  - 画像アップロードは非同期処理で、進捗表示が必要
  - エラーハンドリングはFirebase SDKのエラータイプに基づく

### 画像処理とパフォーマンス
- **Context**: Core Image / CIFilterによるリアルタイム画像編集の実装
- **Sources Consulted**:
  - Core Image Framework公式ドキュメント
  - CIFilterリファレンス
  - iOS画像処理パフォーマンス最適化
- **Findings**:
  - Core ImageはGPUアクセラレーション対応で高速
  - CIFilterはチェーン可能で、複数のフィルターを組み合わせ可能
  - リアルタイムプレビューには低解像度サムネイルを使用してパフォーマンス向上
  - メモリ管理が重要（大きな画像はメモリ不足の原因）
  - 画像のリサイズと圧縮は`UIImage`の`jpegData(compressionQuality:)`で実現
- **Implications**:
  - 編集時はサムネイル（512x512など）でプレビュー
  - 最終保存時にフル解像度で処理
  - 画像処理はバックグラウンドスレッドで実行
  - メモリ効率のため、処理済み画像は適切に解放

### データモデル設計
- **Context**: Firestoreコレクション構造とクエリパターン
- **Sources Consulted**:
  - Firestoreデータモデリングガイド
  - NoSQLデータベース設計パターン
- **Findings**:
  - Firestoreはコレクションとドキュメントの階層構造
  - クエリの効率化には複合インデックスが必要
  - 配列フィールドでの検索は`array-contains`クエリを使用
  - ページネーションは`startAfter`と`limit`で実現
  - 色検索は色の類似度計算が必要（RGB距離計算など）
- **Implications**:
  - `users`, `posts`, `drafts`コレクションを設計
  - 検索クエリ用のインデックスを事前に定義
  - ハッシュタグは配列フィールドに保存し、`array-contains`で検索
  - 色検索は範囲クエリまたは近似色マッチングを実装

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| MVVM | Model-View-ViewModelパターン | SwiftUIと自然に適合、テスト容易、状態管理が明確 | ViewModelの肥大化リスク | SwiftUIの標準パターン、採用決定 |
| MVC | Model-View-Controllerパターン | シンプル、理解しやすい | SwiftUIでは不自然、状態管理が複雑 | SwiftUIでは非推奨 |
| Clean Architecture | レイヤー分離、依存性逆転 | テスタビリティ高、保守性良好 | 過剰設計のリスク、学習コスト | 大規模アプリ向け、今回は過剰 |

## Design Decisions

### Decision: MVVMアーキテクチャパターンの採用
- **Context**: SwiftUIアプリケーションのアーキテクチャパターン選定
- **Alternatives Considered**:
  1. MVC — SwiftUIでは不自然で、状態管理が複雑になる
  2. Clean Architecture — 過剰設計のリスク、学習コストが高い
  3. MVVM — SwiftUIの標準パターン、状態管理が明確
- **Selected Approach**: MVVMパターンを採用
  - View: SwiftUI View（表示のみ）
  - ViewModel: `ObservableObject`を実装し、`@Published`で状態を公開
  - Model: データ構造とFirebaseサービス層
- **Rationale**: 
  - SwiftUIの宣言的UIと自然に適合
  - `@StateObject`, `@ObservedObject`による状態管理が標準的
  - ビジネスロジックとUIの分離が明確
  - テスト容易性が高い
- **Trade-offs**: 
  - メリット: 状態管理が明確、テスト容易、SwiftUI標準
  - デメリット: ViewModelの肥大化に注意が必要
- **Follow-up**: ViewModelの責務を明確にし、必要に応じてService層を分離

### Decision: Firebase統合アーキテクチャ
- **Context**: バックエンドサービスとしてFirebaseを採用
- **Alternatives Considered**:
  1. 自前バックエンド（Node.js, Python等） — 開発・運用コストが高い
  2. AWS Amplify — 学習コスト、複雑性
  3. Firebase — 認証、データベース、ストレージが統合、開発速度が速い
- **Selected Approach**: Firebase統合
  - Authentication: ユーザー認証
  - Firestore: データベース（users, posts, drafts）
  - Storage: 画像ファイル保存
- **Rationale**: 
  - MVP開発に最適（開発速度、運用コスト）
  - 認証、データベース、ストレージが統合
  - リアルタイム同期対応
  - セキュリティルールでアクセス制御
- **Trade-offs**: 
  - メリット: 開発速度、統合性、スケーラビリティ
  - デメリット: ベンダーロックイン、クエリの柔軟性に制限
- **Follow-up**: Firestoreのクエリパターンを最適化、インデックス設計

### Decision: 画像処理のパフォーマンス最適化
- **Context**: リアルタイム画像編集のパフォーマンス要件
- **Alternatives Considered**:
  1. フル解像度でリアルタイム処理 — メモリ不足、パフォーマンス低下
  2. サムネイルプレビュー + フル解像度保存 — パフォーマンスと品質のバランス
  3. サーバーサイド処理 — レイテンシ、コスト
- **Selected Approach**: サムネイルプレビュー + フル解像度保存
  - 編集時: 512x512サムネイルでプレビュー
  - 保存時: 最大2048x2048で処理・保存
  - バックグラウンドスレッドで処理
- **Rationale**: 
  - リアルタイムプレビューのパフォーマンス確保
  - 最終品質はフル解像度で維持
  - メモリ使用量の最適化
- **Trade-offs**: 
  - メリット: パフォーマンス、メモリ効率、ユーザー体験
  - デメリット: 実装の複雑性（2段階処理）
- **Follow-up**: メモリプロファイリング、処理時間の測定

### Decision: データモデル設計（Firestore）
- **Context**: Firestoreコレクション構造とクエリパターン
- **Alternatives Considered**:
  1. 正規化設計 — クエリが複雑、読み取り回数増加
  2. 非正規化設計 — データ重複、更新の複雑性
  3. ハイブリッド設計 — 読み取り頻度の高いデータは非正規化、その他は正規化
- **Selected Approach**: ハイブリッド設計
  - `users`: ユーザー情報（正規化）
  - `posts`: 投稿情報（非正規化、ユーザー情報を埋め込み）
  - `drafts`: 下書き（ユーザーごとに分離）
- **Rationale**: 
  - フィード表示のパフォーマンス向上（1回のクエリで取得）
  - ユーザー情報の更新は`users`コレクションのみ
  - 検索クエリの最適化
- **Trade-offs**: 
  - メリット: クエリパフォーマンス、読み取り回数の削減
  - デメリット: データ整合性の管理（更新時の同期）
- **Follow-up**: Firestore Security Rulesで整合性を保証、Cloud Functionsで更新同期（将来）

## Risks & Mitigations
- **リスク1**: 画像処理のメモリ不足 — **対策**: サムネイルプレビュー、メモリプール、適切な解放
- **リスク2**: Firestoreクエリのパフォーマンス — **対策**: インデックス設計、ページネーション、キャッシュ
- **リスク3**: リアルタイム編集のパフォーマンス — **対策**: バックグラウンド処理、非同期処理、最適化されたCIFilterチェーン
- **リスク4**: セキュリティルールの複雑性 — **対策**: 段階的な実装、テスト、ドキュメント化

## References
- [Firebase iOS SDK Documentation](https://firebase.google.com/docs/ios/setup)
- [SwiftUI Documentation](https://developer.apple.com/documentation/swiftui/)
- [Core Image Framework](https://developer.apple.com/documentation/coreimage)
- [Firestore Data Modeling](https://firebase.google.com/docs/firestore/manage-data/structure-data)

