package com.smartledger.smart_ledger

import android.Manifest
import android.app.AlarmManager
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
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** OS-backed recurring-plan wake-up. It runs even when the UI process was gone. */
object RecurringScheduler {
    const val CHANNEL = "smart_ledger/recurring"
    private const val PREFS = "recurring_scheduler"
    private const val NEXT_AT = "next_at"
    private const val REQUEST = 64031
    private const val NOTIFICATION_CHANNEL = "recurring_plans"
    private const val NOTIFICATION_ID = 64032
    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var pending: BroadcastReceiver.PendingResult? = null
    private var timeout: Runnable? = null

    fun bind(context: Context, flutterEngine: FlutterEngine, foreground: Boolean): MethodChannel {
        val app = context.applicationContext
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "schedule" -> {
                        check(foreground)
                        val at = call.argument<Number>("at")?.toLong() ?: error("at")
                        schedule(app, at)
                        result.success(null)
                    }
                    "cancel" -> {
                        check(foreground)
                        cancel(app)
                        result.success(null)
                    }
                    "finish" -> {
                        check(!foreground)
                        val ok = call.argument<Boolean>("ok") == true
                        val succeeded = call.argument<Number>("succeeded")?.toInt() ?: 0
                        val failed = call.argument<Number>("failed")?.toInt() ?: 0
                        val next = call.argument<Number>("nextAt")?.toLong()
                        if (next == null) cancel(app) else schedule(app, next)
                        if (succeeded > 0 || failed > 0) notifyResult(app, succeeded, failed)
                        result.success(null)
                        handler.post { stop() }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Throwable) {
                result.error("recurring", "周期计划后台调度失败", null)
            }
        }
        return channel
    }

    fun schedule(context: Context, epochMillis: Long) {
        require(epochMillis > 0)
        val app = context.applicationContext
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(NEXT_AT, epochMillis).apply()
        val at = maxOf(epochMillis, System.currentTimeMillis() + 5_000L)
        val alarm = app.getSystemService(AlarmManager::class.java)
        alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, alarmIntent(app))
    }

    fun cancel(context: Context) {
        val app = context.applicationContext
        app.getSystemService(AlarmManager::class.java).cancel(alarmIntent(app))
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(NEXT_AT).apply()
    }

    fun restore(context: Context) {
        val next = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(NEXT_AT, 0L)
        if (next > 0) schedule(context, next)
    }

    fun start(context: Context, completion: BroadcastReceiver.PendingResult) {
        val app = context.applicationContext
        handler.post { startOnMain(app, completion) }
    }

    @Synchronized
    private fun startOnMain(context: Context, completion: BroadcastReceiver.PendingResult) {
        if (engine != null) {
            completion.finish()
            return
        }
        try {
            pending = completion
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
            val worker = FlutterEngine(context)
            engine = worker
            bind(context, worker, false)
            worker.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "recurringPlanWorker"),
            )
            timeout = Runnable {
                schedule(context, System.currentTimeMillis() + 15 * 60_000L)
                notifyResult(context, 0, 1)
                stop()
            }
            handler.postDelayed(timeout!!, 120_000L)
        } catch (_: Throwable) {
            schedule(context, System.currentTimeMillis() + 15 * 60_000L)
            notifyResult(context, 0, 1)
            stop()
        }
    }

    @Synchronized
    private fun stop() {
        timeout?.let(handler::removeCallbacks)
        timeout = null
        engine?.destroy()
        engine = null
        pending?.finish()
        pending = null
    }

    private fun alarmIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST,
        Intent(context, RecurringAlarmReceiver::class.java),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun notifyResult(context: Context, succeeded: Int, failed: Int) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "周期计划提醒",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = "周期账单执行结果与失败重试提醒" },
            )
        }
        val intent = PendingIntent.getActivity(
            context,
            REQUEST + 1,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = when {
            failed > 0 && succeeded > 0 -> "已生成 $succeeded 笔，$failed 个计划失败并将在稍后重试"
            failed > 0 -> "$failed 个周期计划执行失败，将自动重试"
            else -> "已按计划生成 $succeeded 笔账单"
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(context)
        }
        manager.notify(
            NOTIFICATION_ID,
            builder.setSmallIcon(R.drawable.ic_capture)
                .setContentTitle("知账周期计划")
                .setContentText(text)
                .setContentIntent(intent)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_REMINDER)
                .build(),
        )
    }
}

class RecurringAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        RecurringScheduler.start(context, goAsync())
    }
}
