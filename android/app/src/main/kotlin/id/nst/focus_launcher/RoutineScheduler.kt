package id.nst.focus_launcher

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.UUID

/**
 * The routine schedule lives here so it fires while the app is closed, after a reboot and after
 * a package update. Dart pushes the full list with [sync] (each entry carries the next fire time
 * it computed); after a fire, the next time is computed here from the same rules.
 *
 * A fire is queued in [PREFS] until Dart acknowledges it, then the shared Flutter engine is
 * started (no activity) and Dart runs the routine. A partial wake lock covers the run; Dart
 * releases it with [release], and the lock also expires on its own after [WAKE_BUDGET_MS].
 *
 * Main thread only: callers are the method channel, the receivers and the boot hook.
 */
object RoutineScheduler {
    const val ACTION_FIRE = "id.nst.focus_launcher.ROUTINE_FIRE"
    const val ACTION_RUN_NOW = "id.nst.focus_launcher.ROUTINE_RUN_NOW"
    const val EXTRA_ID = "routine_id"

    private const val TAG = "RoutineScheduler"
    private const val PREFS = "flute_routines"
    private const val KEY_SPECS = "specs"
    private const val KEY_PENDING = "pending"
    private const val MINUTE_MS = 60_000L

    /** Dart's run budget (3 min) plus a margin. The lock is released earlier when Dart finishes. */
    private const val WAKE_BUDGET_MS = 3 * 60_000L + 30_000L

    private val wakeLocks = HashMap<String, PowerManager.WakeLock>()

    /** One routine as Dart describes it. [nextAtMs] is null when the routine is not scheduled. */
    data class Spec(
        val id: String,
        val trigger: String,
        val minuteOfDay: Int,
        val weekdays: Set<Int>,
        val everyMinutes: Int,
        val enabled: Boolean,
        val nextAtMs: Long?,
    )

    fun canScheduleExact(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return alarms(context).canScheduleExactAlarms()
    }

    /** Replaces the whole schedule with [items]: routines no longer listed or disabled are cancelled. */
    fun sync(context: Context, items: List<Spec>) {
        val previous = loadSpecs(context)
        val wanted = items.filter { it.enabled && it.nextAtMs != null }
        for (id in previous.keys - wanted.map { it.id }.toSet()) cancelAlarm(context, id)
        for (id in items.map { it.id }.toSet() - wanted.map { it.id }.toSet()) cancelAlarm(context, id)
        for (spec in wanted) arm(context, spec.id, spec.nextAtMs!!)
        saveSpecs(context, wanted.associateBy { it.id })
    }

    /** Boot, time zone change, package replace and exact-alarm permission change. */
    fun rescheduleAll(context: Context) {
        val now = System.currentTimeMillis()
        val specs = loadSpecs(context)
        for (spec in specs.values.toList()) {
            val at = spec.nextAtMs ?: continue
            val next = if (at <= now) nextAfter(spec, now) else at
            specs[spec.id] = spec.copy(nextAtMs = next)
            arm(context, spec.id, next)
        }
        saveSpecs(context, specs)
    }

    /** The alarm for a scheduled routine went off. Queues the fire and arms the next one. */
    fun onAlarm(context: Context, id: String) {
        val specs = loadSpecs(context)
        val spec = specs[id] ?: return
        if (!spec.enabled) return
        val now = System.currentTimeMillis()
        val next = nextAfter(spec, now)
        specs[id] = spec.copy(nextAtMs = next)
        saveSpecs(context, specs)
        arm(context, id, next)
        queueFire(context, id, now, manual = false)
    }

    /** "Run again" from a notification: a fire without touching the schedule. */
    fun onRunNow(context: Context, id: String) {
        queueFire(context, id, System.currentTimeMillis(), manual = true)
    }

    /** Pending fires Dart has not acknowledged yet. */
    fun pendingFires(context: Context): List<Map<String, Any>> {
        val array = loadPending(context)
        return (0 until array.length()).map { i ->
            val o = array.getJSONObject(i)
            mapOf(
                "token" to o.getString("token"),
                "routineId" to o.getString("routineId"),
                "firedAtMs" to o.getLong("firedAtMs"),
                "manual" to o.getBoolean("manual"),
            )
        }
    }

    fun ackFire(context: Context, token: String) {
        val array = loadPending(context)
        val kept = JSONArray()
        for (i in 0 until array.length()) {
            val o = array.getJSONObject(i)
            if (o.getString("token") != token) kept.put(o)
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_PENDING, kept.toString()).apply()
    }

    /** Dart finished a run (or gave up on it): the wake lock is no longer needed. */
    fun release(token: String) {
        val lock = wakeLocks.remove(token) ?: return
        if (lock.isHeld) lock.release()
    }

    private fun queueFire(context: Context, id: String, firedAt: Long, manual: Boolean) {
        val token = UUID.randomUUID().toString()
        val array = loadPending(context)
        array.put(
            JSONObject()
                .put("token", token)
                .put("routineId", id)
                .put("firedAtMs", firedAt)
                .put("manual", manual),
        )
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_PENDING, array.toString()).apply()
        acquireWakeLock(context, token)
        try {
            // The shared engine runs Dart's main() without any activity. Dart drains the queue.
            FluteEngine.get(context)
        } catch (e: Exception) {
            // Class name only: ids and prompts must not reach logs.
            Log.w(TAG, "engine did not start (${e.javaClass.simpleName})")
        }
        RoutineNative.emitFire(
            mapOf(
                "token" to token,
                "routineId" to id,
                "firedAtMs" to firedAt,
                "manual" to manual,
            ),
        )
    }

    private fun acquireWakeLock(context: Context, token: String) {
        val power = context.getSystemService(PowerManager::class.java) ?: return
        val lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "flute:routine")
        lock.setReferenceCounted(false)
        lock.acquire(WAKE_BUDGET_MS)
        wakeLocks[token] = lock
    }

    private fun arm(context: Context, id: String, atMs: Long) {
        val manager = alarms(context)
        val pending = alarmIntent(context, id)
        val exact = Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager.canScheduleExactAlarms()
        try {
            if (exact) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
            } else {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
            }
        } catch (e: SecurityException) {
            // Exact alarms revoked between the check and the call: a late fire beats no fire.
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending)
        }
    }

    private fun cancelAlarm(context: Context, id: String) {
        val existing = PendingIntent.getBroadcast(
            context,
            requestCode(id),
            alarmIntentFor(context, id),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        ) ?: return
        alarms(context).cancel(existing)
        existing.cancel()
    }

    private fun alarmIntent(context: Context, id: String): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            requestCode(id),
            alarmIntentFor(context, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun alarmIntentFor(context: Context, id: String): Intent =
        Intent(context, RoutineReceiver::class.java)
            .setAction(ACTION_FIRE)
            .setData(Uri.parse("flute-routine://$id"))
            .putExtra(EXTRA_ID, id)

    private fun requestCode(id: String): Int = id.hashCode() and 0x7fffffff

    private fun alarms(context: Context): AlarmManager =
        context.getSystemService(AlarmManager::class.java)

    /**
     * The first fire time strictly after [afterMs]. Interval: [afterMs] plus the interval. Daily
     * and weekly: local wall-clock time via [Calendar], so it is correct across DST changes too.
     */
    fun nextAfter(spec: Spec, afterMs: Long): Long {
        if (spec.trigger == "interval") return afterMs + spec.everyMinutes.coerceAtLeast(15) * MINUTE_MS
        val hour = spec.minuteOfDay / 60
        val minute = spec.minuteOfDay % 60
        if (spec.trigger == "weekly" && spec.weekdays.isEmpty()) return afterMs + 24 * 60 * MINUTE_MS
        for (offset in 0..8) {
            val candidate = Calendar.getInstance().apply {
                timeInMillis = afterMs
                add(Calendar.DAY_OF_MONTH, offset)
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            val at = candidate.timeInMillis
            if (at <= afterMs) continue
            if (spec.trigger == "daily" || spec.weekdays.contains(isoWeekday(candidate))) return at
        }
        return afterMs + 24 * 60 * MINUTE_MS
    }

    /** Monday = 1 ... Sunday = 7, like `DateTime.weekday` in Dart. */
    private fun isoWeekday(calendar: Calendar): Int {
        val day = calendar.get(Calendar.DAY_OF_WEEK)
        return if (day == Calendar.SUNDAY) 7 else day - 1
    }

    private fun loadSpecs(context: Context): MutableMap<String, Spec> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_SPECS, null)
            ?: return mutableMapOf()
        val out = LinkedHashMap<String, Spec>()
        val array = JSONArray(raw)
        for (i in 0 until array.length()) {
            val o = array.getJSONObject(i)
            val weekdays = o.getJSONArray("weekdays")
            val spec = Spec(
                id = o.getString("id"),
                trigger = o.getString("trigger"),
                minuteOfDay = o.getInt("minuteOfDay"),
                weekdays = (0 until weekdays.length()).map { weekdays.getInt(it) }.toSet(),
                everyMinutes = o.getInt("everyMinutes"),
                enabled = o.getBoolean("enabled"),
                nextAtMs = if (o.isNull("nextAtMs")) null else o.getLong("nextAtMs"),
            )
            out[spec.id] = spec
        }
        return out.toMutableMap()
    }

    private fun saveSpecs(context: Context, specs: Map<String, Spec>) {
        val array = JSONArray()
        for (spec in specs.values) {
            array.put(
                JSONObject()
                    .put("id", spec.id)
                    .put("trigger", spec.trigger)
                    .put("minuteOfDay", spec.minuteOfDay)
                    .put("weekdays", JSONArray(spec.weekdays.sorted()))
                    .put("everyMinutes", spec.everyMinutes)
                    .put("enabled", spec.enabled)
                    .put("nextAtMs", spec.nextAtMs ?: JSONObject.NULL),
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_SPECS, array.toString()).apply()
    }

    private fun loadPending(context: Context): JSONArray {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_PENDING, null)
            ?: return JSONArray()
        return try {
            JSONArray(raw)
        } catch (e: Exception) {
            JSONArray()
        }
    }
}
