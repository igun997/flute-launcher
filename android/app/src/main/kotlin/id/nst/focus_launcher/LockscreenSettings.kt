package id.nst.focus_launcher

import android.content.Context

/**
 * Whether the Flute lockscreen is on. Kept in native SharedPreferences so the
 * notification listener can read it while the Dart engine is not running.
 */
object LockscreenSettings {
    private const val PREFS = "flute_lockscreen"
    private const val KEY_ENABLED = "enabled"

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
