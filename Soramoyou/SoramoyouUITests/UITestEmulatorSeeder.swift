//
//  UITestEmulatorSeeder.swift
//  SoramoyouUITests
//
//  UI テストの前に、Firebase Emulator を空にして、決まったアカウントと投稿を置く ⭐️☁️
//
//  - 接続先はアプリ側（Soramoyou/Services/FirebaseEmulatorSwitch.swift）と同じ値にしている。
//    ずれると、アプリが見ない場所に置いてしまい、テストが空の画面を見ることになる
//  - 宛先は 127.0.0.1 の Emulator だけ。プロジェクト名は demo- で始まる（Emulator 専用の名前）ので、本番には届かない。
//    送る前に毎回 checkDestination で宛先を確かめ、外れていたら何も送らずにテストを止める
//  - 書き込みは Emulator の管理者の口（Authorization: Bearer owner）で行い、rules を通さない。
//    下ごしらえの失敗と、アプリの操作が rules に断られる失敗を混ぜないため。
//    例外は Storage の写真（seedDeletionTargets）で、本人のログインの印を付けて rules を通して置く
//  - テストの順番に左右されないよう、テストのたびに全部消してから置き直す
//    （ブロックのテストはブロックを実際に行うので、残すと次のテストのホームから投稿が消える）
//

import Foundation
import UIKit

/// UI テスト用の Emulator の下ごしらえ
enum UITestEmulatorSeeder {
    // MARK: - 接続先（FirebaseEmulatorSwitch と同じ値）

    /// Emulator のプロジェクト名（FirebaseEmulatorSwitch.projectID と同じ）
    static let projectID = "demo-soramoyou-security"
    /// Emulator のホスト（FirebaseEmulatorSwitch.host と同じ）
    static let host = "127.0.0.1"
    /// Auth Emulator のポート（FirebaseEmulatorSwitch.authPort と同じ）
    static let authPort = 9099
    /// Firestore Emulator のポート（FirebaseEmulatorSwitch.firestorePort と同じ）
    static let firestorePort = 8080
    /// Storage Emulator のポート（FirebaseEmulatorSwitch.storagePort と同じ）。画像の URL の形を作るのに使う
    static let storagePort = 9199
    /// アプリが Emulator のときに使うバケット（FirebaseEmulatorSwitch.swift の storageBucket と同じ）
    static let bucket = "\(projectID).appspot.com"
    /// Auth Emulator は API キーの中身を確かめないので、形だけの値でよい（アプリ側の偽のキーと同じ値）
    static let apiKey = "AdemoSoramoyouSecurityFakeKey0000000000"

    // MARK: - 置くもの

    /// テストで使うアカウント
    struct Account {
        let email: String
        let password: String
        let displayName: String
    }

    /// ログインして操作する人（通報・ブロック・プロフィール）
    static let tester = Account(email: "test@example.com", password: "test1234", displayName: "テストそら")
    /// 退会する人（確認画面でやめるテストと、退会を本当に実行するテストで使う）
    static let deleteTester = Account(email: "delete_test@example.com", password: "test1234", displayName: "たいかいテスト")
    /// ブロックされる側の投稿者。ホームの先頭にこの人の投稿が並ぶ
    static let posterA = Account(email: "poster-a@example.com", password: "test1234", displayName: "くものひと")
    /// ブロックしない側の投稿者。ブロックの後も、この人の投稿は残ることを確かめる
    static let posterB = Account(email: "poster-b@example.com", password: "test1234", displayName: "にじのひと")

    /// 投稿者 A の投稿のキャプション（新しい順）。ホームの先頭はこの 1 つ目
    static let captionsA = ["UIテストの空A1", "UIテストの空A2"]
    /// 投稿者 B の投稿のキャプション（A より古い）
    static let captionsB = ["UIテストの空B1"]

    /// 置いた人の uid（通報の確かめで使う）
    struct Seeded {
        let testerUid: String
        let deleteTesterUid: String
        let posterAUid: String
        let posterBUid: String
    }

    // MARK: - 入口

    /// Emulator（Storage・Firestore・Auth）を空にして、アカウント 4 つ・ユーザー文書・他の人の公開投稿 3 件を置く
    /// - Returns: 置いた人の uid
    /// - Throws: Emulator に届かない・断られたとき（`SeederError`。メッセージに宛先と状態を入れる）
    static func resetAndSeed() throws -> Seeded {
        try reset()

        let seeded = try Seeded(
            testerUid: createAccount(tester),
            deleteTesterUid: createAccount(deleteTester),
            posterAUid: createAccount(posterA),
            posterBUid: createAccount(posterB)
        )

        // ユーザー文書（本人だけが読める users）と公開プロフィール（投稿者の名前の表示に使う publicProfiles）
        let people: [(String, Account)] = [
            (seeded.testerUid, tester),
            (seeded.deleteTesterUid, deleteTester),
            (seeded.posterAUid, posterA),
            (seeded.posterBUid, posterB),
        ]
        for (uid, account) in people {
            try putUser(uid: uid, account: account)
        }

        // 投稿：A の 2 件が新しく、B の 1 件が古い（ホームの「すべて」は新しい順）
        let now = Date()
        try putPost(id: "uitest-a1", ownerUid: seeded.posterAUid, caption: captionsA[0], createdAt: now.addingTimeInterval(-60))
        try putPost(id: "uitest-a2", ownerUid: seeded.posterAUid, caption: captionsA[1], createdAt: now.addingTimeInterval(-120))
        try putPost(id: "uitest-b1", ownerUid: seeded.posterBUid, caption: captionsB[0], createdAt: now.addingTimeInterval(-180))

        return seeded
    }

    /// 通報した人が [reporterId] の通報の数を数える
    ///
    /// 通報はアプリからは読めない（firestore.rules の reports は read: false）ので、管理者の口で読む。
    /// - Parameter reporterId: 通報した人の uid
    /// - Returns: その人の通報の数
    static func reportCount(reporterId: String) throws -> Int {
        let data = try send("GET", "\(firestoreDocumentsBase)/reports?pageSize=300", asOwner: true)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // 1 件も無いときは documents の欄そのものが無い
        let documents = object?["documents"] as? [[String: Any]] ?? []
        return documents.filter { document in
            let fields = document["fields"] as? [String: Any]
            let reporter = fields?["reporterId"] as? [String: Any]
            return reporter?["stringValue"] as? String == reporterId
        }.count
    }

    // MARK: - 退会を本当に実行するテスト用

    /// 退会で消えるはずのもの（Storage の 4 つのファイルと、投稿の文書）
    struct DeletionTargets {
        /// 投稿の文書の ID
        let postId: String
        /// 投稿の写真の置き場所
        let photoPath: String
        /// 投稿のサムネイルの置き場所
        let thumbnailPath: String
        /// 投稿の元画像（編集する前の写真）の置き場所
        let originalPath: String
        /// アイコン画像の置き場所
        let iconPath: String

        /// Storage の 4 つの置き場所
        var storagePaths: [String] { [photoPath, thumbnailPath, originalPath, iconPath] }
    }

    /// 退会する人の Storage に写真・サムネイル・元画像・アイコンを置き、その写真を指す投稿を 1 件置く
    ///
    /// `resetAndSeed()` には入れない。ここで置く投稿はホームに並ぶので、ほかのテストの画面を変えないよう、
    /// 退会を本当に実行するテストだけが呼ぶ。
    /// Storage へは管理者の口でなく、本人のログインの印（ID トークン）を付けて rules を通して置く
    /// （アプリが写真を置くときと同じ立場。形は functions/postsFollowersStorage.emulator.test.js の upload と同じ）。
    /// - Parameter uid: 退会する人（`deleteTester`）の uid
    /// - Returns: 置いたものの置き場所
    static func seedDeletionTargets(uid: String) throws -> DeletionTargets {
        let postId = "uitest-delete-1"
        let targets = DeletionTargets(
            postId: postId,
            // 置き場所の形はアプリと同じ（AccountStoragePaths：posts・thumbnails は {uid}/{公開範囲}/{名前}、アイコンは決まった名前）
            photoPath: "posts/\(uid)/public/\(postId).jpg",
            thumbnailPath: "thumbnails/\(uid)/public/\(postId)_thumb.jpg",
            // 元画像の形は PostViewModel.swift の「originals/{userId}/{公開範囲}/{imageId}.jpg」と同じ
            originalPath: "originals/\(uid)/public/\(postId).jpg",
            iconPath: "users/\(uid)/profile/profile.jpg"
        )

        let token = try signIn(deleteTester)
        let jpeg = smallJPEG()
        for path in targets.storagePaths {
            try uploadImage(jpeg, to: path, idToken: token)
        }

        // 投稿の文書には、置き場所（storagePath・thumbnailStoragePath）と URL の両方を書く。
        // 退会の処理（AccountStoragePaths.postImagePaths）は置き場所を先に読む
        let image: [String: Any] = [
            "mapValue": [
                "fields": [
                    "url": string(downloadURL(targets.photoPath)),
                    "thumbnail": string(downloadURL(targets.thumbnailPath)),
                    "storagePath": string(targets.photoPath),
                    "thumbnailStoragePath": string(targets.thumbnailPath),
                    "width": integer(8),
                    "height": integer(8),
                    "order": integer(0),
                ],
            ],
        ]
        // 元画像は originalImages の欄に書く（形は images と同じ ImageInfo。サムネイルは持たない）
        let originalImage: [String: Any] = [
            "mapValue": [
                "fields": [
                    "url": string(downloadURL(targets.originalPath)),
                    "storagePath": string(targets.originalPath),
                    "width": integer(8),
                    "height": integer(8),
                    "order": integer(0),
                ],
            ],
        ]
        // ほかの人の投稿より古くして、ホームの先頭を変えない
        let stamp = timestamp(Date().addingTimeInterval(-240))
        try putDocument("posts/\(postId)", fields: [
            "postId": string(postId),
            "userId": string(uid),
            "images": ["arrayValue": ["values": [image]]],
            "originalImages": ["arrayValue": ["values": [originalImage]]],
            "caption": string("UIテストの空 退会する人"),
            "visibility": string("public"),
            "likesCount": integer(0),
            "commentsCount": integer(0),
            "createdAt": stamp,
            "updatedAt": stamp,
        ])
        return targets
    }

    /// Storage に [path] のファイルがあるか（管理者の口でメタデータを読む。読むだけ）
    /// - Returns: あれば true（状態 200）、無ければ false（状態 404）
    /// - Throws: 200 でも 404 でもないとき（「無い」と「読めなかった」を混ぜない）
    static func storageObjectExists(_ path: String) throws -> Bool {
        try exists("\(storageObjectsBase)/\(percentEncoded(path))")
    }

    /// Firestore に [path]（例: `users/abc`）の文書があるか（管理者の口で読む。読むだけ）
    /// - Returns: あれば true（状態 200）、無ければ false（状態 404）
    /// - Throws: 200 でも 404 でもないとき
    static func documentExists(_ path: String) throws -> Bool {
        try exists("\(firestoreDocumentsBase)/\(path)")
    }

    /// 管理者の口で GET して、あるか無いかを返す
    private static func exists(_ urlString: String) throws -> Bool {
        let response = try perform("GET", urlString, headers: ["Authorization": "Bearer owner"])
        switch response.status {
        case 200: return true
        case 404: return false
        default: throw SeederError.rejected("GET \(urlString)：状態 \(response.status)")
        }
    }

    /// メールとパスワードでログインして、本人の印（ID トークン）を受け取る
    private static func signIn(_ account: Account) throws -> String {
        let data = try send(
            "POST",
            "http://\(host):\(authPort)/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=\(apiKey)",
            json: ["email": account.email, "password": account.password, "returnSecureToken": true]
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = object?["idToken"] as? String, !token.isEmpty else {
            throw SeederError.unexpected("ID トークンが返ってこない: \(account.email)")
        }
        return token
    }

    /// 本人として、Storage の [path] に画像を 1 枚置く（multipart の 1 回の要求。rules を通る）
    private static func uploadImage(_ jpeg: Data, to path: String, idToken: String) throws {
        let boundary = "uitest-seeder-boundary"
        let meta = try JSONSerialization.data(withJSONObject: ["name": path, "contentType": "image/jpeg"])
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=utf-8\r\n\r\n".utf8))
        body.append(meta)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let urlString = "\(storageObjectsBase)?name=\(percentEncoded(path))"
        let response = try perform("POST", urlString, body: body, headers: [
            "Authorization": "Firebase \(idToken)",
            "x-goog-upload-protocol": "multipart",
            "Content-Type": "multipart/related; boundary=\(boundary)",
        ])
        guard response.status == 200 else {
            let text = String(data: response.data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw SeederError.rejected("POST \(urlString)：状態 \(response.status)・\(text)")
        }
    }

    /// 8×8 の空色の JPEG（アプリが写真として開ける、本物の画像）
    private static func smallJPEG() -> Data {
        let size = CGSize(width: 8, height: 8)
        return UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// アプリが Emulator のときに通す画像の URL の形（StorageImageURL の決まり）
    private static func downloadURL(_ path: String) -> String {
        "http://\(host):\(storagePort)/v0/b/\(bucket)/o/\(percentEncoded(path))?alt=media"
    }

    /// 置き場所を URL の 1 区切りに入れる形にする（`/` も `%2F` にする）
    private static func percentEncoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path
    }

    // MARK: - 下ごしらえの部品

    /// Firestore の文書の置き場の先頭（REST）
    private static var firestoreDocumentsBase: String {
        "http://\(host):\(firestorePort)/v1/projects/\(projectID)/databases/(default)/documents"
    }

    /// Storage のファイル・Firestore の文書・アカウントを全部消す
    private static func reset() throws {
        let targets = [
            "http://\(host):\(firestorePort)/emulator/v1/projects/\(projectID)/databases/(default)/documents",
            "http://\(host):\(authPort)/emulator/v1/projects/\(projectID)/accounts",
        ]
        // 消す前に、宛先を全部確かめる（一部だけ消して、残りで止まる、を避ける）
        for target in targets + [storageObjectsBase] {
            try checkDestination(target)
        }
        // Storage を先に空にする（失敗した走りで残った写真が、次の走りにたまらないように）
        try clearStorage()
        for target in targets {
            try send("DELETE", target)
        }
    }

    /// Storage の置き場の先頭（REST）。バケットは demo- で始まる Emulator 用のものだけ
    private static var storageObjectsBase: String {
        "http://\(host):\(storagePort)/v0/b/\(bucket)/o"
    }

    /// Emulator の Storage のファイルを全部消す
    ///
    /// Storage には Firestore や Auth のような「全部消す口」が無いので、一覧して 1 つずつ消す。
    /// 持ち主のアカウントはもう無いことがある（退会の後・前の走りの残り）ので、管理者の口で消す。
    /// 宛先は 1 回ごとに `perform` の中の門（checkDestination）を通る。
    private static func clearStorage() throws {
        // 1 回の一覧は 1000 件まで。消してから読み直すので、続きの印（pageToken）は使わない
        for _ in 0 ..< 20 {
            let data = try send("GET", "\(storageObjectsBase)?maxResults=1000", asOwner: true)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            // 1 件も無いときは items が空か、欄そのものが無い
            let names = (object?["items"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if names.isEmpty { return }
            for name in names {
                try send("DELETE", "\(storageObjectsBase)/\(percentEncoded(name))", asOwner: true)
            }
        }
        throw SeederError.unexpected("Storage を 20 回消しても空にならない")
    }

    /// 宛先が「この Mac の中の Emulator（127.0.0.1）・demo- で始まるプロジェクト」かを確かめる
    ///
    /// 1 つでも外れたら、何も送らずに止める。定数を書き換えたり、宛先の組み立てを変えたりしたときに、
    /// 本番や別の場所のデータを消さないための門。文字列の先頭でなく、URL を分解した部品で見る
    /// （先頭だけだと `127.0.0.10` や `127.0.0.1.example.com` が通ってしまう）。
    /// - Parameter urlString: これから送る宛先
    /// - Returns: 確かめた宛先
    /// - Throws: `SeederError.forbiddenDestination`
    @discardableResult
    private static func checkDestination(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else { throw SeederError.unexpected("宛先を URL にできない: \(urlString)") }
        // demo- で始まる名前は Emulator 専用で、本番のプロジェクトには付けられない
        guard projectID.hasPrefix("demo-") else {
            throw SeederError.forbiddenDestination("プロジェクト名が demo- で始まらない（\(projectID)）: \(urlString)")
        }
        guard url.scheme == "http", url.host == "127.0.0.1", host == "127.0.0.1" else {
            throw SeederError.forbiddenDestination("宛先が http の 127.0.0.1 でない: \(urlString)")
        }
        guard let port = url.port, port == authPort || port == firestorePort || port == storagePort else {
            throw SeederError.forbiddenDestination("ポートが Emulator の auth・firestore・storage でない: \(urlString)")
        }
        // プロジェクト名を含む道（Firestore の全部と、消す口）は、その名前も demo- で始まること。
        // アカウントの道（identitytoolkit…/accounts:signUp・signInWithPassword）にはプロジェクト名が入らない
        let path = url.path
        if path.contains("/projects/"), !path.contains("/projects/demo-") {
            throw SeederError.forbiddenDestination("道の中のプロジェクト名が demo- で始まらない: \(urlString)")
        }
        // Storage の道（/v0/b/<バケット>/o…）は、バケットの名前も demo- で始まること
        if port == storagePort, !path.hasPrefix("/v0/b/demo-") {
            throw SeederError.forbiddenDestination("Storage のバケットの名前が demo- で始まらない: \(urlString)")
        }
        return url
    }

    /// Auth Emulator にメールとパスワードのアカウントを作り、uid を返す
    private static func createAccount(_ account: Account) throws -> String {
        let data = try send(
            "POST",
            "http://\(host):\(authPort)/identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(apiKey)",
            json: ["email": account.email, "password": account.password, "returnSecureToken": true]
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let uid = object?["localId"] as? String, !uid.isEmpty else {
            throw SeederError.unexpected("アカウントの uid が返ってこない: \(account.email)")
        }
        return uid
    }

    /// users と publicProfiles に、その人の文書を置く（User・PublicProfile のデコードは id が必須）
    private static func putUser(uid: String, account: Account) throws {
        let stamp = timestamp(Date())
        try putDocument("users/\(uid)", fields: [
            "id": string(uid),
            "email": string(account.email),
            "displayName": string(account.displayName),
            "createdAt": stamp,
            "updatedAt": stamp,
        ])
        try putDocument("publicProfiles/\(uid)", fields: [
            "id": string(uid),
            "displayName": string(account.displayName),
        ])
    }

    /// 公開の投稿を 1 件置く（Post のデコードは postId・userId・images が必須。画像は url・width・height・order が必須）
    ///
    /// 画像の URL は、アプリが Emulator のときに通す形（StorageImageURL の決まり：http・127.0.0.1・9199・
    /// `/v0/b/<バケット>/o/<名前>`）にする。Storage に中身は置かないので、画面では写真の代わりの表示になる。
    private static func putPost(id: String, ownerUid: String, caption: String, createdAt: Date) throws {
        let imageURL = "http://\(host):\(storagePort)/v0/b/\(bucket)/o/posts%2F\(ownerUid)%2Fpublic%2F\(id).jpg?alt=media"
        let image: [String: Any] = [
            "mapValue": [
                "fields": [
                    "url": string(imageURL),
                    "thumbnail": string(imageURL),
                    "width": integer(1080),
                    "height": integer(1440),
                    "order": integer(0),
                ],
            ],
        ]
        let stamp = timestamp(createdAt)
        try putDocument("posts/\(id)", fields: [
            "postId": string(id),
            "userId": string(ownerUid),
            "images": ["arrayValue": ["values": [image]]],
            "caption": string(caption),
            "visibility": string("public"),
            "likesCount": integer(0),
            "commentsCount": integer(0),
            "createdAt": stamp,
            "updatedAt": stamp,
        ])
    }

    /// [path] の文書を [fields] で丸ごと置く（無ければ作る）
    private static func putDocument(_ path: String, fields: [String: Any]) throws {
        try send("PATCH", "\(firestoreDocumentsBase)/\(path)", json: ["fields": fields], asOwner: true)
    }

    // MARK: - Firestore の REST の値の形

    private static func string(_ value: String) -> [String: Any] { ["stringValue": value] }

    /// REST では整数は文字列で送る（例: `{"integerValue":"0"}`）
    private static func integer(_ value: Int) -> [String: Any] { ["integerValue": String(value)] }

    private static func timestamp(_ date: Date) -> [String: Any] {
        ["timestampValue": ISO8601DateFormatter().string(from: date)]
    }

    // MARK: - 通信

    /// 返事を受け取る箱（通信の完了の処理は別のスレッドで動くので、値はこの箱に入れて受け渡す）
    private final class ResponseBox: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }

    /// 1 回の HTTP の要求を送り、返事を待つ（setUp は同期なので、ここで待つ）
    /// - Parameters:
    ///   - method: GET・POST・PATCH・DELETE
    ///   - urlString: 宛先
    ///   - json: 送る JSON（無ければ本文なし）
    ///   - asOwner: Emulator の管理者として送るか（rules を通さない）
    /// - Returns: 返事の本文
    @discardableResult
    private static func send(_ method: String, _ urlString: String, json: [String: Any]? = nil, asOwner: Bool = false) throws -> Data {
        var headers: [String: String] = [:]
        if asOwner {
            headers["Authorization"] = "Bearer owner"
        }
        var body: Data?
        if let json {
            body = try JSONSerialization.data(withJSONObject: json)
            headers["Content-Type"] = "application/json"
        }
        let response = try perform(method, urlString, body: body, headers: headers)
        guard (200 ..< 300).contains(response.status) else {
            let text = String(data: response.data, encoding: .utf8).map { String($0.prefix(300)) } ?? ""
            throw SeederError.rejected("\(method) \(urlString)：状態 \(response.status)・\(text)")
        }
        return response.data
    }

    /// 1 回の HTTP の要求を送り、返事の状態と本文をそのまま返す（状態の良し悪しは呼ぶ側が決める）
    /// - Throws: 宛先が Emulator でない（何も送らない）・届かない・状態が読めないとき
    private static func perform(
        _ method: String,
        _ urlString: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) throws -> (status: Int, data: Data) {
        // 通信はここからしか出ない。送る前に必ず宛先を確かめる（外れたら何も送らない）
        let url = try checkDestination(urlString)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode
            box.error = error
            done.signal()
        }.resume()

        // 返事が無いまま止まらないよう、上限を付けて待つ
        if done.wait(timeout: .now() + 15) == .timedOut {
            throw SeederError.unreachable("\(method) \(urlString)：15 秒たっても返事が無い")
        }
        if let error = box.error {
            throw SeederError.unreachable("\(method) \(urlString)：\(error.localizedDescription)")
        }
        guard let status = box.status else {
            throw SeederError.unexpected("\(method) \(urlString)：返事に状態が無い")
        }
        return (status, box.data ?? Data())
    }

    /// 下ごしらえの失敗
    enum SeederError: LocalizedError {
        /// Emulator に届かない（起きていない・ポートが違う）
        case unreachable(String)
        /// Emulator が断った
        case rejected(String)
        /// 返事の形が思っていたものと違う
        case unexpected(String)
        /// 宛先が「127.0.0.1 の Emulator・demo- のプロジェクト」でないので、何も送らずに止めた
        case forbiddenDestination(String)

        var errorDescription: String? {
            switch self {
            case let .forbiddenDestination(detail):
                "宛先が Emulator でないので、何も送らずに止めた：\(detail)"
            case let .unreachable(detail):
                "Emulator に届かない（auth \(UITestEmulatorSeeder.authPort)・firestore \(UITestEmulatorSeeder.firestorePort)・storage \(UITestEmulatorSeeder.storagePort) が \(UITestEmulatorSeeder.projectID) で起きているか確かめる）：\(detail)"
            case let .rejected(detail):
                "Emulator が断った：\(detail)"
            case let .unexpected(detail):
                "Emulator の返事が思っていた形でない：\(detail)"
            }
        }
    }
}
