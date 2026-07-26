// ⭐️ SkyMotionJobService.swift
// 「空を動かす」（Kling版）フェーズ1b: Storage アップロード + Firestore ジョブ作成 + 状態監視
//
//  SkyMotionJobService.swift
//  Soramoyou
//
// 設計書: docs/sky-motion-design.md（唯一のデータ契約の土台）
//   §0 アーキテクチャ概要:
//     1. 画像3枚を Storage へアップロード（livingSky/{uid}/{jobId}/source.jpg 等）
//     2. Firestore livingSkyJobs/{jobId} を status="pending" で作成
//     3. snapshot listener で status の変化を待つ
//   （4〜8 は Cloud Functions 側の責務・本ファイルのスコープ外）
//
// ⚠️ 命名が近い（`LivingSky*`）既存の Metal ローカル版 Living Sky とは別機能。
//    `StorageService.swift` を参考にしたが、本サービスは自己完結させる（既存ファイルは変更しない）。
//    StorageService.uploadImage は「投稿用画像＋ダウンロードURL取得」に特化しているのに対し、
//    本サービスがアップロードする3ファイルは Cloud Functions が Storage パスを直接参照する
//    （ダウンロードURLは不要。functions/skyMotion.js の getReadSignedUrl(job.sourcePath) 等を参照）。

import FirebaseFirestore
import FirebaseStorage
import Foundation
import os

/// `SkyMotionJobService` が投げるエラー
enum SkyMotionJobServiceError: LocalizedError {
    /// アップロード対象の画像がサイズ上限（storage.rules の isValidSize() と同じ 5MB）を超えている
    case fileTooLarge(fileName: String)
    /// Storage へのアップロードに失敗した
    case uploadFailed(Error)
    /// Firestore へのジョブドキュメント作成に失敗した
    case jobCreationFailed(Error)

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(fileName):
            "\(fileName) のサイズが大きすぎます（最大5MB）"
        case let .uploadFailed(error):
            "画像のアップロードに失敗しました: \(error.localizedDescription)"
        case let .jobCreationFailed(error):
            "ジョブの作成に失敗しました: \(error.localizedDescription)"
        }
    }
}

protocol SkyMotionJobServiceProtocol {
    /// `SkyMotionAssetPreparer.prepare` の出力を Storage へアップロードし、
    /// Firestore に `status="pending"` の初期ジョブドキュメントを作成する。
    /// - Parameter loopDuration: ループ動画の尺（`SkyMotionPreset.loopDurationKey`: "short"/"medium"/"long"）。
    /// - Returns: 作成された jobId（Storage パス・Firestore ドキュメントIDと共通）
    func createJob(
        assets: PreparedSkyMotionAssets, userId: String, loopDuration: String
    ) async throws -> String

    /// jobId の状態変化を配信する。
    /// `completed` で `videoURL` を、`failed` で `errorCode`/`error` を持つ `SkyMotionJob` が流れる。
    /// `completed`/`failed`（終端状態）に達すると自動的にストリームを終了し listener を remove する。
    /// 呼び出し側が Task をキャンセルした場合も `onTermination` 経由で listener を remove する。
    /// listener が error を受け取った場合はストリームを `throwing` で終端する（呼び出し側は
    /// `for try await` で受け、失敗として扱えるようにする。エラー時に何も終端しないと
    /// `for await` が永久に待機し続け、呼び出し元の UI が固まってしまうため）。
    func observeJob(jobId: String) -> AsyncThrowingStream<SkyMotionJob, Error>
}

final class SkyMotionJobService: SkyMotionJobServiceProtocol {
    // MARK: - 定数

    /// Storage 側の 5MB 上限（`storage.rules` の `isValidSize()` と一致させる）
    private static let maxFileSize: Int = 5 * 1024 * 1024

    private static let logger = Logger(
        subsystem: "com.soramoyou.photo-editor",
        category: "SkyMotionJobService"
    )

    // MARK: - Properties

    private let db: Firestore
    private let storage: Storage

    private var jobsCollection: CollectionReference {
        db.collection("livingSkyJobs")
    }

    // MARK: - Init

    init(db: Firestore = Firestore.firestore(), storage: Storage = Storage.storage()) {
        self.db = db
        self.storage = storage
    }

    // MARK: - Public: ジョブ作成

    func createJob(
        assets: PreparedSkyMotionAssets,
        userId: String,
        loopDuration: String = SkyMotionPreset.calm.loopDurationKey
    ) async throws -> String {
        let jobId = UUID().uuidString
        let basePath = "livingSky/\(userId)/\(jobId)"
        let sourcePath = "\(basePath)/source.jpg"
        let skyMaskPath = "\(basePath)/sky_mask.png"
        let groundMaskPath = "\(basePath)/ground_mask.png"

        // 3ファイルを並列アップロード。戻り値のダウンロードURLは使わない
        // （Cloud Functions は Storage パスを直接参照して署名URLを発行するため。
        //   functions/skyMotion.js の getReadSignedUrl(job.sourcePath) 参照）。
        async let sourceUpload: Void = uploadData(
            assets.sourceData, path: sourcePath, contentType: "image/jpeg", fileName: "source.jpg"
        )
        async let skyMaskUpload: Void = uploadData(
            assets.skyMaskData, path: skyMaskPath, contentType: "image/png", fileName: "sky_mask.png"
        )
        async let groundMaskUpload: Void = uploadData(
            assets.groundMaskData, path: groundMaskPath, contentType: "image/png", fileName: "ground_mask.png"
        )
        _ = try await (sourceUpload, skyMaskUpload, groundMaskUpload)

        let trajectory = assets.trajectory.map { SkyMotionTrajectoryPoint(rounding: $0) }
        let job = SkyMotionJob(
            id: jobId,
            userId: userId,
            sourcePath: sourcePath,
            skyMaskPath: skyMaskPath,
            groundMaskPath: groundMaskPath,
            aspectRatio: assets.aspectRatio,
            trajectory: trajectory,
            loopDuration: loopDuration
        )

        do {
            // 設計書§1: id は doc ID と一致させる（Draft/Post と同じ「id フィールドを重複保持」方式）。
            try await jobsCollection.document(jobId).setData(job.toFirestoreData())
        } catch {
            throw SkyMotionJobServiceError.jobCreationFailed(error)
        }

        Self.logger.info("空を動かす: ジョブ作成成功 jobId=\(jobId, privacy: .public)")
        return jobId
    }

    // MARK: - Private: アップロード

    private func uploadData(_ data: Data, path: String, contentType: String, fileName: String) async throws {
        guard data.count <= Self.maxFileSize else {
            throw SkyMotionJobServiceError.fileTooLarge(fileName: fileName)
        }

        let storageRef = storage.reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = contentType

        // メモリ上の Data を直接アップロードする（putData）。
        // ※ 以前は「並列 putData は GTMSessionFetcher 競合で 400 "already finalized" になる」
        //   という仮説で putFile＋一時ファイル＋already-finalized フォールバック＋直列化を
        //   入れていたが、実際の失敗の真因は custom claim(skyMotionBeta) の付与漏れ(403)で、
        //   これらは赤いニシンだった（/review-full 指摘 E）。claim 修正後に putData＋並列へ戻した。
        //   万一 400 "already finalized" が実機で再発したら putFile 版に戻す。
        do {
            _ = try await storageRef.putDataAsync(data, metadata: metadata)
        } catch {
            // アップロード失敗は握り潰さず必ず throw する（原因不明の下流 fal 404 化を防ぐ）。
            throw SkyMotionJobServiceError.uploadFailed(error)
        }
    }

    // MARK: - Public: 状態監視

    func observeJob(jobId: String) -> AsyncThrowingStream<SkyMotionJob, Error> {
        AsyncThrowingStream { continuation in
            let listener = jobsCollection.document(jobId).addSnapshotListener { snapshot, error in
                if let error {
                    Self.logger.error(
                        "空を動かす: livingSkyJobs リスナーエラー jobId=\(jobId, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    // エラーを無視して return するだけだと、呼び出し側の `for await` が
                    // 永久に次のイベントを待ち続け UI が固まる（codex-9）。
                    // throwing で終端し、呼び出し側が `.failed` 表示へ遷移できるようにする。
                    continuation.finish(throwing: error)
                    return
                }
                guard let snapshot else {
                    return
                }
                guard let job = SkyMotionJob(from: snapshot) else {
                    // ドキュメントは取得できたがデコードに失敗（必須フィールド欠落等）。
                    // 無言スキップせずログに残す（tech-spec.md「壊れたドキュメントを無言で
                    // 落とすの禁止」準拠）。listener 自体は継続し、次の更新を待つ。
                    Self.logger.error(
                        "空を動かす: livingSkyJobs デコード失敗 jobId=\(jobId, privacy: .public)"
                    )
                    return
                }

                continuation.yield(job)

                // 終端状態（completed/failed）に達したらストリームを終了する。
                // 設計書§0: 状態遷移は pending→submitting→submitted→completed/failed で完結するため、
                // それ以降 Cloud Functions がドキュメントを更新することはない
                // （listener を張り続ける意味がない＝リソースリークになる）。
                if job.status == .completed || job.status == .failed {
                    continuation.finish()
                }
            }

            // ストリーム終了時（上の finish() 呼び出し・呼び出し側の Task キャンセルいずれも）に
            // 必ず listener を remove する（StorageService.uploadProgress と同じ onTermination 流儀）。
            continuation.onTermination = { _ in
                listener.remove()
            }
        }
    }
}
