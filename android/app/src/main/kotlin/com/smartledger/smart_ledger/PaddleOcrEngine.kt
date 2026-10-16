package com.smartledger.smart_ledger

import android.graphics.Bitmap
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.*
import org.opencv.imgproc.Imgproc
import java.io.File
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.*

/** Offline PP-OCR DB detector + perspective crops + CTC recognizer. */
class PaddleOcrEngine(private val directory: File, private val tier: String) {
    private val environment = OrtEnvironment.getEnvironment()
    data class Region(val corners: Array<Point>)
    data class Recognized(val line: OcrLine, val score: Float)

    fun recognize(bitmap: Bitmap, options: OrtSession.RunOptions, expired: AtomicBoolean): Map<String, Any> {
        check(OpenCVLoader.initLocal()) { "OpenCV unavailable" }
        val names = when (tier) {
            "light" -> Pair("PP-OCRv6_det_tiny.onnx", "PP-OCRv6_rec_tiny.onnx")
            "balanced" -> Pair("PP-OCRv6_det_small.onnx", "PP-OCRv6_rec_small.onnx")
            "accurate" -> Pair("PP-OCRv6_det_medium.onnx", "PP-OCRv6_rec_medium.onnx")
            else -> throw IllegalArgumentException("Unsupported PP-OCR tier")
        }
        val det = File(directory, "models/${names.first}")
        val rec = File(directory, "models/${names.second}")
        require(det.isFile && rec.isFile)
        val image = Mat()
        val bgr = Mat()
        val sessionOptions = OrtSession.SessionOptions()
        try {
            sessionOptions.setIntraOpNumThreads(2)
            sessionOptions.setInterOpNumThreads(1)
            Utils.bitmapToMat(bitmap, image)
            Imgproc.cvtColor(image, bgr, Imgproc.COLOR_RGBA2BGR)
            environment.createSession(det.path, sessionOptions).use { detector ->
                val regions = detect(bgr, detector, options, expired)
                environment.createSession(rec.path, sessionOptions).use { recognizer ->
                    val rawAlphabet = recognizer.metadata.customMetadata["character"] ?: error("Missing alphabet")
                    val alphabet = listOf("") + rawAlphabet.split('\n') + listOf(" ")
                    val result = mutableListOf<Recognized>()
                    for (region in regions) {
                        check(!expired.get()) { "OCR timeout" }
                        val crop = crop(bgr, region.corners)
                        try {
                            val decoded = recognizeLine(crop, recognizer, alphabet, options)
                            if (decoded.text.isNotBlank() && decoded.score >= .5f) {
                                val xs = region.corners.map { it.x }; val ys = region.corners.map { it.y }
                                result.add(Recognized(OcrLine(decoded.text, xs.min().toInt(), ys.min().toInt(), xs.max().toInt(), ys.max().toInt()), decoded.score))
                            }
                        } finally { crop.release() }
                    }
                    val clean = OcrTextLayout.withoutFloatingWindow(result.map { it.line }, bgr.cols(), bgr.rows())
                    val rows = OcrTextLayout.readingOrder(clean)
                    return mapOf("engine" to "ppocr", "texts" to listOf(rows.joinToString("\n") { it.text }),
                        "lines" to result.filter { it.line in clean }.map { mapOf("text" to it.line.text, "confidence" to it.score.toDouble(), "box" to listOf(it.line.left, it.line.top, it.line.right, it.line.bottom)) })
                }
            }
        } finally { sessionOptions.close(); image.release(); bgr.release() }
    }

    private fun tensor(image: Mat, height: Int, width: Int): OnnxTensor {
        val resized = Mat()
        try {
            Imgproc.resize(image, resized, Size(width.toDouble(), height.toDouble()), 0.0, 0.0, Imgproc.INTER_LINEAR)
            val pixels = ByteArray(width * height * 3)
            resized.get(0, 0, pixels)
            val values = FloatArray(pixels.size)
            // RapidOCR ONNX PP-OCR models consume BGR CHW, normalized to [-1, 1].
            for (i in 0 until width * height) for (c in 0..2) values[c * width * height + i] = ((pixels[i * 3 + c].toInt() and 255) / 255f - .5f) / .5f
            return OnnxTensor.createTensor(environment, FloatBuffer.wrap(values), longArrayOf(1, 3, height.toLong(), width.toLong()))
        } finally { resized.release() }
    }

    private fun detect(image: Mat, session: OrtSession, options: OrtSession.RunOptions, expired: AtomicBoolean): List<Region> {
        val limit = if (tier == "light") 960 else 1280
        val scale = min(1.0, limit.toDouble() / max(image.rows(), image.cols()))
        val height = max(32, (image.rows() * scale / 32).roundToInt() * 32)
        val width = max(32, (image.cols() * scale / 32).roundToInt() * 32)
        tensor(image, height, width).use { input ->
            session.run(mapOf(session.inputNames.first() to input), options).use { output ->
                val prediction = output[0] as OnnxTensor
                val dimensions = prediction.info.shape
                val h = dimensions[2].toInt(); val w = dimensions[3].toInt()
                val scores = FloatArray(h * w); prediction.floatBuffer.get(scores)
                val binary = ByteArray(scores.size) { if (scores[it] > .3f) 255.toByte() else 0 }
                val mask = Mat(h, w, CvType.CV_8UC1)
                val hierarchy = Mat()
                val contours = mutableListOf<MatOfPoint>()
                try {
                    mask.put(0, 0, binary)
                    Imgproc.findContours(mask, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)
                    val regions = mutableListOf<Region>()
                    for (contour in contours.take(1000)) {
                        check(!expired.get()) { "OCR timeout" }
                        val contour2f = MatOfPoint2f(*contour.toArray())
                        val rectangle = try { Imgproc.minAreaRect(contour2f) } finally { contour2f.release() }
                        val rw = rectangle.size.width; val rh = rectangle.size.height
                        if (min(rw, rh) < 3 || rw * rh < 10) continue
                        val points = Array(4) { Point() }; rectangle.points(points)
                        if (boxScore(scores, w, h, points) < .5) continue
                        // DB unclip distance: area * ratio / perimeter. Expanding the
                        // oriented rectangle gives the enclosing text crop.
                        val distance = rw * rh * 1.5 / (2 * (rw + rh))
                        rectangle.size = Size(rw + 2 * distance, rh + 2 * distance)
                        rectangle.points(points)
                        val ordered = order(points).map { Point((it.x * image.cols() / w).coerceIn(0.0, image.cols() - 1.0), (it.y * image.rows() / h).coerceIn(0.0, image.rows() - 1.0)) }.toTypedArray()
                        if (hypot(ordered[1].x - ordered[0].x, ordered[1].y - ordered[0].y) > 3 && hypot(ordered[3].x - ordered[0].x, ordered[3].y - ordered[0].y) > 3) regions.add(Region(ordered))
                    }
                    require(regions.size <= 160) { "Too many text regions; crop a single receipt" }
                    return regions.sortedBy { it.corners.minOf { p -> p.y } }
                } finally { contours.forEach { it.release() }; hierarchy.release(); mask.release() }
            }
        }
    }

    private fun boxScore(scores: FloatArray, width: Int, height: Int, corners: Array<Point>): Double {
        val left = floor(corners.minOf { it.x }).toInt().coerceIn(0, width - 1)
        val top = floor(corners.minOf { it.y }).toInt().coerceIn(0, height - 1)
        val right = ceil(corners.maxOf { it.x }).toInt().coerceIn(left, width - 1)
        val bottom = ceil(corners.maxOf { it.y }).toInt().coerceIn(top, height - 1)
        val mask = Mat.zeros(bottom - top + 1, right - left + 1, CvType.CV_8UC1)
        val polygon = MatOfPoint(*corners.map { Point(it.x - left, it.y - top) }.toTypedArray())
        try {
            Imgproc.fillPoly(mask, listOf(polygon), Scalar(1.0))
            val pixels = ByteArray(mask.rows() * mask.cols()); mask.get(0, 0, pixels)
            var total = 0.0; var count = 0
            for (y in 0 until mask.rows()) for (x in 0 until mask.cols()) if (pixels[y * mask.cols() + x].toInt() != 0) { total += scores[(top + y) * width + left + x]; count++ }
            return if (count == 0) 0.0 else total / count
        } finally { polygon.release(); mask.release() }
    }

    private fun order(points: Array<Point>): Array<Point> {
        val sorted = points.sortedBy { it.x }
        val left = sorted.take(2).sortedBy { it.y }; val right = sorted.drop(2).sortedBy { it.y }
        return arrayOf(left[0], right[0], right[1], left[1])
    }

    private fun crop(image: Mat, points: Array<Point>): Mat {
        val width = max(4, max(hypot(points[1].x - points[0].x, points[1].y - points[0].y), hypot(points[2].x - points[3].x, points[2].y - points[3].y)).roundToInt())
        val height = max(4, max(hypot(points[3].x - points[0].x, points[3].y - points[0].y), hypot(points[2].x - points[1].x, points[2].y - points[1].y)).roundToInt())
        val source = MatOfPoint2f(*points)
        val target = MatOfPoint2f(Point(0.0, 0.0), Point(width - 1.0, 0.0), Point(width - 1.0, height - 1.0), Point(0.0, height - 1.0))
        val transform = Imgproc.getPerspectiveTransform(source, target)
        val result = Mat()
        try {
            Imgproc.warpPerspective(image, result, transform, Size(width.toDouble(), height.toDouble()), Imgproc.INTER_CUBIC, Core.BORDER_REPLICATE)
            if (height > width * 1.5) Core.rotate(result, result, Core.ROTATE_90_COUNTERCLOCKWISE)
            return result
        } catch (error: Throwable) { result.release(); throw error }
        finally { source.release(); target.release(); transform.release() }
    }

    private fun recognizeLine(image: Mat, session: OrtSession, alphabet: List<String>, options: OrtSession.RunOptions): PaddleCtcDecoder.Decoded {
        val actualWidth = ceil(48.0 * image.cols() / image.rows()).toInt().coerceAtLeast(1)
        val width = max(32, (actualWidth + 7) / 8 * 8)
        require(width <= 2048) { "Text line too long; crop receipt" }
        // A single crop is processed without stretching to a minimum width.
        // Right padding uses normalized zero, matching PaddleOCR recognition.
        val resized = Mat()
        try {
            Imgproc.resize(image, resized, Size(actualWidth.toDouble(), 48.0), 0.0, 0.0, Imgproc.INTER_LINEAR)
            val pixels = ByteArray(48 * actualWidth * 3); resized.get(0, 0, pixels)
            val values = FloatArray(3 * 48 * width)
            for (y in 0 until 48) for (x in 0 until actualWidth) for (c in 0..2) {
                values[c * 48 * width + y * width + x] = ((pixels[(y * actualWidth + x) * 3 + c].toInt() and 255) / 255f - .5f) / .5f
            }
            OnnxTensor.createTensor(environment, FloatBuffer.wrap(values), longArrayOf(1, 3, 48, width.toLong())).use { input ->
                session.run(mapOf(session.inputNames.first() to input), options).use { output ->
                    val prediction = output[0] as OnnxTensor
                    val shape = prediction.info.shape
                    require(shape.size == 3 && shape[0] == 1L && shape[2] == alphabet.size.toLong())
                    val logits = FloatArray((shape[1] * shape[2]).toInt()); prediction.floatBuffer.get(logits)
                    return PaddleCtcDecoder.decode(logits, shape[1].toInt(), alphabet)
                }
            }
        } finally { resized.release() }
    }
}
