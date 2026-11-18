package id.nst.focus_launcher

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restarts the soft lock after a reboot, from the persisted [LockSettings]. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        LockService.sync(context, LockConfigStore.load(context))
    }
}
