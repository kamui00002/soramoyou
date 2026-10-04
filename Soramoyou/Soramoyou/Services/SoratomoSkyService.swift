//
//  SoratomoSkyService.swift
//  Soramoyou
//
//  そらとも（友達グループで空を共有）の投稿のサービス ⭐️
//  タイムラインの監視と、投稿データの作成・削除・日次件数・サーバーでの存在確認
//  （tasks 11.2・design.md の SoratomoSkyService）。
//
//  ⚠️ このサービスが扱うのは投稿の「データ」（Firestore の `soratomoGroups/{groupId}/skies/{skyId}`）だけ。
//     画像（Storage）は SoratomoImageStore（tasks 11.4）が扱う。
//  ⚠️ 計測（SoratomoAnalytics.log）はここでは呼ばない。画面の ViewModel（tasks 13.x）の責務。
//  ⚠️ 上限を 20・40・60 と伸ばす操作や、引き下げて更新したときに 20 へ戻す操作は ViewModel の責務。
//     このサービスは `limit` を受け取って、その件数の監視を 1 本張るだけ。
//

import FirebaseFirestore
import Foundation

/// そらともの投稿のサービス（`SoratomoSkyServiceProtocol` の Firestore 実装）
///
/// - 作成と削除は、読み取りの無いトランザクション（`set` / `delete` だけ）で行う。
///   書き込み用のバッチと違い、トランザクションは端末内に積まれない。オフラインでは失敗する
///   （Firestore の仕様: 「トランザクションはオンラインで行う」）ので、投稿や削除が後から勝手に実行されない（要件 12.3）。
/// - Firestore のエラーは `SoratomoError.fromFirestore` で写す（読み取り・監視は `.read`、作成・削除は `.write`）。
/// - `Firestore` には Sendable の印が付いていないが、Firestore の API はスレッドセーフなので `@unchecked` にする。
final class SoratomoSkyService: SoratomoSkyServiceProtocol, @unchecked Sendable {
    // MARK: - Properties

    /// Firestore（テストや別の環境では差し替えられる）
    private let db: Firestore

    /// - Parameter db: 使う Firestore
    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    // MARK: - SoratomoSkyServiceProtocol

    /// 新しい投稿 ID を作る（通信しない）
    ///
    /// Firestore の自動 ID はクライアントで作る乱数で、通信は要らない。
    /// 画像のパス（`SoratomoImagePaths`）にも使うので、保存より前に作っておく。
    func newSkyId(groupId: String) -> String {
        guard SoratomoSkyService.isUsableDocumentId(groupId) else {
            // 不正な groupId でパスを作ると Firestore が例外で落ちるので、パスに依らない自動 ID だけ作る。
            // この ID で `createSky` を呼ぶと、そこで `.unknown` として失敗する。
            return db.collection(SoratomoFirestorePath.groups).document().documentID
        }
        return skiesCollection(groupId: groupId).document().documentID
    }

    /// タイムラインを監視する（作成日時の新しい順・最大 `limit` 件）
    ///
    /// - `includeMetadataChanges: true` で監視する。理由: `false` だと、キャッシュの結果（`isFromCache == true`）の後に
    ///   サーバーが同じ内容を返しても、中身が変わらないので 2 回目の結果が届かない。ViewModel が失敗の表示や
    ///   続きの読み込み中を解除できなくなる（オフラインの表示そのものは `NetworkStatusMonitor` で出している）。`limit` は 20〜60 なので、metadata だけの発火が増えるコストは無視できる。
    /// - `createdAt` は送信直後の推定値で読む（`serverTimestampBehavior = .estimate`）。
    /// - 札が止められた（`cancel()` か解放）後は、すでにメインアクターへの引き継ぎ待ちだった結果も届けない。
    ///   上限を伸ばして張り直すとき、古い監視の遅れた結果が新しい結果を上書きしないようにするため。
    func observeTimeline(
        groupId: String,
        limit: Int,
        onChange: @escaping @MainActor (Result<SoratomoTimelineSnapshot, SoratomoError>) -> Void
    ) -> SoratomoListenerToken {
        guard SoratomoSkyService.isUsableDocumentId(groupId) else {
            // 不正な groupId でパスを作ると Firestore が例外で落ちる。読めないグループとして 1 回だけ失敗を返す
            Task { @MainActor in
                onChange(.failure(.notMember))
            }
            return SoratomoListenerToken {}
        }

        let effectiveLimit = SoratomoSkyService.effectiveLimit(limit)
        let state = ListenerState()
        let registration = skiesCollection(groupId: groupId)
            .order(by: Field.createdAt, descending: true)
            .limit(to: effectiveLimit)
            .addSnapshotListener(includeMetadataChanges: true) { snapshot, error in
                // Firestore の型（非 Sendable かもしれない）はここで値に変えてから、メインアクターへ渡す
                let result: Result<SoratomoTimelineSnapshot, SoratomoError>
                if let snapshot {
                    let documents = snapshot.documents.map { document in
                        SourceDocument(
                            id: document.documentID,
                            path: document.reference.path,
                            data: document.data(with: .estimate)
                        )
                    }
                    result = .success(
                        SoratomoSkyService.makeTimelineSnapshot(
                            documents: documents,
                            groupId: groupId,
                            limit: effectiveLimit,
                            isFromCache: snapshot.metadata.isFromCache
                        )
                    )
                } else {
                    // snapshot も error も無いことは起きない想定。起きたら読めなかったものとして扱う
                    let cause: Error = error ?? SoratomoError.unknown
                    result = .failure(SoratomoError.fromFirestore(cause, access: .read))
                }
                Task { @MainActor in
                    guard !state.isCancelled else { return }
                    onChange(result)
                }
            }

        return SoratomoListenerToken {
            state.cancel()
            registration.remove()
        }
    }

    /// 投稿を作る（作成日時はサーバーの時刻）
    ///
    /// 読み取りの無いトランザクションで `set` だけを行う（オフラインでは失敗し、端末内に積まれない）。
    /// `unavailable`・期限切れは `.network` になるが、サーバーには届いている可能性がある。
    /// 呼び出し側は `skyExistsOnServer` で確かめてから成否を決めること。
    func createSky(_ draft: SoratomoSkyDraft) async throws(SoratomoError) {
        guard SoratomoSkyService.isUsableDocumentId(draft.groupId),
              SoratomoSkyService.isUsableDocumentId(draft.skyId)
        else {
            throw SoratomoError.unknown
        }
        let reference = skiesCollection(groupId: draft.groupId).document(draft.skyId)
        let fields = SoratomoSkyService.makeCreateFields(for: draft)
        do {
            _ = try await db.runTransaction { transaction, _ -> Any? in
                transaction.setData(fields, forDocument: reference)
                return nil
            }
        } catch {
            throw SoratomoError.fromFirestore(error, access: .write)
        }
    }

    /// 投稿がサーバーにあるかを、キャッシュを使わずに確かめる
    ///
    /// 結果が確定しない失敗（`.network`）の後に使う。オフラインなら読めないので `.network` で失敗する
    /// （その場合、呼び出し側は「確かめられなかった」として扱う）。
    func skyExistsOnServer(groupId: String, skyId: String) async throws(SoratomoError) -> Bool {
        guard SoratomoSkyService.isUsableDocumentId(groupId),
              SoratomoSkyService.isUsableDocumentId(skyId)
        else {
            throw SoratomoError.unknown
        }
        do {
            let snapshot = try await skiesCollection(groupId: groupId)
                .document(skyId)
                .getDocument(source: .server)
            return snapshot.exists
        } catch {
            throw SoratomoError.fromFirestore(error, access: .read)
        }
    }

    /// 投稿を削除する（画像は消さない）
    ///
    /// 読み取りの無いトランザクションで `delete` だけを行う（オフラインでは失敗し、端末内に積まれない）。
    ///
    /// ⚠️ すでに無い文書を削除すると、ルール（`resource.data.authorId` を読む）が評価できず、
    ///    `permissionDenied` で拒否される。tasks 11.2 が「書き込みだけのトランザクション」と定めているので、
    ///    このサービスは存在確認の読み取りを入れない。
    ///    失敗したら、呼び出し側は `skyExistsOnServer` で成否を確かめること。
    func deleteSky(groupId: String, skyId: String) async throws(SoratomoError) {
        guard SoratomoSkyService.isUsableDocumentId(groupId),
              SoratomoSkyService.isUsableDocumentId(skyId)
        else {
            throw SoratomoError.unknown
        }
        let reference = skiesCollection(groupId: groupId).document(skyId)
        do {
            _ = try await db.runTransaction { transaction, _ -> Any? in
                transaction.deleteDocument(reference)
                return nil
            }
        } catch {
            throw SoratomoError.fromFirestore(error, access: .write)
        }
    }

    /// 自分の今日（端末のタイムゾーン）の投稿件数を数える
    ///
    /// `authorId == 自分` かつ `createdAt >= 今日の 0 時` の件数を、サーバーで集計する（`count()`・キャッシュは使わない）。
    /// 複合インデックス（authorId 昇順・createdAt 昇順）を使う。数えられなければ nil を返す（投稿は止めない）。
    func countTodaySkies(groupId: String, authorId: String, since startOfLocalDay: Date) async -> Int? {
        guard SoratomoSkyService.isUsableDocumentId(groupId) else {
            return nil
        }
        do {
            let snapshot = try await skiesCollection(groupId: groupId)
                .whereField(Field.authorId, isEqualTo: authorId)
                .whereField(Field.createdAt, isGreaterThanOrEqualTo: Timestamp(date: startOfLocalDay))
                .count
                .getAggregation(source: .server)
            return snapshot.count.intValue
        } catch {
            // 利用者の入力（uid・グループ名など）は残さず、エラーの種類だけを残す
            let nsError = error as NSError
            print("⚠️ そらとも 今日の投稿件数を数えられませんでした error=\(nsError.domain)#\(nsError.code)")
            return nil
        }
    }

    // MARK: - Private

    /// 投稿のコレクション（`soratomoGroups/{groupId}/skies`）
    /// - Important: `groupId` は `isUsableDocumentId` を通したものだけ渡すこと
    private func skiesCollection(groupId: String) -> CollectionReference {
        db.collection(SoratomoFirestorePath.groups)
            .document(groupId)
            .collection(SoratomoFirestorePath.skies)
    }
}

// MARK: - Firestore に触らない部分（単体テストの対象）

extension SoratomoSkyService {
    /// Firestore の投稿の項目名（firestore.rules の `isValidSoratomoSky` と一致させる）
    ///
    /// ⚠️ アプリの `SoratomoSky.pixelWidth` / `pixelHeight` は、Firestore では `width` / `height`。
    enum Field {
        static let authorId = "authorId"
        static let caption = "caption"
        static let width = "width"
        static let height = "height"
        static let createdAt = "createdAt"
    }

    /// 読み取った 1 件の文書（Firestore の型に依存しない形）
    ///
    /// `QueryDocumentSnapshot` は Firestore 無しでは作れないので、監視の中でこの形に変えてから変換する。
    /// （`QueryDocumentSnapshot` への extension は、他のデコーダーと名前が衝突するので作らない。）
    struct SourceDocument {
        /// 文書 ID（投稿 ID）
        let id: String
        /// 文書のパス（例: `soratomoGroups/g1/skies/s1`）。壊れた文書をログで特定するために使う
        let path: String
        /// 文書の項目（`createdAt` は `serverTimestampBehavior = .estimate` で読んだ `Timestamp`）
        let data: [String: Any]
    }

    /// 文書を `SoratomoSky` に変換できなかった理由（項目名だけを持つ。項目の値は入れない）
    enum DecodeError: Error, Equatable {
        /// 必須の項目が無い
        case missingField(String)
        /// 項目の型や値が想定と違う
        case invalidField(String)
    }

    /// 変換に失敗した 1 件の情報
    struct DecodeFailure {
        /// 失敗した文書のパス
        let path: String
        /// 失敗の理由
        let error: DecodeError
    }

    /// 文書の項目を `SoratomoSky` に変換する
    ///
    /// - Parameters:
    ///   - id: 文書 ID
    ///   - groupId: 投稿先のグループ ID（文書の中には持たない。パスから決まる）
    ///   - data: 文書の項目
    /// - Throws: 必須の項目が無い、または型・値が想定と違うとき `DecodeError`
    static func decodeSky(id: String, groupId: String, data: [String: Any]) throws -> SoratomoSky {
        let authorId = try requiredValue(Field.authorId, in: data, as: String.self)
        guard !authorId.isEmpty else {
            throw DecodeError.invalidField(Field.authorId)
        }
        let pixelWidth = try requiredValue(Field.width, in: data, as: Int.self)
        let pixelHeight = try requiredValue(Field.height, in: data, as: Int.self)
        // 幅・高さが 0 以下だと、画面が縦横比を計算できない
        guard pixelWidth >= 1 else { throw DecodeError.invalidField(Field.width) }
        guard pixelHeight >= 1 else { throw DecodeError.invalidField(Field.height) }
        let createdAt = try requiredValue(Field.createdAt, in: data, as: Timestamp.self).dateValue()

        // キャプションは無くてよい（項目ごと省かれる）。あるのに文字列でなければ壊れた文書として扱う
        var caption: String?
        if data[Field.caption] != nil {
            guard let text = data[Field.caption] as? String else {
                throw DecodeError.invalidField(Field.caption)
            }
            caption = text
        }

        return SoratomoSky(
            id: id,
            groupId: groupId,
            authorId: authorId,
            caption: caption,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            createdAt: createdAt
        )
    }

    /// 文書の一覧を `SoratomoSky` の配列に変換する（壊れた 1 件だけを飛ばす）
    ///
    /// 1 件の変換に失敗しても例外は投げず、その 1 件だけを飛ばして `onFailure` に渡す。
    /// （`compactMap { try? }` で黙って落とすのは禁止＝docs/tech-spec.md の Firebase 実装規約）
    /// - Parameters:
    ///   - documents: 読み取った文書（作成日時の新しい順）
    ///   - groupId: 投稿先のグループ ID
    ///   - onFailure: 1 件の変換に失敗したときに呼ばれる（既定はログ。テストでは差し替える）
    /// - Returns: 変換できた投稿（元の並び順のまま）
    static func decodeSkies(
        _ documents: [SourceDocument],
        groupId: String,
        onFailure: (DecodeFailure) -> Void = SoratomoSkyService.reportDecodeFailure
    ) -> [SoratomoSky] {
        var skies: [SoratomoSky] = []
        for document in documents {
            do {
                try skies.append(decodeSky(id: document.id, groupId: groupId, data: document.data))
            } catch {
                // decodeSky が投げるのは DecodeError だけ。万一ほかの型が来ても、同じ形で記録して飛ばす
                let reason = error as? DecodeError ?? DecodeError.invalidField("unknown")
                onFailure(DecodeFailure(path: document.path, error: reason))
            }
        }
        return skies
    }

    /// 監視の 1 回分の結果を作る
    ///
    /// ⚠️ `mayHaveMore` は、変換後ではなく**読んだ文書の件数**で決める。壊れた文書を飛ばした分だけ
    ///    変換後の件数が減るので、変換後の件数で決めると、続きがあるのに「もう無い」と判断してしまう。
    /// - Parameters:
    ///   - documents: 読み取った文書
    ///   - groupId: 投稿先のグループ ID
    ///   - limit: 監視に使った件数の上限（`effectiveLimit` を通したもの）
    ///   - isFromCache: 端末のキャッシュからの結果か
    ///   - onFailure: 1 件の変換に失敗したときに呼ばれる（既定はログ）
    static func makeTimelineSnapshot(
        documents: [SourceDocument],
        groupId: String,
        limit: Int,
        isFromCache: Bool,
        onFailure: (DecodeFailure) -> Void = SoratomoSkyService.reportDecodeFailure
    ) -> SoratomoTimelineSnapshot {
        SoratomoTimelineSnapshot(
            skies: decodeSkies(documents, groupId: groupId, onFailure: onFailure),
            isFromCache: isFromCache,
            mayHaveMore: mayHaveMore(documentCount: documents.count, limit: limit)
        )
    }

    /// 続きがありうるか（読んだ文書の件数が上限と同じか）
    /// - Parameters:
    ///   - documentCount: 読んだ文書の件数（変換に失敗して飛ばした分を含む）
    ///   - limit: 監視に使った件数の上限
    static func mayHaveMore(documentCount: Int, limit: Int) -> Bool {
        // 件数は上限を超えない（超えたら続きがあるのは確かなので、等しいか超えたら true）
        documentCount >= limit
    }

    /// 監視に使う件数の上限（1 以上にそろえる）
    ///
    /// Firestore の `limit(to:)` は 0 以下を渡すと例外で落ちる。ViewModel は 20・40・60 を渡すが、
    /// 誤った値でアプリが落ちないようにする。
    static func effectiveLimit(_ limit: Int) -> Int {
        max(1, limit)
    }

    /// 文書 ID（グループ ID・投稿 ID）として使えるか
    ///
    /// 空文字や `/` を含む文字列でパスを作ると、Firestore が例外で落ちる（Swift では捕まえられない）ので、
    /// パスを作る前に確かめる。実際の ID は Firestore の自動 ID なので、通常は必ず通る。
    static func isUsableDocumentId(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/")
    }

    /// 投稿の作成で書く項目を作る
    ///
    /// firestore.rules の `isValidSoratomoSky` に合わせる:
    /// 項目は `authorId`・`caption`・`width`・`height`・`createdAt` の 5 つだけ。
    /// `caption` 以外は必須で、`createdAt` はサーバーの時刻（`request.time` と等しいときだけ通る）。
    /// - Parameter draft: 保存する投稿の中身
    /// - Returns: 書き込む項目。キャプションが無い（または空の）ときは `caption` ごと省く
    static func makeCreateFields(for draft: SoratomoSkyDraft) -> [String: Any] {
        var fields: [String: Any] = [
            Field.authorId: draft.authorId,
            Field.width: draft.pixelWidth,
            Field.height: draft.pixelHeight,
            // 端末の時計で並び順を操作させないため、サーバーの時刻にする
            Field.createdAt: FieldValue.serverTimestamp(),
        ]
        // ルールは「項目が無い」か「1〜100 文字」だけを通す。空の文字列を書くと拒否される
        if let caption = draft.caption, !caption.isEmpty {
            fields[Field.caption] = caption
        }
        return fields
    }

    /// 変換に失敗した文書をログに残す（既定の `onFailure`）
    ///
    /// `PostDocumentDecoder.report` と同じ二段構え。
    /// - コンソールにパスと理由を残す。
    /// - 本番で気づけるよう、`soratomo_sky_decode_failed` として PostHog / Firebase Analytics にも送る
    ///   （`SoratomoAnalytics.log` ではなく、既存の `LoggingService` 経由。そらともの計測イベントの表には載せない）。
    /// - Crashlytics には送らない。壊れた文書 1 件でも、メンバーが開くたびに発生してエラーが積み上がるため。
    ///
    /// パスは内部 ID だけ（グループ名・キャプションなどは含まない）。理由も項目名だけで、項目の値は含めない（要件 15.1・15.3）。
    static func reportDecodeFailure(_ failure: DecodeFailure) {
        let errorDescription = String(describing: failure.error)
        print("❌ そらとも投稿デコード失敗 path=\(failure.path) error=\(errorDescription)")
        LoggingService.shared.logEvent("soratomo_sky_decode_failed", parameters: [
            "path": failure.path,
            "error": errorDescription,
        ])
    }

    // MARK: - 項目の読み取り

    /// 必須の項目を読む
    /// - Throws: 項目が無ければ `.missingField`、型が違えば `.invalidField`
    private static func requiredValue<Value>(
        _ key: String,
        in data: [String: Any],
        as _: Value.Type
    ) throws -> Value {
        guard let raw = data[key] else {
            throw DecodeError.missingField(key)
        }
        guard let value = raw as? Value else {
            throw DecodeError.invalidField(key)
        }
        return value
    }

    // MARK: - 監視の状態

    /// 監視が止められたかを、Firestore のコールバックとメインアクターの間で共有する入れ物
    ///
    /// 止める操作（札の `cancel()`・どのスレッドからでも呼ばれうる）と、結果を届ける側（メインアクター）が
    /// 同時に触るので、ロックで守る。
    fileprivate final class ListenerState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        /// もう止められたか
        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        /// 止められたことを記録する
        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }
}
