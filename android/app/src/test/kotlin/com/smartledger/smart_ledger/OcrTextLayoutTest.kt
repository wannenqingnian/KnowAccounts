package com.smartledger.smart_ledger

import org.junit.Assert.assertEquals
import org.junit.Test

class OcrTextLayoutTest {
    @Test fun floatingChatDoesNotMixIntoPayment() {
        val amount = OcrLine("-3.50", 230, 330, 340, 360)
        val field = OcrLine("商户全称", 45, 590, 490, 620)
        val marker = OcrLine("查看共享链接", 430, 100, 560, 120)
        val chatter = OcrLine("收入和支出", 420, 155, 550, 190)
        val lines = listOf(marker, chatter, amount, field)
        assertEquals(listOf(amount, field), OcrTextLayout.withoutFloatingWindow(lines, 582, 1280))
    }
    @Test fun noMarkerDoesNotDiscardReceiptContent() {
        val lines = listOf(OcrLine("付款", 450, 100, 560, 130), OcrLine("-3.50", 230, 330, 340, 360))
        assertEquals(lines, OcrTextLayout.withoutFloatingWindow(lines, 582, 1280))
    }
    @Test fun merchantNamedCloudOutsideOverlayAreaIsPreserved() {
        val lines = listOf(OcrLine("Cloud", 420, 600, 550, 630))
        assertEquals(lines, OcrTextLayout.withoutFloatingWindow(lines, 582, 1280))
    }
}
