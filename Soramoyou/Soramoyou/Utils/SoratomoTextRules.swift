//
//  SoratomoTextRules.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の文字数の規則 ⭐️
//  グループ名・表示名・キャプションの検証を純関数で持つ（tasks 10.3・要件 2.2・2.3・6.3・6.4・18.2・18.3）。
//

import Foundation

/// 文字数の検証に失敗した理由
enum SoratomoValidationError: Error, Equatable {
    /// 前後の空白を除くと空（空白だけを含む）
    case empty
    /// 上限を超えている（`max` はコードポイント数の上限）
    case tooLong(max: Int)
}

/// 表示名の事前入力で確定できる表示名（前後の空白を除いた 1〜20 文字）
///
/// `SoratomoTextRules.validateDisplayName` だけが作る。保存の窓口（`SoratomoProfileService`・tasks 11.5）は
/// この型しか受け取らないので、検証を通っていない文字列を保存できない。
struct SoratomoDisplayName: Equatable, Sendable {
    /// 前後の空白を除いた 1〜20 文字（コードポイント数）
    let value: String

    fileprivate init(value: String) {
        self.value = value
    }
}

/// そらともの文字数の規則
///
/// ⚠️ 文字数は Unicode のコードポイント数（`unicodeScalars.count`）で数える。
///    - `String.count`（書記素＝見た目の 1 文字）は使わない。Functions（`soratomoCore.js` の
///      `codePointLength` = `Array.from(s).length`）と Firestore のルール（正規表現の回数指定 `{1,100}`）が
///      どちらもコードポイントで数えるため、アプリだけ書記素で数えると「アプリは通すのにサーバーが拒否する」がおきる。
///    - `utf16.count` も使わない。ルールの `size()` は UTF-16 の単位で数える（絵文字 1 つが 2）ため、
///      キャプションのルールは回数指定に決めた（research.md の要確認 1・2026-10-01）。
///    - 例: 絵文字「☀」は 1、「👨‍👩‍👧」（3 人の絵文字を結合文字でつないだもの）は 5、「が」を「か」＋濁点で書くと 2。
enum SoratomoTextRules {
    // MARK: - 上限

    /// グループ名の上限（要件 2.2）。⚠️ Functions の `GROUP_NAME_MAX`（soratomoCore.js）と一致させる
    static let groupNameMax = 30
    /// 表示名の事前入力の上限（要件 18.2）。既存のプロフィール編集の上限（50 文字）とは別
    static let displayNameMax = 20
    /// キャプションの上限（要件 6.3）。⚠️ Functions の入力検査（`soratomoCore.js` の `CAPTION_MAX`・`validateSkyInput`）と一致させる
    static let captionMax = 100

    /// 名前の前後から取り除く文字（空白と改行）
    ///
    /// Swift の `whitespacesAndNewlines` に U+FEFF（ゼロ幅の改行しない空白）を足したもの。
    /// Functions は JavaScript の `trim()` で前後を除き、`trim()` は U+FEFF も除く。
    /// アプリ側で除く文字を JavaScript より広くしておけば、アプリが送った名前をサーバーが
    /// さらに削ることは無く、アプリとサーバーで数えた文字数が食い違わない。
    private static let trimmedCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    // MARK: - 数え方

    /// 文字数（Unicode のコードポイント数）
    /// - Parameter text: 数える文字列
    /// - Returns: コードポイント数
    static func length(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    // MARK: - グループ名

    /// グループ名を検証する（要件 2.2・2.3）
    /// - Parameter raw: 入力されたままのグループ名
    /// - Returns: 成功なら前後の空白を除いた名前。空白だけなら `.empty`、30 文字を超えたら `.tooLong`
    static func validateGroupName(_ raw: String) -> Result<String, SoratomoValidationError> {
        validateName(raw, max: groupNameMax)
    }

    // MARK: - 表示名

    /// 表示名の事前入力を検証する（要件 18.2・18.3）
    /// - Parameter raw: 入力されたままの表示名
    /// - Returns: 成功なら前後の空白を除いた表示名。空白だけなら `.empty`、20 文字を超えたら `.tooLong`
    static func validateDisplayName(_ raw: String) -> Result<SoratomoDisplayName, SoratomoValidationError> {
        validateName(raw, max: displayNameMax).map { SoratomoDisplayName(value: $0) }
    }

    // MARK: - キャプション

    /// キャプションから改行を取り除く（要件 6.3）
    ///
    /// 取り除くのは `CharacterSet.newlines`（LF・VT・FF・CR・U+0085・U+2028・U+2029）。
    /// Firestore のルールが拒否する改行類（CR・LF・U+0085・U+2028・U+2029）をすべて含むので、
    /// ここを通したキャプションは改行の検査でルールに拒否されない。
    /// 改行は空白に置き換えず、詰める（要件 6.3「入力された改行を取り除く」）。
    /// - Note: 空になったキャプションは、保存のときに項目ごと省く（ルールは「無い」か「1〜100 文字」だけを通す）。
    /// - Parameter raw: 入力されたままのキャプション
    /// - Returns: 改行を除いたキャプション
    static func sanitizeCaption(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { !CharacterSet.newlines.contains($0) })
    }

    /// 改行を除いたキャプションが上限（100 文字）以内か（要件 6.3・6.4）
    /// - Parameter sanitized: `sanitizeCaption` を通したキャプション
    /// - Returns: 0〜100 文字なら true（超えている間は投稿を確定できなくする）
    static func isCaptionWithinLimit(_ sanitized: String) -> Bool {
        length(sanitized) <= captionMax
    }

    // MARK: - Private

    /// 前後の空白を除いて 1〜`max` 文字かを確かめる（グループ名と表示名で共通）
    private static func validateName(_ raw: String, max: Int) -> Result<String, SoratomoValidationError> {
        let name = raw.trimmingCharacters(in: trimmedCharacters)
        let count = length(name)
        if count == 0 {
            return .failure(.empty)
        }
        if count > max {
            return .failure(.tooLong(max: max))
        }
        return .success(name)
    }
}
