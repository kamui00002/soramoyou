//
//  SoratomoRootView.swift
//  Soramoyou
//
//  そらともの根の画面（NavigationStack）⭐️
//  （tasks 13.1・design.md の SoratomoRootView・SoratomoRouter・要件 5.1・10.9）
//
//  ルーターのパス（`SoratomoRouter.path`）を NavigationStack に結び、4 つの行き先
//  （タイムライン・招待・メンバー一覧・投稿詳細）をここで 1 回だけ対応づける。
//  ⚠️ 13.2〜13.9 の担当は、このファイルを変えない。自分の画面のファイル（同じ init）の中身を置き換える。
//  全画面のカバーから出すのは 14.1（MainTabView）の担当。
//

import SwiftUI
import UIKit

/// そらともの根の画面
///
/// - パスが空なら一覧、`[.timeline(groupId:)]` なら一覧の上にタイムライン（通知の行き先の形）
/// - ルーターの一時表示（`notice`。「グループを開けませんでした」など）を、上部に数秒だけ出す
struct SoratomoRootView: View {
    // MARK: - Properties

    /// そらともへの遷移を決めるルーター（アプリでは `SoratomoRouter.shared`）
    @ObservedObject var router: SoratomoRouter
    /// サービスの容れ物（アプリでは `SoratomoDependencies.live`）
    let dependencies: SoratomoDependencies

    /// 一時表示を出しておく時間（秒）
    private static let noticeSeconds: UInt64 = 3

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $router.path) {
            SoratomoGroupListView(router: router, dependencies: dependencies)
                .soratomoSkyBackground()
                .navigationDestination(for: SoratomoDestination.self) { destination in
                    view(for: destination)
                }
        }
        .overlay(alignment: .top) {
            noticeBanner
        }
        // 画面名の記録（要件 14.5）。各画面の onAppear は、戻るスワイプを途中でやめたときなどに重ねて発火しうるので、
        // パス（`router.path`）を単一の真実源にして「画面の切り替え 1 回 = 記録 1 回」にする（MainTabView の selectedTab と同じ形）。
        // 投稿画面（シート）はパスに入らないので、投稿画面の側で記録する
        .task {
            SoratomoAnalytics.screen(Self.screen(for: router.path))
        }
        .onChange(of: router.path) { newPath in
            // 閉じるとき（dismiss は isPresented を先に false にしてからパスを空にする）は記録しない
            guard router.isPresented else { return }
            SoratomoAnalytics.screen(Self.screen(for: newPath))
        }
        // 一時表示が変わるたびに、数秒後に消す（同じ文言が続けて来ても、id が nil を挟むので数え直す）
        .task(id: router.notice) {
            guard router.notice != nil else { return }
            try? await Task.sleep(nanoseconds: Self.noticeSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            router.notice = nil
        }
    }

    // MARK: - 画面名

    /// パスの末尾（いま見えている画面）の画面名。パスが空なら一覧
    static func screen(for path: [SoratomoDestination]) -> SoratomoScreen {
        switch path.last {
        case nil: .groupList
        case .timeline: .timeline
        case .invite: .invite
        case .members: .members
        case .skyDetail: .skyDetail
        }
    }

    // MARK: - 行き先

    /// 行き先ごとの画面（13.4・13.5・13.9 の担当が、それぞれのファイルの中身を作る）
    @ViewBuilder
    private func view(for destination: SoratomoDestination) -> some View {
        switch destination {
        // 背景は雲つきの空にそろえる（SoratomoSkyBackground.swift）。投稿詳細だけは写真の色を邪魔しないよう付けない
        case let .timeline(groupId):
            SoratomoTimelineView(groupId: groupId, router: router, dependencies: dependencies)
                .soratomoSkyBackground()
        case let .invite(groupId):
            SoratomoInviteView(groupId: groupId, dependencies: dependencies)
                .soratomoSkyBackground()
        case let .members(groupId):
            SoratomoMembersView(groupId: groupId, dependencies: dependencies)
                .soratomoSkyBackground()
        case let .skyDetail(groupId, skyId):
            SoratomoSkyDetailView(groupId: groupId, skyId: skyId, dependencies: dependencies)
        }
    }

    // MARK: - 一時表示

    /// ルーターの一時表示（無ければ何も出さない）
    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = router.notice {
            Text(notice)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                // VoiceOver では、出た時点で読み上げる
                .accessibilityAddTraits(.updatesFrequently)
                .onAppear {
                    UIAccessibility.post(notification: .announcement, argument: notice)
                }
        }
    }
}
