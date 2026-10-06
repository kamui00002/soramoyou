//
//  NetworkStatusMonitor.swift
//  Soramoyou
//
//  通信の有無をアプリ全体で共有する監視 ⭐️
//  （tasks 10.5・design.md の NetworkStatusMonitor・要件 2.6・4.9・12.1・12.2）
//

import Combine
import Foundation
import Network

/// 通信の有無をアプリ全体で共有する監視（OS の通信経路の監視 `NWPathMonitor` を使う）
///
/// そらともの作成・参加・投稿・削除・表示名の保存の事前確認と、タイムラインのオフラインの表示から使う。
///
/// ⚠️ `isOnline == true` でも、実際には届かないことがある（Wi-Fi にはつながっているが外へ出られない、など）。
///    事前確認を通った後も、サービスの失敗を通信のエラー（`SoratomoError.network`）として拾う前提で使うこと。
///    この監視は「明らかに通信できないときに、送る前に止める」ためのもの。
@MainActor
final class NetworkStatusMonitor: ObservableObject {
    /// アプリ全体で共有する監視
    static let shared = NetworkStatusMonitor()

    /// 通信できる状態か（`NWPath.status == .satisfied`）
    ///
    /// 最初の経路の通知が届くまでは true にしておく。false で始めると、起動直後の操作が
    /// 実際には通信できるのに「オフライン」で止まってしまうため（届かなかったときはサービスの失敗で拾える）。
    @Published private(set) var isOnline: Bool

    /// OS の通信経路の監視（固定値で作ったときは nil）
    private let monitor: NWPathMonitor?

    private init() {
        isOnline = true
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // 監視の通知は専用のキューで届くので、メインアクターに移してから状態を変える
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.update(isOnline: online)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.soramoyou.network-status"))
    }

    /// テストとプレビュー用: 監視せず、決めた値のまま変わらない監視を作る
    /// - Parameter fixedIsOnline: 通信できる状態として扱うか
    init(fixedIsOnline: Bool) {
        isOnline = fixedIsOnline
        monitor = nil
    }

    deinit {
        monitor?.cancel()
    }

    /// 値が変わったときだけ公開する（同じ値で画面を描き直さない）
    private func update(isOnline online: Bool) {
        if isOnline != online {
            isOnline = online
        }
    }
}
