package com.smartledger.smart_ledger

import org.junit.Assert.assertEquals
import org.junit.Test

class ShortcutNotificationTest {
    @Test
    fun sanitizeKeepsOrderDeduplicatesAndLimitsVisibleActions() {
        assertEquals(
            listOf("voice", "capture", "today"),
            ShortcutNotification.sanitize(listOf("unknown", "voice", "capture", "voice", "today", "quick")),
        )
    }
}
