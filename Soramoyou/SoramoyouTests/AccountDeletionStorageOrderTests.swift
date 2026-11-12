//
//  AccountDeletionStorageOrderTests.swift
//  SoramoyouTests
//
//  退会の Storage の 3 段（投稿の写真 → アイコン画像 → 残り物）が、
//  Firestore の posts と users の削除より前に、この順で呼ばれるかのテスト ⭐️
//
//  - Emulator（Auth 9099・Firestore 8080）が要る。動いていなければ失敗する（FirestoreServiceTests と同じ扱い）
//  - アプリ本体のログインの見張りを動かさないよう、別の名前の FirebaseApp でログインする
//  - 種まきと「文書がまだあるか」の確かめは、Emulator の REST に管理者（Bearer owner）として送る。
//    rules を通さないので、posts の read rule が「文書が無いと拒否」になる件に引っかからない
//

#if DEBUG
    import FirebaseAuth
    import FirebaseCore
    import FirebaseFirestore
    @testable import Soramoyou
    import XCTest

    final class AccountDeletionStorageOrderTests: XCTestCase {
        /// このテストだけで使う FirebaseApp の名前
        private static let appName = "account-deletion-storage-order"

        func testStorageStagesRunBeforePostsAndUsersAreDeleted() async throws {
            // 本番に届かないよう、Emulator を向いていることを先に確かめる
            guard FirebaseEmulatorSwitch.isActive else {
                return XCTFail("Firebase が Emulator を向いていません。本番に触らないよう止めます")
            }
            let app = try Self.emulatorApp()
            let auth = Auth.auth(app: app)

            // 1. 退会する人を作ってログインする（作った人は終わったら消す）
            //    合言葉は Emulator の中だけで使う使い捨て。その場で作り、ソースには書かない
            let email = "withdraw-order-\(UUID().uuidString.prefix(8).lowercased())@example.com"
            let uid = try await auth.createUser(withEmail: email, password: UUID().uuidString).user.uid
            addTeardownBlock {
                guard let app = FirebaseApp.app(name: Self.appName) else { return }
                try? await Auth.auth(app: app).currentUser?.delete()
                try? Auth.auth(app: app).signOut()
            }

            // 2. users の文書と、写真が 3 つ（本体・サムネイル・元画像）書かれた投稿を 1 つ置く
            let postId = "withdraw-order-\(UUID().uuidString.lowercased())"
            let photoPath = "posts/\(uid)/public/p1.jpg"
            let thumbnailPath = "thumbnails/\(uid)/public/p1_thumb.jpg"
            let originalPath = "originals/\(uid)/public/o1.jpg"
            let iconPath = AccountStoragePaths.profileIcon(userId: uid)
            let userDocument = "users/\(uid)"
            let postDocument = "posts/\(postId)"

            let image: [String: Any] = [
                "url": "", "width": 1, "height": 1, "order": 0,
                "storagePath": photoPath,
                "thumbnailStoragePath": thumbnailPath,
            ]
            let original: [String: Any] = [
                "url": "", "width": 1, "height": 1, "order": 0,
                "storagePath": originalPath,
            ]
            let post: [String: Any] = [
                "userId": uid,
                "visibility": "public",
                "images": [image],
                "originalImages": [original],
            ]
            try await EmulatorFirestoreREST.put(userDocument, fields: ["displayName": "退会の順番のテスト"])
            try await EmulatorFirestoreREST.put(postDocument, fields: post)
            // 種まきが効いていることを先に確かめる（ここが偽だと、下の「まだある」が全部偽になる）
            let seededPost = try await EmulatorFirestoreREST.exists(postDocument)
            let seededUser = try await EmulatorFirestoreREST.exists(userDocument)
            XCTAssertTrue(seededPost)
            XCTAssertTrue(seededUser)

            // 3. 偽の Storage をつないで退会の削除を流す
            let storage = OrderRecordingStorageClient(postDocument: postDocument, userDocument: userDocument)
            let service = FirestoreService(
                db: Firestore.firestore(app: app),
                accountStorageCleaner: AccountStorageCleaner(client: storage)
            )
            try await service.deleteUserData(userId: uid)

            // 4. 3 段がそれぞれ呼ばれたこと（0 回だと下の確かめが素通りするので、回数から見る）
            let events = storage.events
            let photoEvents = events.filter(\.isPostPhoto)
            let iconEvents = events.filter { $0.kind == .delete && $0.target == iconPath }
            let listEvents = events.filter { $0.kind == .list }
            XCTAssertEqual(Set(photoEvents.map(\.target)), [photoPath, thumbnailPath, originalPath])
            XCTAssertEqual(photoEvents.count, 3)
            XCTAssertEqual(iconEvents.count, 1)
            XCTAssertEqual(listEvents.map(\.target), AccountStoragePaths.leftoverFolders(userId: uid))

            // 5. 投稿の写真は posts の文書を消す前、アイコン画像と残り物は users の文書を消す前
            XCTAssertTrue(photoEvents.allSatisfy(\.postExisted), "投稿の写真は posts の文書を消す前に消す: \(photoEvents)")
            XCTAssertTrue(
                (iconEvents + listEvents).allSatisfy(\.userExisted),
                "アイコン画像と残り物は users の文書を消す前に消す: \(iconEvents + listEvents)"
            )

            // 6. 3 段の中の順番：写真 → アイコン画像 → 残り物
            let lastPhoto = try XCTUnwrap(events.lastIndex(where: \.isPostPhoto))
            let icon = try XCTUnwrap(events.firstIndex { $0.kind == .delete && $0.target == iconPath })
            let firstList = try XCTUnwrap(events.firstIndex { $0.kind == .list })
            XCTAssertLessThan(lastPhoto, icon)
            XCTAssertLessThan(icon, firstList)

            // 7. 終わったら posts と users の文書は消えている
            let postLeft = try await EmulatorFirestoreREST.exists(postDocument)
            let userLeft = try await EmulatorFirestoreREST.exists(userDocument)
            XCTAssertFalse(postLeft)
            XCTAssertFalse(userLeft)
        }

        // MARK: - Helpers

        /// Emulator を向いた、このテスト専用の FirebaseApp を返す（1 回目だけ作る）
        /// - Firestore は使い始めた後に宛先を変えるとクラッシュするので、作ったものを使い回す
        private static func emulatorApp() throws -> FirebaseApp {
            if let app = FirebaseApp.app(name: appName) {
                return app
            }
            // アプリの設定の写しを使う。写しも書き換えできない（SDK 12.6.0 の FIROptions は copy で
            // editingLocked を引き継ぎ、代入すると例外で落ちる）ので、Emulator の ID かを確かめるだけにする
            guard let options = FirebaseApp.app()?.options.copy() as? FirebaseOptions else {
                throw EmulatorFirestoreREST.RESTError.missingDefaultApp
            }
            guard options.projectID == FirebaseEmulatorSwitch.projectID else {
                throw EmulatorFirestoreREST.RESTError.notEmulatorProject
            }
            FirebaseApp.configure(name: appName, options: options)
            guard let app = FirebaseApp.app(name: appName) else {
                throw EmulatorFirestoreREST.RESTError.missingDefaultApp
            }

            Auth.auth(app: app).useEmulator(
                withHost: FirebaseEmulatorSwitch.host,
                port: FirebaseEmulatorSwitch.authPort
            )
            let settings = FirestoreSettings()
            settings.host = "\(FirebaseEmulatorSwitch.host):\(FirebaseEmulatorSwitch.firestorePort)"
            settings.isSSLEnabled = false
            settings.cacheSettings = MemoryCacheSettings()
            Firestore.firestore(app: app).settings = settings
            return app
        }
    }

    // MARK: - OrderRecordingStorageClient

    /// 退会の順番のテスト用の偽の Storage
    /// - 呼ばれるたびに、その時点で posts と users の文書がまだあるかを Emulator で読み、呼ばれた順に記録する
    /// - 一覧はいつも空を返す（残り物の段は、一覧の 10 回だけを見る）
    private final class OrderRecordingStorageClient: AccountStorageClient, @unchecked Sendable {
        enum Kind {
            case delete
            case list
        }

        struct Event: CustomStringConvertible {
            let kind: Kind
            /// 消した置き場所、または一覧したフォルダ
            let target: String
            /// 呼ばれた時点で posts の文書があったか
            let postExisted: Bool
            /// 呼ばれた時点で users の文書があったか
            let userExisted: Bool

            /// 投稿の写真（本体・サムネイル・元画像）の削除か
            var isPostPhoto: Bool {
                kind == .delete && AccountStoragePaths.postRoots.contains { target.hasPrefix("\($0)/") }
            }

            var description: String {
                "\(kind) \(target) post=\(postExisted) user=\(userExisted)"
            }
        }

        private let postDocument: String
        private let userDocument: String
        private let lock = NSLock()
        private var recorded: [Event] = []

        init(postDocument: String, userDocument: String) {
            self.postDocument = postDocument
            self.userDocument = userDocument
        }

        /// 呼ばれた順の記録
        var events: [Event] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func delete(path: String) async throws {
            try await record(.delete, target: path)
        }

        func listFiles(folder: String) async throws -> [String] {
            try await record(.list, target: folder)
            return []
        }

        private func record(_ kind: Kind, target: String) async throws {
            let postExisted = try await EmulatorFirestoreREST.exists(postDocument)
            let userExisted = try await EmulatorFirestoreREST.exists(userDocument)
            append(Event(kind: kind, target: target, postExisted: postExisted, userExisted: userExisted))
        }

        private func append(_ event: Event) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(event)
        }
    }

    // MARK: - EmulatorFirestoreREST

    /// Firestore Emulator の REST に、rules を通さない管理者（Bearer owner）として読み書きする
    private enum EmulatorFirestoreREST {
        enum RESTError: Error {
            /// アプリの FirebaseApp が無い
            case missingDefaultApp
            /// アプリの設定が Emulator の ID ではない（本番に触らないよう止める）
            case notEmulatorProject
            /// 文書の場所から URL を作れない
            case badPath(String)
            /// 思っていない返事
            case unexpectedStatus(path: String, status: Int?)
        }

        /// 文書を置く（あれば上書きする）
        static func put(_ path: String, fields: [String: Any]) async throws {
            var request = try URLRequest(url: documentURL(path))
            request.httpMethod = "PATCH"
            request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields.mapValues(encode)])
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard status == 200 else {
                throw RESTError.unexpectedStatus(path: path, status: status)
            }
        }

        /// 文書があるか（200 ならある・404 なら無い・ほかはエラー）
        static func exists(_ path: String) async throws -> Bool {
            var request = try URLRequest(url: documentURL(path))
            request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            switch status {
            case 200?:
                return true
            case 404?:
                return false
            default:
                throw RESTError.unexpectedStatus(path: path, status: status)
            }
        }

        private static func documentURL(_ path: String) throws -> URL {
            let text = "http://\(FirebaseEmulatorSwitch.host):\(FirebaseEmulatorSwitch.firestorePort)"
                + "/v1/projects/\(FirebaseEmulatorSwitch.projectID)/databases/(default)/documents/\(path)"
            guard let url = URL(string: text) else {
                throw RESTError.badPath(path)
            }
            return url
        }

        /// 値を Firestore の REST の形（stringValue など）にする。種まきで使う型だけ扱う
        private static func encode(_ value: Any) -> Any {
            switch value {
            case let text as String:
                ["stringValue": text]
            case let number as Int:
                ["integerValue": String(number)]
            case let map as [String: Any]:
                ["mapValue": ["fields": map.mapValues(encode)]]
            case let list as [Any]:
                ["arrayValue": ["values": list.map(encode)]]
            default:
                preconditionFailure("種まきで使わない型です: \(type(of: value))")
            }
        }
    }
#endif
