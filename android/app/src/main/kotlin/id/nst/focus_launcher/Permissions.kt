package id.nst.focus_launcher

import android.app.AppOpsManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Process
import android.provider.Settings

object Permissions {
    // Samsung's motions-and-gestures page. Class names are unverified on device; unresolved ones are skipped.
    private const val SAMSUNG_SETTINGS_PACKAGE = "com.samsung.android.settings"
    private val SAMSUNG_MOTION_ACTIVITIES = listOf(
        "com.samsung.android.settings.motion.MotionActivity",
        "com.samsung.android.settings.motion.MotionAndGesturesActivity",
    )

    /** Usage access is an app-op that only the user can grant in settings. */
    fun hasUsageAccess(context: Context): Boolean {
        val appOps = context.getSystemService(AppOpsManager::class.java) ?: return false
        val mode = appOps.checkOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            Process.myUid(),
            context.packageName,
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    fun openPolicyAccess(context: Context) {
        start(context, Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS))
    }

    fun openUsageAccess(context: Context) {
        start(context, Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
    }

    fun hasNotificationAccess(context: Context): Boolean {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        return manager.isNotificationListenerAccessGranted(
            ComponentName(context, FluteNotificationListener::class.java),
        )
    }

    fun openNotificationAccess(context: Context) {
        start(context, Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
    }

    fun hasOverlayPermission(context: Context): Boolean = Settings.canDrawOverlays(context)

    fun openOverlaySettings(context: Context) {
        start(
            context,
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.fromParts("package", context.packageName, null)),
        )
    }

    fun isDefaultLauncher(context: Context): Boolean =
        defaultHomePackage(context) == context.packageName

    /** Package that handles HOME, or null when none or several are set (chooser). */
    fun defaultHomePackage(context: Context): String? {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        return context.packageManager
            .resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
            ?.activityInfo
            ?.packageName
    }

    fun openHomeSettings(context: Context) {
        try {
            start(context, Intent(Settings.ACTION_HOME_SETTINGS))
        } catch (e: ActivityNotFoundException) {
            start(context, Intent(Settings.ACTION_SETTINGS))
        }
    }

    fun openAccessibilitySettings(context: Context) {
        start(context, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    }

    /**
     * Best effort: Samsung's motions-and-gestures page when it resolves, else display settings.
     * Never throws; a failed start falls through to the next target.
     */
    fun openMotionSettings(context: Context) {
        val samsung = SAMSUNG_MOTION_ACTIVITIES
            .map { Intent().setClassName(SAMSUNG_SETTINGS_PACKAGE, it) }
            .firstOrNull { it.resolveActivity(context.packageManager) != null }
        if (samsung != null && tryStart(context, samsung)) return
        tryStart(context, Intent(Settings.ACTION_DISPLAY_SETTINGS))
    }

    private fun tryStart(context: Context, intent: Intent): Boolean = try {
        start(context, intent)
        true
    } catch (e: RuntimeException) {
        // ActivityNotFoundException and SecurityException: nothing about the device reaches the log.
        false
    }

    private fun start(context: Context, intent: Intent) {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
