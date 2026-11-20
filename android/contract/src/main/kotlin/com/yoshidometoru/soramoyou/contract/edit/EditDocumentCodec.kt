// ⭐️ 下書き・編集の途中・装備の保存の形（Kiro android-edit-tools タスク 2.2・K0 で形、タスク 6・C3 で中身・design.md:526-549,1027-1051）
package com.yoshidometoru.soramoyou.contract.edit

import com.yoshidometoru.soramoyou.contract.model.FilterId

/** 下書きと編集の途中の文書（同じ形）。写真の file は、利用者のフォルダからの相対の場所 */
data class EditWorkDocument(
    val sessionId: String,                // この編集の途中の印（大文字の UUID）。写真を選んだ時と下書きを開いた時に、ViewModel が新しく作る
    val draftId: String?,                 // 開いた下書きの ID。新しい編集なら null
    val savedAtEpochMillis: Long,
    val caption: String,
    val visibilityRaw: String,
    val enteredInfo: Boolean,             // 投稿情報の段にいたか
    val photos: List<EditWorkPhoto>,
)

data class EditWorkPhoto(
    val file: String,
    val capturedAtEpochMillis: Long?,
    val capturedAtSourceRaw: String,      // CapturedAtSource.raw（exif・asset・none）
    val edit: PhotoEdit,
)

/**
 * 文書（`java.util.Properties` に載せる文字列の対応表）と型の間の変換。純粋な関数だけで、ファイルには触らない。
 *
 * 鍵の表は design.md「文書の形」（1027-1051）。決まり：
 * - 知らない鍵は読み飛ばす（鍵を足すだけなら版を上げない）
 * - ハッシュタグと履歴の鍵は持たない（要件 8.2・8.19）。装備の文書は `version` と `tools` だけ
 * - 0 のツールは書かない。「なし」のフィルター・回転 0・全体の切り抜きも書かない
 */
object EditDocumentCodec {
    const val VERSION = 1

    // ---- 鍵の名前 ----
    private const val KEY_VERSION = "version"
    private const val KEY_TOOLS = "tools"
    private const val KEY_SESSION_ID = "sessionId"
    private const val KEY_DRAFT_ID = "draftId"
    private const val KEY_SAVED_AT = "savedAt"
    private const val KEY_CAPTION = "caption"
    private const val KEY_VISIBILITY = "visibility"
    private const val KEY_ENTERED_INFO = "enteredInfo"
    private const val KEY_PHOTO_COUNT = "photo.count"

    /** 写真の枚数の範囲（design.md の表：1〜10） */
    private const val MIN_PHOTOS = 1
    private const val MAX_PHOTOS = 10

    private const val SOURCE_NONE = "none"

    /** 装備の文書：`version` と `tools`（`EditTool.raw` をカンマで並べたもの）だけ */
    fun encodeLoadout(loadout: Loadout): Map<String, String> = mapOf(
        KEY_VERSION to VERSION.toString(),
        KEY_TOOLS to loadout.tools.joinToString(",") { it.raw },
    )

    /**
     * 読めなければ DEFAULT。版が無い・読めない・新しすぎる、`tools` の鍵が無い、のどれでも DEFAULT。
     * `tools` の中身は [Loadout.sanitized] を通す（知らない名前・重複を捨て、空なら DEFAULT）。
     */
    fun decodeLoadout(map: Map<String, String>): Loadout {
        if (!isReadableVersion(map[KEY_VERSION])) return Loadout.DEFAULT
        val tools = map[KEY_TOOLS] ?: return Loadout.DEFAULT
        val raws = if (tools.isEmpty()) emptyList() else tools.split(",")
        return Loadout.sanitized(raws)
    }

    fun encodeWork(doc: EditWorkDocument): Map<String, String> {
        // 並びを保つ（Properties に載せる前の対応表。順序に意味は無いが、読みやすさのため挿入順にする）
        val out = LinkedHashMap<String, String>()
        out[KEY_VERSION] = VERSION.toString()
        out[KEY_SESSION_ID] = doc.sessionId
        doc.draftId?.let { out[KEY_DRAFT_ID] = it }
        out[KEY_SAVED_AT] = doc.savedAtEpochMillis.toString()
        out[KEY_CAPTION] = doc.caption
        out[KEY_VISIBILITY] = doc.visibilityRaw
        out[KEY_ENTERED_INFO] = doc.enteredInfo.toString()
        out[KEY_PHOTO_COUNT] = doc.photos.size.toString()
        doc.photos.forEachIndexed { n, photo ->
            val p = "photo.$n."
            out[p + "file"] = photo.file
            photo.capturedAtEpochMillis?.let { out[p + "capturedAt"] = it.toString() }
            out[p + "capturedAtSource"] = photo.capturedAtSourceRaw
            val edit = photo.edit
            edit.filter?.let { out[p + "filter"] = it.raw }
            // 装備の並びでなく EditTool の並びで書く。0 のツールは ToolValues が持たないので書かれない
            for (tool in EditTool.entries) {
                if (!tool.isSlider) continue
                val v = edit.tools[tool]
                if (v != 0) out[p + "tool." + tool.raw] = v.toString()
            }
            if (edit.geometry.quarterTurns != 0) out[p + "turns"] = edit.geometry.quarterTurns.toString()
            val crop = edit.geometry.crop
            if (crop != NormalizedRect.FULL) {
                out[p + "crop"] = "${crop.left},${crop.top},${crop.right},${crop.bottom}"
            }
        }
        return out
    }

    /**
     * 版が新しすぎる・必須の鍵が無い・写真が 0 枚なら null。sessionId の鍵は必須にしない（無ければ空の文字列。
     * ViewModel は、読み戻した印が空なら新しく作る。clearSession は空の印では何も消さない）
     *
     * 必須の鍵＝`version`・`savedAt`・`caption`・`visibility`・`enteredInfo`・`photo.count`（値が読めないのも「無い」と同じ）。
     * 写真の枚数が 1〜10 の外なら null。写真の `file` が相対の場所でない（`..` を含む・絶対・空）ときは、
     * 文書ぜんたいを null にする（利用者のフォルダの外を指す文書は、一部だけ生かさず読まない）。
     * 写真の編集の値が壊れているときは、その写真の編集だけを [PhotoEdit.NONE] にして写真を残す。
     */
    fun decodeWork(map: Map<String, String>): EditWorkDocument? {
        if (!isReadableVersion(map[KEY_VERSION])) return null
        val savedAt = map[KEY_SAVED_AT]?.toLongOrNull() ?: return null
        val caption = map[KEY_CAPTION] ?: return null
        val visibility = map[KEY_VISIBILITY] ?: return null
        val entered = parseBoolean(map[KEY_ENTERED_INFO]) ?: return null
        val count = map[KEY_PHOTO_COUNT]?.toIntOrNull() ?: return null
        if (count !in MIN_PHOTOS..MAX_PHOTOS) return null
        val photos = (0 until count).map { n -> decodePhoto(map, n) ?: return null }
        return EditWorkDocument(
            sessionId = map[KEY_SESSION_ID] ?: "",
            draftId = map[KEY_DRAFT_ID],
            savedAtEpochMillis = savedAt,
            caption = caption,
            visibilityRaw = visibility,
            enteredInfo = entered,
            photos = photos,
        )
    }

    // ---- 内部 ----

    /** 1 以上で VERSION 以下の整数 */
    private fun isReadableVersion(raw: String?): Boolean {
        val v = raw?.toIntOrNull() ?: return false
        return v in 1..VERSION
    }

    /** "true" / "false" だけ（Properties の文字列。大文字小文字は区別する） */
    private fun parseBoolean(raw: String?): Boolean? = when (raw) {
        "true" -> true
        "false" -> false
        else -> null
    }

    /** 写真 1 枚。`file` が使えなければ null（呼び出し側が文書ぜんたいを null にする） */
    private fun decodePhoto(map: Map<String, String>, n: Int): EditWorkPhoto? {
        val p = "photo.$n."
        val file = map[p + "file"]?.takeIf { isSafeRelativePath(it) } ?: return null
        return EditWorkPhoto(
            file = file,
            // 読めない撮影日時は「撮影日時なし」として扱う（写真は残す）
            capturedAtEpochMillis = map[p + "capturedAt"]?.toLongOrNull(),
            capturedAtSourceRaw = map[p + "capturedAtSource"] ?: SOURCE_NONE,
            edit = decodeEdit(map, p) ?: PhotoEdit.NONE,
        )
    }

    /**
     * 編集の値。どれか 1 つでも壊れていれば null（呼び出し側が [PhotoEdit.NONE] にする）。
     * 「壊れている」＝知っている鍵の値が読めない・範囲の外。知らないフィルターの名前も壊れた値として扱う。
     * `photo.N.tool.<raw>` の `<raw>` が知らない名前（またはスライダーでないツール）の鍵は、知らない鍵として読み飛ばす。
     */
    private fun decodeEdit(map: Map<String, String>, p: String): PhotoEdit? {
        val filter = map[p + "filter"]?.let { FilterId.fromRaw(it) ?: return null }

        var tools = ToolValues.NONE
        val toolPrefix = p + "tool."
        for ((key, value) in map) {
            if (!key.startsWith(toolPrefix)) continue
            val tool = EditTool.fromRaw(key.removePrefix(toolPrefix)) ?: continue
            if (!tool.isSlider) continue
            val v = value.toIntOrNull() ?: return null
            if (v !in EditTool.MIN..EditTool.MAX) return null
            tools = tools.with(tool, v)
        }

        val turns = map[p + "turns"]?.let { it.toIntOrNull() ?: return null } ?: 0
        if (turns !in 0..3) return null

        val crop = map[p + "crop"]?.let { parseCrop(it) ?: return null } ?: NormalizedRect.FULL

        return PhotoEdit(filter = filter, tools = tools, geometry = EditGeometry(quarterTurns = turns, crop = crop))
    }

    /** 「左,上,右,下」の小数 4 つ。有限で 0〜1 の中にあり、左<右・上<下 のときだけ。それ以外は null */
    private fun parseCrop(raw: String): NormalizedRect? {
        val parts = raw.split(",")
        if (parts.size != 4) return null
        val v = parts.map { it.trim().toDoubleOrNull() ?: return null }
        if (v.any { !it.isFinite() || it < 0.0 || it > 1.0 }) return null
        if (v[0] >= v[2] || v[1] >= v[3]) return null
        return NormalizedRect(v[0], v[1], v[2], v[3])
    }

    /**
     * 利用者のフォルダからの相対の場所だけを受け付ける。空・絶対（`/` 始まり・`\` を含む・ドライブ名の `:`）・
     * `..` の部分・NUL を含むものは受け付けない。
     */
    private fun isSafeRelativePath(path: String): Boolean {
        if (path.isBlank()) return false
        if (path.startsWith("/") || path.contains('\\') || path.contains(':') || path.contains('\u0000')) return false
        return path.split("/").none { it == ".." }
    }
}
