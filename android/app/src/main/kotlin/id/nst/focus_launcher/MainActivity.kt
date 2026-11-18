package id.nst.focus_launcher

import android.Manifest
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // FlutterActivity looks the cached engine up in onCreate, so it must exist first.
        FluteEngine.get(this)
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineId(): String = FluteEngine.ENGINE_ID

    // The engine outlives this activity: the lockscreen shares it.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    // While the lockscreen has the engine, this activity must not push lifecycle changes into it:
    // a late "paused" from here would freeze the lock UI (frames stop when the app is paused).
    override fun shouldDispatchAppLifecycleState(): Boolean = FluteSurface.current != FluteSurface.LOCK

    override fun onStart() {
        super.onStart()
        visible.set(true)
        started = WeakReference(this)
    }

    override fun onStop() {
        visible.set(false)
        if (started?.get() === this) started = null
        super.onStop()
    }

    override fun onDestroy() {
        // A permission dialog cannot answer a destroyed activity; settle its pending reply.
        LocationAccess.abandonPermissionRequest()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        FluteSurface.set(FluteSurface.HOME)
    }

    // Keeps FlutterActivity's plugin dispatch; the coarse-location answer is ours.
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == LocationAccess.REQUEST_CODE) LocationAccess.onPermissionResult(grantResults)
    }

    // singleTask: pressing Home while Flute is already running lands here.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.isHomeIntent()) {
            FluteEvents.emit(mapOf("type" to "homePressed"))
        }
    }

    companion object {
        /** True between onStart and onStop. The lockscreen launch paths refuse while it is set. */
        private val visible = AtomicBoolean(false)

        /** The started launcher, weakly held so it can show a permission dialog. Null when stopped. */
        @Volatile
        private var started: WeakReference<MainActivity>? = null

        fun isVisible(): Boolean = visible.get()

        /**
         * Shows the system dialog for coarse location from the started launcher. Main thread only.
         * False when no launcher is started, so no dialog can be shown.
         */
        fun requestCoarseLocation(): Boolean {
            val activity = started?.get() ?: return false
            activity.requestPermissions(
                arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION),
                LocationAccess.REQUEST_CODE,
            )
            return true
        }
    }
}
