package id.nst.focus_launcher

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.Result

/**
 * `flute/routines` method channel and `flute/routines/events` stream: the routine schedule, the
 * notification permission, result notifications, and fires queued while Dart was not running.
 *
 * Events: `{type: fire, token, routineId, firedAtMs, manual}` and `{type: opened, runId}` (a
 * notification was tapped). Dart drains `pendingFires` and `takeOpenedRun` on start as well.
 */
class RoutineNative(private val context: Context) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            when (call.method) {
                "sync" -> {
                    RoutineScheduler.sync(context, specsFrom(call))
                    result.success(null)
                }
                "canScheduleExact" -> result.success(RoutineScheduler.canScheduleExact(context))
                "openExactAlarmSettings" -> {
                    openExactAlarmSettings()
                    result.success(null)
                }
                "hasNotificationPermission" -> result.success(Notifier.canPost(context))
                // Replies exactly once: at once, or from the permission dialog's answer.
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "notify" -> {
                    val shown = Notifier.postRoutineResult(
                        context,
                        call.string("routineId"),
                        call.string("runId"),
                        call.string("title"),
                        call.string("text"),
                        call.argument<Boolean>("ok") ?: true,
                    )
                    result.success(shown)
                }
                "pendingFires" -> result.success(RoutineScheduler.pendingFires(context))
                "ackFire" -> {
                    RoutineScheduler.ackFire(context, call.string("token"))
                    result.success(null)
                }
                "finishFire" -> {
                    RoutineScheduler.release(call.string("token"))
                    result.success(null)
                }
                "takeOpenedRun" -> result.success(takeOpenedRun())
                "isScreenOn" -> result.success(
                    context.getSystemService(PowerManager::class.java)?.isInteractive == true,
                )
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Class name only: prompts, names and results must not reach logs or the UI.
            result.error("native_failed", e.javaClass.simpleName, null)
        }
    }

    private fun specsFrom(call: MethodCall): List<RoutineScheduler.Spec> {
        val items = call.argument<List<*>>("items") ?: emptyList<Any?>()
        return items.mapNotNull { raw ->
            val m = raw as? Map<*, *> ?: return@mapNotNull null
            RoutineScheduler.Spec(
                id = m["id"] as? String ?: return@mapNotNull null,
                trigger = m["trigger"] as? String ?: "daily",
                minuteOfDay = (m["minuteOfDay"] as? Number)?.toInt() ?: 0,
                weekdays = (m["weekdays"] as? List<*>)?.mapNotNull { (it as? Number)?.toInt() }?.toSet() ?: emptySet(),
                everyMinutes = (m["everyMinutes"] as? Number)?.toInt() ?: 60,
                enabled = m["enabled"] == true,
                nextAtMs = (m["nextAtMs"] as? Number)?.toLong(),
            )
        }
    }

    private fun requestNotificationPermission(result: Result) {
        if (Notifier.canPost(context)) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // No runtime permission before Android 13: the user has to allow it in settings.
            result.success(false)
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        val shown = try {
            MainActivity.requestRuntimePermission(Manifest.permission.POST_NOTIFICATIONS, PERMISSION_REQUEST_CODE)
        } catch (e: RuntimeException) {
            false
        }
        if (!shown) {
            pendingPermission = null
            result.success(false)
        }
    }

    private fun openExactAlarmSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
            .setData(Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: RuntimeException) {
            // No settings screen on this device: nothing to open.
        }
    }

    // EventChannel: the single Dart listener for routine events.
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun MethodCall.string(key: String): String =
        argument<String>(key) ?: throw IllegalArgumentException(key)

    companion object {
        const val CHANNEL = "flute/routines"
        const val EVENTS_CHANNEL = "flute/routines/events"

        /** Request code for the notification-permission dialog shown by [MainActivity]. */
        const val PERMISSION_REQUEST_CODE = 4712

        /** Intent extra set on the notification tap that opens the app on a run. */
        const val EXTRA_OPEN_RUN = "flute_open_run"

        private val main = Handler(Looper.getMainLooper())

        @Volatile
        private var sink: EventChannel.EventSink? = null

        /** Main thread only: the open request waiting for Dart to take it. */
        private var openedRun: String? = null

        /** Main thread only: the reply owed for the notification-permission dialog on screen. */
        private var pendingPermission: Result? = null

        /** Delivers a queued fire to Dart when a listener is attached. Safe from any thread. */
        fun emitFire(fire: Map<String, Any?>) {
            main.post { sink?.success(mapOf("type" to "fire") + fire) }
        }

        /** Main thread only, from [MainActivity] when it starts with a notification tap. */
        fun noteOpenIntent(intent: Intent?) {
            val runId = intent?.getStringExtra(EXTRA_OPEN_RUN) ?: return
            openedRun = runId
            sink?.success(mapOf("type" to "opened", "runId" to runId))
        }

        /** Main thread only, from [MainActivity.onRequestPermissionsResult]. */
        fun onPermissionResult(granted: Boolean) {
            val result = pendingPermission ?: return
            pendingPermission = null
            result.success(granted)
        }

        /** Main thread only, from [MainActivity.onDestroy]: a dialog answer will never arrive now. */
        fun abandonPermissionRequest() {
            val result = pendingPermission ?: return
            pendingPermission = null
            result.success(false)
        }

        private fun takeOpenedRun(): String? {
            val runId = openedRun
            openedRun = null
            return runId
        }
    }
}
