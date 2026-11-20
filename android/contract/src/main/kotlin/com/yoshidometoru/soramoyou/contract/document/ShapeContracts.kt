// ⭐️ 個々のコレクション・操作の書き込みの形の契約（タスク 13.2・要件 2.10・3.1〜3.5）
package com.yoshidometoru.soramoyou.contract.document

import com.yoshidometoru.soramoyou.contract.model.FeedbackCategory
import com.yoshidometoru.soramoyou.contract.model.ReportReason
import com.yoshidometoru.soramoyou.contract.model.TimeOfDay
import com.yoshidometoru.soramoyou.contract.model.Visibility
import com.yoshidometoru.soramoyou.contract.rules.StorageDownloadUrl
import com.yoshidometoru.soramoyou.contract.rules.TextLimits

// 契約は「このコレクションへ、この操作で書いてよいキーと値」を静的な定数として書いたもの（設計書 :556-595）。
// 契約の型（ShapeContract・FieldRule・Basis など）は ShapeContract.kt、検証は DocumentShapeValidator.kt にある。
// このファイルは、その型で書いた本物の契約だけを持つ。契約を足すときは、ここに val を 1 つ足す。
//
// 契約は許可リスト方式なので、ここに書いていないキーは全て違反になる。
// 書かせたくないキー（`fcmToken` など）は「契約に書かない」ことで止まる。

/** 本物の契約の置き場。操作ごとに 1 つの定数。契約を書き間違えると、作った時点（ShapeContract の init）で止まる。 */
object ShapeContracts {

    // ---- 共通部品（同じ規則を複数の項目で使うもの） ----

    /** 値のある任意の文字列。空文字は「値が無い」ことなので書かない（要件 3.5）。 */
    private val NON_EMPTY: ValueConstraint = ValueConstraint.Utf16LengthIn(1..Int.MAX_VALUE)

    /** カウンタの新規値。作成時は常に整数の 0（要件 3.1）。 */
    private val ZERO: ValueConstraint = ValueConstraint.IntIn(0L..0L)

    /** 補完で写すカウンタ。負の値は書かない。 */
    private val NON_NEGATIVE: ValueConstraint = ValueConstraint.IntIn(0L..Long.MAX_VALUE)

    /** 画像の幅・高さ（px）。0 以下は書かない。 */
    private val POSITIVE: ValueConstraint = ValueConstraint.IntIn(1L..Long.MAX_VALUE)

    /**
     * 画像の URL（投稿の写真の `url`・`thumbnail`、プロフィールの `photoURL`）。Storage のダウンロード URL の形だけを書く（レビュー R14）。
     * 本番の形は firestore.rules の `isValidImageUrl` と同じ。空は形に入らないので、[NON_EMPTY] と同じく空文字も書かない。
     *
     * 本番の形と Android のエミュレータの形の**両方**を、どのビルドでも通す（2026-11-07 利用者の決定）。契約は静的な定数で、
     * ビルドの変種を見分けられないため。本番のビルドが書く URL は SDK が本番の Storage から作るので、エミュレータの形は現れない。
     * 万一書いても、本番の rules が断る（契約が無いときと同じ結果）。変種ごとに通す形を絞るのは、URL を読む側の役目。
     */
    private val IMAGE_URL: ValueConstraint = ValueConstraint.MatchesAnyPattern(
        listOf(StorageDownloadUrl.PRODUCTION_PATTERN, StorageDownloadUrl.EMULATOR_PATTERN),
    )

    /** 文字列の値か、キーの削除（空にした項目：設計書 QD）。削除には制約を当てない（AllowListShapeValidator の規約）。 */
    private val STR_OR_DELETE: Set<ValueKind> = setOf(ValueKind.STR, ValueKind.DELETE)

    /**
     * プロフィールの更新の項目（`users` と `publicProfiles` で同じ）。変えた項目と更新日時だけの部分更新（要件 3.6・10.6）。
     * 表示名・自己紹介の文字数の上限（50・200 の書記素）は、入力の規則（TextLimits）で守る。
     */
    private val PROFILE_UPDATE_FIELDS: List<FieldRule> = listOf(
        FieldRule("updatedAt", setOf(ValueKind.TIME), true, Basis.IOS_SHAPE_PARITY),
        FieldRule("displayName", STR_OR_DELETE, false, Basis.OPTIONAL, NON_EMPTY),
        FieldRule("bio", STR_OR_DELETE, false, Basis.OPTIONAL, NON_EMPTY),
        FieldRule("photoURL", STR_OR_DELETE, false, Basis.OPTIONAL, IMAGE_URL),
    )

    /**
     * `users/{uid}` の作成（`USER_CREATE`）。
     *
     * 根拠：
     * - rules（firestore.rules の users の create）：`isOwner(userId)` ＋ `hasAll(['id','createdAt'])` ＋ `isValidEmail(email)`。
     *   `id` の一致は、この契約の `EqualsDocumentId` で縛る。
     * - iOS の書き込み（User.swift:106-144 `toFirestoreData`。:108-110・:113-115・:137-144）：`id`・`createdAt`・`updatedAt`・（あれば）`email`・
     *   3 つのカウンタ・3 つの通知設定を、常に書く。
     *
     * 書かないもの（契約に無いので違反になる）：`fcmToken`・`fcmTokenUpdatedAt`（要件 2.10。1 ユーザー 1 トークンで、
     * Android が書くと iOS 端末への通知が途切れる）、`customEditTools`・`followedTags`・`iapAccountToken`・
     * `blockedUserIds`、`displayName`・`photoURL`・`bio`（Android は作成時に書かない。更新は USER_PROFILE_UPDATE）。
     *
     * `createdAt` と `updatedAt` が同値であることは、組み立て（[DocumentBuilders.userCreate]）が同じ値を入れる。
     */
    val USER_CREATE: ShapeContract = ShapeContract(
        id = ContractId.USER_CREATE,
        fields = listOf(
            FieldRule("id", setOf(ValueKind.STR), true, Basis.IOS_SHAPE_PARITY, ValueConstraint.EqualsDocumentId),
            FieldRule("createdAt", setOf(ValueKind.TIME), true, Basis.RULES_HAS_ALL),
            FieldRule("updatedAt", setOf(ValueKind.TIME), true, Basis.IOS_SHAPE_PARITY),
            // 無ければキーごと省略（匿名など）。rules の isValidEmail の size() の部分（1..254）。
            // 正規表現は入力の段階で EmailValidator（タスク 13.1）が見るので、ここでは持たない
            FieldRule("email", setOf(ValueKind.STR), false, Basis.RULES_VALUE, ValueConstraint.Utf16LengthIn(1..254)),
            FieldRule("followersCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, ZERO),
            FieldRule("followingCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, ZERO),
            FieldRule("postsCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, ZERO),
            // 通知設定の既定値。Cloud Functions の欠落時の既定（functions/index.js:49-53）と一致させる
            FieldRule("notifyReactions", setOf(ValueKind.BOOL), true, Basis.IOS_SHAPE_PARITY, ValueConstraint.BoolIs(true)),
            FieldRule("notifyNewPostsFromFollowing", setOf(ValueKind.BOOL), true, Basis.IOS_SHAPE_PARITY, ValueConstraint.BoolIs(true)),
            FieldRule("notifyNewPostsFromEveryone", setOf(ValueKind.BOOL), true, Basis.IOS_SHAPE_PARITY, ValueConstraint.BoolIs(false)),
        ),
    )

    /**
     * `publicProfiles/{uid}` の作成（`PUBLIC_PROFILE_CREATE`）。
     *
     * 根拠：
     * - rules（firestore.rules の publicProfiles の create）：`isOwner(userId)` ＋ `hasAll(['id','createdAt'])` ＋ `id == userId`（#133）
     *   ＋ `recommendedPostIds` の型の検査（無ければ許可）＋ `photoURL` が画像の URL の形（iOS #224。[IMAGE_URL]）。
     * - iOS の書き込み（PublicProfile.swift:80-116 `toFirestoreData`。:82-84・:87-97・:107-109）：`id`・`createdAt`・`updatedAt`・
     *   （値があれば）`displayName`・`photoURL`・`bio`・3 つのカウンタ。
     *
     * 書かないもの：`recommendedPostIds`・`customEditTools`・`customEditToolsOrder`（iOS も空のときは書かない：
     * PublicProfile.swift:111-114。Android MVP は持たない）。公開プロフィールは認証済みの誰でも読めるので、
     * 機密の項目（`email`・`fcmToken`・通知設定など）は絶対に入れない。
     *
     * カウンタは、新規なら 0、補完（要件 3.7）なら `users` の値を写す。負の値は書かない。
     */
    val PUBLIC_PROFILE_CREATE: ShapeContract = ShapeContract(
        id = ContractId.PUBLIC_PROFILE_CREATE,
        fields = listOf(
            FieldRule("id", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.EqualsDocumentId),
            FieldRule("createdAt", setOf(ValueKind.TIME), true, Basis.RULES_HAS_ALL),
            FieldRule("updatedAt", setOf(ValueKind.TIME), true, Basis.IOS_SHAPE_PARITY),
            FieldRule("displayName", setOf(ValueKind.STR), false, Basis.OPTIONAL, NON_EMPTY),
            FieldRule("photoURL", setOf(ValueKind.STR), false, Basis.OPTIONAL, IMAGE_URL),
            FieldRule("bio", setOf(ValueKind.STR), false, Basis.OPTIONAL, NON_EMPTY),
            FieldRule("followersCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, NON_NEGATIVE),
            FieldRule("followingCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, NON_NEGATIVE),
            FieldRule("postsCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, NON_NEGATIVE),
        ),
    )

    /**
     * `users/{uid}` のプロフィールの更新（`USER_PROFILE_UPDATE`）。
     *
     * 根拠：
     * - rules（firestore.rules の users の update）：所有者だけが更新でき、`id` と（あれば）`email` を変えない。変えた `photoURL` は
     *   画像の URL の形でなければならない（iOS #224。[IMAGE_URL]）
     * - iOS は `User` 全体を `setData(merge: true)` で書く（設計書の要件 10.6 の注）。Android は要件どおり、変えた項目と
     *   `updatedAt` だけを部分更新する（手元の古いカウンタで上書きしない）
     *
     * 書かないもの（契約に無いので違反になる）：`id`・`email`（rules が変更を拒む）、`followersCount`・`followingCount`・
     * `postsCount`（カウンタは別の契約で増減する）、`fcmToken`・`fcmTokenUpdatedAt`（要件 2.10）、`createdAt`、通知設定などの他の項目。
     */
    val USER_PROFILE_UPDATE: ShapeContract = ShapeContract(
        id = ContractId.USER_PROFILE_UPDATE,
        fields = PROFILE_UPDATE_FIELDS,
    )

    /**
     * `publicProfiles/{uid}` のプロフィールの更新（`PUBLIC_PROFILE_UPDATE`）。
     *
     * 根拠：
     * - rules（firestore.rules の publicProfiles の update）：所有者だけが更新でき、`id` を変えない（＋おすすめの空の形の検査。Android は書かない）、
     *   変えた `photoURL` は画像の URL の形でなければならない（iOS #224。[IMAGE_URL]）
     * - iOS（FirestoreService.swift:1327-1342 `updatePublicProfileFields`）：`updatedAt` を常に書き、値のある表示名・アイコン・
     *   自己紹介だけを足す。iOS は空にできない（キーを削除しない）が、Android は空にした項目をキーの削除にする（設計書 QD）
     *
     * 書かないもの：[USER_PROFILE_UPDATE] と同じ。
     */
    val PUBLIC_PROFILE_UPDATE: ShapeContract = ShapeContract(
        id = ContractId.PUBLIC_PROFILE_UPDATE,
        fields = PROFILE_UPDATE_FIELDS,
    )

    /**
     * `likes/{uid}_{postId}` の作成（`LIKE_CREATE`）。
     *
     * 根拠：
     * - rules（firestore.rules の likes の create）：`userId == auth.uid` ＋ ドキュメント ID が `auth.uid + '_' + postId` ＋ `hasAll(['userId','postId','createdAt'])`
     * - iOS の書き込み（Like.swift:36-38）：この 3 項目だけ。`createdAt` は端末の時刻（設計書 QC）
     *
     * 書かないもの（契約に無いので違反になる）：3 項目以外の全て（要件 9.3）。
     */
    val LIKE_CREATE: ShapeContract = ShapeContract(
        id = ContractId.LIKE_CREATE,
        fields = listOf(
            FieldRule("userId", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.EqualsAuthUid),
            FieldRule("postId", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.DocumentIdIsAuthUidAndValue),
            FieldRule("createdAt", setOf(ValueKind.TIME), true, Basis.RULES_HAS_ALL),
        ),
    )

    /**
     * `posts/{postId}` のいいね数の更新（`POST_LIKE_COUNTER`）。他人の投稿にも書く。
     *
     * 根拠：
     * - rules（firestore.rules の `isCountOnlyUpdate`）：変わるキーは `likesCount`・`commentsCount` だけ、キー数が同じ、
     *   `likesCount` の変化は ±1 だけ
     * - iOS（FirestoreService.swift:1562, 1567）：`likesCount` の `increment(±1)` だけ
     *
     * 書かないもの：`updatedAt`（同時に書くと isCountOnlyUpdate で拒否される。要件 9.5）、`commentsCount`（いいねの書き込みでは
     * 触らない。コメント数の減算は退会のための別の契約 [POST_COMMENT_COUNTER]）、他の全ての項目。
     * 値で上書きする（`Int64`）書き方も許さない（手元の古い値で他人のいいねを消してしまうため）。
     */
    val POST_LIKE_COUNTER: ShapeContract = ShapeContract(
        id = ContractId.POST_LIKE_COUNTER,
        fields = listOf(
            FieldRule("likesCount", setOf(ValueKind.INCREMENT), true, Basis.COUNT_ONLY_UPDATE, ValueConstraint.IncrementIn(setOf(1L, -1L))),
        ),
    )

    /**
     * `posts/{postId}` のコメント数の減算（`POST_COMMENT_COUNTER`）。退会で自分のコメントを 1 件消すたびに、他人の投稿にも書く（タスク 31.3）。
     *
     * 根拠：
     * - rules（firestore.rules の `isCountOnlyUpdate`）：変わるキーは `likesCount`・`commentsCount` だけ、キー数が同じ、
     *   `commentsCount` の変化は ±1 だけ
     * - iOS（FirestoreService.swift:1069・1083 `deleteReaction`）：退会のときに `commentsCount` の `increment(-1)` だけを書く
     *
     * 許すのは **-1 だけ**（[POST_LIKE_COUNTER] の ±1 より狭い）。Android の MVP はコメントを作らない（コメントは MVP 外）ので、
     * +1 を書く呼び出し元が無い。使われない書き込みの口を開けておかない（許可リスト方式。このファイルの冒頭）。
     * コメントの作成を Android に足すときに、この範囲を ±1 に広げる。
     *
     * 書かないもの：`updatedAt`（同時に書くと isCountOnlyUpdate で拒否される）、`likesCount`（いいねは [POST_LIKE_COUNTER]）、
     * 他の全ての項目。値で上書きする（`Int64`）書き方も許さない（手元の古い値で他人のコメントの数を巻き戻してしまうため）。
     */
    val POST_COMMENT_COUNTER: ShapeContract = ShapeContract(
        id = ContractId.POST_COMMENT_COUNTER,
        fields = listOf(
            FieldRule("commentsCount", setOf(ValueKind.INCREMENT), true, Basis.COUNT_ONLY_UPDATE, ValueConstraint.IncrementIn(setOf(-1L))),
        ),
    )

    // ---- 投稿（タスク 20.4・要件 7.3・7.10〜7.14・7.17・8.1・8.2） ----

    /**
     * 投稿の `images` の各要素（`POST_IMAGE`）。[POST_CREATE] の `nested` から使うので、[POST_CREATE] より先に宣言する。
     *
     * 根拠：
     * - iOS の読み取り（ImageInfo.swift:80-86 `init?(from:)`）：`url` が文字列、`width`・`height`・`order` が **`as? Int`**。
     *   どれかが欠ける・型が違うと、その画像が**黙って読み飛ばされる**（Post.swift の `compactMap`）。だから整数で書く
     *   （[FsValue] に小数が無いので、小数はそもそも作れない）
     * - iOS の書き込み（ImageInfo.swift:55-77 `toFirestoreData`）：上の 4 つに、あれば `thumbnail`・`storagePath`・`thumbnailStoragePath`
     * - rules（`isValidImageList`・`isValidImageEntry`。iOS #224）：`url`・`thumbnail` は画像の URL の形（[IMAGE_URL]）
     * - Android は `thumbnail`（要件 4.7・一覧の表示）と 2 つの Storage のパス（要件 7.11・投稿を消すときに画像を確実に消すため）を
     *   必ず書く。iOS では任意だが、Android の書き込みでは必須にする（根拠の種類は既存の [Basis] に合うものが無いので IOS_SHAPE_PARITY）
     *
     * 書かないもの：`externalEditInfo`（iOS は EXIF の日時だけでも作り（ImagePickerService.swift:183-190 `resolveExternalEditInfo`）、
     * 画像に付ける（PostViewModel.swift:824-835）。要件 7.12）。
     */
    val POST_IMAGE: ShapeContract = ShapeContract(
        id = ContractId.POST_IMAGE,
        fields = listOf(
            FieldRule("url", setOf(ValueKind.STR), true, Basis.IOS_READER_REQUIRED, IMAGE_URL),
            FieldRule("width", setOf(ValueKind.INT64), true, Basis.IOS_READER_REQUIRED, POSITIVE),
            FieldRule("height", setOf(ValueKind.INT64), true, Basis.IOS_READER_REQUIRED, POSITIVE),
            // 0 から始まる表示順。iOS は order で並べ直すので、配列の添字との一致は縛らない
            FieldRule("order", setOf(ValueKind.INT64), true, Basis.IOS_READER_REQUIRED, ValueConstraint.IntIn(0L until TextLimits.IMAGES_MAX.toLong())),
            FieldRule("thumbnail", setOf(ValueKind.STR), true, Basis.IOS_SHAPE_PARITY, IMAGE_URL),
            FieldRule("storagePath", setOf(ValueKind.STR), true, Basis.IOS_SHAPE_PARITY, ValueConstraint.StoragePathUnder("posts", ".jpg")),
            FieldRule(
                "thumbnailStoragePath", setOf(ValueKind.STR), true, Basis.IOS_SHAPE_PARITY,
                ValueConstraint.StoragePathUnder("thumbnails", "_thumb.jpg"),
            ),
        ),
    )

    /**
     * `posts/{postId}` の作成（`POST_CREATE`）。
     *
     * 根拠：
     * - rules（firestore.rules の `isValidPost`・posts の create）：`hasAll(['userId','images','visibility','createdAt'])`、
     *   `userId == auth.uid`、`caption` は 2000 以下（`size()` は UTF-16 の単位）、`hashtags` は 30 以下、`visibility` は 3 値、`images` は 1〜10 件
     * - rules（`isCountOnlyUpdate`）：`likesCount`・`commentsCount` が無いと、誰もいいねできない投稿になる。だから作成時に整数の 0 を書く
     * - iOS の読み取り（Post.swift:214-335）：`postId`・`userId` が文字列、`images` がマップの配列でないとデコードに失敗する
     * - iOS の書き込み（Post.swift の `toFirestoreData`・PostViewModel.swift:884-920）：`postId`・`userId`・`images`・`visibility`・
     *   2 つのカウンタ・`createdAt`・`updatedAt` を常に、`caption`・`hashtags`・`capturedAt`・`timeOfDay` などを値があるときだけ書く
     *
     * 値の範囲で縛るもの：`postId` はドキュメント ID と同値、`userId` は自分の uid、`caption` は 1〜2000（空はキーを書かない）、
     * `hashtags` は 1〜30 件（0 件はキーを書かない）、`visibility`・`timeOfDay` は列挙値の `raw` だけ。
     * `timeOfDay` は `capturedAt` があるときだけ書く（要件 7.14。組み立ての呼び出し側の責任）。
     * `createdAt` と `updatedAt` の同値は、組み立てが同じ値を入れる。
     *
     * 書かないもの（契約に無いので違反になる）：
     * - 編集情報 `editSettings`・`editRecipeV1`（要件 8.1・8.2）、オリジナル画像 `originalImages`（要件 7.12）
     * - 気分・フレーム・投稿の種類 `mood`・`frameId`・`frameCaption`・`frameTextColorHex`・`frameFontStyle`・`postKind`・
     *   `collageLayout`・`panelLabels`（iOS も 1 枚の投稿では `postKind` を書かない：PostViewModel.swift:901）
     * - 位置 `location`、自動判定 `skyType`・`skyColors`・`colorTemperature`（要件 7.17・決定事項 D4）
     *
     * 投稿の更新の契約は、いいね数の増減（[POST_LIKE_COUNTER]）と、退会のときのコメント数の減算（[POST_COMMENT_COUNTER]）だけで、
     * 他は作らない。iOS で編集した投稿の編集情報などを Android が書き換えないためである（要件 8.2）。
     */
    val POST_CREATE: ShapeContract = ShapeContract(
        id = ContractId.POST_CREATE,
        fields = listOf(
            FieldRule("postId", setOf(ValueKind.STR), true, Basis.IOS_READER_REQUIRED, ValueConstraint.EqualsDocumentId),
            FieldRule("userId", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.EqualsAuthUid),
            FieldRule(
                "images", setOf(ValueKind.MAP_LIST), true, Basis.RULES_VALUE,
                ValueConstraint.CountIn(TextLimits.IMAGES_MIN..TextLimits.IMAGES_MAX),
            ),
            FieldRule("visibility", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.OneOf(Visibility.entries.map { it.raw }.toSet())),
            FieldRule("likesCount", setOf(ValueKind.INT64), true, Basis.COUNT_ONLY_UPDATE, ZERO),
            FieldRule("commentsCount", setOf(ValueKind.INT64), true, Basis.COUNT_ONLY_UPDATE, ZERO),
            FieldRule("createdAt", setOf(ValueKind.TIME), true, Basis.RULES_HAS_ALL),
            FieldRule("updatedAt", setOf(ValueKind.TIME), true, Basis.IOS_SHAPE_PARITY),
            FieldRule("caption", setOf(ValueKind.STR), false, Basis.RULES_VALUE, ValueConstraint.Utf16LengthIn(1..TextLimits.CAPTION_MAX)),
            FieldRule("hashtags", setOf(ValueKind.STR_LIST), false, Basis.RULES_VALUE, ValueConstraint.CountIn(1..TextLimits.HASHTAGS_MAX)),
            FieldRule("capturedAt", setOf(ValueKind.TIME), false, Basis.OPTIONAL),
            FieldRule("timeOfDay", setOf(ValueKind.STR), false, Basis.OPTIONAL, ValueConstraint.OneOf(TimeOfDay.entries.map { it.raw }.toSet())),
        ),
        nested = mapOf("images" to POST_IMAGE),
    )

    /**
     * `users/{uid}` の全投稿数の更新（`USER_POSTS_COUNT`）。
     *
     * 根拠：iOS の `recountPostsCount`（FirestoreService.swift:678-700）は、投稿を数え直した値（集計）を `postsCount` だけで上書きする。
     * rules（firestore.rules の users の update）は所有者の更新で `id`・`email` を変えない。
     * 加算ではなく値で書く（数え直しなので、手元の古い値で他の端末の投稿を消すことにならない）。負の値は書かない。
     *
     * 書かないもの：`postsCount` 以外の全て（`updatedAt` も iOS は書かない）。
     */
    val USER_POSTS_COUNT: ShapeContract = ShapeContract(
        id = ContractId.USER_POSTS_COUNT,
        fields = listOf(FieldRule("postsCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, NON_NEGATIVE)),
    )

    /**
     * `publicProfiles/{uid}` の公開投稿数の更新（`PUBLIC_PROFILE_POSTS_COUNT`）。数えるのは公開範囲が `public` の投稿だけ。
     *
     * 根拠：iOS の `recountPostsCount`（FirestoreService.swift:684-694）。[USER_POSTS_COUNT] と同じく `postsCount` だけを値で書く。
     */
    val PUBLIC_PROFILE_POSTS_COUNT: ShapeContract = ShapeContract(
        id = ContractId.PUBLIC_PROFILE_POSTS_COUNT,
        fields = listOf(FieldRule("postsCount", setOf(ValueKind.INT64), true, Basis.IOS_SHAPE_PARITY, NON_NEGATIVE)),
    )

    // ---- 通報・ブロック・フィードバック（タスク 28・要件 11.2〜11.5・13.2〜13.4） ----

    /**
     * `reports/{自動ID}` の作成（`REPORT_CREATE`）。
     *
     * 根拠：
     * - rules（firestore.rules の reports）：読み取りは全て拒否。作成は認証済みで、`reporterId == auth.uid` ＋
     *   `hasAll(['postId','reporterId','reportedUserId','reason','createdAt'])`
     * - iOS の書き込み（FirestoreService.swift:1143-1155 `reportPost`）：この 5 項目だけ。`createdAt` は `FieldValue.serverTimestamp()`。
     *   理由は `ReportReason.rawValue`（ReportReason.swift:11-16）
     *
     * ドキュメント ID は自動 ID なので、書き込む前は分からない。この契約はドキュメント ID を縛らない
     * （`postId` は通報される投稿の ID で、通報の文書の ID ではない）。
     *
     * 書かないもの（契約に無いので違反になる）：5 項目以外の全て（通報の説明文・連絡先・`updatedAt` など）。
     * 通報は作成だけで、更新・削除は rules が拒否する（`allow update, delete: if false`）ので、契約も作成の 1 つだけ。
     */
    val REPORT_CREATE: ShapeContract = ShapeContract(
        id = ContractId.REPORT_CREATE,
        fields = listOf(
            // 通報される投稿の ID。空文字は「値が無い」ことなので書かない（運営が追えない通報になる）
            FieldRule("postId", setOf(ValueKind.STR), true, Basis.RULES_HAS_ALL, NON_EMPTY),
            FieldRule("reporterId", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.EqualsAuthUid),
            FieldRule("reportedUserId", setOf(ValueKind.STR), true, Basis.RULES_HAS_ALL, NON_EMPTY),
            // iOS の 5 種に限る（要件 11.3）
            FieldRule("reason", setOf(ValueKind.STR), true, Basis.IOS_SHAPE_PARITY, ValueConstraint.OneOf(ReportReason.entries.map { it.raw }.toSet())),
            // サーバー時刻だけ。端末の時刻（Time）は違反（likes・posts は端末の時刻で、ここだけ違う）
            FieldRule("createdAt", setOf(ValueKind.SERVER_TIME), true, Basis.RULES_HAS_ALL),
        ),
    )

    /**
     * `users/{uid}` のブロック中のユーザーの追加・削除（`USER_BLOCKED_IDS`）。
     *
     * 根拠：
     * - rules（firestore.rules の users の update）：所有者だけが更新でき、`id` と（あれば）`email` を変えない
     * - iOS の書き込み（FirestoreService.swift:1174-1194 `blockUser`・`unblockUser`）：`blockedUserIds` に
     *   `FieldValue.arrayUnion([uid])`／`arrayRemove([uid])` を **1 要素だけ**。`updatedAt` も書かない
     *
     * 追加と削除を 1 つの契約にしているのは、書くキーも要素数も同じで、種類（`ARRAY_UNION` か `ARRAY_REMOVE`）だけが違うため。
     * 一覧を値で上書きする書き方（`StrList`）と、一覧ごと消す書き方（`DeleteField`）は、手元の古い一覧で別の端末のブロックを
     * 消してしまうので許さない（種類の違反）。要素が 0 個・2 個以上の追加・削除も許さない（要件 11.4・11.5 の「1 人ずつ」）。
     *
     * 書かないもの（契約に無いので違反になる）：`blockedUserIds` 以外の全て（`updatedAt` を含む）。
     * 呼び出し側が他人の投稿にだけ操作を出す（要件 11.7）。
     */
    val USER_BLOCKED_IDS: ShapeContract = ShapeContract(
        id = ContractId.USER_BLOCKED_IDS,
        fields = listOf(
            FieldRule(
                "blockedUserIds", setOf(ValueKind.ARRAY_UNION, ValueKind.ARRAY_REMOVE), true, Basis.IOS_SHAPE_PARITY,
                ValueConstraint.CountIn(1..1),
            ),
        ),
    )

    /**
     * `feedback/{UUID}` の作成（`FEEDBACK_CREATE`）。ドキュメント ID は大文字の UUID（Feedback.swift:44）だが、契約は縛らない。
     *
     * 根拠：
     * - rules（firestore.rules の feedback）：読み取りは全て拒否。作成は認証済みで、`userId == auth.uid` ＋
     *   `hasAll(['userId','message','createdAt'])` ＋ `message` が文字列で `size()` が 1〜1000（**UTF-16 の単位**）
     * - iOS の書き込み（Feedback.swift:70-86 `toFirestoreData`・FeedbackViewModel.swift:38-51）：`userId`・`message`・`createdAt`
     *   （`FieldValue.serverTimestamp()`）を常に、`category`・`appVersion`・`deviceInfo` を値があるときだけ。
     *   本文は前後の空白を取り除いた後の値で、空白だけの本文は送らない（`isValid`：Feedback.swift:60-63）
     *
     * 本文の判定は [ValueConstraint.NonBlankUtf16LengthAtMost]：空白だけ（全角空白を含む iOS と同じ集合。[TextLimits.isBlank]）でなく、
     * UTF-16 の長さが 1000 以下。iOS の `message.count`（書記素）は使わない。書記素で数えると、絵文字の多い本文が iOS では通っても
     * rules が（UTF-16 で 1000 を超えて）断る。前後の空白を取り除くのは入力の段階の責任で、契約は取り除いた後の値を前提に、
     * 空白だけの本文と長すぎる本文を止める。
     *
     * 書かないもの（契約に無いので違反になる）：メールアドレス・表示名（要件 13.4。個人を特定する値を送らない）、`updatedAt` など。
     * 更新・削除は rules が拒否する（`allow update, delete: if false`）ので、契約も作成の 1 つだけ。
     */
    val FEEDBACK_CREATE: ShapeContract = ShapeContract(
        id = ContractId.FEEDBACK_CREATE,
        fields = listOf(
            FieldRule("userId", setOf(ValueKind.STR), true, Basis.RULES_VALUE, ValueConstraint.EqualsAuthUid),
            FieldRule(
                "message", setOf(ValueKind.STR), true, Basis.RULES_VALUE,
                ValueConstraint.NonBlankUtf16LengthAtMost(TextLimits.FEEDBACK_MAX),
            ),
            FieldRule("createdAt", setOf(ValueKind.SERVER_TIME), true, Basis.RULES_HAS_ALL),
            // 以下は値があるときだけ。無ければキーごと省略する（要件 13.2）。空文字は「値が無い」ことなので書かない
            FieldRule("category", setOf(ValueKind.STR), false, Basis.OPTIONAL, ValueConstraint.OneOf(FeedbackCategory.entries.map { it.raw }.toSet())),
            FieldRule("appVersion", setOf(ValueKind.STR), false, Basis.OPTIONAL, NON_EMPTY),
            FieldRule("deviceInfo", setOf(ValueKind.STR), false, Basis.OPTIONAL, NON_EMPTY),
        ),
    )
}
