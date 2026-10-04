//
//  SoratomoMembersView.swift
//  Soramoyou
//
//  ⭐️ 仮の行き先（tasks 13.1 で置いた骨組み）。中身は 13.9 の担当（b5）が作る。
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView などを、担当は触らないため）。
//     足したいものがあれば、変えずに「共有ファイルへの追加依頼」として報告する。
//

import SwiftUI

/// グループのメンバー一覧
struct SoratomoMembersView: View {
    /// 表示するグループの ID
    let groupId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    var body: some View {
        Text("準備中")
    }
}
