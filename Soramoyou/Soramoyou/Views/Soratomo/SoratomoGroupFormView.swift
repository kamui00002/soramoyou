//
//  SoratomoGroupFormView.swift
//  Soramoyou
//
//  ⭐️ 仮の行き先（tasks 13.1 で置いた骨組み）。中身は 13.2・13.3 の担当（b1）が作る。
//  ⚠️ init のシグネチャは変えない（呼び出し側の SoratomoRootView などを、担当は触らないため）。
//     足したいものがあれば、変えずに「共有ファイルへの追加依頼」として報告する。
//

import SwiftUI

/// 作成と参加のどちらのフォームか（一覧のシートの `item` に使う）
enum SoratomoGroupFormMode: String, Identifiable {
    /// グループを作る
    case create
    /// 招待コードで参加する
    case join

    var id: String { rawValue }
}

/// グループの作成と、招待コードでの参加のフォーム（一覧からシートで出す）
///
/// 表示名の事前入力（13.2）→ 作成か参加（13.3）→ 通知の事前説明（12.2）までを、このシートの中で行う。
/// 成功したら、進む先のパスを `onCompleted` で返す（一覧がルーターのパスに入れる）。
/// - 作成の成功: `[.timeline(groupId:), .invite(groupId:)]`（招待の画面から戻るとタイムライン）
/// - 参加の成功（既存のメンバーだった場合も）: `[.timeline(groupId:)]`
/// 閉じるだけのときは `onCancel`。
struct SoratomoGroupFormView: View {
    /// 作成か参加か
    let mode: SoratomoGroupFormMode
    /// サービスの容れ物
    let dependencies: SoratomoDependencies
    /// 成功したときに、進む先のパスを渡す
    let onCompleted: ([SoratomoDestination]) -> Void
    /// 何もせずに閉じるとき
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Text("準備中")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる", action: onCancel)
                    }
                }
        }
    }
}
