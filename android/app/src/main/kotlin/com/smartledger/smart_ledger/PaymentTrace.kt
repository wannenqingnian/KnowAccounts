package com.smartledger.smart_ledger

import android.content.Context
import android.os.Build
import android.os.PowerManager
import org.json.JSONArray
import org.json.JSONObject

/** Private bounded log; diagnostic failures never interrupt capturing or saving. */
object PaymentTrace {
    private fun prefs(c: Context) = c.getSharedPreferences("payment_trace", Context.MODE_PRIVATE)
    fun enabled(c: Context) = prefs(c).getBoolean("enabled", true)
    fun setEnabled(c: Context, enabled: Boolean) {
        prefs(c).edit().putBoolean("enabled", enabled).apply()
    }
    @Synchronized fun clear(c: Context) { prefs(c).edit().remove("rows").apply() }
    private fun stored(c: Context): JSONArray = try { JSONArray(prefs(c).getString("rows","[]")) } catch (_: Exception) { JSONArray() }
    @Synchronized fun event(c: Context, code: String, pkg: String="", kind: String="", ref: String="", count: Int=0) {
        try {
            if (!enabled(c) || code !in PaymentTracePolicy.codes) return
            val now=System.currentTimeMillis()
            val rows=JSONArray()
            val previous=stored(c)
            for(i in maxOf(0,previous.length()-PaymentTracePolicy.maxEntries) until previous.length()) {
                val item=previous.optJSONObject(i) ?: continue
                if(PaymentTracePolicy.retained(item.optLong("time"),now)) rows.put(item)
            }
            val app=pkg.takeIf { it in PaymentCaptureGuard.packages || it == PaymentAutomation.MANUAL_OCR_PACKAGE } ?: ""
            val source=PaymentTracePolicy.source(kind); val reference=PaymentTracePolicy.reference(ref)
            val last=if(rows.length()>0) rows.optJSONObject(rows.length()-1) else null
            if(last!=null && last.optString("code")==code && last.optString("app")==app && last.optString("source")==source && last.optString("ref")==reference && now-last.optLong("time")<3000) {
                last.put("time",now).put("repeats",minOf(999999,last.optInt("repeats",1)+1)).put("count",count.coerceIn(0,1000000))
            } else rows.put(JSONObject().put("time",now).put("code",code).put("app",app).put("source",source).put("ref",reference).put("count",count.coerceIn(0,1000000)).put("repeats",1))
            val bounded=JSONArray()
            for(i in maxOf(0, rows.length()-PaymentTracePolicy.maxEntries) until rows.length()) bounded.put(rows.get(i))
            prefs(c).edit().putString("rows",bounded.toString()).apply()
        } catch (_: Exception) { /* Logging must not change the financial outcome. */ }
    }
    fun report(c: Context): Map<String,Any?> {
        val now=System.currentTimeMillis();val rows=stored(c);val events=mutableListOf<Map<String,Any?>>()
        for(i in maxOf(0,rows.length()-PaymentTracePolicy.maxEntries) until rows.length()) {
            val row=rows.optJSONObject(i) ?: continue
            val code=row.optString("code")
            if(code !in PaymentTracePolicy.codes || !PaymentTracePolicy.retained(row.optLong("time"),now)) continue
            events.add(mapOf("time" to row.optLong("time"),"code" to code,
                "app" to (row.optString("app").takeIf { it in PaymentCaptureGuard.packages || it == PaymentAutomation.MANUAL_OCR_PACKAGE } ?: ""),
                "source" to PaymentTracePolicy.source(row.optString("source")),
                "ref" to (row.optString("ref").takeIf {Regex("^[a-f0-9]{12}$").matches(it)} ?: ""),
                "count" to row.optInt("count").coerceIn(0,1000000),"repeats" to row.optInt("repeats",1).coerceIn(1,999999)))
        }
        val status=PaymentAutomation.status(c);val config=PaymentAutomation.config(c)
        val keys=listOf("notificationsGranted","accessibilityGranted","notificationConnected","accessibilityConnected","workerRunning","overlayGranted","overlayVisible","ocrModelReady","queued","error","errorCode")
        val state=keys.associateWith {status[it]}.toMutableMap()
        state["enabled"]=config.optBoolean("enabled");state["enhanced"]=config.optBoolean("enhanced");state["reviewPopup"]=config.optBoolean("reviewPopup",true)
        state["screenshotFallback"]=config.optBoolean("enhanced") && status["ocrModelReady"] == true
        state["wechatEnabled"]=config.optJSONObject("apps")?.optJSONObject("com.tencent.mm")?.optBoolean("enabled") == true
        state["batteryExempt"]=(c.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(c.packageName)
        state["accessibility"]=status["accessibility"]
        state["ocr"]=status["ocr"]
        state["notification"]=status["notification"]
        @Suppress("DEPRECATION")
        val version=c.packageManager.getPackageInfo(c.packageName,0).versionName ?: ""
        return mapOf("enabled" to enabled(c),"appVersion" to version,"androidApi" to Build.VERSION.SDK_INT,"generatedAt" to now,"state" to state,"events" to events)
    }
}
