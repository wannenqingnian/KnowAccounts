package com.smartledger.smart_ledger

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs

/** Strict, privacy-preserving extraction for a freshly sent WeChat transfer card. */
object WechatScreenshotFallback {
    data class Model(val directory: File, val tier: String)
    data class Card(val text: String, val identity: String)
    private val modelFiles = mapOf(
        "light" to mapOf("PP-OCRv6_det_tiny.onnx" to 1_829_618L, "PP-OCRv6_rec_tiny.onnx" to 4_489_813L),
        "balanced" to mapOf("PP-OCRv6_det_small.onnx" to 9_929_594L, "PP-OCRv6_rec_small.onnx" to 21_234_383L),
        "accurate" to mapOf("PP-OCRv6_det_medium.onnx" to 62_119_454L, "PP-OCRv6_rec_medium.onnx" to 76_629_984L))

    fun model(context: Context): Model? = try {
        val directory = File(context.filesDir, "ocr_models/active-v2").canonicalFile
        check(directory.path.startsWith(context.filesDir.canonicalPath + File.separator))
        val manifest = JSONObject(File(directory, "model.json").readText())
        val tier = manifest.optString("tier")
        val expected = modelFiles[tier] ?: return null
        if (manifest.optInt("version") != 3 || manifest.optString("engine") != "ppocr" ||
            expected.any { (name, size) -> File(directory, "models/$name").let { !it.isFile || it.length() != size } }) null
        else Model(directory, tier)
    } catch (_: Exception) { null }

    fun extract(lines: List<OcrLine>, imageHeight: Int, now: Long): Card? {
        if (imageHeight <= 0) return null
        val rows = OcrTextLayout.readingOrder(lines).filter { it.text.isNotBlank() }
        val phrase = Regex("你发起了一笔转账|对方已收款")
        val amount = Regex("[¥￥Y]\\s*(\\d+(?:\\.\\d{1,2})?)|(\\d+(?:\\.\\d{1,2})?)\\s*元")
        val clock = Regex("(?<!\\d)([01]?\\d|2[0-3])[:：]([0-5]\\d)(?!\\d)")
        val date = Date(now)
        val nowMinute = SimpleDateFormat("HH", Locale.US).format(date).toInt() * 60 + SimpleDateFormat("mm", Locale.US).format(date).toInt()
        for (index in rows.indices.reversed()) {
            val status = phrase.find(rows[index].text)?.value ?: continue
            val from = maxOf(0, index - 4); val to = minOf(rows.lastIndex, index + 4)
            if ((from..to).none { rows[it].text.replace(Regex("\\s+"), "").contains("微信转账") }) continue
            val money = (from..to).mapNotNull { i -> amount.find(rows[i].text)?.let { Triple(abs(i-index), i, it) } }
                .minWithOrNull(compareBy<Triple<Int,Int,MatchResult>> { it.first }.thenByDescending { it.second })?.third ?: continue
            val value = (money.groups[1]?.value ?: money.groups[2]?.value)?.trim() ?: continue
            val cardTop = rows[index].top
            val recent = rows.filter { it.top > imageHeight * .06 && it.top < cardTop && cardTop - it.top < imageHeight * .28 }
                .mapNotNull { clock.find(it.text) }.lastOrNull() ?: continue
            val minute = recent.groupValues[1].toInt() * 60 + recent.groupValues[2].toInt()
            val delta = minOf(abs(minute-nowMinute), 1440-abs(minute-nowMinute))
            if (delta > 3) continue
            val day = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(date)
            val hm = "%02d:%02d".format(Locale.US, minute / 60, minute % 60)
            val occurrences = rows.count { phrase.containsMatchIn(it.text) }
            return Card("$status\n¥$value\n微信转账\n转账时间 $day $hm", "$day $hm|$value|$status|$occurrences")
        }
        return null
    }
}
