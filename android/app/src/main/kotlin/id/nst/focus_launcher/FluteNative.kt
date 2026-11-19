package id.nst.focus_launcher

import android.app.KeyguardManager
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors
import kotlin.math.roundToInt

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
                // Video frames for models that take only images. Decoding is slow: it runs on the worker.
                "extractVideoFrames" -> {
                    val path = call.string("path")
                    val count = call.argument<Number>("count")?.toInt() ?: DEFAULT_FRAME_COUNT
                    val maxEdge = call.argument<Number>("maxEdge")?.toInt() ?: DEFAULT_FRAME_EDGE
                    inBackground(result) { extractVideoFrames(path, count, maxEdge) }
                }
                "videoInfo" -> {
                    val path = call.string("path")
                    inBackground(result) { videoInfo(path) }
                }
                // Files the agent made. FluteFiles refuses any path outside the app's files directory.
                "shareFile" -> result.success(
                    FluteFiles.share(context, call.string("path"), call.optionalString("mime"), call.optionalString("name")),
                )
                "openFile" -> result.success(FluteFiles.open(context, call.string("path"), call.optionalString("mime")))
                "saveToDownloads" -> {
                    val path = call.string("path")
                    val name = call.string("name")
                    val mime = call.optionalString("mime")
                    inBackground(result) { FluteFiles.saveToDownloads(context, path, name, mime) }
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

    private fun MethodCall.optionalString(key: String): String = argument<String>(key).orEmpty()

    /**
     * JPEG frames evenly spaced through the video, longest edge at most [maxEdge]. Null when the
     * file cannot be read or no frame decodes. Call only from a worker thread.
     */
    private fun extractVideoFrames(path: String, count: Int, maxEdge: Int): List<ByteArray>? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationMs =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                    ?: return null
            val n = count.coerceIn(1, MAX_FRAMES)
            val edge = maxEdge.coerceIn(MIN_FRAME_EDGE, MAX_FRAME_EDGE)
            val frames = ArrayList<ByteArray>(n)
            for (i in 0 until n) {
                // The middle of each of n equal slices, so no frame is taken at the very first or last instant.
                val timeUs = durationMs * 1000L * (2 * i + 1) / (2 * n)
                val frame = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    ?: continue
                frames.add(jpegScaled(frame, edge))
            }
            return frames.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            // Class name only: the path must not reach logs or the UI.
            return null
        } finally {
            retriever.release()
        }
    }

    /** Duration in milliseconds and display size of a video (quarter turns applied), or null. */
    private fun videoInfo(path: String): Map<String, Any>? {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val durationMs =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                    ?: return null
            val width = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull()
                ?: return null
            val height = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull()
                ?: return null
            val rotation = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
                ?: 0
            val turned = rotation == 90 || rotation == 270
            return mapOf(
                "durationMs" to durationMs,
                "width" to (if (turned) height else width),
                "height" to (if (turned) width else height),
            )
        } catch (e: Exception) {
            // Class name only: the path must not reach logs or the UI.
            return null
        } finally {
            retriever.release()
        }
    }

    /** Scales [frame] so its longest edge is at most [maxEdge], encodes it as JPEG and recycles it. */
    private fun jpegScaled(frame: Bitmap, maxEdge: Int): ByteArray {
        val longest = maxOf(frame.width, frame.height)
        val scaled = if (longest > maxEdge) {
            val factor = maxEdge.toFloat() / longest
            Bitmap.createScaledBitmap(
                frame,
                (frame.width * factor).roundToInt().coerceAtLeast(1),
                (frame.height * factor).roundToInt().coerceAtLeast(1),
                true,
            )
        } else {
            frame
        }
        try {
            val out = ByteArrayOutputStream()
            check(scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)) { "jpeg encode failed" }
            return out.toByteArray()
        } finally {
            if (scaled !== frame) scaled.recycle()
            frame.recycle()
        }
    }

    companion object {
        const val CHANNEL = "flute/native"
        const val EVENTS_CHANNEL = "flute/events"
        private const val DEFAULT_MESSAGE_LIMIT = 30
        private const val DEFAULT_PAUSE_SECONDS = 10
        private const val DEFAULT_GRACE_MINUTES = 5
        private const val DEFAULT_ICON_SIZE = 96
        private const val DEFAULT_FRAME_COUNT = 6
        private const val MAX_FRAMES = 16
        private const val DEFAULT_FRAME_EDGE = 768
        private const val MIN_FRAME_EDGE = 64
        private const val MAX_FRAME_EDGE = 2048
        private const val JPEG_QUALITY = 80
    }
}
