package com.smartledger.smart_ledger

import android.app.Activity
import android.os.Bundle

/**
 * Transparent relay for notification, tile and Flutter screenshot actions.
 *
 * Screenshot bookkeeping deliberately has one implementation: Android's
 * accessibility one-frame screenshot API. It never requests MediaProjection,
 * starts a screen-recording service, or opens the main Flutter activity.
 */
class CaptureActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null && PaymentAccessibilityService.active?.requestQuickScreenshot() != true) {
            PaymentTrace.event(
                this,
                "quick_capture_failed",
                PaymentAutomation.MANUAL_OCR_PACKAGE,
                "screenshot",
            )
            ShortcutNotification.notifyCaptureFailure(
                this,
                "截图记账需要无障碍增强，请先开启并保持知账无障碍服务连接",
            )
        }
        finish()
    }
}
