package id.nst.focus_launcher

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.LauncherApps
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings

/** Launchable apps via LauncherApps. Visibility comes from the manifest `<queries>` entry. */
object AppCatalog {
    class App(
        val pkg: String,
        val label: String,
        val category: Int,
        val isSystem: Boolean,
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "package" to pkg,
            "label" to label,
            "category" to category,
            "isSystem" to isSystem,
        )
    }

    /** One entry per package, sorted by label, excluding Flute itself. */
    fun launchable(context: Context): List<App> {
        val launcherApps = context.getSystemService(LauncherApps::class.java) ?: return emptyList()
        val seen = HashSet<String>()
        val apps = ArrayList<App>()
        for (info in launcherApps.getActivityList(null, Process.myUserHandle())) {
            val pkg = info.componentName.packageName
            if (pkg == context.packageName || !seen.add(pkg)) continue
            val appInfo = info.applicationInfo
            apps += App(
                pkg = pkg,
                label = info.label?.toString()?.takeIf { it.isNotBlank() } ?: pkg,
                // ApplicationInfo.category only exists on API 26+; -1 is CATEGORY_UNDEFINED.
                category = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) appInfo.category else -1,
                isSystem = (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) != 0,
            )
        }
        return apps.sortedBy { it.label.lowercase() }
    }

    fun launch(context: Context, pkg: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        return try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    fun openInfo(context: Context, pkg: String) {
        context.startActivity(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", pkg, null))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
