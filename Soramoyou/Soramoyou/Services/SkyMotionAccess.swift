// ⭐️ SkyMotionAccess.swift
// 「空を動かす」（Kling版）β の表示可否（allowlist）判定を1か所に隔離する。
//
// 設計意図:
//   - 呼び出し元（EditView）を FirebaseAuth 非依存に保つため、custom claim の読み取りを
//     このヘルパーに閉じ込める。EditView は `await SkyMotionAccess.isEnabled()` を呼ぶだけ。
//   - 多層防御の「UI 層」。実際のアップロード/ジョブ作成は storage.rules / firestore.rules /
//     Cloud Functions 側でも同じ claim(skyMotionBeta) を要求するため、ここはあくまで
//     「未許可ユーザーにボタンを見せない」ための表示制御（迷わせない）にすぎない。
//
// 公開範囲（重要）: DEBUG では常に表示（開発者のローカル検証用）。
//   Release/TestFlight では allowlist（custom claim `skyMotionBeta==true`）保有者のみ表示。
//   ＝ TestFlight 内部テストで、許可済みのテストアカウントだけがこの導線を使える状態にする。
//   プライバシーポリシー本文更新・写真送信の同意UI・App Privacy label は公開β時の宿題
//   （設計書 docs/sky-motion-design.md §7）。外部テスター追加・一般公開の前に必須。

import FirebaseAuth

enum SkyMotionAccess {
    /// このビルド/ユーザーで「空を動かす（Kling版）」導線を表示してよいか。
    /// - DEBUG: 常に true（開発者はローカルで常時検証可能）。
    /// - Release/TestFlight: custom claim `skyMotionBeta==true`（allowlist）保有者のみ true。
    ///   取得失敗・未ログイン・claim 無しはすべて false（安全側＝非表示）に倒す。
    static func isEnabled() async -> Bool {
        #if DEBUG
        return true
        #else
        guard let user = Auth.auth().currentUser else { return false }
        do {
            // キャッシュ済みトークンの claim を読む（claim は付与済み前提のため強制リフレッシュしない）。
            // 実際の生成時は SkyMotionSheet 側で forcingRefresh 済みのトークンを使う。
            let result = try await user.getIDTokenResult()
            return result.claims["skyMotionBeta"] as? Bool == true
        } catch {
            return false
        }
        #endif
    }
}
