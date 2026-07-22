// ⭐️ SkyMotionSheet.swift
// 「空を動かす」（Kling版）フェーズ2: DEBUG限定E2E検証用のUI導線
//
//  SkyMotionSheet.swift
//  Soramoyou
//
// 設計書: docs/sky-motion-design.md（唯一のデータ契約の土台）
//   §0 アーキテクチャ概要: 画像3枚アップロード → livingSkyJobs 作成 → snapshot listener で
//      status 変化を待つ（pending → submitted → completed/failed）
//   §5 回数・コスト方針: 3回/日/ユーザー。quota_exceeded 時は fal.ai を一切呼び出さない
//
// ⚠️ 命名・見た目が近い既存の Metal ローカル版 Living Sky（`LivingSkySheet`・`LivingSkyPreviewView.swift`）
//    とは別機能。UI クロームの作りだけ参考にしたが、型は一切再利用しない（新規実装）。
//    既存 LivingSky* 系ファイルには一切手を入れない（温存）。
//
// スコープ: DEBUG限定のE2E検証（フェーズ2 UI導線）。本番導線化はしない
//   （呼び出し元 `EditView` 側で `#if DEBUG` ゲート必須。設計書§7）。
//   同意画面は今回スコープ外（DEBUG・自分の写真のみで検証するため）。
//   スライダー等のパラメータUIも持たない（PoC固定レシピ。マスク・軌跡・aspect比は
//   `SkyMotionAssetPreparer` が自動算出する）。

import SwiftUI
import AVKit
import AVFoundation
import FirebaseAuth

/// `SkyMotionSheet` の処理中に発生しうるエラー（クライアント側のみ）。
enum SkyMotionSheetError: Error, LocalizedError {
    /// `livingSkyJobs.videoURL` が不正な URL 文字列だった
    case invalidVideoURL
    /// 完成した mp4 のダウンロードに失敗した（HTTPステータス異常等）
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidVideoURL:
            return "動画のURLが不正です"
        case .downloadFailed:
            return "動画のダウンロードに失敗しました"
        }
    }
}

/// 「空を動かす」（Kling版）の状態機械。
/// クライアント側の処理段階（準備/アップロード）と、Cloud Functions 側のジョブ状態
/// （pending/submitted → completed/failed）を1つの enum にまとめている。
enum SkyMotionSheetState: Equatable {
    /// 初期表示（まだ何もしていない）
    case idle
    /// `SkyMotionAssetPreparer` でマスク・軌跡・aspect比を準備中
    case preparing
    /// Storage への3ファイルアップロード + Firestore ジョブ作成中
    case uploading
    /// ジョブ作成後、Cloud Functions 側の処理（pending → submitted → completed/failed）を待機中
    case waiting
    /// 完成。ローカルにDL済みの mp4 の URL を保持する
    case completed(localVideoURL: URL)
    /// カメラロールへ保存済み（`completed` の動画はそのまま保持し続ける。プレビューは消さない）
    case saved(localVideoURL: URL)
    /// 失敗。`errorCode` はジョブ側の失敗理由（設計書§1: quota_exceeded 等）。
    /// クライアント側の失敗（準備/アップロード/未ログイン等）では nil になる。
    case failed(errorCode: String?)
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

    @State private var state: SkyMotionSheetState = .idle
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
        .onDisappear {
            // パイプラインTaskをキャンセル（Firestore listener は observeJob の onTermination 経由で
            // 自動 remove される）。ループ再生も止めて余計な CPU/バッテリー消費を防ぐ。
            pipelineTask?.cancel()
            queuePlayer.pause()
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
    }

    // MARK: - Content（状態ごとの分岐）

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            idleView
        case .preparing, .uploading, .waiting:
            progressStateView
        case .completed(let url), .saved(let url):
            resultView(localVideoURL: url)
        case .failed(let errorCode):
            failedView(errorCode: errorCode)
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
            Text("この写真の空にゆるやかな動きをつけた動画を作ります。\n生成には数分かかることがあります（1日3回まで）。")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button {
                startPipeline()
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
            return "空を解析しています…"
        case .uploading:
            return "アップロードしています…"
        case .waiting:
            return "空を動かしています…（数分かかることがあります）"
        default:
            return ""
        }
    }

    // MARK: - 完成（completed/saved）

    private func resultView(localVideoURL: URL) -> some View {
        VStack(spacing: 0) {
            VideoPlayer(player: queuePlayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            saveButton(localVideoURL: localVideoURL)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
        .onAppear {
            setUpLoopingPlayerIfNeeded(with: localVideoURL)
        }
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

    // MARK: - 失敗

    private func failedView(errorCode: String?) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.8))
            Text(failureMessage(for: errorCode))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
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
    /// `errorCode == nil`（クライアント側の失敗・未知のコード）は「その他」扱いにまとめる。
    private func failureMessage(for errorCode: String?) -> String {
        switch errorCode {
        case "quota_exceeded":
            return "今日の無料回数（3回）を使い切ったみたい。また明日試してね"
        default:
            return "生成に失敗したの。もう一度試してみて（回数は消費されていないわ）"
        }
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
                    state = .failed(errorCode: nil)
                    return
                }

                let assets = try await SkyMotionAssetPreparer().prepare(image: sourceImage)
                try Task.checkCancellation()

                state = .uploading
                let jobService = SkyMotionJobService()
                let jobId = try await jobService.createJob(assets: assets, userId: userId)
                try Task.checkCancellation()

                state = .waiting
                LoggingService.shared.logEvent("sky_motion_job_created", parameters: ["job_id": jobId])

                for await job in jobService.observeJob(jobId: jobId) {
                    try Task.checkCancellation()

                    switch job.status {
                    case .pending, .submitted:
                        continue // waiting のまま様子見

                    case .completed:
                        guard let videoURLString = job.videoURL else {
                            state = .failed(errorCode: nil)
                            return
                        }
                        let localURL = try await downloadVideo(from: videoURLString)
                        state = .completed(localVideoURL: localURL)
                        LoggingService.shared.logEvent("sky_motion_video_ready", parameters: nil)
                        return

                    case .failed:
                        state = .failed(errorCode: job.errorCode)
                        LoggingService.shared.logEvent("sky_motion_job_failed", parameters: [
                            "error_code": job.errorCode ?? "unknown"
                        ])
                        return
                    }
                }
            } catch {
                // シートを閉じた（.onDisappear → pipelineTask.cancel()）ことによる中断は
                // 正常操作なのでエラー表示しない。URLSession の非同期APIはキャンセル時に
                // CancellationError ではなく URLError(.cancelled) を投げることがあるため両方見る。
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                LoggingService.shared.logErrorEvent(error, context: "sky_motion_pipeline", category: .systemError)
                state = .failed(errorCode: nil)
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
              (200..<300).contains(httpResponse.statusCode) else {
            throw SkyMotionSheetError.downloadFailed
        }

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return destinationURL
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
    /// `LivingSkyVideoExporter.saveToPhotos` をそのまま再利用する（DEBUGビルドでは保存成功後も
    /// 一時ファイルを削除しない設計を踏襲。Releaseビルドでのみ削除される）。
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
