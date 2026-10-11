//
//  SoratomoLeftGroups.swift
//  Soramoyou
//
//  この端末で抜けたそらとものグループの記録 ⭐️
//  （leave-group 7.2・design.md の「SoratomoLeftGroups」・要件 5.3・5.6・5.7）
//
//  - 利用者ごとに UserDefaults の `soratomo.leftGroups.{uid}` へ、グループ ID の JSON の配列を残す
//    （保存の仕方は SoratomoReportedSkies にそろえた: 利用者ごとのキー・JSON の配列・上限）
//  - 一覧（オフラインのキャッシュを含む）と古い通知から、抜けたグループを開かないために使う
//  - メモリに持たず、毎回 UserDefaults を読む（件数が小さい）
//  - サインアウトでは消さない（同じ人が入り直したときも隠す）。退会の手順にも足さない（退会を変えない）
//  - ⚠️ ログ・計測にグループ ID を出さない（要件 11.1）
//

import Foundation

/// この端末で抜けたグループ（利用者ごとに UserDefaults の `soratomo.leftGroups.{uid}` に残す）
///
/// - 外す時点: ①この端末で同じグループへの参加が成功したとき。②一覧の読み込みで、サーバーが
///   メンバーだと確かめたとき（別の端末で入り直した）。
/// - 1 人あたり最大 `maxCount` 件。超えたら古いものから捨てる。
///
/// `UserDefaults` は `Sendable` ではないので `@unchecked` にしている。`UserDefaults` 自体は
/// スレッド安全（Apple の文書）で、この型が持つのはその参照 1 本だけ（自分の可変の状態は無い）。
struct SoratomoLeftGroups: @unchecked Sendable {
    /// 1 人あたりに残す件数の上限
    static let maxCount = 50

    /// 記録の置き場（テストで差し替える）
    private let defaults: UserDefaults

    /// - Parameter defaults: 記録の置き場。既定は `.standard`
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 利用者ごとの記録のキー
    static func storageKey(uid: String) -> String {
        "soratomo.leftGroups.\(uid)"
    }

    /// その利用者が、この端末でそのグループを抜けたか
    /// - Parameters:
    ///   - groupId: グループ ID
    ///   - uid: 利用者の uid
    func contains(_ groupId: String, uid: String) -> Bool {
        stored(uid: uid).contains(groupId)
    }

    /// 抜けたグループを足す（抜けるが確定したとき）
    ///
    /// その利用者の記録の末尾に足して端末に残す。すでにあれば末尾へ移す（最新の扱い）。
    /// 上限を超えたら古いものから捨てる。
    /// - Parameters:
    ///   - groupId: 抜けたグループ ID
    ///   - uid: 抜けた利用者の uid
    func insert(_ groupId: String, uid: String) {
        var list = stored(uid: uid).filter { $0 != groupId }
        list.append(groupId)
        if list.count > Self.maxCount {
            list.removeFirst(list.count - Self.maxCount)
        }
        save(list, uid: uid)
    }

    /// 抜けたグループを記録から外す（入り直したとき）
    ///
    /// 記録に無ければ何もしない。
    /// - Parameters:
    ///   - groupId: 入り直したグループ ID
    ///   - uid: 利用者の uid
    func remove(_ groupId: String, uid: String) {
        let list = stored(uid: uid)
        guard list.contains(groupId) else { return }
        save(list.filter { $0 != groupId }, uid: uid)
    }

    /// 端末に残した記録（古い順）。無い・読めないときは空
    private func stored(uid: String) -> [String] {
        guard let data = defaults.data(forKey: Self.storageKey(uid: uid)),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return list
    }

    /// 記録を端末に書く
    private func save(_ list: [String], uid: String) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.storageKey(uid: uid))
        }
    }
}
