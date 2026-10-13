//
//  SoratomoFeatureGate.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の入口と設定を出すかの判定 ⭐️
//  （tasks 10.6・design.md の SoratomoFeatureGate・要件 1.1・1.2・1.4・1.5・10.10・10.14）
//  1.15.0 の一般公開で、クレームの判定から「登録済みでログイン」の判定に替えた（soratomo-public-launch 6.1）
//

import Combine
import FirebaseAuth
import Foundation

// MARK: - アカウントの窓口（テストで差し替える）

/// 判定に使うアカウントの種類
enum SoratomoAccountKind: Equatable {
    /// メールアドレスで登録したアカウント
    case registered
    /// 匿名アカウント（ゲスト）
    case anonymous
}

/// 判定が読むアカウントの窓口
///
/// FirebaseAuth を直接呼ばずにこの窓口を通すのは、単体テストでログイン状態を差し替えるため。
/// ID トークン（クレーム）を読む口は持たない（1.15.0 の一般公開で判定に使わなくなった）。
@MainActor
protocol SoratomoAccountProviding {
    /// いまログインしているアカウントの種類。ログインしていなければ nil
    func currentAccountKind() -> SoratomoAccountKind?
}

/// 本番の窓口（FirebaseAuth の現在のユーザー）
@MainActor
struct FirebaseSoratomoAccountProvider: SoratomoAccountProviding {
    func currentAccountKind() -> SoratomoAccountKind? {
        guard let user = Auth.auth().currentUser else { return nil }
        // 匿名かどうかは email の有無で決める（SettingsViewModel の先例: この app のサインイン方式は
        // メール/パスワードと匿名の 2 つだけで、匿名ユーザーは email が必ず nil）
        return user.email == nil ? .anonymous : .registered
    }
}

// MARK: - 判定

/// そらともを使えるかの判定
///
/// 登録済みのアカウントでログインしていれば有効にする。ID トークンもクレームも読まず、通信もしないので、
/// 起動時に通信できなくても、登録済みなら入口が出る（soratomo-public-launch 要件 2.1〜2.3）。
///
/// - 未ログイン・匿名アカウントは無効
/// - 判定が済むまで（`unknown` の間）は入口を出さない。ログイン中の `unknown` は、ログインが確定してから
///   最初の `evaluate()` までの一瞬だけ。未ログイン・ゲストの間は評価しないので `unknown` のまま（入口は隠れる）
/// - ルール（`isSoratomoUser()`）と Functions（`requireSoratomoUser`）も、同じ「登録済みでログイン（匿名は拒否）」を
///   要求する。3 か所は同じ条件にしておく（ずれると、入口は出るのに読み書きが拒否される）
/// - 1.14.x まではカスタムクレームで判定していた。1.15.0 で一般公開した（soratomo-public-launch）
///
/// アプリの起点（`SoramoyouApp`）で環境オブジェクトとして渡す。ゲスト中の画面（`GuestTabView`）も
/// 同じ `HomeView` を使うので、同じオブジェクトを読む。評価とサインアウト時の `reset()` の呼び出しは tasks 14.1。
@MainActor
final class SoratomoFeatureGate: ObservableObject {
    /// 無効の理由
    enum DisabledReason: Equatable {
        /// ログインしていない
        case signedOut
        /// 匿名アカウント
        case anonymous
    }

    /// 判定の状態
    enum State: Equatable {
        /// まだ判定していない（入口を出さない）
        case unknown
        case enabled
        case disabled(DisabledReason)
    }

    /// いまの判定
    @Published private(set) var state: State = .unknown

    /// 入口と設定を出してよいか（`state == .enabled` のときだけ true）
    var isEnabled: Bool {
        state == .enabled
    }

    private let provider: SoratomoAccountProviding

    /// - Parameter provider: アカウントの窓口（テストではモックを渡す）
    init(provider: SoratomoAccountProviding) {
        self.provider = provider
    }

    /// 本番の窓口（FirebaseAuth）で作る
    ///
    /// 引数の既定値（`= FirebaseSoratomoAccountProvider()`）にしないのは、既定値の式がメインアクターの外で
    /// 評価される扱いになり、メインアクター専用の窓口を作れないため（コンパイルエラーになる）。
    convenience init() {
        self.init(provider: FirebaseSoratomoAccountProvider())
    }

    /// 現在のログイン状態から評価し直す（同期。通信しない）
    /// - Returns: 評価した後の状態
    @discardableResult
    func evaluate() -> State {
        guard let kind = provider.currentAccountKind() else {
            state = .disabled(.signedOut)
            return state
        }
        // `default` を置かない: アカウントの種類が増えたら、ここで有効にするかを決め直させる
        switch kind {
        case .registered:
            state = .enabled
        case .anonymous:
            state = .disabled(.anonymous)
        }
        return state
    }

    /// サインアウト時に判定を戻す（`unknown` にして入口を隠す）
    func reset() {
        state = .unknown
    }
}
