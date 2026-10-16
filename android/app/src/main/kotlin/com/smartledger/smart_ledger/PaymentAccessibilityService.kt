package com.smartledger.smart_ledger

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Bitmap
import android.os.Build
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.Display
import ai.onnxruntime.OrtSession
import android.os.Handler
import android.os.Looper
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class PaymentAccessibilityService : AccessibilityService() {
    companion object { var active: PaymentAccessibilityService? = null }
    private val handler = Handler(Looper.getMainLooper())
    private var pending: Runnable? = null
    private var windowClass = ""
    private var windowPackage = ""
    private val pageSession = PaymentPageSession()
    private val ocrWorker = Executors.newSingleThreadExecutor()
    private val ocrTimer = Executors.newSingleThreadScheduledExecutor()
    private val ocrBusy = AtomicBoolean(false)
    private data class DeferredScan(val packageName: String, val windowClass: String, val snippets: List<String>)
    private var deferredScan: DeferredScan? = null
    @Volatile private var nextScreenshotAt = 0L
    @Volatile private var consecutiveOcrMisses = 0
    private var occurrence = "0"
    private val occurrenceTracker = PaymentOccurrenceTracker()
    override fun onServiceConnected() {
        active = this; PaymentAutomation.accessibilityConnected = true; PaymentTrace.event(this,"accessibility_connected"); refreshPackages(); PaymentAutomation.resume(this)
    }
    fun refreshPackages() {
        val selected = PaymentCaptureGuard.packages.keys.filter { PaymentAutomation.permitted(this, it, "accessibility") }
        serviceInfo = serviceInfo.apply { packageNames = if (selected.isEmpty()) arrayOf(packageName) else selected.toTypedArray() }
    }
    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString() ?: return
        val now = System.currentTimeMillis()
        val nextClass = event.className?.toString() ?: ""
        val transition = occurrenceTracker.observe(pkg, nextClass, event.eventType, now)
        if (transition.boundary) {
            pending?.let { handler.removeCallbacks(it) }
            pending = null
            pageSession.reset()
            consecutiveOcrMisses = 0
            nextScreenshotAt = 0L
            occurrence = transition.token
        }
        if (pkg != windowPackage || event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
                consecutiveOcrMisses = 0
                nextScreenshotAt = 0L
            }
            if (nextClass.isNotBlank() || pkg != windowPackage) windowClass = nextClass
            windowPackage = pkg
        }
        if (!PaymentAutomation.sourceGate(this,pkg,"accessibility")) {
            pending?.let { handler.removeCallbacks(it) }
            pending = null
            pageSession.reset()
            return
        }
        val snippets = collectEventText(event)
        // OCR owns a stable bitmap, but the user may already open another bill
        // while it is running. Keep only the newest event and rescan the live
        // window as soon as OCR finishes instead of dropping every new event.
        if (ocrBusy.get()) {
            if (deferredScan == null) PaymentTrace.event(this,"ocr_event_coalesced",pkg,"accessibility")
            deferredScan = DeferredScan(pkg, nextClass.ifBlank { windowClass }, snippets)
            return
        }
        val firstPending = pending == null
        if(snippets.isNotEmpty() && firstPending) PaymentTrace.event(this,"event_text_read",pkg,"accessibility",count=snippets.size)
        val shouldScan = pageSession.observe(pkg, windowClass, snippets, now)
        if (shouldScan && firstPending) PaymentTrace.event(this,"page_session_started",pkg,"accessibility")
        // Do not debounce by continuously postponing the read. Payment pages can
        // emit dozens of content-change events per second; one scheduled read is
        // kept and later events are accumulated by PaymentPageSession.
        if (shouldScan) {
            scheduleScan(pkg, 160L)
        }
    }

    private fun collectEventText(event: AccessibilityEvent): List<String> = buildList {
            addAll(event.text.map { it.toString() })
            event.contentDescription?.toString()?.let { add(it) }
            event.source?.let { source ->
                var visited = 0
                fun visit(node: AccessibilityNodeInfo) {
                    if (++visited > 80 || node.isPassword) return
                    (node.text?.toString()?.takeIf { it.isNotBlank() }
                        ?: node.contentDescription?.toString())?.trim()?.let { if (it.length <= 300) add(it) }
                    for (i in 0 until minOf(node.childCount, 40)) node.getChild(i)?.let { visit(it) }
                }
                visit(source)
            }
        }.map { it.trim() }.filter { it.isNotEmpty() }.distinct()

    private fun scheduleScan(pkg: String, delay: Long) {
        pending?.let { handler.removeCallbacks(it) }
        val task = Runnable {
            pending = null
            scanPage(pkg)
        }
        pending = task
        handler.postDelayed(task, delay)
    }

    private fun scanPage(pkg: String) {
        if (!PaymentAutomation.permitted(this, pkg, "accessibility")) {
            pageSession.reset()
            return
        }
        val root = rootInActiveWindow
        val lines = mutableListOf<String>()
        var visited = 0
        var chars = 0
        fun addLine(raw: String?) {
            val value = raw?.trim()?.takeIf { it.isNotEmpty() && it.length <= 300 } ?: return
            if (chars + value.length > 4000) return
            lines.add(value)
            chars += value.length + 1
        }
        fun shallowValue(node: AccessibilityNodeInfo?, depth: Int = 0): String? {
            if (node == null || node.isPassword || !node.isVisibleToUser || depth > 2) return null
            (node.text?.toString()?.takeIf { it.isNotBlank() }
                ?: node.contentDescription?.toString()?.takeIf { it.isNotBlank() })?.let { return it.trim() }
            for (i in 0 until minOf(node.childCount, 8)) {
                shallowValue(node.getChild(i), depth + 1)?.let { return it }
            }
            return null
        }
        fun visit(node: AccessibilityNodeInfo) {
            if (++visited > 1000 || chars > 4000 || node.isPassword) return
            if (node.isVisibleToUser) {
                val value = (node.text?.toString()?.takeIf { it.isNotBlank() }
                    ?: node.contentDescription?.toString())?.trim()
                addLine(value)
                addLine(PaymentFieldHints.fromViewId(node.viewIdResourceName, value))
                // A label and value frequently live in adjacent child
                // containers. Preserve that relationship before the regular
                // DFS flattens the page; unknown labels are ignored.
                for (i in 0 until minOf(node.childCount - 1, 24)) {
                    addLine(PaymentFieldHints.sibling(
                        pkg,
                        shallowValue(node.getChild(i)),
                        shallowValue(node.getChild(i + 1)),
                    ))
                }
            }
            for (i in 0 until minOf(node.childCount, 80)) node.getChild(i)?.let { visit(it) }
        }
        try {
            if (PaymentOverlay.visible() && !PaymentOverlay.isCollapsed()) {
                // The confirmation form is expanded on screen. Do not suspend or re-scan while the user is filling it out.
                return
            }
            if (root == null && PaymentOverlay.suspendForCapture()) {
                scheduleScan(pkg, 180L)
                return
            }
            if (root != null && root.packageName?.toString() == pkg) {
                visit(root)
            } else if (root != null) {
                // The confirmation form is an application overlay. While it is
                // expanded Android can report that window as the active root,
                // leaving only one node from the payment app and causing OCR to
                // capture our own form. Hide it for one stable source frame.
                if (PaymentOverlay.suspendForCapture()) {
                    scheduleScan(pkg, 180L)
                    return
                }
                // A transient system/overlay window must not erase the payment
                // fragments already collected from the source application.
                PaymentTrace.event(this,"window_changed",pkg,"accessibility")
            }
            PaymentAutomation.accessibilityRootNodeCount = visited
            PaymentAutomation.accessibilityUsableTextCount = lines.size
            PaymentAutomation.accessibilityPageSessionId = occurrence
            PaymentAutomation.accessibilityWindowPackage = pkg
            PaymentTrace.event(this,"node_read",pkg,"accessibility",count=visited)
            val assessment = pageSession.assess(lines, System.currentTimeMillis())
            if (assessment.matched) {
                PaymentTrace.event(this,"page_session_matched",pkg,"accessibility",count=assessment.attempt)
                PaymentAutomation.record(this, pkg, "accessibility", "matched")
                val identity = PaymentCaptureGuard.semanticIdentity(pkg, assessment.text)
                    .ifEmpty { "${SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())}|${assessment.text}" }
                val scopedOccurrence = if (pkg == "com.tencent.mm" && PaymentCaptureGuard.wechatTransferCard(assessment.text))
                    "$occurrence|${PaymentCaptureGuard.wechatCardOccurrence(assessment.text)}" else occurrence
                PaymentAutomation.enqueue(this, pkg, "accessibility", assessment.text, System.currentTimeMillis(),
                    PaymentCaptureGuard.occurrenceIdentity(identity, scopedOccurrence))
                pageSession.complete()
                PaymentOverlay.resumeAfterCapture()
            } else {
                PaymentAutomation.record(this, pkg, "accessibility", assessment.reason)
                when {
                    assessment.shouldRetry -> {
                        PaymentTrace.event(this,"page_session_waiting",pkg,"accessibility",count=assessment.attempt)
                        val delay = when (assessment.attempt) { 1 -> 180L; 2 -> 360L; else -> 620L }
                        scheduleScan(pkg, delay)
                    }
                    assessment.shouldOcr -> {
                        PaymentTrace.event(this,"ocr_fallback",pkg,"accessibility",count=assessment.attempt)
                        maybeScreenshotOcr(pkg, windowClass)
                    }
                    PaymentPageRouter.isChatClass(pkg, windowClass) -> {
                        PaymentAutomation.record(this,pkg,"accessibility","chat_filtered")
                        pageSession.complete()
                        PaymentOverlay.resumeAfterCapture()
                    }
                    else -> {
                        pageSession.complete()
                        PaymentOverlay.resumeAfterCapture()
                    }
                }
            }
        } catch (_: Exception) {
            PaymentAutomation.record(this, pkg, "accessibility", "read_failed")
            pageSession.complete()
            PaymentOverlay.resumeAfterCapture()
        }
    }
    override fun onInterrupt() { PaymentTrace.event(this,"accessibility_interrupted"); pending?.let { handler.removeCallbacks(it) }; pending = null; deferredScan = null; pageSession.reset(); PaymentOverlay.resumeAfterCapture() }

    /** User-triggered one-frame OCR. It uses the already enabled accessibility
     * service and never starts MediaProjection or keeps a recording session. */
    fun requestQuickScreenshot(): Boolean {
        if (Build.VERSION.SDK_INT < 30 || active !== this) return false
        if (serviceInfo.capabilities and AccessibilityServiceInfo.CAPABILITY_CAN_TAKE_SCREENSHOT == 0) {
            PaymentTrace.event(this,"screenshot_capability_missing",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
            return false
        }
        val model = WechatScreenshotFallback.model(this)
        if (model == null) {
            PaymentTrace.event(this,"ocr_model_missing",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
            ShortcutNotification.notifyCaptureFailure(this,"请先在知账中下载飞桨OCR模型")
            return true
        }
        if (!ocrBusy.compareAndSet(false,true)) {
            ShortcutNotification.notifyCaptureFailure(this,"已有一张图片正在识别，请稍后重试")
            return true
        }
        deferredScan = null
        PaymentAutomation.ocrScreenshotSucceeded = false
        PaymentAutomation.ocrRecognizedLineCount = 0
        PaymentAutomation.ocrAmountCandidateFound = false
        PaymentAutomation.ocrSuccessMarkerFound = false
        PaymentAutomation.ocrRejectionReason = ""
        PaymentOverlay.suspendForCapture()
        ShortcutNotification.clearCaptureFailure(this)
        PaymentTrace.event(this,"quick_capture_started",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
        // Wait for the transparent launcher activity to disappear so only the
        // payment page behind it is present in the one-frame screenshot.
        handler.postDelayed({
            try {
                takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                    override fun onFailure(errorCode: Int) {
                        PaymentAutomation.ocrRejectionReason = "quick_capture_failed"
                        PaymentTrace.event(this@PaymentAccessibilityService,"quick_capture_failed",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot",count=errorCode)
                        finishAutomaticOcr()
                        PaymentOverlay.resumeAfterCapture()
                        ShortcutNotification.notifyCaptureFailure(this@PaymentAccessibilityService,"系统未提供单帧截图，请重新开启知账无障碍权限")
                    }
                    override fun onSuccess(result: ScreenshotResult) {
                        var wrapped: Bitmap? = null
                        var bitmap: Bitmap? = null
                        try {
                            wrapped = Bitmap.wrapHardwareBuffer(result.hardwareBuffer,result.colorSpace)
                            bitmap = wrapped?.copy(Bitmap.Config.ARGB_8888,false)
                        } finally {
                            wrapped?.recycle();result.hardwareBuffer.close()
                        }
                        if (bitmap == null) {
                            PaymentAutomation.ocrRejectionReason = "quick_capture_failed"
                            PaymentTrace.event(this@PaymentAccessibilityService,"quick_capture_failed",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
                            finishAutomaticOcr()
                            PaymentOverlay.resumeAfterCapture()
                            ShortcutNotification.notifyCaptureFailure(this@PaymentAccessibilityService,"系统截图为空，请重新截图")
                            return
                        }
                        PaymentTrace.event(this@PaymentAccessibilityService,"quick_capture_ready",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
                        PaymentOverlay.resumeAfterCapture()
                        runQuickScreenshotOcr(bitmap,model,System.currentTimeMillis())
                    }
                })
            } catch (_: Exception) {
                PaymentAutomation.ocrRejectionReason = "quick_capture_failed"
                PaymentTrace.event(this,"quick_capture_failed",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
                finishAutomaticOcr()
                PaymentOverlay.resumeAfterCapture()
                ShortcutNotification.notifyCaptureFailure(this,"系统未提供单帧截图，请重新开启知账无障碍权限")
            }
        }, 250L)
        return true
    }

    private fun runQuickScreenshotOcr(bitmap: Bitmap, model: WechatScreenshotFallback.Model, capturedAt: Long) {
        ocrWorker.execute {
            val options = OrtSession.RunOptions()
            val expired = AtomicBoolean(false)
            val timeout = ocrTimer.schedule({ expired.set(true);options.setTerminate(true) },60,TimeUnit.SECONDS)
            try {
                PaymentTrace.event(this,"ocr_started",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
                val result = PaddleOcrEngine(model.directory,model.tier).recognize(bitmap,options,expired)
                check(!expired.get())
                val lines = (result["lines"] as? List<*>)?.mapNotNull { row ->
                    val item=row as? Map<*,*> ?: return@mapNotNull null
                    val text=item["text"] as? String ?: return@mapNotNull null
                    val box=item["box"] as? List<*> ?: return@mapNotNull null
                    if(box.size!=4 || box.any { it !is Int }) null else OcrLine(text,box[0] as Int,box[1] as Int,box[2] as Int,box[3] as Int)
                } ?: emptyList()
                val text=OcrTextLayout.readingOrder(lines).joinToString("\n") { it.text }.trim().take(4000)
                check(text.isNotEmpty())
                PaymentAutomation.ocrScreenshotSucceeded = true
                PaymentAutomation.ocrRecognizedLineCount = lines.size
                PaymentAutomation.ocrAmountCandidateFound = Regex("[¥￥]\\s*\\d+(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?\\s*元|(?<!\\d)[+-]?\\d+\\.\\d{2}(?!\\d)").containsMatchIn(text)
                PaymentAutomation.ocrSuccessMarkerFound = PaymentCaptureGuard.successful(PaymentAutomation.MANUAL_OCR_PACKAGE, text)
                PaymentAutomation.ocrRejectionReason = ""
                PaymentTrace.event(this,"quick_ocr_text_read",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot",count=lines.size)
                PaymentTrace.event(this,"quick_ocr_matched",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
                PaymentAutomation.enqueueScreenshot(this,text,capturedAt,ShortcutNotification.ledgerId(this))
            } catch (_: Throwable) {
                PaymentAutomation.ocrScreenshotSucceeded = true
                PaymentAutomation.ocrRejectionReason = "quick_ocr_failed"
                PaymentTrace.event(this,"quick_ocr_failed",PaymentAutomation.MANUAL_OCR_PACKAGE,"screenshot")
                ShortcutNotification.notifyCaptureFailure(this,"未识别到账单，请保持账单页面完整显示后重试")
            } finally {
                timeout.cancel(false);options.close();bitmap.recycle()
                handler.post { if (active === this) finishAutomaticOcr() }
            }
        }
    }

    private fun maybeScreenshotOcr(pkg: String, sourceWindowClass: String) {
        if (Build.VERSION.SDK_INT < 30 || !PaymentAutomation.config(this).optBoolean("enhanced")) { PaymentOverlay.resumeAfterCapture();return }
        if (PaymentOverlay.visible() && !PaymentOverlay.isCollapsed()) {
            // The expanded form is being edited. A collapsed bubble does not
            // block recognition and must not pause later payment captures.
            return
        }
        val now = System.currentTimeMillis()
        if (now < nextScreenshotAt || !ocrBusy.compareAndSet(false,true)) { PaymentOverlay.resumeAfterCapture();return }
        if (serviceInfo.capabilities and AccessibilityServiceInfo.CAPABILITY_CAN_TAKE_SCREENSHOT == 0) {
            PaymentTrace.event(this,"screenshot_capability_missing",pkg,"accessibility")
            ocrBusy.set(false)
            PaymentOverlay.resumeAfterCapture()
            return
        }
        val model = WechatScreenshotFallback.model(this)
        if (model == null) { PaymentTrace.event(this,"ocr_model_missing",pkg,"accessibility");ocrBusy.set(false);PaymentOverlay.resumeAfterCapture();return }
        deferredScan = null
        PaymentAutomation.ocrScreenshotSucceeded = false
        PaymentAutomation.ocrRecognizedLineCount = 0
        PaymentAutomation.ocrAmountCandidateFound = false
        PaymentAutomation.ocrSuccessMarkerFound = false
        PaymentAutomation.ocrRejectionReason = ""
        val captureOccurrence = occurrence
        val overlayHidden = PaymentOverlay.suspendForCapture()
        PaymentTrace.event(this,"screenshot_requested",pkg,"accessibility")
        val capture = Runnable {
            try { takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                override fun onFailure(errorCode: Int) {
                    PaymentAutomation.ocrRejectionReason = "screenshot_unavailable"
                    PaymentTrace.event(this@PaymentAccessibilityService,"screenshot_unavailable",pkg,"accessibility",count=errorCode)
                    nextScreenshotAt = System.currentTimeMillis() + 1_500
                    finishAutomaticOcr()
                    PaymentOverlay.resumeAfterCapture()
                }
                override fun onSuccess(result: ScreenshotResult) {
                    var wrapped: Bitmap? = null
                    var bitmap: Bitmap? = null
                    try {
                        wrapped = Bitmap.wrapHardwareBuffer(result.hardwareBuffer,result.colorSpace)
                        bitmap = wrapped?.copy(Bitmap.Config.ARGB_8888,false)
                    } finally {
                        wrapped?.recycle();result.hardwareBuffer.close()
                    }
                    if (bitmap == null) { PaymentAutomation.ocrRejectionReason = "screenshot_unavailable";PaymentTrace.event(this@PaymentAccessibilityService,"screenshot_unavailable",pkg,"accessibility");finishAutomaticOcr();PaymentOverlay.resumeAfterCapture();return }
                    PaymentOverlay.resumeAfterCapture()
                    runScreenshotOcr(bitmap,model,pkg,sourceWindowClass,captureOccurrence)
                }
            }) } catch (_: Exception) {
                PaymentAutomation.ocrRejectionReason = "screenshot_unavailable"
                PaymentTrace.event(this,"screenshot_unavailable",pkg,"accessibility")
                nextScreenshotAt = System.currentTimeMillis() + 1_500
                finishAutomaticOcr()
                PaymentOverlay.resumeAfterCapture()
            }
        }
        if (overlayHidden) handler.postDelayed(capture,180L) else capture.run()
    }
    private fun runScreenshotOcr(bitmap: Bitmap, model: WechatScreenshotFallback.Model, pkg: String, sourceWindowClass: String, captureOccurrence: String) {
        ocrWorker.execute {
            val options = OrtSession.RunOptions();val expired = AtomicBoolean(false)
            val timeout = ocrTimer.schedule({ expired.set(true);options.setTerminate(true) },60,TimeUnit.SECONDS)
            try {
                PaymentTrace.event(this,"ocr_started",pkg,"accessibility")
                val result = PaddleOcrEngine(model.directory,model.tier).recognize(bitmap,options,expired)
                check(!expired.get())
                val lines = (result["lines"] as? List<*>)?.mapNotNull { row ->
                    val item=row as? Map<*,*> ?: return@mapNotNull null
                    val text=item["text"] as? String ?: return@mapNotNull null
                    val box=item["box"] as? List<*> ?: return@mapNotNull null
                    if(box.size!=4 || box.any { it !is Int }) null else OcrLine(text,box[0] as Int,box[1] as Int,box[2] as Int,box[3] as Int)
                } ?: emptyList()
                val orderedText=OcrTextLayout.readingOrder(lines).joinToString("\n") { it.text }
                val isWechatChat=PaymentPageRouter.isChatClass(pkg,sourceWindowClass)
                val card=if(isWechatChat) WechatScreenshotFallback.extract(lines,bitmap.height,System.currentTimeMillis()) else null
                val matchedText=card?.text ?: orderedText.takeIf { !isWechatChat && PaymentCaptureGuard.pageReason(pkg,it)=="matched" }
                val textForEval = matchedText ?: orderedText
                val evalReason = PaymentCaptureGuard.pageReason(pkg, textForEval)
                PaymentAutomation.ocrScreenshotSucceeded = true
                PaymentAutomation.ocrRecognizedLineCount = lines.size
                PaymentAutomation.ocrAmountCandidateFound = PaymentCaptureGuard.notificationReason(pkg, "", textForEval, false) != "money_missing"
                PaymentAutomation.ocrSuccessMarkerFound = PaymentCaptureGuard.successful(pkg, textForEval)
                PaymentAutomation.ocrRejectionReason = if (matchedText != null) "" else evalReason
                val identity=card?.identity ?: "${SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(Date())}|$matchedText"
                val finishedAt=System.currentTimeMillis()
                if(matchedText==null) {
                    consecutiveOcrMisses++
                    nextScreenshotAt=finishedAt + if(consecutiveOcrMisses <= 2) 1_200 else 8_000
                } else {
                    consecutiveOcrMisses=0
                    nextScreenshotAt=finishedAt + 10_000
                }
                handler.post {
                    if(active !== this) return@post
                    if(matchedText==null) PaymentTrace.event(this,"ocr_no_match",pkg,"accessibility")
                    else {
                        PaymentTrace.event(this,"ocr_matched",pkg,"accessibility")
                        PaymentAutomation.enqueue(this,pkg,"accessibility",matchedText,System.currentTimeMillis(),
                            PaymentCaptureGuard.occurrenceIdentity("ocr|$identity", captureOccurrence))
                    }
                    finishAutomaticOcr()
                }
            } catch (_: Throwable) {
                nextScreenshotAt=System.currentTimeMillis()+1_500
                PaymentAutomation.ocrScreenshotSucceeded = true
                PaymentAutomation.ocrRejectionReason = "ocr_failed"
                PaymentTrace.event(this,"ocr_failed",pkg,"accessibility")
                handler.post { if (active === this) finishAutomaticOcr() }
            }
            finally { timeout.cancel(false);options.close();bitmap.recycle() }
        }
    }

    /** Continues from the newest accessibility event observed during OCR. */
    private fun finishAutomaticOcr() {
        ocrBusy.set(false)
        pageSession.complete()
        val latest = deferredScan ?: return
        deferredScan = null
        if (!PaymentAutomation.permitted(this, latest.packageName, "accessibility")) return
        val shouldScan = pageSession.observe(
            latest.packageName,
            latest.windowClass,
            latest.snippets,
            System.currentTimeMillis(),
        )
        if (shouldScan) {
            PaymentTrace.event(this,"page_session_resumed",latest.packageName,"accessibility")
            scheduleScan(latest.packageName, 80L)
        }
    }
    override fun onDestroy() {
        onInterrupt();active=null;PaymentAutomation.accessibilityConnected=false;PaymentTrace.event(this,"accessibility_disconnected")
        ocrWorker.shutdownNow();ocrTimer.shutdownNow();super.onDestroy()
    }
}
