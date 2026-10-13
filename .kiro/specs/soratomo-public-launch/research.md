# Research & Design Decisions — soratomo-public-launch ⭐️

## Summary
- **Feature**: `soratomo-public-launch`（そらとも：一般公開の切り替え）
- **Discovery Scope**: Extension（既存の3か所の関門の条件を差し替える。light discovery）
- **Key Findings**:
  - IDトークンの予約済みの項目`firebase.sign_in_provider`で、匿名（`anonymous`）とメールとパスワード（`password`）を見分けられる。ルールとCallableの両方で同じ項目を読める。
  - 関門の名前と呼ぶ側を残し、条件だけを替えれば、差分と変異テストの置き換え元を最小にできる（Firestore 6か所・Storage 3か所・Callable 7本＋抜ける1本）。
  - 提出の道具は「承認されたら自動で公開」で、App Store Connectの画面で手動に変えても、提出のときに上書きされる（`fastlane/Fastfile:70`）。12.6には道具の変更が要る。→ 2026-10-11 利用者が自動のままを選んだ。道具は変えず、12.6を言い直した。
  - プライバシーポリシーの原本はアプリの中（`SettingsView.privacyPolicyText`）なので、G5のポリシーの更新は1.15.0のアプリの変更に含まれる。
  - 公開前の基準値・予測・クエリは、gitの管理外の`.claude/handoffs/`にしか無い。本書の下へ写した。

## Research Log

### 匿名の判定（ルール）
- **Context**: クレームの確認を外すと、匿名アカウントを止めるものが無くなる（要件1.7）。
- **Sources Consulted**: Firebase公式の[Rules and Auth](https://firebase.google.com/docs/rules/rules-and-auth)。2026-10-11に読んだ。
- **Findings**:
  - `auth.token`の項目に`firebase.sign_in_provider`があり、「このトークンを得たサインイン方式」。値は`custom`・`password`・`phone`・`anonymous`ほか。
  - `email`は「あれば」のアカウントのメールアドレス。
  - 未ログインでは`auth`が`null`。
  - 公式のページに、`sign_in_provider`を使ったルールの例は無い。
- **Implications**: `request.auth.token.firebase.sign_in_provider != 'anonymous'`で判定する。`get`の既定値つきで読まず、項目が無いときはエラーで拒否される形にする（閉じる側に倒れ、テストでトークンの書き忘れが見つかる）。

### 匿名の判定（Callable）
- **Context**: Functionsでも同じ規則にする（要件1.7・4.1）。
- **Sources Consulted**: `functions/node_modules/firebase-admin/lib/auth/token-verifier.d.ts:62-88`（firebase-admin 14.5.0）・`functions/node_modules/firebase-functions/lib/common/providers/https.d.ts:39-46`（firebase-functions 7.4.0）・Firebase公式の[Protocol specification for https.onCall](https://firebase.google.com/docs/functions/callable-reference)。
- **Findings**:
  - `DecodedIdToken.firebase`は「Firebase Authenticationが入れる予約済みの項目」で、型は省略できない。`sign_in_provider: string`は`"anonymous"`・`"password"`・`"apple.com"`・`"phone"`・`"custom"`ほか。
  - Callableの`request.auth.token`は、検証済みの`DecodedIdToken`。トークンが正しくなければ、ハンドラーの前で`UNAUTHENTICATED`で拒否される。
  - 既存のテストは、匿名を`{ firebase: { sign_in_provider: "anonymous" } }`で表している（`functions/soratomo.test.js:504`）。
- **Implications**: 純粋関数`isRegisteredToken(token)`を`soratomoCore.js`に置き、Callableの関門から使う。方式が文字列でなければ偽（閉じる側）。

### いまのログイン方式（iOS・Android）
- **Sources Consulted**: `Soramoyou/Soramoyou`のgrep（`signInAnonymously`・`ASAuthorizationAppleID`・`OAuthProvider`・`PhoneAuthProvider`・`GoogleSignIn`）・`AuthViewModel.swift:121-150`・`~/dev/soramoyou-android/android/app/src/main/kotlin/com/yoshidometoru/soramoyou/data/repository/AuthRepository.kt:17-51`（読むだけ）。
- **Findings**: iOSはメールとパスワードと匿名だけ。匿名ログインを呼ぶ画面は無い（定義だけ）。匿名でログインすると`isAuthenticated = true`で`MainTabView`が出る（`AuthViewModel.swift:135`）。Android版は匿名を作らない。
- **Implications**: 匿名の拒否は、画面から見える変化を生まない。匿名に全員向けのWhat's New（そらとも）が出るのは、到達しないので受け入れる（design.mdの差し戻し5）。

### ルールのテストの作り
- **Sources Consulted**: `scripts/rules_test_soratomo.py`・`scripts/rules_test_storage_soratomo.py`の全体。
- **Findings**:
  - `is_ok`（`:306-313`）は、拒否を期待するケースが「エラーで拒否」されたら期待外れにする。許可を期待するケースは、エラーなら拒否なので期待外れ。
  - 変異テストは置き換え元が1回だけ現れることを確かめ、そうでなければ失敗にする（`:335-339`）。
  - ルールのパスは引数で受け取れる（`:365`）。本番から読み返した本文や、変える前のルールの写しに、同じテストを流せる。
  - クレームの無い人には別のクレーム（`skyMotionBeta`）を持たせている（`:259`）。
- **Implications**: トークンに`firebase.sign_in_provider`を必ず入れる。変異テストの置き換え元を`isSoratomoUser()`の本文の式（1回だけ現れる）にする。陽性対照は、テストを先に直して、変える前のルールに流す。

### 本番のルールの読み返しの前例
- **Sources Consulted**: `.kiro/specs/soratomo-release-gate/tasks.md:633-649`（17の結果）・`.claude/handoffs/2026-10-10-そらとも公開前ゲート-16.4.md:33・56`。
- **Findings**: 出す前と後に、本番のrulesetの識別子・ハッシュの頭が手元のファイルと一致することを確かめ、読み返した本番の本文に`rules_test_soratomo.py`を流した（96/96）。道具はリポジトリに無く、手元の一時的なもので行った。Functionsは`functions:list`の名前の一致で「mainと同じ」を確かめた。
- **Implications**: 読み返しの道具を`scripts/`に小さく足し、同じ手順をくり返せるようにする。Functionsはコードを読み返さず、出し元のコミット・一覧・挙動のログで確かめる（design.mdの差し戻し1）。

### 提出の道具と公開の方法
- **Sources Consulted**: `fastlane/Fastfile:57-124`・`scripts/appstore-release.sh`・`docs/appstore-release-automation.md`。
- **Findings**: `deliver_release`は`automatic_release: true`・`skip_screenshots: true`・メタデータはリリースノートだけ。`release_prepare`と`release_submit`は同じ引数で`deliver`を呼ぶ。`submit`は`prepare`のマニフェスト（version・build・リリースノートのハッシュ）と照合する。
- **Implications**: 手動で公開するには、レーンに選択肢を足し、マニフェストにも記録して照合する。スクリーンショット・審査メモ・ラベルは開発者がASCで入れる。

### App Storeの審査の基準
- **Sources Consulted**: [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。2026-10-11に読んだ。
- **Findings**:
  - 2.1(a): ログインがあるアプリは、デモのアカウントの情報を含め、バックエンドを動かしておく。
  - 2.3.1(a): 隠れた・眠った・説明の無い機能を入れない。新機能は審査メモ（Notes for Review）に具体的に書き、審査で触れられるようにする（一般的な説明は却下）。
  - 1.2: ユーザー生成コンテンツには、不快な投稿の絞り込み・通報と速やかな対応・ブロック・連絡先の公開が要る。
- **Implications**: 1.15.0の提出の前にサーバーを開ける（3.1）。審査メモに、そらともの具体的な説明と、審査用のグループの招待コードでの確かめ方を書く。退会の削除は、デモのアカウントを消さないよう、新しく登録したアカウントで試してもらう。

### PR #163
- **Sources Consulted**: `gh pr view 163`・`gh pr diff 163`（2026-10-11）。
- **Findings**: OPEN・draft・MERGEABLE。オンボのページ（`47e5fcc`。「みんなと共有」の直後・アイコン`person.2.circle`・説明「ホーム右上のボタンから始めよう」・コメントに「1.14」）と、スクリーンショットの素材と作り方（6.5インチ`02-soratomo-1284x2778.png`・iPad`02-soratomo-2048x2732.png`を既存の8枚の2枚目に）。本文に「ゲートを外すPRと同時か、その後にマージ」。
- **Implications**: PR-B（アプリ）に取り込み、#163はリンクを書いて閉じる（このリポジトリはsquashでマージするので、自動では閉じない）。

### G5の現状
- **Sources Consulted**: `SettingsView.swift:736-`（ポリシーの本文。最終更新日 2026年8月3日・そらともの記述なし）・`docs/app-privacy-label.md`（ASCの入力表・最終確認 2026-08-03）・`docs/firestore-schema.md:339`（G5への引き継ぎ）。
- **Findings**: ポリシーの原本はアプリの中で、ホストのHTMLは生成スクリプトで作る。ラベルの表はマニフェスト（`PrivacyInfo.xcprivacy`）と一致させる約束。写真・その他のユーザーコンテンツ・ユーザーID・名前はすでに申告済み。
- **Implications**: ポリシーの更新はPR-Bに入れ、提出の前にhostingを出す。ラベルは増える項目の有無を確かめ、変えるならマニフェストと表を同時に直す。

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|---|---|---|---|---|
| 関門の条件の置き換え（採用） | `isSoratomoUser()`・`requireSoratomoUser`・`SoratomoFeatureGate`の名前と呼ぶ側を残し、条件だけを「登録済みでログイン」にする | 差分が小さい。変異テストの置き換え元が1か所。3か所の同じ形を保てる | 名前の「Soratomo User」の意味が「クレームのある人」から「登録済みの人」に変わる（コメントで書く） | soratomo design.md:1135の「3か所を同時に」をそのまま守れる |
| 全員にクレームを配る | 既存の仕組みのまま、全員に`soratomoBeta`を付ける | コードの変更が無い | 新規の利用者に付け続ける仕組みが要る。審査の人が見えない（2.3.1） | 要件で不採用 |
| 関門を新しい名前に替える | `isRegisteredUser()`などを新しく作り、呼ぶ側を全部直す | 名前と意味が一致する | 呼ぶ側の9か所とアプリの5画面の差分が増える | 名前の違和感はコメントで足りるので採らない |

## Design Decisions

### Decision: 匿名の判定は「匿名でない」にする
- **Context**: 要件1.7（匿名は拒否）。用語の「登録済み」はメールとパスワード。
- **Alternatives Considered**:
  1. `sign_in_provider != 'anonymous'`（匿名だけを拒否）
  2. `sign_in_provider == 'password'`（メールとパスワードだけを許す）
  3. `token.email`があるか（iOSの`email == nil`の判定と同じ）
- **Selected Approach**: 1。
- **Rationale**: いまのログイン方式はメールとパスワードと匿名だけで、1と2の結果は同じ。将来ほかの方式（Appleでサインインなど）を足したとき、1ならルールとFunctionsを開け直さずに済む。3は方式に依らない代わりに、メールの無い正当な方式（電話）を拒否し、メールを返さない方式の挙動にも左右される。要件1.7の文言（匿名を拒否）にも1がそのまま合う。
- **Trade-offs**: 電話など、意図していない方式が本番で有効になっていれば通る（要確認3で、本番の設定を読む）。
- **Follow-up**: 新しいログイン方式を足すときは、そらともに入れてよいかをその時に決める。

### Decision: 匿名の拒否の理由は新しい`registration_required`
- **Context**: Callableが匿名を拒否するときの`details.reason`。
- **Alternatives Considered**:
  1. 既存の`flag_off`を使い回す（アプリの写しを変えずに済む）
  2. 新しい`registration_required`（`permission-denied`）
- **Selected Approach**: 2。
- **Rationale**: 公開の後のログで`flag_off`が出ると「機能フラグ」の意味と混ざる。新しい理由なら、見回りで「アプリ以外からの要求」として数えられる。1.15.0のアプリは知らない理由を`.permissionDenied`に写す（`SoratomoGroupService.swift:352-379`の`:374`）ので、アプリの変更は要らない。
- **Trade-offs**: `flag_off`の写しはアプリに残る（計測の値を変えない・9.4）。サーバーからは返らなくなる。

### Decision: 通知の集計の`flagOff`の項目は残す
- **Context**: `classifyRecipient`から`flag_off`の分岐を消すと、集計の`flagOff`はいつも0になる。
- **Alternatives Considered**:
  1. 項目ごと消す（ログに意味の無い0が出ない）
  2. 項目を残し、0のまま出す（ログの形が変わらない）
- **Selected Approach**: 2。
- **Rationale**: `soratomoCore.js`の集計の関数を変えずに済み、14日の見回りと1.14期のログを同じ形で読める。0であることは「クレームの無い宛先へ送るようになった」ことの確かめにも使える（本番の通しの4）。

### Decision: アプリの判定は型を残し、トークンを読まない
- **Context**: 要件2（登録済みなら出す・通信で消えない）。
- **Alternatives Considered**:
  1. `SoratomoFeatureGate`を残し、`currentAccountKind()`だけで決める
  2. 判定の型を消し、各画面が`AuthViewModel`を直接読む
- **Selected Approach**: 1。窓口のプロトコルは`SoratomoAccountProviding`に名前を変え、`evaluate()`を同期にする。トークンの強制更新・世代・再評価を消す。
- **Rationale**: 5つの画面と通知のルーターの差分が最小で、判定の単体テストが1か所に集まる。2は呼ぶ側とプレビューの差分が広がる。
- **Trade-offs**: 名前の「FeatureGate」は「登録済みかの判定」になる（コメントで書く）。

### Decision: 先行公開の紹介の経路は消す
- **Context**: 6.1（誰にも出さない）・7.5（1人1回）。
- **Alternatives Considered**:
  1. 経路（識別子・ページ・判定・`MainTabView`の種類）を消す
  2. 経路を残し、判定に常に偽を渡す
- **Selected Approach**: 1。
- **Rationale**: 2は使われない分岐を残し、後で誤って有効にすると二重の表示になる。全画面のカバーの`item:`の仕組みは実機で直した経緯があるので、種類が1つになっても形は変えない。

### Decision: 切り替えの順序
- **Context**: 要件3。
- **Alternatives Considered**:
  1. サーバー（Firestore→Storage→Functions）を開けて読み返してから、1.15.0をTestFlightへ出す（採用）
  2. 1.15.0のTestFlightを先に出し、クレームのある人だけで試してから開ける
  3. 3か所を別の日に出す
- **Selected Approach**: 1。PR-Aは切り替えの当日にマージする。Functionsはそらともの関数だけを名前で指定して出す。
- **Rationale**: 守る条件は「クレームの無い人が1.15.0を手にする前に開け終える」だけ。2は、開発者の端末のログイン中のアカウントがクレームを持たないと、開ける前に壊れた画面を見る。3は、画面を通さない直接の要求を受ける期間が延びる。ルールは読み返しが速く確実なので先に出し、挙動の確かめに時間のかかるFunctionsを最後にする。
- **Trade-offs**: 開けてから公開まで（審査の1〜3日＋公開を押すまで）は、画面を通さない直接の要求を受ける。決定事項1で受け入れ、開けた日から見回る。

### Decision: 変異テストの作り直し
- **Context**: 10.2・10.3。置き換え元`CLAIM`がルールから消える。
- **Selected Approach**: 置き換え元を`isSoratomoUser()`の本文の式（`REGISTERED`）にし、「匿名の判定を外す」「逆にする」「常に偽」「ログインの判定を外す」「ログイン・匿名・メンバーをすべて外す」を入れる。メンバーと投稿者本人の壊し方は既存のまま。登場人物に匿名のメンバーを足し、クレームの無いメンバーを許可の期待に変える。
- **Rationale**: 本文の式はルールに1回だけ現れるので、置き換えが空振りしない。匿名のメンバーのケースが「匿名の判定」の壊し方を、未ログインのケースが「ログインの判定」の壊し方を見分ける。
- **Trade-offs**: 「ログインの判定を外す」は、未ログインのトークンの読み取りがエラーになることで見つかる（テストの道具がエラーでの拒否を期待外れに数えるため）。本番の挙動ではエラーでも拒否なので、安全の差はこの壊し方では生まれない。安全の差が出る壊し方は「すべて外す」が受け持つ。

### Decision: 陽性対照は同じブランチで「テストを先に」
- **Context**: 10.4。共有のstashは使えない（ほかのセッションと共有）。
- **Selected Approach**: テストの変更を先にコミットし、コードを変える前に流して赤を記録する。ルールは引数で変える前の写しにも流せる。コードを変えた後の「わざと壊す」確認は、スクラッチパッドの一時的なworktreeで行う。
- **Rationale**: 作業ツリーのコードを壊して戻す手順を避けられる。

### Decision: リリース手順書の置き場
- **Selected Approach**: design.mdのMigration Strategyを手順書とし、結果は`tasks.md`の各タスクに書く。審査メモの文案は`tasks.md`のG5のタスクに置く（招待コードは書かない）。ラベルの変更は`docs/app-privacy-label.md`、ポリシーの本文はアプリの原本。
- **Rationale**: 手順・目安・比べ方を1か所に置け、承認の対象にもなる。新しい文書のファイルを増やさない。release-gate specの16〜18と同じ型。

## Risks & Mitigations
- PR-Aを早くマージすると、別の理由でルールやFunctionsを出したときに予定より早く開く — 当日にマージする。
- leave-groupの`soratomoLeaveGroup`の`requireFlag: false`が残る — `soratomoCallable`が知らない選択肢で読み込みを止める。grepでも0件を確かめる。
- 使い捨ての登録済みアカウントによる乱用 — 既存の上限・見回りの目安・利用停止（決定事項1）。
- 審査メモの招待コードが外に残る — 承認の後に再発行する。
- 承認が夜中に通り、見回れない時刻に公開される — 利用者の判断1で自動のまま（2026-10-11）。公開を知った日のうちに見回りを始める（12.6を言い直し）。
- 基準値の出どころが消える — 本書の下に写した。

## 公開前の基準値と、比べるためのクエリ（`.claude/handoffs/2026-10-11-材料/`からの写し）

出どころ: `posthog_results.md`（2026-10-11 06:00〜06:30 JSTに実行・PostHogのプロジェクト Soramoyou id 430627）と`forecast.json`。uidは先頭6文字か置き場所の名前だけを書く。

### 定義
- 利用者: `Application Opened`が1回以上あるperson。アプリは`properties.$app_namespace = 'com.yoshidometoru.Soramoyou'`。
- 区切り: 日本時間（`toTimeZone(timestamp,'Asia/Tokyo')`）・週は月曜始まり（`toStartOfWeek(...,1)`）。
- 締め日: 2026-10-10（10/5の週は6日分）。
- PostHogは1.9.6（2026-08-16公開）以降の版だけを写す。

### 除外の条件（person単位・2026-06-01以降に1回でも当たったpersonを丸ごと除く）
```sql
person_id NOT IN (
  SELECT person_id FROM events
  WHERE timestamp >= toDateTime('2026-06-01 00:00:00')
    AND (properties.$is_emulator = true
      OR properties.$is_testflight = true
      OR properties.$geoip_country_code = 'US'
      OR distinct_id IN ('<開発者yahooのuid>', '<開発者gmailのuid>', '<S5のuid>')
      OR distinct_id LIKE '8Ar2DV%'   -- S3
      OR distinct_id LIKE 'Qk9lcs%'   -- S5（public-launch 10.1・クレーム無し・2026-10-13 作成）
      OR distinct_id LIKE 'nhYcDQ%'   -- B（soratomo5・leave-group の相手役・クレームあり）
      OR distinct_id LIKE '1xPRKe%'   -- S4
      OR distinct_id LIKE 'FvPXCf%')) -- 審査用のデモ
```
- `<S5のuid>`は段0-2で足す（11.6: 足したら基準値を出し直す）。

### クエリの型
- 週ごとの利用者:
```sql
SELECT toStartOfWeek(toTimeZone(timestamp,'Asia/Tokyo'),1) AS week_jst,
       uniq(person_id) AS wau_all, uniqIf(person_id, <除外>) AS wau_clean
FROM events
WHERE event = 'Application Opened' AND timestamp >= toDateTime('2026-06-01 00:00:00')
  AND properties.$app_namespace = 'com.yoshidometoru.Soramoyou'
GROUP BY week_jst ORDER BY week_jst
```
- 直近7日の利用者（その日で終わる7日）:
```sql
SELECT day, uniq(person_id) FROM (
  SELECT person_id, toDate(toTimeZone(timestamp,'Asia/Tokyo')) + arrayJoin(range(7)) AS day
  FROM events
  WHERE event = 'Application Opened' AND timestamp >= toDateTime('<開始の8日前>')
    AND properties.$app_namespace = 'com.yoshidometoru.Soramoyou' AND <除外>)
WHERE day BETWEEN toDate('<開始>') AND toDate('<締め>') GROUP BY day ORDER BY day
```
- 週次コホートの継続率:
```sql
WITH clean AS (
  SELECT person_id, toStartOfWeek(toTimeZone(timestamp,'Asia/Tokyo'),1) AS wk FROM events
  WHERE event = 'Application Opened' AND timestamp >= toDateTime('2026-08-01 00:00:00')
    AND properties.$app_namespace = 'com.yoshidometoru.Soramoyou' AND <除外>
  GROUP BY person_id, wk),
firsts AS (SELECT person_id, min(wk) AS cohort FROM clean GROUP BY person_id)
SELECT f.cohort, dateDiff('week', f.cohort, c.wk) AS week_n, uniq(c.person_id)
FROM clean c INNER JOIN firsts f ON c.person_id = f.person_id
GROUP BY f.cohort, week_n ORDER BY f.cohort, week_n
```
- G4（そらとものイベントの着弾・除外あり／なし。新しく足す型）:
```sql
SELECT event, count() AS all_events, countIf(<除外>) AS clean_events
FROM events
WHERE event IN ('soratomo_opened','soratomo_group_created','soratomo_group_joined','soratomo_post_created',
                'soratomo_invite_shared','soratomo_report_submitted','soratomo_user_blocked','soratomo_guideline_result')
  AND timestamp BETWEEN toDateTime('<通しの開始>') AND toDateTime('<通しの終わり>')
GROUP BY event ORDER BY event
```
- そらともを開いた人・作成または参加した人（11.3。新しく足す型）:
```sql
SELECT uniqIf(person_id, event = 'soratomo_opened') AS opened,
       uniqIf(person_id, event IN ('soratomo_group_created','soratomo_group_joined')) AS created_or_joined
FROM events
WHERE timestamp BETWEEN toDateTime('<公開の日時>') AND toDateTime('<締め>') AND <除外>
```
- 1.15.0の普及率（11.4。新しく足す型・`$app_version`の値の形は要確認6）:
```sql
SELECT uniqIf(person_id, properties.$app_version = '1.15.0') / uniq(person_id) AS share_115
FROM events
WHERE event = 'Application Opened' AND timestamp >= now() - INTERVAL 7 DAY
  AND properties.$app_namespace = 'com.yoshidometoru.Soramoyou' AND <除外>
```
- 新規登録はFirestoreの`users`の登録日で数える（PostHogに写らない古い版のため。Firestore MCPはTimestampに文字列の範囲条件を付けると黙って0件を返すので、並べ替えと件数で数える）。

### 公開前の基準値（除外後）

| 数字 | 値 | 出どころの行（`posthog_results.md`） |
|---|---|---|
| 直近7日の利用者 | 2026-10-10に360（山は10-04〜10-05の452） | 60〜61 |
| 日ごとの利用者 | 2026-10-10に112（10-05〜10-10は112〜137） | 53 |
| 週ごとの利用者 | 9-28の週に452・10-05の週に334（6日分） | 48〜49 |
| 新規登録（Firestoreの`users`） | 9-28の週に266・10-05の週に87（6日分） | 80 |
| 投稿した人÷週ごとの利用者 | 10-05の週に192÷334≈57% | 82 |
| 1週後の継続率 | 9-14の週41%・9-21の週32%・9-28の週41%（6日分） | 73〜75 |

#### 2026-10-13 除外の条件に S5（`Qk9lcs…`）と B（`nhYcDQ…`）を足して出し直した値（10.1 後半）

2026-10-13 18:30 JST ごろ（PostHog MCP の `execute-sql`・プロジェクト 430627）。定義・期間は上の「定義」「クエリの型」と同じ（`Application Opened`・`$app_namespace`・JST・週は月曜始まり）。上限は基準値を取った時刻（2026-10-11 06:30 JST）で切り、後から着いた分を混ぜない。除外前後は同じクエリで「旧の条件」「S5 と B を足した条件」を並べて出した。開発者2件は`nzvqlZ%`・`bOigAs%`（`posthog_results.md`の先頭6文字）で指定した。

| 数字 | 元の値（10-11 記録） | 旧の条件で出し直し | S5・B を足した条件 | 足したことによる差 |
|---|---|---|---|---|
| 直近7日の利用者（10-10） | 360 | 361 | 361 | 0 |
| 直近7日の利用者（山の10-04／10-05） | 452 | 452／452 | 452／452 | 0 |
| 日ごとの利用者（10-10） | 112 | 118 | 118 | 0 |
| 日ごとの利用者（10-05〜10-09） | 130／133／137／125／131 | 130／133／140／126／132 | 同左 | 0 |
| 週ごとの利用者（9-28の週） | 452 | 452 | 452 | 0 |
| 週ごとの利用者（10-05の週・6日分） | 334 | 335 | 335 | 0 |
| 1週後の継続率（9-14／9-21／9-28の週） | 78／76／135人（41%・32%・41%） | 同じ | 同じ | 0 |

- **差は0**。S5（`Qk9lcs…`）の最初のイベントは 2026-10-13 18:20 JST（3件・`Application Opened`なし）、B（`nhYcDQ…`）は 10-12 02:00〜06:38 JST（34件・`Application Opened`が2件）で、どちらも基準値の締め（10-10）より後。基準値の期間には1件も入っていないので、足しても値は動かない。値が動くのは、公開後に出す指標（11.3・11.4 など）から。
- 「元の値」と「旧の条件で出し直し」のずれ（日ごとの10-10が112→118など、+1〜+6）は、条件の足しとは無関係。旧の条件のまま出し直しても同じずれが出る。10-11 の記録より後に、古い端末の遅れて届いたイベント等が着いたためと見られる（原因は未確認）。公開後の比べ方は、元の値でなくこの「旧の条件で出し直し」の列と比べると同じ条件で比べられる。
- 継続率は9-21の週の2週後だけ 48→49（旧・新とも）。他は一致。

### 予測（`forecast.json`・直近7日の利用者の4週分）

| 場合 | 1週 | 2週 | 3週 | 4週 |
|---|---|---|---|---|
| 低（新規60/週）×継続 横ばい | 254 | 244 | 252 | 262 |
| 低（新規60/週）×継続 毎週1割減 | 249 | 232 | 227 | 224 |
| 中（新規110/週・今の水準）×継続 横ばい | 304 | 313 | 331 | 350 |
| 中（新規110/週・今の水準）×継続 毎週1割減 | 299 | 301 | 306 | 312 |
| 高（新規200/週・また波が来る）×継続 横ばい | 394 | 437 | 473 | 507 |
| 高（新規200/週・また波が来る）×継続 毎週1割減 | 389 | 425 | 449 | 469 |

- 「横ばい×新規一定」で増え続けるのはモデルの作り（残った人が減らずに積み上がる）で、上限の線。4週より先は出さない。継続率 r1=0.38・r2=0.20・r3=0.17（実測）。10/5の週を同じ式で再現すると321（実測334・ずれ4%）。

## References
- [Firebase: Rules and Auth](https://firebase.google.com/docs/rules/rules-and-auth) — `auth.token.firebase.sign_in_provider`・`email`・未ログインの`auth == null`
- [Firebase: Protocol specification for https.onCall](https://firebase.google.com/docs/functions/callable-reference) — Callableのトークンの検証
- `functions/node_modules/firebase-admin/lib/auth/token-verifier.d.ts`（firebase-admin 14.5.0）— `DecodedIdToken.firebase.sign_in_provider`
- `functions/node_modules/firebase-functions/lib/common/providers/https.d.ts`（firebase-functions 7.4.0）— `AuthData.token: DecodedIdToken`
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — 1.2・2.1(a)・2.3.1(a)
- `.kiro/specs/soratomo/design.md:1135`・`.kiro/specs/soratomo-release-gate/design.md:1028-1047`・`.kiro/specs/soratomo-release-gate/tasks.md:633-674`
