// ⭐️ 結合テストから開発機の Firebase エミュレータを操作する（データの初期化と、ルールを通さない投入・確認）（タスク 11.1・23.2・25.1）
package com.yoshidometoru.soramoyou.integration

import com.yoshidometoru.soramoyou.di.FirebaseEmulator
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * エミュレータの管理用の REST の口を叩く。アプリの書き込みの入口（M1 では全て無効）を通さずにテストのデータを用意するため、
 * Firestore の SDK の書き込み API は使わない（WriteApiConfinementTest の対象外のテストのコードでも、書き込みの経路を増やさない）。
 *
 * - 初期化：Firestore の全ドキュメントと、Auth の全アカウントを消す（エミュレータの専用の口）。
 *   Auth のエミュレータは、firebase.json に auth の設定が無いと起動しない（2026-10-05 に実測。firebase.json は変えない）ので、
 *   `android/tools/start-firebase-emulators.sh` が写しの設定で起動する（タスク 17.1）。rules も写しで、firestore.rules には
 *   エミュレータの Storage の URL の形を 1 行だけ足してある（足さないと、アプリが書く画像の URL が rules で断られる。レビュー R14）。
 *   Storage には一括で消す口が無いので、Storage を使うテストを足すときに、そのテストが作ったものを消す
 * - 投入・確認：`Authorization: Bearer owner` を付けると、エミュレータはセキュリティルールを通さずに読み書きする（管理者として扱う）。
 *   アプリが書いた結果は、アプリの読み取りの経路でなく、ここから確かめる（読み取りの不具合と書き込みの不具合を混ぜない）
 */
object EmulatorBackend {

    private val firestoreBase = "http://${FirebaseEmulator.HOST}:${FirebaseEmulator.FIRESTORE_PORT}"
    private val authBase = "http://${FirebaseEmulator.HOST}:${FirebaseEmulator.AUTH_PORT}"
    private val storageBase = "http://${FirebaseEmulator.HOST}:${FirebaseEmulator.STORAGE_PORT}"
    private const val DATABASE = "(default)"

    /** 検証用ビルドの既定のバケット（app/src/emulator/google-services.json の storage_bucket）。 */
    private const val BUCKET = "demo-soramoyou.appspot.com"

    /** Firestore の 1 回の commit に入れられる書き込みの上限。 */
    private const val COMMIT_LIMIT = 500

    /** Firestore のデータを全て消す。テストごとに最初に呼ぶ。 */
    fun reset() {
        request("DELETE", "$firestoreBase/emulator/v1/projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents")
    }

    /** Auth のアカウントを全て消す。ログインを使うテストごとに最初に呼ぶ（端末側のログイン状態は、テストがログアウトで消す）。 */
    fun resetAuth() {
        request("DELETE", "$authBase/emulator/v1/projects/${FirebaseEmulator.PROJECT_ID}/accounts")
    }

    /**
     * [collection] の ID [id] の文書の `fields` を、ルールを通さずに読む。文書が無ければ null。
     * 返すのは Firestore の REST の形（例: `{"id":{"stringValue":"u1"}}`）。
     */
    fun readFields(collection: String, id: String): JSONObject? {
        val connection = URL(
            "$firestoreBase/v1/projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents/$collection/$id",
        ).openConnection() as HttpURLConnection
        try {
            connection.setRequestProperty("Authorization", "Bearer owner")
            val code = connection.responseCode
            if (code == 404) return null
            check(code in 200..299) { "エミュレータからの読み取りが失敗した（HTTP $code）: $collection/$id" }
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            return JSONObject(body).optJSONObject("fields") ?: JSONObject()
        } finally {
            connection.disconnect()
        }
    }

    /**
     * [collection] に ID [id] の文書を、ルールを通さずに作る。[fieldsJson] は Firestore の REST の `fields` の中身
     * （例: `"userId":{"stringValue":"u1"}`）。
     */
    fun seed(collection: String, id: String, fieldsJson: String) {
        request(
            "POST",
            "$firestoreBase/v1/projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents/$collection?documentId=$id",
            body = """{"fields":{$fieldsJson}}""",
            owner = true,
        )
    }

    /**
     * [collection] の ID [id] の文書のうち [fieldPaths] の項目だけを、ログイン中のユーザー（ID トークン [idToken]）として
     * 書き換え、HTTP の状態コードを返す（rules に断られれば 403）。アプリの書き込みの入口と契約を通さずに、rules だけが
     * 断ることを確かめるための口（タスク 19.1 の陽性対照）。[fieldsJson] の形は [seed] と同じ。
     */
    fun patchAsUser(collection: String, id: String, fieldsJson: String, fieldPaths: List<String>, idToken: String): Int {
        // HttpURLConnection は PATCH を送れず、エミュレータは X-HTTP-Method-Override を受け付けない（400。2026-10-09 実測）ので、
        // POST で送れる commit（項目を絞った update の 1 件）を使う
        val name = "projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents/$collection/$id"
        val mask = fieldPaths.joinToString(",") { "\"$it\"" }
        val body = """{"writes":[{"update":{"name":"$name","fields":{$fieldsJson}},"updateMask":{"fieldPaths":[$mask]}}]}"""
        val connection = URL(
            "$firestoreBase/v1/projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents:commit",
        ).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.setRequestProperty("Authorization", "Bearer $idToken")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            connection.outputStream.use { it.write(body.toByteArray()) }
            val code = connection.responseCode
            // 断られた理由をログに残す（rules の拒否なら PERMISSION_DENIED。それ以外の 4xx は要求の誤り）
            if (code !in 200..299) println("patchAsUser $collection/$id → HTTP $code: ${connection.errorStream?.bufferedReader()?.use { it.readText() }}")
            return code
        } finally {
            connection.disconnect()
        }
    }

    /**
     * [collection] の ID [id] の文書を、ログイン中のユーザー（ID トークン [idToken]）として消し、HTTP の状態コードを返す
     * （rules に断られれば 403）。アプリの削除の部品は持ち主の確認で先に止めるので、rules だけが断ることを確かめるための口（タスク 25.1 の陽性対照）。
     */
    fun deleteAsUser(collection: String, id: String, idToken: String): Int {
        val connection = URL(
            "$firestoreBase/v1/projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents/$collection/$id",
        ).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "DELETE"
            connection.setRequestProperty("Authorization", "Bearer $idToken")
            val code = connection.responseCode
            // 断られた理由をログに残す（rules の拒否なら PERMISSION_DENIED）
            if (code !in 200..299) println("deleteAsUser $collection/$id → HTTP $code: ${connection.errorStream?.bufferedReader()?.use { it.readText() }}")
            return code
        } finally {
            connection.disconnect()
        }
    }

    /**
     * [collection] に、[documents]（文書 ID と、[seed] と同じ形の `fields` の中身の組）を、ルールを通さずにまとめて作る（タスク 33.1）。
     * 1 件ずつの [seed] だと数百件で遅いので、1 回の commit で送る（commit の上限 500 件ごとに分ける）。
     */
    fun seedMany(collection: String, documents: List<Pair<String, String>>) {
        val prefix = "projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents/$collection"
        for (chunk in documents.chunked(COMMIT_LIMIT)) {
            val writes = chunk.joinToString(",") { (id, fieldsJson) -> """{"update":{"name":"$prefix/$id","fields":{$fieldsJson}}}""" }
            request(
                "POST",
                "$firestoreBase/v1/projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents:commit",
                body = """{"writes":[$writes]}""",
                owner = true,
            )
        }
    }

    /**
     * [collection]（`users/u1/favorites` のような入れ子も可）の全ての文書を、ルールを通さずに読む（タスク 33.1）。
     * 返すのは文書 ID と `fields`（REST の形）の組。通報やフィードバックのように自動 ID で作られる文書を探すのに使う。
     */
    fun listDocuments(collection: String): List<Pair<String, JSONObject>> {
        val found = mutableListOf<Pair<String, JSONObject>>()
        var pageToken: String? = null
        do {
            val query = "pageSize=300" + (pageToken?.let { "&pageToken=${URLEncoder.encode(it, "UTF-8")}" } ?: "")
            val connection = URL(
                "$firestoreBase/v1/projects/${FirebaseEmulator.PROJECT_ID}/databases/$DATABASE/documents/$collection?$query",
            ).openConnection() as HttpURLConnection
            val body = try {
                connection.setRequestProperty("Authorization", "Bearer owner")
                val code = connection.responseCode
                check(code in 200..299) { "エミュレータからの一覧が失敗した（HTTP $code）: $collection" }
                JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            } finally {
                connection.disconnect()
            }
            val documents = body.optJSONArray("documents")
            if (documents != null) {
                for (i in 0 until documents.length()) {
                    val document = documents.getJSONObject(i)
                    found += document.getString("name").substringAfterLast('/') to (document.optJSONObject("fields") ?: JSONObject())
                }
            }
            pageToken = body.optString("nextPageToken").takeIf { it.isNotEmpty() }
        } while (pageToken != null)
        return found
    }

    /** Auth のエミュレータに uid [uid] のアカウントがあるか（管理者の口で読む。タスク 33.1：退会で認証のアカウントまで消えたかの確かめ）。 */
    fun authAccountExists(uid: String): Boolean {
        val connection = URL(
            "$authBase/identitytoolkit.googleapis.com/v1/projects/${FirebaseEmulator.PROJECT_ID}/accounts:lookup",
        ).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.setRequestProperty("Authorization", "Bearer owner")
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            connection.outputStream.use { it.write("""{"localId":[${JSONObject.quote(uid)}]}""".toByteArray()) }
            val code = connection.responseCode
            check(code in 200..299) { "Auth のエミュレータの照会が失敗した（HTTP $code）" }
            val users = JSONObject(connection.inputStream.bufferedReader().use { it.readText() }).optJSONArray("users")
            return users != null && users.length() > 0
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Storage の [path] のオブジェクトのメタデータ（`contentType`・`size` など）を、ルールを通さずに読む。無ければ null（タスク 23.2）。
     * ⚠️ 読むだけにする。2026-10-10 に、開発機からこの口へ管理者として直接 POST（アップロード）したところ、エミュレータ全体が
     *    「An unexpected error has occurred.」で落ちた。テストのデータは、アプリの書き込みの入口で作り、入口で消す。
     */
    fun storageObject(path: String): JSONObject? {
        val encoded = URLEncoder.encode(path, "UTF-8")
        val connection = URL("$storageBase/v0/b/$BUCKET/o/$encoded").openConnection() as HttpURLConnection
        try {
            connection.setRequestProperty("Authorization", "Bearer owner")
            val code = connection.responseCode
            if (code == 404) return null
            check(code in 200..299) { "Storage のエミュレータからの読み取りが失敗した（HTTP $code）: $path" }
            return JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
        } finally {
            connection.disconnect()
        }
    }

    /**
     * Storage の [folder] の直下のオブジェクトのパスを、ルールを通さずに一覧する（タスク 31.6：数百個の有無を 1 回の GET で確かめる）。
     * [storageObject] と同じく読むだけにする（管理者としての POST はエミュレータを落とした：[storageObject] の注記）。
     */
    fun storageList(folder: String): List<String> {
        val found = mutableListOf<String>()
        var pageToken: String? = null
        do {
            val query = "prefix=${URLEncoder.encode("$folder/", "UTF-8")}&delimiter=%2F" +
                (pageToken?.let { "&pageToken=${URLEncoder.encode(it, "UTF-8")}" } ?: "")
            val connection = URL("$storageBase/v0/b/$BUCKET/o?$query").openConnection() as HttpURLConnection
            val body = try {
                connection.setRequestProperty("Authorization", "Bearer owner")
                val code = connection.responseCode
                check(code in 200..299) { "Storage のエミュレータの一覧が失敗した（HTTP $code）: $folder" }
                JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            } finally {
                connection.disconnect()
            }
            val items = body.optJSONArray("items")
            if (items != null) for (i in 0 until items.length()) found += items.getJSONObject(i).getString("name")
            pageToken = body.optString("nextPageToken").takeIf { it.isNotEmpty() }
        } while (pageToken != null)
        return found
    }

    private fun request(method: String, url: String, body: String? = null, owner: Boolean = false) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            if (owner) connection.setRequestProperty("Authorization", "Bearer owner")
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = connection.responseCode
            check(code in 200..299) { "エミュレータへの $method が失敗した（HTTP $code）: $url" }
        } finally {
            connection.disconnect()
        }
    }
}
