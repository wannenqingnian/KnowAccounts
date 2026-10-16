package com.smartledger.smart_ledger

/** Geometry is kept separate from the OCR runtime so layout filtering can be tested. */
data class OcrLine(val text: String, val left: Int, val top: Int, val right: Int, val bottom: Int)
object OcrTextLayout {
    fun withoutFloatingWindow(lines: List<OcrLine>, width: Int, height: Int): List<OcrLine> {
        val marker = lines.firstOrNull {
            val compact = it.text.replace(Regex("\\s+"), "")
            it.left > width * .55 && it.top < height * .35 &&
                Regex("查看共享链接|ChatGPT|BaseEn|Cloud", RegexOption.IGNORE_CASE).containsMatchIn(compact)
        } ?: return lines
        val left = maxOf((width * .55).toInt(), marker.left - width / 25)
        val bottom = (height * .35).toInt()
        return lines.filterNot { it.left >= left && it.bottom <= bottom }
    }
    fun readingOrder(lines: List<OcrLine>): List<OcrLine> {
        val rows = mutableListOf<MutableList<OcrLine>>()
        for (line in lines.sortedBy { (it.top + it.bottom) / 2 }) {
            val row = rows.lastOrNull()
            val anchor = row?.firstOrNull()
            if (anchor != null && kotlin.math.abs((anchor.top + anchor.bottom) - (line.top + line.bottom)) < minOf(anchor.bottom - anchor.top, line.bottom - line.top) &&
                (maxOf(0, line.left - row.maxOf { it.right }, row.minOf { it.left } - line.right) <= minOf(anchor.bottom - anchor.top, line.bottom - line.top) * 2.5)) {
                row.add(line)
            } else rows.add(mutableListOf(line))
        }
        return rows.map { row ->
            OcrLine(row.sortedBy { it.left }.joinToString(" ") { it.text }, row.minOf { it.left }, row.minOf { it.top }, row.maxOf { it.right }, row.maxOf { it.bottom })
        }
    }

}
