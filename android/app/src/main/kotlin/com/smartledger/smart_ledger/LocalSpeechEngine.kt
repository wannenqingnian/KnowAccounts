package com.smartledger.smart_ledger

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import io.flutter.plugin.common.MethodChannel
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import org.apache.commons.compress.compressors.bzip2.BZip2CompressorInputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.concurrent.ExecutionException
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean

class LocalSpeechEngine(private val activity: Activity) {
    companion object {
        const val permissionRequestCode = 52062
        private const val sampleRate = 16000
        private const val recordingPrefs = "speech_recording"
        private const val maxSecondsKey = "max_seconds"
        private const val silenceAutoFinishKey = "silence_auto_finish"
        private const val silenceSecondsKey = "silence_seconds"
        private const val minimumConfiguredSeconds = 5
        private const val maximumConfiguredSeconds = 300
        private const val defaultSilenceSeconds = 2
        private const val minimumSilenceSeconds = 1
        private const val maximumSilenceSeconds = 10
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val recordingExecutor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private val sessionActive = AtomicBoolean(false)
    private val stopRequested = AtomicBoolean(false)
    private var permissionRequest: Triple<String, String, MethodChannel.Result>? = null
    private var recognizer: OfflineRecognizer? = null
    private var recognizerPath: String? = null

    /** Zero means that only the user's explicit "done" action ends recording. */
    fun recordingLimitSeconds(): Int {
        val saved = activity.getSharedPreferences(recordingPrefs, Context.MODE_PRIVATE)
            .getInt(maxSecondsKey, 0)
        return if (saved == 0 || saved in minimumConfiguredSeconds..maximumConfiguredSeconds) saved else 0
    }

    fun setRecordingLimitSeconds(seconds: Int?, result: MethodChannel.Result) {
        if (seconds == null || (seconds != 0 && seconds !in minimumConfiguredSeconds..maximumConfiguredSeconds)) {
            result.error("invalid_input", "最长录音时长需为5到300秒，或关闭自动完成", null)
            return
        }
        activity.getSharedPreferences(recordingPrefs, Context.MODE_PRIVATE)
            .edit().putInt(maxSecondsKey, seconds).apply()
        result.success(seconds)
    }

    fun silenceAutoFinish(): Boolean =
        activity.getSharedPreferences(recordingPrefs, Context.MODE_PRIVATE)
            .getBoolean(silenceAutoFinishKey, false)

    fun setSilenceAutoFinish(enabled: Boolean?, result: MethodChannel.Result) {
        if (enabled == null) {
            result.error("invalid_input", "静音自动结束设置无效", null)
            return
        }
        activity.getSharedPreferences(recordingPrefs, Context.MODE_PRIVATE)
            .edit().putBoolean(silenceAutoFinishKey, enabled).apply()
        result.success(enabled)
    }

    fun silenceFinishSeconds(): Int {
        val saved = activity.getSharedPreferences(recordingPrefs, Context.MODE_PRIVATE)
            .getInt(silenceSecondsKey, defaultSilenceSeconds)
        return if (saved in minimumSilenceSeconds..maximumSilenceSeconds) {
            saved
        } else {
            defaultSilenceSeconds
        }
    }

    fun setSilenceFinishSeconds(seconds: Int?, result: MethodChannel.Result) {
        if (seconds == null || seconds !in minimumSilenceSeconds..maximumSilenceSeconds) {
            result.error("invalid_input", "静音结束时长需为1到10秒", null)
            return
        }
        activity.getSharedPreferences(recordingPrefs, Context.MODE_PRIVATE)
            .edit().putInt(silenceSecondsKey, seconds).apply()
        result.success(seconds)
    }

    private data class SessionModels(
        val recognizer: OfflineRecognizer,
        val vad: Vad,
    )

    fun installModel(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val archivePath = call.argument<String>("archivePath")
        val vadPath = call.argument<String>("vadPath")
        val outputPath = call.argument<String>("outputPath")
        if (archivePath == null || vadPath == null || outputPath == null) {
            result.error("invalid_input", "语音模型安装参数不完整", null)
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "语音模型正在处理", null)
            return
        }
        executor.execute {
            try {
                val archive = privateFile(archivePath, mustExist = true)
                val vad = privateFile(vadPath, mustExist = true)
                val output = privateFile(outputPath, mustExist = true)
                require(output.isDirectory)
                extractSpeechFiles(archive, output)
                copyFile(vad, File(output, "silero_vad.int8.onnx"))
                finish { result.success(null) }
            } catch (_: Throwable) {
                finish { result.error("install_failed", "语音模型解压失败，请重新下载", null) }
            } finally {
                busy.set(false)
            }
        }
    }

    fun listen(modelPath: String?, language: String, result: MethodChannel.Result) {
        if (modelPath == null) {
            result.error("model_missing", "请先下载本地语音模型", null)
            return
        }
        if (!hasRecordPermission()) {
            permissionRequest = Triple(modelPath, language, result)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), permissionRequestCode)
            } else {
                permissionRequest = null
                result.error("permission_denied", "没有麦克风权限", null)
            }
            return
        }
        startListening(modelPath, language, result)
    }

    fun prepare(modelPath: String?, language: String, result: MethodChannel.Result) {
        if (modelPath == null) {
            result.error("model_missing", "请先下载本地语音模型", null)
            return
        }
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "语音模型正在处理", null)
            return
        }
        executor.execute {
            try {
                val root = privateFile(modelPath, mustExist = true)
                require(root.isDirectory)
                val model = File(root, "models/model.int8.onnx").canonicalFile
                val tokens = File(root, "models/tokens.txt").canonicalFile
                require(model.isFile && tokens.isFile)
                recognizerFor(root.path, model, tokens, language)
                finish { result.success(null) }
            } catch (_: OutOfMemoryError) {
                finish { result.error("model_memory", "设备内存不足，无法加载当前语音模型", mapOf("stage" to "recognizer")) }
            } catch (error: Throwable) {
                finish {
                    result.error(
                        "model_init_failed",
                        "语音模型初始化失败，请重新下载模型",
                        mapOf("stage" to "recognizer", "errorType" to error.javaClass.simpleName),
                    )
                }
            } finally {
                busy.set(false)
            }
        }
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != permissionRequestCode) return false
        val pending = permissionRequest ?: return true
        permissionRequest = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startListening(pending.first, pending.second, pending.third)
        } else {
            pending.third.error("permission_denied", "请允许麦克风权限后再使用语音记账", null)
        }
        return true
    }

    private fun startListening(modelPath: String, language: String, result: MethodChannel.Result) {
        if (!busy.compareAndSet(false, true)) {
            result.error("busy", "语音识别正在进行", null)
            return
        }
        stopRequested.set(false)
        sessionActive.set(true)
        recordingExecutor.execute {
            var recorder: AudioRecord? = null
            var models: SessionModels? = null
            var modelFuture: Future<SessionModels>? = null
            var stage = "recorder"
            try {
                val minimum = AudioRecord.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                )
                check(minimum > 0)
                recorder = createRecorder(MediaRecorder.AudioSource.VOICE_RECOGNITION, minimum)
                if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                    recorder.release()
                    recorder = createRecorder(MediaRecorder.AudioSource.MIC, minimum)
                }
                check(recorder.state == AudioRecord.STATE_INITIALIZED)
                recorder.startRecording()
                check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING)
                // Start capturing before loading SenseVoice. This preserves the
                // first words on a cold start while model/VAD initialization
                // runs concurrently on the model executor.
                val configuredSeconds = recordingLimitSeconds()
                val finishAfterSilence = silenceAutoFinish()
                val configuredSilenceSeconds = silenceFinishSeconds()
                val future = executor.submit<SessionModels> {
                    val root = privateFile(modelPath, mustExist = true)
                    require(root.isDirectory)
                    val model = File(root, "models/model.int8.onnx").canonicalFile
                    val tokens = File(root, "models/tokens.txt").canonicalFile
                    val vadModel = File(root, "models/silero_vad.int8.onnx").canonicalFile
                    require(model.isFile && tokens.isFile && vadModel.isFile)
                    val localRecognizer = recognizerFor(root.path, model, tokens, language)
                    val localVad = Vad(
                        assetManager = null,
                        config = VadModelConfig(
                            sileroVadModelConfig = SileroVadModelConfig(
                                model = vadModel.path,
                                threshold = 0.5F,
                                minSilenceDuration = if (finishAfterSilence) {
                                    configuredSilenceSeconds.toFloat()
                                } else {
                                    0.65F
                                },
                                minSpeechDuration = 0.2F,
                                windowSize = 512,
                                // With silence auto-finish enabled, a long spoken
                                // sentence must not be mistaken for silence merely
                                // because VAD split it at its normal segment cap.
                                maxSpeechDuration = if (finishAfterSilence) 300F else 12F,
                            ),
                            sampleRate = sampleRate,
                            numThreads = 1,
                            provider = "cpu",
                        ),
                    )
                    SessionModels(localRecognizer, localVad)
                }
                modelFuture = future
                stage = "recording"
                val deadline = configuredSeconds.takeIf { it > 0 }
                    ?.let { System.currentTimeMillis() + it * 1_000L }
                val buffer = ShortArray(512)
                val captured = ArrayList<FloatArray>()
                val segments = ArrayList<FloatArray>()
                var fedChunks = 0
                var readErrors = 0
                while (!stopRequested.get() && (deadline == null || System.currentTimeMillis() < deadline)) {
                    val count = recorder.read(buffer, 0, buffer.size)
                    if (count <= 0) {
                        readErrors += 1
                        check(readErrors < 8)
                        continue
                    }
                    readErrors = 0
                    captured.add(FloatArray(count) { buffer[it] / 32768F })
                    if (models == null && future.isDone) {
                        stage = "model_wait"
                        models = awaitModels(future)
                        stage = "recording"
                    }
                    models?.let { ready ->
                        while (fedChunks < captured.size) {
                            ready.vad.acceptWaveform(captured[fedChunks++])
                        }
                        while (!ready.vad.empty()) {
                            segments.add(ready.vad.front().samples)
                            ready.vad.pop()
                        }
                        if (finishAfterSilence && segments.isNotEmpty()) break
                    }
                }
                recorder.stop()
                stage = "model_wait"
                val ready = models ?: awaitModels(future).also { models = it }
                while (fedChunks < captured.size) {
                    ready.vad.acceptWaveform(captured[fedChunks++])
                }
                ready.vad.flush()
                while (!ready.vad.empty()) {
                    segments.add(ready.vad.front().samples)
                    ready.vad.pop()
                }
                val samples = joinSegments(segments)
                if (samples.isEmpty()) {
                    finish { result.error("no_match", "没有检测到清晰语音，请靠近麦克风再说一次", null) }
                } else {
                    stage = "decode"
                    val stream = ready.recognizer.createStream()
                    try {
                        stream.acceptWaveform(samples, sampleRate)
                        ready.recognizer.decode(stream)
                        val text = ready.recognizer.getResult(stream).text.trim()
                        if (text.isEmpty()) finish { result.error("no_match", "没有听清，请重试", null) }
                        else finish { result.success(text) }
                    } finally {
                        stream.release()
                    }
                }
            } catch (_: SecurityException) {
                finish { result.error("permission_denied", "请允许麦克风权限后再使用语音记账", null) }
            } catch (_: OutOfMemoryError) {
                finish { result.error("model_memory", "设备内存不足，无法运行当前语音模型", mapOf("stage" to stage)) }
            } catch (error: Throwable) {
                val message = when (stage) {
                    "model_wait" -> "语音模型无法加载，请重新下载模型"
                    "recorder", "recording" -> "麦克风无法启动，请关闭其他录音应用后重试"
                    else -> "本地语音解码失败，请重试"
                }
                finish {
                    result.error(
                        "speech_failed_$stage",
                        message,
                        mapOf("stage" to stage, "errorType" to error.javaClass.simpleName),
                    )
                }
            } finally {
                try { if (recorder?.recordingState == AudioRecord.RECORDSTATE_RECORDING) recorder.stop() } catch (_: Throwable) { }
                recorder?.release()
                models?.vad?.release()
                if (models == null) modelFuture?.cancel(true)
                stopRequested.set(false)
                sessionActive.set(false)
                busy.set(false)
            }
        }
    }

    fun stop(result: MethodChannel.Result) {
        // busy is set before the recorder executor starts, so a very fast tap
        // on "done" is still remembered and stops the session once recording
        // has begun.
        val recording = sessionActive.get()
        if (recording) stopRequested.set(true)
        result.success(recording)
    }

    private fun awaitModels(future: Future<SessionModels>): SessionModels = try {
        future.get()
    } catch (error: ExecutionException) {
        throw error.cause ?: error
    }

    @Suppress("MissingPermission")
    private fun createRecorder(source: Int, minimum: Int) = AudioRecord(
        source,
        sampleRate,
        AudioFormat.CHANNEL_IN_MONO,
        AudioFormat.ENCODING_PCM_16BIT,
        maxOf(minimum * 2, 4096),
    )

    @Synchronized
    private fun recognizerFor(path: String, model: File, tokens: File, language: String): OfflineRecognizer {
        if (recognizer != null && recognizerPath == path) return recognizer!!
        recognizer?.release()
        recognizer = OfflineRecognizer(
            assetManager = null,
            config = OfflineRecognizerConfig(
                featConfig = FeatureConfig(sampleRate = sampleRate, featureDim = 80),
                modelConfig = OfflineModelConfig(
                    senseVoice = OfflineSenseVoiceModelConfig(
                        model = model.path,
                        language = if (language in setOf("zh", "yue", "en", "ja", "ko")) language else "zh",
                        useInverseTextNormalization = true,
                    ),
                    tokens = tokens.path,
                    numThreads = 2,
                    provider = "cpu",
                ),
            ),
        )
        recognizerPath = path
        return recognizer!!
    }

    private fun joinSegments(segments: List<FloatArray>): FloatArray {
        val size = segments.sumOf { it.size }
        if (size == 0) return FloatArray(0)
        val result = FloatArray(size)
        var offset = 0
        for (segment in segments) {
            segment.copyInto(result, offset)
            offset += segment.size
        }
        return result
    }

    private fun extractSpeechFiles(archive: File, output: File) {
        var foundModel = false
        var foundTokens = false
        TarArchiveInputStream(
            BZip2CompressorInputStream(BufferedInputStream(FileInputStream(archive)), true),
        ).use { tar ->
            while (true) {
                val entry = tar.nextEntry ?: break
                if (!entry.isFile) continue
                val fileName = entry.name.substringAfterLast('/')
                if (fileName != "model.int8.onnx" && fileName != "tokens.txt") continue
                val target = File(output, fileName).canonicalFile
                require(target.parentFile == output.canonicalFile)
                BufferedOutputStream(FileOutputStream(target)).use { sink ->
                    val buffer = ByteArray(1024 * 1024)
                    var total = 0L
                    while (true) {
                        val count = tar.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= if (fileName == "model.int8.onnx") 240_000_000L else 400_000L)
                        sink.write(buffer, 0, count)
                    }
                }
                if (fileName == "model.int8.onnx") foundModel = true else foundTokens = true
            }
        }
        require(foundModel && foundTokens)
    }

    private fun copyFile(source: File, target: File) {
        BufferedInputStream(FileInputStream(source)).use { input ->
            BufferedOutputStream(FileOutputStream(target)).use { output -> input.copyTo(output) }
        }
    }

    private fun privateFile(path: String, mustExist: Boolean): File {
        val file = File(path).canonicalFile
        val root = activity.filesDir.canonicalFile
        require(file.path.startsWith(root.path + File.separator))
        if (mustExist) require(file.exists())
        return file
    }

    private fun hasRecordPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun finish(block: () -> Unit) = activity.runOnUiThread {
        if (!activity.isDestroyed) block()
    }

    fun shutdown() {
        permissionRequest?.third?.error("cancelled", "语音输入已结束", null)
        permissionRequest = null
        stopRequested.set(true)
        if (!busy.get()) {
            recognizer?.release()
            recognizer = null
        }
        recordingExecutor.shutdownNow()
        executor.shutdownNow()
    }
}
