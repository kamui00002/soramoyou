//
//  SoratomoInviteCode.swift
//  Soramoyou
//
//  そらとものグループの招待コード ⭐️
//  入力の正規化（全角→半角・大文字化・空白とハイフン類の除去）と表示の形を持つ（tasks 10.3・要件 3.4・4.1〜4.3）。
//

import Foundation

/// そらとものグループの招待コード（字種の 8 文字）
///
/// `parse(userInput:)` だけが作る。正規化と形の検査を通った値しか存在しないので、
/// 参加の窓口（`SoratomoGroupService.joinGroup`・tasks 11.1）に形の違うコードは渡らない（要件 4.3）。
/// サーバーから受け取ったコードも `parse(userInput:)` で読む（正規化済みの値はそのまま通る）。
struct SoratomoInviteCode: Hashable, Sendable {
    // MARK: - 定数

    /// 招待コードの字種（32 文字）。読み間違えやすい 0・O・1・I を除いている（要件 3.1）
    ///
    /// ⚠️ Functions の `INVITE_ALPHABET`（soratomoCore.js）と必ず一致させること。片方だけ変えると、
    ///    アプリが「形が違う」と弾くコードをサーバーが発行する（またはその逆）。
    static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    /// 招待コードの長さ（要件 3.1）。⚠️ Functions の `INVITE_CODE_LENGTH` と一致させる
    static let length = 8

    /// 入力で区切りとして無視する文字（空白とハイフン類）
    ///
    /// ⚠️ Functions の `INVITE_CODE_SEPARATORS`（soratomoCore.js）と同じ集合にすること
    ///    （アプリとサーバーで「同じ入力を同じコードとみなす」ため）。
    /// - 空白: JavaScript の正規表現の `\s` と同じ文字（タブ・改行類・半角空白・U+00A0・U+1680・
    ///   U+2000〜U+200A・U+2028・U+2029・U+202F・U+205F・全角空白 U+3000・U+FEFF）
    /// - ハイフン類: 半角「-」、U+2010〜U+2015（‐‑‒–—―）、U+2212（−）、U+FE63（﹣）、U+FF0D（－）、
    ///   長音符 U+30FC（ー）と半角の U+FF70（ｰ）。日本語入力のまま「-」を打つと「ー」になるため入れている。
    ///   どれも字種に無い文字なので、除いても別のコードと誤って一致することはない。
    private static let separators: Set<Unicode.Scalar> = {
        var scalars: [UInt32] = [
            // 空白（JavaScript の \s）
            0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680,
            0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
            // ハイフン類
            0x002D, 0x2212, 0xFE63, 0xFF0D, 0x30FC, 0xFF70,
        ]
        scalars += Array(0x2000 ... 0x200A) // 空白（U+2000〜U+200A）
        scalars += Array(0x2010 ... 0x2015) // ハイフン類（‐‑‒–—―）
        return Set(scalars.compactMap(Unicode.Scalar.init))
    }()

    // MARK: - Properties

    /// 正規化済みの 8 文字（例: "ABCDEFGH"）。Firestore とサーバーに渡すのはこの値
    let rawValue: String

    /// 画面に出す形（4 文字ごとにハイフンで区切る。例: "ABCD-EFGH"・要件 3.4）
    var displayText: String {
        let half = rawValue.index(rawValue.startIndex, offsetBy: Self.length / 2)
        return "\(rawValue[..<half])-\(rawValue[half...])"
    }

    // MARK: - Init

    private init(validated rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: - 正規化

    /// 入力された招待コードを、照合できる形にそろえる（要件 4.1〜4.3）
    ///
    /// 順序は Functions の `normalizeInviteCode` と同じ:
    /// NFKC（全角→半角）→ 大文字化 → 空白とハイフン類を除去 → 8 文字かつ字種内かを確かめる。
    /// 0・O・1・I のような字種外の文字は、似た文字へ補正せずに無効にする（推測で別のグループに入れないため）。
    /// - Parameter userInput: 入力されたままの文字列
    /// - Returns: 正規化した結果が字種の 8 文字なら招待コード。そうでなければ nil（サーバーへ問い合わせない）
    static func parse(userInput: String) -> SoratomoInviteCode? {
        // NFKC: 全角の英数字・ハイフン・空白を半角にする（例: "ＡＢＣ－" → "ABC-"）
        let normalized = userInput.precomposedStringWithCompatibilityMapping.uppercased()
        // 文字数はコードポイントで数える（Functions の Array.from と同じ）
        let scalars = normalized.unicodeScalars.filter { !separators.contains($0) }
        guard scalars.count == length,
              scalars.allSatisfy({ alphabet.unicodeScalars.contains($0) })
        else {
            return nil
        }
        return SoratomoInviteCode(validated: String(scalars))
    }
}
