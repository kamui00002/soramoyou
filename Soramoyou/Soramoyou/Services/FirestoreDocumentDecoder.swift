//
//  FirestoreDocumentDecoder.swift
//  Soramoyou
//
//  Firestore のコメント・下書きドキュメント群をモデル配列へ変換する ⭐️
//

import FirebaseFirestore
import Foundation

/// 1 件ずつ変換できる Firestore ドキュメント（ID・パス・中身だけを持つ）
///
/// `QueryDocumentSnapshot` は Firestore 無しでは作れないため、変換処理を
/// この最小限の形に対して書き、テストでは偽ドキュメントを渡せるようにする。
///
/// ⚠️ パスのプロパティ名を `documentPath` にしないこと。投稿用の `PostSourceDocument`
///    （別ブランチ）が `QueryDocumentSnapshot` に `documentPath` を生やすため、
///    同名にすると両方が main に入った時点で二重定義のビルドエラーになる。
protocol FirestoreSourceDocument {
    /// ドキュメント ID（`QueryDocumentSnapshot` が元から持っている）
    var documentID: String { get }
    /// ドキュメントのパス（例: `comments/abc123`）。ログで壊れたドキュメントを特定するために使う
    var firestorePath: String { get }
    /// ドキュメントのフィールド（`QueryDocumentSnapshot` が元から持っている）
    func data() -> [String: Any]
}

extension QueryDocumentSnapshot: FirestoreSourceDocument {
    var firestorePath: String { reference.path }
}

/// Firestore のコメント・下書きドキュメント群をモデル配列へ変換する ⭐️
///
/// 壊れたドキュメント（必須項目の欠落・型違い）が 1 件混ざっても一覧全体を失敗させない。
/// 失敗した 1 件はパスとエラーを記録してスキップする（docs/tech-spec.md の Firebase 実装規約）。
/// Android 版など別クライアントが同じコレクションに書くため、想定外の形のドキュメントは現実に起こりうる。
/// ⚠️ `compactMap { try? ... }` で黙って落とすのは禁止。必ず `onFailure` を通して痕跡を残す。
enum FirestoreDocumentDecoder {
    /// 何のドキュメントを変換していたか
    enum Kind {
        case comment
        case draft

        /// 解析イベント名（PostHog / Firebase Analytics）。投稿用の `post_decode_failed` と揃える
        var eventName: String {
            switch self {
            case .comment: "comment_decode_failed"
            case .draft: "draft_decode_failed"
            }
        }
    }

    /// 変換に失敗した 1 件の情報
    struct Failure {
        /// 何のドキュメントを変換していたか
        let kind: Kind
        /// 失敗したドキュメントのパス
        let path: String
        /// モデルの init が投げたエラー
        let error: Error
    }

    /// コメントのドキュメント群を Comment 配列へ変換する
    /// - Parameters:
    ///   - documents: クエリで取得したドキュメント
    ///   - onFailure: 1 件の変換に失敗したときに呼ばれる
    /// - Returns: 変換できたコメント（並び順はドキュメントの順のまま）
    static func decodeComments(
        _ documents: [some FirestoreSourceDocument],
        onFailure: (Failure) -> Void = FirestoreDocumentDecoder.report
    ) -> [Comment] {
        decodeEach(documents, kind: .comment, onFailure: onFailure) { document in
            try Comment(from: document.data(), documentId: document.documentID)
        }
    }

    /// 下書きのドキュメント群を Draft 配列へ変換する
    /// - Parameters:
    ///   - documents: クエリで取得したドキュメント
    ///   - onFailure: 1 件の変換に失敗したときに呼ばれる
    /// - Returns: 変換できた下書き（並び順はドキュメントの順のまま）
    static func decodeDrafts(
        _ documents: [some FirestoreSourceDocument],
        onFailure: (Failure) -> Void = FirestoreDocumentDecoder.report
    ) -> [Draft] {
        decodeEach(documents, kind: .draft, onFailure: onFailure) { document in
            try Draft(from: document.data())
        }
    }

    /// 変換失敗をログと解析イベントに残す（既定の onFailure）
    ///
    /// クラッシュしない不具合はテレメトリに残さないと誰も気づけないため、print に加えて
    /// 解析イベントも送る（docs/pre-release-checklist.md §1）。パスはドキュメント ID だけで PII を含まない。
    static func report(_ failure: Failure) {
        // `localizedDescription` だと `missingRequiredFields` などの中身が消えるため `\(error)` で書く
        let errorDescription = String(describing: failure.error)
        print("❌ デコード失敗 kind=\(failure.kind) path=\(failure.path) error=\(errorDescription)")
        LoggingService.shared.logEvent(failure.kind.eventName, parameters: [
            "path": failure.path,
            "error": errorDescription,
        ])
    }

    // MARK: - Private

    /// ドキュメントを 1 件ずつ変換し、失敗した 1 件は onFailure に渡してスキップする
    private static func decodeEach<Document: FirestoreSourceDocument, Value>(
        _ documents: [Document],
        kind: Kind,
        onFailure: (Failure) -> Void,
        decode: (Document) throws -> Value
    ) -> [Value] {
        documents.compactMap { document in
            do {
                return try decode(document)
            } catch {
                onFailure(Failure(kind: kind, path: document.firestorePath, error: error))
                return nil
            }
        }
    }
}
