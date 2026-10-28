//
//  PostReactionButtons.swift ⭐️
//  Soramoyou
//
//  いいね（❤️）・お気に入り（🔖）の共通ボタン
//  1.18.0 PR-H「2: いいね・🔖 の共通ボタン」
//
//  これまでは 3 か所（ホームなどのカード＝PostCard・投稿の詳細＝PostDetailView・ギャラリーの詳細＝GalleryDetailView）に
//  同じようなボタンを直書きしていた。見た目は今のまま変えずにこの部品へ集め、次の 3 つをそろえて足す。
//  - 触覚: `Haptics.play`（いいねを付けたときだけ一段強い `.likeOn`・それ以外は今までと同じ強さの `.tap`）
//  - 弾み: 付けたときにアイコンが「ぽよん」と弾む（iOS 17 以上・「視差効果を減らす」が OFF のときだけ）
//  - 数字: いいね数が変わるとき、数字がくるっと入れ替わる（`.contentTransition(.numericText())`）
//
//  ⚠️ ここは「見た目と押したときの手ごたえ」だけを持つ部品にする。いいね済みか・件数・押したときの処理は
//     呼び出し側から値で受け取る（`@EnvironmentObject` の LikeManager / FavoriteManager は読まない）。
//     付けるかどうか・ゲストのときの案内・通信中の連打を捨てるのは、今までどおり LikeManager / FavoriteManager の仕事。
//

import SwiftUI

// MARK: - 見た目の種類

/// いいね・🔖 ボタンの見た目の種類
///
/// 見た目はカードと詳細の 2 通りなので、その 2 つに名前を付ける（どちらも今の見た目そのまま）。
enum PostReactionButtonStyle {
    /// カード（PostCard のアクション行）
    /// アイコンは 16pt・数字は丸い文字の .caption・OFF の色は textTertiary
    case card
    /// 詳細（投稿の詳細・ギャラリーの詳細）
    /// アイコンと数字を並べた Label・大きさは .headline・OFF の色は textSecondary
    case detail

    /// OFF（付いていない）ときの色
    var offColor: Color {
        switch self {
        case .card:
            DesignTokens.Colors.textTertiary
        case .detail:
            DesignTokens.Colors.textSecondary
        }
    }
}

// MARK: - 押したときの判定（純粋な関数）

/// いいね・🔖 ボタンを押したときの「触覚の強さ」と「弾ませるか」の判定
///
/// ボタンの中（View）からこの関数を呼ぶ。UIKit も SwiftUI の View も使わない**純粋な関数**にしているのは、
/// 判定を単体テストで固定するため（`PostReactionButtonFeedbackTests`）。
///
/// ## 弾ませる条件（なぜ `isLiked` をそのまま弾みの合図にしないか）
/// 「付けるタップをした」かつ「その後に画面上で ON になった」ときだけ弾ませる。
/// （LikeManager は楽観更新＝サーバーの返事を待たず先に画面を ON にするので、ここでの「ON」は書き込みの成功を意味しない。
///   書き込みに失敗したときは、弾んだ後に元の OFF へ戻る。）
/// - `isLiked` をそのまま `.symbolEffect(.bounce, value:)` の value にすると、フィードを読み込んだとき
///   （`LikeManager.checkLikeStatus` がいいね済みの投稿を false → true にする）に、画面中のハートが一斉に弾んでしまう。
/// - ゲスト（押してもログインの案内が出るだけで付かない）や、通信中の連打（LikeManager が捨てる）でも弾まないようにしたい。
/// そこで、押したときに「弾み待ち」を立てておき（`shouldWaitForBounce`）、ON になったのを見たときに
/// 弾み待ちだったら弾ませる（`shouldBounce`）、という 2 段にしている。
enum PostReactionButtonFeedback {
    /// 押したときに鳴らす触覚の場面
    /// - Parameters:
    ///   - isLike: いいねのボタンか（false なら 🔖）
    ///   - isOnBefore: 押す前に付いていたか
    ///   - hasAction: 押したときの処理があるか（検索の画面のカードは nil＝押しても何も起きない）
    /// - Returns: いいねを「付ける」タップ（押す前が OFF・処理あり）なら `.likeOn`、それ以外（いいねを外す・処理なし・🔖）は `.tap`
    static func haptic(isLike: Bool, isOnBefore: Bool, hasAction: Bool) -> Haptics.Kind {
        if isLike, !isOnBefore, hasAction {
            return .likeOn
        }
        return .tap
    }

    /// 押したときに「弾み待ち」を立てるか
    /// - Parameters:
    ///   - isOnBefore: 押す前に付いていたか
    ///   - hasAction: 押したときの処理があるか
    /// - Returns: 「付ける」タップ（押す前が OFF・処理あり）なら true（いいね・🔖 共通）
    static func shouldWaitForBounce(isOnBefore: Bool, hasAction: Bool) -> Bool {
        !isOnBefore && hasAction
    }

    /// 付いている状態が変わったのを見たときに、弾ませるか
    /// - Parameters:
    ///   - waitingForBounce: 弾み待ちか（付けるタップをした後か）
    ///   - isOnNow: 変わった後に付いているか
    /// - Returns: 弾み待ちで、しかも ON になったときだけ true
    static func shouldBounce(waitingForBounce: Bool, isOnNow: Bool) -> Bool {
        waitingForBounce && isOnNow
    }
}

// MARK: - いいねボタン

/// いいね（❤️）のボタン（アイコン＋いいね数）
///
/// ## 使い方
/// ```swift
/// // カード
/// PostLikeButton(isLiked: isLiked, count: likeCount ?? post.likesCount, style: .card, action: onLikeTapped)
/// // 詳細
/// PostLikeButton(isLiked: likeManager.isLiked(post.id), count: likeManager.likeCount(for: post), style: .detail) {
///     Task { await likeManager.toggleLike(post: post, source: "post_detail", method: .button) }
/// }
/// ```
///
/// - 読み上げ（VoiceOver）のラベルは足さない（今の読み上げを変えない）。
/// - 写真の 2 回タップでいいねを付けたときは、このボタンは弾まない（弾み待ちを立てるのはこのボタンを押したときだけ。
///   2 回タップは写真の中央に大きなハートが出る＝PostCard の `doubleTapHeart`）。
struct PostLikeButton: View {
    // MARK: - Properties

    /// いいね済みか
    let isLiked: Bool
    /// 表示するいいね数
    let count: Int
    /// 見た目の種類（カード / 詳細）
    let style: PostReactionButtonStyle
    /// 押したときの処理（nil なら押しても軽い触覚だけで何も起きない＝検索の画面のカード）
    let action: (() -> Void)?

    /// 弾み待ち（付けるタップをした後、まだ ON になったのを見ていない）
    @State private var isWaitingForBounce = false
    /// 弾みの回数（`.symbolEffect(.bounce, value:)` の合図。1 増えるたびに 1 回弾む）
    @State private var bounceTrigger = 0
    /// 「視差効果を減らす」が ON か（ON のときは色・数字を一瞬で変える）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        Button {
            handleTap()
        } label: {
            label
        }
        .buttonStyle(.plain)
        // ON / OFF が変わったのを見て、弾ませるか決める（理由は PostReactionButtonFeedback の説明）
        .onChange(of: isLiked) { isLikedNow in
            if PostReactionButtonFeedback.shouldBounce(waitingForBounce: isWaitingForBounce, isOnNow: isLikedNow) {
                bounceTrigger += 1
            }
            // ON になったとき（弾んだ・弾まなかったどちらも）も、OFF になったときも、弾み待ちは下ろす
            isWaitingForBounce = false
        }
    }

    // MARK: - Label

    /// 見た目の種類ごとの中身
    /// ⚠️ 修飾子の並び（色・動きをどこに付けるか）は、置き換える前の 3 か所の並びをそのまま残している（見た目を変えないため）。
    @ViewBuilder
    private var label: some View {
        switch style {
        case .card:
            // 今の PostCard と同じ: 色は HStack の外側、ハートの切り替えの動きはアイコンにだけ付ける
            HStack(spacing: 6) {
                icon
                    .font(.system(size: 16, weight: .medium))
                    .animation(Motion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: isLiked)
                countText
                    // Dynamic Type 対応: .caption はユーザーの文字サイズ設定に追従
                    .font(.system(.caption, design: .rounded, weight: .semibold))
            }
            .foregroundColor(isLiked ? DesignTokens.Colors.softPink : style.offColor)

        case .detail:
            // 今の詳細 2 か所と同じ: Label（数字＋アイコン）に大きさ・色・切り替えの動きを付ける
            // 今は `Label("数字", systemImage:)` の形だったが、数字とアイコンにそれぞれ動き（数字の入れ替わり・弾み）を
            // 付けるため、中身を自分で渡す `Label { 数字 } icon: { アイコン }` の形にした（並び・大きさは同じ）。
            Label {
                countText
            } icon: {
                icon
            }
            .font(.headline)
            .foregroundColor(isLiked ? DesignTokens.Colors.softPink : style.offColor)
            .animation(Motion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: isLiked)
        }
    }

    /// ハートのアイコン（付けたときに弾む）
    private var icon: some View {
        Image(systemName: isLiked ? "heart.fill" : "heart")
            .modifier(PostReactionBounceModifier(trigger: bounceTrigger))
    }

    /// いいね数（変わるとき、数字がくるっと入れ替わる）
    /// `.numericText()` は iOS 16 から使える。動きは「視差効果を減らす」が ON なら付けない（一瞬で変わる）。
    private var countText: some View {
        Text("\(count)")
            .contentTransition(.numericText())
            .animation(
                Motion.animation(.spring(response: 0.3, dampingFraction: 0.8), reduceMotion: reduceMotion),
                value: count
            )
    }

    // MARK: - Private Methods

    /// ボタンを押した → 触覚を鳴らし、付けるタップなら弾み待ちを立ててから、処理を呼ぶ
    /// （弾み待ちを処理より先に立てるのは、処理の中で ON になったのを onChange で取りこぼさないため）
    private func handleTap() {
        let hasAction = action != nil
        Haptics.play(PostReactionButtonFeedback.haptic(isLike: true, isOnBefore: isLiked, hasAction: hasAction))
        if PostReactionButtonFeedback.shouldWaitForBounce(isOnBefore: isLiked, hasAction: hasAction) {
            isWaitingForBounce = true
        }
        action?()
    }
}

// MARK: - お気に入り（🔖）ボタン

/// お気に入り（🔖）のボタン（アイコンだけ）
///
/// ❤️と違い件数は出さない（自分だけのプライベート保存なので公開する数がない＝今までと同じ）。
///
/// ## 使い方
/// ```swift
/// PostFavoriteButton(isFavorited: favoriteManager.isFavorited(post.id), style: .detail) {
///     Task { await favoriteManager.toggleFavorite(post: post, source: "post_detail") }
/// }
/// ```
struct PostFavoriteButton: View {
    // MARK: - Properties

    /// お気に入り済みか
    let isFavorited: Bool
    /// 見た目の種類（カード / 詳細）
    let style: PostReactionButtonStyle
    /// 押したときの処理（nil なら押しても軽い触覚だけで何も起きない）
    let action: (() -> Void)?

    /// 弾み待ち（付けるタップをした後、まだ ON になったのを見ていない）
    @State private var isWaitingForBounce = false
    /// 弾みの回数（`.symbolEffect(.bounce, value:)` の合図。1 増えるたびに 1 回弾む）
    @State private var bounceTrigger = 0
    /// 「視差効果を減らす」が ON か（ON のときは色を一瞬で変える）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        Button {
            handleTap()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorited ? "お気に入りから外す" : "お気に入りに追加")
        // ON / OFF が変わったのを見て、弾ませるか決める（理由は PostReactionButtonFeedback の説明）
        .onChange(of: isFavorited) { isFavoritedNow in
            if PostReactionButtonFeedback.shouldBounce(waitingForBounce: isWaitingForBounce, isOnNow: isFavoritedNow) {
                bounceTrigger += 1
            }
            // ON になったとき（弾んだ・弾まなかったどちらも）も、OFF になったときも、弾み待ちは下ろす
            isWaitingForBounce = false
        }
    }

    // MARK: - Label

    /// 見た目の種類ごとの中身
    /// ⚠️ 修飾子の並び（色と切り替えの動きのどちらが先か）は、置き換える前のカード・詳細それぞれの並びをそのまま残している。
    @ViewBuilder
    private var label: some View {
        switch style {
        case .card:
            // 今の PostCard と同じ並び: 大きさ → 切り替えの動き → 色
            icon
                .font(.system(size: 16, weight: .medium))
                .animation(Motion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: isFavorited)
                .foregroundColor(isFavorited ? DesignTokens.Colors.goldenHour : style.offColor)

        case .detail:
            // 今の詳細 2 か所と同じ並び: 大きさ → 色 → 切り替えの動き
            icon
                .font(.headline)
                .foregroundColor(isFavorited ? DesignTokens.Colors.goldenHour : style.offColor)
                .animation(Motion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value: isFavorited)
        }
    }

    /// しおりのアイコン（付けたときに弾む）
    private var icon: some View {
        Image(systemName: isFavorited ? "bookmark.fill" : "bookmark")
            .modifier(PostReactionBounceModifier(trigger: bounceTrigger))
    }

    // MARK: - Private Methods

    /// ボタンを押した → 触覚を鳴らし（🔖 は付け外しどちらも `.tap`）、付けるタップなら弾み待ちを立ててから、処理を呼ぶ
    private func handleTap() {
        let hasAction = action != nil
        Haptics.play(PostReactionButtonFeedback.haptic(isLike: false, isOnBefore: isFavorited, hasAction: hasAction))
        if PostReactionButtonFeedback.shouldWaitForBounce(isOnBefore: isFavorited, hasAction: hasAction) {
            isWaitingForBounce = true
        }
        action?()
    }
}

// MARK: - 弾み（iOS 17 以上）

/// 付けたときにアイコンを弾ませる（`.symbolEffect(.bounce, value:)`）
///
/// - `.symbolEffect` は iOS 17 から。最低 iOS 16 なので、iOS 16 では何も付けない（弾まないだけで、色・形の切り替えは今までどおり）。
/// - 「視差効果を減らす」が ON のときは、iOS 17 以上でも付けない（画面の動きで気分が悪くなる人が ON にする設定のため）。
/// - `trigger` が 1 増えるたびに 1 回弾む。画面に出たとき（最初の値）には弾まない。
private struct PostReactionBounceModifier: ViewModifier {
    /// 弾みの合図（ボタンの `bounceTrigger`）
    let trigger: Int
    /// 「視差効果を減らす」が ON か
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            // 「視差効果を減らす」ON: 弾みを付けない
            content
        } else {
            if #available(iOS 17.0, *) {
                content.symbolEffect(.bounce, value: trigger)
            } else {
                // iOS 16: `.symbolEffect` が無いので付けない
                content
            }
        }
    }
}
