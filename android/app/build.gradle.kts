// ⭐️ アプリ本体（:app）のビルド設定
// 画面と Firebase への接続を持つモジュール。依存の版数は gradle/libs.versions.toml で一元管理する。
plugins {
    // AGP 9 は Kotlin を組み込みで扱うため、org.jetbrains.kotlin.android は適用しない
    alias(libs.plugins.android.application)
    // Kotlin 2.0 以降は、Compose のコンパイラをこのプラグインで有効にする
    alias(libs.plugins.kotlin.compose)
    // google-services.json（Git 管理外）を読み、本番の Firebase プロジェクトへの接続情報をリソースにする
    alias(libs.plugins.google.services)
    // Crashlytics のビルド ID の埋め込みと、リリースビルドのマッピングファイルのアップロード
    alias(libs.plugins.firebase.crashlytics)
    // kotlinx-serialization（型安全なルートの @Serializable）は、ルートを書くタスク 5 で適用する
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
    }

    // Java 17 のバイトコードを出す。組み込み Kotlin の jvmTarget もこの値に揃う
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Android Studio で Compose を扱う（プレビューなど）ために必要
    buildFeatures {
        compose = true
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

    // 画像の表示：Storage のダウンロード URL（https）を読むため、OkHttp のネットワーク部品も入れる
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    // 分析：PostHog（iOS 版と同じプロジェクト）
    implementation(libs.posthog.android)
}

// ── プッシュ通知（FCM）の SDK が入っていないことの検査（要件 2.10・タスク 1.2）──
// users/{uid}.fcmToken は 1 ユーザー 1 トークンで、Android が書き換えると iOS 端末へ通知が届かなくなる。
// FCM の SDK（firebase-messaging）がアプリに無ければ、トークンを書く経路そのものが存在しない。
// 推移的な依存を含めて、実行時のクラスパスに firebase-messaging* が現れたらビルドを止める。
val verifyNoFirebaseMessaging = tasks.register("verifyNoFirebaseMessaging") {
    group = "verification"
    description = "実行時のクラスパスに firebase-messaging が含まれていないことを確かめる"

    // 検査するクラスパス（debug と release の両方）。AGP が作る構成なので、ここ（タスクの設定時）で遅延して参照する
    val classpaths = listOf("debugRuntimeClasspath", "releaseRuntimeClasspath")
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
