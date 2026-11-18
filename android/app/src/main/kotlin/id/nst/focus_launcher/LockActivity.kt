package id.nst.focus_launcher

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.CountDownTimer
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher

/**
 * Pause screen shown over a locked app. Translucent, excluded from Recents.
 * "Go back" sends the user Home. "Open anyway" unlocks after the countdown and grants
 * the package a grace period.
 */
class LockActivity : Activity() {
    private var targetPackage: String = ""
    private var graceMinutes = DEFAULT_GRACE_MINUTES
    private var countdownView: TextView? = null
    private var openAnywayView: TextView? = null
    private var timer: CountDownTimer? = null
    private var backCallback: OnBackInvokedCallback? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pkg = intent.getStringExtra(EXTRA_PACKAGE)
        if (pkg.isNullOrEmpty()) {
            finish()
            return
        }
        targetPackage = pkg
        graceMinutes = intent.getIntExtra(EXTRA_GRACE_MINUTES, DEFAULT_GRACE_MINUTES).coerceAtLeast(1)
        val pauseSeconds = intent.getIntExtra(EXTRA_PAUSE_SECONDS, DEFAULT_PAUSE_SECONDS).coerceAtLeast(0)
        setContentView(buildContent(appLabel(pkg)))
        registerBack()
        startCountdown(pauseSeconds)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        goHome()
    }

    override fun onStop() {
        super.onStop()
        // Home or screen-off ends the pause. The app is locked again when it comes back.
        if (!isFinishing) finish()
    }

    override fun onDestroy() {
        timer?.cancel()
        backCallback?.let { onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it) }
        if (targetPackage.isNotEmpty()) {
            LockState.block(targetPackage, System.currentTimeMillis() + RELAUNCH_SUPPRESS_MS)
        }
        super.onDestroy()
    }

    private fun buildContent(label: String): View {
        val title = TextView(this).apply {
            text = label
            textSize = 26f
            setTextColor(TEXT_PRIMARY)
            gravity = Gravity.CENTER
        }
        val subtitle = TextView(this).apply {
            text = getString(R.string.lock_subtitle)
            textSize = 15f
            setTextColor(TEXT_MUTED)
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, dp(40))
        }
        val countdown = TextView(this).apply {
            textSize = 64f
            setTextColor(TEXT_PRIMARY)
            gravity = Gravity.CENTER
        }
        countdownView = countdown
        val goBack = pill(getString(R.string.lock_go_back), filled = true) { goHome() }
        val openAnyway = pill(getString(R.string.lock_open_anyway), filled = false) { openAnyway() }
        openAnyway.isEnabled = false
        openAnyway.alpha = DISABLED_ALPHA
        openAnywayView = openAnyway

        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(BACKGROUND)
            setPadding(dp(32), dp(32), dp(32), dp(32))
            addView(title)
            addView(subtitle)
            addView(countdown)
            addView(goBack)
            addView(openAnyway)
        }
    }

    private fun pill(label: String, filled: Boolean, onClick: () -> Unit): TextView = TextView(this).apply {
        text = label
        textSize = 16f
        gravity = Gravity.CENTER
        setTextColor(if (filled) BACKGROUND else TEXT_PRIMARY)
        background = GradientDrawable().apply {
            cornerRadius = dp(28).toFloat()
            setColor(if (filled) TEXT_PRIMARY else SUBTLE_FILL)
        }
        setPadding(dp(24), dp(16), dp(24), dp(16))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dp(12) }
        setOnClickListener { onClick() }
    }

    private fun startCountdown(seconds: Int) {
        if (seconds <= 0) {
            showReady()
            return
        }
        countdownView?.text = seconds.toString()
        val countdown = object : CountDownTimer(seconds * 1000L, 1000L) {
            override fun onTick(millisUntilFinished: Long) {
                countdownView?.text = ((millisUntilFinished + 999L) / 1000L).toString()
            }

            override fun onFinish() {
                showReady()
            }
        }
        timer = countdown
        countdown.start()
    }

    private fun showReady() {
        countdownView?.text = "0"
        openAnywayView?.let {
            it.isEnabled = true
            it.alpha = 1f
        }
    }

    private fun goHome() {
        val home = Intent(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_HOME)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(home)
        } catch (e: ActivityNotFoundException) {
            // No home app available: closing the pause screen is all that is left.
        }
        finish()
    }

    private fun openAnyway() {
        LockState.block(targetPackage, System.currentTimeMillis() + graceMinutes * 60_000L)
        finish()
    }

    private fun registerBack() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val callback = OnBackInvokedCallback { goHome() }
        backCallback = callback
        onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
    }

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (e: PackageManager.NameNotFoundException) {
        pkg
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val EXTRA_PACKAGE = "id.nst.focus_launcher.extra.PACKAGE"
        const val EXTRA_PAUSE_SECONDS = "id.nst.focus_launcher.extra.PAUSE_SECONDS"
        const val EXTRA_GRACE_MINUTES = "id.nst.focus_launcher.extra.GRACE_MINUTES"

        private const val DEFAULT_PAUSE_SECONDS = 10
        private const val DEFAULT_GRACE_MINUTES = 5
        private const val RELAUNCH_SUPPRESS_MS = 1_500L
        private const val DISABLED_ALPHA = 0.35f

        private val BACKGROUND = 0xFA101012.toInt()
        private val TEXT_PRIMARY = 0xFFEDEDF0.toInt()
        private val TEXT_MUTED = 0xFF9A9AA3.toInt()
        private val SUBTLE_FILL = 0x22FFFFFF
    }
}
