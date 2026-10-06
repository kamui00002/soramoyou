//
//  PostDocumentDecoder.swift
//  Soramoyou
//
//  Firestore の投稿ドキュメント群を Post 配列へ変換する ⭐️
//

import FirebaseFirestore
import Foundation

/// 投稿として変換できる Firestore ドキュメント（パスと中身だけを持つ）
///
/// `QueryDocumentSnapshot` は Firestore 無しでは作れないため、変換処理を
/// この最小限の形に対して書き、テストでは偽ドキュメントを渡せるようにする。
protocol PostSourceDocument {
    /// ドキュメントのパス（例: `posts/abc123`）。ログで壊れたドキュメントを特定するために使う
    var documentPath: String { get }
    /// ドキュメントのフィールド
    func data() -> [String: Any]
}

extension QueryDocumentSnapshot: PostSourceDocument {
    var documentPath: String { reference.path }
}

/// Firestore の投稿ドキュメント群を Post 配列へ変換する ⭐️
enum PostDocumentDecoder {
    /// 変換に失敗した 1 件の情報
    struct Failure {
        /// どの取得経路で失敗したか（例: `home_feed`）。ログの絞り込みキーになる
        let source: String
        /// 失敗したドキュメントのパス
        let path: String
        /// `Post(from:)` が投げたエラー
        let error: Error
    }

    /// ドキュメント群を Post 配列へ変換する
    ///
    /// 1 件の変換に失敗しても例外は投げず、その 1 件だけを飛ばして `onFailure` に渡す。
    /// 旧実装は `try documents.compactMap { try Post(from:) }` だったため、
    /// 必須項目を欠いた投稿が 1 件あるだけで、そのページ全体が全ユーザーに表示されなくなっていた。
    /// （⚠️ `compactMap { try? }` で黙って落とすのも禁止＝tech-spec.md の Firebase 実装規約）
    ///
    /// - Important: ページングの起点（次ページの `start(afterDocument:)`）は呼び出し側で
    ///   **`snapshot.documents.last` のまま**にすること。変換後の配列から決めると、
    ///   末尾の壊れたドキュメントを起点にできず同じページを読み直してしまう。
    /// - Note: スキップで返す件数はページサイズを割ることがある。続きの有無は件数でなく、
    ///   呼び出し側が `PostPage(posts:snapshot:limit:)` で作る `isExhausted`
    ///   （実際に読んだドキュメント数）で判定すること。
    /// - Parameters:
    ///   - documents: クエリで取得したドキュメント
    ///   - source: 取得経路の名前（ログ用。例: `home_feed`）
    ///   - onFailure: 1 件の変換に失敗したときに呼ばれる（既定はログ送信。テストでは差し替える）
    /// - Returns: 変換できた投稿（元の並び順のまま）
    static func decodePosts(
        _ documents: [some PostSourceDocument],
        source: String,
        onFailure: (Failure) -> Void = PostDocumentDecoder.report
    ) -> [Post] {
        documents.compactMap { document in
            do {
                return try Post(from: document.data())
            } catch {
                // 壊れた 1 件は記録して飛ばし、ページの他の投稿は生かす
                onFailure(Failure(source: source, path: document.documentPath, error: error))
                return nil
            }
        }
    }

    /// 変換失敗をログに残す（既定の onFailure）
    ///
    /// print だけだと本番では誰も気づけないため、PostHog / Firebase Analytics にも
    /// `post_decode_failed` として送る（source で取得経路、path で壊れた投稿を特定できる）。
    /// Crashlytics には送らない: 壊れた投稿 1 件でも、全ユーザーがページを開くたびに
    /// 発生するため、エラーとして大量に積み上がってしまう。
    static func report(_ failure: Failure) {
        // PostModelError は LocalizedError ではないので、localizedDescription だと
        // 「The operation couldn't be completed.」になる。ケース名が出る形で残す。
        let errorDescription = String(describing: failure.error)
        print("❌ 投稿デコード失敗 source=\(failure.source) path=\(failure.path) error=\(errorDescription)")
        LoggingService.shared.logEvent("post_decode_failed", parameters: [
            "source": failure.source,
            "path": failure.path,
            "error": errorDescription,
        ])
    }
}
