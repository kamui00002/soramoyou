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
//  - 画像の VoiceOver の説明はキャプション。無ければ「{表示名}さんの空」
//  - ⚠️ 画像は必ず `SoratomoStorageImageProvider` と `.targetCache(SoratomoImageCache.shared)` で読み、
//    processor（ダウンサンプリングなど）は付けない（鍵が変わり、削除やサインアウトで消せなくなるため）
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
    }

    // MARK: - Body

    var body: some View {
        // 覚えから引く（覚えは ObservableObject ではないが、詳細を開いている間に変わるのは削除だけで、
        // 削除はタイムラインで行うため、ここで読み直さなくてよい）
        let sky = dependencies.skyLookup.sky(groupId: groupId, skyId: skyId)

        Group {
            if let sky {
                detail(sky)
            } else {
                unavailableView
            }
        }
        .navigationTitle("空")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sky?.authorId) {
            // 投稿者の表示名とアイコンを取りに行く（取得済みなら何もしない）
            guard let authorId = sky?.authorId else { return }
            await profileStore.prefetch(uids: [authorId])
        }
        .onAppear {
            // 画面の切り替えで 1 回記録する（この画面から先へ進む画面は無いので、表示のたびに重ならない）
            SoratomoAnalytics.screen(.skyDetail)
        }
    }

    // MARK: - 中身

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
                .targetCache(SoratomoImageCache.shared)
                .resizable()
                .scaledToFit()

            // 上: 表示用画像（届いたら重ねて置き換える。届かなければサムネイルが見えたまま）
            KFImage(source: .provider(SoratomoStorageImageProvider(storagePath: paths.display)))
                .targetCache(SoratomoImageCache.shared)
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
    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("表示できません")
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
