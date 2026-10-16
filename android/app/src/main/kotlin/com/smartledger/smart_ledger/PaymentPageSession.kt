package com.smartledger.smart_ledger

/**
 * Keeps the small amount of cross-event state needed by payment pages.
 *
 * Payment applications commonly publish the page class, amount and result in
 * separate accessibility events. This object retains only bounded, de-duplicated
 * text from an enabled payment application and expires it quickly. It never owns
 * AccessibilityNodeInfo instances or performs actions on the source application.
 */
class PaymentPageSession {
    data class Assessment(
        val text: String,
        val route: String,
        val reason: String,
        val matched: Boolean,
        val shouldRetry: Boolean,
        val shouldOcr: Boolean,
        val attempt: Int,
    )

    companion object {
        private const val SESSION_TTL_MS = 12_000L
        private const val RETRY_WINDOW_MS = 2_200L
        private const val MAX_LINES = 120
        private const val MAX_CHARS = 4_000
    }

    private var packageName = ""
    private var pageClass = ""
    private var route = "unknown"
    private var startedAt = 0L
    private var lastEventAt = 0L
    private var active = false
    private var attempts = 0
    private var passiveWechatEvents = 0
    private var charCount = 0
    private val lines = linkedSetOf<String>()

    fun observe(pkg: String, cls: String, values: List<String>, now: Long): Boolean {
        if (pkg != packageName || now - lastEventAt > SESSION_TTL_MS) reset()
        packageName = pkg
        lastEventAt = now
        val incomingClass = cls.ifBlank { pageClass }
        val eventText = PaymentPageRouter.clean(values).joinToString("\n")
        val eventRoute = PaymentPageRouter.route(pkg, incomingClass, eventText)
        val financialClass = PaymentPageRouter.isFinancialClass(pkg, incomingClass)
        val signal = financialClass ||
            PaymentPageRouter.hasFinancialSignal(pkg, eventText)
        // A payment flow often changes Activity while fields are being rendered,
        // so financial-to-financial transitions keep their fragments. Returning
        // to a chat/home/unrelated page is different: discard the old receipt
        // before the new page can accidentally complete it.
        val leftFinancialFlow = active && pageClass.isNotBlank() &&
            incomingClass.isNotBlank() && incomingClass != pageClass &&
            !financialClass && !PaymentPageRouter.hasFinancialSignal(pkg, eventText)
        if (leftFinancialFlow) {
            reset()
            packageName = pkg
            lastEventAt = now
        }
        if (incomingClass.isNotBlank()) pageClass = incomingClass
        if (signal || active) {
            if (!active) startedAt = now
            active = true
            if (eventRoute != "unknown" && eventRoute != "chat") route = eventRoute
            append(values)
        } else if (pkg == "com.tencent.mm" && PaymentPageRouter.isChatClass(pkg, pageClass)) {
            // Some WeChat versions expose a transfer card only as pixels. Two
            // consecutive chat events may request one strictly validated OCR frame.
            passiveWechatEvents = (passiveWechatEvents + 1).coerceAtMost(3)
        }
        return active || (pkg == "com.tencent.mm" && PaymentPageRouter.isChatClass(pkg, pageClass))
    }

    fun assess(rootValues: List<String>, now: Long): Assessment {
        if (lastEventAt == 0L || now - lastEventAt > SESSION_TTL_MS) {
            reset()
            return Assessment("", "unknown", "empty_content", false, false, false, 0)
        }
        val root = PaymentPageRouter.clean(rootValues)
        val rootText = root.joinToString("\n")
        if (!active && (PaymentPageRouter.isFinancialClass(packageName, pageClass) ||
                PaymentPageRouter.hasFinancialSignal(packageName, rootText))) {
            active = true
            startedAt = now
        }
        if (active) append(root)
        attempts++
        val text = PaymentCaptureGuard.receiptBody(lines.joinToString("\n"))
        val currentRoute = PaymentPageRouter.route(packageName, pageClass, text)
        if (currentRoute != "unknown" && currentRoute != "chat") route = currentRoute
        val reason = PaymentCaptureGuard.pageReason(packageName, text)
        val matched = reason == "matched"
        val partial = reason in setOf("empty_content", "money_missing", "success_missing", "fields_missing")
        val age = if (startedAt == 0L) 0L else now - startedAt
        val retry = active && partial && attempts < 4 && age < RETRY_WINDOW_MS
        val ocr = !matched && partial && !retry && (
            active || (packageName == "com.tencent.mm" && passiveWechatEvents >= 2)
        )
        return Assessment(text, route, reason, matched, retry, ocr, attempts)
    }

    fun complete() = reset()

    fun reset() {
        packageName = ""
        pageClass = ""
        route = "unknown"
        startedAt = 0L
        lastEventAt = 0L
        active = false
        attempts = 0
        passiveWechatEvents = 0
        charCount = 0
        lines.clear()
    }

    private fun append(values: List<String>) {
        for (line in PaymentPageRouter.clean(values)) {
            if (lines.size >= MAX_LINES || charCount + line.length + 1 > MAX_CHARS) break
            if (lines.add(line)) charCount += line.length + 1
        }
    }
}

/** Package and page routing derived from shipped payment-page behavior. */
object PaymentPageRouter {
    private data class Profile(
        val route: String,
        val classes: List<String>,
        val completed: List<String> = emptyList(),
        val fields: List<String> = emptyList(),
    )

    private val wechatPaymentClasses = listOf(
        "MMWebViewUI", "WebViewUI", "UIPageFragmentActivity", "RemittanceBusiUI",
        "RemittanceUI", "WalletOfflineCoinPurseUI", "WalletBrandUI",
        "LuckyMoneyPrepareUI", "LuckyMoneyDetailUI", "LuckyMoneyNotHookReceiveUI",
        "OrderHandlerUI", "RemittanceDetailUI", "WalletOrderInfoNewUI", "PaylistAAUI",
        "AppBrandUI", "BaseScanUI",
    )
    /*
     * Static page families observed in the independently analysed reference APK.
     * They are only routing hints: a page still needs amount + completed state +
     * transaction fields in PaymentCaptureGuard before it can become a draft.
     */
    private val profiles = mapOf(
        "com.eg.android.AlipayGphone" to Profile("alipay", listOf(
            "MspContainerActivity", "MspUniRenderActivity", "SnsCouponDetailActivity",
            "NfcPayActivity", "NResPageActivity", "MainCaptureActivity", "OnsitepayActivity",
            "SchemeLauncherActivity", "PayResultActivity",
        ), listOf(
            "代付成功", "亲情卡付款成功", "免密支付成功", "自动续费成功", "支付宝小荷包付款成功",
            "自动扣款成功", "充值成功", "提现成功", "资金待入账", "转入成功", "转出成功", "成功转入", "成功转出",
        ), listOf("实付金额", "订单金额", "提现金额", "红包金额", "付款方式", "交易方式", "到账账户", "到账银行卡", "对方账户", "收款方", "付款备注", "转账备注", "创建时间", "支付时间", "收款时间")),
        "com.jingdong.app.mall" to Profile("jd", listOf(
            "CounterActivity", "CashierUserContentCompletePopActivity", "CashierCompleteActivity",
            "JDPayActivity", "CashierPayActivity", "NewFillOrderActivity", "PopupNewFillOrderActivity",
            "JDReactNativeCommonActivity", "WebActivity",
        ), fields = listOf("实付", "商品名称", "交易说明", "收款方", "支付方式", "创建时间", "退款至")),
        "com.jd.jrapp" to Profile("jd_finance", listOf("JRCustomDyPageActivity"),
            fields = listOf("实付", "交易说明", "收款方", "支付方式", "创建时间", "退款至")),
        "com.sankuai.meituan" to Profile("meituan", listOf(
            "MRNBaseActivity", "MRNStandardActivity", "EHContainerActivity", "PaySeatActivity",
            "HTMRNBaseActivity", "neo.loading",
        ), listOf("先用后付自动扣款成功"), listOf("支付成功 ¥", "交易成功 ¥", "合计", "支付方式", "交易时间", "创建时间", "下单时间", "退款至")),
        "com.sankuai.meituan.takeoutnew" to Profile("meituan_takeout", listOf(
            "OrderConfirmActivity", "OrderConfirmNoTransActivity", "MRNBaseActivity", "MRNStandardActivity", "EHContainerActivity",
        ), listOf("先用后付自动扣款成功"), listOf("支付成功 ¥", "交易成功 ¥", "合计", "支付方式", "交易时间", "创建时间", "下单时间", "退款至")),
        "com.dianping.v1" to Profile("dianping", listOf(
            "OrderConfirmActivity", "MRNBaseActivity", "MRNStandardActivity", "EHContainerActivity", "PaySeatActivity", "HTMRNBaseActivity",
        ), fields = listOf("支付成功 ¥", "交易成功 ¥", "合计", "支付方式", "交易时间", "创建时间", "下单时间", "退款至")),
        "com.taobao.taobao" to Profile("taobao", listOf(
            "UltronTradeHybridActivity", "TBBuyActivity", "StdPopContainerActivity", "TMSActivity", "SkuDialogFragment",
        ), listOf("免密支付成功", "下单成功，等待商家接单", "下单成功，商家已接单", "下单成功，商家正在备餐", "下单成功，商家备餐中", "下单成功，商家备货完成"),
            listOf("实付价", "合计", "免密支付", "确认付款", "支付宝")),
        "com.taobao.idlefish" to Profile("xianyu", listOf("FishFlutterBoostActivity"),
            fields = listOf("现价", "支付方式")),
        "com.alibaba.wireless" to Profile("1688", listOf("AliWindvaneActivity", "PopPageWindow"),
            fields = listOf("立即支付", "确认订单", "提交订单", "有限公司")),
        "com.xunmeng.pinduoduo" to Profile("pinduoduo", listOf(
            "NewPageActivity", "sku_checkout", "android.webkit.WebView",
        ), listOf("拼单成功", "已支付", "免拼成功"), listOf("支付方式", "支付时间", "当前状态", "交易单号", "已选", "已选择")),
        "me.ele" to Profile("eleme", listOf("WMCheckoutActivity", "RetailSubmitActivity", "ShopDetailV2Activity"),
            listOf("下单成功，等待商家接单", "下单成功，商家已接单", "下单成功，商家正在备餐", "下单成功，商家备餐中", "下单成功，商家备货完成"),
            listOf("提交订单", "已选", "点餐", "评价")),
        "com.wudaokou.hippo" to Profile("hema", listOf("PayCodeActivity"),
            fields = listOf("支付成功：¥", "优先使用此付款方式")),
        "com.huawei.wallet" to Profile("huawei_wallet", listOf(
            "SwipeResultActivity", "UnCardTransRecordDetailActivity", "BillDetailInfoActivity",
            "ScanQrCodePayResultActivity", "PaymentCodeActivity", "SwipeActivity",
        ), fields = listOf("商家", "商品名称", "付款方式", "付款银行", "交易时间", "日期", "二维码付款码")),
        "com.ccb.longjiLife" to Profile("ccb_life", listOf(
            "CodeResultActivity", "TransactionsDetailActivity", "CodeActivity", "WebViewActivity",
        ), fields = listOf("商户名", "商户名称", "商品名称", "支付方式", "交易时间", "订单号", "优先选择此方式支付")),
        "com.unionpay" to Profile("unionpay", listOf(
            "UPActivityScan", "UPActivityPaymentQrCodeOut",
        ), listOf("转出成功"), listOf("实付金额（元）", "实收金额（元）", "支出金额", "收入金额", "订单金额", "转账金额", "商户名称", "付款卡", "收款卡", "付款银行", "收款银行", "交易时间", "扣款时间", "订单时间")),
        "com.smile.gifmaker" to Profile("kuaishou", listOf(
            "MerchantEraActivity", "MerchantPurchasePanelContainerV2Activity", "KwaiRnActivity",
            "MerchantContentDetailActivity", "MerchantKwaiDialog", "MerchantInterceptOutsideTouchDialog",
        ), listOf("购买成功"), listOf("立即支付", "免密支付", "实付", "门店通用", "关注", "进店")),
        "com.kuaishou.nebula" to Profile("kuaishou_lite", listOf(
            "MerchantEraActivity", "MerchantPurchasePanelContainerV2Activity", "KwaiRnActivity",
            "MerchantContentDetailActivity", "MerchantKwaiDialog", "MerchantInterceptOutsideTouchDialog",
        ), listOf("购买成功"), listOf("立即支付", "免密支付", "实付", "门店通用", "关注", "进店")),
        "com.ss.android.ugc.aweme" to Profile("douyin", listOf(
            "DyPayETActivity", "DyPayStandardActivity", "CJPaySecurityLoadingActivity",
            "CJPayCommonDialog", "BuyNowFullscreenActivity", "BuyNowFullscreenDialog", "FixedDialog", "BulletContainerActivity", "LynxOverlayDialog", "LiveDummyActivity",
        ), listOf("购买成功", "自动付款成功", "入账成功"), listOf("实付", "实付价", "支付方式", "交易方式", "支付时间", "创建时间", "到账方式", "到账时间", "充值方式", "充值时间", "还款方式", "还款时间")),
        "com.ss.android.ugc.aweme.lite" to Profile("douyin_lite", listOf(
            "DyPayETActivity", "DyPayStandardActivity", "CJPaySecurityLoadingActivity", "CJPayCommonDialog", "BulletContainerActivity", "FixedDialog",
        ), listOf("购买成功", "自动付款成功", "入账成功"), listOf("实付", "实付价", "支付方式", "交易方式", "支付时间", "创建时间", "到账方式", "到账时间", "充值方式", "充值时间")),
        "com.ss.android.ugc.livelite" to Profile("douyin_volcano", listOf(
            "DyPayETActivity", "DyPayStandardActivity", "CJPaySecurityLoadingActivity", "CJPayCommonDialog", "BulletContainerActivity", "FixedDialog",
        ), listOf("购买成功", "自动付款成功", "入账成功"), listOf("实付", "实付价", "支付方式", "交易方式", "支付时间", "创建时间", "到账方式", "到账时间", "充值方式", "充值时间")),
        "com.ss.android.yumme.video" to Profile("hongguo", listOf(
            "DyPayETActivity", "DyPayStandardActivity", "CJPaySecurityLoadingActivity", "CJPayCommonDialog", "BulletContainerActivity", "FixedDialog",
        ), listOf("购买成功", "自动付款成功", "入账成功"), listOf("实付", "实付价", "支付方式", "交易方式", "支付时间", "创建时间", "到账方式", "到账时间", "充值方式", "充值时间")),
    )
    private val genericPaymentClass = Regex(
        "(?:Pay|Cashier|Checkout|Trade|Transaction|Wallet|Bill|Receipt|Order|Result)",
        RegexOption.IGNORE_CASE,
    )
    private val commonFinancialSignal = Regex(
        "支付成功|付款成功|交易成功|消费成功|扣款成功|收款成功|到账成功|" +
            "当前状态|交易状态|账单详情|交易详情|付款方式|支付方式|实付金额|交易金额|" +
            "交易单号|转账单号|付款单号|收款单号|转账成功|转账时间|收款时间|" +
            "转账金额|提现金额|充值金额|到账金额",
    )
    private val wechatFinancialSignal = Regex(
        "你发起了一笔转账|对方已收款|微信转账|红包详情|红包已发出|已存入零钱|二维码收款",
    )

    fun clean(values: List<String>): List<String> = values.asSequence()
        .flatMap { it.lines().asSequence() }
        .map { it.trim() }
        .filter { it.isNotEmpty() && it.length <= 300 }
        .distinct()
        .toList()

    fun hasFinancialSignal(pkg: String, text: String): Boolean =
        commonFinancialSignal.containsMatchIn(text) ||
            (pkg == "com.tencent.mm" && wechatFinancialSignal.containsMatchIn(text)) ||
            profiles[pkg]?.completed?.any(text::contains) == true

    fun appCompletedStatus(pkg: String, text: String): Boolean =
        profiles[pkg]?.completed?.any(text::contains) == true

    fun appFieldRoles(pkg: String): List<String> = profiles[pkg]?.fields.orEmpty()

    fun appCompletedLine(pkg: String, line: String): Boolean {
        val value = line.trim().replace(Regex("^(?:当前状态|交易状态)\\s*[:：]?\\s*"), "")
        return profiles[pkg]?.completed?.any { status ->
            Regex("^${Regex.escape(status)}(?:\\s*[¥￥]?\\s*\\d+(?:\\.\\d{1,2})?\\s*元?)?(?:[，,。；;：:].{0,100})?$").matches(value)
        } == true
    }

    fun isChatClass(pkg: String, cls: String): Boolean = pkg == "com.tencent.mm" &&
        Regex("Chatting|Conversation|LauncherUI", RegexOption.IGNORE_CASE).containsMatchIn(cls)

    fun isFinancialClass(pkg: String, cls: String): Boolean {
        if (cls.isBlank()) return false
        if (pkg == "com.tencent.mm") return wechatPaymentClasses.any { cls.contains(it) }
        val profile = profiles[pkg]
        if (profile != null) return profile.classes.any { cls.contains(it, ignoreCase = true) }
        // Didi is supported by the allowlist but was absent from the analysed
        // reference routing table, so retain a narrow class-name fallback only.
        return pkg == "com.sdu.didi.psnger" && genericPaymentClass.containsMatchIn(cls)
    }

    fun route(pkg: String, cls: String, text: String): String {
        if (pkg != "com.tencent.mm") {
            val profile = profiles[pkg]
            if (profile == null) {
                return if (isFinancialClass(pkg, cls) || hasFinancialSignal(pkg, text)) "payment" else "unknown"
            }
            if (!isFinancialClass(pkg, cls) && !hasFinancialSignal(pkg, text)) return "unknown"
            if (pkg == "com.eg.android.AlipayGphone") {
                return when {
                    cls.contains("SnsCouponDetailActivity") || Regex("支付宝红包|红包详情").containsMatchIn(text) -> "alipay_red_packet"
                    Regex("转账成功|转账金额|转账时间|支付宝转账").containsMatchIn(text) -> "alipay_transfer"
                    else -> profile.route
                }
            }
            return profile.route
        }
        return when {
            cls.contains("PaylistAAUI") || text.contains("群收款") -> "group_collection"
            cls.contains("LuckyMoney") || text.contains("红包") -> "red_packet"
            cls.contains("Remittance") || text.contains("微信转账") || text.contains("转账单号") -> "transfer"
            cls.contains("WalletOrderInfo") || text.contains("账单详情") || text.contains("交易单号") -> "receipt"
            cls.contains("BaseScanUI") -> "scanner"
            wechatPaymentClasses.any { cls.contains(it) } || hasFinancialSignal(pkg, text) -> "payment"
            isChatClass(pkg, cls) -> "chat"
            else -> "unknown"
        }
    }
}
