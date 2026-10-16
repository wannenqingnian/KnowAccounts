package com.smartledger.smart_ledger

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Build
import android.widget.RemoteViews

object HomeShortcuts {
    private const val PREFS = "desktop_shortcuts"
    private const val KEY_ACTIONS = "actions"
    val allowed = listOf("quick", "voice", "smart", "capture", "templates", "recurring")

    private val labels = mapOf(
        "quick" to "手动记账",
        "voice" to "语音记账",
        "smart" to "一句话记账",
        "capture" to "OCR截图记账",
        "templates" to "模板记账",
        "recurring" to "周期计划",
    )

    fun actions(context: Context): List<String> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_ACTIONS, "quick,voice,smart,capture") ?: ""
        return raw.split(',').filter { it in allowed }.distinct().take(4)
    }

    fun configure(context: Context, requested: Iterable<String>) {
        val selected = requested.filter { it in allowed }.distinct().take(4)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_ACTIONS, selected.joinToString(",")).apply()
        if (Build.VERSION.SDK_INT >= 25) {
            context.getSystemService(ShortcutManager::class.java).dynamicShortcuts =
                selected.mapIndexed { index, action -> shortcut(context, action, index) }
        }
    }

    fun refresh(context: Context) = configure(context, actions(context))

    fun requestPinShortcut(context: Context, action: String): Boolean {
        if (Build.VERSION.SDK_INT < 26 || action !in allowed) return false
        val manager = context.getSystemService(ShortcutManager::class.java)
        if (!manager.isRequestPinShortcutSupported) return false
        return manager.requestPinShortcut(shortcut(context, action, 100 + allowed.indexOf(action)), null)
    }

    fun requestPinWidget(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 26) return false
        val manager = AppWidgetManager.getInstance(context)
        val provider = ComponentName(context, LedgerWidgetProvider::class.java)
        return manager.isRequestPinAppWidgetSupported && manager.requestPinAppWidget(provider, null, null)
    }

    private fun shortcut(context: Context, action: String, rank: Int): ShortcutInfo {
        val label = labels[action] ?: "记一笔"
        return ShortcutInfo.Builder(context, "ledger_$action")
            .setShortLabel(label)
            .setLongLabel("知账 · $label")
            .setRank(rank)
            .setIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(mainIntent(context, action))
            .build()
    }

    fun mainIntent(context: Context, action: String): Intent =
        Intent(context, MainActivity::class.java)
            .setAction("com.smartledger.action.$action")
            .putExtra(ShortcutNotification.EXTRA_ACTION, action)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    fun updateWidgets(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val component = ComponentName(context, LedgerWidgetProvider::class.java)
        val ids = manager.getAppWidgetIds(component)
        if (ids.isNotEmpty()) LedgerWidgetProvider().onUpdate(context, manager, ids)
    }
}

class LedgerWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.ledger_widget)
            bind(context, views, R.id.widget_quick, "quick", 7101 + id)
            bind(context, views, R.id.widget_voice, "voice", 7201 + id)
            bind(context, views, R.id.widget_capture, "capture", 7301 + id)
            bind(context, views, R.id.widget_templates, "templates", 7401 + id)
            manager.updateAppWidget(id, views)
        }
    }

    private fun bind(context: Context, views: RemoteViews, viewId: Int, action: String, request: Int) {
        views.setOnClickPendingIntent(
            viewId,
            PendingIntent.getActivity(
                context,
                request,
                HomeShortcuts.mainIntent(context, action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
    }
}
