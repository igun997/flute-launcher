package id.nst.focus_launcher

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build

/**
 * Notifications for routine results. Channel `flute_routines`, one notification per routine (a
 * newer result replaces the older one). Tapping opens the app on that run; "Run again" queues
 * the routine again through [RoutineReceiver].
 */
object Notifier {
    private const val ROUTINE_CHANNEL = "flute_routines"
    private const val CHANNEL_NAME = "Routines"
    private const val RUN_AGAIN = "Run again"
    private const val TAG = "routine"

    fun canPost(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return context.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() == true
    }

    /** Posts or replaces the result notification of one routine. False when it cannot be shown. */
    @Suppress("DEPRECATION")
    fun postRoutineResult(
        context: Context,
        routineId: String,
        runId: String,
        title: String,
        text: String,
        ok: Boolean,
    ): Boolean {
        if (!canPost(context)) return false
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        ensureChannel(context, manager)

        val openIntent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(RoutineNative.EXTRA_OPEN_RUN, runId)
        val open = PendingIntent.getActivity(
            context,
            runId.hashCode(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val runAgain = PendingIntent.getBroadcast(
            context,
            routineId.hashCode(),
            Intent(context, RoutineReceiver::class.java)
                .setAction(RoutineScheduler.ACTION_RUN_NOW)
                .setData(Uri.parse("flute-routine-now://$routineId"))
                .putExtra(RoutineScheduler.EXTRA_ID, routineId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, ROUTINE_CHANNEL)
        } else {
            Notification.Builder(context)
        }
        val icon = Icon.createWithResource(context, R.mipmap.ic_launcher)
        val notification = builder
            .setContentTitle(title)
            .setContentText(firstLine(text))
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(if (ok) Notification.CATEGORY_MESSAGE else Notification.CATEGORY_ERROR)
            .addAction(Notification.Action.Builder(icon, RUN_AGAIN, runAgain).build())
            .build()
        manager.notify(TAG, routineId.hashCode(), notification)
        return true
    }

    private fun firstLine(text: String): String = text.lineSequence().firstOrNull()?.take(120).orEmpty()

    private fun ensureChannel(context: Context, manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(ROUTINE_CHANNEL) != null) return
        manager.createNotificationChannel(
            NotificationChannel(ROUTINE_CHANNEL, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT),
        )
    }
}
