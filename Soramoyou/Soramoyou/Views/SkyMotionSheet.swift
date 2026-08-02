// ⭐️ SkyMotionSheet.swift
// 「空を動かす」（Kling版）フェーズ2: DEBUG限定E2E検証用のUI導線
//
//  SkyMotionSheet.swift
//  Soramoyou
//
// 設計書: docs/sky-motion-design.md（唯一のデータ契約の土台）
//   §0 アーキテクチャ概要: 画像3枚アップロード → livingSkyJobs 作成 → snapshot listener で
//      status 変化を待つ（pending → submitting → submitted → completed/failed）
//   §5 回数・コスト方針: 3回/日/ユーザー。quota_exceeded 時は fal.ai を一切呼び出さない
//
// ⚠️ 命名・見た目が近い既存の Metal ローカル版 Living Sky（`LivingSkySheet`・`LivingSkyPreviewView.swift`）
//    とは別機能。UI クロームの作りだけ参考にしたが、型は一切再利用しない（新規実装）。
//    既存 LivingSky* 系ファイルには一切手を入れない（温存）。
//
// スコープ: DEBUG限定のE2E検証（フェーズ2 UI導線）。本番導線化はしない
//   （呼び出し元 `EditView` 側で `#if DEBUG` ゲート必須。設計書§7）。
//   フェーズB第一歩として「初回の写真送信同意ゲート」を実装済み（下記 Consent 節）。
//   allowlist ゲート（DEBUG or skyMotionBeta claim）自体は変更なし・公開ゲート解除はフェーズC。
//   スライダー等のパラメータUIも持たない（PoC固定レシピ。マスク・軌跡・aspect比は
//   `SkyMotionAssetPreparer` が自動算出する）。

import AVFoundation
import AVKit
import FirebaseAuth
import SwiftUI

/// `SkyMotionSheet` の処理中に発生しうるエラー（クライアント側のみ）。
enum SkyMotionSheetError: Error, LocalizedError {
    /// `livingSkyJobs.videoURL` が不正な URL 文字列だった
    case invalidVideoURL
    /// 完成した mp4 のダウンロードに失敗した（HTTPステータス異常等）
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidVideoURL:
            "動画のURLが不正です"
        case .downloadFailed:
            "動画のダウンロードに失敗しました"
        }
    }
}

/// 「空を動かす」（Kling版）の状態機械。
/// クライアント側の処理段階（準備/アップロード）と、Cloud Functions 側のジョブ状態
/// （pending/submitting/submitted → completed/failed）を1つの enum にまとめている。
enum SkyMotionSheetState: Equatable {
    /// 初期表示（まだ何もしていない）
    case idle
    /// `SkyMotionAssetPreparer` でマスク・軌跡・aspect比を準備中
    case preparing
    /// Storage への3ファイルアップロード + Firestore ジョブ作成中
    case uploading
    /// ジョブ作成後、Cloud Functions 側の処理（pending → submitting → submitted → completed/failed）を待機中
    case waiting
    /// 完成。ローカルにDL済みの mp4 の URL を保持する
    case completed(localVideoURL: URL)
    /// カメラロールへ保存済み（`completed` の動画はそのまま保持し続ける。プレビューは消さない）
    case saved(localVideoURL: URL)
    /// サーバー側では `completed`（＝回数消費済み）に達したが、端末への動画ダウンロードに
    /// 失敗した状態。`failed` とはあえて区別する（`failed` の既定文言「回数は消費されていない」が
    /// この経路では事実と異なるため）。新規ジョブを作り直させず、同じ `videoURLString` からの
    /// 再ダウンロードのみを許可する（3回/日の枠を再消費させない）。
    case downloadFailed(videoURLString: String)
    /// 失敗。`errorCode` はジョブ側の失敗理由（設計書§1: quota_exceeded 等）。
    /// クライアント側の失敗（準備/アップロード/未ログイン等）では nil になる。
    case failed(errorCode: String?, serverMessage: String?)
}

/// 「空を動かす」（Kling版）β のプレビュー・生成シート。
///
/// - 対象: DEBUG限定のE2E検証（フェーズ2 UI導線）。開発者の実機でのみ動く想定
///   （呼び出し元 `EditView` が `#if DEBUG` でゲートする）。
struct SkyMotionSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// 元にする写真（EditView の編集済みプレビュー、無ければ元画像）
    let sourceImage: UIImage

    // MARK: - State

    /// 回数パックの残高・購入フロー。⚠️ 残高は**表示用**で、生成可否はサーバーが決める。
    @ObservedObject private var creditService = SkyMotionCreditService.shared

    @State private var state: SkyMotionSheetState = .idle
    /// ユーザーが選んだプリセット（単一3択）。`loopDurationKey`（→サーバーの setpts）で
    /// 尺と減速の度合いが決まる。雲の移動量はプリセット共通（`SkyMotionPreset.driftWidthRatio`）。
    /// 既定は .calm（≒7.5秒・落ち着いた見た目）。
    @State private var selectedPreset: SkyMotionPreset = .calm
    /// 進行中ジョブID（UserDefaults 永続）。シートを閉じてもサーバーは生成を続けるため、これを
    /// 残しておき、次にシートを開いた時 `resumeActiveJobIfNeeded()` で監視を張り直して結果を
    /// 取り戻す（＝「閉じてもOK・完成後に開けば1回だけ表示」の担保）。
    /// ⚠️ シートを閉じた時にはクリアしない（再開の生命線）。クリアは **終端状態すべて**
    /// （completed/saved/downloadFailed/failed）到達時（`.onChange(of: state)` で一元化）。
    /// → 完成済みジョブが毎回復活して新規生成を塞ぐ事故を防ぐ（1回表示したら次回は idle）。
    /// キーは _v2: 旧 build(79/80) の未保存ジョブ（別プリセット/別drift）が復活する事故を断つため改名。
    @AppStorage("skyMotionActiveJobId_v2") private var activeJobId = ""
    /// 初回の写真送信同意シートの表示フラグ。
    /// `hasConsentedSkyMotionUpload` が false のまま「動かす」が押されたときに true にする
    /// （`WhatsNewContent` 等の永続化フラグ＋一時的な表示フラグの組み合わせと同じ流儀）。
    @State private var showingConsentSheet = false
    /// 「写真を海外AIサービス(fal.ai)へ送信する」ことへの同意済みフラグ。
    /// 一度同意すれば以後は確認なしで即 `startPipeline()` する（App Store 提出向けの
    /// 公開β運用を見据え、UserDefaults に永続化して端末をまたいでは再確認する設計）。
    /// キー命名は `WhatsNewContent` の `hasSeenLivingSkyCoachMarkKey` 等に倣う。
    @AppStorage("hasConsentedSkyMotionUpload") private var hasConsentedSkyMotionUpload = false
    /// パイプライン全体（準備 → アップロード → 待機 → DL）を持つ Task。
    /// シートを閉じたら `.onDisappear` で `cancel()` する（`LivingSkySheet.exportTask` と同じ流儀）。
    @State private var pipelineTask: Task<Void, Never>?
    /// ループ再生用の `AVQueuePlayer`。`completed`/`saved` になったタイミングで item をセットする。
    @State private var queuePlayer = AVQueuePlayer()
    /// `AVPlayerLooper` はシームレスループの生存期間を握るオブジェクト。`queuePlayer` と対で
    /// 保持しないと ARC で即座に解放されループが止まる。
    @State private var playerLooper: AVPlayerLooper?
    /// カメラロール保存中フラグ（`completed`/`saved` どちらの状態でも保存ボタンから遷移しうる）
    @State private var isSaving = false
    /// `downloadFailed` からの再ダウンロード中フラグ
    @State private var isRetryingDownload = false
    /// 保存アクション（`completed` → `saved`）が失敗したときのアラートメッセージ。
    ///
    /// ジョブ生成そのものの失敗（`state = .failed`、errorCode で文言分岐する経路）とは
    /// あえて別経路にしている。保存だけが失敗した場合（Photos権限拒否など）に `.failed` へ
    /// 遷移させると、せっかく生成できた動画・プレビューを画面から失わせてしまい、
    /// ユーザーは3回/日の枠を消費して最初からやり直す羽目になる。保存失敗はアラートに留め、
    /// `completed` 状態（＝動画とプレビュー）は維持したまま再度「保存」を押せるようにする。
    @State private var saveErrorMessage: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                content
            }
            .background(Color.black)
            .navigationTitle("空を動かす（β）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { dismiss() }
                        .foregroundColor(.white)
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .onAppear {
            LoggingService.shared.logEvent("sky_motion_opened", parameters: nil)
        }
        .task {
            // シートを開いた時、進行中/完成未保存のジョブが残っていれば監視を張り直す（再開）。
            // これで「閉じてもOK・完成後に開けば結果を表示」が成立する。
            resumeActiveJobIfNeeded()
            // 残高の購読と、**未完了トランザクションの再送**を開始する。
            // ⚠️ 再送はここが唯一の入口。前回「購入は済んだがサーバー加算の確認前に落ちた」
            //    ケースはここで拾い直される（＝課金したのに増えない事故の最後の砦）。
            creditService.start()
            await creditService.loadProducts()
        }
        .onChange(of: state) { newState in
            // 終端状態（完成/保存/DL失敗/失敗）に達したら再開対象から外す。これで完成済みジョブが
            // 毎回復活して新規生成を塞ぐ事故を防ぐ（1回表示→次回 idle）。in-flight（preparing/
            // uploading/waiting）中はクリアしない＝閉じても再開できる生命線。dismiss でもクリアしない。
            switch newState {
            case .completed, .saved, .downloadFailed, .failed:
                activeJobId = ""
            case .idle, .preparing, .uploading, .waiting:
                break
            }
        }
        .onDisappear {
            // パイプラインTaskをキャンセル（Firestore listener は observeJob の onTermination 経由で
            // 自動 remove される）。ループ再生も止めて余計な CPU/バッテリー消費を防ぐ。
            pipelineTask?.cancel()
            queuePlayer.pause()
            // player/looper を解放してから、保持しているローカル一時mp4を削除する（G6/codex-10）。
            // 本機能は DEBUG限定到達のため `LivingSkyVideoExporter.saveToPhotos` の
            // `#if !DEBUG` 削除分岐が走らず、ここで明示的に消さない限り残り続けてしまう。
            playerLooper = nil
            if let url = currentLocalVideoURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        .alert("保存に失敗しました", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { isPresented in
                if !isPresented { saveErrorMessage = nil }
            }
        )) {
            Button("OK") { saveErrorMessage = nil }
        } message: {
            if let saveErrorMessage {
                Text(saveErrorMessage)
            }
        }
        // 初回の写真送信同意シート。「動かす」タップ時に `hasConsentedSkyMotionUpload == false`
        // なら生成を始めずここを先に出す（`requestConsentThenStartPipeline()` 参照）。
        .sheet(isPresented: $showingConsentSheet) {
            SkyMotionConsentView(
                onAgree: {
                    hasConsentedSkyMotionUpload = true
                    LoggingService.shared.logEvent("sky_motion_consent_agreed", parameters: nil)
                    showingConsentSheet = false
                    startPipeline()
                },
                onCancel: {
                    showingConsentSheet = false
                }
            )
            .onAppear {
                LoggingService.shared.logEvent("sky_motion_consent_shown", parameters: nil)
            }
        }
    }

    // MARK: - Content（状態ごとの分岐）

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleView
        case .preparing, .uploading, .waiting:
            progressStateView
        case let .completed(url), let .saved(url):
            resultView(localVideoURL: url)
        case let .downloadFailed(videoURLString):
            downloadFailedView(videoURLString: videoURLString)
        case let .failed(errorCode, serverMessage):
            failedView(errorCode: errorCode, serverMessage: serverMessage)
        }
    }

    /// `.onDisappear` での一時ファイル削除用。`completed`/`saved` のときだけローカルURLを持つ。
    private var currentLocalVideoURL: URL? {
        switch state {
        case let .completed(url), let .saved(url):
            url
        default:
            nil
        }
    }

    // MARK: - idle

    private var idleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wind")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.8))
            Text("空を動かす（Kling版・β）")
                .font(.headline)
                .foregroundColor(.white)
            Text("この写真の空にゆるやかな動きをつけた動画を作ります。\n生成には数分かかることがあります。")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            // 残高表示。⚠️ これは**表示用**であって認可ではない（実際に生成できるかは
            //    サーバーの reserveAndClaimJob が無料枠と残高を見て決める）。
            if creditService.balance > 0 {
                Label("残り \(creditService.balance) 回ぶんのクレジット", systemImage: "ticket")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
            } else {
                Text("毎日1回まで無料で作れます")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            // 速さと尺がセットの単一3択（速い/標準/ゆっくり）。速さ=雲の移動量(trajectory)、尺=setpts。
            VStack(spacing: 6) {
                Text("動きの速さ・長さ")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                Picker("動きの速さ・長さ", selection: $selectedPreset) {
                    ForEach(SkyMotionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
            Button {
                requestConsentThenStartPipeline()
            } label: {
                Text("動かす")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - 進行中（preparing/uploading/waiting）

    private var progressStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            Text(progressMessage)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var progressMessage: String {
        switch state {
        case .preparing:
            "空を解析しています…"
        case .uploading:
            "アップロードしています…"
        case .waiting:
            // ⚠️ この安心文言は `.waiting`（＝サーバーがジョブを所有した後）だけに出す。
            //    preparing/uploading 中はクライアントのアップロードが走っており、閉じると
            //    onDisappear で cancel され「続かない」ため、ここに出すと嘘になる。
            "空を動かしています…（数分かかることがあります）\n"
                + "この画面を閉じても生成は続きます。完成後にもう一度開くと結果を表示します（通知でもお知らせします）。"
        default:
            ""
        }
    }

    // MARK: - 完成（completed/saved）

    private func resultView(localVideoURL: URL) -> some View {
        VStack(spacing: 0) {
            VideoPlayer(player: queuePlayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            VStack(spacing: 12) {
                saveButton(localVideoURL: localVideoURL)
                // 別プリセットで作り直す導線。保存しなくても idle に戻って再生成できる
                // （完成結果が居座って次の生成を塞ぐ事故を防ぐ・実機FB 2026-07-26）。
                Button {
                    regenerate()
                } label: {
                    Text("もう一度作る")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .onAppear {
            setUpLoopingPlayerIfNeeded(with: localVideoURL)
        }
    }

    /// 完成/保存後に「もう一度作る」で呼ぶ。現在のプレビューを片付けて idle に戻し、別プリセットで
    /// 再生成できるようにする。activeJobId は onChange(.completed 等) で既にクリア済みだが念のため空に。
    private func regenerate() {
        pipelineTask?.cancel()
        queuePlayer.pause()
        playerLooper = nil
        if let url = currentLocalVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeJobId = ""
        LoggingService.shared.logEvent("sky_motion_regenerate_tapped", parameters: nil)
        state = .idle
    }

    @ViewBuilder
    private func saveButton(localVideoURL: URL) -> some View {
        if case .saved = state {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text("カメラロールに保存しました")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        } else {
            Button {
                saveToPhotos(localVideoURL: localVideoURL)
            } label: {
                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("保存しています…")
                    }
                } else {
                    Text("カメラロールに保存")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.white.opacity(0.2)))
            .disabled(isSaving)
        }
    }

    // MARK: - 完成済みだが端末DL失敗（downloadFailed）

    /// サーバー側では完成済み（回数消費済み）だが、端末への動画ダウンロードに失敗した状態のビュー。
    /// `failedView` とは文言・導線を分ける（G5対応）。「もう一度試す」ではなく、同じ
    /// `videoURLString` からの再ダウンロードのみを促す（新規ジョブを作らせない＝回数を再消費させない）。
    private func downloadFailedView(videoURLString: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.circle.trianglebadge.exclamationmark")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.8))
            Text("動画はできたけど受信に失敗したの。通信環境を確認してもう一度受信してね")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                retryDownload(videoURLString: videoURLString)
            } label: {
                if isRetryingDownload {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("受信しています…")
                    }
                } else {
                    Text("もう一度受信する")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.white.opacity(0.15)))
            .disabled(isRetryingDownload)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: - 失敗

    private func failedView(errorCode: String?, serverMessage: String?) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: errorCode == "quota_exceeded" ? "hourglass" : "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.8))
            Text(failureMessage(for: errorCode, serverMessage: serverMessage))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            // 無料枠を使い切って残高も無いときだけ、購入導線を出す。
            // ⚠️ 日次上限（paid_daily_cap）で弾かれた場合は買い足しても今日は使えないので出さない。
            if errorCode == "quota_exceeded", creditService.balance == 0 {
                purchaseButton
            }
            Button {
                // 「動かす」ボタンからやり直せるよう idle に戻す（シート自体は閉じない。
                // シート自体を閉じたい場合はツールバーの「閉じる」を使う）。
                state = .idle
            } label: {
                Text("もう一度試す")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    /// 設計書§1 の `errorCode` ごとの日本語メッセージ。
    ///
    /// `quota_exceeded` は理由が2種類ある（無料枠を使い切って残高も無い／購入枠の日次上限）。
    /// サーバーが理由ごとに文言を書き分けているので、**あればそれをそのまま出す**
    /// （クライアントで理由を再判定すると、サーバーの上限値を二重管理することになる）。
    private func failureMessage(for errorCode: String?, serverMessage: String?) -> String {
        switch errorCode {
        case "quota_exceeded":
            serverMessage ?? "今日の生成回数を使い切ったみたい。また明日試してね"
        default:
            "生成に失敗したの。もう一度試してみて（回数は消費されていないわ）"
        }
    }

    // MARK: - 回数パックの購入導線

    /// クレジット購入ボタン。購入状態に応じてラベルと有効/無効が変わる。
    @ViewBuilder
    private var purchaseButton: some View {
        let price = creditService.displayPrice(for: SkyMotionProduct.pack5)
        let credits = SkyMotionProduct.displayCredits(for: SkyMotionProduct.pack5) ?? 5
        Button {
            Task { await creditService.purchase() }
        } label: {
            Group {
                switch creditService.purchaseState {
                case .purchasing, .verifying:
                    HStack(spacing: 8) {
                        ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text(creditService.purchaseState == .verifying ? "反映しています…" : "購入手続き中…")
                    }
                default:
                    // 価格は StoreKit から取れたときだけ出す（取れないのに「¥1,000」と
                    // 決め打ちすると、地域や価格改定でユーザーに嘘を見せることになる）。
                    Text(price.map { "\(credits)回パックを購入（\($0)）" } ?? "\(credits)回パックを購入")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Color.white.opacity(0.28)))
        }
        .disabled(isPurchaseInFlight)
        .padding(.horizontal, 24)
    }

    private var isPurchaseInFlight: Bool {
        switch creditService.purchaseState {
        case .purchasing, .verifying: true
        default: false
        }
    }

    // MARK: - 同意ゲート

    /// 「動かす」タップの入口。初回（`hasConsentedSkyMotionUpload == false`）は生成を始めず、
    /// 先に `SkyMotionConsentView` を表示して明示同意を取る。同意済みなら従来どおり即座に
    /// `startPipeline()` する（毎回確認すると UX を損なうため、同意は端末に永続化）。
    private func requestConsentThenStartPipeline() {
        guard hasConsentedSkyMotionUpload else {
            showingConsentSheet = true
            return
        }
        startPipeline()
    }

    // MARK: - パイプライン本体

    /// 「動かす」タップから、準備 → アップロード → ジョブ作成 → 完了待機 → 動画DL までを1つの
    /// Task にまとめて実行する。
    private func startPipeline() {
        guard pipelineTask == nil else { return }
        state = .preparing

        pipelineTask = Task {
            defer { pipelineTask = nil }
            do {
                // DEBUG限定のE2E検証機能のため未ログインは想定外だが、クラッシュさせず
                // 失敗表示にフォールバックする（`firestore.rules` の create 条件が
                // `request.auth.uid` を要求するため、未ログインではどのみち job 作成が失敗する）。
                guard let userId = Auth.auth().currentUser?.uid else {
                    state = .failed(errorCode: nil, serverMessage: nil)
                    return
                }

                // custom claim(skyMotionBeta) を付与直後のトークンに反映させるため強制リフレッシュする。
                // 付与前に取得済みのトークンには claim が乗っておらず、Storage/Firestore rules の
                // allowlist で 403 Permission denied になるため（E2E検証用の確実策）。
                // 失敗しても致命的ではない（後続の upload が 403 で失敗し .failed にフォールバックする）が、
                // 無言握り潰しにはせず理由をログに残す（403 の切り分けを可能にするため）。
                do {
                    _ = try await Auth.auth().currentUser?.getIDToken(forcingRefresh: true)
                } catch {
                    LoggingService.shared.logErrorEvent(
                        error, context: "sky_motion_token_refresh", category: .systemError
                    )
                }

                // 雲の移動量(画像幅比)はプリセット共通。プリセットの違いは loopDurationKey(尺)側で付く。
                let assets = try await SkyMotionAssetPreparer().prepare(
                    image: sourceImage, driftWidthRatio: SkyMotionPreset.driftWidthRatio
                )
                try Task.checkCancellation()

                state = .uploading
                let jobService = SkyMotionJobService()
                let jobId = try await jobService.createJob(
                    assets: assets, userId: userId, loopDuration: selectedPreset.loopDurationKey
                )
                try Task.checkCancellation()

                // 以降サーバーがジョブを所有する。シートを閉じても生成は続くため、再開できるよう
                // ID を永続化する（クリアは .saved/.failed 到達時のみ・onChange で一元化）。
                activeJobId = jobId
                state = .waiting
                LoggingService.shared.logEvent("sky_motion_job_created", parameters: [
                    "job_id": jobId,
                    "loop_preset": selectedPreset.rawValue,
                ])

                try await observeJobUntilTerminal(jobId: jobId, using: jobService)
            } catch {
                // シートを閉じた（.onDisappear → pipelineTask.cancel()）ことによる中断は
                // 正常操作なのでエラー表示しない。URLSession の非同期APIはキャンセル時に
                // CancellationError ではなく URLError(.cancelled) を投げることがあるため両方見る。
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                LoggingService.shared.logErrorEvent(error, context: "sky_motion_pipeline", category: .systemError)
                state = .failed(errorCode: nil, serverMessage: nil)
            }
        }
    }

    /// 既存ジョブ（進行中/完成）の監視を張り、完了/失敗/DL失敗のいずれかに達したら状態を確定する。
    /// `startPipeline`（新規作成後）と `resumeActiveJobIfNeeded`（再開）で共有する。
    /// `observeJob` は AsyncThrowingStream。listener がエラーを受けたら throwing で終端するため
    /// （codex-9対応）、`for try await` で受けて呼び出し元の catch に落とす。
    private func observeJobUntilTerminal(jobId: String, using jobService: SkyMotionJobService) async throws {
        for try await job in jobService.observeJob(jobId: jobId) {
            try Task.checkCancellation()

            switch job.status {
            case .pending, .submitting, .submitted:
                continue // waiting のまま様子見

            case .completed:
                guard let videoURLString = job.videoURL else {
                    state = .failed(errorCode: nil, serverMessage: nil)
                    return
                }
                do {
                    let localURL = try await downloadVideo(from: videoURLString)
                    state = .completed(localVideoURL: localURL)
                    LoggingService.shared.logEvent("sky_motion_video_ready", parameters: nil)
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        return
                    }
                    // サーバー側は既に completed（＝回数消費済み）のため、この失敗を
                    // 通常の `.failed`（「回数は消費されていない」の文言）にすると
                    // 事実と異なる（G5対応）。専用状態で「もう一度受信」導線を出す。
                    LoggingService.shared.logErrorEvent(
                        error, context: "sky_motion_download_after_completed", category: .systemError
                    )
                    state = .downloadFailed(videoURLString: videoURLString)
                }
                return

            case .failed:
                state = .failed(errorCode: job.errorCode, serverMessage: job.error)
                LoggingService.shared.logEvent("sky_motion_job_failed", parameters: [
                    "error_code": job.errorCode ?? "unknown",
                ])
                return
            }
        }
    }

    /// シートを開いた時、`activeJobId` に進行中/完成未保存のジョブが残っていれば監視を張り直す。
    /// 「閉じてもOK・完成後に開けば表示」の担保。`.idle` かつ pipelineTask 不在のときだけ動く
    /// （生成中の再表示での二重監視や、既に表示中の状態の破壊を防ぐ）。
    private func resumeActiveJobIfNeeded() {
        guard case .idle = state, pipelineTask == nil, !activeJobId.isEmpty else { return }
        let jobId = activeJobId
        state = .waiting
        LoggingService.shared.logEvent("sky_motion_job_resumed", parameters: ["job_id": jobId])
        pipelineTask = Task {
            defer { pipelineTask = nil }
            do {
                try await observeJobUntilTerminal(jobId: jobId, using: SkyMotionJobService())
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                LoggingService.shared.logErrorEvent(error, context: "sky_motion_resume", category: .systemError)
                state = .failed(errorCode: nil, serverMessage: nil)
            }
        }
    }

    /// 完成した mp4（Storageのダウンロード URL）をローカル一時ファイルへ保存する。
    /// `LivingSkyVideoExporter.saveToPhotos(fileURL:)` に渡すファイルとして再利用するため、
    /// 拡張子 `.mp4` を明示的に付ける（`URLSession.download` の一時ファイルは拡張子なし）。
    private func downloadVideo(from remoteURLString: String) async throws -> URL {
        guard let remoteURL = URL(string: remoteURLString) else {
            throw SkyMotionSheetError.invalidVideoURL
        }

        let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw SkyMotionSheetError.downloadFailed
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return destinationURL
    }

    /// `downloadFailed` 状態からの再ダウンロード。新規ジョブは作らず、同じ `videoURLString` から
    /// 再取得するだけ（3回/日の枠を再消費させないため）。失敗しても `.downloadFailed` のまま留まり、
    /// ボタンから再試行し続けられる。
    private func retryDownload(videoURLString: String) {
        guard !isRetryingDownload else { return }
        isRetryingDownload = true

        Task {
            defer { isRetryingDownload = false }
            do {
                let localURL = try await downloadVideo(from: videoURLString)
                state = .completed(localVideoURL: localURL)
                LoggingService.shared.logEvent("sky_motion_video_ready", parameters: nil)
            } catch {
                LoggingService.shared.logErrorEvent(error, context: "sky_motion_download_retry", category: .systemError)
            }
        }
    }

    /// `AVQueuePlayer` + `AVPlayerLooper` でシームレスループ再生を開始する。
    /// `completed` → `saved` の状態遷移で `resultView` が再度 `.onAppear` を呼んでも
    /// 二重セットアップしないよう `playerLooper` の有無で判定する。
    private func setUpLoopingPlayerIfNeeded(with url: URL) {
        guard playerLooper == nil else { return }
        let item = AVPlayerItem(url: url)
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.play()
    }

    /// 「カメラロールに保存」ボタンのアクション。
    /// `LivingSkyVideoExporter.saveToPhotos` をそのまま再利用するが、本機能は DEBUG限定到達のため
    /// そちらの `#if !DEBUG` 削除分岐は走らない。一時ファイルの明示削除は `.onDisappear`（player/looper
    /// 解放後）にまとめている（G6/codex-10対応）。保存直後にここで消さない理由: `.saved` 状態でも
    /// プレビューはループ再生を継続する仕様（`state` の doc comment・`saveErrorMessage` の doc comment
    /// 参照）で、`AVPlayerLooper` が内部でループ用に URL を再オープンする可能性を否定できない以上、
    /// 再生中のファイルを削除するのは避ける。`onDisappear` まで待てば再生終了後の削除になり安全。
    private func saveToPhotos(localVideoURL: URL) {
        guard !isSaving else { return }
        isSaving = true

        Task {
            defer { isSaving = false }
            do {
                try await LivingSkyVideoExporter().saveToPhotos(fileURL: localVideoURL)
                state = .saved(localVideoURL: localVideoURL)
                LoggingService.shared.logEvent("sky_motion_video_saved", parameters: nil)
            } catch {
                LoggingService.shared.logErrorEvent(error, context: "sky_motion_save", category: .systemError)
                saveErrorMessage = error.userFriendlyMessage
            }
        }
    }
}

// MARK: - Consent View（初回の写真送信同意）☀️

/// 「空を動かす（Kling版）」で写真を海外AIサービス（fal.ai）へ送信することへの、初回同意画面。
///
/// - `SkyMotionSheet` から `hasConsentedSkyMotionUpload == false` のときだけ `.sheet` で提示される。
///   同意すると `SkyMotionSheet` 側で `hasConsentedSkyMotionUpload = true` を永続化するため、
///   このビュー自身は状態を持たず、同意/キャンセルのアクションを親に委譲するだけの純粋な表示。
/// - デザインは `SettingsView.swift` の `PrivacyPolicyView`／`TermsOfServiceView`（黒背景+白文字の
///   ダーク基調・"閉じる" ボタン）と `SkyMotionSheet` 自身のトーン（Capsule ボタン）を踏襲する。
struct SkyMotionConsentView: View {
    /// 「同意して続ける」タップ時に呼ばれる（フラグ永続化・計装・シート閉じる・生成開始は呼び出し元の責務）。
    let onAgree: () -> Void
    /// 「キャンセル」タップ時に呼ばれる（生成は開始しない）。
    let onCancel: () -> Void

    /// プライバシーポリシー全文シート（`SettingsView.swift` の `PrivacyPolicyView` を再利用）の表示フラグ。
    @State private var showingPrivacyPolicy = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: "paperplane.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .center)

                        Text(
                            "この機能は、あなたが選んだ空の写真を海外のAIサービス"
                                + "（fal.ai／米国）に送信して、空が動く動画を生成します。"
                                + "生成された動画はあなたの端末に保存されます。"
                                + "生成には数分かかることがあります"
                                + "（現在ベータ・1日3回まで）。"
                        )
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)

                        // プライバシーポリシーへの導線。
                        // 現状のプライバシーポリシー本文（SettingsView.swift）は「空を動かす」の
                        // fal.ai 送信に未対応（メインが Phase B で更新予定）だが、導線自体は
                        // 既存の在り処（アプリ内 PrivacyPolicyView）へ張っておく。
                        Button {
                            showingPrivacyPolicy = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("プライバシーポリシーを見る")
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white.opacity(0.85))
                            .underline()
                        }
                    }
                    .padding(24)
                }

                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Button {
                            onAgree()
                        } label: {
                            Text("同意して続ける")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .background(Capsule().fill(Color.white.opacity(0.2)))
                        }

                        Button {
                            onCancel()
                        } label: {
                            Text("キャンセル")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("写真の送信について")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { onCancel() }
                        .foregroundColor(.white)
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingPrivacyPolicy) {
            PrivacyPolicyView()
        }
    }
}
