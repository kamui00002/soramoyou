//
//  SoratomoDependencies.swift
//  Soramoyou
//
//  そらともの画面が使うサービスの容れ物と、投稿の覚え ⭐️
//  （tasks 13.1・design.md の iOS: 画面と状態）
//
//  そらともの画面（View）は、サービスをこの容れ物から受け取り、ViewModel を作るときに中身を渡す。
//  ⚠️ ViewModel は容れ物を受け取らず、protocol（`SoratomoGroupServiceProtocol` など）を直接受け取る。
//     こうすると、ViewModel の単体テストは容れ物を組み立てずに、モックだけで書ける。
//  ⚠️ View の init で受け取る（`@EnvironmentObject` は View の init の中で読めず、`@StateObject` の
//     ViewModel を作るときに依存を渡せないため）。
//

import FirebaseAuth
import Foundation

// MARK: - 投稿の覚え

/// セッションの間、タイムラインで読んだ投稿を覚えておく置き場
///
/// 投稿詳細の行き先（`SoratomoDestination.skyDetail`）は ID だけを持ち、サービスには投稿 1 件を
/// 取得する口が無い。そこで、タイムライン（13.5）が読んだ投稿をここに覚え、投稿詳細（13.9）がここから読む。
///
/// - 通知からの行き先はタイムラインまでなので、投稿詳細は必ずタイムラインを経由して開く。
///   それでも見つからない（覚えを消した後など）ときは、投稿詳細は「表示できません」の表示にする。
/// - サインアウト時の消去（`clear()`）の配線は 14.1。
@MainActor
final class SoratomoSkyLookup {
    /// 覚えている投稿（グループ ID と投稿 ID の組 → 投稿）
    private var skies: [Key: SoratomoSky] = [:]

    /// 投稿を引くための鍵（投稿 ID はグループの中でだけ一意なので、グループ ID と組にする）
    private struct Key: Hashable {
        let groupId: String
        let skyId: String
    }

    init() {}

    /// 投稿を覚える（同じ投稿は新しい内容で上書きする）
    /// - Parameter newSkies: タイムラインの監視で届いた投稿
    func remember(_ newSkies: [SoratomoSky]) {
        for sky in newSkies {
            skies[Key(groupId: sky.groupId, skyId: sky.id)] = sky
        }
    }

    /// 投稿を忘れる（削除した投稿を、詳細で出さないため）
    func forget(groupId: String, skyId: String) {
        skies[Key(groupId: groupId, skyId: skyId)] = nil
    }

    /// 覚えている投稿を引く
    /// - Returns: 覚えていなければ nil
    func sky(groupId: String, skyId: String) -> SoratomoSky? {
        skies[Key(groupId: groupId, skyId: skyId)]
    }

    /// 覚えをすべて消す（サインアウト用。配線は 14.1）
    func clear() {
        skies = [:]
    }
}

// MARK: - サービスの容れ物

/// そらともの画面が使うサービスの容れ物
///
/// アプリでは `live` を 1 つだけ使う（`SoratomoProfileStore` と `SoratomoSkyLookup` はセッションの間の
/// 保持なので、画面ごとに作り直さない）。Preview では `init` で作る。
///
/// ⚠️ この容れ物は `ObservableObject` にしない。中の `profileStore` の変化を View に伝えるには、
///    View が `@ObservedObject` で `profileStore` を別に持つこと（容れ物越しには伝わらない）。
@MainActor
final class SoratomoDependencies {
    /// グループ（作成・参加・再発行・一覧・監視・メンバー）
    let groupService: any SoratomoGroupServiceProtocol
    /// 投稿（タイムライン・作成・削除・今日の件数）
    let skyService: any SoratomoSkyServiceProtocol
    /// 画像（アップロード・削除）
    let imageStore: any SoratomoImageStoreProtocol
    /// 表示名とそらとも通知の保存
    let profileService: any SoratomoProfileServiceProtocol
    /// 投稿者とメンバーの表示名・アイコン（セッションの間だけ保持）
    let profileStore: SoratomoProfileStore
    /// 通知の事前説明と設定の案内の判定
    let primer: any SoratomoNotificationPrimerProtocol
    /// 通信の有無
    let network: NetworkStatusMonitor
    /// タイムラインで読んだ投稿の覚え（投稿詳細が読む）
    let skyLookup: SoratomoSkyLookup
    /// ⭐️ 通報とブロック（release-gate 9.2）
    let moderationService: any SoratomoModerationServiceProtocol
    /// ⭐️ ガイドラインへの同意の状態と記録（release-gate 9.5）
    let guidelineService: any SoratomoGuidelineServiceProtocol
    /// ⭐️ ブロックした投稿者（release-gate 9.1）。すべてのグループのタイムラインと投稿詳細が同じものを読む
    let blockedAuthors: SoratomoBlockedAuthors
    /// ⭐️ この端末で通報した投稿（release-gate 9.1）。すべてのグループのタイムラインと投稿詳細が同じものを読む
    let reportedSkies: SoratomoReportedSkies
    /// いまログインしている利用者の uid（未ログインなら nil）
    let currentUid: () -> String?

    /// いま開いているタイムラインの ViewModel（投稿詳細から、タイムラインと同じ削除の経路を使うため）
    ///
    /// - タイムラインが表示されたときに自分の ViewModel を入れる（`@StateObject` は init の中ではまだ作られないため）
    /// - 弱参照なので、タイムラインが画面の積み重ねから外れれば自然に nil になる。
    ///   ⚠️ タイムラインの `onDisappear` で消さない（投稿詳細を上に積んだときにも呼ばれるため）
    /// - 投稿詳細は、グループ ID が一致するときだけ使う（別のグループの ViewModel を使わないため）
    weak var activeTimelineViewModel: SoratomoTimelineViewModel?

    /// - Parameters: 各サービス。テストや Preview では、モックを渡す
    ///   （`skyLookup`・`blockedAuthors`・`reportedSkies` に既定値を付けないのは、既定の引数がメインアクターの外で
    ///   評価され、メインアクターの型の init を呼べないため）
    init(
        groupService: any SoratomoGroupServiceProtocol,
        skyService: any SoratomoSkyServiceProtocol,
        imageStore: any SoratomoImageStoreProtocol,
        profileService: any SoratomoProfileServiceProtocol,
        profileStore: SoratomoProfileStore,
        primer: any SoratomoNotificationPrimerProtocol,
        network: NetworkStatusMonitor,
        skyLookup: SoratomoSkyLookup,
        moderationService: any SoratomoModerationServiceProtocol,
        guidelineService: any SoratomoGuidelineServiceProtocol,
        blockedAuthors: SoratomoBlockedAuthors,
        reportedSkies: SoratomoReportedSkies,
        currentUid: @escaping () -> String?
    ) {
        self.groupService = groupService
        self.skyService = skyService
        self.imageStore = imageStore
        self.profileService = profileService
        self.profileStore = profileStore
        self.primer = primer
        self.network = network
        self.skyLookup = skyLookup
        self.moderationService = moderationService
        self.guidelineService = guidelineService
        self.blockedAuthors = blockedAuthors
        self.reportedSkies = reportedSkies
        self.currentUid = currentUid
    }

    /// サインアウトのときに、セッションの間だけ持つものを空にする（ContentView のサインアウトの後片付けから呼ぶ）
    ///
    /// 表示名とアイコンの保持・投稿の覚え（14.1）と、ブロックの一覧・通報の記録のメモリ（release-gate 9.6・要件 9.4・9.6）。
    /// ⚠️ 端末の通報の記録（UserDefaults）は消さない。同じ人が入り直したときも隠したままにするため（決定事項 6）。
    ///    消すのは退会のときだけ（`SoratomoReportedSkies.erase`・SettingsViewModel）
    func clearSessionState() {
        profileStore.clear()
        skyLookup.clear()
        blockedAuthors.clear()
        reportedSkies.clear()
    }

    /// アプリ全体で使う本物の容れ物
    ///
    /// サインアウト時は、ContentView が `live.clearSessionState()` と `SoratomoImageCache.clear()` を呼ぶ。
    static let live = SoratomoDependencies(
        groupService: SoratomoGroupService(),
        skyService: SoratomoSkyService(),
        imageStore: SoratomoImageStore(),
        profileService: SoratomoProfileService(),
        profileStore: SoratomoProfileStore(),
        primer: SoratomoNotificationPrimer(),
        network: .shared,
        skyLookup: SoratomoSkyLookup(),
        moderationService: SoratomoModerationService(),
        guidelineService: SoratomoGuidelineService(),
        blockedAuthors: SoratomoBlockedAuthors(),
        reportedSkies: SoratomoReportedSkies(),
        currentUid: { Auth.auth().currentUser?.uid }
    )
}
