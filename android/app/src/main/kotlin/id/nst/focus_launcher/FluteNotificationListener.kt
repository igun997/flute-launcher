package id.nst.focus_launcher

import android.app.KeyguardManager
import android.app.Notification
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.UUID

/**
 * Captures WhatsApp and SMS messages from notifications. Only notifications posted
 * after the listener connected are kept, so nothing older than the grant is imported.
 *
 * The system keeps this service bound, so it also watches the screen and starts the
 * Flute lockscreen when the device is locked (see [maybeShowLockscreen]). It also
 * drives the wave-to-wake proximity sensor ([WaveToWake]) while the screen is off.
 */
class FluteNotificationListener : NotificationListenerService() {
    private var screenReceiverRegistered = false

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    WaveToWake.onScreenOff(this@FluteNotificationListener)
                    maybeShowLockscreen(turnScreenOn = false)
                }
                Intent.ACTION_SCREEN_ON -> {
                    WaveToWake.stop()
                    maybeShowLockscreen(turnScreenOn = true)
                }
            }
        }
    }

    override fun onListenerConnected() {
        connectedAt = System.currentTimeMillis()
        registerScreenReceiver()
    }

    override fun onListenerDisconnected() {
        WaveToWake.stop()
        unregisterScreenReceiver()
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        WaveToWake.stop()
        unregisterScreenReceiver()
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val source = sourceFor(sbn.packageName) ?: return
        val since = connectedAt
        if (since == 0L || sbn.postTime < since) return

        val notification = sbn.notification ?: return
        if ((notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return
        val extras = notification.extras ?: return

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val newest = newestMessagingEntry(extras)
        val body = newest?.text
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
        val text = body?.trim().orEmpty()
        if (text.isEmpty() || isPlaceholder(text)) return

        val message = CapturedMessage(
            id = UUID.randomUUID().toString(),
            source = source,
            pkg = sbn.packageName,
            sender = newest?.sender?.takeIf { it.isNotBlank() } ?: title,
            text = text,
            timestampMs = newest?.timeMs?.takeIf { it > 0L } ?: sbn.postTime,
            conversationKey = "${sbn.packageName}|$title",
        )
        if (MessageStore.insert(this, message)) {
            FluteEvents.emit(mapOf("type" to "message", "message" to message.toMap()))
        }
    }

    private class MessagingEntry(val sender: String?, val text: String?, val timeMs: Long)

    /** The newest entry of a MessagingStyle notification (its bundles are oldest first). */
    @Suppress("DEPRECATION")
    private fun newestMessagingEntry(extras: Bundle): MessagingEntry? {
        // Bundle keys of Notification.MessagingStyle.Message; the constants are not public.
        val last = extras.getParcelableArray(Notification.EXTRA_MESSAGES)?.lastOrNull() as? Bundle
            ?: return null
        return MessagingEntry(
            sender = last.getCharSequence("sender")?.toString(),
            text = last.getCharSequence("text")?.toString(),
            timeMs = last.getLong("time"),
        )
    }

    private fun isPlaceholder(text: String): Boolean =
        PLACEHOLDER.matches(text) || text.equals("Checking for new messages", ignoreCase = true)

    private fun sourceFor(pkg: String): String? = when (pkg) {
        in WHATSAPP_PACKAGES -> "whatsapp"
        in SMS_PACKAGES -> "sms"
        else -> null
    }

    private fun registerScreenReceiver() {
        if (screenReceiverRegistered) return
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF).apply {
            addAction(Intent.ACTION_SCREEN_ON)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
        screenReceiverRegistered = true
    }

    private fun unregisterScreenReceiver() {
        if (!screenReceiverRegistered) return
        screenReceiverRegistered = false
        unregisterReceiver(screenReceiver)
    }

    /**
     * Starts the lockscreen on SCREEN_OFF and SCREEN_ON when every guard passes.
     * [turnScreenOn] is true only for SCREEN_ON, the one launch allowed to wake the device.
     */
    private fun maybeShowLockscreen(turnScreenOn: Boolean) {
        if (!LockscreenSettings.isEnabled(this)) return
        if (!Permissions.hasOverlayPermission(this)) return
        val keyguard = getSystemService(KeyguardManager::class.java) ?: return
        // A secure device counts as locked the moment the screen turns off, before the keyguard reports it.
        val locked = keyguard.isKeyguardLocked || (!turnScreenOn && keyguard.isDeviceSecure)
        if (!locked) return
        if (!isTelephonyIdle(this) || hasAlarmOrCallNotification()) return
        // MainActivity holds the shared engine while started; a second attach crashes libflutter.
        if (MainActivity.isVisible()) return
        if (LockscreenActivity.isShowing()) return
        try {
            startActivity(
                Intent(this, LockscreenActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(LockscreenActivity.EXTRA_TURN_SCREEN_ON, turnScreenOn),
            )
        } catch (e: RuntimeException) {
            // Class name only: nothing about the device or its messages reaches the log.
            Log.w(TAG, "lockscreen not started: ${e.javaClass.simpleName}")
        }
    }

    private fun hasAlarmOrCallNotification(): Boolean {
        val active = activeNotifications ?: return false
        return active.any { sbn ->
            val category = sbn.notification?.category
            category == Notification.CATEGORY_ALARM || category == Notification.CATEGORY_CALL
        }
    }

    companion object {
        private const val TAG = "FluteListener"
        private val WHATSAPP_PACKAGES = setOf("com.whatsapp", "com.whatsapp.w4b")
        private val SMS_PACKAGES = setOf(
            "com.google.android.apps.messaging",
            "com.samsung.android.messaging",
            "com.android.mms",
            "com.android.messaging",
        )
        private val PLACEHOLDER = Regex("""\d+ new messages?""", RegexOption.IGNORE_CASE)

        /** Set in onListenerConnected; 0 means not connected yet. */
        @Volatile
        private var connectedAt = 0L
    }
}

/**
 * Calls and ringing show up as audio modes. TelephonyManager.getCallState needs
 * READ_PHONE_STATE, which Flute deliberately does not request, so the audio mode is the check.
 * IN_COMMUNICATION covers VoIP calls.
 */
internal fun isTelephonyIdle(context: Context): Boolean {
    val mode = context.getSystemService(AudioManager::class.java)?.mode ?: return true
    return mode != AudioManager.MODE_IN_CALL &&
        mode != AudioManager.MODE_RINGTONE &&
        mode != AudioManager.MODE_IN_COMMUNICATION
}
