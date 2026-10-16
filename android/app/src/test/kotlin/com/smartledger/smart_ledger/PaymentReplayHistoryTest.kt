package com.smartledger.smart_ledger

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PaymentReplayHistoryTest {
    @Test fun alternatingCaptureVariantsStillSuppressTheFirstVariant() {
        var history = PaymentReplayHistory.record("", "refund-a", 1_000L)
        history = PaymentReplayHistory.record(history, "refund-b", 2_000L)

        assertTrue(PaymentReplayHistory.contains(history, "refund-a", 3_000L, 30_000L))
        assertFalse(PaymentReplayHistory.contains(history, "refund-a", 40_001L, 30_000L))
    }
}
