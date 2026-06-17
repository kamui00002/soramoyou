//
//  AppGroup.swift
//  Soramoyou
//
//  本体アプリとホーム画面ウィジェット拡張（SoramoyouWidget）が共有する
//  App Group コンテナへの単一アクセス窓口。
//
//  ⚠️ なぜ定数を 1 箇所に集約するか:
//    App Group ID をリテラルで複数箇所に書くと、片方をタイプミスしても
//    コンパイルは通り、実行時に「本体は書けるがウィジェットは別コンテナを見て空表示」
//    という *無言の失敗* になる（最も発見しづらいバグ）。
//    そのため ID とパス計算をここに一元化し、本体・ウィジェット双方がこれだけを使う。
//
//  ⚠️ widget セーフ:
//    このファイルは Foundation のみに依存する（Firebase / OpenCV / UIKit に触れない）。
//    本体・ウィジェット拡張の両ターゲットに Target Membership で所属させる。
//

import Foundation

/// 本体とウィジェットで共有する App Group コンテナの定義とパス計算。
enum AppGroup {

    /// App Group 識別子。Xcode の Signing & Capabilities で両ターゲットに付与する文字列と
    /// **完全一致**していなければならない（不一致＝無言の空表示）。
    static let identifier = "group.com.yoshidometoru.Soramoyou"

    /// ウィジェットが参照するキャッシュ用ファイル/ディレクトリ名。
    enum Path {
        /// ローカル縮小画像（512px JPEG）を置くディレクトリ名。
        static let imagesDirectory = "WidgetImages"
        /// ウィジェットが読むインデックス（投稿メタの一覧）ファイル名。
        static let indexFile = "widget_index.json"
        /// 位置情報の dual-write 先（Mode C の太陽計算用）ファイル名。
        static let locationFile = "widget_location.json"
    }

    /// App Group 共有コンテナのルート URL。
    /// - Returns: entitlement が付与されていれば URL、未付与なら nil。
    ///   - 本体: App Group capability 付与後に有効。
    ///   - テスト: entitlement が無い環境では nil になるため、I/O 実装側は
    ///     コンテナ URL を **注入可能** にしておくこと（テストは temp ディレクトリで検証する）。
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// 縮小画像ディレクトリの URL（コンテナ未取得なら nil）。
    static var imagesDirectoryURL: URL? {
        containerURL?.appendingPathComponent(Path.imagesDirectory, isDirectory: true)
    }

    /// インデックスファイルの URL（コンテナ未取得なら nil）。
    static var indexFileURL: URL? {
        containerURL?.appendingPathComponent(Path.indexFile, isDirectory: false)
    }

    /// 位置情報ファイルの URL（コンテナ未取得なら nil）。
    static var locationFileURL: URL? {
        containerURL?.appendingPathComponent(Path.locationFile, isDirectory: false)
    }
}
