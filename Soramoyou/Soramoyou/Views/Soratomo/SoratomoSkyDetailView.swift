//
//  SoratomoSkyDetailView.swift
//  Soramoyou
//
//  ⭐️ 仮の行き先（tasks 13.1 で置いた骨組み）。中身は 13.9 の担当（b5）が作る。
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView などを、担当は触らないため）。
//     足したいものがあれば、変えずに「共有ファイルへの追加依頼」として報告する。
//

import SwiftUI

/// 投稿の詳細
///
/// 投稿の中身は `dependencies.skyLookup.sky(groupId:skyId:)` から読む（タイムラインが覚えたもの）。
/// 見つからなければ「表示できません」の表示にする。
struct SoratomoSkyDetailView: View {
    /// 投稿のグループの ID
    let groupId: String
    /// 投稿の ID
    let skyId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    var body: some View {
        Text("準備中")
    }
}
