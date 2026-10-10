//
//  SupportContact.swift ⭐️
//  Soramoyou
//
//  開発者への連絡先（設定の「お問い合わせ」・プライバシーポリシー・そらともガイドラインで使う）
//

import Foundation

/// 開発者への連絡先
///
/// 同じアドレスを画面ごとに直書きしない（変えるときに 1 か所だけ直せば揃うようにする）。
/// アプリの外（App Store の連絡先・Web のプライバシーポリシー）にも同じアドレスを載せているので、変えるときはそちらも直す。
enum SupportContact {
    /// お問い合わせのメールアドレス
    static let email = "soramoyou.app@gmail.com"
}
