//
//  SoratomoServiceMocks.swift
//  SoramoyouTests
//
//  そらとものサービスの protocol のモック ⭐️
//  （S6 の Wave 0 で先に置いた。画面の ViewModel のテスト（tasks 13.x）で使う）
//
//  どのモックも「返す結果を先に決めておく」と「呼ばれた引数を記録する」の 2 つだけを持つ。
//  結果の既定値は `.failure(.unknown)`。テストで使う結果は、必ずテストの中で決めること。
//
//  ⚠️ 型の名前（Mock + protocol の名前から Protocol を除いたもの）は全体で 1 つ。
//     同じ名前のモックを別のテストのファイルに作ると、ビルドが通らない。
//

import Foundation
@testable import Soramoyou

// MARK: - 共通

private extension Result where Failure == SoratomoError {
    /// 結果を取り出す（失敗なら SoratomoError として投げる）
    ///
    /// `Result.get()` を使わないのは、投げる型が `any Error` になる SDK があり、
    /// `throws(SoratomoError)` の関数の中で使えないことがあるため。
    func soratomoValue() throws(SoratomoError) -> Success {
        switch self {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }
}

// MARK: - グループ

/// `SoratomoGroupServiceProtocol` のモック
final class MockSoratomoGroupService: SoratomoGroupServiceProtocol, @unchecked Sendable {
    // 返す結果
    var createGroupResult: Result<SoratomoGroupSummary, SoratomoError> = .failure(.unknown)
    var joinGroupResult: Result<SoratomoJoinResult, SoratomoError> = .failure(.unknown)
    var regenerateInviteCodeResult: Result<SoratomoInviteCode, SoratomoError> = .failure(.unknown)
    var fetchMyGroupsResult: Result<[SoratomoGroup], SoratomoError> = .failure(.unknown)
    var fetchMembersResult: Result<[SoratomoMember], SoratomoError> = .failure(.unknown)

    // 呼ばれた引数
    private(set) var createGroupCalls: [(name: String, requestId: UUID)] = []
    private(set) var joinGroupCalls: [SoratomoInviteCode] = []
    private(set) var regenerateInviteCodeCalls: [String] = []
    private(set) var fetchMyGroupsCalls: [String] = []
    private(set) var fetchMembersCalls: [String] = []
    private(set) var observeGroupCalls: [String] = []
    /// 止められた監視のグループ ID（札の cancel か解放で記録される）
    private(set) var cancelledGroupObservations: [String] = []

    /// 監視の受け手（グループ ID ごとに最後に張られたもの）
    private var groupObservers: [String: @MainActor (Result<SoratomoGroup, SoratomoError>) -> Void] = [:]

    func createGroup(name: String, requestId: UUID) async throws(SoratomoError) -> SoratomoGroupSummary {
        createGroupCalls.append((name, requestId))
        return try createGroupResult.soratomoValue()
    }

    func joinGroup(code: SoratomoInviteCode) async throws(SoratomoError) -> SoratomoJoinResult {
        joinGroupCalls.append(code)
        return try joinGroupResult.soratomoValue()
    }

    func regenerateInviteCode(groupId: String) async throws(SoratomoError) -> SoratomoInviteCode {
        regenerateInviteCodeCalls.append(groupId)
        return try regenerateInviteCodeResult.soratomoValue()
    }

    func fetchMyGroups(uid: String) async throws(SoratomoError) -> [SoratomoGroup] {
        fetchMyGroupsCalls.append(uid)
        return try fetchMyGroupsResult.soratomoValue()
    }

    func observeGroup(
        groupId: String,
        onChange: @escaping @MainActor (Result<SoratomoGroup, SoratomoError>) -> Void
    ) -> SoratomoListenerToken {
        observeGroupCalls.append(groupId)
        groupObservers[groupId] = onChange
        return SoratomoListenerToken { [weak self] in
            self?.groupObservers[groupId] = nil
            self?.cancelledGroupObservations.append(groupId)
        }
    }

    func fetchMembers(groupId: String) async throws(SoratomoError) -> [SoratomoMember] {
        fetchMembersCalls.append(groupId)
        return try fetchMembersResult.soratomoValue()
    }

    /// 監視中の受け手に結果を届ける（止められていれば何もしない）
    @MainActor
    func emitGroup(groupId: String, _ result: Result<SoratomoGroup, SoratomoError>) {
        groupObservers[groupId]?(result)
    }
}

// MARK: - 投稿

/// `SoratomoSkyServiceProtocol` のモック
final class MockSoratomoSkyService: SoratomoSkyServiceProtocol, @unchecked Sendable {
    // 返す結果
    var createSkyResult: Result<Void, SoratomoError> = .failure(.unknown)
    var skyExistsOnServerResult: Result<Bool, SoratomoError> = .failure(.unknown)
    var deleteSkyResult: Result<Void, SoratomoError> = .failure(.unknown)
    /// `countTodaySkies` が返す件数（nil = 数えられなかった）
    var todaySkyCount: Int?

    // 呼ばれた引数
    private(set) var newSkyIdCalls: [String] = []
    private(set) var observeTimelineCalls: [(groupId: String, limit: Int)] = []
    private(set) var createSkyCalls: [SoratomoSkyDraft] = []
    private(set) var skyExistsOnServerCalls: [(groupId: String, skyId: String)] = []
    private(set) var deleteSkyCalls: [(groupId: String, skyId: String)] = []
    private(set) var countTodaySkiesCalls: [(groupId: String, authorId: String, since: Date)] = []
    /// 止められた監視の番号（`observeTimelineCalls` の添字）
    private(set) var cancelledTimelineIndexes: Set<Int> = []
    /// 投稿 1 件の監視の呼び出し（release-gate 9.3）
    private(set) var observeSkyCalls: [(groupId: String, skyId: String)] = []
    /// 止められた投稿 1 件の監視の番号（`observeSkyCalls` の添字）
    private(set) var cancelledSkyIndexes: Set<Int> = []

    /// 監視の受け手（`observeTimelineCalls` と同じ添字）
    private var timelineObservers: [@MainActor (Result<SoratomoTimelineSnapshot, SoratomoError>) -> Void] = []
    /// 投稿 1 件の監視の受け手（`observeSkyCalls` と同じ添字）
    private var skyObservers: [@MainActor (Result<SoratomoSkyPresence, SoratomoError>) -> Void] = []

    func newSkyId(groupId: String) -> String {
        newSkyIdCalls.append(groupId)
        return "sky-\(newSkyIdCalls.count)"
    }

    func observeTimeline(
        groupId: String,
        limit: Int,
        onChange: @escaping @MainActor (Result<SoratomoTimelineSnapshot, SoratomoError>) -> Void
    ) -> SoratomoListenerToken {
        let index = observeTimelineCalls.count
        observeTimelineCalls.append((groupId, limit))
        timelineObservers.append(onChange)
        return SoratomoListenerToken { [weak self] in
            self?.cancelledTimelineIndexes.insert(index)
        }
    }

    func observeSky(
        groupId: String,
        skyId: String,
        onChange: @escaping @MainActor (Result<SoratomoSkyPresence, SoratomoError>) -> Void
    ) -> SoratomoListenerToken {
        let index = observeSkyCalls.count
        observeSkyCalls.append((groupId, skyId))
        skyObservers.append(onChange)
        return SoratomoListenerToken { [weak self] in
            self?.cancelledSkyIndexes.insert(index)
        }
    }

    func createSky(_ draft: SoratomoSkyDraft) async throws(SoratomoError) {
        createSkyCalls.append(draft)
        try createSkyResult.soratomoValue()
    }

    func skyExistsOnServer(groupId: String, skyId: String) async throws(SoratomoError) -> Bool {
        skyExistsOnServerCalls.append((groupId, skyId))
        return try skyExistsOnServerResult.soratomoValue()
    }

    func deleteSky(groupId: String, skyId: String) async throws(SoratomoError) {
        deleteSkyCalls.append((groupId, skyId))
        try deleteSkyResult.soratomoValue()
    }

    func countTodaySkies(groupId: String, authorId: String, since startOfLocalDay: Date) async -> Int? {
        countTodaySkiesCalls.append((groupId, authorId, startOfLocalDay))
        return todaySkyCount
    }

    /// いちばん新しい、止められていない監視に結果を届ける（無ければ何もしない）
    @MainActor
    func emitTimeline(_ result: Result<SoratomoTimelineSnapshot, SoratomoError>) {
        guard let index = timelineObservers.indices.last(where: { !cancelledTimelineIndexes.contains($0) }) else {
            return
        }
        timelineObservers[index](result)
    }

    /// いちばん新しい、止められていない投稿 1 件の監視に結果を届ける（無ければ何もしない）
    @MainActor
    func emitSky(_ result: Result<SoratomoSkyPresence, SoratomoError>) {
        guard let index = skyObservers.indices.last(where: { !cancelledSkyIndexes.contains($0) }) else {
            return
        }
        skyObservers[index](result)
    }
}

// MARK: - 画像

/// `SoratomoImageStoreProtocol` のモック
final class MockSoratomoImageStore: SoratomoImageStoreProtocol, @unchecked Sendable {
    // 返す結果
    var uploadResult: Result<Void, SoratomoError> = .failure(.unknown)
    /// アップロード中に、この順で進み具合を知らせる
    var progressToReport: [Double] = []
    var deleteOutcome: SoratomoImageDeleteOutcome = .deleted

    // 呼ばれた引数
    private(set) var uploadCalls: [(images: SoratomoEncodedImages, paths: SoratomoImagePaths)] = []
    private(set) var cancelUploadsCalls: [SoratomoImagePaths] = []
    private(set) var deleteCalls: [SoratomoImagePaths] = []

    func upload(
        _ images: SoratomoEncodedImages,
        to paths: SoratomoImagePaths,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws(SoratomoError) {
        uploadCalls.append((images, paths))
        for value in progressToReport {
            progress(value)
        }
        try uploadResult.soratomoValue()
    }

    func cancelUploads(to paths: SoratomoImagePaths) {
        cancelUploadsCalls.append(paths)
    }

    func delete(_ paths: SoratomoImagePaths) async -> SoratomoImageDeleteOutcome {
        deleteCalls.append(paths)
        return deleteOutcome
    }
}

// MARK: - 表示名とそらとも通知

/// `SoratomoProfileServiceProtocol` のモック
final class MockSoratomoProfileService: SoratomoProfileServiceProtocol, @unchecked Sendable {
    // 返す結果
    var needsDisplayNameResult: Result<Bool, SoratomoError> = .failure(.unknown)
    var saveDisplayNameResult: Result<Void, SoratomoError> = .failure(.unknown)
    var setNotifySoratomoResult: Result<Void, SoratomoError> = .failure(.unknown)

    // 呼ばれた引数
    private(set) var needsDisplayNameCalls: [String] = []
    private(set) var saveDisplayNameCalls: [(uid: String, name: SoratomoDisplayName)] = []
    private(set) var setNotifySoratomoCalls: [(uid: String, enabled: Bool)] = []

    func needsDisplayName(uid: String) async throws(SoratomoError) -> Bool {
        needsDisplayNameCalls.append(uid)
        return try needsDisplayNameResult.soratomoValue()
    }

    func saveDisplayName(uid: String, name: SoratomoDisplayName) async throws(SoratomoError) {
        saveDisplayNameCalls.append((uid, name))
        try saveDisplayNameResult.soratomoValue()
    }

    func setNotifySoratomo(uid: String, enabled: Bool) async throws(SoratomoError) {
        setNotifySoratomoCalls.append((uid, enabled))
        try setNotifySoratomoResult.soratomoValue()
    }
}

// MARK: - 通報とブロック（release-gate 9.2）

/// `SoratomoModerationServiceProtocol` のモック
///
/// ⚠️ 本物と違い、ブロックが成功しても `.userBlocked` を送らない（呼ばれた引数を記録するだけ）。
final class MockSoratomoModerationService: SoratomoModerationServiceProtocol, @unchecked Sendable {
    // 返す結果
    var reportResult: Result<Void, SoratomoError> = .failure(.unknown)
    var blockResult: Result<Void, SoratomoError> = .failure(.unknown)
    var fetchBlockedUserIdsResult: Result<Set<String>, SoratomoError> = .failure(.unknown)

    // 呼ばれた引数
    private(set) var reportCalls: [(groupId: String, skyId: String, reason: ReportReason)] = []
    private(set) var blockCalls: [(uid: String, authorId: String)] = []
    private(set) var fetchBlockedUserIdsCalls: [String] = []

    func report(groupId: String, skyId: String, reason: ReportReason) async throws(SoratomoError) {
        reportCalls.append((groupId, skyId, reason))
        try reportResult.soratomoValue()
    }

    func block(uid: String, authorId: String) async throws(SoratomoError) {
        blockCalls.append((uid, authorId))
        try blockResult.soratomoValue()
    }

    func fetchBlockedUserIds(uid: String) async throws(SoratomoError) -> Set<String> {
        fetchBlockedUserIdsCalls.append(uid)
        return try fetchBlockedUserIdsResult.soratomoValue()
    }
}
