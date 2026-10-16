package com.smartledger.smart_ledger

import android.Manifest
import android.content.Intent
import android.content.ComponentName
import android.content.ActivityNotFoundException
import android.app.Activity
import android.app.StatusBarManager
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.speech.RecognizerIntent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface
import ai.onnxruntime.OrtSession
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private val speechRequestCode = 52061
    private val notificationRequestCode = 52062
    private var pendingSpeechResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null
    private lateinit var localSpeechEngine: LocalSpeechEngine
    private val pendingCaptures = java.util.ArrayDeque<Pair<File, Long>>()
    private var captureChannel: MethodChannel? = null
    private var shortcutChannel: MethodChannel? = null
    private val pendingShortcuts = java.util.ArrayDeque<String>()
    private var automationChannel: MethodChannel? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val running = AtomicBoolean(false)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        localSpeechEngine = LocalSpeechEngine(this)
        automationChannel = PaymentAutomation.bind(this, flutterEngine, true)
        RecurringScheduler.bind(this, flutterEngine, true)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smart_ledger/speech")
            .setMethodCallHandler { call, result ->
                if (call.method == "installModel") {
                    localSpeechEngine.installModel(call, result)
                    return@setMethodCallHandler
                }
                if (call.method == "listenLocal") {
                    localSpeechEngine.listen(
                        call.argument<String>("modelPath"),
                        call.argument<String>("language") ?: "zh",
                        result,
                    )
                    return@setMethodCallHandler
                }
                if (call.method == "stopLocal") {
                    localSpeechEngine.stop(result)
                    return@setMethodCallHandler
                }
                if (call.method == "getRecordingLimit") {
                    result.success(localSpeechEngine.recordingLimitSeconds())
                    return@setMethodCallHandler
                }
                if (call.method == "setRecordingLimit") {
                    localSpeechEngine.setRecordingLimitSeconds(call.argument<Int>("seconds"), result)
                    return@setMethodCallHandler
                }
                if (call.method == "getSilenceAutoFinish") {
                    result.success(localSpeechEngine.silenceAutoFinish())
                    return@setMethodCallHandler
                }
                if (call.method == "setSilenceAutoFinish") {
                    localSpeechEngine.setSilenceAutoFinish(call.argument<Boolean>("enabled"), result)
                    return@setMethodCallHandler
                }
                if (call.method == "getSilenceFinishSeconds") {
                    result.success(localSpeechEngine.silenceFinishSeconds())
                    return@setMethodCallHandler
                }
                if (call.method == "setSilenceFinishSeconds") {
                    localSpeechEngine.setSilenceFinishSeconds(call.argument<Int>("seconds"), result)
                    return@setMethodCallHandler
                }
                if (call.method == "prepareLocal") {
                    localSpeechEngine.prepare(
                        call.argument<String>("modelPath"),
                        call.argument<String>("language") ?: "zh",
                        result,
                    )
                    return@setMethodCallHandler
                }
                if (call.method != "listenSystem") { result.notImplemented(); return@setMethodCallHandler }
                if (pendingSpeechResult != null) {
                    result.error("busy", "语音识别正在进行", null)
                    return@setMethodCallHandler
                }
                val locale = call.argument<String>("locale") ?: "zh-CN"
                val preferOffline = call.argument<Boolean>("preferOffline") ?: true
                val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                    putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, locale)
                    putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, preferOffline)
                    putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                    putExtra(RecognizerIntent.EXTRA_PROMPT, "请说出时间、商户、金额和付款账户")
                }
                try {
                    pendingSpeechResult = result
                    startActivityForResult(intent, speechRequestCode)
                } catch (_: ActivityNotFoundException) {
                    pendingSpeechResult = null
                    result.error("unavailable", "手机未安装可用的系统语音识别服务", null)
                } catch (_: Throwable) {
                    pendingSpeechResult = null
                    result.error("speech_failed", "无法启动语音识别", null)
                }
            }
        queueCapture(intent)
        queueShortcut(intent)
        HomeShortcuts.refresh(this)
        captureChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smart_ledger/capture")
        captureChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePending" -> {
                    val pending = pendingCaptures.pollFirst()
                    result.success(pending?.let { mapOf("path" to it.first.path, "capturedAt" to it.second) })
                }
                "startCapture" -> {
                    if (running.get()) {
                        result.error("busy", "正在识别，请等待本次记账完成", null)
                    } else {
                        try {
                            // The relay delegates to the connected accessibility
                            // one-frame screenshot API; no recording permission.
                            startActivity(Intent(this, CaptureActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS))
                            moveTaskToBack(true)
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("capture_start", "无法开始截图，请使用下拉截图记账磁贴", null)
                        }
                    }
                }
                "addTile" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        getSystemService(StatusBarManager::class.java).requestAddTileService(
                            ComponentName(this, CaptureTileService::class.java), "截图记账",
                            Icon.createWithResource(this, R.drawable.ic_capture), mainExecutor) { code ->
                                result.success(code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED || code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED)
                            }
                    } else result.success(false)
                }
                else -> result.notImplemented()
            }
        }
        shortcutChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ShortcutNotification.CHANNEL)
        shortcutChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(mapOf(
                    "supported" to true,
                    "granted" to ShortcutNotification.granted(this),
                    "actions" to ShortcutNotification.actions(this),
                ))
                "configure" -> {
                    val actions = call.argument<List<String>>("actions") ?: emptyList()
                    val today = call.argument<Number>("todayExpenseMinor")?.toLong() ?: 0L
                    ShortcutNotification.configure(this, actions, today,
                        call.argument<String>("ledgerId") ?: "personal")
                    result.success(true)
                }
                "updateToday" -> {
                    ShortcutNotification.updateToday(
                        this,
                        call.argument<Number>("todayExpenseMinor")?.toLong() ?: 0L,
                        call.argument<String>("ledgerId") ?: "personal",
                    )
                    result.success(true)
                }
                "desktopStatus" -> result.success(mapOf(
                    "supported" to (Build.VERSION.SDK_INT >= 25),
                    "pinWidgetSupported" to (Build.VERSION.SDK_INT >= 26 &&
                        android.appwidget.AppWidgetManager.getInstance(this)
                            .isRequestPinAppWidgetSupported),
                    "actions" to HomeShortcuts.actions(this),
                ))
                "configureDesktop" -> {
                    HomeShortcuts.configure(
                        this,
                        call.argument<List<String>>("actions") ?: emptyList(),
                    )
                    result.success(true)
                }
                "pinShortcut" -> result.success(
                    HomeShortcuts.requestPinShortcut(
                        this,
                        call.argument<String>("action") ?: "",
                    ),
                )
                "pinWidget" -> result.success(HomeShortcuts.requestPinWidget(this))
                "takePending" -> result.success(pendingShortcuts.pollFirst())
                "requestPermission" -> {
                    if (ShortcutNotification.granted(this)) {
                        ShortcutNotification.refresh(this)
                        result.success(true)
                    } else if (Build.VERSION.SDK_INT >= 33) {
                        if (pendingNotificationResult != null) {
                            result.error("busy", "系统通知授权正在进行", null)
                        } else {
                            pendingNotificationResult = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), notificationRequestCode)
                        }
                    } else result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smart_ledger/ocr")
            .setMethodCallHandler { call, result ->
                if (call.method != "recognize") { result.notImplemented(); return@setMethodCallHandler }
                val imagePath = call.argument<String>("imagePath")
                val modelPath = call.argument<String>("modelPath")
                val tier = call.argument<String>("tier") ?: "balanced"
                val engine = call.argument<String>("engine")
                if (imagePath == null || modelPath == null || engine != "ppocr" || tier !in listOf("light", "balanced", "accurate")) {
                    result.error("invalid_input", "请选择图片并下载OCR模型", null)
                    return@setMethodCallHandler
                }
                if (!running.compareAndSet(false, true)) {
                    result.error("busy", "图片正在识别，请稍后", null)
                    return@setMethodCallHandler
                }
                worker.execute {
                    var bitmap: Bitmap? = null
                    val runOptions = OrtSession.RunOptions()
                    var timeout: java.util.concurrent.ScheduledFuture<*>? = null
                    val expired = AtomicBoolean(false)
                    try {
                        val models = File(modelPath).canonicalFile
                        require(models.path.startsWith(filesDir.canonicalPath + File.separator))
                        val image = File(imagePath)
                        require(image.isFile && image.length() in 1..(20L * 1024 * 1024))
                        bitmap = loadBitmap(image)
                        timeout = timer.schedule({ expired.set(true); runOptions.setTerminate(true) }, 90, TimeUnit.SECONDS)
                        val recognized = PaddleOcrEngine(models, tier).recognize(bitmap, runOptions, expired)
                        check(!expired.get())
                        timeout.cancel(false)
                        timer.submit {}.get()
                        runOnUiThread { if (!isDestroyed) result.success(recognized) }
                    } catch (_: OutOfMemoryError) {
                        runOnUiThread { if (!isDestroyed) result.error("image_memory", "图片过大，请裁剪到单笔账单后重试", null) }
                    } catch (_: Throwable) {
                        runOnUiThread { if (!isDestroyed) result.error("ocr_failed", if (expired.get()) "图片识别超时，请裁剪后重试" else "图片或模型无法读取，请使用清晰的PNG/JPG截图并检查模型", null) }
                    } finally {
                        timeout?.cancel(false)
                        try { timer.submit {}.get() } catch (_: Exception) { }
                        runOptions.close()
                        bitmap?.recycle()
                        running.set(false)
                        if (isDestroyed) timer.shutdown()
                    }
                }
            }
    }

    private fun queueCapture(source: Intent): Boolean {
        val path = source.getStringExtra("capturePath") ?: return false
        source.removeExtra("capturePath")
        return try {
            val file = File(path).canonicalFile
            if (file.parentFile != File(cacheDir, "captures").canonicalFile || !file.isFile) false
            else {
                pendingCaptures.addLast(file to source.getLongExtra("capturedAt", System.currentTimeMillis()))
                true
            }
        } catch (_: Exception) { false }
    }

    private fun queueShortcut(source: Intent): Boolean {
        val action = source.getStringExtra(ShortcutNotification.EXTRA_ACTION) ?: return false
        source.removeExtra(ShortcutNotification.EXTRA_ACTION)
        if (action !in listOf("quick", "voice", "today", "smart", "capture", "templates", "recurring")) return false
        pendingShortcuts.addLast(action)
        return true
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (queueCapture(intent)) captureChannel?.invokeMethod("available", null)
        if (queueShortcut(intent)) shortcutChannel?.invokeMethod("available", null)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != speechRequestCode) return
        val result = pendingSpeechResult ?: return
        pendingSpeechResult = null
        if (resultCode != Activity.RESULT_OK) {
            result.error("cancelled", "已取消语音输入", null)
            return
        }
        val candidates = data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
        val text = candidates?.firstOrNull { it.isNotBlank() }?.trim()
        if (text == null) result.error("no_match", "没有听清，请重试", null)
        else result.success(text)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationRequestCode) {
            val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
            pendingNotificationResult?.success(granted)
            pendingNotificationResult = null
            if (granted) ShortcutNotification.refresh(this)
            return
        }
        localSpeechEngine.onPermissionResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        pendingSpeechResult?.error("cancelled", "语音输入已结束", null)
        pendingSpeechResult = null
        pendingNotificationResult?.error("cancelled", "通知授权已结束", null)
        pendingNotificationResult = null
        localSpeechEngine.shutdown()
        PaymentAutomation.unbind(automationChannel)
        worker.shutdown()
        if (!running.get()) timer.shutdown()
        super.onDestroy()
    }

    private fun loadBitmap(file: File): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0)
        require(bounds.outWidth.toLong() * bounds.outHeight <= 80_000_000L)
        var sample = 1
        while ((bounds.outWidth.toLong() / sample) * (bounds.outHeight / sample) > 8_000_000L) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
        val original = BitmapFactory.decodeFile(file.path, options) ?: throw IllegalArgumentException("image")
        var oriented = original
        try {
            val orientation = ExifInterface(file).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            val matrix = Matrix()
            when (orientation) {
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.setScale(1f, -1f)
                ExifInterface.ORIENTATION_TRANSPOSE -> { matrix.setRotate(90f); matrix.postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
                ExifInterface.ORIENTATION_TRANSVERSE -> { matrix.setRotate(-90f); matrix.postScale(-1f, 1f) }
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            }
            if (!matrix.isIdentity) oriented = Bitmap.createBitmap(original, 0, 0, original.width, original.height, matrix, true)
            val opaque = Bitmap.createBitmap(oriented.width, oriented.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(opaque)
            canvas.drawColor(Color.WHITE)
            canvas.drawBitmap(oriented, 0f, 0f, null)
            return opaque
        } finally {
            if (oriented !== original) oriented.recycle()
            original.recycle()
        }
    }
}
