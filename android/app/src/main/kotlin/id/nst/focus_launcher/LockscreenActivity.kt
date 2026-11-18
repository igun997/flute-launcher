package id.nst.focus_launcher

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flute's lockscreen: a Flutter surface shown over the keyguard, on the same engine as
 * [MainActivity]. Dart decides what to draw from the surface value it reads natively.
 * Excluded from Recents. Ends on Back, Home, screen off, or any unlock.
 */
class LockscreenActivity : FlutterActivity() {
    /** True while a keyguard dismissal prompt is up; the lock must survive that prompt. */
    private var dismissing = false
    private var userPresentRegistered = false
    /** Set when the launch was refused before the engine was touched; the activity only finishes. */
    private var refused = false

    private val userPresent = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // Unlocked by another route than dismissKeyguard: nothing left to guard.
            if (!isKeyguardLocked()) this@LockscreenActivity.finish()
        }
    }

    override fun getCachedEngineId(): String = FluteEngine.ENGINE_ID

    // The two activities share one engine, so only one of them may drive its lifecycle. This one
    // never reports pause or detach: when it closes, MainActivity resumes with the engine intact
    // (a late "paused" from here left the launcher black). It reports "resumed" itself below.
    override fun shouldDispatchAppLifecycleState(): Boolean = false

    override fun onResume() {
        super.onResume()
        // flutterEngine reads FlutterActivity's delegate, which a refused launch never creates.
        if (!refused) flutterEngine?.lifecycleChannel?.appIsResumed()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // MainActivity holds the shared engine while it is started. Attaching a second activity to
        // the engine crashes libflutter, so refuse before anything touches the engine. super.onCreate
        // is skipped on this path: FlutterActivity's lifecycle callbacks check their delegate and do
        // nothing without one, and the refused activity only finishes.
        if (MainActivity.isVisible()) {
            refused = true
            finish()
            return
        }
        // FlutterActivity looks the cached engine up in onCreate, so it must exist first.
        FluteEngine.get(this)
        super.onCreate(savedInstanceState)
        showing = WeakReference(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            // Only a launch from ACTION_SCREEN_ON wakes the device.
            setTurnScreenOn(intent.getBooleanExtra(EXTRA_TURN_SCREEN_ON, false))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            setInheritShowWhenLocked(true)
        }
        registerUserPresent()
        // super.onCreate attached the engine to this activity, so the surface is live now.
        FluteSurface.set(FluteSurface.LOCK)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        // Not forwarded to Dart: Back ends the lock.
        finish()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!dismissing) finish()
    }

    override fun onStop() {
        super.onStop()
        // Screen off or Home ends the lock; the listener shows a fresh one on the next screen-on.
        if (!dismissing && !isChangingConfigurations) finish()
    }

    override fun onDestroy() {
        unregisterUserPresent()
        if (showing?.get() === this) {
            showing = null
            FluteSurface.set(FluteSurface.HOME)
        }
        super.onDestroy()
    }

    private fun requestDismiss(onResult: (Boolean) -> Unit) {
        val replied = AtomicBoolean(false)
        fun reply(unlocked: Boolean) {
            if (!replied.compareAndSet(false, true)) return
            dismissing = false
            onResult(unlocked)
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            reply(false)
            return
        }
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard == null) {
            reply(false)
            return
        }
        dismissing = true
        try {
            keyguard.requestDismissKeyguard(
                this,
                object : KeyguardManager.KeyguardDismissCallback() {
                    override fun onDismissSucceeded() {
                        reply(true)
                        this@LockscreenActivity.finish()
                    }

                    override fun onDismissCancelled() = reply(false)

                    override fun onDismissError() = reply(false)
                },
            )
        } catch (e: Exception) {
            // Class name only: nothing from the device reaches the log.
            reply(false)
        }
    }

    private fun isKeyguardLocked(): Boolean =
        getSystemService(KeyguardManager::class.java)?.isKeyguardLocked == true

    private fun registerUserPresent() {
        val filter = IntentFilter(Intent.ACTION_USER_PRESENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(userPresent, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(userPresent, filter)
        }
        userPresentRegistered = true
    }

    private fun unregisterUserPresent() {
        if (!userPresentRegistered) return
        userPresentRegistered = false
        unregisterReceiver(userPresent)
    }

    companion object {
        const val EXTRA_TURN_SCREEN_ON = "id.nst.focus_launcher.turnScreenOn"

        /** Weak, so this registry can never keep a finished activity alive. */
        private var showing: WeakReference<LockscreenActivity>? = null

        private fun current(): LockscreenActivity? =
            showing?.get()?.takeUnless { it.isFinishing || it.isDestroyed }

        /** True while a lockscreen is up and not finishing. */
        fun isShowing(): Boolean = current() != null

        fun finishIfShowing() {
            current()?.finish()
        }

        /**
         * Asks the system to dismiss the keyguard (PIN or biometric prompt on secure devices).
         * [onResult] runs exactly once on the main thread: true once unlocked (the lockscreen
         * then finishes); false on cancel, error, or when no lockscreen is showing.
         */
        fun dismissKeyguard(onResult: (Boolean) -> Unit) {
            val activity = current()
            if (activity == null) {
                onResult(false)
            } else {
                activity.requestDismiss(onResult)
            }
        }
    }
}
