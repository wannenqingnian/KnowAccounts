package com.smartledger.smart_ledger
import org.junit.Assert.*
import org.junit.Test
class PaymentTracePolicyTest {
    @Test fun onlyHashReferencesAndKnownSourcesAreAccepted() {
        assertEquals("a".repeat(12), PaymentTracePolicy.reference("auto-"+"a".repeat(64)))
        for(value in listOf("4111111111111111", "支付成功16.00元", "用户聊天", "a".repeat(12))) assertEquals("",PaymentTracePolicy.reference(value))
        assertEquals("",PaymentTracePolicy.source("微信支付16元"))
        assertEquals("notification",PaymentTracePolicy.source("notification"))
        assertEquals("screenshot",PaymentTracePolicy.source("screenshot"))
        assertTrue(PaymentTracePolicy.codes.contains("quick_ocr_matched"))
        assertTrue(PaymentTracePolicy.codes.contains("quick_capture_started"))
        assertTrue(PaymentTracePolicy.codes.contains("quick_capture_ready"))
        assertTrue(PaymentTracePolicy.codes.contains("quick_ocr_text_read"))
        assertTrue(PaymentTracePolicy.codes.contains("confidence_high"))
        assertTrue(PaymentTracePolicy.codes.contains("confidence_review"))
        assertTrue(PaymentTracePolicy.codes.contains("confidence_low"))
        assertFalse(PaymentTracePolicy.codes.contains("支付成功16元"))
    }
    @Test fun retentionRejectsOldFutureAndInvalidTimes() {
        val now=1800000000000L
        assertTrue(PaymentTracePolicy.retained(now-PaymentTracePolicy.maxAge,now))
        assertFalse(PaymentTracePolicy.retained(now-PaymentTracePolicy.maxAge-1,now))
        assertFalse(PaymentTracePolicy.retained(now+1,now))
        assertFalse(PaymentTracePolicy.retained(0,now))
    }
    @Test fun rejectionReasonsDistinguishWechatFailuresWithoutRawContent() {
        val pkg="com.tencent.mm"
        assertEquals("untrusted_title",PaymentCaptureGuard.notificationReason(pkg,"张三","支付成功16元",false))
        assertEquals("group_summary",PaymentCaptureGuard.notificationReason(pkg,"微信支付","支付成功16元",true))
        assertEquals("money_missing",PaymentCaptureGuard.notificationReason(pkg,"微信支付","支付成功",false))
        assertEquals("success_missing",PaymentCaptureGuard.notificationReason(pkg,"微信支付","交易金额16元",false))
        assertEquals("state_unsupported",PaymentCaptureGuard.notificationReason(pkg,"微信支付","支付失败16元",false))
        assertEquals("fields_missing",PaymentCaptureGuard.pageReason(pkg,"支付成功\n16元\n主页"))
        assertEquals("matched",PaymentCaptureGuard.notificationReason(pkg,"微信支付","你向精品沙县小吃付款16.00元",false))
    }
}
