// ⭐️ 投稿に使った写真の出どころ（計装のみ・Firestore には保存しない）
import Foundation

/// 写真の入手経路。判定ゲート（アプリ内カメラ経由の投稿比率）を測るために計装へ載せる。
///
/// ⚠️ 既存の `source` は「どの画面から操作したか」の意味で使われているため、
///    名前の衝突を避けて属性名は `photo_source` にしている。
enum PhotoSource: String {
    /// 写真ライブラリ（PHPicker）から選んだ。合成投稿・下書き再開もこちら。
    case library
    /// アプリ内の空カメラで撮った。
    case camera
}
