package com.smartledger.smart_ledger

/** PP-OCR CTC decoding: blank separates repeated characters, not a text token. */
object PaddleCtcDecoder {
    data class Decoded(val text: String, val score: Float)
    fun decode(values: FloatArray, steps: Int, alphabet: List<String>): Decoded {
        require(steps > 0 && alphabet.size > 1 && values.size == steps * alphabet.size)
        val text = StringBuilder()
        var previous = -1
        var confidence = 0f
        var count = 0
        for (step in 0 until steps) {
            val offset = step * alphabet.size
            var token = 0
            for (i in 1 until alphabet.size) if (values[offset + i] > values[offset + token]) token = i
            if (token != 0 && token != previous) {
                text.append(alphabet[token]); confidence += values[offset + token]; count++
            }
            previous = token
        }
        return Decoded(text.toString(), if (count == 0) 0f else confidence / count)
    }
}
