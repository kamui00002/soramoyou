// ⭐️ 読み取り口が受け付けるクエリと集計の形の閉じた集合（タスク 7.1・15.1・23.1・31.1・要件 1.4・4.1・4.2・7.19・10.2・10.4・10.5・12.3）
package com.yoshidometoru.soramoyou.data.remote.read

import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.data.remote.RawDocument

/**
 * 読み取り口（[FirestoreReader.query]）が受け付けるクエリの形（設計書の QuerySpec。:681）。
 * 形は sealed の閉じた集合で表す（要件 1.4：定義済みのインデックスがあるクエリだけを投げる）。
 * 形ごとの条件・並び順・件数は [DefaultFirestoreReader] の計画（[QueryPlan]）にだけ書く。
 *
 * M1 では公開投稿のフィード（設計書のクエリ×インデックス表の 1）を、M2 で自分の投稿と他人の公開投稿（表の 2・3。タスク 15.1）を置いた。
 * M5 で、退会の取得（表の 6〜9。タスク 31.1）として [DrainByField]・[AllOwned] を足した。
 *
 * 続きの起点（`after`）は、同じ形のクエリのページから得たものだけを渡す。
 */
sealed interface QuerySpec {

    /**
     * 公開投稿のフィード：`posts` の `visibility == public` を `createdAt` の新しい順に [PAGE_SIZE] 件（要件 4.1・4.2）。
     * インデックスは複合 `visibility+createdAt`（iOS の firestore.indexes.json:3-16。iOS の同じ形は FirestoreService.swift:278-286）。
     *
     * 件数は引数にせず固定する（設計書 :682 は引数だが、形を閉じた集合に限る趣旨に合わせて 20 件に固定した）。
     *
     * @property after 続きの起点（前のページの [RawPage.cursor]）。null なら先頭から。
     */
    data class PublicFeed(val after: RawCursor?) : QuerySpec {
        companion object {
            /** 1 ページの件数（iOS のフィードと同じ 20 件。要件 4.1）。 */
            const val PAGE_SIZE: Int = 20
        }
    }

    /**
     * 自分の投稿：`posts` の `userId == uid` を、公開範囲で絞らずに `createdAt` の新しい順に [PAGE_SIZE] 件（要件 10.2）。
     * インデックスは複合 `userId+createdAt`（iOS の firestore.indexes.json:17-30。iOS の同じ形は FirestoreService.swift:413-420）。
     * 非公開・フォロワー限定の投稿も含むので、rules（`isOwner`）が通るのは [uid] がログイン中の本人のときだけである。
     *
     * @property uid ログイン中のユーザーの uid。
     * @property after 続きの起点（前のページの [RawPage.cursor]）。null なら先頭から。
     */
    data class OwnPosts(val uid: Uid, val after: RawCursor?) : QuerySpec {
        companion object {
            /** 1 ページの件数（iOS の ProfileViewModel.postsPageSize と同じ 50 件。2026-10-06 ユーザー判断）。 */
            const val PAGE_SIZE: Int = PROFILE_POSTS_PAGE_SIZE
        }
    }

    /**
     * 他人の公開投稿：`posts` の `visibility == public` かつ `userId == uid` を `createdAt` の新しい順に [PAGE_SIZE] 件（要件 10.4・10.5）。
     * インデックスは複合 `visibility+userId+createdAt`（iOS の firestore.indexes.json:45-62。iOS の同じ形は FirestoreService.swift:481-490）。
     *
     * 公開範囲を指定する引数は持たせない。公開範囲の条件を外したクエリは、rules が非公開の投稿を含みうるものとして
     * クエリ全体を拒否するので（要件 10.5）、この形からは外せないようにしている。
     *
     * @property uid プロフィールを開いた相手の uid。
     * @property after 続きの起点（前のページの [RawPage.cursor]）。null なら先頭から。
     */
    data class UserPublicPosts(val uid: Uid, val after: RawCursor?) : QuerySpec {
        companion object {
            /** 1 ページの件数（iOS の UserProfileViewModel の `limit: 50` と同じ。2026-10-06 ユーザー判断）。 */
            const val PAGE_SIZE: Int = PROFILE_POSTS_PAGE_SIZE
        }
    }

    /**
     * 退会で空にする取得：[target] のコレクションから、[uid] に関わる文書を先頭から [PAGE_SIZE] 件取る（設計書のクエリ×インデックス表の 6・7。要件 12.3）。
     * 呼び出し側は、取れた文書を消してから**同じ形で先頭から取り直し**、空になるまで繰り返す。そのため続きの起点（`after`）は持たない。
     * 並び順は付けない（付けると複合インデックスが要り、deploy 漏れで退会が丸ごと失敗する経路が増える。iOS FirestoreService.swift:956-958）。
     *
     * 組み合わせは [DrainTarget] に閉じ、件数は [PAGE_SIZE] に固定する（要件 1.4）。
     *
     * **取得元は常にサーバー**（呼び出し側が [ReadSource.DEFAULT] を渡しても [DefaultFirestoreReader] が SERVER にする）。
     * 通信が切れたときにキャッシュの一部を「全部消えた」と誤認して、残りを消さずに退会を終えないため（iOS FirestoreService.swift:960-965）。
     *
     * @property target 取る対象（コレクションと、uid を照合するフィールドの組）。
     * @property uid 退会するユーザーの uid（ログイン中の本人）。
     */
    data class DrainByField(val target: DrainTarget, val uid: Uid) : QuerySpec {
        companion object {
            /**
             * 1 回に取る件数（iOS の followsPageSize・reactionsPageSize と同じ 50 件）。
             * follows の rules は list に `request.query.limit <= 50` を課し、上限なしの取得は拒否される（firestore.rules:237）。
             */
            const val PAGE_SIZE: Int = 50
        }
    }

    /**
     * 退会で消す、自分の文書の全件取得：[collection] の [uid] の文書を、件数の上限なしで全て取る（設計書の表の 8・9。要件 12.3）。
     * iOS も投稿・下書き・お気に入りは上限なしで取って一括削除する（FirestoreService.swift:925-941）。続きの起点は持たず、並び順も付けない。
     *
     * 取得元は [DrainByField] と同じ理由で**常にサーバー**。全件の取りこぼしは、投稿が退会後も公開のまま見え続ける実害になる
     * （iOS FirestoreService.swift:920-921）。
     *
     * @property collection 取る対象のコレクション。
     * @property uid 退会するユーザーの uid（ログイン中の本人）。
     */
    data class AllOwned(val collection: OwnedCollection, val uid: Uid) : QuerySpec
}

/**
 * [QuerySpec.DrainByField] が取る対象。コレクション名と照合するフィールド名は [DefaultFirestoreReader] の計画（[QueryPlan]）にだけ書く。
 * 名前は退会の段階（contract の `DeletionStage`）に揃えてある。
 */
enum class DrainTarget {
    /** 自分がフォローした側：`follows` の `followerId == uid`。 */
    FOLLOWS_AS_FOLLOWER,

    /** 自分がフォローされた側：`follows` の `followeeId == uid`。 */
    FOLLOWS_AS_FOLLOWEE,

    /** 自分が付けたいいね：`likes` の `userId == uid`。 */
    LIKES,

    /** 自分が書いたコメント：`comments` の `userId == uid`。 */
    COMMENTS,
}

/** [QuerySpec.AllOwned] が取る対象のコレクション（設計書の OwnedCollection）。コレクション名は [DefaultFirestoreReader] の計画にだけ書く。 */
enum class OwnedCollection {
    /** 自分の投稿：`posts` の `userId == uid`。 */
    POSTS,

    /** 自分の下書き：`drafts` の `userId == uid`。 */
    DRAFTS,

    /** 自分のお気に入り：`users/{uid}/favorites` の全件。 */
    FAVORITES,
}

/** プロフィールの投稿一覧（自分・他人）の 1 ページの件数。2 つの形で同じ値を使うため 1 か所に置く。 */
private const val PROFILE_POSTS_PAGE_SIZE: Int = 50

/**
 * 読み取り口（[FirestoreReader.count]）が受け付ける集計の形（設計書の CountSpec。:688）。[QuerySpec] と同じく閉じた集合で表す（要件 1.4）。
 * 集計は常にサーバーで行い、ドキュメントの中身は読まない（件数だけ。取得の上限に左右されない）。
 * 形ごとの条件は [DefaultFirestoreReader] の計画（[CountPlan]）にだけ書く。
 *
 * M4 で、投稿数の数え直し（タスク 23.1）に使う 2 つを置いた。どちらも等値の条件だけなので複合インデックスは要らない
 * （iOS が本番で同じ形を実行している：FirestoreService.swift:678-684）。
 */
sealed interface CountSpec {

    /**
     * 自分の全投稿数：`posts` の `userId == uid` を、公開範囲で絞らずに数える（設計書のクエリ×インデックス表の 4。要件 7.19）。
     * 非公開・フォロワー限定の投稿も含むので、rules（`isOwner`）が通るのは [uid] がログイン中の本人のときだけである。
     *
     * @property uid ログイン中のユーザーの uid。
     */
    data class OwnPosts(val uid: Uid) : CountSpec

    /**
     * 自分の公開投稿数：`posts` の `userId == uid` かつ `visibility == public` を数える（表の 5。要件 7.19）。
     * 公開プロフィール（他人に見せる値）に書く数なので、非公開・フォロワー限定の投稿の件数を含めない。
     *
     * @property uid ログイン中のユーザーの uid。
     */
    data class OwnPublicPosts(val uid: Uid) : CountSpec
}

/**
 * 読み取りの取得元（設計書 :689）。SERVER はキャッシュを使わない（退会の取得などで、キャッシュの一部を全件と誤認しないため）。
 * 退会の取得（[QuerySpec.DrainByField]・[QuerySpec.AllOwned]）は、ここで何を渡しても SERVER で読む。
 */
enum class ReadSource { DEFAULT, SERVER }

/**
 * 続きの起点。前のページの最後の 1 件（変換前の生のドキュメント）を指す。
 * 中身は SDK のスナップショットだが、SDK の型を外に出さないよう不透明な値として持つ（[FirebaseFirestoreReadClient] だけが戻す）。
 * 作れるのはこのモジュールの中（読み取り口）だけで、等しさは同じ値かどうか（同一性）で決まる。
 */
class RawCursor internal constructor(internal val token: Any)

/**
 * クエリの結果（設計書の RawPage）。表示用への変換はしない（投稿は PostDocumentReader。タスク 7.2）。
 *
 * @property documents 変換前の生のドキュメントの列（クエリの順）。
 * @property cursor 最後の 1 件を起点とするカーソル。結果が 0 件なら null。
 *   変換できずに飛ばす投稿も含めた生の最後の 1 件なので、末尾が壊れた投稿でも同じページを読み直さない（設計書「フィード読み込み」）。
 */
class RawPage(val documents: List<RawDocument>, val cursor: RawCursor?)
