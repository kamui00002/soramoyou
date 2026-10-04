//
//  SoratomoInviteView.swift
//  Soramoyou
//
//  ⭐️ 仮の行き先（tasks 13.1 で置いた骨組み）。中身は 13.4 の担当（b2）が作る。
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView などを、担当は触らないため）。
//     足したいものがあれば、変えずに「共有ファイルへの追加依頼」として報告する。
//

import SwiftUI

/// 招待コードの共有と再発行
///
/// グループ名・招待コード・オーナーは `observeGroup` で取り、オーナーかどうかは `dependencies.currentUid()` と
/// `ownerId` を比べて決める。
struct SoratomoInviteView: View {
    /// 表示するグループの ID
    let groupId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    var body: some View {
        Text("準備中")
    }
}
