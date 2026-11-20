// ⭐️☁️ 依存の組み立てと Firebase・PostHog の初期化をまとめる 1 か所（タスク 5.1・要件 1.2・2.2・2.9）
package com.yoshidometoru.soramoyou.di

import android.content.Context
import android.net.ConnectivityManager
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.analytics.FirebaseAnalytics
import com.google.firebase.crashlytics.FirebaseCrashlytics
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.storage.FirebaseStorage
import com.yoshidometoru.soramoyou.BuildConfig
import com.yoshidometoru.soramoyou.LOG_TAG
import com.yoshidometoru.soramoyou.data.remote.read.DefaultFirestoreReader
import com.yoshidometoru.soramoyou.data.remote.read.FirebaseFirestoreReadClient
import com.yoshidometoru.soramoyou.data.remote.read.FirestoreReader
import com.yoshidometoru.soramoyou.data.remote.write.BuildConfigWriteGate
import com.yoshidometoru.soramoyou.data.remote.write.DefaultStorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.FirebaseStorageWriteClient
import com.yoshidometoru.soramoyou.data.remote.write.StorageGateway
import com.yoshidometoru.soramoyou.data.remote.write.WriteGate
import com.yoshidometoru.soramoyou.platform.AnalyticsFacade
import com.yoshidometoru.soramoyou.platform.ConnectivityManagerNetworkSource
import com.yoshidometoru.soramoyou.platform.CrashReporter
import com.yoshidometoru.soramoyou.platform.CrashlyticsSdkClient
import com.yoshidometoru.soramoyou.platform.DefaultAnalyticsFacade
import com.yoshidometoru.soramoyou.platform.DefaultCrashReporter
import com.yoshidometoru.soramoyou.platform.DefaultNetworkMonitor
import com.yoshidometoru.soramoyou.platform.FirebaseAnalyticsSdkClient
import com.yoshidometoru.soramoyou.platform.NetworkMonitor
import com.yoshidometoru.soramoyou.platform.PostHogSdkClient
import com.yoshidometoru.soramoyou.platform.PostHogSetup
import kotlinx.coroutines.tasks.await

/** Storage のアップロード・削除・URL 取得の再試行を打ち切るまでの時間（ミリ秒）。SDK の既定は 10 分・10 分・2 分（レビュー R06）。 */
private const val STORAGE_RETRY_LIMIT_MILLIS = 60_000L

/**
 * アプリ全体の依存を組み立てる、ただ 1 つの場所（設計書の部品 AppContainer。DI は手動：research.md）。
 * [com.yoshidometoru.soramoyou.SoramoyouApplication] の起動時に 1 回だけ作り、アプリの寿命と同じだけ生きる。
 *
 * - Firestore・Storage のインスタンスを得るのはこのファイルだけ（設計書「M1の書き込みゼロ保証」2。
 *   FirebaseInstanceCreationSiteTest がソースを走査して確かめる）。
 * - Firestore はメモリだけのキャッシュで使い（[FirestoreSettingsFactory]）、ログアウトで破棄して作り直せるよう
 *   [ResettableInstance] に入れて渡す。使う側は、操作のたびに `firestore.current()` から得る。
 * - Firebase 自体（FirebaseApp）の初期化は、Firebase の SDK が持つ FirebaseInitProvider が、Application.onCreate より前に
 *   google-services.json の値で済ませている。ここでは、それを前提に各 SDK のインスタンスを得る。
 *
 * 握りつぶした失敗（分析・Crashlytics・接続状態の監視）は、[logFailure] で Logcat の警告に出す。
 *
 * @param context アプリの Context。Activity の Context を渡しても、Application の Context に替えて持つ。
 */
class AppContainer(context: Context) {

    private val appContext: Context = context.applicationContext

    /** google-services.json の値で、FirebaseInitProvider が初期化済みの既定の FirebaseApp。 */
    private val firebaseApp: FirebaseApp = FirebaseApp.getInstance()

    /** 接続先の Firebase のプロジェクト ID（[FirebaseProjectCheck] で本番かを確かめる）。 */
    val firebaseProjectId: String? = firebaseApp.options.projectId

    /**
     * Firestore のインスタンスの入れ物。ログアウト・退会の完了時に `reset()` する（SessionManager・タスク 8.2）。
     * 停止は SDK の terminate（登録簿から外す→停止）と clearPersistence。clearPersistence はメモリだけのキャッシュでは
     * 消すものが無いが、設計書の手順（SessionManager）どおりに行い、停止したインスタンスにだけ呼べるので terminate の後に置く。
     * Task の await は kotlinx-coroutines-play-services の拡張で、firebase-common が compile の依存として持ち込んでいる
     * （firebase-common 22.2.1 の pom で確認。依存を足していない）。
     */
    val firestore: ResettableInstance<FirebaseFirestore> = ResettableInstance(
        create = { FirebaseFirestore.getInstance(firebaseApp) },
        configure = {
            it.firestoreSettings = FirestoreSettingsFactory.memoryOnly()
            // デバッグビルドだけ、Firestore の詳細ログを Logcat に出す（タスク 11.2：本番の M1 で書き込みのログが出ないことを端末で確かめるため）。
            // 配布用（release）には出さない。足す前は、エミュレータへ実際に書いても Firestore の行が 0 行だった（2026-10-08 実測）
            FirebaseFirestore.setLoggingEnabled(BuildConfig.DEBUG)
            // 検証用の変種だけ、開発機のエミュレータへ向ける。設定の後に呼んでよい（useEmulator は、まだ使っていないインスタンスなら
            // いまの設定にエミュレータの宛先を重ねる。firebase-firestore 26.6.0 のバイトコードで確認）。作り直すたびに当てる
            if (BuildConfig.USE_FIREBASE_EMULATOR) it.useEmulator(FirebaseEmulator.HOST, FirebaseEmulator.FIRESTORE_PORT)
        },
        release = { old ->
            // terminate は呼んだ時点で登録簿から外す（同期）。これを ResettableInstance のロックの中で行う
            val terminated = old.terminate()
            suspend {
                terminated.await()
                old.clearPersistence().await()
            }
        },
    )

    /**
     * Storage のインスタンス。使うのはアップロードと削除の入口（タスク 6.3）。キャッシュを持たないので作り直さない。
     * 電波が切れたとき SDK は既定で約 10 分（アップロード・削除）再試行し、その間は投稿の画面から出られない
     * （アップロード中は戻る・キャンセルを止める決定②は変えない）ため、3 つの再試行の上限を約 1 分に縮める。iOS は既定のまま（レビュー R06）。
     */
    val storage: FirebaseStorage by lazy {
        FirebaseStorage.getInstance(firebaseApp).also {
            it.maxUploadRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS
            it.maxDownloadRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS
            it.maxOperationRetryTimeMillis = STORAGE_RETRY_LIMIT_MILLIS
            if (BuildConfig.USE_FIREBASE_EMULATOR) it.useEmulator(FirebaseEmulator.HOST, FirebaseEmulator.STORAGE_PORT)
        }
    }

    /**
     * 書き込みの可否（タスク 6.1）。ビルドのマイルストーン設定だけで決まり、実行時には変わらない（M1 は全て無効）。
     * 書き込みの入口（タスク 6.2・6.3）と、書き込みを伴う画面の導線の表示の切り替えが、同じこれを見る。
     */
    val writeGate: WriteGate = BuildConfigWriteGate

    init {
        // PostHog は、分析の窓口が送り始めるより前に初期化する（初期化の前に送ったものは SDK が捨てる）
        // 検証用の変種は初期化しない（iOS と共有の本番の PostHog のプロジェクトへ送らない。初期化しなければ SDK は何も送らない）
        if (!BuildConfig.USE_FIREBASE_EMULATOR) PostHogSetup.setUp(appContext)
    }

    /** 非致命エラーの記録（Crashlytics）。 */
    val crashReporter: CrashReporter =
        DefaultCrashReporter(CrashlyticsSdkClient(FirebaseCrashlytics.getInstance()), ::logFailure)

    /** 分析イベントの単一の送信窓口（PostHog と Firebase Analytics）。 */
    val analytics: AnalyticsFacade = DefaultAnalyticsFacade(
        postHog = PostHogSdkClient(),
        firebase = FirebaseAnalyticsSdkClient(FirebaseAnalytics.getInstance(appContext)),
        crashReporter = crashReporter,
        reportFailure = ::logFailure,
    )

    /**
     * Storage へのアップロードと削除の唯一の入口（タスク 6.3）。Storage のインスタンスは使うときに [storage] から得る
     * （ここで作っても Storage はまだ初期化しない）。
     */
    val storageGateway: StorageGateway = DefaultStorageGateway(
        gate = writeGate,
        client = FirebaseStorageWriteClient { storage },
        analytics = analytics,
    )

    /**
     * Firestore からの読み取りの唯一の入口（タスク 7.1）。Firestore のインスタンスは読み取りのたびに [firestore] から得る
     * （ログアウトで作り直されたものを使うため）。
     */
    val firestoreReader: FirestoreReader = DefaultFirestoreReader(FirebaseFirestoreReadClient { firestore.current() })

    /** ネットワークの接続状態。作った時点で OS の通知の登録を行う（DefaultNetworkMonitor）。 */
    val networkMonitor: NetworkMonitor = DefaultNetworkMonitor(
        ConnectivityManagerNetworkSource(
            requireNotNull(appContext.getSystemService(ConnectivityManager::class.java)) { "ConnectivityManager を取得できない" },
        ),
        ::logFailure,
    )

    // ── 認証（タスク 8.x）。並行して足される部品と import の行がぶつからないよう、ここでは完全修飾名で書く ──

    /**
     * ログアウト・退会の完了時に、端末内のそのユーザーのデータを消す（タスク 8.2）。
     * 画面で共有する状態を持つ部品は、作られたときにここへ register する。Firestore は止めて手放し、次の利用で作り直される。
     */
    val sessionManager: com.yoshidometoru.soramoyou.platform.SessionManager =
        com.yoshidometoru.soramoyou.platform.DefaultSessionManager(
            imageCache = com.yoshidometoru.soramoyou.platform.CoilImageCacheCleaner(appContext),
            resetFirestore = { firestore.reset() },
            analytics = analytics,
        )

    /**
     * 走っている取り消さない書き込み（プロフィールの保存・投稿の削除の後半）の数（全体レビュー 4 回目 Q03）。アプリ全体で 1 つ。
     * [profileEditor]・[postDeleter] が数え、ログアウト（[authRepository]）がその終わりを待つので、3 つに同じこれを渡す
     * （ログアウトの組み立てより前に作る）。走っている間だけ数えるので SessionManager に登録しない。
     */
    val inFlightWrites: com.yoshidometoru.soramoyou.data.repository.InFlightWrites =
        com.yoshidometoru.soramoyou.data.repository.InFlightWrites()

    /**
     * 編集機能の端末内の保存の置き場（バックアップに入らない場所）。全ての編集の保存部品に同じものを渡すので、作るのはここ 1 か所。
     * ログアウト・退会の後始末（[editDataPurger]）が [authRepository]・[accountDeletionService] の組み立てより前に要るので、ここで作る
     * （プロパティは書いた順に初期化されるため、後ろに置くと組み立ての時点で null になる）。
     */
    val editFiles: com.yoshidometoru.soramoyou.data.edit.EditFileStore =
        com.yoshidometoru.soramoyou.data.edit.EditFileStore.forApp(appContext)

    /**
     * ログアウト・退会のときに、端末の編集の途中（と、匿名のログアウト・退会では下書きも）を消す後始末（Kiro android-edit-tools 19.2）。
     * [authRepository] と [accountDeletionService] の両方に同じものを渡す。
     */
    val editDataPurger: com.yoshidometoru.soramoyou.data.edit.UserEditDataPurger =
        com.yoshidometoru.soramoyou.data.edit.DefaultUserEditDataPurger(editFiles, analytics)

    /**
     * ログインと認証状態の監視（タスク 8.1）・ログアウト（タスク 8.2）。作った時点で、端末に保持されたセッションの確認を始める。
     * 書き込みの入口には依存しない（要件 2.2）。ログアウトは、走っている取り消さない書き込みの終わりを上限まで待ってから行う。
     */
    val authRepository: com.yoshidometoru.soramoyou.data.repository.AuthRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultAuthRepository(
            com.yoshidometoru.soramoyou.data.repository.FirebaseAuthClient(
                com.google.firebase.auth.FirebaseAuth.getInstance(firebaseApp).also {
                    if (BuildConfig.USE_FIREBASE_EMULATOR) it.useEmulator(FirebaseEmulator.HOST, FirebaseEmulator.AUTH_PORT)
                },
            ),
            sessionManager,
            inFlightWrites,
            purger = editDataPurger,
        )

    /**
     * 画面で読み込んでよい画像の URL の形（全体レビュー 4 回目 R11）。ビルドの変種ごとに 1 つ：本番は本番の Storage、検証用はエミュレータの Storage。
     * 画像の URL を読む部品（投稿の変換・投稿者の表示・プロフィール）は、作るときにこれを必ず受け取る。
     */
    private val remoteImageUrls: com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy =
        com.yoshidometoru.soramoyou.data.remote.read.RemoteImageUrlPolicy.forBuild(BuildConfig.USE_FIREBASE_EMULATOR)

    /** 投稿者の名前とアイコン（タスク 9.2）。作った時点で sessionManager へ登録し、ログアウトで捨てる。 */
    val authorProfileCache: com.yoshidometoru.soramoyou.data.repository.AuthorProfileCache =
        com.yoshidometoru.soramoyou.data.repository.DefaultAuthorProfileCache(firestoreReader, sessionManager, remoteImageUrls)

    // ── フィード（タスク 9.1）。並行して足される部品とぶつからないよう、ここでも完全修飾名で書く ──

    /** 公開投稿のフィードのページ取得（タスク 9.1）。状態を持たないので SessionManager に登録しない。 */
    val feedRepository: com.yoshidometoru.soramoyou.data.repository.FeedRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultFeedRepository(
            firestoreReader,
            com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader(remoteImageUrls),
            analytics,
        )

    /** 自分がブロック中のユーザーの一覧（タスク 9.1）。uid は読むたびにいまの認証状態から得る。 */
    val blockListRepository: com.yoshidometoru.soramoyou.data.repository.BlockListRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultBlockListRepository(
            firestoreReader,
            { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
            analytics,
        )

    /** 自分・他人のプロフィールと投稿一覧の読み取り（タスク 15.1）。状態を持たないので SessionManager に登録しない。uid は読むたびにいまの認証状態から得る。 */
    val profileRepository: com.yoshidometoru.soramoyou.data.repository.ProfileRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultProfileRepository(
            firestoreReader,
            com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader(remoteImageUrls),
            { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
            analytics,
            remoteImageUrls,
        )

    /** 投稿 1 件の取得（タスク 10.1）。状態を持たないので SessionManager に登録しない。 */
    val postReadRepository: com.yoshidometoru.soramoyou.data.repository.PostReadRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultPostReadRepository(
            firestoreReader,
            com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader(remoteImageUrls),
        )

    // ── アカウント文書の作成・補完（タスク 14.2・14.3）。ここでも完全修飾名で書く ──

    /**
     * Firestore への書き込みの唯一の入口（タスク 6.2）。可否は [writeGate] で決まる（M1 のビルドでは全てが `WriteBlocked` になる）。
     * Firestore のインスタンスは書き込みのたびに [firestore] から得る（ログアウトで作り直されたものを使うため）。
     *
     * 書き手の uid は、認証の SDK の `currentUser` から直接得る。[authRepository] の `session` は、認証状態の通知（非同期）で
     * 切り替わるので、アカウントの作成の直後は、まだ `SignedIn` になっていないことがある。それを使うと、作成直後の文書の作成が
     * 「未ログイン」として断られうる。SDK の `currentUser` は、アカウントを作る・ログインする処理が戻る時点で切り替わっている。
     * FirebaseAuth のインスタンスは、アプリごとに 1 つだけ返る（[authRepository] の組み立てで作成済みで、エミュレータの接続も済んでいる）。
     */
    val firestoreWriteGateway: com.yoshidometoru.soramoyou.data.remote.write.FirestoreWriteGateway =
        com.yoshidometoru.soramoyou.data.remote.write.DefaultFirestoreWriteGateway(
            writeGate,
            com.yoshidometoru.soramoyou.contract.document.AllowListShapeValidator,
            com.yoshidometoru.soramoyou.data.remote.write.FirebaseFirestoreWriteClient { firestore.current() },
            analytics,
        ) {
            com.google.firebase.auth.FirebaseAuth.getInstance(firebaseApp).currentUser?.uid?.let { com.yoshidometoru.soramoyou.contract.Uid(it) }
        }

    /** アカウントの作成直後に、アカウント文書を作る（タスク 14.2）。状態を持たないので SessionManager に登録しない。 */
    val accountBootstrapper: com.yoshidometoru.soramoyou.data.repository.AccountBootstrapper =
        com.yoshidometoru.soramoyou.data.repository.DefaultAccountBootstrapper(firestoreWriteGateway, analytics)

    /**
     * 欠けているアカウント文書の補完（タスク 14.3）。ログインしている間は、いまの認証状態（[authRepository] の `session`）から uid と
     * メールアドレスを得る（呼ぶのはプロフィール画面の表示時と書き込みの直前で、アカウントの作成の直後ではないので、通知の遅れは起きない）。
     * 補完の結果は、何かを作ったときだけ Logcat に出す（分析のイベントは iOS 版にあるものに閉じているため。値は列挙の名前だけ）。
     * 出すのは警告（Log.w）。リリースの R8 の規則（proguard-rules.pro）が Log.v・d・i を消すので、端末の確認で数える合図が消えないようにする（レビュー R12）。
     * `users`・`publicProfiles` が両方とも無いときは、作る前に認証のアカウントがサーバーに残っているかを reload で確かめる（レビュー R10）。
     * 状態を持たないので SessionManager に登録しない。
     */
    val accountDocumentRepairer: com.yoshidometoru.soramoyou.data.repository.AccountDocumentRepairer =
        com.yoshidometoru.soramoyou.data.repository.DefaultAccountDocumentRepairer(
            gateway = firestoreWriteGateway,
            analytics = analytics,
            currentUser = { authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn },
            recordOutcome = { outcome ->
                if (outcome != com.yoshidometoru.soramoyou.data.repository.RepairOutcome.ALREADY_PRESENT) {
                    Log.w(LOG_TAG, "アカウント文書を補った: $outcome")
                }
            },
            // 両方とも無いときだけ呼ばれる（レビュー R10）。認証の SDK の currentUser を呼ぶたびに読み（firestoreWriteGateway と同じ）、
            // reload でサーバーにアカウントの記録が残っているかを問い合わせる。消されたアカウント・通信の失敗などは全て「通らない」に倒す
            // （コルーチンの取り消しだけは、そのまま伝える）。この判断は accountExistsOnServer の中にあり、単体テストで確かめる（全体レビュー 4 回目 Q14）
            verifyAccount = {
                com.yoshidometoru.soramoyou.data.repository.accountExistsOnServer(
                    com.google.firebase.auth.FirebaseAuth.getInstance(firebaseApp).currentUser,
                ) { user -> user.reload().await() }
            },
        )

    // ── プロフィール編集（タスク 16.1・16.2）。ここでも完全修飾名で書く ──

    /**
     * 選んだ写真をアップロード用の JPEG にする（タスク 16.1）。写真は ContentResolver で content URI から読む。
     * 状態を持たないので SessionManager に登録しない。
     */
    val imagePipeline: com.yoshidometoru.soramoyou.data.image.ImagePipeline =
        com.yoshidometoru.soramoyou.data.image.DefaultImagePipeline(
            com.yoshidometoru.soramoyou.data.image.AndroidImageCodec(appContext.contentResolver),
        )

    /**
     * 選んだ写真を読み込めるかを確かめる（タスク 21.2・要件 6.9）。投稿の変換と同じ窓口（AndroidImageCodec）で復号する。
     * 窓口は状態を持たないので、[imagePipeline] とは別に作る。状態を持たないので SessionManager に登録しない。
     */
    val photoProbe: com.yoshidometoru.soramoyou.data.image.PhotoProbe =
        com.yoshidometoru.soramoyou.data.image.DefaultPhotoProbe(
            com.yoshidometoru.soramoyou.data.image.AndroidImageCodec(appContext.contentResolver),
        )

    /**
     * 自分のプロフィールの保存（タスク 16.2）。可否は [writeGate] の PROFILE_EDIT（M1 のビルドでは `WriteBlocked`）。
     * 公開プロフィールが無いときの補完は [accountDocumentRepairer] に任せる。状態を持たないので SessionManager に登録しない。
     */
    val profileEditor: com.yoshidometoru.soramoyou.data.repository.ProfileEditor =
        com.yoshidometoru.soramoyou.data.repository.DefaultProfileEditor(
            gateway = firestoreWriteGateway,
            storage = storageGateway,
            pipeline = imagePipeline,
            reader = firestoreReader,
            repairer = accountDocumentRepairer,
            analytics = analytics,
            inFlight = inFlightWrites,
        )

    // ── いいね（タスク 18.2）。ここでも完全修飾名で書く ──

    /**
     * いいねの書き込みと、いいね済みかどうかの確認（タスク 18.2）。可否は [writeGate] の LIKE（M2 以前のビルドでは `WriteBlocked`）。
     * 書き手の uid は、いまの認証状態（[authRepository] の `session`）から呼ぶたびに読む。
     * 状態を持たないので SessionManager に登録しない（全画面で共有する表示の状態は LikeStateStore（タスク 18.3）が持つ）。
     */
    val likeRepository: com.yoshidometoru.soramoyou.data.repository.LikeRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultLikeRepository(
            gateway = firestoreWriteGateway,
            reader = firestoreReader,
            analytics = analytics,
            currentUid = { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
        )

    /**
     * いいねの表示状態を全画面で共有する（タスク 18.3）。アプリ全体で 1 つ。作った時点で sessionManager へ登録し、ログアウトで捨てる。
     * uid は呼ぶたびにいまの認証状態から読む（ログインしていなければ押しても確かめても何もしない）。
     */
    val likeStateStore: com.yoshidometoru.soramoyou.data.repository.LikeStateStore =
        com.yoshidometoru.soramoyou.data.repository.DefaultLikeStateStore(
            repository = likeRepository,
            analytics = analytics,
            currentUid = { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
            sessionManager = sessionManager,
        )

    // ── 投稿（タスク 23.x）。ここでも完全修飾名で書く ──

    /**
     * 自分の投稿数をサーバーで数え直して保存する（タスク 23.1）。可否は [writeGate] の POSTS_COUNT_SYNC（M3 以前のビルドでは `WriteBlocked`）。
     * 呼ぶのは投稿の作成（タスク 23.3）と削除（タスク 24）。状態を持たないので SessionManager に登録しない。
     */
    val postsCountSynchronizer: com.yoshidometoru.soramoyou.data.repository.PostsCountSynchronizer =
        com.yoshidometoru.soramoyou.data.repository.DefaultPostsCountSynchronizer(
            reader = firestoreReader,
            gateway = firestoreWriteGateway,
            analytics = analytics,
        )

    /**
     * 写真の撮影日時の読み取り（タスク 22.2。配線はタスク 23.2）。投稿の公開が先頭の写真の撮影日時と時間帯を決めるのに使う。
     * EXIF と写真選択画面の撮影日時の列を ContentResolver で読む。状態を持たないので SessionManager に登録しない。
     */
    val photoMetadataReader: com.yoshidometoru.soramoyou.data.image.PhotoMetadataReader =
        com.yoshidometoru.soramoyou.data.image.DefaultPhotoMetadataReader(
            com.yoshidometoru.soramoyou.data.image.AndroidPhotoMetadataSource(appContext.contentResolver),
        )

    /**
     * 作った投稿の知らせ（タスク 23.3）。投稿の文書の保存が成功したら流し、フィードと自分のプロフィールが一覧の先頭に差し込む。
     * 溜めないので SessionManager に登録しない。
     */
    val createdPosts: com.yoshidometoru.soramoyou.data.repository.CreatedPosts =
        com.yoshidometoru.soramoyou.data.repository.CreatedPosts()

    /**
     * 投稿の公開（タスク 23.2・23.3）。可否は [writeGate] の POST_CREATE（M3 以前のビルドでは画像のアップロードが `WriteBlocked`）。
     * アプリ全体で 1 つ（二重送信の防止は、この 1 つの中のロックで行う）。uid は投稿のたびにいまの認証状態から読む。
     * 文書の保存（作成・投稿数の数え直し・post_completed・知らせ）は [com.yoshidometoru.soramoyou.data.repository.DefaultPostDocumentSaver]。
     * ⚠️ 最後の状態（成功・失敗）はログアウトしても残る。投稿画面（タスク 23.5）が、表示に使う前にそれを扱う。
     */
    val postPublisher: com.yoshidometoru.soramoyou.data.repository.PostPublisher =
        com.yoshidometoru.soramoyou.data.repository.DefaultPostPublisher(
            storage = storageGateway,
            pipeline = imagePipeline,
            saver = com.yoshidometoru.soramoyou.data.repository.DefaultPostDocumentSaver(
                gateway = firestoreWriteGateway,
                countSynchronizer = postsCountSynchronizer,
                reader = com.yoshidometoru.soramoyou.data.remote.read.DefaultPostDocumentReader(remoteImageUrls),
                createdPosts = createdPosts,
                analytics = analytics,
            ),
            analytics = analytics,
            currentUid = { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
        )

    /**
     * 消した投稿の知らせ（タスク 24）。自分の投稿の削除が終わったら流し、フィードと自分のプロフィールがその投稿を一覧から除く。
     * 溜めないので SessionManager に登録しない。
     */
    val deletedPosts: com.yoshidometoru.soramoyou.data.repository.DeletedPosts =
        com.yoshidometoru.soramoyou.data.repository.DeletedPosts()

    /**
     * 自分の投稿の削除（タスク 24）。可否は [writeGate] の POST_DELETE（M3 以前のビルドでは `WriteBlocked`。詳細も削除を出さない）。
     * 状態を持たないので SessionManager に登録しない。uid は削除のたびにいまの認証状態から読む。
     */
    val postDeleter: com.yoshidometoru.soramoyou.data.repository.PostDeleter =
        com.yoshidometoru.soramoyou.data.repository.DefaultPostDeleter(
            reader = firestoreReader,
            gateway = firestoreWriteGateway,
            storage = storageGateway,
            countSynchronizer = postsCountSynchronizer,
            deletedPosts = deletedPosts,
            analytics = analytics,
            currentUid = { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
            inFlight = inFlightWrites,
        )

    // ── 通報・ブロック（タスク 29.1）。ここでも完全修飾名で書く ──

    /**
     * 通報・ブロックの書き込みと、ブロック中のユーザーの取得（タスク 29.1）。可否は [writeGate] の REPORT・BLOCK（M4 以前のビルドでは `WriteBlocked`）。
     * ブロック中の uid は [blockListRepository]、名前とアイコンは [authorProfileCache] から得る。
     * 書き手の uid は、いまの認証状態（[authRepository] の `session`）から呼ぶたびに読む。状態を持たないので SessionManager に登録しない。
     */
    val moderationRepository: com.yoshidometoru.soramoyou.data.repository.ModerationRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultModerationRepository(
            gateway = firestoreWriteGateway,
            blockList = blockListRepository,
            authors = authorProfileCache,
            analytics = analytics,
            currentUid = { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
        )

    // ── 広告（タスク 32.1）。ここでも完全修飾名で書く ──

    /**
     * 同意の取得（UMP）と広告 SDK（GMA Next-Gen）の初期化（タスク 32.1）。アプリ全体で 1 つ。始めるのは MainActivity の起動時
     * （UMP は Activity が要る）。ID は app/build.gradle.kts がビルドの種類で選んで焼き込んだ値で、マイルストーンが M5 より前の
     * ビルドでは何もしない。同意の段は main で、初期化は背景のスレッド（Dispatchers.IO）で行う。失敗は Logcat の警告に出し、広告を出さないだけにする。
     * ログアウトで変わる状態を持たないので SessionManager に登録しない。
     */
    val adsController: com.yoshidometoru.soramoyou.platform.AdsController =
        com.yoshidometoru.soramoyou.platform.DefaultAdsController(
            config = com.yoshidometoru.soramoyou.platform.AdsConfig.fromBuildConfig(
                BuildConfig.ADS_BUILD_KIND,
                BuildConfig.ADMOB_APP_ID,
                BuildConfig.ADMOB_BANNER_UNIT_ID,
            ),
            enabled = com.yoshidometoru.soramoyou.platform.adsEnabledAt(BuildConfigWriteGate.milestone),
            sdk = com.yoshidometoru.soramoyou.platform.GmaMobileAdsInitializer(appContext),
            scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Main.immediate),
            background = kotlinx.coroutines.Dispatchers.IO,
            reportFailure = ::logFailure,
        )

    // ── 退会（タスク 31.2・31.3）。ここでも完全修飾名で書く ──

    /**
     * アカウントとデータの削除（タスク 31.2 の手順の本体と、31.3 のいいね・コメントの削除）。可否は [writeGate] の ACCOUNT_DELETE
     * （M4 以前のビルドでは書き込みが `WriteBlocked`）。使うのは退会の画面（タスク 31.5）。
     * 端末内のデータの消去は手順の本体が成功の後に [sessionManager] で行う（画面から呼び直さない）。
     * uid は呼ぶたびにいまの認証状態から読む。実行中の段階（`stage`）は削除の間だけの表示用で、ログアウトで捨てるものが無いので
     * SessionManager に登録しない。いいね・コメントの削除の部品は、この手順の本体だけが使うので、ここで作って渡す。
     */
    val accountDeletionService: com.yoshidometoru.soramoyou.data.repository.AccountDeletionService =
        com.yoshidometoru.soramoyou.data.repository.DefaultAccountDeletionService(
            auth = authRepository,
            reader = firestoreReader,
            gateway = firestoreWriteGateway,
            storage = storageGateway,
            reactions = com.yoshidometoru.soramoyou.data.repository.DefaultOwnReactionsDeleter(
                reader = firestoreReader,
                gateway = firestoreWriteGateway,
                analytics = analytics,
            ),
            sessionManager = sessionManager,
            analytics = analytics,
            currentUid = { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid },
            purger = editDataPurger,
        )

    // ── ブロックの知らせ（タスク 29.2）。ここでも完全修飾名で書く ──

    /**
     * ブロックしたユーザーの知らせ（タスク 29.2）。フィード・投稿詳細の通報・ブロックの操作がブロックに成功したら流し、
     * フィードがその投稿者の投稿を表示中の一覧から除く。溜めないので SessionManager に登録しない。
     */
    val blockedUsers: com.yoshidometoru.soramoyou.data.repository.BlockedUsers =
        com.yoshidometoru.soramoyou.data.repository.BlockedUsers()

    // ── アプリ内フィードバック（タスク 30）。ここでも完全修飾名で書く ──

    /**
     * アプリ内フィードバックの書き込み（タスク 30）。可否は [writeGate] の FEEDBACK（M4 以前のビルドでは `WriteBlocked`）。
     * 書き手の uid は [firestoreWriteGateway] が認証の SDK から読む（画面が渡す `userId` と一致しなければ契約が止める）。
     * 状態を持たないので SessionManager に登録しない。
     */
    val feedbackRepository: com.yoshidometoru.soramoyou.data.repository.FeedbackRepository =
        com.yoshidometoru.soramoyou.data.repository.DefaultFeedbackRepository(
            gateway = firestoreWriteGateway,
            analytics = analytics,
        )

    // ── 編集機能の部品（Kiro android-edit-tools 18.1）。ここでも完全修飾名で書く ──

    /**
     * アプリの寿命のスコープ。画面（ViewModel）が閉じても続けたい保存と、装備の最初の読み込みに使う。
     * 親を持たない SupervisorJob なので、1 つの失敗が他に伝わらず、アプリのプロセスが終わるまで生きる。
     * 他の部品の持つスコープ（広告の初期化用など）とは共有しない。
     */
    val appScope: kotlinx.coroutines.CoroutineScope =
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default)

    /** 装備（使うツールの並び）。最初の読み込みは [appScope] で始める。 */
    val loadoutStore: com.yoshidometoru.soramoyou.data.edit.LoadoutStore =
        com.yoshidometoru.soramoyou.data.edit.DefaultLoadoutStore(editFiles, analytics, appScope)

    /** 編集の途中の保存。 */
    val editSessionStore: com.yoshidometoru.soramoyou.data.edit.EditSessionStore =
        com.yoshidometoru.soramoyou.data.edit.DefaultEditSessionStore(editFiles, analytics)

    /** 端末の下書き。 */
    val localDraftRepository: com.yoshidometoru.soramoyou.data.edit.LocalDraftRepository =
        com.yoshidometoru.soramoyou.data.edit.DefaultLocalDraftRepository(editFiles, analytics)

    /** 選んだ写真をアプリの中に写す。撮影日時は [photoMetadataReader] で読む。 */
    val workingPhotoImporter: com.yoshidometoru.soramoyou.data.edit.WorkingPhotoImporter =
        com.yoshidometoru.soramoyou.data.edit.DefaultWorkingPhotoImporter(
            editFiles,
            appContext.contentResolver,
            photoMetadataReader,
            analytics,
        )

    /** 編集のプレビューを描く。写真は ContentResolver で読む（投稿の変換と同じ窓口）。 */
    val editPreviewRenderer: com.yoshidometoru.soramoyou.data.image.EditPreviewRenderer =
        com.yoshidometoru.soramoyou.data.image.DefaultEditPreviewRenderer(
            com.yoshidometoru.soramoyou.data.image.AndroidImageCodec(appContext.contentResolver),
            analytics,
            kotlinx.coroutines.Dispatchers.IO,
            kotlinx.coroutines.Dispatchers.Default,
        )

    /** いまログインしている人の uid（ログインしていなければ null）。呼ぶたびにいまの認証状態から読む。 */
    val currentUid: () -> com.yoshidometoru.soramoyou.contract.Uid? =
        { (authRepository.session.value as? com.yoshidometoru.soramoyou.data.repository.SessionState.SignedIn)?.uid }

    /** 握りつぶした失敗を Logcat の警告に出す（各部品の reportFailure。[where] は「送信先.操作」の名前で、値を含まない）。 */
    private fun logFailure(where: String, error: Exception) {
        Log.w(LOG_TAG, "失敗を握りつぶした: $where", error)
    }
}
