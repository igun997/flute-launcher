package id.nst.focus_launcher

import android.content.Context
import android.content.pm.LauncherApps
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Process
import java.io.ByteArrayOutputStream
import kotlin.math.roundToInt

/** Launcher icons as square PNGs for the Dart pins. Call only from a worker thread. */
object AppIcons {
    const val MAX_PACKAGES = 64
    private const val MIN_PX = 16
    private const val MAX_PX = 512
    private const val PNG_QUALITY = 100

    /** PNG bytes per package. Packages whose icon cannot be read are left out. */
    fun render(context: Context, packages: List<String>, size: Int): Map<String, ByteArray> {
        val px = size.coerceIn(MIN_PX, MAX_PX)
        val icons = HashMap<String, ByteArray>()
        for (pkg in packages.distinct().take(MAX_PACKAGES)) {
            try {
                icons[pkg] = pngOf(context, pkg, px)
            } catch (e: Exception) {
                // Skipped on purpose: one missing icon must not fail the whole batch.
            }
        }
        return icons
    }

    private fun pngOf(context: Context, pkg: String, px: Int): ByteArray {
        val drawable = iconOf(context, pkg)
        val bitmap = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        try {
            // Fit inside the square, keeping the aspect ratio. Adaptive icons are square, so
            // their background and foreground layers fill the whole tile.
            val w = drawable.intrinsicWidth.takeIf { it > 0 } ?: px
            val h = drawable.intrinsicHeight.takeIf { it > 0 } ?: px
            val scale = minOf(px.toFloat() / w, px.toFloat() / h)
            val fitW = (w * scale).roundToInt().coerceIn(1, px)
            val fitH = (h * scale).roundToInt().coerceIn(1, px)
            val left = (px - fitW) / 2
            val top = (px - fitH) / 2
            drawable.setBounds(left, top, left + fitW, top + fitH)
            drawable.draw(Canvas(bitmap))
            val out = ByteArrayOutputStream()
            check(bitmap.compress(Bitmap.CompressFormat.PNG, PNG_QUALITY, out)) { "png encode failed" }
            return out.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    /** The launcher activity's icon (adaptive icons included), else the application icon. */
    private fun iconOf(context: Context, pkg: String): Drawable {
        val launcherApps = context.getSystemService(LauncherApps::class.java)
        val density = context.resources.displayMetrics.densityDpi
        val launcherIcon = launcherApps
            ?.getActivityList(pkg, Process.myUserHandle())
            ?.firstOrNull()
            ?.getIcon(density)
        return launcherIcon ?: context.packageManager.getApplicationIcon(pkg)
    }
}
