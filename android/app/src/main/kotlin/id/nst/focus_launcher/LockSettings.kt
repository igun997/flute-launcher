package id.nst.focus_launcher

import android.content.Context
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/** Soft-lock configuration, mirrored from Dart's `LockConfig`. */
data class LockSettings(
    val enabled: Boolean,
    val lockedPackages: Set<String>,
    val allowedPackages: Set<String>,
    val pauseSeconds: Int,
    val graceMinutes: Int,
) {
    /** The lock service only runs when there is something to lock. */
    val isActive: Boolean get() = enabled && lockedPackages.isNotEmpty()

    fun toJson(): JSONObject = JSONObject()
        .put("enabled", enabled)
        .put("lockedPackages", JSONArray(lockedPackages.toList()))
        .put("allowedPackages", JSONArray(allowedPackages.toList()))
        .put("pauseSeconds", pauseSeconds)
        .put("graceMinutes", graceMinutes)

    companion object {
        const val MAX_PAUSE_SECONDS = 120
        const val MAX_GRACE_MINUTES = 1440

        fun create(
            enabled: Boolean,
            locked: Collection<String>,
            allowed: Collection<String>,
            pauseSeconds: Int,
            graceMinutes: Int,
        ) = LockSettings(
            enabled = enabled,
            lockedPackages = locked.toSet(),
            allowedPackages = allowed.toSet(),
            pauseSeconds = pauseSeconds.coerceIn(0, MAX_PAUSE_SECONDS),
            // Zero would re-lock the package the instant "Open anyway" is pressed.
            graceMinutes = graceMinutes.coerceIn(1, MAX_GRACE_MINUTES),
        )

        fun fromJson(o: JSONObject): LockSettings = create(
            enabled = o.optBoolean("enabled", false),
            locked = o.optJSONArray("lockedPackages").strings(),
            allowed = o.optJSONArray("allowedPackages").strings(),
            pauseSeconds = o.optInt("pauseSeconds", 10),
            graceMinutes = o.optInt("graceMinutes", 5),
        )

        private fun JSONArray?.strings(): List<String> =
            if (this == null) emptyList() else (0 until length()).map { optString(it) }
    }
}

/** Persists the last [LockSettings] so the service can come back after a reboot. */
object LockConfigStore {
    private const val PREFS = "flute_lock"
    private const val KEY = "config"

    fun save(context: Context, settings: LockSettings) {
        prefs(context).edit().putString(KEY, settings.toJson().toString()).apply()
    }

    fun load(context: Context): LockSettings? {
        val raw = prefs(context).getString(KEY, null) ?: return null
        return try {
            LockSettings.fromJson(JSONObject(raw))
        } catch (e: JSONException) {
            null
        }
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
