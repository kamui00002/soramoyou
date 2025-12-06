# Implementation Plan

## タスク一覧

- [x] 1. プロジェクト基盤とFirebase設定
- [x] 1.1 (P) iOSプロジェクトの初期化と依存関係の設定
  - Xcodeプロジェクトの作成（SwiftUI、iOS 15.0+）
  - Swift Package ManagerでFirebase SDK、Kingfisher、Google Mobile Ads SDKを追加
  - Info.plistに必要な権限設定（カメラロール、位置情報）
  - _Requirements: 15.5_

- [x] 1.2 (P) Firebaseプロジェクトの設定と統合
  - Firebase Consoleでプロジェクト作成
  - GoogleService-Info.plistを追加（.gitignoreに追加）
  - Firebase Authentication、Firestore、Storageの有効化
  - 初期セキュリティルールの設定
  - _Requirements: 1.3, 8.2, 15.1, 15.4, 15.5_

- [ ] 2. データモデルとドメイン層の実装
- [ ] 2.1 ユーザーモデルの実装
  - Userエンティティの定義（userId, email, displayName, photoURL, bio, customEditTools, customEditToolsOrder等）
  - Firestoreドキュメントとのマッピング
  - _Requirements: 1.3, 5.6, 12.5_

- [ ] 2.2 投稿モデルの実装
  - Postエンティティの定義（postId, userId, images, caption, hashtags, location, skyColors等）
  - ImageInfo、Location、Visibility等のValue Object定義
  - Firestoreドキュメントとのマッピング
  - _Requirements: 6.1, 7.7, 8.4_

- [ ] 2.3 下書きモデルの実装
  - Draftエンティティの定義（draftId, userId, images, editedImages, editSettings等）
  - EditSettings Value Objectの定義
  - Firestoreドキュメントとのマッピング
  - _Requirements: 9.1_

- [ ] 2.4 編集ツールとフィルターの列挙型定義
  - FilterType enum（10種類のフィルター）
  - EditTool enum（27種類の編集ツール）
  - TimeOfDay、SkyType、Visibility enum
  - _Requirements: 3.1, 4.4, 7.2, 7.6_

- [ ] 3. 認証サービスの実装
- [ ] 3.1 AuthServiceの実装
  - Firebase Authentication統合
  - メール/パスワード認証メソッド（signIn, signUp, signOut）
  - 認証状態の監視（observeAuthState）
  - エラーハンドリング
  - _Requirements: 1.3, 1.5, 1.6, 1.8_

- [ ] 3.2 AuthViewModelの実装
  - 認証状態の管理（@Publishedプロパティ）
  - ログイン/新規登録の処理
  - 認証エラーの処理と表示
  - 自動ログイン機能
  - _Requirements: 1.1, 1.2, 1.4, 1.6, 1.7, 1.8_

- [ ] 3.3 認証UIの実装
  - ウェルカム画面
  - ログイン画面
  - 新規登録画面
  - エラーメッセージ表示
  - _Requirements: 1.1, 1.2, 1.4, 1.6, 1.7_

- [ ] 4. 画像処理サービスの実装
- [ ] 4.1 ImageServiceの基本実装
  - Core Image / CIFilterの統合
  - 画像読み込みとバリデーション
  - バックグラウンドスレッドでの処理
  - _Requirements: 3.5, 14.1, 14.2_

- [ ] 4.2 フィルター機能の実装
  - 10種類のフィルター（ナチュラル、クリア、ドラマ、ソフト、ウォーム、クール、ビンテージ、モノクロ、パステル、ヴィヴィッド）の適用
  - リアルタイムプレビュー生成（サムネイル512x512）
  - フィルターの切り替えと解除
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

- [ ] 4.3 編集ツール機能の実装
  - 27種類の編集ツールの適用（露出、明るさ、コントラスト等）
  - スライダーによるパラメータ調整
  - リアルタイムプレビュー更新
  - 編集パラメータの範囲検証
  - _Requirements: 4.1, 4.2, 4.3, 4.4_

- [ ] 4.4 画像分析機能の実装
  - EXIF情報の抽出（撮影時刻）
  - 時間帯の自動判定（morning/afternoon/evening/night）
  - 主要色の抽出（最大5色、16進数カラーコード）
  - 色温度の計算（K表示）
  - 空の種類の自動判定（clear/cloudy/sunset/sunrise/storm）- Core ImageとVision Frameworkを使用
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7_

- [ ] 4.5 画像圧縮・リサイズ機能の実装
  - 最大解像度2048x2048ピクセルへのリサイズ
  - JPEG形式での圧縮（圧縮率80-90%）
  - ファイルサイズ5MB以下への圧縮
  - サムネイル画像の生成
  - _Requirements: 2.8, 8.1, 14.1, 14.2, 14.3, 14.4_

- [ ] 5. Firestoreサービスの実装
- [ ] 5.1 FirestoreServiceの基本実装
  - Firestore SDKの統合
  - コレクション参照の管理
  - エラーハンドリング
  - _Requirements: 8.4, 9.1, 10.1, 11.1_

- [ ] 5.2 投稿データ操作の実装
  - 投稿の作成（createPost）
  - 投稿の取得（fetchPosts、fetchPost）- ページネーション対応
  - 投稿の削除（deletePost）
  - 公開設定に基づくフィルタリング
  - _Requirements: 8.4, 10.1, 10.5, 12.2_

- [ ] 5.3 下書きデータ操作の実装
  - 下書きの保存（saveDraft）
  - 下書きの取得（fetchDrafts、loadDraft）
  - 下書きの削除（deleteDraft）
  - _Requirements: 9.1, 9.3, 9.5_

- [ ] 5.4 ユーザーデータ操作の実装
  - ユーザー情報の取得（fetchUser）
  - ユーザー情報の更新（updateUser）
  - 編集装備ツールの更新（updateEditTools）
  - ユーザー投稿一覧の取得（fetchUserPosts）
  - _Requirements: 5.6, 12.3, 12.5, 12.6_

- [ ] 5.5 検索機能の実装
  - ハッシュタグ検索（searchByHashtag）- array-containsクエリ
  - 時間帯検索（searchByTimeOfDay）
  - 空の種類検索（searchBySkyType）
  - 色検索（searchByColor）- クライアント側フィルタリング（RGB距離計算）
  - 複合検索（複数条件の組み合わせ）
  - _Requirements: 11.2, 11.3, 11.4, 11.5, 11.6_

- [ ] 5.6 Firestoreインデックスの設定
  - フィード取得用インデックス（visibility + createdAt）
  - ユーザー投稿一覧用インデックス（userId + createdAt）
  - ハッシュタグ検索用インデックス（hashtags配列）
  - 時間帯検索用インデックス（timeOfDay + createdAt）
  - 空の種類検索用インデックス（skyType + createdAt）
  - _Requirements: 10.1, 11.2, 11.4, 11.5_

- [ ] 6. Storageサービスの実装
- [ ] 6.1 StorageServiceの実装
  - Firebase Storage SDKの統合
  - 画像アップロード（uploadImage、uploadThumbnail）
  - 画像削除（deleteImage）
  - アップロード進捗の監視（uploadProgress）
  - エラーハンドリングとリトライ機能
  - _Requirements: 8.2, 8.3, 12.6, 14.4_

- [ ] 7. 投稿フローの実装
- [ ] 7.1 写真選択機能の実装
  - PHPickerViewControllerの統合
  - カメラロールへのアクセス許可リクエスト
  - 写真選択UI（最大3枚/10枚の制限）
  - 選択写真のプレビュー表示
  - 画像サイズ・ファイルサイズの検証
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8_

- [ ] 7.2 EditViewModelの実装
  - 画像編集状態の管理
  - フィルター適用の管理
  - 編集ツール適用の管理（装備ツールのみ表示）
  - リアルタイムプレビューの生成
  - 編集パラメータの管理
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 5.7_

- [ ] 7.3 編集画面UIの実装
  - 画像プレビュー表示
  - フィルター選択UI（10種類）
  - 編集ツール選択UI（装備ツールのみ）
  - スライダーによるパラメータ調整
  - リアルタイムプレビュー更新
  - _Requirements: 3.1, 3.2, 4.1, 4.2, 4.3_

- [ ] 7.4 PostViewModelの実装
  - 写真選択の管理
  - 編集済み画像の管理
  - 投稿情報の管理（キャプション、ハッシュタグ、位置情報、公開設定）
  - 投稿保存処理（画像アップロード、Firestore保存）- 整合性保証戦略の実装
  - 下書き保存・読み込み処理
  - エラーハンドリングとロールバック処理
  - _Requirements: 2.7, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.9, 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 9.1, 9.2_

- [ ] 7.5 投稿情報入力画面UIの実装
  - 編集済み写真のプレビュー表示
  - キャプション入力フィールド
  - ハッシュタグ入力と抽出機能
  - 位置情報追加機能（CoreLocation統合）
  - 地図表示とランドマーク選択（MapKit統合）
  - 公開設定選択UI
  - 投稿ボタンと下書き保存ボタン
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.9, 9.1_

- [ ] 7.6 自動情報抽出の統合
  - 写真選択時のEXIF情報抽出
  - 時間帯の自動判定と表示
  - 色抽出と表示
  - 色温度の計算と表示
  - 空の種類の自動判定と表示
  - 投稿データへの自動反映
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7_

- [ ] 8. フィード表示機能の実装
- [ ] 8.1 HomeViewModelの実装
  - 公開投稿の取得と管理
  - ページネーション処理
  - ローディング状態の管理
  - エラーハンドリング
  - _Requirements: 10.1, 10.5, 10.6_

- [ ] 8.2 ホーム画面UIの実装
  - フィード表示（時系列順）
  - サムネイル画像の表示（Kingfisher統合）
  - 画像の遅延読み込み（LazyLoad）
  - ページネーション（スクロール検知）
  - ローディングインジケーター
  - 投稿タップ時の詳細画面遷移
  - _Requirements: 10.1, 10.2, 10.3, 10.5, 10.6, 10.7, 14.5, 14.6_

- [ ] 8.3 投稿詳細画面UIの実装
  - フルサイズ画像の表示
  - キャプション、ハッシュタグの表示
  - 位置情報の表示
  - 投稿者情報の表示
  - _Requirements: 10.4_

- [ ] 9. 検索機能の実装
- [ ] 9.1 SearchViewModelの実装
  - 検索クエリの管理
  - 検索結果の取得と表示
  - 複数条件の組み合わせ検索
  - エラーハンドリング
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6_

- [ ] 9.2 検索画面UIの実装
  - 検索画面の表示
  - ハッシュタグ入力フィールド
  - 色選択UI
  - 時間帯選択UI
  - 空の種類選択UI
  - 検索結果一覧表示
  - 検索結果の投稿タップ時の詳細画面遷移
  - _Requirements: 11.1, 11.2, 11.3, 11.4, 11.5, 11.6, 11.7_

- [ ] 10. プロフィール機能の実装
- [ ] 10.1 ProfileViewModelの実装
  - プロフィール情報の表示・編集
  - 編集装備システムの管理（5-8個の制約）
  - 自分の投稿一覧の表示
  - 他ユーザーのプロフィール表示
  - エラーハンドリング
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 12.1, 12.2, 12.3, 12.4, 12.5, 12.6, 12.7, 12.8_

- [ ] 10.2 プロフィール画面UIの実装
  - プロフィール画像、表示名、自己紹介の表示
  - 投稿数、フォロワー数、フォロー数の表示
  - 自分の投稿一覧表示（グリッド/リスト）
  - プロフィール編集ボタン
  - _Requirements: 12.1, 12.2, 12.3_

- [ ] 10.3 プロフィール編集画面UIの実装
  - 表示名・自己紹介の編集
  - プロフィール画像の変更（画像選択、アップロード）
  - 保存ボタン
  - _Requirements: 12.4, 12.5, 12.6_

- [ ] 10.4 編集装備設定画面UIの実装
  - 27種類の編集ツール一覧表示
  - ツールの選択・解除（5-8個の制約）
  - ドラッグ&ドロップによる順序変更
  - 設定の保存
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6_

- [ ] 10.5 他ユーザーのプロフィール画面UIの実装
  - 他ユーザーのプロフィール情報表示
  - 公開設定がpublicの投稿のみ表示
  - _Requirements: 12.7, 12.8_

- [ ] 11. 下書き機能の実装
- [ ] 11.1 下書き一覧画面UIの実装
  - 下書き一覧の表示
  - 下書きの選択（編集画面または投稿情報入力画面へ遷移）
  - 下書きの削除
  - _Requirements: 9.3, 9.4, 9.5_

- [ ] 12. AdMob広告統合
- [ ] 12.1 AdServiceの実装
  - Google Mobile Ads SDKの統合
  - バナー広告の読み込み
  - 広告読み込み状態の監視
  - エラーハンドリング（アプリ動作に影響なし）
  - _Requirements: 13.1, 13.2, 13.3, 13.4_

- [ ] 12.2 広告表示UIの実装
  - 画面下部に固定表示されるバナー広告コンポーネント
  - 全画面への統合
  - _Requirements: 13.1, 13.2_

- [ ] 13. ナビゲーションとアプリ構造
- [ ] 13.1 タブバーナビゲーションの実装
  - ホーム、投稿、検索、プロフィールタブ
  - タブ間の遷移
  - _Requirements: 2.1, 10.1, 11.1, 12.1_

- [ ] 13.2 アプリ全体のナビゲーション統合
  - 認証状態に基づく画面遷移（ウェルカム → ホーム）
  - 投稿フローの画面遷移（選択 → 編集 → 情報入力 → 完了）
  - エラーハンドリングとフォールバック
  - _Requirements: 1.7, 2.7, 8.5, 8.8_

- [ ] 14. セキュリティルールの実装
- [ ] 14.1 Firestore Security Rulesの実装
  - usersコレクション: 認証済みユーザーのみ読み書き、自分のデータのみ更新
  - postsコレクション: 公開投稿は全員読み取り可能、自分の投稿のみ作成・更新・削除可能
  - draftsコレクション: 自分の下書きのみ読み書き可能
  - 公開設定（public/followers/private）に基づくアクセス制御
  - _Requirements: 15.1, 15.2, 15.3_

- [ ] 14.2 Firebase Storage Security Rulesの実装
  - 画像ファイルは認証済みユーザーのみアップロード可能
  - 公開画像は全員読み取り可能、プライベート画像は所有者のみ読み取り可能
  - _Requirements: 15.4_

- [ ] 15. エラーハンドリングとロギング
- [ ] 15.1 エラーハンドリングの統合
  - ユーザーエラー（4xx）の処理と表示
  - システムエラー（5xx）の処理とリトライ
  - ビジネスロジックエラー（422）の処理
  - エラーメッセージのユーザーフレンドリーな表示
  - _Requirements: 1.6, 2.6, 8.6, 8.7_

- [ ] 15.2 ロギングとモニタリングの実装
  - Firebase Crashlyticsの統合
  - エラーログの記録（Firebase Analytics）
  - ネットワークエラーのリトライ回数と成功率の記録
  - 機密情報の除外
  - _Requirements: 13.3_

- [ ] 16. テスト実装
- [ ] 16.1 ユニットテストの実装
  - AuthServiceのテスト（成功/失敗ケース）
  - ImageServiceのテスト（フィルター、編集ツール、圧縮）
  - FirestoreServiceのテスト（CRUD操作）
  - StorageServiceのテスト（アップロード成功/失敗）
  - ViewModelのテスト（状態管理、ビジネスロジック）
  - _Requirements: 1.3, 1.5, 3.2, 4.3, 8.2, 8.4_

- [ ] 16.2 統合テストの実装
  - 認証フローのテスト（ログイン/新規登録からホーム画面遷移）
  - 投稿フローのテスト（写真選択から投稿保存）
  - 検索フローのテスト（検索条件から結果表示）
  - Firebase統合テスト（Firestore、Storage、Authentication）
  - _Requirements: 1.7, 8.8, 11.6_

- [ ] 16.3 E2E/UIテストの実装
  - 認証のUI操作テスト
  - 投稿のUI操作テスト（写真選択、編集、投稿情報入力、投稿保存）
  - フィード表示のUI操作テスト
  - 検索のUI操作テスト
  - プロフィールのUI操作テスト
  - _Requirements: 1.1, 1.2, 2.1, 6.1, 10.1, 11.1, 12.1_

