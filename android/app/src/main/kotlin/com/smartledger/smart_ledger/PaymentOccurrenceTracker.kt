package com.smartledger.smart_ledger

import android.view.accessibility.AccessibilityEvent

/**
 * Gives one visible payment flow a stable identity.
 *
 * Payment result activities may keep emitting TYPE_WINDOW_STATE_CHANGED while
 * nothing on screen changed (and opening our overlay can trigger another
 * event). Time alone must therefore never create a new occurrence. A boundary
 * is created only when the source package changes or the page really leaves
 * one financial route for another kind of page. Financial-to-financial class
 * changes are kept in the same flow because many apps render one receipt
 * through several activities/dialogs.
 */
class PaymentOccurrenceTracker {
    data class Update(val token: String, val boundary: Boolean)

    private var packageName = ""
    private var pageClass = ""
    private var sequence = 0L
    private var token = "0"

    fun observe(pkg: String, cls: String, eventType: Int, now: Long): Update {
        val packageChanged = pkg != packageName
        val nextClass = if (!packageChanged && cls.isBlank()) pageClass else cls
        val classChanged = eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            pageClass.isNotBlank() && nextClass.isNotBlank() && nextClass != pageClass
        val sameFinancialFlow = !packageChanged && classChanged &&
            PaymentPageRouter.isFinancialClass(pkg, pageClass) &&
            PaymentPageRouter.isFinancialClass(pkg, nextClass)
        val boundary = packageChanged || (classChanged && !sameFinancialFlow)
        if (boundary) token = "$now-${++sequence}"
        packageName = pkg
        if (nextClass.isNotBlank() || packageChanged) pageClass = nextClass
        return Update(token, boundary)
    }
}
