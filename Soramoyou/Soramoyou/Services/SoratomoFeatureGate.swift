//
//  SoratomoFeatureGate.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の入口と設定を出すかの判定 ⭐️
//  （tasks 10.6・design.md の SoratomoFeatureGate・要件 1.1・1.2・1.4・1.5・10.10・10.14）
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
/// FirebaseAuth を直接呼ばずにこの窓口を通すのは、単体テストでログイン状態とクレームを差し替えるため。
@MainActor
protocol SoratomoClaimsProviding {
    /// いまログインしているアカウントの種類。ログインしていなければ nil
    func currentAccountKind() -> SoratomoAccountKind?
    /// ID トークンのクレーム（カスタムクレームを含む）を読む
    /// - Parameter forceRefresh: true ならキャッシュを使わず、サーバーからトークンを取り直す
    func claims(forceRefresh: Bool) async throws -> [String: Any]
}

/// 本番の窓口（FirebaseAuth の現在のユーザー）
@MainActor
struct FirebaseSoratomoClaimsProvider: SoratomoClaimsProviding {
    /// 判定の途中でログアウトしていたとき
    struct SignedOutError: Error {}

    func currentAccountKind() -> SoratomoAccountKind? {
        guard let user = Auth.auth().currentUser else { return nil }
        // 匿名かどうかは email の有無で決める（SettingsViewModel の先例: この app のサインイン方式は
        // メール/パスワードと匿名の 2 つだけで、匿名ユーザーは email が必ず nil）
        return user.email == nil ? .anonymous : .registered
    }

    func claims(forceRefresh: Bool) async throws -> [String: Any] {
        guard let user = Auth.auth().currentUser else { throw SignedOutError() }
        return try await user.getIDTokenResult(forcingRefresh: forceRefresh).claims
    }
}

// MARK: - 判定

/// そらともの機能フラグの判定
///
/// ID トークンのカスタムクレーム `soratomoBeta == true` のときだけ有効にする。
/// 利用者やビルドの種類（Debug / Release）にかかわらず、クレームの有無だけで決める。
///
/// - 未ログイン・匿名アカウントは無効。クレームの取得に失敗したときも無効に倒す
/// - 判定が済むまで（`unknown` の間）は入口を出さない
/// - ⚠️ DEBUG ビルドでも例外を設けない（`SkyMotionAccess` は DEBUG で常に表示するが、そらともは違う）。
///   クレームの無い開発者に入口を出しても、書き込みがすべてルール（`isSoratomoUser()`）で拒否されるため
/// - 起動ごとの最初のトークンの取得だけ、強制的に更新する。クレームを付けた直後でも、
///   ログインし直さずに使えるようにするため。以後はキャッシュ済みのトークンを読む
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
        /// クレーム `soratomoBeta` が無い（または true でない）
        case claimMissing
        /// トークンを取得できなかった（通信できないなど）
        case tokenUnavailable
    }

    /// 判定の状態
    enum State: Equatable {
        /// まだ判定していない（入口を出さない）
        case unknown
        case enabled
        case disabled(DisabledReason)
    }

    /// 機能フラグのカスタムクレームの名前。⚠️ ルール・Functions・付与のスクリプトと同じ名前にする
    static let claimKey = "soratomoBeta"

    /// いまの判定
    @Published private(set) var state: State = .unknown

    /// 入口と設定を出してよいか（`state == .enabled` のときだけ true）
    var isEnabled: Bool {
        state == .enabled
    }

    private let provider: SoratomoClaimsProviding

    /// この起動で、まだトークンの強制的な更新に成功していないか
    private var needsForcedRefresh = true

    /// 評価の世代。新しい評価と `reset()` で進める
    ///
    /// トークンの取得を待っている間にサインアウトや別の評価があったとき、古い評価の結果で
    /// 状態を上書きしないために使う（サインアウト後に「有効」へ戻るのを防ぐ）。
    private var generation = 0

    /// - Parameter provider: アカウントの窓口（テストではモックを渡す）
    init(provider: SoratomoClaimsProviding) {
        self.provider = provider
    }

    /// 本番の窓口（FirebaseAuth）で作る
    ///
    /// 引数の既定値（`= FirebaseSoratomoClaimsProvider()`）にしないのは、既定値の式がメインアクターの外で
    /// 評価される扱いになり、メインアクター専用の窓口を作れないため（コンパイルエラーになる）。
    convenience init() {
        self.init(provider: FirebaseSoratomoClaimsProvider())
    }

    /// 現在のログイン状態とトークンから評価し直す
    /// - Returns: 評価した後の状態（待っている間に新しい評価やリセットがあれば、そちらの状態）
    @discardableResult
    func evaluate() async -> State {
        generation += 1
        let evaluating = generation

        guard let kind = provider.currentAccountKind() else {
            return apply(.disabled(.signedOut), evaluatedAt: evaluating)
        }
        guard kind == .registered else {
            return apply(.disabled(.anonymous), evaluatedAt: evaluating)
        }

        let forceRefresh = needsForcedRefresh
        let result: State
        do {
            let claims = try await provider.claims(forceRefresh: forceRefresh)
            if forceRefresh {
                // 強制的な更新に成功したら、この起動ではもう強制しない（失敗したら次の評価でもう一度強制する）
                needsForcedRefresh = false
            }
            // 真偽値の true のときだけ有効（文字列の "true" などは無効。ルールの `== true` と同じ）
            result = claims[Self.claimKey] as? Bool == true ? .enabled : .disabled(.claimMissing)
        } catch {
            result = .disabled(.tokenUnavailable)
        }
        return apply(result, evaluatedAt: evaluating)
    }

    /// サインアウト時に判定を戻す（`unknown` にして入口を隠す）
    func reset() {
        generation += 1
        state = .unknown
    }

    /// 評価した世代がいまの世代のときだけ状態に反映する
    private func apply(_ newState: State, evaluatedAt evaluating: Int) -> State {
        guard evaluating == generation else { return state }
        state = newState
        return newState
    }
}
