package id.nst.focus_launcher

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings

/**
 * Wakes the screen with two deliberate waves over the proximity sensor, so the phone can be woken
 * without its power button. A wave is near, far, near, far: each near phase ends within
 * [NEAR_MAX_MS] and the whole gesture within [WAVE_WINDOW_MS].
 *
 * The sensor is registered by [onScreenOff] and dropped by [stop] (screen on, listener gone, or the
 * setting turned off), so it never runs with the screen on. A wave wakes the screen; the SCREEN_ON
 * path of [FluteNotificationListener] then shows the lockscreen.
 *
 * All state is touched on the main thread: the sensor is registered with the default (main) handler.
 */
object WaveToWake : SensorEventListener {
    private const val PREFS = "flute_wake"
    private const val KEY_WAVE = "waveToWake"
    private const val NEAR_MAX_MS = 1_200L
    private const val WAVE_WINDOW_MS = 2_000L
    private const val DEBOUNCE_MS = 3_000L
    private const val WAKE_HOLD_MS = 3_000L
    private const val WAKE_LOCK_TAG = "Flute:waveToWake"

    // Keys that Samsung and other OEMs use for the system double-tap settings.
    private val SYSTEM_WAKE_KEYS = listOf("double_tab_to_wake_up", "double_tap_to_wake")
    private const val SYSTEM_SLEEP_KEY = "double_tap_to_sleep"

    private var sensorManager: SensorManager? = null
    private var appContext: Context? = null
    private var registered = false

    private var near = false
    private var nearSince = 0L
    private var attemptStart = 0L
    private var covers = 0
    private var lastWakeAt = 0L

    /** Wake and sleep state the Dart settings page shows. */
    fun info(context: Context): Map<String, Any?> {
        val resolver = context.contentResolver
        val hasProximity = context.getSystemService(SensorManager::class.java)
            ?.getDefaultSensor(Sensor.TYPE_PROXIMITY) != null
        return mapOf(
            "systemDoubleTapWake" to SYSTEM_WAKE_KEYS.any { Settings.System.getInt(resolver, it, 0) == 1 },
            "systemDoubleTapSleep" to (Settings.System.getInt(resolver, SYSTEM_SLEEP_KEY, 0) == 1),
            "hasProximity" to hasProximity,
            "waveToWake" to isEnabled(context),
        )
    }

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_WAVE, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_WAVE, enabled).apply()
        if (!enabled) stop()
    }

    /** Registers the wake-up proximity sensor (falls back to the normal one). Called on SCREEN_OFF. */
    fun onScreenOff(context: Context) {
        if (registered || !isEnabled(context)) return
        val manager = context.getSystemService(SensorManager::class.java) ?: return
        val sensor = manager.getDefaultSensor(Sensor.TYPE_PROXIMITY, true)
            ?: manager.getDefaultSensor(Sensor.TYPE_PROXIMITY)
            ?: return
        if (!manager.registerListener(this, sensor, SensorManager.SENSOR_DELAY_NORMAL)) return
        sensorManager = manager
        appContext = context.applicationContext
        registered = true
        resetAttempt()
        near = false
    }

    /** Unregisters the sensor. Safe to call when nothing is registered. */
    fun stop() {
        if (!registered) return
        sensorManager?.unregisterListener(this)
        sensorManager = null
        appContext = null
        registered = false
        near = false
        nearSince = 0L
        resetAttempt()
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event == null || event.values.isEmpty()) return
        val isNear = event.values[0] < event.sensor.maximumRange
        if (isNear == near) return
        near = isNear
        val now = SystemClock.elapsedRealtime()
        if (isNear) onNear(now) else onFar(now)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private fun onNear(now: Long) {
        if (now - lastWakeAt < DEBOUNCE_MS) return
        if (attemptStart != 0L && now - attemptStart > WAVE_WINDOW_MS) resetAttempt()
        if (attemptStart == 0L) attemptStart = now
        nearSince = now
    }

    private fun onFar(now: Long) {
        val started = nearSince
        nearSince = 0L
        if (started == 0L) return
        if (now - started > NEAR_MAX_MS) {
            // Held too long to be a wave (a pocket, a hand on the sensor): start over.
            resetAttempt()
            return
        }
        covers++
        if (covers < 2) return
        val inWindow = now - attemptStart <= WAVE_WINDOW_MS
        resetAttempt()
        if (inWindow) wake(now)
    }

    private fun wake(now: Long) {
        val context = appContext ?: return
        if (!isTelephonyIdle(context)) return
        lastWakeAt = now
        wakeScreen(context)
    }

    /** Turns the screen on; the lock is released by itself after [WAKE_HOLD_MS]. */
    @Suppress("DEPRECATION")
    private fun wakeScreen(context: Context) {
        val power = context.getSystemService(PowerManager::class.java) ?: return
        if (power.isInteractive) return
        val lock = power.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            WAKE_LOCK_TAG,
        )
        lock.setReferenceCounted(false)
        lock.acquire(WAKE_HOLD_MS)
    }

    private fun resetAttempt() {
        attemptStart = 0L
        covers = 0
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
