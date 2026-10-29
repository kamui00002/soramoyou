//
//  StorageImageURL.swift
//  Soramoyou
//
//  Firebase Storage の画像の URL を 1 か所で確かめる ⭐️
//
//  通すのは、決まり（Policy）の scheme・ホスト・ポート・バケットに合い、
//  パスがちょうど `/v0/b/<バケット>/o/<名前>` の URL だけ。
//  決まりは今の Firebase の接続情報から作る（本番は https・firebasestorage.googleapis.com・ポート無しか 443、
//  テストの Emulator は http・127.0.0.1:9199）。接続情報が取れなければ何も通さない。
//

import FirebaseCore
import Foundation

enum StorageImageURL {
    /// 通す URL の決まり
    struct Policy: Equatable {
        /// scheme（完全一致）
        let scheme: String
        /// ホスト（完全一致）
        let host: String
        /// 通すポート（nil は「ポートの書かれていない URL」を通す）
        let ports: Set<Int?>
        /// バケット（`/v0/b/<バケット>/o/` の部分・完全一致）
        let bucket: String
    }

    /// 本番の Storage のホスト
    static let productionHost = "firebasestorage.googleapis.com"

    /// 今の Firebase の接続情報から作った決まり（接続情報が取れなければ nil＝何も通さない）
    static var live: Policy? {
        policy(from: FirebaseApp.app()?.options)
    }

    /// Firebase の接続情報から決まりを作る
    ///
    /// - バケットは接続情報の storageBucket の 1 つだけ
    /// - Debug で接続先が Emulator（`FirebaseEmulatorSwitch.projectID`）なら、http・127.0.0.1・Storage のポート
    /// - それ以外は https・firebasestorage.googleapis.com・ポート無しか 443
    /// - Parameter options: Firebase の接続情報
    /// - Returns: 決まり。接続情報か storageBucket が無ければ nil
    static func policy(from options: FirebaseOptions?) -> Policy? {
        guard let options, let bucket = options.storageBucket, !bucket.isEmpty else { return nil }
        #if DEBUG
            // テストの Emulator の接続情報（FirebaseEmulatorSwitch が差し替えたもの）
            if options.projectID == FirebaseEmulatorSwitch.projectID {
                return Policy(
                    scheme: "http",
                    host: FirebaseEmulatorSwitch.host,
                    ports: [FirebaseEmulatorSwitch.storagePort],
                    bucket: bucket
                )
            }
        #endif
        return Policy(scheme: "https", host: productionHost, ports: [nil, 443], bucket: bucket)
    }

    /// 決まりに合う Storage の画像の URL だけを URL にする
    ///
    /// 1. 空でなく、`URL(string:)` で URL にできる
    /// 2. scheme・ホストが決まりと完全一致（ホストは % のまま比べる）
    /// 3. ポートが決まりの中にある（書かれていなければ nil として比べる）
    /// 4. 利用者名・パスワードが付いていない
    /// 5. パス（% のまま）がちょうど `/v0/b/<バケット>/o/<名前>`。名前は空でなく、/ を含まない（%2F は可）
    ///
    /// 返すのは `URL(string:)` と同じ値（文字列を作り直さない）
    /// - Parameters:
    ///   - string: Firestore から読んだ URL の文字列
    ///   - policy: 決まり。nil なら何も通さない
    /// - Returns: 通せば URL、通さなければ nil
    static func url(from string: String?, policy: Policy?) -> URL? {
        guard let policy, let string, !string.isEmpty, let url = URL(string: string) else { return nil }

        // scheme・ホスト・ポート・利用者名とパスワード
        guard url.scheme == policy.scheme,
              url.host(percentEncoded: true) == policy.host,
              policy.ports.contains(url.port),
              url.user(percentEncoded: true) == nil,
              url.password(percentEncoded: true) == nil
        else { return nil }

        // パスを / で分けると ["", "v0", "b", <バケット>, "o", <名前>] のちょうど 6 つ
        let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts[0].isEmpty,
              parts[1] == "v0",
              parts[2] == "b",
              parts[3] == policy.bucket,
              parts[4] == "o",
              !parts[5].isEmpty
        else { return nil }

        return url
    }

    /// 今の Firebase の接続情報から作った決まり（`live`）に合う Storage の画像の URL だけを URL にする
    ///
    /// 読み方（PostImageSource）を通さない画像（アイコンなど）の URL を読む直前に使う。
    /// - Parameter string: Firestore から読んだ URL の文字列
    /// - Returns: 通せば URL、通さなければ nil
    static func url(from string: String?) -> URL? {
        url(from: string, policy: live)
    }
}
