// ⭐️ アプリ本体（:app）のビルド設定
// 画面と Firebase への接続を持つモジュール。依存の版数は gradle/libs.versions.toml で一元管理する。
// 署名の設定ファイルを読む（タスク 34.1）。式の中の java.… は Java のプラグインの拡張（java {}）と解釈されるので、import で読む
import java.util.Properties

plugins {
    // AGP 9 は Kotlin を組み込みで扱うため、org.jetbrains.kotlin.android は適用しない
    alias(libs.plugins.android.application)
    // Kotlin 2.0 以降は、Compose のコンパイラをこのプラグインで有効にする
    alias(libs.plugins.kotlin.compose)
    // google-services.json（Git 管理外）を読み、本番の Firebase プロジェクトへの接続情報をリソースにする
    alias(libs.plugins.google.services)
    // Crashlytics のビルド ID の埋め込みと、リリースビルドのマッピングファイルのアップロード
    alias(libs.plugins.firebase.crashlytics)
    // 型安全なルート（@Serializable のクラスでルートを表す）を直列化する（タスク 8.3）
    alias(libs.plugins.kotlin.serialization)
}

// ── 書き込みの可否を決めるマイルストーン（タスク 6.1・要件 2.2）──
// gradle.properties の soramoyou.milestone（M1〜M6）を読み、下の defaultConfig で BuildConfig.WRITE_MILESTONE に焼き込む。
// 有効な書き込みの集合は、アプリの WriteGate がこの定数だけから決める（M1 は空集合）。実行時に変える経路は作らない。
// 値が無い・M1〜M6 以外のときは、黙って既定値にせずビルドを止める（どのマイルストーンでビルドしたかを曖昧にしない）。
fun milestoneProperty(name: String): String = providers.gradleProperty(name).orNull.let { value ->
    if (value == null || !value.matches(Regex("M[1-6]"))) {
        throw GradleException(
            "gradle.properties の $name は M1〜M6 のどれかにしてください（今の値: $value）。" +
                "書き込みの可否はこの値で決まります（設計書「マイルストーンと有効化の範囲」）。",
        )
    }
    value
}

/** 本番向けの変種（prod）のマイルストーン。 */
val writeMilestone: String = milestoneProperty("soramoyou.milestone")

// 検証用の変種（emulator）は、本番より先に書き込みを試せるよう、別のマイルストーンを持つ（タスク 14・2026-10-05 ユーザー判断：
// 検証用だけ M2、本番用は M1）。検証用は demo- のプロジェクトのエミュレータにしか繋がらないので、上げても本番へは書かない。
// 本番向けより低い値は、検証用で試していないものを本番に出すことになるので、ビルドを止める。
val emulatorWriteMilestone: String = milestoneProperty("soramoyou.emulatorMilestone").also { value ->
    if (value < writeMilestone) {
        throw GradleException("soramoyou.emulatorMilestone（$value）は soramoyou.milestone（$writeMilestone）以上にしてください。")
    }
}

android {
    namespace = "com.yoshidometoru.soramoyou"
    // compileSdk はビルド時にだけ使う値で、端末での動き（targetSdk 36）は変わらない。
    // 設計書の Compose BOM 2026.09.00（Compose 1.12）・lifecycle 2.11・navigation 2.10・Coil 3.6 は
    // compileSdk 37 以上を要求するため（各 AAR の minCompileSdk=37。36 では checkDebugAarMetadata が失敗する
    // ことを 2026-10-02 に確認）、36 から 37 に上げた。AGP 9.4 が扱える上限は 37。
    compileSdk = 37

    defaultConfig {
        // Play では公開後に変更できない ID（決定済み）
        applicationId = "com.yoshidometoru.soramoyou"
        minSdk = 26
        targetSdk = 36
        // 版数（タスク 34.1・要件 18.7）。ここに実際の値で書いてコミットし、コマンドラインで上書きしない
        // （iOS で、コマンドラインで版数を上げて台帳とずれた教訓）。値を Gradle の設定や環境変数から読む形にしない（単体テストが止める）。
        // AGP 9.4.1 は、コマンドラインの -Pandroid.injected.version.code・name を APK にも BuildConfig にも反映しない（2026-10-13 に確認）。
        // Play へ提出するたびに versionCode を 1 つ以上増やす（Play は同じ・小さい値を受け付けない。一度上げた値は下げられない）。
        // フィードバックの appVersion は「versionName (versionCode)」で送る（タスク 30・設計書）
        versionCode = 2
        versionName = "1.0.1"

        // 書き込みの可否を決めるマイルストーン（上の writeMilestone）。Java の文字列の定数として焼き込むので、引用符で囲む
        buildConfigField("String", "WRITE_MILESTONE", "\"$writeMilestone\"")

        // 端末で動かす結合テスト（src/androidTestEmulator）の実行役（タスク 11.1）
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // ── 接続先で分ける 2 つの変種（タスク 11.1・要件 1.3）──
    // prod：本番の Firebase（app/google-services.json・Git 管理外）。ストアへ出すのはこちらだけ。
    // emulator：開発機の Firebase Local Emulator Suite にだけ繋ぐ検証用。src/emulator/google-services.json は
    //   demo- で始まる検証用のプロジェクト ID しか持たず、本番へは届かない。リリース用のビルドは作れない（下の androidComponents）。
    flavorDimensions += "backend"
    productFlavors {
        create("prod") {
            dimension = "backend"
            buildConfigField("boolean", "USE_FIREBASE_EMULATOR", "false")
        }
        create("emulator") {
            dimension = "backend"
            // 本番のアプリと同じ端末に並べて入れられ、取り違えないよう別のアプリにする
            applicationIdSuffix = ".emulator"
            versionNameSuffix = "-emulator"
            buildConfigField("boolean", "USE_FIREBASE_EMULATOR", "true")
            // defaultConfig の本番向けの値を、検証用のマイルストーンで上書きする（変種の値が defaultConfig より優先される）
            buildConfigField("String", "WRITE_MILESTONE", "\"$emulatorWriteMilestone\"")
        }
    }

    // Java 17 のバイトコードを出す。組み込み Kotlin の jvmTarget もこの値に揃う
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Android Studio で Compose を扱う（プレビューなど）ために必要
    buildFeatures {
        compose = true
        // BuildConfig クラスを作る（AGP の既定では作らない）。中身は上の WRITE_MILESTONE
        buildConfig = true
    }
}

dependencies {
    // ドキュメントの形・規則・列挙値は :contract から使う
    implementation(project(":contract"))

    // Firebase：認証・Firestore・Storage・Analytics・Crashlytics（版数は BoM が決める）
    // ⚠️ firebase-messaging（FCM）は入れない。下の verifyNoFirebaseMessaging が検出したらビルドを止める
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.auth)
    implementation(libs.firebase.firestore)
    implementation(libs.firebase.storage)
    implementation(libs.firebase.analytics)
    implementation(libs.firebase.crashlytics)

    // Compose：画面の部品と Material 3（版数は BOM が決める）
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    // @Preview の注釈（本体に入れても実行時の動作は変わらない）
    implementation(libs.androidx.compose.ui.tooling.preview)
    // プレビューの描画とレイアウトの検査は、debug ビルドにだけ入れる
    debugImplementation(libs.androidx.compose.ui.tooling)
    // 単一 Activity に Compose の画面を載せる（setContent）
    implementation(libs.androidx.activity.compose)
    // 画面から ViewModel を取得し（viewModel()）、StateFlow をライフサイクルに合わせて集める（collectAsStateWithLifecycle）
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)

    // ナビゲーション（型安全なルート）
    implementation(libs.androidx.navigation.compose)
    // ルートの @Serializable の注釈。Navigation は実行時にしか持ち込まないので、コンパイル時に見えるよう直接入れる
    implementation(libs.kotlinx.serialization.core)

    // 画像の表示：Storage のダウンロード URL（https）を読むため、OkHttp のネットワーク部品も入れる
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    // 写真の変換：EXIF の向きを読む（タスク 16.1）
    implementation(libs.androidx.exifinterface)

    // 分析：PostHog（iOS 版と同じプロジェクト）
    implementation(libs.posthog.android)

    // 広告：GMA Next-Gen SDK と、同意の取得（UMP）。ID の切り替えはこのファイルの末尾（タスク 32.1）
    implementation(libs.ads.mobile.sdk)
    implementation(libs.user.messaging.platform)

    // JVM の単体テスト（:contract と同じ枠組み。版数は gradle/libs.versions.toml）
    // kotlin-test-junit は kotlin.test.Test を持つ部品。:app では自動で選ばれないので明示する（カタログの注記を参照）
    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.junit)

    // 端末で動かす結合テスト（検証用の変種だけ。タスク 11.1・2026-10-05 にユーザーが追加を承認）
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    // 画面のテスト（タスク 9.5・2026-11-10 にユーザーが追加を承認）。版数は本体と同じ Compose の BOM が決める（BOM の公式の書き方どおり端末のテストにも通す）。
    // manifest の部品は createComposeRule が画面を載せる空の Activity を足すだけなので、ui-tooling と同じく debug ビルドにだけ入れる（製品版には入らない）
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

// 検証用の変種（emulator）のリリース用ビルドは、既定では作らない（ストアへ出せる形にしない）。
// 例外：-Psoramoyou.emulatorRelease=true のときだけ作る（タスク 34.2）。R8 をかけた版で投稿・いいねが動くかを、
// 本番に書かずに手元の Firebase エミュレータで確かめるため。gradle.properties には書かず、コマンドラインで渡したときだけ有効にする。
// 作るときは debug の鍵で署名し（アップロード鍵で署名しない。ストアへ出す形にしない）、Crashlytics への対応表のアップロードは無効にする
// （接続先は demo- のプロジェクトで、送り先が無い）。
val emulatorReleaseEnabled: Boolean = providers.gradleProperty("soramoyou.emulatorRelease").orNull == "true"
androidComponents {
    beforeVariants(selector().withFlavor("backend" to "emulator").withBuildType("release")) { it.enable = emulatorReleaseEnabled }
    onVariants(selector().withFlavor("backend" to "emulator").withBuildType("release")) { variant ->
        // buildType の release が持つ upload の署名を、この変種だけ debug の鍵に置き換える
        variant.signingConfig.from(android.signingConfigs.getByName("debug"))
    }
}
tasks.matching { it.name == "uploadCrashlyticsMappingFileEmulatorRelease" }.configureEach { enabled = false }

// ── プッシュ通知（FCM）の SDK が入っていないことの検査（要件 2.10・タスク 1.2）──
// users/{uid}.fcmToken は 1 ユーザー 1 トークンで、Android が書き換えると iOS 端末へ通知が届かなくなる。
// FCM の SDK（firebase-messaging）がアプリに無ければ、トークンを書く経路そのものが存在しない。
// 推移的な依存を含めて、実行時のクラスパスに firebase-messaging* が現れたらビルドを止める。
val verifyNoFirebaseMessaging = tasks.register("verifyNoFirebaseMessaging") {
    group = "verification"
    description = "実行時のクラスパスに firebase-messaging が含まれていないことを確かめる"

    // 検査するクラスパス（debug と release の両方）。AGP が作る構成なので、ここ（タスクの設定時）で遅延して参照する
    // 変種を分けたので、本番の debug・release と検証用の debug の 3 つを見る（検証用の release は既定では作らない）。
    // 検証用の release を作るとき（-Psoramoyou.emulatorRelease=true）だけ、そのクラスパスも見る（無いときに名前で引くと設定の段階で止まる）
    val classpaths = listOf("prodDebugRuntimeClasspath", "prodReleaseRuntimeClasspath", "emulatorDebugRuntimeClasspath") +
        listOfNotNull("emulatorReleaseRuntimeClasspath".takeIf { emulatorReleaseEnabled })
    // 依存の解決結果（推移的な依存を含むグラフの根）を Provider のまま受け取る
    val roots = classpaths.associateWith { name ->
        configurations.named(name).flatMap { it.incoming.resolutionResult.rootComponent }
    }

    doLast {
        val hits = sortedSetOf<String>()
        roots.forEach { (classpath, root) ->
            // グラフを根から幅優先でたどり、全ての部品（推移的な依存を含む）を 1 回ずつ見る
            val seen = mutableSetOf<ComponentIdentifier>()
            val queue = ArrayDeque(listOf(root.get()))
            while (queue.isNotEmpty()) {
                val component = queue.removeFirst()
                if (!seen.add(component.id)) continue
                val id = component.id
                // 名前の一部一致ではなく、group と module の組で判定する（-ktx・-directboot などの派生も含める）
                if (id is ModuleComponentIdentifier &&
                    id.group == "com.google.firebase" &&
                    id.module.startsWith("firebase-messaging")
                ) {
                    hits += "$classpath → ${id.displayName}"
                }
                component.dependencies
                    .filterIsInstance<ResolvedDependencyResult>()
                    .forEach { queue += it.selected }
            }
        }
        if (hits.isNotEmpty()) {
            throw GradleException(
                "FCM の SDK（firebase-messaging）が依存に含まれています。fcmToken を書き換える経路を作らないため、" +
                    "Android 版の MVP では入れません（要件 2.10）。どの依存が持ち込んだかは " +
                    "`./gradlew :app:dependencies --configuration releaseRuntimeClasspath` で確かめてください。\n" +
                    hits.joinToString("\n") { "  - $it" },
            )
        }
    }
}

// assemble・テストの前に必ず通る preBuild と、check の両方に繋ぐ（検査を飛ばしてビルドできないようにする）
tasks.named("preBuild") { dependsOn(verifyNoFirebaseMessaging) }
tasks.named("check") { dependsOn(verifyNoFirebaseMessaging) }

// ── 端末内の画像全体を読む権限が、統合したマニフェストに無いことの検査（要件 6.2・タスク 21.1）──
// 写真はシステムの写真選択画面（PickMultipleVisualMedia）で選ばせるので、端末内の画像全体を読む権限は要らない。
// 自分の AndroidManifest.xml に書かなくても、依存のライブラリが権限を持ち込むと統合したマニフェストに入る。
// そこで変種ごとの統合したマニフェスト（AGP の MERGED_MANIFEST）を読み、下の権限が 1 つでもあればビルドを止める。
val broadMediaPermissions = listOf(
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.READ_MEDIA_VISUAL_USER_SELECTED",
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.WRITE_EXTERNAL_STORAGE",
    "android.permission.MANAGE_EXTERNAL_STORAGE",
)
androidComponents {
    onVariants { variant ->
        val variantName = variant.name.replaceFirstChar { it.uppercase() }
        val mergedManifest = variant.artifacts.get(com.android.build.api.artifact.SingleArtifact.MERGED_MANIFEST)
        val task = tasks.register("verifyNoBroadMediaPermission$variantName") {
            group = "verification"
            description = "${variant.name} の統合したマニフェストに、端末内の画像全体を読む権限が無いことを確かめる"
            inputs.file(mergedManifest)
            doLast {
                val manifest = mergedManifest.get().asFile
                // <uses-permission> と <uses-permission-sdk-23> の android:name を全て拾う（属性の並びに依存しない）
                val declared = Regex("""<uses-permission(?:-sdk-23)?\b[^>]*android:name="([^"]+)"""")
                    .findAll(manifest.readText())
                    .map { it.groupValues[1] }
                    .toSet()
                val hits = broadMediaPermissions.filter { it in declared }
                if (hits.isNotEmpty()) {
                    throw GradleException(
                        "${variant.name} の統合したマニフェストに、端末内の画像全体を読む権限が入っています（要件 6.2）。" +
                            "写真は写真選択画面で選ばせるので要りません。どの依存が持ち込んだかは " +
                            "app/build/outputs/logs/ の manifest-merger の報告で確かめてください。\n" +
                            hits.joinToString("\n") { "  - $it" },
                    )
                }
            }
        }
        // check と、その変種の組み立て（assemble）・AAB の前段（package…Bundle）の全部で必ず通す（bundle… だけでは assemble を通らないため。レビュー R24）
        tasks.matching { it.name == "assemble$variantName" || it.name == "package${variantName}Bundle" }.configureEach { dependsOn(task) }
    }
}
// 変種のタスクは onVariants で後から作られるので、名前で遅延して拾う
tasks.named("check") { dependsOn(tasks.matching { it.name.startsWith("verifyNoBroadMediaPermission") }) }

// ── リリースビルドの署名と難読化（タスク 34.1・要件 1.6・18.8・設計書 Security Considerations）──
// アップロード鍵（.jks）はリポジトリの外に置く。鍵の場所（storeFile。絶対パス）と別名（keyAlias）は Git 管理外の設定ファイルに、
// パスワードは環境変数に置く（Keychain から secret CLI で渡す。設計書のとおり、パスワードはファイルに書かない）。
//   設定ファイル：既定は android/keystore.properties（.gitignore 済み）。Gradle の設定 soramoyou.keystoreProperties で
//     リポジトリの外のファイルを指せる（~/.gradle/gradle.properties に書けば、リポジトリの中に何も置かずに済む）
//   環境変数：SORAMOYOU_UPLOAD_STORE_PASSWORD（鍵のファイルのパスワード）・SORAMOYOU_UPLOAD_KEY_PASSWORD（鍵のパスワード）
//   例：SORAMOYOU_UPLOAD_STORE_PASSWORD="$(secret get <名前>)" SORAMOYOU_UPLOAD_KEY_PASSWORD="$(secret get <名前>)" \
//         ./gradlew :app:bundleProdRelease
// どれかが欠けていても設定の段階では止めず、release の R8 と APK・AAB の組み立ての前でだけ止める（debug のビルドと単体テストは鍵なしで通す）。
// 署名しないまま組み立てると app-…-unsigned.apk が黙ってでき、R8 の後で Crashlytics へ対応表まで上がってしまうため。

/** 署名の設定ファイル（鍵の場所と別名だけを持つ。パスワードは持たない）。 */
val uploadKeystorePropertiesFile: File =
    rootProject.file(providers.gradleProperty("soramoyou.keystoreProperties").orElse("keystore.properties").get())

/** 署名の設定ファイルの中身。ファイルが無ければ null。 */
val uploadKeystoreProperties: Properties? = uploadKeystorePropertiesFile.takeIf { it.isFile }?.let { file ->
    Properties().apply { file.reader(Charsets.UTF_8).use { load(it) } }
}

/** 鍵のファイルと別名（設定ファイルの値。空なら無いとみなす）。 */
val uploadStoreFile: File? = uploadKeystoreProperties?.getProperty("storeFile")?.trim()?.takeIf { it.isNotEmpty() }?.let(::File)
val uploadKeyAlias: String? = uploadKeystoreProperties?.getProperty("keyAlias")?.trim()?.takeIf { it.isNotEmpty() }

/** パスワード（環境変数の値。空なら無いとみなす）。値はログにもエラーにも出さない。 */
val uploadStorePassword: String? = providers.environmentVariable("SORAMOYOU_UPLOAD_STORE_PASSWORD").orNull?.takeIf { it.isNotEmpty() }
val uploadKeyPassword: String? = providers.environmentVariable("SORAMOYOU_UPLOAD_KEY_PASSWORD").orNull?.takeIf { it.isNotEmpty() }

/**
 * [file] を含む Git の作業ツリーの根。[file] の親から根（/）までたどり、最初に `.git` があったディレクトリを返す。無ければ null。
 * 鍵がどこかの作業ツリーの中にあれば止める（要件 18.8：鍵をリポジトリに含めない）。
 *
 * `.git` は、ふつうの作業ツリーではディレクトリ、git worktree で足した作業ツリーではファイル（`gitdir: …` の 1 行）なので、どちらも数える。
 * ビルドした作業ツリー（android/ の 1 つ上）だけを見ると、worktree でビルドしたときに、本体の作業ツリー（そちらの .gitignore が
 * *.jks を拾うとは限らない）に置いた鍵を「外」と誤って通すため。`git check-ignore` で無視されていれば許す、という和らげ方は入れない
 * （ブランチごとに .gitignore が違うので、無視されるかどうかは鍵の置き場の安全の証拠にならない）。
 */
fun enclosingGitWorkTree(file: File): File? =
    generateSequence(file.canonicalFile.parentFile) { it.parentFile }.firstOrNull { File(it, ".git").exists() }

/** release の署名に足りないもの（空なら揃っている）。パスワードの値は載せず、場所と名前だけを書く。 */
val uploadSigningProblems: List<String> = buildList {
    if (uploadKeystoreProperties == null) {
        add("署名の設定ファイルがありません: ${uploadKeystorePropertiesFile.path}（storeFile と keyAlias を書く）")
    } else {
        val store = uploadStoreFile
        when {
            store == null -> add("${uploadKeystorePropertiesFile.path} に storeFile（鍵のファイルの絶対パス）がありません")
            !store.isAbsolute -> add("storeFile は絶対パスで書いてください: $store")
            !store.isFile -> add("storeFile の鍵のファイルがありません: $store")
            else -> enclosingGitWorkTree(store)?.let { workTree ->
                add("鍵のファイルがリポジトリの中にあります: $store（Git の作業ツリー $workTree の中。どのリポジトリの外にも置く）")
            }
        }
        if (uploadKeyAlias == null) add("${uploadKeystorePropertiesFile.path} に keyAlias（鍵の別名）がありません")
    }
    if (uploadStorePassword == null) add("環境変数 SORAMOYOU_UPLOAD_STORE_PASSWORD（鍵のファイルのパスワード）がありません")
    if (uploadKeyPassword == null) add("環境変数 SORAMOYOU_UPLOAD_KEY_PASSWORD（鍵のパスワード）がありません")
}

android {
    signingConfigs {
        // 揃っているときだけ作る（欠けた値のまま作ると、AGP が別の分かりにくい理由で止まるため）
        if (uploadSigningProblems.isEmpty()) {
            create("upload") {
                storeFile = uploadStoreFile
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
            }
        }
    }
    buildTypes {
        getByName("release") {
            // R8 で、使われないコードを削り、名前を難読化する。規則は既定（最適化つき）とアプリの proguard-rules.pro
            // （各ライブラリが同梱する規則は R8 が自動で足す）。リソースの削減（isShrinkResources）は入れない
            // （Firebase は google-services のリソースを名前で読む。要るかは 34.2 の実機の確認の後で決める）
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // 鍵が揃っていなければ null（署名しない）。そのときは下の verifyReleaseBuildInputs が組み立ての前に止める
            signingConfig = signingConfigs.findByName("upload")
            // 難読化したスタックトレースを Crashlytics で元に戻すため、R8 の対応表を上げる（プラグインの既定も有効だが、意図を残すために明示する）。
            // 上げるのは minifyProdReleaseWithR8 の後に続く uploadCrashlyticsMappingFileProdRelease（プラグイン 3.0.8 の中身で確認）。
            // 手元で試しに組み立てるときは -x uploadCrashlyticsMappingFileProdRelease で外し、本番の Crashlytics へ送らない
            configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
                mappingFileUploadEnabled = true
            }
        }
    }
}

// release の組み立ての前提（署名の鍵が揃っている）を確かめる。足りなければ、足りないものを全て並べて止める
val verifyReleaseBuildInputs = tasks.register("verifyReleaseBuildInputs") {
    group = "verification"
    description = "release を組み立てる前提（リポジトリの外の署名の鍵と、そのパスワード）が揃っていることを確かめる"
    val problems = uploadSigningProblems
    doLast {
        if (problems.isNotEmpty()) {
            throw GradleException(
                "release の APK・AAB を組み立てられません（タスク 34.1）。アップロード鍵の作成はタスク 27（ユーザー作業）です。\n" +
                    problems.joinToString("\n") { "  - $it" } + "\n" +
                    "鍵の場所と別名は android/keystore.properties（または -Psoramoyou.keystoreProperties=<リポジトリの外のファイル>）に、" +
                    "パスワードは環境変数に置きます（app/build.gradle.kts の「リリースビルドの署名と難読化」の注記を参照）。",
            )
        }
    }
}
// R8（とその後の対応表のアップロード）・APK・AAB の組み立ての前に必ず通す。release の lint など、組み立て以外は鍵が無くても動かせるよう止めない
// （試走で、verifyReleaseBuildInputs が minifyProdReleaseWithR8 の直前に並び、lintProdRelease には並ばないことを確かめた）
// 検証用の release（-Psoramoyou.emulatorRelease=true のときだけ作る）は debug の鍵で署名するので、アップロード鍵を求めない（prod だけに繋ぐ）
androidComponents {
    onVariants(selector().withFlavor("backend" to "prod").withBuildType("release")) { variant ->
        val variantName = variant.name.replaceFirstChar { it.uppercase() }
        val guarded = setOf("minify${variantName}WithR8", "package$variantName", "package${variantName}Bundle")
        tasks.matching { it.name in guarded }.configureEach { dependsOn(verifyReleaseBuildInputs) }
    }
}

// ── 広告のアプリ ID と広告ユニット ID の切り替え（タスク 32.1・要件 14.2・14.3・設計書 Q9）──
// ID はビルドの種類で決める。決めるのはここだけで、同じ値を BuildConfig（SDK の初期化とバナー）とマニフェスト（UMP が読むアプリ ID）の
// 両方へ流す。アプリ側（platform/AdsConfig.kt）は焼き込んだ値が種類に合っているかを検査するだけで、選ばない。
//   debug（開発用。検証用の変種 emulator は debug しか無い）… Google のテスト用の ID（種類 DEVELOPMENT）
//   release … gradle.properties の soramoyou.adsTrack が CLOSED_TEST なら Google のテスト用の ID、PRODUCTION_TRACK なら本番の ID
// テスト用の ID の出典：developers.google.com/admob/android/next-gen/quick-start のサンプルのアプリ ID（2026-10-13 に確認）と、
//   同 next-gen/test-ads の表の Fixed Size Banner（固定サイズのバナー）のデモの広告ユニット（2026-10-14 に確認）。
//   枠は iOS 版と同じ標準バナー（320x50。AdSize.BANNER）で読み込むので、アダプティブのデモ（…/9214589741）でなく固定サイズのデモを使う。
//   アカウントに紐づかないので、押しても無効なトラフィックにならない。
// アプリ ID をマニフェストにも置くのは、UMP がそこから読むため（同 next-gen/privacy「Add the application ID」）。Next-Gen は初期化の引数で受け取る。
val admobTestAppId = "ca-app-pub-3940256099942544~3347511713"
val admobTestBannerUnitId = "ca-app-pub-3940256099942544/6300978111"

/**
 * Google のテスト用の発行元。公表されているテスト用の ID は、アプリ ID も広告ユニット ID も全てこの発行元の下にある（同 next-gen/test-ads の表）。
 * 番号を 3 か所目として書き写さず、テスト用のアプリ ID の `~` より前から作る（アプリの GoogleTestAdIds.PUBLISHER と同じ値。M5 レビュー）。
 */
val admobTestPublisher = admobTestAppId.substringBefore("~")

/** リリースビルドの広告の種類（CLOSED_TEST・PRODUCTION_TRACK）。値が無い・それ以外の値なら、黙って既定にせずビルドを止める。 */
val releaseAdsTrack: String = providers.gradleProperty("soramoyou.adsTrack").orNull.let { value ->
    if (value != "CLOSED_TEST" && value != "PRODUCTION_TRACK") {
        throw GradleException(
            "gradle.properties の soramoyou.adsTrack は CLOSED_TEST か PRODUCTION_TRACK にしてください（今の値: $value）。" +
                "リリースビルドがテスト用と本番のどちらの広告を出すかは、この値で決まります。",
        )
    }
    value
}

/**
 * gradle.properties の本番の ID。PRODUCTION_TRACK のときだけ読み、未設定ならビルドを止める（テスト用の広告のまま本番に出さない・
 * 広告の無いまま出さないため）。CLOSED_TEST のときは読まない（タスク 27 で発行するまでは空のまま置いてある）。
 *
 * Google のテスト用の発行元の ID（`ca-app-pub-3940256099942544~…`・`ca-app-pub-3940256099942544/…`）も止める（本番でテスト用の広告を
 * 出さない）。デモの広告ユニットは形式ごとにいくつもあるので、1 つとの完全一致でなく、発行元の前置き（区切りの `~`・`/` まで）で断る。
 * アプリの platform/AdsConfig.kt（adsConfigProblem）と同じ規則で、-P で渡した値もここを通る。
 */
fun admobProductionId(name: String): String {
    val value = providers.gradleProperty(name).orNull.orEmpty().trim()
    if (value.isEmpty()) {
        throw GradleException(
            "soramoyou.adsTrack が PRODUCTION_TRACK なのに、gradle.properties の $name が未設定です。" +
                "Android 用に新規発行した本番の ID を入れてください（タスク 27。iOS 版の ID は使わない）。" +
                "クローズドテストのビルドなら、soramoyou.adsTrack を CLOSED_TEST にしてください。",
        )
    }
    if (value.startsWith("$admobTestPublisher~") || value.startsWith("$admobTestPublisher/")) {
        throw GradleException(
            "soramoyou.adsTrack が PRODUCTION_TRACK なのに、$name が Google のテスト用の発行元（$admobTestPublisher）の ID です。" +
                "Android 用に新規発行した本番の ID を入れてください（タスク 27）。" +
                "テスト用の広告を出すビルドなら、soramoyou.adsTrack を CLOSED_TEST にしてください。",
        )
    }
    return value
}

/** リリースビルドで使う、アプリ ID と広告ユニット ID の組。 */
val releaseAdmobIds: Pair<String, String> =
    if (releaseAdsTrack == "PRODUCTION_TRACK") {
        admobProductionId("soramoyou.admobProductionAppId") to admobProductionId("soramoyou.admobProductionBannerUnitId")
    } else {
        admobTestAppId to admobTestBannerUnitId
    }

android {
    buildTypes {
        getByName("debug") {
            buildConfigField("String", "ADS_BUILD_KIND", "\"DEVELOPMENT\"")
            buildConfigField("String", "ADMOB_APP_ID", "\"$admobTestAppId\"")
            buildConfigField("String", "ADMOB_BANNER_UNIT_ID", "\"$admobTestBannerUnitId\"")
            manifestPlaceholders["admobAppId"] = admobTestAppId
        }
        getByName("release") {
            buildConfigField("String", "ADS_BUILD_KIND", "\"$releaseAdsTrack\"")
            buildConfigField("String", "ADMOB_APP_ID", "\"${releaseAdmobIds.first}\"")
            buildConfigField("String", "ADMOB_BANNER_UNIT_ID", "\"${releaseAdmobIds.second}\"")
            manifestPlaceholders["admobAppId"] = releaseAdmobIds.first
        }
    }
}
