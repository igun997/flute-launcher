package id.nst.focus_launcher

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Address
import android.location.Geocoder
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Coarse, one-shot location for the weather: the permission, one fix, and reverse geocoding.
 * Nothing here logs coordinates or addresses. Every reply is delivered on the main thread, once.
 */
object LocationAccess {
    /** Request code for the coarse-location dialog shown by [MainActivity]. */
    const val REQUEST_CODE = 4711

    private const val FIX_TIMEOUT_MS = 8_000L

    private val main = Handler(Looper.getMainLooper())
    private val locationExecutor = Executors.newSingleThreadExecutor()
    private val geocodeExecutor = Executors.newSingleThreadExecutor()

    /** Main thread only: the reply owed for the permission dialog currently on screen. */
    private var pendingPermission: MethodChannel.Result? = null

    fun hasPermission(context: Context): Boolean =
        context.checkPermission(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Process.myPid(),
            Process.myUid(),
        ) == PackageManager.PERMISSION_GRANTED

    /**
     * Main thread only. Replies at once when granted, or when no request can be shown. Otherwise
     * the reply comes from [onPermissionResult] or [abandonPermissionRequest].
     */
    fun requestPermission(context: Context, result: MethodChannel.Result) {
        if (hasPermission(context)) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        val shown = try {
            MainActivity.requestCoarseLocation()
        } catch (e: RuntimeException) {
            false
        }
        if (!shown) {
            pendingPermission = null
            result.success(false)
        }
    }

    /** Main thread only, from [MainActivity.onRequestPermissionsResult]. */
    fun onPermissionResult(grantResults: IntArray) {
        val result = pendingPermission ?: return
        pendingPermission = null
        result.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
    }

    /** Main thread only, from [MainActivity.onDestroy]: a dialog answer will never arrive now. */
    fun abandonPermissionRequest() {
        val result = pendingPermission ?: return
        pendingPermission = null
        result.success(false)
    }

    /**
     * Main thread only. Replies with `{latitude, longitude}` or null (no permission, or no fix).
     * Never blocks the main thread.
     */
    fun currentLocation(context: Context, reply: (Map<String, Double>?) -> Unit) {
        val lm = context.getSystemService(LocationManager::class.java)
        if (lm == null || !hasPermission(context)) {
            reply(null)
            return
        }
        OneShotFix(lm, reply).start()
    }

    /**
     * Main thread only. Replies with `{name, admin, country}` or null. [name] is the locality, else
     * the sub-admin area, else the admin area. Null when there is no Geocoder backend or on failure.
     */
    @Suppress("DEPRECATION")
    fun reverseGeocode(
        context: Context,
        latitude: Double,
        longitude: Double,
        reply: (Map<String, String>?) -> Unit,
    ) {
        if (!Geocoder.isPresent()) {
            reply(null)
            return
        }
        val answer: (Address?) -> Unit = { address ->
            val place = address?.toPlace()
            main.post { reply(place) }
        }
        try {
            val geocoder = Geocoder(context, Locale.getDefault())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                geocoder.getFromLocation(latitude, longitude, 1, object : Geocoder.GeocodeListener {
                    override fun onGeocode(addresses: MutableList<Address>) {
                        answer(addresses.firstOrNull())
                    }

                    override fun onError(errorMessage: String?) {
                        answer(null)
                    }
                })
            } else {
                geocodeExecutor.execute {
                    val first = try {
                        geocoder.getFromLocation(latitude, longitude, 1)?.firstOrNull()
                    } catch (e: Exception) {
                        null
                    }
                    answer(first)
                }
            }
        } catch (e: RuntimeException) {
            // Invalid coordinates or no service: nothing about the point reaches the log.
            answer(null)
        }
    }

    private fun Address.toPlace(): Map<String, String>? {
        val name = locality.orNullIfBlank()
            ?: subAdminArea.orNullIfBlank()
            ?: adminArea.orNullIfBlank()
            ?: return null
        return mapOf(
            "name" to name,
            "admin" to (adminArea.orNullIfBlank() ?: ""),
            "country" to (countryName.orNullIfBlank() ?: ""),
        )
    }

    private fun String?.orNullIfBlank(): String? = this?.takeIf { it.isNotBlank() }

    /**
     * One fix request. Settles exactly once: with a fresh fix, else the newest last-known fix, or null.
     * On API 30+ a fresh fix is requested from the network provider (or fused, API 31+) and given up
     * after [FIX_TIMEOUT_MS]. Below API 30 only the last-known fix is used.
     */
    @SuppressLint("MissingPermission")
    private class OneShotFix(
        private val lm: LocationManager,
        private val reply: (Map<String, Double>?) -> Unit,
    ) {
        private val settled = AtomicBoolean(false)
        private val signal = CancellationSignal()
        private val timeout = Runnable {
            signal.cancel()
            fallBackToLastKnown()
        }

        /** Main thread only. */
        fun start() {
            val provider = freshProvider()
            if (provider == null) {
                fallBackToLastKnown()
                return
            }
            main.postDelayed(timeout, FIX_TIMEOUT_MS)
            try {
                lm.getCurrentLocation(provider, signal, locationExecutor) { fix ->
                    // Runs on locationExecutor. A null fix falls back to the last known one.
                    deliver(fix ?: lastKnown())
                }
            } catch (e: RuntimeException) {
                main.removeCallbacks(timeout)
                signal.cancel()
                fallBackToLastKnown()
            }
        }

        private fun freshProvider(): String? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
            val candidates = buildList {
                add(LocationManager.NETWORK_PROVIDER)
                // Fused takes coarse permission only; GPS would need the fine permission.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(LocationManager.FUSED_PROVIDER)
            }
            return candidates.firstOrNull { lm.isProviderEnabled(it) }
        }

        private fun fallBackToLastKnown() {
            locationExecutor.execute { deliver(lastKnown()) }
        }

        /** Newest last-known fix across every enabled provider, passive included. */
        private fun lastKnown(): Location? = try {
            lm.getProviders(true)
                .mapNotNull { lm.getLastKnownLocation(it) }
                .maxByOrNull { it.time }
        } catch (e: RuntimeException) {
            null
        }

        /** Any thread. The first call wins; the reply is posted to the main thread. */
        private fun deliver(fix: Location?) {
            if (!settled.compareAndSet(false, true)) return
            main.removeCallbacks(timeout)
            val coordinates = fix?.let { mapOf("latitude" to it.latitude, "longitude" to it.longitude) }
            main.post { reply(coordinates) }
        }
    }
}
