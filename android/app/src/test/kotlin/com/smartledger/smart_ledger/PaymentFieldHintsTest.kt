package com.smartledger.smart_ledger

import org.junit.Assert.*
import org.junit.Test

class PaymentFieldHintsTest {
    @Test fun explicitSiblingFieldsAreCombinedButNavigationAndInvalidMoneyAreRejected() {
        assertEquals(
            "实付金额 ¥18.00",
            PaymentFieldHints.sibling("com.tencent.mm", "实付金额", "¥18.00"),
        )
        assertEquals(
            "支付方式 招商银行储蓄卡(1234)",
            PaymentFieldHints.sibling("com.tencent.mm", "支付方式：", "招商银行储蓄卡(1234)"),
        )
        assertNull(PaymentFieldHints.sibling("com.tencent.mm", "实付金额", "订单号1234"))
        assertNull(PaymentFieldHints.sibling("com.tencent.mm", "商户名称", "返回"))
        assertNull(PaymentFieldHints.sibling("com.tencent.mm", "验证码", "123456"))
    }

    @Test fun onlyAllowlistedResourceIdsBecomeCanonicalFields() {
        assertEquals(
            "退款金额 ¥12.93",
            PaymentFieldHints.fromViewId("com.example:id/refundAmountValue", "¥12.93"),
        )
        assertEquals(
            "商户名称 某便利店",
            PaymentFieldHints.fromViewId("com.example:id/merchant_name", "某便利店"),
        )
        assertNull(PaymentFieldHints.fromViewId("com.example:id/balance_amount", "¥999.00"))
        assertNull(PaymentFieldHints.fromViewId("com.example:id/password", "123456"))
    }
}
