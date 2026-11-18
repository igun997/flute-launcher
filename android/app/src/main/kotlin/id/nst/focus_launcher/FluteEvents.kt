package id.nst.focus_launcher

import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** The single `flute/events` sink, shared by the activities and the notification listener. */
object FluteEvents : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Delivered on the main thread. Dropped when no Dart listener is attached. */
    fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }
}

/**
 * Which activity the shared engine is serving: [LOCK] over the keyguard, otherwise [HOME].
 * Changes are pushed to Dart as `{type: surface, surface: ...}`; Dart can also read [current].
 */
object FluteSurface {
    const val HOME = "home"
    const val LOCK = "lock"

    @Volatile
    var current: String = HOME
        private set

    /** Main thread only. */
    fun set(surface: String) {
        current = surface
        FluteEvents.emit(mapOf("type" to "surface", "surface" to surface))
    }
}

internal fun Intent.isHomeIntent(): Boolean =
    action == Intent.ACTION_MAIN && hasCategory(Intent.CATEGORY_HOME)
