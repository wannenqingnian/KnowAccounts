package com.smartledger.smart_ledger

/**
 * Converts explicit accessibility structure into field/value lines.
 *
 * Raw resource IDs are never persisted. Only a small allowlist of semantic ID
 * suffixes and label/sibling pairs becomes canonical receipt text; unknown IDs
 * remain ordinary visible text and cannot invent a financial field.
 */
object PaymentFieldHints {
    private val commonRoles = setOf(
        "退款到账金额", "已退款金额", "退款金额", "实付金额", "实际支付", "实际付款", "实付款", "实付",
        "付款金额", "支付金额", "扣款金额", "到账金额", "转账金额", "提现金额", "充值金额", "红包金额",
        "实收金额", "应付金额", "应收金额", "交易金额", "消费金额", "合计", "总计", "金额",
        "商户全称", "商户名称", "商家名称", "商户", "商家", "收款方", "收款人", "对方账户", "商品名称",
        "支付方式", "付款方式", "付款账户", "扣款账户", "支付账户", "支付渠道", "转入方式", "充值方式", "到账银行卡",
        "退款到账时间", "退款时间", "支付时间", "付款时间", "扣款时间", "到账时间", "转账时间", "收款时间",
        "提现时间", "充值时间", "交易时间", "创建时间", "下单时间", "订单时间",
        "交易单号", "支付单号", "付款单号", "收款单号", "转账单号", "订单号", "商户单号",
    )
    private val amount = Regex("[¥￥]?\\s*[+\\-−－–—]?\\s*\\d[\\d,]*(?:\\.\\d{1,2})?\\s*元?")
    private val navigation = Regex("^(?:成功|完成|返回|关闭|首页|主页|查看订单|账单详情|交易详情)$")

    fun sibling(packageName: String, label: String?, value: String?): String? {
        val role = label?.trim()?.trimEnd(':', '：') ?: return null
        val fieldValue = value?.trim()?.takeIf { it.isNotEmpty() && it.length <= 160 } ?: return null
        val roles = commonRoles + PaymentPageRouter.appFieldRoles(packageName)
        if (role !in roles || role == fieldValue || navigation.matches(fieldValue)) return null
        if (isAmountRole(role) && !amount.matches(fieldValue)) return null
        return "$role $fieldValue"
    }

    fun fromViewId(viewId: String?, value: String?): String? {
        val fieldValue = value?.trim()?.takeIf { it.isNotEmpty() && it.length <= 160 } ?: return null
        val raw = viewId?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: return null
        val token = raw.replace(Regex("([a-z0-9])([A-Z])"), "$1_$2").lowercase()
        val role = when {
            Regex("^(?:refund|refunded|refund_arrival)_amount(?:_text|_value)?$").matches(token) -> "退款金额"
            Regex("^(?:actual|real|paid|pay|payment)_amount(?:_text|_value)?$").matches(token) -> "实付金额"
            Regex("^(?:trade|transaction)_amount(?:_text|_value)?$").matches(token) -> "交易金额"
            Regex("^(?:merchant|shop|payee)_name(?:_text|_value)?$").matches(token) -> "商户名称"
            Regex("^(?:payment|pay)_(?:method|tool)(?:_text|_value)?$").matches(token) -> "付款方式"
            Regex("^(?:trade|transaction|payment|pay)_time(?:_text|_value)?$").matches(token) -> "交易时间"
            Regex("^(?:trade|transaction|order|payment)_id(?:_text|_value)?$").matches(token) -> "交易单号"
            else -> return null
        }
        if (isAmountRole(role) && !amount.matches(fieldValue)) return null
        return "$role $fieldValue"
    }

    private fun isAmountRole(role: String): Boolean =
        role.contains("金额") || role in setOf("实付", "合计", "总计", "现价") || role.contains('¥') || role.contains('￥')
}
