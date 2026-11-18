package id.nst.focus_launcher

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Routine alarms, the "Run again" notification action, and the events that change when alarms
 * must be armed again. Finishes at once: the run itself happens in Dart on the shared engine.
 */
class RoutineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(RoutineScheduler.EXTRA_ID)
        when (intent.action) {
            RoutineScheduler.ACTION_FIRE -> if (id != null) RoutineScheduler.onAlarm(context, id)
            RoutineScheduler.ACTION_RUN_NOW -> if (id != null) RoutineScheduler.onRunNow(context, id)
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
            -> RoutineScheduler.rescheduleAll(context)
        }
    }
}
