//
//  SoratomoTimelineView.swift
//  Soramoyou
//
//  ⭐️ 仮の行き先（tasks 13.1 で置いた骨組み）。中身は 13.5・13.6 の担当（b3）が作る。
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView などを、担当は触らないため）。
//     足したいものがあれば、変えずに「共有ファイルへの追加依頼」として報告する。
//

import SwiftUI

/// グループのタイムライン
///
/// - グループを最初に読めたら `router.reportAccessible(groupId:)`、読めなかったら
///   `router.reportNotAccessible(groupId:)` を呼ぶ（12.1 の記録は 1 タップ 1 回）
/// - 招待・メンバー一覧・投稿詳細へは `router.path.append(...)` で進む
/// - 投稿画面（13.7・13.8 の `SoratomoComposeView`）はシートで出す
struct SoratomoTimelineView: View {
    /// 表示するグループの ID
    let groupId: String
    /// そらともへの遷移を決めるルーター
    @ObservedObject var router: SoratomoRouter
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    var body: some View {
        Text("準備中")
    }
}
