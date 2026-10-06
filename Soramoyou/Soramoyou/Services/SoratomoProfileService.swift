//
//  SoratomoProfileService.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の表示名とそらとも通知の保存 ⭐️
//  （tasks 11.5・design.md の SoratomoProfileService・要件 10.16・18.1・18.4・18.5・18.6・18.7）
//
//  - 表示名が要るか: `users/{uid}.displayName` を前後の空白を除いて判定する
//  - 表示名の保存: 1 つのトランザクションで `users` と `publicProfiles` の 2 項目（displayName・updatedAt）だけを書く
//  - そらとも通知の保存: `users/{uid}.notifySoratomo` だけを `updateData` で書く
//
//  ⚠️ そらとも専用の別の表示名は持たない（要件 18.7）。ここで保存した表示名が、既存のプロフィールの表示名になる。
//  ⚠️ 失敗はすべて `SoratomoError` に写して投げる（書き込みは `.write`、読み取りは `.read`）。
//     サーバーの文言は画面に出さない（要件 12.5）。
//  ⚠️ 計測（SoratomoAnalytics.log）はここでは呼ばない。画面の ViewModel（tasks 13.x）の責務。
//

import FirebaseFirestore
import Foundation

// MARK: - Firestore の窓口（テストで差し替える）

/// 表示名とそらとも通知を読み書きする Firestore の窓口
///
/// `SoratomoProfileService` は、この窓口が投げたエラーを `SoratomoError` に写すだけを受け持つ。
/// Firestore を直接呼ばずにこの窓口を通すのは、単体テストで失敗（通信を含む）を差し替えるため。
/// 窓口は `SoratomoError` へ写さず、元のエラーのまま投げる。
protocol SoratomoProfileDataSource: Sendable {
    /// `users/{uid}` の表示名を読む
    /// - Returns: 表示名（前後の空白は除かない）。文書が無い・項目が無い・文字列でないときは nil
    func fetchUserDisplayName(uid: String) async throws -> String?

    /// 表示名を保存する（`users` と `publicProfiles` を 1 つのトランザクションで）
    /// - Parameters:
    ///   - uid: 保存する利用者
    ///   - displayName: `SoratomoTextRules.validateDisplayName` を通した表示名
    func saveDisplayName(uid: String, displayName: String) async throws

    /// `users/{uid}.notifySoratomo` だけを更新で書く
    func setNotifySoratomo(uid: String, enabled: Bool) async throws
}

// MARK: - サービス

/// 表示名の事前入力と、そらとも通知の保存（`SoratomoProfileServiceProtocol` の実装）
final class SoratomoProfileService: SoratomoProfileServiceProtocol {
    /// 表示名の保存でトランザクションの中で決める「どう書くか」
    enum DisplayNameWritePlan: Equatable {
        /// `users/{uid}` が無い。書けない（文書全体は作らない）ので失敗にする
        case userDocumentMissing
        /// すでに表示名が設定されている。何も書かず、いまの名前を残す（50 文字までの名前を含む・要件 18.6）
        case keepExisting
        /// 表示名が無い（未設定・空・空白だけ）。書く
        case write
    }

    /// Firestore の読み書きの窓口
    private let dataSource: any SoratomoProfileDataSource

    /// - Parameter dataSource: Firestore の窓口。既定は本物の Firestore（呼ばれたときに初めて Firestore を使う）
    init(dataSource: any SoratomoProfileDataSource = SoratomoProfileFirestoreDataSource()) {
        self.dataSource = dataSource
    }

    // MARK: - SoratomoProfileServiceProtocol

    /// 表示名の入力が要るか（`users/{uid}.displayName` が無いか空白だけなら true）
    func needsDisplayName(uid: String) async throws(SoratomoError) -> Bool {
        try Self.requireUid(uid)
        do {
            let displayName = try await dataSource.fetchUserDisplayName(uid: uid)
            return Self.isDisplayNameMissing(displayName)
        } catch {
            throw SoratomoError.fromFirestore(error, access: .read)
        }
    }

    /// 表示名を保存する（`users` と `publicProfiles` を 1 つのトランザクションで）
    ///
    /// すでに表示名が設定されているときは、何も書かずに成功で返す（いまの名前を残す・要件 18.6）。
    func saveDisplayName(uid: String, name: SoratomoDisplayName) async throws(SoratomoError) {
        try Self.requireUid(uid)
        do {
            try await dataSource.saveDisplayName(uid: uid, displayName: name.value)
        } catch {
            throw SoratomoError.fromFirestore(error, access: .write)
        }
    }

    /// そらとも通知のオン・オフを保存する（`users/{uid}.notifySoratomo` だけを更新）
    func setNotifySoratomo(uid: String, enabled: Bool) async throws(SoratomoError) {
        try Self.requireUid(uid)
        do {
            try await dataSource.setNotifySoratomo(uid: uid, enabled: enabled)
        } catch {
            throw SoratomoError.fromFirestore(error, access: .write)
        }
    }

    // MARK: - 判定（純関数・テストから呼ぶ）

    /// 表示名が「要る」状態か（無い・空・前後の空白を除くと空）
    ///
    /// 除く文字は `RankingDisplayText.authorName`（画面の代替の規則）と同じ空白と改行。
    /// 空白だけの名前は、画面では「ユーザー」に代替されるので、入力を求める側に倒す。
    /// - Parameter raw: `users/{uid}.displayName` の値（前後の空白を除く前）
    static func isDisplayNameMissing(_ raw: String?) -> Bool {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 表示名の保存で、トランザクションの中で読んだ内容から「どう書くか」を決める
    ///
    /// - Parameters:
    ///   - userDocumentExists: `users/{uid}` が在るか
    ///   - existingDisplayName: `users/{uid}.displayName` の値（前後の空白を除く前）
    static func displayNameWritePlan(
        userDocumentExists: Bool,
        existingDisplayName: String?
    ) -> DisplayNameWritePlan {
        if !userDocumentExists {
            return .userDocumentMissing
        }
        if !isDisplayNameMissing(existingDisplayName) {
            return .keepExisting
        }
        return .write
    }

    // MARK: - Private

    /// uid が空でないことを確かめる
    ///
    /// Firestore は空のドキュメント ID でクラッシュする（実行時の例外）。ログインしていない状態
    /// （uid が取れない）で呼ばれても落とさず、認証の失敗と同じ `.permissionDenied` にする。
    private static func requireUid(_ uid: String) throws(SoratomoError) {
        if uid.isEmpty { throw .permissionDenied }
    }
}

// MARK: - 本物の Firestore の窓口

/// `users` と `publicProfiles` を読み書きする本物の Firestore の窓口
///
/// 状態を持たない（呼ばれるたびに `Firestore.firestore()` を引く）。アプリの外（単体テスト）で
/// `SoratomoProfileService()` を作っても、呼ばない限り Firebase に触れない。
struct SoratomoProfileFirestoreDataSource: SoratomoProfileDataSource {
    /// 既存の利用者のコレクション名（FirestoreService の `usersCollection` と同じ。
    /// ⚠️ `SoratomoFirestorePath.users` は別物（`soratomoUsers`・グループの所属の集計）なので使わない）
    private static let usersCollection = "users"
    /// 既存の公開プロフィールのコレクション名（FirestoreService の `publicProfilesCollection` と同じ）
    private static let publicProfilesCollection = "publicProfiles"
    /// トランザクションの中で独自に失敗にするときのエラードメイン（`SoratomoError.fromFirestore` が `.unknown` に写す）
    private static let errorDomain = "SoratomoProfileFirestoreDataSource"
    /// `users/{uid}` が無かったときのエラー番号
    private static let userDocumentMissingCode = 404

    private var db: Firestore {
        Firestore.firestore()
    }

    func fetchUserDisplayName(uid: String) async throws -> String? {
        let snapshot = try await db.collection(Self.usersCollection).document(uid).getDocument()
        return snapshot.data()?["displayName"] as? String
    }

    /// 表示名を 1 つのトランザクションで保存する
    ///
    /// 1. `users/{uid}` と `publicProfiles/{uid}` を読む（トランザクションは書き込みの前に読み取りを済ませる）
    /// 2. 表示名がすでにあれば何も書かない。`users/{uid}` が無ければ失敗にする
    /// 3. `users/{uid}` の `displayName` と `updatedAt` だけを更新する（文書全体は書かない）
    /// 4. `publicProfiles/{uid}` があれば、同じ 2 項目だけを更新する。無ければ、既存の作成
    ///    （`createPublicProfileIfMissing`）と同じ `PublicProfile(from:)` の形で作る
    ///
    /// ルール（firestore.rules）との照合: users の update は「所有者・id 不変・email 不変」、
    /// publicProfiles の update は「所有者・id 不変・recommendedPostIds の検査」、create は
    /// 「所有者・id と createdAt が在る・id が uid と一致」。上の書き方はどれも満たす。
    func saveDisplayName(uid: String, displayName: String) async throws {
        let userRef = db.collection(Self.usersCollection).document(uid)
        let publicProfileRef = db.collection(Self.publicProfilesCollection).document(uid)

        _ = try await db.runTransaction { transaction, errorPointer in
            do {
                let userSnapshot = try transaction.getDocument(userRef)
                let publicProfileSnapshot = try transaction.getDocument(publicProfileRef)
                let userData = userSnapshot.data()

                let plan = SoratomoProfileService.displayNameWritePlan(
                    userDocumentExists: userSnapshot.exists,
                    existingDisplayName: userData?["displayName"] as? String
                )
                switch plan {
                case .userDocumentMissing:
                    errorPointer?.pointee = NSError(
                        domain: Self.errorDomain,
                        code: Self.userDocumentMissingCode,
                        userInfo: [NSLocalizedDescriptionKey: "利用者の文書がありません"]
                    )
                    return nil
                case .keepExisting:
                    return nil
                case .write:
                    let now = Date()
                    let fields: [String: Any] = [
                        "displayName": displayName,
                        "updatedAt": Timestamp(date: now),
                    ]
                    transaction.updateData(fields, forDocument: userRef)

                    if publicProfileSnapshot.exists {
                        transaction.updateData(fields, forDocument: publicProfileRef)
                    } else {
                        // 公開プロフィールが無い（移行前の旧アカウント）。`createPublicProfileIfMissing` と同じく
                        // 利用者の文書から作る。中の id は、ルールの作成条件（id == uid）のため uid に固定する。
                        var data = userData ?? [:]
                        data["id"] = uid
                        var user = try User(from: data)
                        user.displayName = displayName
                        user.updatedAt = now
                        transaction.setData(PublicProfile(from: user).toFirestoreData(), forDocument: publicProfileRef)
                    }
                    return nil
                }
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
        }
    }

    func setNotifySoratomo(uid: String, enabled: Bool) async throws {
        // notifySoratomo の 1 項目だけを更新で書く（User 全体を書かない・既存の 3 つの通知設定と同じ保存の仕組み）。
        // 文書が無ければ Firestore の notFound で失敗する（書き込みの notFound は `.unknown` に写る）。
        try await db.collection(Self.usersCollection).document(uid).updateData([
            "notifySoratomo": enabled,
        ])
    }
}
