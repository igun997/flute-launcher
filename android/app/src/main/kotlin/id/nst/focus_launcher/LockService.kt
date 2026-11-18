package id.nst.focus_launcher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings

/**
 * Soft lock. Polls the foreground app about once a second and shows [LockActivity]
 * over apps in the locked set, unless they are allowed, in a grace period, or exempt.
 *
 * Foreground state comes from the latest ACTIVITY_RESUMED event. Windows with no
 * events keep the last known package, since no event means nothing changed.
 */
class LockService : Service() {
    private var worker: HandlerThread? = null
    @Volatile private var handler: Handler? = null
    @Volatile private var settings: LockSettings? = null
    @Volatile private var exempt: Set<String> = emptySet()

    // Only touched from the worker thread.
    private var foreground: String? = null

    private val tick = object : Runnable {
        override fun run() {
            poll()
            handler?.postDelayed(this, POLL_INTERVAL_MS)
        }
    }

    /** No polling while the screen is off: nothing can be opened, so there is nothing to lock. */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> handler?.removeCallbacks(tick)
                Intent.ACTION_SCREEN_ON -> handler?.apply {
                    removeCallbacks(tick)
                    post(tick)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val thread = HandlerThread("flute-lock").also { it.start() }
        worker = thread
        handler = Handler(thread.looper)
        registerReceiver(
            screenReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Must promote to foreground on every start, even when about to stop.
        startAsForeground()
        val loaded = LockConfigStore.load(this)
        if (loaded == null || !loaded.isActive || !Permissions.hasUsageAccess(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        settings = loaded
        exempt = exemptPackages()
        handler?.apply {
            removeCallbacks(tick)
            if (getSystemService(PowerManager::class.java)?.isInteractive != false) post(tick)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        runCatching { unregisterReceiver(screenReceiver) }
        handler?.removeCallbacks(tick)
        worker?.quitSafely()
        handler = null
        worker = null
        super.onDestroy()
    }

    private fun poll() {
        val current = settings ?: return
        val now = System.currentTimeMillis()
        readLastResumed(now)?.let { foreground = it }
        val pkg = foreground ?: return
        if (pkg !in current.lockedPackages || pkg in current.allowedPackages || pkg in exempt) return
        if (LockState.isBlocked(pkg, now)) return
        // Block before launching: if the activity cannot start (background-start limits),
        // this stops a relaunch on every poll.
        LockState.block(pkg, now + RELAUNCH_COOLDOWN_MS)
        startLock(pkg, current)
    }

    /** Package of the latest ACTIVITY_RESUMED event in the recent window, if any. */
    private fun readLastResumed(now: Long): String? {
        val usageStats = getSystemService(UsageStatsManager::class.java) ?: return null
        val events: UsageEvents = try {
            usageStats.queryEvents(now - EVENT_WINDOW_MS, now) ?: return null
        } catch (e: SecurityException) {
            return null
        }
        val event = UsageEvents.Event()
        var last: String? = null
        var lastTs = Long.MIN_VALUE
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            if (event.eventType != UsageEvents.Event.ACTIVITY_RESUMED) continue
            val pkg = event.packageName ?: continue
            if (event.timeStamp >= lastTs) {
                last = pkg
                lastTs = event.timeStamp
            }
        }
        return last
    }

    private fun startLock(pkg: String, current: LockSettings) {
        startActivity(
            Intent(this, LockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(LockActivity.EXTRA_PACKAGE, pkg)
                .putExtra(LockActivity.EXTRA_PAUSE_SECONDS, current.pauseSeconds)
                .putExtra(LockActivity.EXTRA_GRACE_MINUTES, current.graceMinutes),
        )
    }

    /** Flute itself, the default launcher, Settings and system UI are never locked. */
    private fun exemptPackages(): Set<String> {
        val names = mutableSetOf(
            packageName,
            "android",
            "com.android.systemui",
            "com.android.settings",
            "com.android.permissioncontroller",
            "com.google.android.permissioncontroller",
        )
        Permissions.defaultHomePackage(this)?.let { names += it }
        packageManager.resolveActivity(Intent(Settings.ACTION_SETTINGS), 0)
            ?.activityInfo?.packageName?.let { names += it }
        return names
    }

    private fun startAsForeground() {
        ensureChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.lock_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setContentTitle(getString(R.string.lock_notification_title))
            .setContentText(getString(R.string.lock_notification_text))
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "focus_lock"
        private const val NOTIFICATION_ID = 4101
        private const val POLL_INTERVAL_MS = 900L
        private const val EVENT_WINDOW_MS = 10_000L
        private const val RELAUNCH_COOLDOWN_MS = 2_000L

        /** Starts the service when [settings] has something to lock, otherwise stops it. */
        fun sync(context: Context, settings: LockSettings?) {
            val intent = Intent(context, LockService::class.java)
            if (settings?.isActive == true) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } else {
                context.stopService(intent)
            }
        }
    }
}

/**
 * Per-package blocks in memory: the grace after "Open anyway", plus short cooldowns that
 * stop relaunch loops. Lost when the process dies, so grace restarts after a kill.
 */
internal object LockState {
    private val blockedUntil = HashMap<String, Long>()

    @Synchronized
    fun isBlocked(pkg: String, now: Long): Boolean = now < (blockedUntil[pkg] ?: 0L)

    /** Extends the block for [pkg] until [until]. Never shortens an existing block. */
    @Synchronized
    fun block(pkg: String, until: Long) {
        if (until > (blockedUntil[pkg] ?: 0L)) blockedUntil[pkg] = until
    }
}
