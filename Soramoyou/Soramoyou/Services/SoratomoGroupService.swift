//
//  SoratomoGroupService.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）のグループのサービス ⭐️☁️
//  作成・参加・招待コードの再発行（Callable）と、メンバーとしての読み取り（Firestore）を行う
//  （tasks 11.1・design.md の SoratomoGroupService）。
//
//  ⚠️ 計測（SoratomoAnalytics.log）はここでは呼ばない。画面の ViewModel（tasks 13.x）の責務。
//  ⚠️ グループ・メンバー・所属の写しの書き手は Functions だけ（firestore.rules）。このサービスは読むだけ。
//  ⚠️ 失敗の記録（SoratomoError.record）には、グループ名・招待コードを入れない（要件 15.1）。
//     入れてよいのは ID（groupId・uid）だけ。
//

import FirebaseFirestore
import FirebaseFunctions
import Foundation

/// 記録（非致命エラー）に残す、そらともの読み取りの失敗
///
/// ID だけを持つ。グループ名・招待コードなどの中身は入れない（要件 15.1）。
private enum SoratomoGroupServiceFailure: LocalizedError {
    /// Callable の戻り値が、決めた形でなかった
    case malformedResponse
    /// 文書が、決めた形でなかった（`path` は文書のパス。ID だけで作られる）
    case malformedDocument(path: String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse:
            "soratomo: Callable の戻り値の形が違う"
        case let .malformedDocument(path):
            "soratomo: 文書の形が違う path=\(path)"
        }
    }
}

/// グループのサービス（`SoratomoGroupServiceProtocol` の本物の実装）
///
/// - 作成・参加・再発行は、asia-northeast1 の Callable を制限時間 20 秒で呼ぶ。
/// - 読み取り・監視が権限の拒否か不在で失敗したら、「メンバーでない」（`.notMember`）として返す。
/// - エラーの写しと、文書の読み取りと、並び替えは `static` の純関数にしてある（単体テストで確かめる）。
final class SoratomoGroupService: SoratomoGroupServiceProtocol, @unchecked Sendable {
    // MARK: - 定数

    /// Callable のリージョン（functions/soratomo.js の `REGION` と同じ）
    static let region = "asia-northeast1"

    /// Callable を呼ぶときの制限時間（秒・要件 12.2 の「待ち続けない」ため）
    static let callTimeout: TimeInterval = 20

    /// グループ一覧に出す最大の件数（所属できるグループの上限と同じ・要件 2.5）
    static let maxListedGroups = 10

    /// Callable の名前（functions/soratomo.js の `exports` と同じ）
    private static let createGroupCallableName = "soratomoCreateGroup"
    private static let joinGroupCallableName = "soratomoJoinGroup"
    private static let regenerateInviteCodeCallableName = "soratomoRegenerateInviteCode"

    // MARK: - Properties

    /// 読み取りと監視に使う Firestore
    private let firestore: Firestore
    /// Callable を呼ぶ Functions（リージョン固定）
    private let functions: Functions

    // MARK: - Init

    /// - Parameters:
    ///   - firestore: 読み取りと監視に使う Firestore
    ///   - functions: Callable を呼ぶ Functions（既定は asia-northeast1）
    init(
        firestore: Firestore = Firestore.firestore(),
        functions: Functions = Functions.functions(region: SoratomoGroupService.region)
    ) {
        self.firestore = firestore
        self.functions = functions
    }

    // MARK: - Callable（作成・参加・再発行）

    /// グループを作る（Callable `soratomoCreateGroup`）
    ///
    /// 同じ `requestId` で送り直しても、サーバーが前回のグループを返すので二重に作られない。
    func createGroup(name: String, requestId: UUID) async throws(SoratomoError) -> SoratomoGroupSummary {
        let response = try await call(
            Self.createGroupCallableName,
            payload: ["name": name, "requestId": requestId.uuidString],
            context: "soratomo.createGroup"
        )
        guard let summary = Self.decodeCreateResponse(response) else {
            SoratomoError.record(SoratomoGroupServiceFailure.malformedResponse, context: "soratomo.createGroup.response")
            throw SoratomoError.unknown
        }
        return summary
    }

    /// 招待コードで参加する（Callable `soratomoJoinGroup`）
    ///
    /// すでにメンバーだった場合も成功（`alreadyMember == true`）で返す（要件 4.8）。
    func joinGroup(code: SoratomoInviteCode) async throws(SoratomoError) -> SoratomoJoinResult {
        let response = try await call(
            Self.joinGroupCallableName,
            // サーバーへ渡すのは、正規化済みの 8 文字（表示用のハイフンは付けない）
            payload: ["code": code.rawValue],
            context: "soratomo.joinGroup"
        )
        guard let result = Self.decodeJoinResponse(response) else {
            SoratomoError.record(SoratomoGroupServiceFailure.malformedResponse, context: "soratomo.joinGroup.response")
            throw SoratomoError.unknown
        }
        return result
    }

    /// 招待コードを再発行する（Callable `soratomoRegenerateInviteCode`・オーナーだけ）
    func regenerateInviteCode(groupId: String) async throws(SoratomoError) -> SoratomoInviteCode {
        let response = try await call(
            Self.regenerateInviteCodeCallableName,
            payload: ["groupId": groupId],
            context: "soratomo.regenerateInviteCode"
        )
        guard let inviteCode = Self.decodeRegenerateResponse(response) else {
            SoratomoError.record(SoratomoGroupServiceFailure.malformedResponse, context: "soratomo.regenerateInviteCode.response")
            throw SoratomoError.unknown
        }
        return inviteCode
    }

    /// Callable を呼んで、戻り値（デコード済みの JSON）を返す
    ///
    /// 制限時間は 20 秒。失敗は `mapCallableError` で `SoratomoError` に写す。
    /// - Parameters:
    ///   - name: Callable の名前
    ///   - payload: 送る値（文字列だけで作る）
    ///   - context: 失敗を記録するときの固定の文脈（`soratomo.` で始める）
    private func call(
        _ name: String,
        payload: [String: Any],
        context: StaticString
    ) async throws(SoratomoError) -> Any {
        let callable = functions.httpsCallable(name)
        callable.timeoutInterval = Self.callTimeout
        do {
            let result = try await callable.call(payload)
            return result.data
        } catch {
            let mapped = Self.mapCallableError(error)
            // 想定内の拒否（名前の誤り・満員・通信など）は記録しない。想定外のものだけ残す
            switch mapped {
            case .unknown, .permissionDenied:
                SoratomoError.record(error, context: context)
            default:
                break
            }
            throw mapped
        }
    }

    // MARK: - 読み取り（一覧・メンバー）

    /// 自分が入っているグループを、最新の活動時刻の新しい順に返す（最大 10 件）
    ///
    /// `soratomoUsers/{uid}/groups`（所属の写し）を読み、グループを 1 件ずつ取得する。
    /// グループの一覧（list）はルールで拒否されているため、写しから一覧を作る。
    ///
    /// 1 件ごとの失敗の扱い:
    /// - 通信の失敗・想定外の失敗 → 一覧全体を失敗にする（一部だけ出すと「グループが消えた」と誤解されるため）
    /// - 「メンバーでない」（権限の拒否・不在）か、文書が無い・形が違う → 文書のパスをログに残して、その 1 件だけ飛ばす
    ///   （写しは残っているが実体が読めない、という食い違いが 1 件あるだけで、ほかのグループを隠さない）
    func fetchMyGroups(uid: String) async throws(SoratomoError) -> [SoratomoGroup] {
        guard Self.isUsableDocumentId(uid) else {
            throw SoratomoError.notMember
        }

        let memberships: QuerySnapshot
        do {
            memberships = try await firestore
                .collection(SoratomoFirestorePath.users)
                .document(uid)
                .collection(SoratomoFirestorePath.userGroups)
                .getDocuments()
        } catch {
            throw Self.mapReadError(error, context: "soratomo.fetchMyGroups.memberships")
        }

        var loadedGroups: [SoratomoGroup] = []
        for membership in memberships.documents {
            // 所属の写しの文書 ID が、そのままグループ ID
            let groupId = membership.documentID
            guard Self.isUsableDocumentId(groupId) else {
                continue
            }
            let reference = firestore.collection(SoratomoFirestorePath.groups).document(groupId)

            let snapshot: DocumentSnapshot
            do {
                snapshot = try await reference.getDocument()
            } catch {
                let mapped = Self.mapReadError(error, context: "soratomo.fetchMyGroups.group")
                if mapped == .notMember {
                    // 写しは残っているのに、グループを読めない。この 1 件だけ飛ばす
                    print("⚠️ そらとも: グループを読めないため一覧から除外 path=\(reference.path)")
                    continue
                }
                throw mapped
            }

            guard let data = snapshot.data() else {
                // 写しは残っているのに、グループの文書が無い。この 1 件だけ飛ばす
                print("⚠️ そらとも: グループの文書が無いため一覧から除外 path=\(reference.path)")
                continue
            }
            guard let group = Self.decodeGroup(id: snapshot.documentID, data: data) else {
                // 壊れた文書は、パスをログに残して 1 件だけ飛ばす（`compactMap { try? }` で黙って落とさない）
                print("❌ そらとも: グループの文書を読めないため一覧から除外 path=\(reference.path)")
                SoratomoError.record(
                    SoratomoGroupServiceFailure.malformedDocument(path: reference.path),
                    context: "soratomo.fetchMyGroups.decode"
                )
                continue
            }
            loadedGroups.append(group)
        }
        return Self.sortedForList(loadedGroups)
    }

    /// メンバー一覧を取得する（参加日時の古い順。オーナーは `role == .owner`）
    ///
    /// 文書の形が違うメンバーは、パスをログに残してその 1 件だけ飛ばす。
    func fetchMembers(groupId: String) async throws(SoratomoError) -> [SoratomoMember] {
        guard Self.isUsableDocumentId(groupId) else {
            throw SoratomoError.notMember
        }

        let snapshot: QuerySnapshot
        do {
            snapshot = try await firestore
                .collection(SoratomoFirestorePath.groups)
                .document(groupId)
                .collection(SoratomoFirestorePath.members)
                .getDocuments()
        } catch {
            throw Self.mapReadError(error, context: "soratomo.fetchMembers")
        }

        var loadedMembers: [SoratomoMember] = []
        for document in snapshot.documents {
            guard let member = Self.decodeMember(id: document.documentID, data: document.data()) else {
                print("❌ そらとも: メンバーの文書を読めないため一覧から除外 path=\(document.reference.path)")
                SoratomoError.record(
                    SoratomoGroupServiceFailure.malformedDocument(path: document.reference.path),
                    context: "soratomo.fetchMembers.decode"
                )
                continue
            }
            loadedMembers.append(member)
        }
        return Self.sortedForMembers(loadedMembers)
    }

    // MARK: - 監視

    /// グループ（名前・メンバー数）を監視する
    ///
    /// - 結果は `onChange`（メインアクター）へ、届いた順に渡す。Firestore のコールバックから直接は呼ばず、
    ///   1 本の列（AsyncStream）に積んで、メインアクターの 1 つの Task が順に取り出して呼ぶ
    ///   （`Task { @MainActor in }` を結果ごとに作ると、順序が入れ替わりうるため）。
    /// - 札が止められたら、Firestore の監視を外し、まだ届いていない結果は捨てる。
    /// - ⚠️ `onChange` は、札が止まるまで（Firestore の監視と、取り出す Task が）保持する。呼び出し側が札を
    ///   プロパティに持つ場合、`onChange` の中で `self` を強く捕まえると循環して、札が解放されない
    ///   （自動で止まらない）。`[weak self]` で捕まえること。
    /// - Returns: 監視の札。持っている間だけ監視が続く
    func observeGroup(
        groupId: String,
        onChange: @escaping @MainActor (Result<SoratomoGroup, SoratomoError>) -> Void
    ) -> SoratomoListenerToken {
        // 結果の列（作った直後に、列へ積む口を取り出す）
        var capturedContinuation: AsyncStream<Result<SoratomoGroup, SoratomoError>>.Continuation?
        let stream = AsyncStream<Result<SoratomoGroup, SoratomoError>> { capturedContinuation = $0 }
        let continuation = capturedContinuation

        // 列から順に取り出して、メインアクターで渡す Task
        let consumer = Task { @MainActor in
            for await result in stream {
                // 札が止められた後に積まれていた結果は、渡さない
                if Task.isCancelled { break }
                onChange(result)
            }
        }

        // 文書 ID に使えない文字列では、Firestore が異常終了する。監視は張らずに「メンバーでない」を返す
        guard Self.isUsableDocumentId(groupId) else {
            continuation?.yield(.failure(.notMember))
            continuation?.finish()
            return SoratomoListenerToken {
                consumer.cancel()
            }
        }

        let registration = firestore
            .collection(SoratomoFirestorePath.groups)
            .document(groupId)
            .addSnapshotListener { snapshot, error in
                let result = SoratomoGroupService.resolveObservedGroup(
                    id: groupId,
                    data: snapshot?.data(),
                    isFromCache: snapshot?.metadata.isFromCache ?? false,
                    error: error
                )
                // 想定外の失敗だけ記録する（権限の拒否・通信は想定内）
                if case .failure(.unknown) = result {
                    SoratomoError.record(
                        error ?? SoratomoGroupServiceFailure.malformedDocument(path: "\(SoratomoFirestorePath.groups)/\(groupId)"),
                        context: "soratomo.observeGroup"
                    )
                }
                continuation?.yield(result)
            }

        return SoratomoListenerToken {
            registration.remove()
            continuation?.finish()
            consumer.cancel()
        }
    }

    // MARK: - 純関数: エラーの写し

    /// Callable（Functions）の失敗を、そらともの失敗の種類に写す
    ///
    /// | 元のエラー | 写した種類 |
    /// |---|---|
    /// | `details["reason"]` が `flag_off`・`invalid_name`・`invalid_format`・`not_found`・`group_full`・`user_limit`・`not_owner` | 同名の種類 |
    /// | `unavailable`・`deadlineExceeded`（制限時間切れを含む） | `.network` |
    /// | `permissionDenied`（理由なし）・`unauthenticated` | `.permissionDenied` |
    /// | 理由の無い、それ以外の code | `.unknown` |
    /// | Functions 以外のエラー | `SoratomoError.fromFirestore(_:access: .write)`（通信の失敗は `.network`） |
    ///
    /// - Important: 種類を決めるのは `details["reason"]` だけにして、code だけからは決めない。
    ///   たとえば関数が未デプロイのときは `notFound`（理由なし）が返るが、これを「招待コードが見つかりません」
    ///   にすると、利用者に誤った案内を出してしまう。
    /// - Important: `unauthenticated` は `.permissionDenied` にする（`fromFirestore` の表と同じ）。
    ///   ログインしていない人にはそらともの入口を出さない（SoratomoFeatureGate）ので、通常は来ない。
    /// - Note: サーバーの文言（`message`）は読まない（画面に出さない・要件 12.5）。
    /// - Parameter error: Callable が投げたエラー
    /// - Returns: 写した種類
    static func mapCallableError(_ error: Error) -> SoratomoError {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain else {
            // Functions 以外（通信の失敗など）は、Firestore と同じ写しに回す。
            // Callable は書き込み側の操作なので、権限の拒否は `.permissionDenied` のまま
            return SoratomoError.fromFirestore(error, access: .write)
        }

        // サーバーが理由を付けているもの（ドメインの失敗）が最優先
        if let details = nsError.userInfo[FunctionsErrorDetailsKey] as? [String: Any],
           let reason = details["reason"] as? String,
           let mapped = reasonToError(reason)
        {
            return mapped
        }

        guard let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return .unknown
        }
        switch code {
        case .unavailable, .deadlineExceeded:
            return .network
        case .permissionDenied, .unauthenticated:
            return .permissionDenied
        default:
            return .unknown
        }
    }

    /// `details["reason"]` の文字列を、そらともの失敗の種類に写す（functions/soratomo.js の `REASON_TO_CODE` の理由）
    ///
    /// - Returns: 知っている理由なら種類。知らない理由は nil
    private static func reasonToError(_ reason: String) -> SoratomoError? {
        switch reason {
        case "flag_off":
            .flagOff
        case "invalid_name":
            .invalidName
        case "invalid_format":
            .invalidFormat
        case "not_found":
            .notFound
        case "group_full":
            .groupFull
        case "user_limit":
            .userLimit
        case "not_owner":
            .notOwner
        default:
            nil
        }
    }

    /// 読み取り（Firestore）の失敗を写す。想定外（`.unknown`）だけ記録に残す
    ///
    /// - Parameters:
    ///   - error: Firestore が投げたエラー
    ///   - context: 失敗を記録するときの固定の文脈
    private static func mapReadError(_ error: Error, context: StaticString) -> SoratomoError {
        let mapped = SoratomoError.fromFirestore(error, access: .read)
        if mapped == .unknown {
            SoratomoError.record(error, context: context)
        }
        return mapped
    }

    // MARK: - 純関数: Callable の戻り値

    /// `soratomoCreateGroup` の戻り値を読む
    /// - Returns: `{ groupId, name, inviteCode, memberCount }` の形なら要約。形が違えば nil
    static func decodeCreateResponse(_ response: Any) -> SoratomoGroupSummary? {
        guard let object = response as? [String: Any],
              let groupId = object["groupId"] as? String, !groupId.isEmpty,
              let name = object["name"] as? String,
              let codeText = object["inviteCode"] as? String,
              let inviteCode = SoratomoInviteCode.parse(userInput: codeText),
              let memberCount = object["memberCount"] as? Int
        else {
            return nil
        }
        return SoratomoGroupSummary(groupId: groupId, name: name, inviteCode: inviteCode, memberCount: memberCount)
    }

    /// `soratomoJoinGroup` の戻り値を読む
    /// - Returns: `{ groupId, alreadyMember }` の形なら結果。形が違えば nil
    static func decodeJoinResponse(_ response: Any) -> SoratomoJoinResult? {
        guard let object = response as? [String: Any],
              let groupId = object["groupId"] as? String, !groupId.isEmpty,
              let alreadyMember = object["alreadyMember"] as? Bool
        else {
            return nil
        }
        return SoratomoJoinResult(groupId: groupId, alreadyMember: alreadyMember)
    }

    /// `soratomoRegenerateInviteCode` の戻り値を読む
    /// - Returns: `{ inviteCode }` の形なら招待コード。形が違えば nil
    static func decodeRegenerateResponse(_ response: Any) -> SoratomoInviteCode? {
        guard let object = response as? [String: Any],
              let codeText = object["inviteCode"] as? String
        else {
            return nil
        }
        return SoratomoInviteCode.parse(userInput: codeText)
    }

    // MARK: - 純関数: 文書の読み取り

    /// Firestore の文書 ID として使える文字列か
    ///
    /// 空文字や「/」を含む文字列で `document(_:)` を呼ぶと、Firestore が異常終了する。
    /// 呼ぶ前にここで弾いて、「メンバーでない」として扱う。
    static func isUsableDocumentId(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/")
    }

    /// グループの文書（`soratomoGroups/{groupId}`）を読む
    /// - Parameters:
    ///   - id: 文書 ID（グループ ID）
    ///   - data: 文書の項目
    /// - Returns: 6 項目がそろって正しい形ならグループ。1 つでも欠ける・形が違えば nil
    static func decodeGroup(id: String, data: [String: Any]) -> SoratomoGroup? {
        guard let name = data["name"] as? String,
              let ownerId = data["ownerId"] as? String,
              let codeText = data["inviteCode"] as? String,
              let inviteCode = SoratomoInviteCode.parse(userInput: codeText),
              let memberCount = data["memberCount"] as? Int,
              let createdAt = (data["createdAt"] as? Timestamp)?.dateValue(),
              let lastActivityAt = (data["lastActivityAt"] as? Timestamp)?.dateValue()
        else {
            return nil
        }
        return SoratomoGroup(
            id: id,
            name: name,
            ownerId: ownerId,
            inviteCode: inviteCode,
            memberCount: memberCount,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
        )
    }

    /// メンバーの文書（`soratomoGroups/{groupId}/members/{uid}`）を読む
    /// - Parameters:
    ///   - id: 文書 ID（メンバーの uid）
    ///   - data: 文書の項目
    /// - Returns: `role`（`owner` か `member`）と `joinedAt` が正しい形ならメンバー。そうでなければ nil
    static func decodeMember(id: String, data: [String: Any]) -> SoratomoMember? {
        guard let roleText = data["role"] as? String,
              let role = SoratomoMemberRole(rawValue: roleText),
              let joinedAt = (data["joinedAt"] as? Timestamp)?.dateValue()
        else {
            return nil
        }
        return SoratomoMember(id: id, role: role, joinedAt: joinedAt)
    }

    /// グループの監視の 1 回分（Firestore のコールバックの中身）を、結果に直す
    ///
    /// | 状態 | 結果 |
    /// |---|---|
    /// | エラー | `SoratomoError.fromFirestore(_:access: .read)`（権限の拒否・不在は `.notMember`） |
    /// | 文書が無い（サーバーの確認済み） | `.notMember` |
    /// | 文書が無い（端末のキャッシュだけの結果） | `.network` |
    /// | 文書があるが形が違う | `.unknown` |
    /// | 文書がある | 成功 |
    ///
    /// - Important: オフラインで、まだ端末に写しが無い文書は「無い」として届く（エラーにならない）。
    ///   これを `.notMember` にすると、通信できないだけで「グループを開けませんでした」になるため、
    ///   キャッシュだけの「無い」は `.network` にする。監視は続くので、つながれば正しい結果が届く。
    /// - Parameters:
    ///   - id: 監視しているグループ ID
    ///   - data: 文書の項目（文書が無ければ nil）
    ///   - isFromCache: 端末のキャッシュだけから作った結果か
    ///   - error: 監視のエラー
    static func resolveObservedGroup(
        id: String,
        data: [String: Any]?,
        isFromCache: Bool,
        error: Error?
    ) -> Result<SoratomoGroup, SoratomoError> {
        if let error {
            return .failure(SoratomoError.fromFirestore(error, access: .read))
        }
        guard let data else {
            return .failure(isFromCache ? .network : .notMember)
        }
        guard let group = decodeGroup(id: id, data: data) else {
            return .failure(.unknown)
        }
        return .success(group)
    }

    // MARK: - 純関数: 並び替え

    /// グループ一覧の並びにする: 最新の活動時刻の新しい順に並べて、最大 10 件にする
    ///
    /// 活動時刻が同じものは、作成日時の新しい順、さらに同じなら ID 順にする（実行のたびに並びが揺れないため）。
    /// - Parameter groups: 読み取れたグループ（順不同）
    /// - Returns: 最大 `maxListedGroups` 件
    static func sortedForList(_ groups: [SoratomoGroup]) -> [SoratomoGroup] {
        let sorted = groups.sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
        return Array(sorted.prefix(maxListedGroups))
    }

    /// メンバー一覧の並びにする: 参加日時の古い順（同じなら uid 順）
    ///
    /// Firestore の `order(by: "joinedAt")` は使わない。`joinedAt` が無い文書がクエリから黙って消えるため、
    /// 全件を読んでから、アプリ側で並べる。
    /// - Parameter members: 読み取れたメンバー（順不同）
    static func sortedForMembers(_ members: [SoratomoMember]) -> [SoratomoMember] {
        members.sorted { lhs, rhs in
            if lhs.joinedAt != rhs.joinedAt {
                return lhs.joinedAt < rhs.joinedAt
            }
            return lhs.id < rhs.id
        }
    }
}
