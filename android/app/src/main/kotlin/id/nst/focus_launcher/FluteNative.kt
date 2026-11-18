package id.nst.focus_launcher

import android.app.KeyguardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Handles `flute/native` calls and registers the `flute/events` stream.
 * Heavy queries run on [worker]; results are always replied on the main thread.
 */
class FluteNative(private val context: Context) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENTS_CHANNEL).setStreamHandler(FluteEvents)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getApps" -> inBackground(result) { AppCatalog.launchable(context).map { it.toMap() } }
                "launchApp" -> result.success(AppCatalog.launch(context, call.string("package")))
                "openAppInfo" -> {
                    AppCatalog.openInfo(context, call.string("package"))
                    result.success(null)
                }
                "hasUsageAccess" -> result.success(Permissions.hasUsageAccess(context))
                "openUsageAccessSettings" -> {
                    Permissions.openUsageAccess(context)
                    result.success(null)
                }
                "getUsageToday" -> inBackground(result) { UsageTracker.todayTotals(context).map { it.toMap() } }
                "hasNotificationAccess" -> result.success(Permissions.hasNotificationAccess(context))
                "openNotificationAccessSettings" -> {
                    Permissions.openNotificationAccess(context)
                    result.success(null)
                }
                "hasOverlayPermission" -> result.success(Permissions.hasOverlayPermission(context))
                "openOverlaySettings" -> {
                    Permissions.openOverlaySettings(context)
                    result.success(null)
                }
                "getRecentMessages" -> {
                    val limit = call.argument<Number>("limit")?.toInt() ?: DEFAULT_MESSAGE_LIMIT
                    result.success(MessageStore.recent(context, limit).map { it.toMap() })
                }
                "clearRecentMessages" -> {
                    MessageStore.clear(context)
                    result.success(null)
                }
                "setLockConfig" -> {
                    val settings = lockSettingsFrom(call)
                    LockConfigStore.save(context, settings)
                    LockService.sync(context, settings)
                    result.success(null)
                }
                "hasPolicyAccess" -> result.success(Dnd.hasAccess(context))
                "openPolicyAccessSettings" -> {
                    Permissions.openPolicyAccess(context)
                    result.success(null)
                }
                "setDoNotDisturb" -> result.success(Dnd.set(context, call.argument<Boolean>("enabled") ?: false))
                "isDefaultLauncher" -> result.success(Permissions.isDefaultLauncher(context))
                "openHomeSettings" -> {
                    Permissions.openHomeSettings(context)
                    result.success(null)
                }
                // Batch PNG icons for the Dart pins. Off the main thread: bitmap work.
                "getIcons" -> {
                    val packages = call.stringList("packages")
                    val size = call.argument<Number>("size")?.toInt() ?: DEFAULT_ICON_SIZE
                    inBackground(result) { AppIcons.render(context, packages, size) }
                }
                "getSurface" -> result.success(FluteSurface.current)
                "setLockscreenEnabled" -> {
                    LockscreenSettings.setEnabled(context, call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "isLockscreenEnabled" -> result.success(LockscreenSettings.isEnabled(context))
                "isKeyguardLocked" -> result.success(isKeyguardLocked())
                // Replies exactly once: from the keyguard callback, or at once when no lockscreen is up.
                "dismissKeyguard" -> LockscreenActivity.dismissKeyguard { unlocked -> result.success(unlocked) }
                "finishLockscreen" -> {
                    LockscreenActivity.finishIfShowing()
                    result.success(null)
                }
                // Expanding the shade needs a privileged status-bar call that third-party apps
                // cannot make on current Android. Deliberately a no-op.
                "expandNotificationShade" -> result.success(null)
                // Locks through the connected accessibility service (double-tap to lock). False when it is not enabled.
                "lockScreen" -> result.success(FluteAccessibilityService.lockScreen())
                "isAccessibilityEnabled" -> result.success(FluteAccessibilityService.isEnabled(context))
                "openAccessibilitySettings" -> {
                    Permissions.openAccessibilitySettings(context)
                    result.success(null)
                }
                "getWakeInfo" -> result.success(WaveToWake.info(context))
                "setWaveToWake" -> {
                    WaveToWake.setEnabled(context, call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                }
                "isWaveToWakeEnabled" -> result.success(WaveToWake.isEnabled(context))
                "openMotionSettings" -> {
                    Permissions.openMotionSettings(context)
                    result.success(null)
                }
                "hasLocationPermission" -> result.success(LocationAccess.hasPermission(context))
                // Shows the system dialog when needed. Replies exactly once: at once, or from the permission callback.
                "requestLocationPermission" -> LocationAccess.requestPermission(context, result)
                // One coarse fix, or null. Replies on the main thread after at most about 8 s.
                "getLocation" -> LocationAccess.currentLocation(context) { result.success(it) }
                "reverseGeocode" -> {
                    val latitude = call.argument<Number>("latitude")?.toDouble()
                    val longitude = call.argument<Number>("longitude")?.toDouble()
                    if (latitude == null || longitude == null) {
                        result.success(null)
                    } else {
                        LocationAccess.reverseGeocode(context, latitude, longitude) { result.success(it) }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Class name only: messages and package details must not reach logs or the UI.
            result.error("native_failed", e.javaClass.simpleName, null)
        }
    }

    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            val value = try {
                work()
            } catch (e: Exception) {
                main.post { result.error("native_failed", e.javaClass.simpleName, null) }
                return@execute
            }
            main.post { result.success(value) }
        }
    }

    private fun isKeyguardLocked(): Boolean =
        context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true

    private fun lockSettingsFrom(call: MethodCall): LockSettings = LockSettings.create(
        enabled = call.argument<Boolean>("enabled") ?: false,
        locked = call.stringList("lockedPackages"),
        allowed = call.stringList("allowedPackages"),
        pauseSeconds = call.argument<Number>("pauseSeconds")?.toInt() ?: DEFAULT_PAUSE_SECONDS,
        graceMinutes = call.argument<Number>("graceMinutes")?.toInt() ?: DEFAULT_GRACE_MINUTES,
    )

    private fun MethodCall.string(key: String): String =
        argument<String>(key) ?: throw IllegalArgumentException(key)

    private fun MethodCall.stringList(key: String): List<String> =
        (argument<List<*>>(key) ?: emptyList<Any?>()).filterIsInstance<String>()

    companion object {
        const val CHANNEL = "flute/native"
        const val EVENTS_CHANNEL = "flute/events"
        private const val DEFAULT_MESSAGE_LIMIT = 30
        private const val DEFAULT_PAUSE_SECONDS = 10
        private const val DEFAULT_GRACE_MINUTES = 5
        private const val DEFAULT_ICON_SIZE = 96
    }
}
