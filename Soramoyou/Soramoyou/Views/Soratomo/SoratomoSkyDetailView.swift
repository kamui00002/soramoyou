//
//  SoratomoSkyDetailView.swift
//  Soramoyou
//
//  そらともの投稿詳細 ⭐️
//  （tasks 13.9・design.md の SoratomoSkyDetailView・要件 8.9・8.14・14.5・16.4・16.5）
//
//  - 投稿の中身は `dependencies.skyLookup.sky(groupId:skyId:)` から読む（タイムラインが覚えたもの）。
//    見つからなければ「表示できません」の表示にする（投稿詳細は必ずタイムラインを経由して開く）
//  - 画像は、サムネイル（タイムラインで読んだのでキャッシュにある前提）を先に出し、表示用画像が届いたら
//    その上に重ねて置き換える。ピンチとダブルタップで拡大できる（iOS 16 で動く SwiftUI の操作だけを使う）
//  - キャプションは全文を出す（行数を制限しない）
//  - 自分の投稿のときだけ、ナビゲーションバー右の「…」から削除できる（長押しに気づけない人のため）。
//    削除はタイムラインの ViewModel（`dependencies.activeTimelineViewModel`）の `delete` をそのまま使い、
//    本人かの判定（`canDelete`）・確認の文言・失敗の文言もタイムラインとそろえる
//  - 自分以外の投稿には「…」から通報とブロックを出す（release-gate 10.6）。操作・判定・文言はタイムラインの ViewModel と同じ。
//    通報が受け付けられたら知らせを閉じた後に、ブロックが保存されたらすぐに詳細を閉じる。隠す集合に当たる投稿は「表示できません」
//  - 開いている間は投稿 1 件を監視し、「もう無い」か「メンバーでなくなった」が届いたら「この投稿は表示できなくなりました」を出し、
//    覚えから外す（release-gate 10.6・要件 1.7）
//  - 投稿者の行の下にリアクションの欄（数・自分以外の投稿ならメニュー・1 人以上なら押した人の一覧の入口）を置く。
//    操作と上書きはタイムラインのリアクションの ViewModel（`dependencies.activeReactionViewModel`）を借り、数は監視の最新で出す
//    （soratomo-reactions 8.3・要件 1.1・1.6・2.4・2.5・3.1・3.5・8.7）
//  - 画像の VoiceOver の説明はキャプション。無ければ「{表示名}さんの空」
//  - ⚠️ 画像は必ず `SoratomoStorageImageProvider` と `.targetCache(SoratomoImageCache.cache(forStoragePath:))`
//    （パスは provider と同じ）で読み、processor（ダウンサンプリングなど）は付けない
//    （鍵が変わり、削除やサインアウトや抜けたときに消せなくなるため）
//  - ⚠️ init のシグネチャ（groupId:skyId:dependencies:）は変えない（呼び出し側の SoratomoRootView が使うため）
//

import Kingfisher
import SwiftUI

/// 投稿の詳細
///
/// 投稿の中身は `dependencies.skyLookup.sky(groupId:skyId:)` から読む（タイムラインが覚えたもの）。
/// 見つからなければ「表示できません」の表示にする。
struct SoratomoSkyDetailView: View {
    // MARK: - Properties

    /// 投稿のグループの ID
    let groupId: String
    /// 投稿の ID
    let skyId: String
    /// サービスの容れ物
    let dependencies: SoratomoDependencies

    /// 投稿者の表示名とアイコンの保持（容れ物は ObservableObject ではないので、変化を画面に出すため別に持つ）
    @ObservedObject private var profileStore: SoratomoProfileStore
    /// この投稿のグループのタイムラインの ViewModel（削除に使う。開いていない・別のグループなら nil）
    private let timelineViewModel: SoratomoTimelineViewModel?
    /// この投稿のグループのリアクションの ViewModel（タイムラインと同じ上書きと操作の経路・soratomo-reactions 8.3。
    /// 開いていない・別のグループなら nil）
    private let reactionViewModel: SoratomoReactionViewModel?

    /// 監視で届いた最新のリアクション（nil の間は、タイムラインの覚えの値を最初の表示にだけ使う・soratomo-reactions 要件 2.5）
    @State private var liveReactions: SoratomoReactions?
    /// 押した人の一覧のシートを出しているか（soratomo-reactions 要件 3.1）
    @State private var isShowingReactors = false

    /// 削除して閉じる途中か（閉じるまでの間に「表示できません」が一瞬出ないようにする）
    @State private var didDelete = false
    /// 監視で「もう無い」か「メンバーでなくなった」が届いたか（release-gate 10.6）
    @State private var becameUnavailable = false
    /// 画面を閉じる（削除できたらタイムラインへ戻る）
    @Environment(\.dismiss) private var dismiss

    /// 確定した拡大率（1 = 等倍）
    @State private var zoomScale: CGFloat = 1
    /// ピンチ中の拡大率の変化（指を離すと 1 に戻り、`zoomScale` に掛けて確定する）
    @GestureState private var pinchScale: CGFloat = 1
    /// 確定した画像のずらし量（拡大中だけ使う）
    @State private var panOffset: CGSize = .zero
    /// ドラッグ中のずらし量（指を離すと 0 に戻り、`panOffset` に足して確定する）
    @GestureState private var dragOffset: CGSize = .zero

    /// 拡大率の下限（等倍より小さくしない）
    private static let minZoomScale: CGFloat = 1
    /// 拡大率の上限
    private static let maxZoomScale: CGFloat = 4
    /// ダブルタップで拡大するときの拡大率
    private static let doubleTapZoomScale: CGFloat = 2.5

    // MARK: - Init

    /// - Parameters:
    ///   - groupId: 投稿のグループの ID
    ///   - skyId: 投稿の ID
    ///   - dependencies: サービスの容れ物
    init(groupId: String, skyId: String, dependencies: SoratomoDependencies) {
        self.groupId = groupId
        self.skyId = skyId
        self.dependencies = dependencies
        _profileStore = ObservedObject(wrappedValue: dependencies.profileStore)
        // 投稿詳細は必ずタイムラインを経由して開くので、そのタイムラインの ViewModel を借りる
        // （グループ ID が違えば使わない）
        if let viewModel = dependencies.activeTimelineViewModel, viewModel.groupId == groupId {
            timelineViewModel = viewModel
        } else {
            timelineViewModel = nil
        }
        // リアクションの ViewModel も同じく、グループ ID が一致するときだけ借りる（soratomo-reactions 8.3）
        if let viewModel = dependencies.activeReactionViewModel, viewModel.groupId == groupId {
            reactionViewModel = viewModel
        } else {
            reactionViewModel = nil
        }
    }

    // MARK: - Body

    var body: some View {
        // 覚えから引く（覚えは ObservableObject ではないが、詳細を開いている間に変わるのは削除だけで、
        // 削除できたらこの画面を閉じるため、ここで読み直さなくてよい）
        let sky = dependencies.skyLookup.sky(groupId: groupId, skyId: skyId)

        withActionMenu(
            Group {
                if didDelete {
                    // 削除できて閉じる途中（覚えから消えているが「表示できません」は出さない）
                    Color.clear
                } else if becameUnavailable {
                    // 開いている間に消えた・グループから外れた（要件 1.7）
                    unavailableView(message: "この投稿は表示できなくなりました")
                } else if let sky, !(timelineViewModel?.isHidden(sky) ?? false) {
                    detail(sky)
                } else {
                    // 覚えに無い・ブロックした投稿者や通報した投稿（要件 5.5・9.6）
                    unavailableView(message: "表示できません")
                }
            },
            sky: sky
        )
        .navigationTitle("空")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sky?.authorId) {
            // 投稿者の表示名とアイコンを取りに行く（取得済みなら何もしない）
            guard let authorId = sky?.authorId else { return }
            await profileStore.prefetch(uids: [authorId])
        }
        .task(id: skyId) {
            await observeSky()
        }
        .modifier(SoratomoModerationNoticeAlert(viewModel: timelineViewModel, onFinished: { dismiss() }))
        // 押した人の一覧（soratomo-reactions 8.3）。⚠️ 中身（detail）でなく、ここに付ける。中身は投稿が消えると
        // 「表示できなくなりました」に切り替わって消えるので、そこに付けるとシートが勝手に閉じ、8.7 の文を出せない
        .sheet(isPresented: $isShowingReactors) {
            reactorsSheet
        }
        // リアクションの失敗の知らせ（詳細が開いている間は詳細が出す。タイムラインは一番上のときだけ出す）
        .modifier(SoratomoReactionNoticeAlert(viewModel: reactionViewModel))
        // 画面名の記録は根の画面（SoratomoRootView）がパスの変化で 1 回だけ行う（14.3 の点検で集約）
    }

    // MARK: - 中身

    /// 開いている間、投稿 1 件を監視する（画面が消えて task が取り消されたら止める）
    ///
    /// `.gone` と `.notMember` では「表示できなくなりました」にする。`.present` は何度も届きうるので、
    /// 中のリアクションを最新として覚えるだけにする（soratomo-reactions 要件 2.5）。
    /// ほかの失敗（通信など）では、出している中身を変えない（数も最後に届いた値のまま）。
    private func observeSky() async {
        let skyLookup = dependencies.skyLookup
        let groupId = groupId
        let skyId = skyId
        let token = dependencies.skyService.observeSky(groupId: groupId, skyId: skyId) { result in
            switch result {
            case .success(.gone), .failure(.notMember):
                becameUnavailable = true
                skyLookup.forget(groupId: groupId, skyId: skyId)
            case let .success(.present(reactions)):
                liveReactions = reactions
            case .failure:
                break
            }
        }
        // 取り消されるまで待つ（Task.sleep は取り消されると投げるので、すぐに抜ける）
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        token.cancel()
    }

    /// 「…」メニューを付ける。自分の投稿なら削除だけ（判定はタイムラインと同じ `canDelete`）、
    /// 自分以外なら通報とブロック（`canModerate`・要件 5.1・5.2・9.1）
    @ViewBuilder
    private func withActionMenu(_ content: some View, sky: SoratomoSky?) -> some View {
        if didDelete || becameUnavailable {
            content
        } else if let sky, let timelineViewModel, timelineViewModel.isHidden(sky) {
            content
        } else if let sky, let timelineViewModel, timelineViewModel.canModerate(sky) {
            content.modifier(
                SoratomoSkyModerationMenu(
                    viewModel: timelineViewModel,
                    sky: sky,
                    authorName: profileStore.displayName(for: sky.authorId),
                    onFinished: { dismiss() }
                )
            )
        } else if let sky, let timelineViewModel, timelineViewModel.canDelete(sky) {
            let skyLookup = dependencies.skyLookup
            content.modifier(
                SoratomoSkyDeleteMenu(
                    viewModel: timelineViewModel,
                    sky: sky,
                    isDeleted: { skyLookup.sky(groupId: sky.groupId, skyId: sky.id) == nil },
                    onDeleted: {
                        didDelete = true
                        dismiss()
                    }
                )
            )
        } else {
            content
        }
    }

    /// 投稿の詳細（画像・投稿者・キャプションの全文）
    private func detail(_ sky: SoratomoSky) -> some View {
        let authorName = profileStore.displayName(for: sky.authorId)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                zoomableImage(sky, authorName: authorName)

                // 投稿者（アイコンと表示名）
                HStack(spacing: 10) {
                    UserAvatarView(
                        photoURL: profileStore.photoURL(for: sky.authorId)?.absoluteString,
                        size: 36
                    )
                    .accessibilityHidden(true)
                    Text(authorName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .accessibilityElement(children: .combine)

                // リアクションの欄（投稿者の行にまとめない。メニューを VoiceOver の別の要素にするため・13.4）
                reactionSection(sky)
                    .padding(.horizontal, 16)

                // キャプションは全文（行数を制限しない・要件 8.9）
                if let caption = sky.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// リアクションの欄（soratomo-reactions 8.3）
    ///
    /// 表示に使う値は、監視で届いた最新（`liveReactions`）。まだ届いていなければタイムラインの覚えの値（要件 2.5）。
    /// 借りた ViewModel が無いとき（起きない想定）は数の表示だけを出し、ブロックした人の分は容れ物の一覧で除く
    /// - Parameter sky: 表示している投稿
    @ViewBuilder
    private func reactionSection(_ sky: SoratomoSky) -> some View {
        let server = liveReactions ?? sky.reactions
        if let reactionViewModel {
            SoratomoSkyReactionSection(
                viewModel: reactionViewModel,
                sky: sky,
                server: server,
                onOpenReactors: { isShowingReactors = true }
            )
        } else {
            SoratomoSkyReactionCounts(
                blockedAuthors: dependencies.blockedAuthors,
                server: server,
                myUid: dependencies.currentUid()
            )
        }
    }

    /// 押した人の一覧のシートの中身
    ///
    /// 開いている間に投稿が消えた・グループから外れた（覚えから外れた）ら、「この投稿は表示できなくなりました」を出す（8.7）。
    /// 行は、欄と同じく監視の最新に自分の分の上書きを重ね、ブロックした人の分を除いたもの
    private var reactorsSheet: some View {
        let sky = dependencies.skyLookup.sky(groupId: groupId, skyId: skyId)
        let entries = sky.flatMap { sky in
            reactionViewModel?.summary(for: sky, server: liveReactions ?? sky.reactions).reactors
        } ?? []
        return SoratomoReactorsSheet(
            entries: entries,
            isUnavailable: becameUnavailable || sky == nil,
            profileStore: profileStore
        )
    }

    /// 拡大できる画像（サムネイルを先に出し、表示用画像を重ねて置き換える）
    private func zoomableImage(_ sky: SoratomoSky, authorName: String) -> some View {
        let paths = sky.imagePaths
        // 表示用画像の縦横比で枠を先に決める（サムネイルから表示用画像に変わっても、高さが動かないように）
        let aspectRatio = CGFloat(max(sky.pixelWidth, 1)) / CGFloat(max(sky.pixelHeight, 1))
        // ピンチ中は、確定した拡大率に変化を掛ける（上限と下限の中に収める）
        let currentScale = Self.clampedScale(zoomScale * pinchScale)

        return ZStack {
            // 下: サムネイル（タイムラインで読んだので、キャッシュから出る前提）
            KFImage(source: .provider(SoratomoStorageImageProvider(storagePath: paths.thumbnail)))
                .targetCache(SoratomoImageCache.cache(forStoragePath: paths.thumbnail))
                .resizable()
                .scaledToFit()

            // 上: 表示用画像（届いたら重ねて置き換える。届かなければサムネイルが見えたまま）
            KFImage(source: .provider(SoratomoStorageImageProvider(storagePath: paths.display)))
                .targetCache(SoratomoImageCache.cache(forStoragePath: paths.display))
                .fade(duration: 0.2)
                .resizable()
                .scaledToFit()
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .scaleEffect(currentScale)
        .offset(
            x: panOffset.width + dragOffset.width,
            y: panOffset.height + dragOffset.height
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .background(Color(.secondarySystemBackground))
        // 拡大した画像が、枠の外（投稿者やキャプションの上）にはみ出さないようにする
        .clipped()
        .contentShape(Rectangle())
        // ダブルタップで、等倍と拡大を切り替える
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.25)) {
                if zoomScale > Self.minZoomScale {
                    zoomScale = Self.minZoomScale
                    panOffset = .zero
                } else {
                    zoomScale = Self.doubleTapZoomScale
                }
            }
        }
        // ピンチで拡大・縮小する
        .gesture(magnificationGesture)
        // 拡大中だけ、ドラッグで画像をずらす（等倍の間はスクロールの邪魔をしないよう、この操作を外す）
        .simultaneousGesture(panGesture, including: zoomScale > Self.minZoomScale ? .all : .subviews)
        // VoiceOver: 画像としてまとめ、説明はキャプション（無ければ「{表示名}さんの空」）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.imageAccessibilityLabel(caption: sky.caption, displayName: authorName))
        .accessibilityAddTraits(.isImage)
    }

    /// 投稿が見つからないときの表示
    private func unavailableView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.headline)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 操作

    /// ピンチの操作（指を離したら拡大率を確定し、等倍に戻ったらずらしも戻す）
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let newScale = Self.clampedScale(zoomScale * value)
                zoomScale = newScale
                if newScale <= Self.minZoomScale {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        panOffset = .zero
                    }
                }
            }
    }

    /// 拡大中のドラッグの操作（指を離したら、ずらし量を確定する）
    private var panGesture: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                panOffset = CGSize(
                    width: panOffset.width + value.translation.width,
                    height: panOffset.height + value.translation.height
                )
            }
    }

    // MARK: - 純関数

    /// 拡大率を、下限（等倍）と上限の中に収める
    private static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, minZoomScale), maxZoomScale)
    }

    /// 投稿画像の VoiceOver の説明（要件 16.5）
    ///
    /// キャプションがあればキャプション。無い（nil・空・空白だけ）なら「{表示名}さんの空」。
    /// 表示名は `SoratomoProfileStore.displayName(for:)` の値（未設定・未取得は「ユーザー」）を渡す。
    /// - Parameters:
    ///   - caption: 投稿のキャプション
    ///   - displayName: 投稿者の表示名
    /// - Returns: VoiceOver が読む説明
    static func imageAccessibilityLabel(caption: String?, displayName: String) -> String {
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return caption
        }
        return "\(displayName)さんの空"
    }
}

// MARK: - 削除の「…」メニュー

/// 投稿詳細の、自分の投稿を削除する「…」メニュー（確認・削除中の表示・失敗の表示を含む）
///
/// 削除はタイムラインの ViewModel の `delete` をそのまま呼ぶ（新しい削除の実装は作らない）。
/// 確認の文言・失敗の文言・削除中の表示（薄くして「削除しています…」）はタイムラインとそろえる。
private struct SoratomoSkyDeleteMenu: ViewModifier {
    /// タイムラインの ViewModel（削除の途中・失敗の文言を画面に出すため監視する）
    @ObservedObject var viewModel: SoratomoTimelineViewModel
    /// 削除する投稿
    let sky: SoratomoSky
    /// 投稿が消えたか（削除が成功すると、ViewModel が覚えから消す）
    let isDeleted: () -> Bool
    /// 削除できたときに呼ぶ（詳細を閉じる）
    let onDeleted: () -> Void

    /// 削除の確認を出しているか
    @State private var isConfirmingDeletion = false

    /// この投稿の削除の途中か（タイムラインの行と同じ判定）
    private var isDeleting: Bool {
        viewModel.deletingSkyIds.contains(sky.id)
    }

    func body(content: Content) -> some View {
        content
            .opacity(isDeleting ? 0.5 : 1)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isDeleting {
                    Text("削除しています…")
                        .font(.caption)
                        .foregroundStyle(.soratomoSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            isConfirmingDeletion = true
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                        .accessibilityLabel("この投稿を削除")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("その他の操作")
                    .disabled(isDeleting)
                }
            }
            .confirmationDialog(
                "この投稿を削除しますか？",
                isPresented: $isConfirmingDeletion,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    Task {
                        await viewModel.delete(sky)
                        // 成功したときだけ閉じる（失敗・始めなかったときは投稿が残り、失敗の文言が出る）
                        if isDeleted() {
                            onDeleted()
                        }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("削除した投稿は元に戻せません")
            }
            .alert(
                viewModel.deleteErrorMessage ?? "",
                isPresented: isShowingDeleteError
            ) {
                Button("OK", role: .cancel) {}
            }
    }

    /// 削除の失敗を出しているか（閉じたら文言を消す・タイムラインと同じ）
    private var isShowingDeleteError: Binding<Bool> {
        Binding(
            get: { viewModel.deleteErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.deleteErrorMessage = nil
                }
            }
        )
    }
}

// MARK: - 通報とブロックの「…」メニュー

/// 投稿詳細の、自分以外の投稿を通報・ブロックする「…」メニュー（release-gate 10.6）
///
/// 操作はタイムラインの ViewModel の `report`・`block` をそのまま呼び、判定と文言をそろえる。
/// - 通報が受け付けられた・投稿がもう無い → 知らせを閉じたら詳細も閉じる（要件 5.5・5.7）
/// - ブロックが保存された → すぐに詳細を閉じる（要件 9.5）
/// - 失敗 → 知らせだけを出し、詳細は開いたまま（もう一度操作できる）
private struct SoratomoSkyModerationMenu: ViewModifier {
    /// タイムラインの ViewModel（途中の状態と知らせを画面に出すため監視する）
    @ObservedObject var viewModel: SoratomoTimelineViewModel
    /// 対象の投稿
    let sky: SoratomoSky
    /// 投稿者の表示名（ブロックの確認の見出しにだけ使う。ログと計測には出さない・14.1）
    let authorName: String
    /// 詳細を閉じる
    let onFinished: () -> Void

    /// 通報の理由を選ばせているか
    @State private var isChoosingReason = false
    /// ブロックの確認を出しているか
    @State private var isConfirmingBlock = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            isChoosingReason = true
                        } label: {
                            Label("通報", systemImage: "exclamationmark.bubble")
                        }
                        .accessibilityLabel("この投稿を通報")
                        .disabled(viewModel.reportingSkyIds.contains(sky.id))

                        Button(role: .destructive) {
                            isConfirmingBlock = true
                        } label: {
                            Label("ブロック", systemImage: "hand.raised")
                        }
                        .accessibilityLabel("この投稿者をブロック")
                        .disabled(viewModel.blockingAuthorIds.contains(sky.authorId))
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("その他の操作")
                }
            }
            // 通報の理由はタイムラインと同じ 5 つ（要件 5.3）
            .confirmationDialog("通報理由を選択", isPresented: $isChoosingReason, titleVisibility: .visible) {
                ForEach(ReportReason.allCases, id: \.self) { reason in
                    Button(reason.displayName) {
                        Task { await viewModel.report(sky, reason: reason, source: .detail) }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("通報したことは、投稿した人やほかのメンバーには知らされません")
            }
            // ブロックの確認（文言はタイムラインと同じ・要件 9.2・9.10）
            .alert("\(authorName)さんをブロックしますか？", isPresented: $isConfirmingBlock) {
                Button("キャンセル", role: .cancel) {}
                Button("ブロック", role: .destructive) {
                    Task {
                        if await viewModel.block(sky, source: .detail) {
                            onFinished()
                        }
                    }
                }
            } message: {
                Text("この人の投稿が、ホーム・ギャラリー・そらともに表示されなくなります。お互いのフォローも外れます。ブロックしたことは相手に知らされません")
            }
    }
}

// MARK: - 通報とブロックの知らせ

/// 投稿詳細で、通報とブロックの結果の知らせを出す（release-gate 10.6）
///
/// メニューとは別に、詳細の画面そのものに付ける。通報が受け付けられると投稿は隠す集合に入り、詳細の body が次に
/// 作り直されたとき（投稿者の名前が届いたときなど）にメニューが外れるので、メニューに付けると知らせも一緒に消えうる。
/// ⚠️ 詳細はタイムラインの ViewModel を観測していないので、隠れた瞬間には作り直されない（知らせを閉じるまで、
///    詳細の中身とメニューが出たままのことがある。受け付けた知らせを閉じると詳細も閉じる）。
/// タイムラインは自分が一番上のときだけ知らせを出すので、二重にはならない。
/// 受け付けた・もう無いの知らせは、閉じたら詳細も閉じる（要件 5.5・5.7）。失敗の知らせでは閉じない（もう一度操作できる）。
private struct SoratomoModerationNoticeAlert: ViewModifier {
    /// タイムラインの ViewModel（無ければ何もしない）
    let viewModel: SoratomoTimelineViewModel?
    /// 詳細を閉じる
    let onFinished: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let viewModel {
            content.modifier(Observed(viewModel: viewModel, onFinished: onFinished))
        } else {
            content
        }
    }

    /// ViewModel を監視して知らせを出す本体
    private struct Observed: ViewModifier {
        @ObservedObject var viewModel: SoratomoTimelineViewModel
        let onFinished: () -> Void

        func body(content: Content) -> some View {
            content.alert(viewModel.moderationNotice?.userMessage ?? "", isPresented: isShowingNotice) {
                Button("OK", role: .cancel) {}
            }
        }

        /// 知らせを出しているか（閉じたら知らせを消し、受け付けた・もう無いなら詳細も閉じる）
        private var isShowingNotice: Binding<Bool> {
            Binding(
                get: { viewModel.moderationNotice != nil },
                set: { isPresented in
                    guard !isPresented, let notice = viewModel.moderationNotice else { return }
                    viewModel.moderationNotice = nil
                    if notice == .reportAccepted || notice == .skyGone {
                        onFinished()
                    }
                }
            )
        }
    }
}

// MARK: - リアクション（soratomo-reactions 8.3）

/// 投稿詳細のリアクションの欄（数の表示・自分以外の投稿ならメニュー・1 人以上なら押した人の一覧の入口）
///
/// 借りた ViewModel を監視するので、送っている間・確定の上書き・ブロックの変化で描き直す
/// （詳細の画面そのものは ViewModel を監視していないため、欄を部品に分けている）。
/// - 自分の投稿で 0 件なら、欄ごと出さない（親の VStack の間隔を増やさない）
/// - 数が 0 件でも、メニューは右端に置く（タイムラインのカードと同じ位置。数の表示は 0 件だと場所を取らないので空白で寄せる）
private struct SoratomoSkyReactionSection: View {
    /// タイムラインから借りたリアクションの ViewModel
    @ObservedObject var viewModel: SoratomoReactionViewModel
    /// 表示している投稿
    let sky: SoratomoSky
    /// 監視の最新のリアクション（まだ届いていなければタイムラインの覚えの値）
    let server: SoratomoReactions
    /// 押した人の一覧を開く
    let onOpenReactors: () -> Void

    var body: some View {
        let summary = viewModel.summary(for: sky, server: server)
        let showsMenu = viewModel.canReact(to: sky)
        if showsMenu || summary.total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if summary.total > 0 {
                        SoratomoReactionSummaryView(summary: summary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if showsMenu {
                        SoratomoReactionMenuButton(
                            summary: summary,
                            isSending: viewModel.isSending(sky),
                            onChoose: { kind in
                                Task { await viewModel.choose(kind, for: sky, server: server, source: .detail) }
                            }
                        )
                    }
                }
                // 1 人以上なら、押した人の一覧の入口（人数は一覧の人数＝合計・3.1・3.5）
                if summary.total > 0 {
                    Button {
                        viewModel.didOpenReactors(count: summary.reactors.count)
                        onOpenReactors()
                    } label: {
                        Text("押した人を見る（\(summary.reactors.count)人）")
                            .font(.subheadline)
                    }
                    .accessibilityHint("リアクションした人の一覧を開きます")
                }
            }
        }
    }
}

/// 借りた ViewModel が無いとき（起きない想定）の、数の表示だけの欄
///
/// ブロックの一覧の変化で描き直すため、`SoratomoBlockedAuthors` を監視する。上書きは無いので、監視の値そのままを出す
private struct SoratomoSkyReactionCounts: View {
    /// ブロックした投稿者（数からブロックした人の分を除く・5.1〜5.3）
    @ObservedObject var blockedAuthors: SoratomoBlockedAuthors
    /// 監視の最新のリアクション（まだ届いていなければタイムラインの覚えの値）
    let server: SoratomoReactions
    /// いまの利用者の uid（自分の絵文字の印に使う。未ログインなら nil）
    let myUid: String?

    var body: some View {
        SoratomoReactionSummaryView(
            summary: SoratomoReactionSummary.make(
                reactions: server,
                myUid: myUid,
                myOverride: nil,
                blockedUserIds: blockedAuthors.ids
            )
        )
    }
}

/// 投稿詳細で、リアクションの失敗の知らせを出す（詳細が開いている間は詳細が出す・タイムラインは一番上のときだけ出す）
///
/// 通報とブロックの知らせ（`SoratomoModerationNoticeAlert`）と同じく、ViewModel が無ければ何もしない
private struct SoratomoReactionNoticeAlert: ViewModifier {
    /// タイムラインから借りたリアクションの ViewModel（無ければ何もしない）
    let viewModel: SoratomoReactionViewModel?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let viewModel {
            content.modifier(Observed(viewModel: viewModel))
        } else {
            content
        }
    }

    /// ViewModel を監視して知らせを出す本体
    private struct Observed: ViewModifier {
        @ObservedObject var viewModel: SoratomoReactionViewModel

        func body(content: Content) -> some View {
            content.alert(viewModel.notice?.userMessage ?? "", isPresented: isShowingNotice) {
                Button("OK", role: .cancel) {}
            }
        }

        /// 知らせを出しているか（閉じたら知らせを消す。詳細は閉じない＝もう一度操作できる）
        private var isShowingNotice: Binding<Bool> {
            Binding(
                get: { viewModel.notice != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.notice = nil
                    }
                }
            )
        }
    }
}
