package com.smartledger.smart_ledger

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import java.util.Locale

/** User-configured, local-only notification shortcuts. */
object ShortcutNotification {
    const val CHANNEL = "smart_ledger/shortcuts"
    const val EXTRA_ACTION = "shortcutAction"
    private const val PREFS = "notification_shortcuts"
    private const val KEY_ACTIONS = "actions"
    private const val KEY_TODAY = "todayExpenseMinor"
    private const val KEY_LEDGER = "ledgerId"
    private const val NOTIFICATION_ID = 20301
    private const val CAPTURE_FAILURE_ID = 20302
    val allowed = listOf("capture", "quick", "voice", "today")

    fun sanitize(source: Iterable<String>): List<String> = source
        .filter { it in allowed }
        .distinct()
        .take(3)

    fun actions(context: Context): List<String> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_ACTIONS, "") ?: ""
        return sanitize(raw.split(',').filter { it.isNotBlank() })
    }

    fun configure(context: Context, requested: Iterable<String>, todayMinor: Long, ledgerId: String) {
        val selected = sanitize(requested)
        require(ledgerId.length in 1..100)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_ACTIONS, selected.joinToString(","))
            .putLong(KEY_TODAY, todayMinor.coerceAtLeast(0))
            .putString(KEY_LEDGER, ledgerId)
            .apply()
        refresh(context)
    }

    fun updateToday(context: Context, todayMinor: Long, ledgerId: String) {
        require(ledgerId.length in 1..100)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(KEY_TODAY, todayMinor.coerceAtLeast(0)).putString(KEY_LEDGER, ledgerId).apply()
        refresh(context)
    }

    fun ledgerId(context: Context): String = context
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getString(KEY_LEDGER, "personal")
        ?.takeIf { it.length in 1..100 } ?: "personal"

    fun granted(context: Context): Boolean = Build.VERSION.SDK_INT < 33 ||
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun refresh(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val selected = actions(context)
        if (selected.isEmpty() || !granted(context)) {
            manager.cancel(NOTIFICATION_ID)
            return
        }
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "快捷记账", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "显示你选择的本地记账快捷入口"
                    setShowBadge(false)
                },
            )
        }
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val today = prefs.getLong(KEY_TODAY, 0)
        val notification = (if (Build.VERSION.SDK_INT >= 26)
            Notification.Builder(context, CHANNEL)
        else @Suppress("DEPRECATION") Notification.Builder(context))
            .setSmallIcon(R.drawable.ic_capture)
            .setContentTitle("知账快捷记账")
            .setContentText("今日消费 ${money(today)} · 点击按钮快速记一笔")
            .setContentIntent(mainIntent(context, null, 500))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
        selected.forEachIndexed { index, action ->
            val (label, intent) = when (action) {
                "capture" -> "截图识别" to PendingIntent.getActivity(
                    context,
                    510 + index,
                    Intent(context, CaptureActivity::class.java)
                        .addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS,
                    ),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                "voice" -> "语音记账" to mainIntent(context, action, 520 + index)
                "today" -> "今日消费" to mainIntent(context, action, 530 + index)
                else -> "快捷记账" to mainIntent(context, "quick", 540 + index)
            }
            notification.addAction(Notification.Action.Builder(R.drawable.ic_capture, label, intent).build())
        }
        manager.notify(NOTIFICATION_ID, notification.build())
    }

    fun clearCaptureFailure(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(CAPTURE_FAILURE_ID)
    }

    fun notifyCaptureFailure(context: Context, message: String) {
        clearCaptureFailure(context)
        showMessage(context, message)
    }

    /** Transient operation and permission feedback belongs on screen instead
     * of leaving another notification behind. */
    fun showMessage(context: Context, message: String, long: Boolean = true) {
        val app = context.applicationContext
        val show = Runnable {
            Toast.makeText(app, message, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()
        }
        if (Looper.myLooper() == Looper.getMainLooper()) show.run()
        else Handler(Looper.getMainLooper()).post(show)
    }

    private fun mainIntent(context: Context, action: String?, request: Int): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (action != null) intent.putExtra(EXTRA_ACTION, action)
        return PendingIntent.getActivity(
            context,
            request,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun money(minor: Long): String = String.format(
        Locale.CHINA,
        "¥%,d.%02d",
        minor / 100,
        minor % 100,
    )
}

class ShortcutBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            ShortcutNotification.refresh(context)
            HomeShortcuts.refresh(context)
            HomeShortcuts.updateWidgets(context)
            RecurringScheduler.restore(context)
        }
    }
}
