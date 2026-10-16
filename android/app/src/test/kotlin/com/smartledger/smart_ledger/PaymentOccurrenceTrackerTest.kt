package com.smartledger.smart_ledger

import android.view.accessibility.AccessibilityEvent
import org.junit.Assert.*
import org.junit.Test

class PaymentOccurrenceTrackerTest {
    @Test fun repeatedWindowEventsNeverTurnOneVisibleReceiptIntoNewPayments() {
        val tracker = PaymentOccurrenceTracker()
        val pkg = "com.eg.android.AlipayGphone"
        val cls = "com.alipay.mobile.payee.ui.PayResultActivity"
        val first = tracker.observe(pkg, cls, AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 1_000L)
        val afterOverlay = tracker.observe(pkg, cls, AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 8_000L)
        val muchLater = tracker.observe(pkg, cls, AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 80_000L)
        assertTrue(first.boundary)
        assertFalse(afterOverlay.boundary)
        assertFalse(muchLater.boundary)
        assertEquals(first.token, afterOverlay.token)
        assertEquals(first.token, muchLater.token)
    }

    @Test fun oneReceiptMayCrossFinancialActivitiesButLeavingItCreatesBoundary() {
        val tracker = PaymentOccurrenceTracker()
        val pkg = "com.tencent.mm"
        val first = tracker.observe(pkg, "RemittanceUI", AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 1_000L)
        val details = tracker.observe(pkg, "WalletOrderInfoNewUI", AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 1_100L)
        val chat = tracker.observe(pkg, "ChattingUI", AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, 2_000L)
        assertFalse(details.boundary)
        assertEquals(first.token, details.token)
        assertTrue(chat.boundary)
        assertNotEquals(first.token, chat.token)
    }
}
