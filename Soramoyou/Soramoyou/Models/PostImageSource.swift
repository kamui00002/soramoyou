//
//  PostImageSource.swift
//  Soramoyou
//
//  投稿の画像を「URL で読むか・Storage のパスで読むか」を決める ⭐️（URL 側の C・C-1）
//
//  フォロワー限定・非公開の画像は、トークン付きの URL で読むと Storage のルールを通らない
//  （URL を知っている人なら誰でも、フォローを外した後でも見られる）。
//  そこで公開以外は、URL が残っていても Storage のパスで読む（毎回ルールが本人かフォロワーかを確かめる）。
//

import Foundation

/// 投稿の画像の読み方
enum PostImageSource: Equatable {
    /// 公開の画像：今までどおり URL で読む
    case remote(URL)
    /// 公開以外の画像：Storage のパスで読む
    case storage(String)
    /// 読めない（灰色の枠を出す）
    case unavailable

    /// 画像の読み方を決める
    ///
    /// 1. 使うパスを決める（サムネイルは thumbnailStoragePath → サムネイルの URL から取り出したパス、
    ///    手がかりが無ければ本体。本体は storagePath → URL から取り出したパス）
    /// 2. パスの区分（3 つ目）がちょうど public で、URL が読める → URL で読む
    /// 3. 区分の無い古い置き場（4 つに分かれていないパス）→ URL が読めれば URL、読めなければ読めない
    ///    （Storage のルールにこの形の読む行が無く、パスで読むと本人でも断られるため）
    /// 4. それ以外でパスがある → URL が残っていてもパスで読む（D-2 でトークンを消しても壊れないように）
    /// 5. パスが無い → URL が読めれば URL、読めなければ読めない
    ///
    /// 「URL が読める」は、URL が決まり（StorageImageURL）に合うこと。合わない URL からはパスも取り出さない。
    ///
    /// 判定をパスの区分で行うのは、Storage のルールもパスの区分で読める人を決めているため（storage.rules）。
    /// - Parameters:
    ///   - image: 投稿の画像の情報
    ///   - prefersThumbnail: サムネイルを読みたいか（一覧など）。false なら本体
    ///   - policy: 通す URL の決まり（既定は今の Firebase の接続情報から作ったもの）
    /// - Returns: 読み方
    static func resolve(
        _ image: ImageInfo,
        prefersThumbnail: Bool,
        policy: StorageImageURL.Policy? = StorageImageURL.live
    ) -> PostImageSource {
        // 本体のパスと URL
        var path = nonEmpty(image.storagePath) ?? pathInDownloadURL(image.url, policy: policy)
        var urlString: String? = image.url

        // サムネイルが欲しく、その手がかり（パスか URL）があるときだけサムネイルに替える。
        // 手がかりが何も無いときは本体に落とす（今の画面の「サムネイルが無ければ本体」と同じ）
        if prefersThumbnail {
            let thumbnailPath = nonEmpty(image.thumbnailStoragePath) ?? pathInDownloadURL(image.thumbnail, policy: policy)
            if thumbnailPath != nil || readableURL(image.thumbnail, policy: policy) != nil {
                path = thumbnailPath
                urlString = image.thumbnail
            }
        }

        if let path {
            if isPublicPath(path), let url = readableURL(urlString, policy: policy) {
                return .remote(url)
            }
            // 区分の無い古い置き場は、ルールに読む行が無い＝パスでは誰も読めない。URL だけが頼り
            if isLegacyPathWithoutSegment(path) {
                if let url = readableURL(urlString, policy: policy) {
                    return .remote(url)
                }
                return .unavailable
            }
            return .storage(path)
        }
        if let url = readableURL(urlString, policy: policy) {
            return .remote(url)
        }
        return .unavailable
    }

    // MARK: - Private

    /// パスの区分（`posts/{uid}/{区分}/…` の 3 つ目）がちょうど public か
    ///
    /// posts・thumbnails・originals とも 3 つ目が区分。大文字・似た名前は公開扱いにしない（安全な側に倒す）。
    private static func isPublicPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts[2] == "public"
    }

    /// 区分の無い古い置き場のパスか（`posts/{uid}/{名前}`・`thumbnails/{uid}/{名前}`）
    ///
    /// 2026-01-16 より前の投稿はこの形で置いていた。Storage のルールの投稿の写真の行は、どれも
    /// `{置き場}/{uid}/{区分}/{名前}` の 4 つに分かれた形なので、4 つに満たないパスには読む行が無い。
    /// 4 つに分かれていて区分が見慣れないもの（大文字の Public など）はここに入れない（今までどおりパスで読む＝安全な側）。
    private static func isLegacyPathWithoutSegment(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: false).count < 4
    }

    /// Storage のダウンロード URL の文字列から、Storage のパスを取り出す（決まりに合わない・取り出せなければ nil）
    private static func pathInDownloadURL(_ string: String?, policy: StorageImageURL.Policy?) -> String? {
        guard let url = readableURL(string, policy: policy) else { return nil }
        return nonEmpty(StorageService.storagePathFromDownloadURL(url))
    }

    /// 決まり（StorageImageURL）に合う Storage の画像の URL だけを URL にする
    private static func readableURL(_ string: String?, policy: StorageImageURL.Policy?) -> URL? {
        StorageImageURL.url(from: string, policy: policy)
    }

    /// 空の文字列は「無い」と同じに扱う
    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.isEmpty else { return nil }
        return string
    }
}
