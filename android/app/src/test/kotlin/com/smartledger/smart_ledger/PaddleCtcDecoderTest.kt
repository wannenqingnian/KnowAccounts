package com.smartledger.smart_ledger

import org.junit.Assert.*
import org.junit.Test

class PaddleCtcDecoderTest {
    private val alphabet = listOf("", "1", "6", ".", "0", "沙")
    private fun logits(vararg tokens: Int): FloatArray = FloatArray(tokens.size * alphabet.size).also { a ->
        tokens.forEachIndexed { step, token -> a[step * alphabet.size + token] = .98f }
    }
    @Test fun repeatedDigitsSeparatedByBlankArePreserved() {
        val text = PaddleCtcDecoder.decode(logits(1,1,2,2,3,4,0,4),8,alphabet)
        assertEquals("16.00",text.text); assertEquals(.98f,text.score,.00001f)
    }
    @Test fun blanksDoNotLowerCharacterConfidence() {
        assertEquals(.98f,PaddleCtcDecoder.decode(logits(0,5,5,0),4,alphabet).score,.00001f)
        assertEquals("",PaddleCtcDecoder.decode(logits(0,0),2,alphabet).text)
    }
    @Test(expected = IllegalArgumentException::class) fun mismatchedDictionaryCannotCorruptAmounts() {
        PaddleCtcDecoder.decode(FloatArray(4),1,alphabet)
    }
}
