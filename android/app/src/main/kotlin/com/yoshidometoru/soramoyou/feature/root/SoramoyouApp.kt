// ⭐️ いちばん外側の画面：認証状態で、読み込み中・ログイン画面・ログイン後のナビゲーションを切り替える（タスク 8.3）
package com.yoshidometoru.soramoyou.feature.root

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.rememberViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.navigation.NavBackStackEntry
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import com.yoshidometoru.soramoyou.contract.PostId
import com.yoshidometoru.soramoyou.contract.Uid
import com.yoshidometoru.soramoyou.R
import com.yoshidometoru.soramoyou.data.repository.SessionState
import com.yoshidometoru.soramoyou.di.AppContainer
import com.yoshidometoru.soramoyou.feature.ads.BannerAdSlot
import com.yoshidometoru.soramoyou.feature.auth.AuthMode
import com.yoshidometoru.soramoyou.feature.auth.AuthViewModel
import com.yoshidometoru.soramoyou.feature.auth.LoginScreen
import com.yoshidometoru.soramoyou.feature.auth.SignUpScreen
import com.yoshidometoru.soramoyou.feature.compose.PostComposerScreen
import com.yoshidometoru.soramoyou.feature.compose.PostComposerViewModel
import com.yoshidometoru.soramoyou.feature.detail.PostDetailScreen
import com.yoshidometoru.soramoyou.feature.detail.PostDetailViewModel
import com.yoshidometoru.soramoyou.feature.feed.FeedScreen
import com.yoshidometoru.soramoyou.feature.feed.FeedViewModel
import com.yoshidometoru.soramoyou.feature.feed.LikeDisplay
import com.yoshidometoru.soramoyou.feature.feedback.FeedbackMetadata
import com.yoshidometoru.soramoyou.feature.feedback.FeedbackScreen
import com.yoshidometoru.soramoyou.feature.feedback.FeedbackViewModel
import com.yoshidometoru.soramoyou.feature.profile.ProfileDestination
import com.yoshidometoru.soramoyou.feature.profile.ProfileEditScreen
import com.yoshidometoru.soramoyou.feature.profile.ProfileEditViewModel
import com.yoshidometoru.soramoyou.feature.profile.ProfileScreen
import com.yoshidometoru.soramoyou.feature.profile.ProfileViewModel
import com.yoshidometoru.soramoyou.feature.profile.UserProfileViewModel
import com.yoshidometoru.soramoyou.feature.profile.profileDestinationOf
import com.yoshidometoru.soramoyou.feature.settings.AccountDeletionScreen
import com.yoshidometoru.soramoyou.feature.settings.AccountDeletionViewModel
import com.yoshidometoru.soramoyou.feature.settings.BlockListScreen
import com.yoshidometoru.soramoyou.feature.settings.BlockListViewModel
import com.yoshidometoru.soramoyou.feature.settings.SettingsScreen
import com.yoshidometoru.soramoyou.feature.settings.SettingsViewModel
import com.yoshidometoru.soramoyou.ui.component.BackdropKind
import com.yoshidometoru.soramoyou.ui.component.LoadingContent
import com.yoshidometoru.soramoyou.ui.component.SkyBackdrop
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.Serializable
import kotlin.reflect.KClass

/** ログイン後のナビゲーションのルート（型安全なルート）。フィード（最初の画面）。 */
@Serializable
data object FeedRoute

/** 設定画面のルート。 */
@Serializable
data object SettingsRoute

/** 投稿の作成（タスク 21.1）。 */
@Serializable
data object PostComposeRoute

/** 投稿詳細のルート（タスク 10.2）。投稿 ID だけを渡し、投稿は詳細の画面で読み直す。 */
@Serializable
data class PostDetailRoute(val postId: String)

/** 自分のプロフィールのルート（タスク 15.2）。 */
@Serializable
data object ProfileRoute

/** プロフィール編集のルート（タスク 16.3）。いまのプロフィールは画面で読み直す。 */
@Serializable
data object ProfileEditRoute

/** 他人のプロフィールのルート（タスク 15.2）。uid だけを渡し、プロフィールは画面で読む。 */
@Serializable
data class UserProfileRoute(val uid: String)

/** 設定の下の「ブロック中のユーザー」のルート（タスク 29.2）。一覧は画面で読む。 */
@Serializable
data object BlockListRoute

/** 設定の下の「ご意見・ご要望」（フィードバック送信）のルート（タスク 30）。 */
@Serializable
data object FeedbackRoute

/** 設定の下の「アカウントを削除」（退会の確認と削除）のルート（タスク 31.5）。 */
@Serializable
data object AccountDeletionRoute

/**
 * バナー広告を出さない行き先（ログイン済みのナビゲーションのルート）。設定の画面と、設定の下に足す画面（29.2 ブロック中のユーザー・
 * 30 意見・31.5 退会の確認）には出さない（iOS 版も設定には広告を出さない。投稿の画面には出す。2026-10-14 ユーザー判断）。
 * いまある設定の下の画面は、下の集合に並べたもの。
 *
 * 出すかどうかを決めるのはこの集合だけ。設定の下に画面を足すタスクは、そのルートをここに 1 行足す
 * （Scaffold の bottomBar の側は触らなくてよい）。
 */
internal val ROUTES_WITHOUT_BANNER: Set<KClass<*>> = setOf(
    SettingsRoute::class,
    BlockListRoute::class,
    FeedbackRoute::class,
    AccountDeletionRoute::class,
)

/**
 * いまの行き先 [destination] でバナー広告を出すか。[ROUTES_WITHOUT_BANNER] のどれでもなければ出す。
 * [isRoute] は「行き先がそのルートか」（本物は Navigation の NavDestination.hasRoute）。Android の型に依らない純関数にして、
 * JVM の単体テストで確かめられるようにしている。
 *
 * 行き先がまだ分からない（[destination] が null。NavHost がグラフを置く前の最初の描画）あいだは出さない。
 * 出さない行き先で一瞬だけ広告を要求して、すぐ捨てることにならないように。
 */
fun <D : Any> showsBannerAt(destination: D?, isRoute: (D, KClass<*>) -> Boolean): Boolean =
    destination != null && ROUTES_WITHOUT_BANNER.none { route -> isRoute(destination, route) }

/**
 * 背景を無地にする行き先（ログイン済みのナビゲーションのルート）。投稿の作成だけ（android-ui-ios-parity 要件 1.9）。
 * 写真の色を見て選ぶ画面なので、空のグラデーションを敷かない（要件の D5）。
 *
 * 無地にするかを決めるのはこの集合だけ。無地にしたい画面を足すタスクは、そのルートをここに 1 行足す。
 */
internal val ROUTES_WITH_PLAIN_BACKDROP: Set<KClass<*>> = setOf(
    PostComposeRoute::class,
)

/**
 * 根の画面 [screen] と今の行き先 [destination] で、いちばん外側に敷く背景の種類（android-ui-ios-parity タスク 7.2・要件 1.1・1.2・1.9）。
 * - 読み込み中は空。ログイン前（ログインと新規登録）は空と雲
 * - ログイン済みは、行き先が [ROUTES_WITH_PLAIN_BACKDROP] のどれかなら無地、それ以外は空
 * - 行き先がまだ分からない（[destination] が null。NavHost がグラフを置く前の最初の描画）あいだも空にする
 *
 * [isRoute] は [showsBannerAt] と同じく「行き先がそのルートか」（本物は Navigation の NavDestination.hasRoute）で、
 * Android の型に依らない純関数にして JVM の単体テストで確かめる（BackdropTest）。
 * 受け取るのは根の画面と行き先だけなので、背景は時刻・時間帯・投稿の内容では変わらない（要件 1.4）。
 */
fun <D : Any> backdropOf(screen: RootScreen, destination: D?, isRoute: (D, KClass<*>) -> Boolean): BackdropKind = when (screen) {
    RootScreen.LOADING -> BackdropKind.SKY
    RootScreen.SIGNED_OUT -> BackdropKind.SKY_WITH_CLOUDS
    RootScreen.SIGNED_IN ->
        if (destination != null && ROUTES_WITH_PLAIN_BACKDROP.any { route -> isRoute(destination, route) }) {
            BackdropKind.PLAIN
        } else {
            BackdropKind.SKY
        }
}

/** 本番の ViewModel に渡す viewModelScope（ViewModel の既定と同じ、Main の即時実行と SupervisorJob）。 */
private fun mainScope(): CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

/**
 * アプリの画面の根。画面の切り替えは [RootViewModel.screen]（認証状態と、新規登録の途中か）だけで決める。
 * - 確認中は読み込み中の表示（ログイン画面を一瞬も出さない）
 * - 未ログインはログイン画面
 * - ログイン済みはフィード・投稿詳細・プロフィール・設定のナビゲーション。ログアウトで未ログインになると、このグラフごと捨てられ、戻る履歴も残らない。
 *   各画面の ViewModel は、[SignedInNavHost] が置くログイン中だけの ViewModelStoreOwner がこのとき clear するので、次のログインへ持ち越さない
 * - 新規登録の途中（アカウントを作ってから文書を書き終えるまで）は、ログイン済みでもログイン前の画面のまま（タスク 14.4）
 */
@Composable
fun SoramoyouApp(container: AppContainer) {
    // RootViewModel が新規登録の途中かを読むので、AuthViewModel は根で作る（どちらも Activity の寿命。LoginRoute も同じものを使う）
    val authViewModel: AuthViewModel = viewModel(
        factory = viewModelFactory {
            initializer {
                AuthViewModel(container.authRepository, container.accountBootstrapper, container.writeGate, container.analytics, mainScope())
            }
        },
    )
    val rootViewModel: RootViewModel = viewModel(
        factory = viewModelFactory {
            initializer {
                RootViewModel(container.authRepository.session, container.analytics, mainScope(), authViewModel.signUpInProgress)
            }
        },
    )
    val screen by rootViewModel.screen.collectAsStateWithLifecycle()
    // ログイン済みのナビゲーション。バナーを出すかを「いまの行き先」で決めるため、NavHost の外（Scaffold の bottomBar）からも
    // 見えるよう、ここで作る。ログイン済みのあいだだけ作り、ログアウトで捨てる（条件の外れた remember は捨てられ、次のログインでは
    // 作り直される。戻る履歴を次のログインへ持ち越さない）。
    // ただし navController を捨てるだけでは、各画面の ViewModel は捨てられない（Navigation が画面の ViewModel を消すのは、その画面を
    // 戻る履歴から外したときだけ）。ViewModel は、SignedInNavHost の中のログイン中だけの ViewModelStoreOwner がログアウトで clear する（レビュー R23）
    val navController = if (screen == RootScreen.SIGNED_IN) rememberNavController() else null
    val destination = navController?.currentBackStackEntryAsState()?.value?.destination

    // 背景は、透明の Scaffold の後ろに、窓いっぱい（システムバーの後ろまで）1 枚だけ敷く（android-ui-ios-parity タスク 7.3・要件 1.6・1.7）。
    // 画面ごとに背景を持たないので、縦に送っても背景は動かず途切れない。種類は根の画面と今の行き先で決める（backdropOf。起動時の読み込み中は空）
    Box(modifier = Modifier.fillMaxSize()) {
        SkyBackdrop(backdropOf(screen, destination) { current, route -> current.hasRoute(route) })
        Scaffold(
            // 枠の地を透明にして、後ろの背景を見せる。文字の基本の色は onBackground の役にする（要件 1.1・1.2）。
            // 透明を渡すと、既定の文字の色（contentColorFor）が LocalContentColor の既定の黒に戻り、ダークで文字が黒になるため（設計書 R5）
            containerColor = Color.Transparent,
            contentColor = MaterialTheme.colorScheme.onBackground,
            // バナー広告の枠は、ログイン済みの画面の下端に固定する（タスク 32.2・要件 14.1・14.5）。Scaffold が枠の高さの分だけ
            // 本文の領域を縮めるので、投稿の画像や操作ボタンとは重ならない。ボトムナビゲーションができたら、その上に移す。
            // 出さない行き先（設定の画面など）は ROUTES_WITHOUT_BANNER で決める。枠は背景を持たないので、枠の左右と
            // ナビゲーションバーの後ろには外側の背景が見える
            bottomBar = {
                if (screen == RootScreen.SIGNED_IN && showsBannerAt(destination) { current, route -> current.hasRoute(route) }) {
                    BannerAdSlot(container.adsController)
                }
            },
        ) { padding ->
            val modifier = Modifier
                .fillMaxSize()
                .padding(padding)
            when (screen) {
                RootScreen.LOADING -> LoadingContent(modifier)
                RootScreen.SIGNED_OUT -> LoginRoute(authViewModel, modifier)
                RootScreen.SIGNED_IN -> if (navController != null) SignedInNavHost(container, navController, modifier)
            }
        }
    }
}

/** ログイン前の画面。ログインと新規登録を [AuthViewModel.mode] で切り替える（iOS はシートで出し分ける）。 */
@Composable
private fun LoginRoute(viewModel: AuthViewModel, modifier: Modifier) {
    val mode by viewModel.mode.collectAsStateWithLifecycle()
    when (mode) {
        AuthMode.SIGN_IN -> {
            val state by viewModel.state.collectAsStateWithLifecycle()
            LoginScreen(
                state = state,
                onEmailChange = viewModel::onEmailChange,
                onPasswordChange = viewModel::onPasswordChange,
                onSignIn = viewModel::signIn,
                onShowSignUp = viewModel::showSignUp,
                modifier = modifier,
            )
        }
        AuthMode.SIGN_UP -> {
            val state by viewModel.signUpState.collectAsStateWithLifecycle()
            // 戻る操作はログインの画面へ。新規登録の途中は showSignIn が何もしないので、戻る操作ごと受け止めて画面に留める
            // （アプリを閉じると ViewModel が捨てられ、文書の作成が途中で止まるため）
            BackHandler { viewModel.showSignIn() }
            SignUpScreen(
                state = state,
                onEmailChange = viewModel::onSignUpEmailChange,
                onPasswordChange = viewModel::onSignUpPasswordChange,
                onConfirmPasswordChange = viewModel::onConfirmPasswordChange,
                onSignUp = viewModel::signUp,
                onContinue = viewModel::continueAfterBootstrapFailure,
                onBack = viewModel::showSignIn,
                modifier = modifier,
            )
        }
    }
}

/**
 * ログイン後のナビゲーション。根の画面が [RootScreen.SIGNED_IN] のあいだだけ合成に入る（[SoramoyouApp]）。
 *
 * NavHost は、ここで作るログイン中だけの ViewModelStoreOwner（rememberViewModelStoreOwner）の下に置く（レビュー R23）。
 * - NavHost はこの owner の store を [navController] に渡し、各画面（戻る履歴の 1 枚ずつ）の ViewModel の store はその子になる
 * - ログアウトで根の画面が SIGNED_IN でなくなると、この関数が合成から抜けて owner が store を clear する。子の store も clear され、
 *   各 ViewModel に渡した scope が閉じるので、session の監視（ProfileViewModel の uid の切り替えなど）も止まる
 * - owner を置かないと、store は Activity のものになる。Navigation が画面の ViewModel を消すのは、その画面を戻る履歴から外したとき
 *   だけなので、ログアウトしても ViewModel が残り、次のログインで古い監視・取得がもう 1 組走る。NavHost が消えた後に戻る履歴を
 *   外しても消えない（遷移の終わりの知らせが来ないため）ので、その形では直さない
 * - 回転などの作り直しでは、親の Activity が生きているので ViewModel は残る（owner は親の寿命に結びついている）
 *
 * 利用者が押す「戻る・閉じる・開く」は、[popFrom]・[navigateFrom] を通す（二度押しの守り。レビュー R04）。
 * 状態で 1 回に限られている自動の閉じる（LaunchedEffect の中の 3 か所）は、守りを通さない。
 */
@Composable
private fun SignedInNavHost(container: AppContainer, navController: NavHostController, modifier: Modifier) {
    CompositionLocalProvider(LocalViewModelStoreOwner provides rememberViewModelStoreOwner()) {
        NavHost(navController = navController, startDestination = FeedRoute, modifier = modifier) {
            composable<FeedRoute> { entry ->
                val viewModel: FeedViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            FeedViewModel(
                                container.feedRepository,
                                container.blockListRepository,
                                container.authorProfileCache,
                                container.likeStateStore,
                                container.writeGate,
                                container.analytics,
                                container.networkMonitor.isOnline,
                                container.authRepository.session,
                                mainScope(),
                                container.moderationRepository,
                                container.blockedUsers,
                                container.createdPosts.events,
                                container.deletedPosts.events,
                            )
                        }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                val authors by viewModel.authors.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                // いいねは 2 つとも集める（サーバーの数が届いたときにも描き直すため。LikeStateStore の注記）
                val liked by viewModel.liked.collectAsStateWithLifecycle()
                val likeCountOverrides by viewModel.likeCountOverrides.collectAsStateWithLifecycle()
                val moderation by viewModel.moderation.state.collectAsStateWithLifecycle()
                // 画面名「ホーム」は、戻る履歴の 1 枚ごとに 1 回だけ送る（全体レビュー 4 回目 Q13）。印は rememberSaveable なので、
                // 回転・ダークモードの切り替えで作り直されても、上に開いた画面（投稿詳細・設定・プロフィール）から戻っても送り直さない
                // （ホームは 1 枚なので、ログインごとに 1 回。前は戻るたびに送っていた）。iOS は起動時に 1 回とタブを切り替えたときに送る
                // （MainTabView.swift:81-92。onAppear ではない）。「投稿」と同じ数え方
                var screenLogged by rememberSaveable { mutableStateOf(false) }
                LaunchedEffect(Unit) {
                    if (!screenLogged) {
                        screenLogged = true
                        viewModel.onScreenShown()
                    }
                }
                FeedScreen(
                    state = state,
                    authors = authors,
                    isOnline = isOnline,
                    likes = LikeDisplay(liked, likeCountOverrides, viewModel.canLike),
                    onRefresh = viewModel::refresh,
                    onLoadMore = viewModel::loadMore,
                    onToggleLike = viewModel::toggleLike,
                    onOpenProfile = { navController.navigateFrom(entry, ProfileRoute) },
                    onOpenSettings = { navController.navigateFrom(entry, SettingsRoute) },
                    onOpenPost = { postId -> navController.navigateFrom(entry, PostDetailRoute(postId.value)) },
                    moderation = moderation,
                    moderationActionsFor = viewModel.moderation::actionsFor,
                    moderationHandlers = viewModel.moderation.handlers,
                    // 投稿の書き込みが有効なビルドだけ、投稿の導線を出す（要件 6.1・M4 から）
                    onCompose = if (viewModel.canPost) {
                        { navController.navigateFrom(entry, PostComposeRoute) }
                    } else {
                        null
                    },
                )
            }
            composable<PostComposeRoute> { entry ->
                val viewModel: PostComposerViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            PostComposerViewModel(
                                container.photoProbe,
                                container.analytics,
                                container.postPublisher,
                                container.networkMonitor.isOnline,
                                // この画面（戻る履歴の 1 枚）の保存の箱。プロセスが落ちても、打った入力を残す（全体レビュー 4 回目 Q09）
                                createSavedStateHandle(),
                                mainScope(),
                                container.workingPhotoImporter,
                                container.editSessionStore,
                                container.localDraftRepository,
                                container.loadoutStore,
                                container.editPreviewRenderer,
                                container.currentUid,
                                container.appScope,
                            )
                        }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                PostComposerScreen(
                    state = state,
                    isOnline = isOnline,
                    onScreenShown = viewModel::onScreenShown,
                    onStop = viewModel::onStop,
                    onPhotosPicked = viewModel::onPhotosPicked,
                    // 選び直しの前の確かめ。requestRepick は値を返さないので、呼んだ直後の確かめを状態から読んで返す
                    // （状態はその場で変わる。画面の引数の状態は次の描き直しまで古いので、画面の側では読めない）。
                    // null なら画面はそのまま写真選択画面を開き、確かめが出たら「選び直す」の答えの後に開く
                    onRequestRepick = {
                        viewModel.requestRepick()
                        viewModel.state.value.leaveQuestion
                    },
                    onShowPhoto = viewModel::showPhoto,
                    onSelectFilter = viewModel::selectFilter,
                    onOpenTool = viewModel::openTool,
                    onSliderChange = viewModel::onSliderChange,
                    onSliderFinished = viewModel::onSliderFinished,
                    onUndo = viewModel::undo,
                    onRedo = viewModel::redo,
                    onCropDrag = viewModel::onCropDrag,
                    onCropNudge = viewModel::onCropNudge,
                    onRotateLeft = viewModel::rotateLeft,
                    onRotateRight = viewModel::rotateRight,
                    onConfirmCrop = viewModel::confirmCrop,
                    onCancelCrop = viewModel::cancelCrop,
                    onRequestLeave = viewModel::requestLeave,
                    onAnswerLeave = viewModel::answerLeave,
                    onSaveDraft = viewModel::saveDraft,
                    onOpenDrafts = viewModel::openDrafts,
                    onOpenDraft = viewModel::openDraft,
                    onDeleteDraft = viewModel::deleteDraft,
                    onOpenLoadout = viewModel::openLoadout,
                    onSaveLoadout = viewModel::saveLoadout,
                    onDismissSheet = viewModel::dismissSheet,
                    onDismissNotice = viewModel::dismissNotice,
                    onGoToInfo = viewModel::goToInfo,
                    onBackToEditing = viewModel::backToEditing,
                    onCaptionChange = viewModel::onCaptionChange,
                    onSelectVisibility = viewModel::selectVisibility,
                    onPublish = viewModel::publish,
                    onDismissPublishError = viewModel::dismissPublishError,
                    onClose = { navController.popFrom(entry) },
                )
            }
            composable<PostDetailRoute> { backStackEntry ->
                val route = backStackEntry.toRoute<PostDetailRoute>()
                val viewModel: PostDetailViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            PostDetailViewModel(
                                PostId(route.postId),
                                container.postReadRepository,
                                container.authorProfileCache,
                                container.likeStateStore,
                                container.postDeleter,
                                container.writeGate,
                                container.analytics,
                                container.networkMonitor.isOnline,
                                { (container.authRepository.session.value as? SessionState.SignedIn)?.uid },
                                mainScope(),
                                container.moderationRepository,
                                container.blockedUsers,
                            )
                        }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                val authors by viewModel.authors.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                val liked by viewModel.liked.collectAsStateWithLifecycle()
                val likeCountOverrides by viewModel.likeCountOverrides.collectAsStateWithLifecycle()
                val deleteState by viewModel.deleteState.collectAsStateWithLifecycle()
                val moderation by viewModel.moderation.state.collectAsStateWithLifecycle()
                val moderationActions by viewModel.moderationActions.collectAsStateWithLifecycle()
                // 消し終えたら詳細を閉じる（iOS の dismiss()）。消した投稿は知らせでフィードとプロフィールの一覧から除かれている
                LaunchedEffect(deleteState.deleted) { if (deleteState.deleted) navController.popBackStack() }
                // 投稿者をブロックできたら詳細を閉じる（iOS の dismiss()：HomeView.swift:1258-1264）。その投稿者の投稿は、
                // 知らせ（BlockedUsers）で下のフィードから除かれている
                LaunchedEffect(moderation.blockedAuthor) { if (moderation.blockedAuthor != null) navController.popBackStack() }
                PostDetailScreen(
                    state = state,
                    authors = authors,
                    isOnline = isOnline,
                    likes = LikeDisplay(liked, likeCountOverrides, viewModel.canLike),
                    deleteState = deleteState,
                    onRetry = viewModel::retry,
                    onToggleLike = viewModel::toggleLike,
                    onBack = { navController.popFrom(backStackEntry) },
                    onRequestDelete = viewModel::requestDelete,
                    onConfirmDelete = viewModel::confirmDelete,
                    onCancelDelete = viewModel::cancelDelete,
                    onDismissDeleteError = viewModel::dismissDeleteError,
                    moderation = moderation,
                    moderationActions = moderationActions,
                    moderationHandlers = viewModel.moderation.handlers,
                    // 投稿者が自分なら自分のプロフィール、他人ならその人のプロフィールへ（要件 5.3・2026-10-06 ユーザー判断）
                    onOpenAuthor = { author ->
                        when (val destination = profileDestinationOf(author, container.authRepository.session.value)) {
                            ProfileDestination.Own -> navController.navigateFrom(backStackEntry, ProfileRoute)
                            is ProfileDestination.Other -> navController.navigateFrom(backStackEntry, UserProfileRoute(destination.uid.value))
                        }
                    },
                )
            }
            composable<ProfileRoute> { entry ->
                val viewModel: ProfileViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            ProfileViewModel(
                                container.profileRepository,
                                container.accountDocumentRepairer,
                                container.writeGate,
                                container.analytics,
                                container.networkMonitor.isOnline,
                                container.authRepository.session,
                                mainScope(),
                                container.createdPosts.events,
                                container.deletedPosts.events,
                            )
                        }
                    },
                )
                val header by viewModel.header.collectAsStateWithLifecycle()
                val posts by viewModel.posts.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                // 画面名「プロフィール」も、戻る履歴の 1 枚ごとに 1 回だけ送る（ホームと同じ。回転でも、投稿詳細・編集から戻っても
                // 送り直さない。ホームから開き直せば新しい 1 枚なので送る）
                var screenLogged by rememberSaveable { mutableStateOf(false) }
                LaunchedEffect(Unit) {
                    if (!screenLogged) {
                        screenLogged = true
                        viewModel.onScreenShown()
                    }
                }
                ProfileScreen(
                    title = stringResource(R.string.profile_title),
                    header = header,
                    posts = posts,
                    isOnline = isOnline,
                    onRefresh = viewModel::refresh,
                    onLoadMore = viewModel::loadMore,
                    onRetryHeader = viewModel::retryHeader,
                    onOpenPost = { postId -> navController.navigateFrom(entry, PostDetailRoute(postId.value)) },
                    onBack = { navController.popFrom(entry) },
                    // 編集の書き込みが有効なビルドだけ、編集の導線を出す（要件 10.6・M1 では出さない）
                    onEdit = if (viewModel.canEdit) {
                        { navController.navigateFrom(entry, ProfileEditRoute) }
                    } else {
                        null
                    },
                )
            }
            composable<ProfileEditRoute> { entry ->
                val viewModel: ProfileEditViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            ProfileEditViewModel(
                                container.profileRepository,
                                container.profileEditor,
                                container.analytics,
                                container.networkMonitor.isOnline,
                                // プロセスが落ちても、打った表示名・自己紹介を残す（全体レビュー 4 回目 Q10）
                                createSavedStateHandle(),
                                mainScope(),
                            )
                        }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                // 保存できたら閉じる（iOS も保存の成功で dismiss する：ProfileEditView.swift:219-226）
                LaunchedEffect(state.saved) { if (state.saved) navController.popBackStack() }
                ProfileEditScreen(
                    state = state,
                    isOnline = isOnline,
                    onDisplayNameChange = viewModel::onDisplayNameChange,
                    onBioChange = viewModel::onBioChange,
                    onIconPicked = viewModel::onIconPicked,
                    onSave = viewModel::save,
                    onRetryLoad = viewModel::retryLoad,
                    onCancel = { navController.popFrom(entry) },
                )
            }
            composable<UserProfileRoute> { backStackEntry ->
                val route = backStackEntry.toRoute<UserProfileRoute>()
                val viewModel: UserProfileViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            UserProfileViewModel(
                                Uid(route.uid),
                                container.profileRepository,
                                container.analytics,
                                container.networkMonitor.isOnline,
                                mainScope(),
                            )
                        }
                    },
                )
                val header by viewModel.header.collectAsStateWithLifecycle()
                val posts by viewModel.posts.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                ProfileScreen(
                    title = null,
                    header = header,
                    posts = posts,
                    isOnline = isOnline,
                    onRefresh = viewModel::refresh,
                    onLoadMore = viewModel::loadMore,
                    onRetryHeader = viewModel::retryHeader,
                    onOpenPost = { postId -> navController.navigateFrom(backStackEntry, PostDetailRoute(postId.value)) },
                    onBack = { navController.popFrom(backStackEntry) },
                )
            }
            composable<SettingsRoute> { entry ->
                val viewModel: SettingsViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer { SettingsViewModel(container.authRepository, container.writeGate, container.analytics, mainScope()) }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                SettingsScreen(
                    state = state,
                    onSignOut = viewModel::signOut,
                    // 戻るは、ブロック中のユーザーの画面と同じく守りを通して 1 つ戻る（設定はフィードから開く）
                    onBack = { navController.popFrom(entry) },
                    // ブロックの書き込みが有効なビルドだけ、「ブロック中のユーザー」を出す（要件 11.5・M5 から）
                    onOpenBlockedUsers = if (viewModel.canManageBlocks) {
                        { navController.navigateFrom(entry, BlockListRoute) }
                    } else {
                        null
                    },
                    // フィードバックの書き込みが有効なビルドだけ、「ご意見・ご要望」を出す（要件 13.1・M5 から）
                    onOpenFeedback = if (viewModel.canSendFeedback) {
                        { navController.navigateFrom(entry, FeedbackRoute) }
                    } else {
                        null
                    },
                    // 退会の書き込みが有効なビルドだけ、「アカウントを削除」を出す（要件 12.1・M5 から）
                    onOpenAccountDeletion = if (viewModel.canDeleteAccount) {
                        { navController.navigateFrom(entry, AccountDeletionRoute) }
                    } else {
                        null
                    },
                )
            }
            composable<BlockListRoute> { entry ->
                val viewModel: BlockListViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer { BlockListViewModel(container.moderationRepository, container.networkMonitor.isOnline, mainScope()) }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                BlockListScreen(
                    state = state,
                    isOnline = isOnline,
                    onRetry = viewModel::retry,
                    onUnblock = viewModel::unblock,
                    onDismissUnblockError = viewModel::dismissUnblockError,
                    onBack = { navController.popFrom(entry) },
                )
            }
            composable<FeedbackRoute> { entry ->
                val viewModel: FeedbackViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            FeedbackViewModel(
                                container.feedbackRepository,
                                { (container.authRepository.session.value as? SessionState.SignedIn)?.uid },
                                // 送信のたびに付ける、アプリのバージョンと端末の情報（要件 13.4。メールアドレス・表示名は付けない）
                                FeedbackMetadata.currentAppVersion(),
                                FeedbackMetadata.currentDeviceInfo(),
                                container.analytics,
                                container.networkMonitor.isOnline,
                                // プロセスが落ちても、打った本文と選んだ種別を残す（全体レビュー 4 回目 Q09）
                                createSavedStateHandle(),
                                mainScope(),
                            )
                        }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                // 画面名は送らない（iOS の FeedbackView も送らない）
                FeedbackScreen(
                    state = state,
                    isOnline = isOnline,
                    onMessageChange = viewModel::onMessageChange,
                    onCategoryChange = viewModel::onCategoryChange,
                    onSubmit = viewModel::submit,
                    onClose = { navController.popFrom(entry) },
                )
            }
            composable<AccountDeletionRoute> { entry ->
                val viewModel: AccountDeletionViewModel = viewModel(
                    factory = viewModelFactory {
                        initializer {
                            AccountDeletionViewModel(
                                container.accountDeletionService,
                                container.analytics,
                                container.networkMonitor.isOnline,
                                mainScope(),
                            )
                        }
                    },
                )
                val state by viewModel.state.collectAsStateWithLifecycle()
                val stage by viewModel.stage.collectAsStateWithLifecycle()
                val isOnline by viewModel.isOnline.collectAsStateWithLifecycle()
                // 画面名は送らない（iOS は退会を設定の中のアラートで行い、画面名を送らない）。削除し終えたら、認証状態が未ログインになって
                // ログイン後のナビゲーションごと捨てられ、ログイン前の画面に替わる（ここから戻る操作もしない）
                AccountDeletionScreen(
                    state = state,
                    stage = stage,
                    isOnline = isOnline,
                    requestPageUrl = viewModel.requestPageUrl,
                    onPasswordChange = viewModel::onPasswordChange,
                    onRequestDelete = viewModel::requestDelete,
                    onConfirmDelete = viewModel::confirmDelete,
                    onCancelDelete = viewModel::cancelDelete,
                    onRetry = viewModel::retry,
                    onRequestPageOpenFailed = viewModel::onRequestPageOpenFailed,
                    onBack = { navController.popFrom(entry) },
                )
            }
        }
    }
}

/**
 * この画面 [entry] が、まだ戻る履歴の一番上のときだけ 1 つ戻る（利用者が押す「戻る・閉じる」の二度押しの守り。レビュー R04）。
 *
 * 画面を外すと、戻る履歴はその場で書き換わる。ところが出ていく画面は、フェード（既定 700ms）の間も描かれていて押せる。
 * そのまま 2 回目を通すと下の画面まで外れ、フィードの上の画面なら開始の行き先のフィードも外れて戻る履歴が空になり、何も描かれなくなる。
 * 2 回目のときは一番上が別の画面に替わっているので、比べて落とす。
 *
 * lifecycle の dropUnlessResumed（RESUMED のときだけ通す）は使わない。投稿の画面は、初めの写真ピッカーで何も選ばずに戻ったとき、
 * ピッカーの結果の受け取りから閉じるを呼ぶ（PostComposerScreen の shouldCloseAfterPicker）。結果が届く瞬間の Activity は STARTED
 * （RESUMED の手前）なので、包むと閉じるが黙って捨てられ、空の投稿画面に取り残される。しかもその閉じるは、二度押しの本丸の
 * 「投稿完了」の OK と同じラムダなので、そこだけ除くこともできない。一番上かどうかで比べる守りは STARTED でも動く。
 *
 * 比べるのは [NavBackStackEntry.id]（戻る履歴の 1 枚ごとに付く識別子）にし、entry どうしの等しさ（equals）は使わない。
 */
private fun NavHostController.popFrom(entry: NavBackStackEntry) {
    if (currentBackStackEntry?.id == entry.id) popBackStack()
}

/**
 * この画面 [entry] が、まだ戻る履歴の一番上のときだけ [route] を開く（利用者が押す「開く」の二度押しの守り。レビュー R04）。
 * 開くと戻る履歴はその場で書き換わって一番上が開いた画面に替わるので、フェードの間の 2 回目（同じ画面を 2 枚積む）は落ちる。
 * dropUnlessResumed を使わない理由と、id で比べることは [popFrom] と同じ。
 */
private fun <T : Any> NavHostController.navigateFrom(entry: NavBackStackEntry, route: T) {
    if (currentBackStackEntry?.id == entry.id) navigate(route)
}
