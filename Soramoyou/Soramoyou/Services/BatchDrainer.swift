//
//  BatchDrainer.swift
//  Soramoyou
//
//  「上限つきで取得 → まとめて削除」を空になるまで繰り返す汎用ループ ⭐️
//
//  なぜ独立した型に切り出すか:
//    Firestore Security Rules が list に件数上限を課しているコレクション
//    （follows は `request.query.limit <= 50`）は、`getDocuments()` を
//    上限なしで撃つと permission-denied になる。つまり「1 ページずつ取って消す」
//    ループが必須になるが、このループ自体は Firestore に依存しない純粋な制御構造で、
//    そこにこそ壊れやすい条件（終了判定・無限ループ）が集中している。
//    取得と削除をクロージャで受け取る形にして、単体テストで検証できるようにする。
//

import Foundation

/// ページ単位の「取得 → 削除」を繰り返すドレイン処理
enum BatchDrainer {
    /// ドレイン処理のエラー
    enum DrainError: Error, LocalizedError {
        /// 上限ページ数に達しても空にならなかった（削除が効いていない疑い）
        case exceededMaxPages(maxPages: Int)

        var errorDescription: String? {
            switch self {
            case let .exceededMaxPages(maxPages):
                return "削除処理が \(maxPages) ページを超えても終わりませんでした"
            }
        }
    }

    /// 取得と削除を繰り返して、対象が空になるまで消し切る。
    ///
    /// - Important: `fetch` は **毎回コレクションの先頭から取り直す** 想定
    ///   （カーソルを使わない）。削除しながら進むため、消した分だけ先頭が繰り上がり、
    ///   カーソルを持つより単純かつ安全になる。
    ///
    /// - Parameters:
    ///   - pageSize: 1 回あたりの取得件数。rules の list 上限を満たす値を渡すこと。
    ///   - maxPages: 保険としての最大反復回数。`delete` が無言で効かない（＝毎回同じ
    ///     ドキュメントが返る）場合に無限ループするのを防ぐ。超えたら例外を投げる。
    ///   - fetch: 先頭から最大 `pageSize` 件を取得するクロージャ。
    ///   - delete: 取得した 1 ページぶんを削除するクロージャ。
    static func drain<Item>(
        pageSize: Int,
        maxPages: Int = 200,
        fetch: (_ pageSize: Int) async throws -> [Item],
        delete: (_ items: [Item]) async throws -> Void
    ) async throws {
        // pageSize が 0 以下だと fetch が永久に空を返し続けるか、進捗ゼロで回り続ける。
        // 呼び出し側のミスを黙って飲み込まず、何もせず抜ける（削除対象なし扱い）。
        guard pageSize > 0 else { return }

        for _ in 0 ..< max(maxPages, 0) {
            let items = try await fetch(pageSize)

            // 空になったら完了。
            if items.isEmpty { return }

            try await delete(items)

            // 取得件数が上限未満 ＝ これが最後のページなので、
            // 空を確認するためだけの追加 1 回を撃たずに終える。
            if items.count < pageSize { return }
        }

        // ここに来るのは「毎回 pageSize 件ちょうど返り続けた」場合。
        // 正常な大量データでもありうるが、削除が効いていない可能性のほうが怖いので、
        // 黙って打ち切らずに例外にして呼び出し側へ知らせる。
        throw DrainError.exceededMaxPages(maxPages: maxPages)
    }
}
