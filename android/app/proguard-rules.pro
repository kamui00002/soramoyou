# ⭐️ アプリ本体（:app）の R8 の規則（タスク 34.1）
# release だけが読む（app/build.gradle.kts の「リリースビルドの署名と難読化」）。既定の規則（proguard-android-optimize.txt）と、
# 各ライブラリが同梱する規則（Firebase・PostHog・kotlinx-serialization・Navigation・Coil など）で足りない分だけをここに書く。
# 規則が効いたかは app/build/outputs/mapping/prodRelease/ の configuration.txt（合わせた規則）と seeds.txt（残したもの）で確かめる。
#
# 反射でクラスやメンバーを読むコードは、2026-10-13 に src/main を検索して確かめた。Firestore の toObject・Class.forName・
# getDeclared…・ServiceLoader・Gson・Moshi は使っていない（Firestore の文書は Map のまま読む）。型安全なルート（@Serializable）は
# コンパイラのプラグインが作る直列化を使い、反射しない。Milestone.valueOf（BuildConfig の文字列から列挙値へ）は既定の規則が
# 列挙の valueOf を残す。CrashReporter が取り除くフレームの名前は実行時のクラスから取るので、難読化されても一致する。

# 名前に依存するのは、記録に例外の型名を載せる所（AppError.Unknown(e.javaClass.simpleName)：SessionManager・DefaultStorageGateway・
# DefaultFirestoreWriteGateway・DefaultFirestoreReader）。error_occurred の説明と Crashlytics の記録に載る文字列は、
# Crashlytics の対応表では元に戻らない（戻るのはスタックトレースだけ）ので、例外のクラスの名前だけは難読化しない。
# -keepnames なので、使われない例外のクラスの削除と最適化は止めない。Firebase などのライブラリの例外も含めるため、パッケージで絞らない。
-keepnames class * extends java.lang.Throwable

# Crashlytics のスタックトレースにファイル名と行番号を残し、対応表で元のクラス・行に戻せるようにする（Firebase の公式の手順）。
-keepattributes SourceFile,LineNumberTable
# 元のファイル名は対応表から戻るので、APK の中では「SourceFile」に置き換える。
-renamesourcefileattribute SourceFile

# Room のデータベースの実装（…_Impl）の引数なしのコンストラクタを残す（タスク 34.2）。
# 広告の SDK（ads-mobile-sdk 1.5.0）が持ち込む work-runtime 2.7.0 は、起動時に WorkDatabase_Impl を反射で作る（newInstance）。
# 一緒に入る room-runtime 2.2.5 の同梱の規則（-keep class * extends androidx.room.RoomDatabase）はクラスしか残さず、
# R8 の full モード（AGP 8 以降の既定）ではコンストラクタが消える。2026-10-15 に R8 をかけた版が起動直後に
# 「Failed to create an instance of androidx.work.impl.WorkDatabase」で落ちることを AVD で確かめた（mapping.txt に <init> が無かった）。
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# リリースでは Log.v・Log.d・Log.i の呼び出しを消す（レビュー R12）。
# アプリ自身が Logcat に出す行（Soramoyou のタグ）は Log.w・Log.e だけにしてあり、この規則では消えない
# （端末の確認で数える合図の「アカウント文書を補った」と「Firebase の接続先」は Log.w。ReleaseBuildSettingsTest で固定）。
# 効くのは R8 をかける release だけ（このファイルを読むのが release だけのため）。debug の Logcat はそのまま。
-assumenosideeffects class android.util.Log { public static int v(...); public static int d(...); public static int i(...); }
