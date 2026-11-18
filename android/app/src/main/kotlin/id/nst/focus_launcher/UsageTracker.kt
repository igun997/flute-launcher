package id.nst.focus_launcher

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import java.util.Calendar

/**
 * Today's foreground time per package, from `queryEvents` resume/pause pairs between
 * local midnight and now.
 *
 * Chosen over `queryUsageStats(INTERVAL_DAILY)`: daily buckets are aggregated by the
 * system, can lag behind the current day, and split time across the midnight boundary
 * unpredictably. Event pairs give exact times that we can clip to the window.
 */
object UsageTracker {
    class Total(val pkg: String, val foregroundMs: Long) {
        fun toMap(): Map<String, Any?> = mapOf("package" to pkg, "foregroundMs" to foregroundMs)
    }

    fun todayTotals(context: Context, now: Long = System.currentTimeMillis()): List<Total> {
        if (!Permissions.hasUsageAccess(context)) return emptyList()
        val usageStats = context.getSystemService(UsageStatsManager::class.java) ?: return emptyList()
        val start = startOfToday(now)
        val events = usageStats.queryEvents(start, now) ?: return emptyList()

        val totals = HashMap<String, Long>()
        val resumedInWindow = HashSet<String>()
        val event = UsageEvents.Event()
        var current: String? = null
        var currentSince = start

        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            val pkg = event.packageName ?: continue
            val ts = event.timeStamp
            when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> {
                    resumedInWindow += pkg
                    if (current != pkg) {
                        current?.let { add(totals, it, ts - currentSince) }
                        current = pkg
                        currentSince = ts
                    }
                }
                UsageEvents.Event.ACTIVITY_PAUSED -> {
                    if (current == pkg) {
                        add(totals, pkg, ts - currentSince)
                        current = null
                    } else if (current == null && pkg !in resumedInWindow) {
                        // Already in the foreground before midnight: count from the window start.
                        add(totals, pkg, ts - start)
                    }
                }
                UsageEvents.Event.SCREEN_NON_INTERACTIVE -> {
                    current?.let { add(totals, it, ts - currentSince) }
                    current = null
                }
            }
        }
        current?.let { add(totals, it, now - currentSince) }

        return totals
            .filter { it.value > 0 }
            .map { Total(it.key, it.value) }
            .sortedByDescending { it.foregroundMs }
    }

    private fun add(totals: MutableMap<String, Long>, pkg: String, ms: Long) {
        if (ms > 0) totals[pkg] = (totals[pkg] ?: 0L) + ms
    }

    private fun startOfToday(now: Long): Long = Calendar.getInstance().run {
        timeInMillis = now
        set(Calendar.HOUR_OF_DAY, 0)
        set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
        timeInMillis
    }
}
