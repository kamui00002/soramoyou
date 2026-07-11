# App Store 審査提出の自動化（fastlane deliver）☀️

TestFlight アップロード**より先**の工程（App Store 版作成・新機能欄記入・審査提出）を自動化する仕組みのリファレンス。
`fastlane/Fastfile` と、その薄いラッパー `scripts/appstore-release.sh` の2点構成。

> 使い方: リリース作業（build番号を上げて審査提出するまで）の際に、該当セクションを上から順に確認する。
> 関連: `docs/pre-release-checklist.md`「4. 提出メカニクス」/ `~/.claude/scripts/xcode-testflight-upload.sh`（TestFlight アップロード担当・本ドキュメントの対象外）

---

## 1. 概要

**何が自動化されるか:**
- App Store Connect 上の新しい版（version）の作成、または編集中の版へのビルド選択
- 新機能欄（release notes）の記入
- 審査提出（submit for review）

**既存 TestFlight スクリプトとの役割分担:**

| 工程 | 担当 | 実行場所 |
|---|---|---|
| build番号の自動bump・archive・IPA書き出し・TestFlightアップロード | `~/.claude/scripts/xcode-testflight-upload.sh --auto-bump` | リポジトリ外（`~/.claude/scripts/`） |
| App Store版の作成・新機能欄記入・ビルド選択・審査提出 | `scripts/appstore-release.sh`（本ドキュメントの対象） | リポジトリ内（`fastlane/`） |

TestFlight アップロードが完了し、Apple 側のビルド処理（processing）が終わった**あと**に本自動化を使う。

---

## 2. 前提条件

- **secret CLI に ASC 認証情報を登録済みであること**
  - `secret get ASC_KEY_ID` / `secret get ASC_ISSUER_ID` が値を返すこと
- **App Store Connect API キーの p8 ファイルを配置済みであること**
  - `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`（`<KEY_ID>` は `ASC_KEY_ID` の値）
- **fastlane がインストール済みであること**
  - `fastlane --version` が通ること（未導入なら `bundle install` または `brew install fastlane`）
- `scripts/appstore-release.sh` は上記2つの secret を読み取り、`ASC_KEY_ID` / `ASC_ISSUER_ID` を環境変数にセットしてから `fastlane` を呼び出す。**手動 export は不要**（むしろ引数直書きは `secrets.md` 違反になるため行わないこと）。

---

## 3. リリース時の全体フロー

1. リリースブランチで TestFlight アップロード（既存スクリプト）
   ```bash
   ~/.claude/scripts/xcode-testflight-upload.sh Soramoyou/Soramoyou.xcodeproj Soramoyou --auto-bump
   ```
2. Apple 側のビルド processing 完了を待つ（目安 5〜30分。App Store Connect の TestFlight タブで確認）
3. リリースノート草案をユーザーに提示して承認を取り、`fastlane/metadata/ja/release_notes.txt` へ保存する
   - このファイルに `PLACEHOLDER` の文言が残っていると、次の `prepare` / `submit` は実行前に止まる（§6 参照）
4. 版作成・新機能欄記入・ビルド選択を行う（**この時点では審査提出しない**）
   ```bash
   scripts/appstore-release.sh prepare --version 1.9.3 --build 73
   ```
5. **GO確認（人間の判断・自動化しない）**
   - App Store Connect 上で `prepare` 後の内容（版番号・新機能欄・選択されたビルド）を目視確認する
   - 「審査提出GOの最終判断は自動化しない」方針のため、この確認は必ず人間（ユーザー）が行う
6. 審査提出（不可逆操作）
   ```bash
   # 手動実行時: SUBMIT と入力するプロンプトが出る
   scripts/appstore-release.sh submit --version 1.9.3 --build 73

   # AI（Claude）経由で実行する場合: 事前にユーザーへGO確認を取った上でのみ --yes を付ける
   scripts/appstore-release.sh submit --version 1.9.3 --build 73 --yes
   ```

---

## 4. コマンドリファレンス

`scripts/appstore-release.sh <サブコマンド> [オプション]`

| サブコマンド | 対応 Fastlane レーン | 説明 |
|---|---|---|
| `status` | `asc_status` | App Store Connect API 認証の疎通確認（読み取り専用・最新TestFlightビルド番号を取得） |
| `prepare` | `release_prepare` | 版作成／ビルド選択＋新機能欄記入のみ行う。`submit_for_review: false` のため審査提出はしない |
| `submit` | `release_submit` | `prepare` と同一内容で審査提出まで行う。**不可逆** |

**オプション:**

| オプション | 対象サブコマンド | 説明 |
|---|---|---|
| `--version` | prepare / submit | App Store 版番号（例 `1.9.3`）。省略時は pbxproj の `MARKETING_VERSION` を既定値として使用 |
| `--build` | prepare / submit | 選択するビルド番号（例 `73`）。省略時は pbxproj の `CURRENT_PROJECT_VERSION` を既定値として使用 |
| `--yes` | submit のみ | 対話プロンプト（`SUBMIT` 入力）をスキップして提出を実行する。**AIがユーザーからGO確認を取った後にのみ使用すること** |

`prepare` / `submit` はどちらも、実行前に `fastlane/metadata/ja/release_notes.txt` の内容をチェックする（シェル側・Fastfile側の二重ガード。§6参照）。

---

## 5. 版番号方針

これまで App Store 上の版番号（1.4.x 系）と、バイナリの `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION`（1.9.x 系）が**別々に運用**されており、これが過去の版番号照会時の混乱の原因になっていた。

**2026-07-11 決定: 次の提出からは App Store 版番号をバイナリの版番号に揃える。**
- 例: 次のリリースは App Store 版番号も `1.9.3` とする（1.4.x からのジャンプになるが、増加方向のジャンプのため Apple 側の制約には抵触しない）
- 以後は `scripts/appstore-release.sh` の `--version` 既定値（pbxproj 由来）をそのまま使えば、両者が自然に一致する運用にする

---

## 6. トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| `prepare` / `submit` が版作成前に失敗する | **in-reviewロック**: 審査中（WAITING_FOR_REVIEW等）の版が存在する間は新しい版を作成できない | 現在審査中の版の結果（承認 or リジェクト）が出るまで待ってから再実行する |
| 版作成・提出が **403** で失敗する | App Store Connect API キーの role が `Developer` になっている | App Store Connect の「ユーザとアクセス > 統合（Integrations）」で該当キーを **App Manager** 権限に変更する |
| `build_number` 指定でビルドが見つからない／選択に失敗する | Apple 側でビルドが **processing 中**（目安5〜30分） | 少し待って再実行する |
| 初回 `submit` 実行時に `submission_information`（IDFA等）の入力を要求してエラーになる | deliver が輸出コンプライアンス等の申告情報を要求している | `fastlane/Fastfile` の `release_submit` レーンに `submission_information` オプションを追加する |
| `prepare` / `submit` が「リリースノートが PLACEHOLDER のまま」で止まる | `fastlane/metadata/ja/release_notes.txt` が未編集（`PLACEHOLDER` 文字列が残ったまま） | ユーザー承認済みのリリースノート草案でファイルを置き換えてから再実行する（§3 手順3） |

---

## 7. 初回運用メモ

- 本自動化（`scripts/appstore-release.sh` の `prepare` / `submit`）は、**2026-07-11時点で実弾での End-to-End 検証を行っていない**。
- 理由: この時点で 1.4.2 / build72 が審査中（in-reviewロック中）のため、新しい版を作成できる状態になかった。
- **初回の実弾実行は次リリース（build 73 以降）で行う予定。** 実行時は §6 の既知制約（特に in-reviewロックと403権限エラー）に注意しながら進めること。
