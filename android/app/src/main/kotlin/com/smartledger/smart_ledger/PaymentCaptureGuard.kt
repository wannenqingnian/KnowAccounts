package com.smartledger.smart_ledger

/** Only financial success signals from the opt-in application allowlist. */
object PaymentCaptureGuard {
    val packages = linkedMapOf(
        "com.tencent.mm" to "微信", "com.eg.android.AlipayGphone" to "支付宝",
        "com.jingdong.app.mall" to "京东", "com.jd.jrapp" to "京东金融",
        "com.sankuai.meituan" to "美团", "com.sankuai.meituan.takeoutnew" to "美团外卖",
        "com.unionpay" to "云闪付", "com.taobao.taobao" to "淘宝",
        "com.xunmeng.pinduoduo" to "拼多多", "com.ss.android.ugc.aweme" to "抖音",
        "me.ele" to "淘宝闪购 / 饿了么", "com.sdu.didi.psnger" to "滴滴",
        "com.huawei.wallet" to "华为钱包", "com.dianping.v1" to "大众点评",
        "com.ss.android.ugc.aweme.lite" to "抖音极速版", "com.ss.android.ugc.livelite" to "抖音火山版",
        "com.ss.android.yumme.video" to "红果短剧", "com.wudaokou.hippo" to "盒马",
        "com.kuaishou.nebula" to "快手极速版", "com.smile.gifmaker" to "快手",
        "com.alibaba.wireless" to "1688", "com.taobao.idlefish" to "闲鱼",
        "com.ccb.longjiLife" to "建行生活")
    private val success = Regex("支付成功|付款成功|交易成功|消费成功|扣款成功|收款成功|到账成功|转账成功|充值成功|提现成功|自动扣款成功|你已收款|已收到|已(?:成功)?(?:支付|付款|扣款|收款)")
    private val blockedState = Regex(
        "^(?:支付失败|付款失败|交易失败|消费失败|扣款失败|" +
            "待支付|待付款|未支付|未付款|等待支付|等待付款|支付中|付款中|交易处理中|银行处理中|" +
            "已取消|交易关闭|订单关闭|退款成功|退款中|已退款|已全额退款|退款处理完成|" +
            "转账已退回|已退回|已退还|退回成功|还款成功|借款成功|放款成功)" +
            "(?:\\s*[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*元?)?(?:[，,。；;：:].{0,100})?$",
    )
    private val statusLabel = Regex("^(?:当前状态|交易状态|订单状态|支付状态|付款状态|转账状态)\\s*[:：]?\\s*(.+)$")
    private val money = Regex("[¥￥]\\s*\\d+(?:\\.\\d{1,2})?|\\d+(?:\\.\\d{1,2})?\\s*元|(?<!\\d)[+-]?\\d+\\.\\d{2}(?!\\d)")
    // Completed-payment verbs used by notification prose, not only fixed success labels.
    private val completedProse = Regex("(?:你|您)(?:已|已经)?(?:向|在).{1,80}?(?:支付|付款|消费)(?:了|成功|完成)?\\s*[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*元|(?:成功|已)(?:支付|付款|消费|扣款).{0,20}?\\d+(?:\\.\\d{1,2})?\\s*元")
    // Strong call-to-action/security copy is not a completed transaction. Keep
    // ordinary discount descriptions (立减、满减、返现) out of this list,
    // because they commonly coexist with a genuine Alipay receipt.
    private val nonTransactionNoise = Regex("领取优惠券|验证码|账单汇总|催付|(?:^|\\n)\\s*(?:领红包|抢红包)\\s*(?:$|\\n)")
    private val completedRefundState = Regex(
        "退款成功|已全额退款|退款处理完成|退款到账|已退款(?:\\s*[（(]?[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*元?[)）]?)?|" +
            "退回成功|已退回|已退还",
    )
    private val refundEvidence = Regex(
        "退款记录|退款详情|退款到账金额|已退款金额|退款金额|退款时间|退款到账时间|" +
            "(?:退款成功|已退款|已全额退款|退款到账|退回成功|已退回|已退还)\\s*[（(]?[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?",
    )
    /** A WeChat transfer card is embedded in chat and does not say "success". */
    fun wechatTransferCard(text: String): Boolean {
        val compact = text.replace(Regex("\\s+"), "")
        return compact.contains("微信转账") &&
            Regex("你发起了一笔转账|对方已收款|已收款|已退还|已退回").containsMatchIn(compact) &&
            money.containsMatchIn(text)
    }
    fun successful(packageName: String, text: String): Boolean {
        val transfer = Regex("转账成功|已转账|已收款").containsMatchIn(text)
        val wechatPeer = packageName == "com.tencent.mm" && (
            wechatTransferCard(text) ||
                Regex("红包已发出|红包发送成功|已存入零钱|领取成功").containsMatchIn(text)
            )
        val alipayPeer = packageName == "com.eg.android.AlipayGphone" &&
            Regex("支付宝红包|红包详情|红包金额").containsMatchIn(text) &&
            Regex("领取成功(?:[，,]已存入余额)?|已领取").containsMatchIn(text)
        return success.containsMatchIn(text) || completedRefund(text) || completedProse.containsMatchIn(text) || transfer ||
            wechatPeer || alipayPeer || PaymentPageRouter.appCompletedStatus(packageName, text)
    }
    fun completedRefund(text: String): Boolean = completedRefundState.containsMatchIn(text) &&
        refundEvidence.containsMatchIn(text) && money.containsMatchIn(text)
    private fun hasBlockedState(text: String): Boolean = text.lines().any { raw ->
        val line = raw.trim()
        if (line.isEmpty()) return@any false
        val labeled = statusLabel.matchEntire(line)?.groupValues?.get(1)?.trim()
        blockedState.matches(labeled ?: line)
    }
    fun trustedTitle(packageName: String, title: String): Boolean {
        val normalized = title.trim().replace(Regex("[（(]\\d+条?[）)]$"), "").trim()
        return if(packageName == "com.tencent.mm") Regex("^(微信支付|微信收款助手|支付通知|付款成功|收款到账通知|微信支付凭证|微信红包|转账通知)$").matches(normalized)
        else normalized == packages[packageName] || normalized in listOf("支付宝", "交易提醒", "交易通知", "消费通知", "付款成功", "支付成功", "支付通知", "收款通知", "扣款通知")
    }
    fun notification(packageName: String, title: String, text: String, groupSummary: Boolean) = notificationReason(packageName,title,text,groupSummary)=="matched"
    fun notificationReason(packageName: String, title: String, text: String, groupSummary: Boolean): String {
        if(packageName !in packages) return "app_disabled"
        if(groupSummary) return "group_summary"
        if(text.length>4000) return "too_long"
        if(packageName=="com.tencent.mm" && !trustedTitle(packageName,title)) return "untrusted_title"
        if(hasBlockedState(text) && !completedRefund(text)) return "state_unsupported"
        if(nonTransactionNoise.containsMatchIn(text)) return "state_unsupported"
        if(!successful(packageName, "$title\n$text")) return "success_missing"
        if(!money.containsMatchIn(text)) return "money_missing"
        return "matched"
    }
    fun receiptBody(text: String): String = text.lines().takeWhile { !Regex("^(账单服务|交易服务|其他账单服务|推荐服务|服务推荐|商家小程序|订单服务|申请退款|联系客服)").containsMatchIn(it.trim()) }.joinToString("\n")
    fun page(packageName: String, input: String) = pageReason(packageName,input)=="matched"
    fun pageReason(packageName: String, input: String): String {
        val text = receiptBody(input)
        if(packageName !in packages) return "app_disabled"
        if(text.length>4000) return "too_long"
        if(hasBlockedState(text) && !completedRefund(text)) return "state_unsupported"
        if(nonTransactionNoise.containsMatchIn(text)) return "state_unsupported"
        if(!money.containsMatchIn(text)) return "money_missing"
        if(packageName == "com.tencent.mm" && wechatTransferCard(text)) return "matched"
        val lines = text.lines().map { it.trim() }
        val commonCompleted = Regex("^(?:(?:当前状态|交易状态|订单状态|支付状态|付款状态|转账状态)\\s*[:：]?\\s*)?(支付成功|付款成功|交易成功|消费成功|扣款成功|收款成功|到账成功|转账成功|充值成功|提现成功|自动扣款成功|已支付|已付款|已扣款|已转账|已收款|你已收款|已收到|对方已收款|交易完成|支付完成|完成)(?:\\s*[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*元?)?(?:[，,。；;：:].{0,100})?$")
        val wechatCompleted = Regex("^(红包已发出|红包发送成功|已存入零钱(?:[，,]可直接消费)?|领取成功|已领取|已发出)(?:\\s*[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*元?)?$")
        val alipayCompleted = Regex("^(领取成功(?:[，,]已存入余额)?|已领取)(?:\\s*[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*元?)?$")
        val hasCompletedLine = completedRefund(text) || lines.any {
            commonCompleted.matches(it) ||
                (packageName == "com.tencent.mm" && wechatCompleted.matches(it)) ||
                (packageName == "com.eg.android.AlipayGphone" && alipayCompleted.matches(it)) ||
                PaymentPageRouter.appCompletedLine(packageName, it)
        }
        if (!hasCompletedLine) return "success_missing"
        val roles = mutableListOf("支付时间", "付款时间", "交易时间", "到账时间", "充值时间", "提现时间", "支付方式", "付款方式", "转入方式", "商户全称", "商户名称", "商户", "商家", "交易详情", "账单详情", "实付金额", "交易金额", "转账时间", "收款时间", "转账金额", "提现金额", "充值金额", "到账金额", "转账说明", "收款方", "收款人", "对方账户", "商品", "商品名称", "付款备注", "收款方备注", "到账银行卡", "收款账号", "充值方式", "退款记录", "退款详情", "退款金额", "已退款金额", "退款到账金额", "退款时间", "退款到账时间", "退款方式", "微信支付", "支付宝", "条码支付", "二维码支付", "扫码支付")
        roles += PaymentPageRouter.appFieldRoles(packageName)
        if (packageName == "com.tencent.mm" || packageName == "com.eg.android.AlipayGphone") {
            roles += listOf("红包详情", "领取详情", "红包金额", "领取时间", "发出时间")
        }
        val roleCount = roles.distinct().count { text.contains(it) }
        val peerProof = lines.any {
            Regex("^(转账成功)$").matches(it) ||
                (packageName == "com.tencent.mm" && Regex("^(.{1,40}的红包|微信红包|红包已发出|红包发送成功)$").matches(it)) ||
                (packageName == "com.eg.android.AlipayGphone" && Regex("^(支付宝红包|红包详情|领取成功(?:[，,]已存入余额)?)$").matches(it))
        }
        val hasPrice = money.containsMatchIn(text)
        return if(roleCount >= 1 || peerProof || hasPrice) "matched" else "fields_missing"
    }
    /** Stable cross-source identity used only for a short duplicate-suppression window. */
    fun semanticIdentity(packageName: String, input: String): String {
        val text = receiptBody(input)
        val order = Regex("(?:交易|转账|付款|收款|经营|订单|退款)单号\\s*[:：]?\\s*([0-9 ]{8,})")
            .find(text)?.groupValues?.get(1)?.filter(Char::isDigit)
        if (!order.isNullOrEmpty()) return "$packageName|id:$order"
        val amount = transactionAmount(text) ?: return ""
        val labeledPeer = Regex("(?:商户全称|商户名称|商户名|商家|收款方|收款人|商品名称|商品|交易说明|转账说明)\\s*[:：]?\\s*([^\\n]{1,60})")
            .find(text)?.groupValues?.get(1)
        val prosePeer = Regex("(?:你|您)(?:已|已经)?向(.{1,60}?)(?:支付|付款|转账)")
            .find(text)?.groupValues?.get(1)
        val peer = (labeledPeer ?: prosePeer ?: "").trim().replace(Regex("\\s+"), " ")
        val moment = Regex(
            "(?:支付时间|付款时间|交易时间|转账时间|收款时间|到账时间|扣款时间|创建时间)\\s*[:：]?\\s*" +
                "((?:20\\d{2}[年./-]\\d{1,2}[月./-]\\d{1,2}日?\\s*)?\\d{1,2}[:：]\\d{2}(?::\\d{2})?)",
        ).find(text)?.groupValues?.get(1)?.replace(Regex("\\s+"), " ")?.replace('：', ':')
        val scene = when {
            completedRefund(text) -> "refund"
            Regex("转账成功|已转账|转账金额|转账时间|资金待入账|转入成功|转出成功").containsMatchIn(text) -> "transfer"
            Regex("收款成功|到账成功|(?<!对方)已收款|已收到|实收金额").containsMatchIn(text) -> "income"
            else -> "expense"
        }
        return "$packageName|scene:$scene|amount:$amount|peer:$peer${moment?.let { "|time:$it" } ?: ""}"
    }
    fun replayIdentity(packageName: String, input: String): String {
        val identity = semanticIdentity(packageName, input)
        return if (identity.contains("|scene:refund|")) identity.replace(Regex("\\|peer:[^|]*"), "") else identity
    }
    fun replayWindow(identity: String): Long =
        if (identity.contains("|id:")) 48 * 60 * 60 * 1000L else 10 * 60 * 1000L
    internal fun diagnosticFields(input: String): Map<String, String> {
        val text = receiptBody(input)
        val lines = text.lines().map { it.trim() }.filter { it.isNotEmpty() }
        fun labeled(labels: String): String? {
            val pattern = Regex("^(?:$labels)\\s*[:：]?\\s*(.*)$")
            for (i in lines.indices) {
                val match = pattern.matchEntire(lines[i]) ?: continue
                val inline = match.groupValues[1].trim()
                if (inline.isNotEmpty()) return inline.take(100)
                lines.getOrNull(i + 1)?.takeIf { it.length <= 100 }?.let { return it }
            }
            return null
        }
        val amount = transactionAmount(text)
        val account = labeled("支付方式|付款方式|付款账户|扣款账户|支付账户|支付渠道|转入方式|充值方式|到账银行卡")
        val merchant = labeled("商户全称|商户名称|商户名|商家名称|商户|商家|收款方|收款人|商品名称|商品|交易说明|转账说明")
            ?: Regex("(?:你|您)(?:已|已经)?向(.{1,60}?)(?:支付|付款|转账)").find(text)?.groupValues?.get(1)?.trim()
            ?: amount?.let { value ->
                val amountLine = lines.indexOfFirst { normalizeAmount(it) == value }
                lines.getOrNull(amountLine - 1)?.takeIf {
                    it.length <= 60 && !Regex("支付成功|付款成功|交易成功|支付完成|微信支付|支付宝").matches(it)
                }
            }
        return linkedMapOf<String, String>().apply {
            amount?.let { put("amount", it) }
            merchant?.takeIf { it.isNotEmpty() }?.let { put("merchant", it) }
            account?.takeIf { it.isNotEmpty() }?.let { put("account", it) }
        }
    }
    /**
     * Picks a transaction amount by field role instead of the first number on
     * screen. A receipt can contain original price, discount, balance and the
     * actual payment at the same time. Conflicting values at the same priority
     * return no identity so duplicate suppression fails open.
     */
    internal fun transactionAmount(text: String): String? {
        val roles = if (completedRefund(text)) {
            listOf("退款到账金额", "已退款金额", "退款金额", "已退款", "退款成功")
        } else {
            listOf(
                "实付金额", "实际支付", "实际付款", "实付款", "实付", "付款金额", "支付金额",
                "扣款金额", "到账金额", "转账金额", "提现金额", "充值金额", "红包金额",
                "实收金额", "应付金额", "应收金额", "交易金额", "消费金额", "合计", "总计",
            )
        }
        val valuePattern = "[¥￥]?\\s*[+\\-−－–—]?\\s*(\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.(\\d{1,2}))?\\s*元?"
        for (role in roles) {
            val pattern = Regex(
                "(?:^|\\n)\\s*${Regex.escape(role)}\\s*[:：()（）]?\\s*(?:\\n\\s*)?($valuePattern)(?=\\s*(?:\\n|$|[，,。；;]))",
            )
            val values = pattern.findAll(text).mapNotNull { normalizeAmount(it.groupValues[1]) }.toSet()
            if (values.size == 1) return values.single()
            if (values.size > 1) return null
        }
        val standalone = Regex("(?m)^\\s*([+\\-−－–—]?\\s*(?:[¥￥]\\s*)?\\d[\\d,]*(?:\\.\\d{1,2})?\\s*(?:元)?)\\s*$")
            .findAll(text).mapNotNull { normalizeAmount(it.groupValues[1]) }.toSet()
        if (standalone.size == 1) return standalone.single()
        val all = money.findAll(text).mapNotNull { normalizeAmount(it.value) }.toSet()
        return all.singleOrNull()
    }
    private fun normalizeAmount(value: String): String? {
        val plain = value.replace(Regex("[¥￥元,\\s+\\-−－–—]"), "")
        val decimal = plain.toBigDecimalOrNull()?.abs() ?: return null
        if (decimal.scale() > 2) return null
        return decimal.setScale(2).toPlainString()
    }
    /**
     * Order numbers identify a transaction globally. Amount/peer fallbacks only
     * identify one visible payment-page occurrence: two real transfers may have
     * the same amount and recipient.
     */
    fun occurrenceIdentity(identity: String, occurrence: String): String = when {
        identity.contains("|id:") -> identity
        occurrence.isBlank() -> identity
        else -> "$identity|occ:$occurrence"
    }
    /** Distinguishes a newly appended WeChat card without reading chat prose. */
    fun wechatCardOccurrence(input: String): String {
        val cards = Regex("你发起了一笔转账|对方已收款|已收款").findAll(input).count()
        val clock = Regex("(?<!\\d)([01]?\\d|2[0-3])[:：]([0-5]\\d)(?!\\d)")
            .findAll(input).lastOrNull()?.value ?: ""
        return "cards:$cards|clock:$clock"
    }
    fun redact(text: String): String = text.replace(Regex("(?<![0-9０-９])(?:[0-9０-９][ \\t-]?){12,}[0-9０-９](?![0-9０-９])")) {
        val digits = it.value.filter { c -> c in '0'..'9' || c in '０'..'９' }.map { c -> if (c in '０'..'９') ('0'.code + c.code - '０'.code).toChar() else c }.joinToString("")
        "尾号 ${digits.takeLast(4)}"
    }
}
