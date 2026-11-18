package id.nst.focus_launcher

import android.app.NotificationManager
import android.content.Context

/**
 * Do Not Disturb for Sleep mode. Needs "Do Not Disturb access", which only the user can
 * grant in settings. Flute only ever undoes a change it made: the filter that was active
 * before is saved when Flute turns DND on and put back when it turns it off.
 */
object Dnd {
    private const val PREFS = "flute_dnd"
    private const val KEY_ACTIVE = "active"
    private const val KEY_PREVIOUS = "previous"

    fun hasAccess(context: Context): Boolean =
        context.getSystemService(NotificationManager::class.java)?.isNotificationPolicyAccessGranted == true

    /** Returns false when access is missing, so the caller can show how to grant it. */
    fun set(context: Context, enable: Boolean): Boolean {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return false
        if (!nm.isNotificationPolicyAccessGranted) return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val active = prefs.getBoolean(KEY_ACTIVE, false)
        if (enable && !active) {
            prefs.edit()
                .putInt(KEY_PREVIOUS, nm.currentInterruptionFilter)
                .putBoolean(KEY_ACTIVE, true)
                .apply()
            nm.setInterruptionFilter(NotificationManager.INTERRUPTION_FILTER_ALARMS)
        } else if (!enable && active) {
            val previous = prefs.getInt(KEY_PREVIOUS, NotificationManager.INTERRUPTION_FILTER_ALL)
            nm.setInterruptionFilter(
                if (previous == NotificationManager.INTERRUPTION_FILTER_UNKNOWN) {
                    NotificationManager.INTERRUPTION_FILTER_ALL
                } else {
                    previous
                },
            )
            prefs.edit().putBoolean(KEY_ACTIVE, false).apply()
        }
        return true
    }
}
