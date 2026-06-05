//
//  UseRecipeButton.swift
//  Soramoyou
//
//  レシピ共有: 投稿に添付された編集レシピ（Post.attachedRecipe）を
//  自分の写真に適用して編集を始める入口ボタン。
//  投稿詳細（PostDetailView / GalleryDetailView）の双方から再利用する。
//
//  フロー: ボタン → 写真選択（ImagePicker）→ EditView（共有レシピを初期シード）
//          → 既存の投稿フロー（PostInfoView → savePost）に合流。
//          新しい投稿にもレシピが自動添付されるため、再共有のチェーンが成立する。
//

import SwiftUI

/// エディタ起動用ペイロード。
/// `fullScreenCover(item:)` で提示することで、選択画像が確実にセットされた後にのみ
/// EditView が構築されるようにする（`isPresented` 方式だと state 更新と同一トランザクションの
/// 提示で空の画像配列をキャプチャする stale-state 問題がある。EditView の PostInfoPayload と同じ対策）。
private struct RecipeEditPayload: Identifiable {
    let id = UUID()
    let images: [UIImage]
    let metadata: [ExternalEditInfo?]
}

/// 「このレシピで編集」ボタン（写真選択〜エディタ起動の提示を内包）
struct UseRecipeButton: View {
    /// 共有元投稿に添付されたレシピ
    let recipe: EditRecipe
    /// 共有元投稿の ID（計測用）
    let postId: String

    @EnvironmentObject private var authViewModel: AuthViewModel

    /// 写真選択シートの表示フラグ
    @State private var showingImagePicker = false
    /// 選択された写真（編集対象）
    @State private var selectedImages: [UIImage] = []
    /// 選択写真の外部編集情報（写真Appバッジ表示用）
    @State private var pickedMetadata: [ExternalEditInfo?] = []
    /// エディタ起動ペイロード（nil でなくなった時に提示される）
    @State private var editPayload: RecipeEditPayload?
    /// 写真の非同期ロードが完了したか。
    /// PHPicker は選択直後に自分自身を dismiss し（→ sheet の onDismiss が先に走る）、
    /// 画像ロードは*その後*に完了して onSelectionComplete が呼ばれる。
    /// 「sheet が閉じた」と「ロードが完了した」の両方が揃って初めてエディタを提示する。
    @State private var pickerLoadCompleted = false

    var body: some View {
        // ゲート: 実質的な編集が無い（中立）レシピや未ログインでは表示しない
        // （ゲストは投稿不可のため、編集フローに入れても完了できない）
        if authViewModel.isAuthenticated && !recipe.isNeutral {
            Button {
                LoggingService.shared.logEvent(
                    "recipe_share_tapped",
                    parameters: ["post_id": postId]
                )
                showingImagePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.rays")
                    Text("このレシピで編集")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(
                    Capsule().fill(
                        LinearGradient(
                            colors: DesignTokens.Colors.accentGradient,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                )
            }
            .accessibilityLabel("このレシピで編集")
            // 写真選択 → 閉じてからエディタを提示する。
            // 「sheet クローズ」と「画像ロード完了」の到達順は両方あり得るため、
            // 双方の契機から presentEditorIfReady() を呼び、揃った時点で提示する。
            .sheet(isPresented: $showingImagePicker, onDismiss: {
                presentEditorIfReady()
            }) {
                ImagePicker(
                    selectedImages: $selectedImages,
                    pickedMetadata: $pickedMetadata,
                    maxSelectionCount: 10,
                    onSelectionComplete: {
                        // この時点で selectedImages はセット済み（ロード完了後に呼ばれる）
                        pickerLoadCompleted = true
                        showingImagePicker = false
                        presentEditorIfReady()
                    }
                )
            }
            .fullScreenCover(item: $editPayload, onDismiss: {
                // 次回に備えて選択状態をクリア
                selectedImages = []
                pickedMetadata = []
                pickerLoadCompleted = false
            }) { payload in
                EditView(
                    images: payload.images,
                    userId: authViewModel.currentUser?.id,
                    externalEditInfos: payload.metadata,
                    // 写真固有フィールド（クロップ・HDR）を除いた作風だけをシードする
                    initialRecipe: recipe.preparedAsSharedSeed()
                )
            }
        }
    }

    /// 「sheet が閉じた」かつ「画像ロードが完了した」が揃ったらエディタを提示する。
    /// どちらか一方だけ（ロード未完了・キャンセルで空選択など）では何もしない。
    private func presentEditorIfReady() {
        guard pickerLoadCompleted, !selectedImages.isEmpty, !showingImagePicker else { return }
        pickerLoadCompleted = false
        // ペイロードに画像を確定コピーしてから提示（stale-state 回避）
        editPayload = RecipeEditPayload(images: selectedImages, metadata: pickedMetadata)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        UseRecipeButton(
            recipe: {
                var recipe = EditRecipe()
                recipe.exposureEV = 0.5
                recipe.appliedFilter = .warm
                return recipe
            }(),
            postId: "preview-post"
        )
        .environmentObject(AuthViewModel())
        .padding()
    }
}
