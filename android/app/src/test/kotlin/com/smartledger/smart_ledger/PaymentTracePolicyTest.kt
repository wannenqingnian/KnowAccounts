package com.smartledger.smart_ledger
import org.junit.Assert.*
import org.junit.Test
class PaymentTracePolicyTest {
    @Test fun detailedPaymentFieldsRequireConsentAndAreScrubbedWhenDisabled() {
        val input = "支付成功\n商户全称\n示例商店\n-3.00\n支付方式\n零钱\n支付时间\n2026年10月22日 08:23:03\n交易单号\n12345678901234567890\n商品\n早餐"
        val read = PaymentCaptureGuard.diagnosticFields(input)
        assertEquals(input, read["paymentText"])
        assertEquals("零钱", read["paymentMethod"])
        assertEquals("2026年10月22日 08:23:03", read["paymentTime"])
        assertEquals("12345678901234567890", read["orderId"])
        val saved = PaymentTracePolicy.fields(read + mapOf("parsedFields" to "{\"blocked\":false}", "warnings" to "账户未匹配"), true)
        assertEquals(input, saved["paymentText"])
        assertTrue(saved.containsKey("parsedFields"))
        val disabled = PaymentTracePolicy.fields(saved, false)
        for (key in listOf("paymentText", "paymentMethod", "paymentTime", "orderId", "parsedFields", "warnings")) assertFalse(disabled.containsKey(key))
        assertFalse(PaymentCaptureGuard.diagnosticFields("今天聊天聊到早餐").containsKey("paymentText"))
        assertTrue(PaymentTracePolicy.fields(mapOf("paymentText" to "x".repeat(20000)), true)["paymentText"]!!.endsWith("[内容过长，已截断]"))
    }
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
    @Test fun recognizedFieldsAreAllowlistedAndMasked() {
        val fields = PaymentTracePolicy.fields(mapOf(
            "amount" to "3.00",
            "merchant" to "三津实业（深圳）有限公司",
            "account" to "招商银行信用卡1234",
            "category" to "餐饮美食",
            "raw" to "付款给谁的完整原文",
            "qualityScore" to "92",
            "amountMatch" to "1",
            "categoryMatch" to "0",
            "remarkScore" to "80",
            "discountMinor" to "300",
        ))
        assertFalse(fields.containsKey("amount"))
        assertEquals("三**********司", fields["merchant"])
        assertEquals("招******1234", fields["account"])
        assertEquals("餐**食", fields["category"])
        assertFalse(fields.containsKey("raw"))
        assertEquals("92", fields["qualityScore"])
        assertEquals("1", fields["amountMatch"])
        assertEquals("0", fields["categoryMatch"])
        assertEquals("80", fields["remarkScore"])
        assertFalse(fields.containsKey("discountMinor"))
        assertTrue(PaymentTracePolicy.fields(mapOf("amount" to "转账3元")).isEmpty())
        assertTrue(PaymentTracePolicy.fields(mapOf(
            "qualityScore" to "101",
            "amountMatch" to "yes",
            "remarkScore" to "-1",
        )).isEmpty())
        val revealed = PaymentTracePolicy.fields(mapOf(
            "amount" to "3.00",
            "merchant" to "三津实业（深圳）有限公司",
            "account" to "招商银行信用卡1234",
        ), reveal = true)
        assertEquals("3.00", revealed["amount"])
        assertEquals("三津实业（深圳）有限公司", revealed["merchant"])
        assertEquals("招商银行信用卡1234", revealed["account"])
    }
    @Test fun accessibilityReceiptProducesUsefulMaskedDiagnosticFields() {
        val fields = PaymentCaptureGuard.diagnosticFields(
            "支付成功\n三津实业（深圳）有限公司\n¥ 3.00\n支付方式\n招商银行储蓄卡（1234）\n返回商家",
        )
        assertEquals("3.00", fields["amount"])
        assertEquals("三津实业（深圳）有限公司", fields["merchant"])
        assertEquals("招商银行储蓄卡（1234）", fields["account"])

        val masked = PaymentTracePolicy.fields(fields)
        assertFalse(masked.containsKey("amount"))
        assertEquals("三**********司", masked["merchant"])
        assertEquals("招********1234", masked["account"])
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
