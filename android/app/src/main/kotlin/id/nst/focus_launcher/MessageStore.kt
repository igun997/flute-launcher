package id.nst.focus_launcher

import android.content.Context
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** A message captured from a notification. The text is never logged. */
data class CapturedMessage(
    val id: String,
    val source: String,
    val pkg: String,
    val sender: String,
    val text: String,
    val timestampMs: Long,
    val conversationKey: String,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "source" to source,
        "package" to pkg,
        "sender" to sender,
        "text" to text,
        "timestampMs" to timestampMs,
        "conversationKey" to conversationKey,
    )

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("source", source)
        .put("package", pkg)
        .put("sender", sender)
        .put("text", text)
        .put("timestampMs", timestampMs)
        .put("conversationKey", conversationKey)
}

/** Newest-first JSON array in SharedPreferences, capped at [MAX_STORED]. */
object MessageStore {
    const val MAX_STORED = 200
    private const val PREFS = "flute_messages"
    private const val KEY = "recent"

    /** Returns false when the same conversation, text and timestamp is already stored. */
    @Synchronized
    fun insert(context: Context, message: CapturedMessage): Boolean {
        val existing = readAll(context)
        val duplicate = existing.any {
            it.conversationKey == message.conversationKey &&
                it.text == message.text &&
                it.timestampMs == message.timestampMs
        }
        if (duplicate) return false
        val updated = (listOf(message) + existing)
            .sortedByDescending { it.timestampMs }
            .take(MAX_STORED)
        prefs(context).edit().putString(KEY, JSONArray(updated.map { it.toJson() }).toString()).apply()
        return true
    }

    @Synchronized
    fun recent(context: Context, limit: Int): List<CapturedMessage> =
        readAll(context).take(limit.coerceAtLeast(0))

    @Synchronized
    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }

    private fun readAll(context: Context): List<CapturedMessage> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).map { fromJson(array.getJSONObject(it)) }
        } catch (e: JSONException) {
            emptyList()
        }
    }

    private fun fromJson(o: JSONObject) = CapturedMessage(
        id = o.optString("id"),
        source = o.optString("source"),
        pkg = o.optString("package"),
        sender = o.optString("sender"),
        text = o.optString("text"),
        timestampMs = o.optLong("timestampMs"),
        conversationKey = o.optString("conversationKey"),
    )

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
