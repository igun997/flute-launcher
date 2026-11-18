package id.nst.focus_launcher

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/**
 * The one FlutterEngine shared by [MainActivity] (home) and [LockscreenActivity] (lock).
 * Created lazily; the native channel handlers are registered exactly once, here.
 */
object FluteEngine {
    const val ENGINE_ID = "flute"

    /** Returns the cached engine, creating it on first use. Call on the main thread. */
    fun get(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        // Handlers go up before the Dart entrypoint runs, so early calls from Dart are answered.
        FluteNative(appContext).register(engine.dartExecutor.binaryMessenger)
        RoutineNative(appContext).register(engine.dartExecutor.binaryMessenger)
        VoiceNative.register(engine.dartExecutor.binaryMessenger, appContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }
}
