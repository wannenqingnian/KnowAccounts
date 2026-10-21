package com.smartledger.smart_ledger

import android.content.Context
import android.content.Intent
import android.content.ComponentName
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.accessibilityservice.AccessibilityServiceInfo
import android.view.accessibility.AccessibilityManager
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONArray
import java.security.MessageDigest
import java.util.UUID
import android.net.Uri

/** Main-thread private queue, captured configuration, bounded replay and a short-lived Dart worker. */
object PaymentAutomation {
    const val MANUAL_OCR_PACKAGE = "com.smartledger.capture.ocr"
    private val handler = Handler(Looper.getMainLooper())
    private var engine: FlutterEngine? = null
    private var ui: MethodChannel? = null
    private var timeout: Runnable? = null
    var notificationConnected = false
    var lastNotificationConnectedAt = 0L
    var accessibilityConnected = false
    var accessibilityRootNodeCount = 0
    var accessibilityUsableTextCount = 0
    var accessibilityPageSessionId = ""
    var accessibilityWindowPackage = ""
    var ocrScreenshotSucceeded = false
    var ocrRecognizedLineCount = 0
    var ocrAmountCandidateFound = false
    var ocrSuccessMarkerFound = false
    var ocrRejectionReason = ""
    private fun prefs(c: Context) = c.getSharedPreferences("payment_automation", Context.MODE_PRIVATE)
    fun config(c: Context): JSONObject = try { JSONObject(prefs(c).getString("config", "{}")!!) } catch (_: Exception) { JSONObject() }
    fun permitted(c: Context, packageName: String, kind: String): Boolean {
        val cfg = config(c)
        return cfg.optBoolean("enabled") && packageName in PaymentCaptureGuard.packages &&
            (kind != "accessibility" || cfg.optBoolean("enhanced")) &&
            (cfg.optJSONObject("apps")?.optJSONObject(packageName)?.optBoolean("enabled") == true)
    }
    fun sourceGate(c: Context, pkg: String, kind: String): Boolean {
        if(pkg !in PaymentCaptureGuard.packages) return false
        if(permitted(c,pkg,kind)) { PaymentTrace.event(c,"event_received",pkg,kind); return true }
        val cfg=config(c)
        val code=if(!cfg.optBoolean("enabled")) "master_disabled" else if(kind=="accessibility" && !cfg.optBoolean("enhanced")) "enhanced_disabled" else "app_disabled"
        PaymentTrace.event(c,code,pkg,kind);return false
    }
    private fun queued(c: Context): JSONArray = try { JSONArray(prefs(c).getString("queue", "[]")) } catch (_: Exception) { JSONArray() }
    private fun writeQueue(c: Context, q: JSONArray) { check(prefs(c).edit().putString("queue", q.toString()).commit()) }
    /** Recognized fields follow the user's privacy setting; raw page text is never retained. */
    fun record(c: Context, pkg: String, kind: String, reason: String, fields: Map<String, String>? = null) {
        if (!permitted(c, pkg, kind)) return
        PaymentTrace.event(c,reason,pkg,kind,fields=fields)
        val p = prefs(c)
        p.edit().putInt("sourceEvents", minOf(Int.MAX_VALUE - 1, p.getInt("sourceEvents", 0)) + 1)
            .putString("lastSource", pkg).putString("lastKind", kind).putString("lastReason", reason)
            .putLong("sourceTime", System.currentTimeMillis()).apply()
    }
    fun reconnect(c: Context) {
        if (!config(c).optBoolean("enabled") || notificationConnected) return
        val component = ComponentName(c, PaymentNotificationService::class.java)
        val granted = (Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners") ?: "")
            .split(':').mapNotNull { ComponentName.unflattenFromString(it) }.contains(component)
        if (granted) try { PaymentTrace.event(c,"reconnect_requested"); NotificationListenerService.requestRebind(component) } catch (_: Exception) { /* OS retains authority. */ }
    }
    fun status(c: Context): Map<String, Any?> {
        val listener = ComponentName(c, PaymentNotificationService::class.java)
        val listeners = Settings.Secure.getString(c.contentResolver, "enabled_notification_listeners") ?: ""
        val notifications = listeners.split(':').mapNotNull { ComponentName.unflattenFromString(it) }.contains(listener)
        val manager = c.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
        val access = manager.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK).any {
            it.resolveInfo.serviceInfo.packageName == c.packageName && it.resolveInfo.serviceInfo.name == PaymentAccessibilityService::class.java.name
        }
        val p = prefs(c)
        return mapOf("supported" to true, "config" to jsonMap(config(c)), "notificationsGranted" to notifications,
            "accessibilityGranted" to access, "notificationConnected" to notificationConnected, "accessibilityConnected" to accessibilityConnected,
            "queued" to queued(c).length(), "posted" to p.getInt("posted", 0), "pending" to p.getInt("pending", 0),
            "sourceEvents" to p.getInt("sourceEvents", 0), "lastSource" to p.getString("lastSource", ""),
            "lastKind" to p.getString("lastKind", ""), "lastReason" to p.getString("lastReason", ""), "sourceTime" to p.getLong("sourceTime", 0),
            "errorCode" to p.getString("errorCode", ""), "workerRunning" to (engine != null), "overlayGranted" to Settings.canDrawOverlays(c), "overlayVisible" to PaymentOverlay.visible(),
            "dropped" to p.getInt("dropped", 0), "lastTime" to p.getLong("lastTime", 0), "error" to p.getBoolean("error", false),
            "ocrModelReady" to (WechatScreenshotFallback.model(c) != null),
            "notification" to mapOf("listenerConnected" to notificationConnected, "lastConnectedAt" to lastNotificationConnectedAt),
            "accessibility" to mapOf("rootNodeCount" to accessibilityRootNodeCount, "usableTextCount" to accessibilityUsableTextCount, "pageSessionId" to accessibilityPageSessionId, "windowPackage" to accessibilityWindowPackage),
            "ocr" to mapOf("screenshotSucceeded" to ocrScreenshotSucceeded, "recognizedLineCount" to ocrRecognizedLineCount, "amountCandidateFound" to ocrAmountCandidateFound, "successMarkerFound" to ocrSuccessMarkerFound, "rejectionReason" to ocrRejectionReason),

            "installed" to PaymentCaptureGuard.packages.keys.associateWith { pkg -> try { c.packageManager.getApplicationInfo(pkg, 0); true } catch (_: Exception) { false } })
    }
    fun bind(c: Context, flutterEngine: FlutterEngine, foreground: Boolean): MethodChannel {
        val context = c.applicationContext
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smart_ledger/automation")
        if (foreground) ui = channel
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "status" -> { result.success(status(context)); reconnect(context); kick(context) }
                    "diagnostics" -> { check(foreground); result.success(PaymentTrace.report(context)) }
                    "clearDiagnostics" -> { check(foreground); PaymentTrace.clear(context); result.success(null) }
                    "setDiagnosticsEnabled" -> { check(foreground); PaymentTrace.setEnabled(context,call.argument<Boolean>("enabled")==true); result.success(null) }
                    "setDiagnosticsSensitive" -> { check(foreground); PaymentTrace.setSensitive(context,call.argument<Boolean>("enabled")==true); result.success(null) }
                    "workerTrace" -> {
                        check(!foreground)
                        PaymentTrace.event(context,call.argument<String>("code") ?: "",call.argument<String>("app") ?: "",call.argument<String>("source") ?: "",call.argument<String>("id") ?: "",call.argument<Int>("count") ?: 0)
                        result.success(null)
                    }
                    "configure" -> {
                        check(foreground)
                        val input = call.arguments as? Map<*, *> ?: error("config")
                        val cfg = JSONObject()
                        val ledger = input["ledgerId"] as? String ?: error("ledger")
                        require(ledger.length in 1..100)
                        cfg.put("enabled", input["enabled"] == true).put("enhanced", input["enhanced"] == true)
                            .put("autoSave", input["autoSave"] != false).put("reviewPopup", input["reviewPopup"] != false)
                            .put("screenshotFallback", input["screenshotFallback"] == true).put("ledgerId", ledger)
                        val apps = JSONObject(); val choices = input["apps"] as? Map<*, *> ?: emptyMap<Any, Any>()
                        for (pkg in PaymentCaptureGuard.packages.keys) {
                            val row = choices[pkg] as? Map<*, *> ?: emptyMap<Any, Any>()
                            val app = JSONObject().put("enabled", row["enabled"] == true)
                            for (field in listOf("accountId", "categoryId")) {
                                val id = row[field] as? String
                                require(id == null || id.length in 1..100)
                                app.put(field, id ?: JSONObject.NULL)
                            }
                            apps.put(pkg, app)
                        }
                        cfg.put("apps", apps)
                        // Settings changes invalidate unprocessed captures instead of applying a new account to old data.
                        val edit = prefs(context).edit().putString("config", cfg.toString()).putBoolean("error", false).putString("errorCode", "")
                        if (config(context).toString() != cfg.toString()) { PaymentTrace.event(context,"queue_reset",count=queued(context).length()); edit.putString("queue", "[]") }
                        check(edit.commit())
                        PaymentTrace.event(context,"config_saved")
                        if(!cfg.optBoolean("enabled") || !cfg.optBoolean("reviewPopup",true)) PaymentOverlay.hide()
                        reconnect(context)
                        PaymentAccessibilityService.active?.refreshPackages()
                        result.success(null)
                        ui?.invokeMethod("updated", null)
                    }
                    "openNotifications" -> { check(foreground); c.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(null) }
                    "openAccessibility" -> { check(foreground); c.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(null) }
                    "openOverlay" -> { check(foreground); c.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${c.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(null) }
                    "takeConfirmation" -> { check(!foreground); result.success(confirmation(context)?.let {jsonMap(it)}) }
                    "authorizeConfirmation" -> { check(!foreground); result.success(confirmation(context)?.optString("nonce") == call.argument<String>("nonce")) }
                    "confirmationResult" -> {
                        check(!foreground)
                        if(confirmation(context)?.optString("nonce") == call.argument<String>("nonce")) {
                            check(prefs(context).edit().remove("confirmation").commit())
                            val duplicate=call.argument<Boolean>("duplicate")==true
                            PaymentTrace.event(context,if(call.argument<Boolean>("ok")==true) "form_saved" else if(duplicate) "form_duplicate" else "form_rejected")
                            PaymentOverlay.result(call.argument<Boolean>("ok")==true,call.argument<String>("message") ?: "保存失败，请重试",call.argument<Boolean>("duplicate")==true)
                            ui?.invokeMethod("updated",null)
                        }
                        result.success(null)
                    }
                    "retry" -> { check(foreground); PaymentTrace.event(context,"retry_requested"); prefs(context).edit().putBoolean("error", false).putString("errorCode", "").apply(); reconnect(context); kick(context); result.success(null) }
                    "take" -> {
                        check(!foreground)
                        val cfg = config(context); val q = queued(context)
                        val selected = if (cfg.optBoolean("enabled")) {
                            if (q.length() > 0) q.getJSONObject(0) else null
                        } else {
                            (0 until q.length()).map { q.getJSONObject(it) }
                                .firstOrNull { it.optString("kind") == "screenshot" }
                        }
                        result.success(selected?.let { jsonMap(it) })
                    }
                    "ack" -> {
                        check(!foreground)
                        val id = call.argument<String>("id"); val outcome = call.argument<String>("outcome")
                        val q = queued(context); val next = JSONArray(); var found = false
                        for (i in 0 until q.length()) { val e = q.getJSONObject(i); if (e.optString("id") == id) found = true else next.put(e) }
                        if (found) {
                            val preview=call.argument<Map<String,Any?>>("preview")
                            fun selectedName(list: String, selected: String): String {
                                val selectedId=preview?.get(selected) as? String ?: return ""
                                return (preview[list] as? List<*>)?.mapNotNull { it as? Map<*, *> }
                                    ?.firstOrNull { it["id"] == selectedId }?.get("name") as? String ?: ""
                            }
                            PaymentTrace.event(
                                context,
                                if(outcome in listOf("posted","pending","repeated","discarded")) "worker_$outcome" else "processing_error",
                                ref=id ?: "",
                                fields=mapOf(
                                    "amount" to (preview?.get("amount") as? String ?: ""),
                                    "merchant" to (preview?.get("merchant") as? String ?: ""),
                                    "account" to selectedName("accounts", "accountId"),
                                    "category" to selectedName("categories", "categoryId"),
                                ),
                            )
                            val quality = call.argument<Map<String,Any?>>("quality")
                            if (quality != null) {
                                PaymentTrace.event(context, "worker_quality", ref=id ?: "", fields=quality)
                            }
                            writeQueue(context, next)
                            val p = prefs(context); val edit = p.edit().putLong("lastTime", System.currentTimeMillis()).putBoolean("error", false)
                            if (outcome in listOf("posted", "pending")) edit.putInt(outcome!!, p.getInt(outcome, 0) + 1)
                            edit.apply(); ui?.invokeMethod("updated", null)
                            val manual = call.argument<String>("kind") == "screenshot"
                            if(manual && outcome == "discarded") ShortcutNotification.notifyCaptureFailure(context,"未识别到明确账单，请在支付成功或账单详情页面重试")
                            if(preview!=null && (manual || (config(context).optBoolean("enabled") && config(context).optBoolean("reviewPopup",true)))) PaymentOverlay.show(context,preview)
                        }
                        result.success(null)
                    }
                    "authorize" -> {
                        check(!foreground)
                        val id = call.argument<String>("id")
                        val q = queued(context)
                        result.success((0 until q.length()).any { q.getJSONObject(it).optString("id") == id })
                    }
                    "finish" -> {
                        check(!foreground)
                        val ok = call.argument<Boolean>("ok") == true
                        val code = call.argument<String>("code") ?: "processing_error"
                        PaymentTrace.event(context,if(ok) "worker_finish" else code)
                        prefs(context).edit().putBoolean("error", !ok).putString("errorCode", if(ok) "" else if(code in listOf("plugin_unavailable", "invalid_capture", "database_error", "processing_error")) code else "processing_error").apply()
                        result.success(null)
                        handler.post { stop(); if (!ok && confirmation(context) != null) PaymentOverlay.result(false,"后台处理失败，请重试或在应用内查看待确认账单",false); ui?.invokeMethod("updated", null); if (ok) kick(context) }
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("automation", "自动记账设置或后台处理失败，请重试", null) }
        }
        return channel
    }
    fun unbind(channel: MethodChannel?) { if (ui === channel) ui = null }
    @Synchronized fun enqueue(c: Context, packageName: String, kind: String, text: String, capturedAt: Long, identity: String) {
        if (!permitted(c, packageName, kind)) return
        val cfg = config(c); val app = cfg.getJSONObject("apps").getJSONObject(packageName); val p = prefs(c)
        val diagnosticFields = PaymentCaptureGuard.diagnosticFields(text)
        val digest = MessageDigest.getInstance("SHA-256").digest("${cfg.optString("ledgerId")}|$packageName|$kind|$identity".toByteArray()).joinToString("") { "%02x".format(it) }
        val seen = JSONArray(p.getString("seen", "[]"))
        if ((0 until seen.length()).any { seen.optString(it) == digest }) { PaymentTrace.event(c,"replay_skipped",packageName,kind,digest,fields=diagnosticFields);return }
        // Notification and accessibility/OCR may report the same payment with
        // different source IDs. Suppress only a short semantic repeat window so
        // a later legitimate purchase of the same amount remains valid.
        val semantic = PaymentCaptureGuard.replayIdentity(packageName, text)
        val recentFingerprint = if (semantic.isEmpty()) "" else MessageDigest.getInstance("SHA-256")
            .digest("${cfg.optString("ledgerId")}|$semantic".toByteArray())
            .joinToString("") { "%02x".format(it) }
        val now = System.currentTimeMillis()
        val semanticReplayWindow = PaymentCaptureGuard.replayWindow(semantic)
        val replayHistory = p.getString("recentCaptures", "") ?: ""
        val legacyRepeat = p.getString("recentCapture", "") == recentFingerprint &&
            now - p.getLong("recentCaptureTime", 0L) in 0..semanticReplayWindow
        if (recentFingerprint.isNotEmpty() &&
            (legacyRepeat || PaymentReplayHistory.contains(replayHistory, recentFingerprint, now, semanticReplayWindow))) {
            PaymentTrace.event(c,"replay_skipped",packageName,kind,digest,fields=diagnosticFields)
            return
        }
        val event = JSONObject().put("id", digest).put("packageName", packageName).put("kind", kind)
            .put("text", PaymentCaptureGuard.redact(text)).put("capturedAt", capturedAt).put("ledgerId", cfg.optString("ledgerId"))
            .put("accountId", app.opt("accountId") ?: JSONObject.NULL).put("categoryId", app.opt("categoryId") ?: JSONObject.NULL).put("autoSave", cfg.optBoolean("autoSave", true) && !cfg.optBoolean("reviewPopup", true))
        val q = queued(c); val next = JSONArray(); var dropped = 0
        for (i in 0 until q.length()) {
            val e = q.getJSONObject(i)
            if (System.currentTimeMillis() - e.optLong("capturedAt") > 48 * 60 * 60 * 1000L || next.length() >= 99) dropped++ else next.put(e)
        }
        next.put(event)
        val history = JSONArray(); for (i in maxOf(0, seen.length() - 499) until seen.length()) history.put(seen.getString(i)); history.put(digest)
        val edit = p.edit().putString("queue", next.toString()).putString("seen", history.toString())
            .putInt("dropped", p.getInt("dropped", 0) + dropped)
        if (recentFingerprint.isNotEmpty()) edit.putString(
            "recentCaptures",
            PaymentReplayHistory.record(replayHistory, recentFingerprint, now),
        ).remove("recentCapture").remove("recentCaptureTime")
        check(edit.commit())
        PaymentTrace.event(c,"queued",packageName,kind,digest,next.length(),diagnosticFields)
        if(dropped>0) PaymentTrace.event(c,"queue_dropped",count=dropped)
        kick(c.applicationContext)
    }
    /** A user-requested screenshot is independent from passive auto-bookkeeping. */
    @Synchronized fun enqueueScreenshot(c: Context, text: String, capturedAt: Long, ledgerId: String) {
        require(text.isNotBlank() && text.length <= 4000 && ledgerId.length in 1..100)
        val p = prefs(c)
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$ledgerId|screenshot|$capturedAt|$text".toByteArray())
            .joinToString("") { "%02x".format(it) }
        val seen = JSONArray(p.getString("seen", "[]"))
        if ((0 until seen.length()).any { seen.optString(it) == digest }) {
            PaymentTrace.event(c,"replay_skipped",MANUAL_OCR_PACKAGE,"screenshot",digest)
            return
        }
        val event = JSONObject().put("id", digest).put("packageName", MANUAL_OCR_PACKAGE)
            .put("kind", "screenshot").put("text", PaymentCaptureGuard.redact(text))
            .put("capturedAt", capturedAt).put("ledgerId", ledgerId)
            .put("accountId", JSONObject.NULL).put("categoryId", JSONObject.NULL)
            // A quick screenshot has no trusted source package or confidence
            // envelope. Always ask for one lightweight overlay confirmation.
            .put("autoSave", false)
        val q = queued(c); val next = JSONArray(); var dropped = 0
        for (i in 0 until q.length()) {
            val old = q.getJSONObject(i)
            if (System.currentTimeMillis() - old.optLong("capturedAt") > 48 * 60 * 60 * 1000L || next.length() >= 99) dropped++
            else next.put(old)
        }
        next.put(event)
        val history = JSONArray()
        for (i in maxOf(0, seen.length() - 499) until seen.length()) history.put(seen.getString(i))
        history.put(digest)
        check(p.edit().putString("queue", next.toString()).putString("seen", history.toString())
            .putInt("dropped", p.getInt("dropped", 0) + dropped)
            .putBoolean("error", false).putString("errorCode", "").commit())
        PaymentTrace.event(c,"queued",MANUAL_OCR_PACKAGE,"screenshot",digest,next.length())
        kick(c.applicationContext)
    }
    private fun confirmation(c: Context): JSONObject? = try { prefs(c).getString("confirmation",null)?.let {JSONObject(it)} } catch(_:Exception) { null }
    fun submitConfirmation(c: Context, values: JSONObject) {
        val old = confirmation(c)
        check(old == null || (engine == null && old.optString("draftId") == values.optString("draftId")))
        PaymentTrace.event(c,"form_submitted",ref=values.optString("draftId"))
        values.put("nonce",UUID.randomUUID().toString())
        check(prefs(c).edit().putString("confirmation",values.toString()).putBoolean("error",false).putString("errorCode", "").commit())
        kick(c.applicationContext)
    }
    fun resume(c: Context) { kick(c.applicationContext) }
    /**
     * FlutterLoader and FlutterEngine must be initialized on Android's main
     * thread. Screenshot OCR completes on its own executor, so always marshal
     * the worker launch before touching either API. Keeping the state check in
     * the synchronized main-thread method also collapses several captures that
     * finish at nearly the same time into one worker.
     */
    private fun kick(c: Context) {
        val context = c.applicationContext
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { kickOnMain(context) }
            return
        }
        kickOnMain(context)
    }
    @Synchronized private fun kickOnMain(c: Context) {
        val q = queued(c)
        val runnable = config(c).optBoolean("enabled") ||
            (0 until q.length()).any { q.getJSONObject(it).optString("kind") == "screenshot" }
        if (engine != null || (confirmation(c)==null && (q.length() == 0 || !runnable)) || prefs(c).getBoolean("error", false)) return
        try {
            PaymentTrace.event(c,"worker_start",count=queued(c).length())
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(c); loader.ensureInitializationComplete(c, null)
            val worker = FlutterEngine(c)
            engine = worker
            bind(c, worker, false)
            worker.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "paymentAutomationWorker"))
            timeout = Runnable { PaymentTrace.event(c,"worker_timeout"); prefs(c).edit().putBoolean("error", true).putString("errorCode", "worker_timeout").apply(); stop(); if (confirmation(c) != null) PaymentOverlay.result(false,"保存超时，请重试",false); ui?.invokeMethod("updated", null) }
            handler.postDelayed(timeout!!, 120_000)
        } catch (_: Throwable) { PaymentTrace.event(c,"worker_start_failed"); prefs(c).edit().putBoolean("error", true).putString("errorCode", "worker_start_failed").apply(); stop(); if (confirmation(c) != null) PaymentOverlay.result(false,"保存未启动，请重试",false) }
    }
    @Synchronized private fun stop() { timeout?.let { handler.removeCallbacks(it) }; timeout = null; engine?.destroy(); engine = null }
    private fun jsonMap(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key ->
        when (val value = json.get(key)) { JSONObject.NULL -> null; is JSONObject -> jsonMap(value); else -> value }
    }
}
