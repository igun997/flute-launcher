package id.nst.focus_launcher

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import java.lang.ref.WeakReference

/**
 * Accessibility service with no event types, no window content and no gestures. Its only job is
 * [AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN], which Flute calls for double-tap to lock.
 */
class FluteAccessibilityService : AccessibilityService() {
    override fun onServiceConnected() {
        super.onServiceConnected()
        connected = WeakReference(this)
    }

    // No event types are requested, so nothing is delivered here.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onUnbind(intent: Intent?): Boolean {
        clearIf(this)
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        clearIf(this)
        super.onDestroy()
    }

    companion object {
        /** Set in onServiceConnected; weak so the registry never keeps a dead service alive. */
        @Volatile
        private var connected: WeakReference<FluteAccessibilityService>? = null

        private fun clearIf(service: FluteAccessibilityService) {
            if (connected?.get() === service) connected = null
        }

        /** True when the user enabled this service in Settings and it is connected now. */
        fun isEnabled(context: Context): Boolean = isListedInSettings(context) && connected?.get() != null

        /** Locks the screen through the connected service. False when it is not connected. */
        fun lockScreen(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
            val service = connected?.get() ?: return false
            return service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)
        }

        private fun isListedInSettings(context: Context): Boolean {
            val me = ComponentName(context, FluteAccessibilityService::class.java)
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
        }
    }
}
