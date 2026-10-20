package com.smartledger.smart_ledger
import org.junit.Assert.*
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Locale
class PaymentCaptureGuardTest {
    private val receipt = "交易详情\n精品沙县小吃\n-16.00\n支付成功\n支付时间\n2026年10月03日 12:05:15\n支付方式\n零钱"
    @Test fun knownAppSuccessIsCandidateButForeignOrGroupIsNot() {
        assertEquals(23, PaymentCaptureGuard.packages.size)
        for (pkg in PaymentCaptureGuard.packages.keys) {
            assertTrue(PaymentCaptureGuard.notification(pkg, "微信支付", "支付成功，商户名称 瑞幸咖啡，交易金额38.50元", false))
            assertTrue(PaymentCaptureGuard.page(pkg, receipt))
        }
        assertFalse(PaymentCaptureGuard.page("com.evil.fake", receipt))
        assertFalse(PaymentCaptureGuard.notification("com.tencent.mm", "微信支付", "支付成功 38.50元", true))
    }
    @Test fun wechatChatAndPromotionAndUnfinishedAreNotCandidates() {
        assertFalse(PaymentCaptureGuard.notification("com.tencent.mm", "张三", "我支付成功了38.50元", false))
        for (text in listOf("支付成功 38.50元 领取优惠券", "支付成功 38.50元 验证码123456", "待支付38.50元", "支付失败38.50元", "退款中38.50元", "还款成功38.50元")) {
            assertFalse(text, PaymentCaptureGuard.notification("com.eg.android.AlipayGphone", "支付宝", text, false))
        }
        assertTrue(PaymentCaptureGuard.notification(
            "com.eg.android.AlipayGphone", "支付宝", "退款成功38.50元", false,
        ))
    }
    @Test fun titleMayProvideSuccessButBodyMustContainActualMoney() {
        assertTrue(PaymentCaptureGuard.notification("com.jingdong.app.mall", "付款成功", "商户名称：京东，金额：38.50元", false))
        assertFalse(PaymentCaptureGuard.notification("com.jingdong.app.mall", "付款成功", "订单号1234567890123456", false))
    }
    @Test fun pageRequiresStandaloneSuccessAndAtLeastTwoTransactionFieldRoles() {
        assertFalse(PaymentCaptureGuard.page("com.tencent.mm", "我支付成功了38.50元\n支付方式 微信\n交易详情"))
        assertFalse(PaymentCaptureGuard.page("com.tencent.mm", "支付成功\n38.50元\n主页"))
        assertFalse(PaymentCaptureGuard.page("com.tencent.mm", receipt.replace("支付成功", "支付失败")))
    }
    @Test fun actionFooterDoesNotTurnCompletedPurchaseIntoRefund() {
        assertTrue(PaymentCaptureGuard.page("com.taobao.taobao", "$receipt\n交易服务\n申请退款\n优惠券"))
        assertEquals(receipt, PaymentCaptureGuard.receiptBody("$receipt\n交易服务\n申请退款"))
    }
    @Test fun redactLongIdentifiersPreservesMoneyAndDatesAndLastFour() {
        val text = PaymentCaptureGuard.redact("交易单号4500000432202610038589325\n支付时间2026年10月03日\n银行卡4111 1111 1111 1111\n金额16.00元")
        assertFalse(text.contains("4500000432202610038589325"))
        assertFalse(text.contains("4111 1111"))
        assertTrue(text.contains("尾号 1111")); assertTrue(text.contains("16.00元")); assertTrue(text.contains("2026年10月03日"))
    }
    @Test fun completedWechatProseAndInlineStatusAreAcceptedWithoutFixedSuccessPhrase() {
        assertTrue(PaymentCaptureGuard.notification("com.tencent.mm", "微信支付（2条）", "你向精品沙县小吃付款16.00元", false))
        assertTrue(PaymentCaptureGuard.notification("com.tencent.mm", "微信支付", "您在瑞幸咖啡消费了38.50元", false))
        assertFalse(PaymentCaptureGuard.notification("com.tencent.mm", "张三", "你向精品沙县小吃付款16.00元", false))
        assertTrue(PaymentCaptureGuard.page("com.tencent.mm", receipt.replace("支付成功", "当前状态：支付成功")))
    }
    @Test fun transfersAndRedPacketsRequireFinancialDetailScreenAndCompletedStatus() {
        assertTrue(PaymentCaptureGuard.page("com.tencent.mm", "转账成功\n16.00元\n收款方 张三\n转账时间 2026年10月05日"))
        assertTrue(PaymentCaptureGuard.page("com.tencent.mm", "红包详情\n-16.00\n红包已发出"))
        assertTrue(PaymentCaptureGuard.page("com.tencent.mm", "张三的红包\n16.00元\n已存入零钱，可直接消费"))
        assertFalse(PaymentCaptureGuard.page("com.tencent.mm", "转账时间 昨天\n16.00元\n等待付款"))
        assertFalse(PaymentCaptureGuard.page("com.tencent.mm", "领取优惠券\n红包已发出\n红包详情\n16.00元"))
        assertFalse(PaymentCaptureGuard.page("com.eg.android.AlipayGphone", "红包已发出\n红包详情\n16.00元"))
        assertTrue(PaymentCaptureGuard.page("com.eg.android.AlipayGphone", "支付宝红包\n红包金额 16.00元\n领取成功，已存入余额"))
        assertTrue(PaymentCaptureGuard.page("com.eg.android.AlipayGphone", "交易详情\n支付宝红包主题餐厅\n-16.00\n支付成功\n支付方式 余额\n优惠 支付宝红包"))
    }
    @Test fun alipayTransferIgnoresAdvisoryRefundAndPromotionText() {
        val completed = "支付宝转账\n-0.01\n转账成功，对方预计即时到账\n收款方 张三\n" +
            "转账时间 2026年10月09日 22:10:30\n对方未收款时资金将原路退回\n退款说明\n立减优惠"
        assertEquals("matched", PaymentCaptureGuard.pageReason("com.eg.android.AlipayGphone", completed))
        assertTrue(PaymentCaptureGuard.page(
            "com.eg.android.AlipayGphone",
            "支付宝转账\n0.01元\n资金待入账\n对方账户 张三\n转账时间 2026年10月09日",
        ))
        assertEquals(
            "state_unsupported",
            PaymentCaptureGuard.pageReason(
                "com.eg.android.AlipayGphone",
                "支付宝转账\n0.01元\n当前状态 转账已退回\n转账时间 2026年10月09日",
            ),
        )
        assertTrue(PaymentCaptureGuard.notification(
            "com.eg.android.AlipayGphone",
            "支付宝",
            "转账成功0.01元，立减优惠已到账；未收款时将原路退回",
            false,
        ))
    }
    @Test fun alipayAssetOperationsUseTheirOwnCompletedStatesAndAmountRoles() {
        assertEquals(
            "matched",
            PaymentCaptureGuard.pageReason(
                "com.eg.android.AlipayGphone",
                "结果详情\n提现成功\n提现金额 88.00元\n到账银行卡 招商银行尾号1234\n提现时间 2026年10月09日",
            ),
        )
        assertEquals(
            "matched",
            PaymentCaptureGuard.pageReason(
                "com.eg.android.AlipayGphone",
                "充值成功\n充值金额 20.00元\n充值方式 招商银行尾号1234\n充值时间 2026年10月09日",
            ),
        )
    }
    @Test fun sourceSpecificCompletionAndFieldPairsAreAcceptedForEveryAdapterFamily() {
        val samples = mapOf(
            "com.eg.android.AlipayGphone" to ("代付成功" to "到账银行卡 招商银行尾号1234"),
            "com.jingdong.app.mall" to ("付款成功" to "商品名称 京东自营"),
            "com.jd.jrapp" to ("交易成功" to "交易说明 京东商城"),
            "com.sankuai.meituan" to ("先用后付自动扣款成功" to "下单时间 2026年10月12日"),
            "com.sankuai.meituan.takeoutnew" to ("支付成功" to "合计 16.00元"),
            "com.dianping.v1" to ("支付成功" to "创建时间 2026年10月12日"),
            "com.taobao.taobao" to ("免密支付成功" to "实付价 16.00元"),
            "com.taobao.idlefish" to ("支付成功" to "现价16.00元"),
            "com.alibaba.wireless" to ("付款成功" to "某某有限公司"),
            "com.xunmeng.pinduoduo" to ("拼单成功" to "已选择：商品"),
            "me.ele" to ("下单成功，商家已接单" to "提交订单"),
            "com.wudaokou.hippo" to ("支付成功" to "优先使用此付款方式 盒马礼品卡"),
            "com.huawei.wallet" to ("交易成功" to "付款银行 招商银行"),
            "com.ccb.longjiLife" to ("支付成功" to "商户名 瑞幸咖啡"),
            "com.unionpay" to ("支付成功" to "实付金额（元） 16.00"),
            "com.smile.gifmaker" to ("购买成功" to "立即支付16.00元"),
            "com.kuaishou.nebula" to ("购买成功" to "门店通用"),
            "com.ss.android.ugc.aweme" to ("购买成功" to "实付16.00元"),
            "com.ss.android.ugc.aweme.lite" to ("自动付款成功" to "到账方式 抖音支付"),
            "com.ss.android.ugc.livelite" to ("入账成功" to "充值方式 抖音支付"),
            "com.ss.android.yumme.video" to ("支付成功" to "实付价 16.00元"),
        )
        assertEquals(21, samples.size)
        for ((pkg, sample) in samples) {
            val text = "${sample.first}\n16.00元\n${sample.second}"
            assertEquals("$pkg\n$text", "matched", PaymentCaptureGuard.pageReason(pkg, text))
        }
    }
    @Test fun wechatChatTransferCardIsReviewableWithoutSuccessLabel() {
        val card = "¥0.01\n你发起了一笔转账\n微信转账"
        assertTrue(PaymentCaptureGuard.wechatTransferCard(card))
        assertEquals("matched", PaymentCaptureGuard.pageReason("com.tencent.mm", card))
        assertFalse(PaymentCaptureGuard.wechatTransferCard("你发起了一笔转账\n微信转账"))
        assertFalse(PaymentCaptureGuard.wechatTransferCard("¥0.01\n普通聊天文字\n微信转账"))
        assertEquals("state_unsupported", PaymentCaptureGuard.pageReason("com.tencent.mm", "¥0.01\n转账已退回\n微信转账"))
    }
    @Test fun semanticIdentityPrefersOrderNumberAndFallsBackToAmountAndPeer() {
        val withOrder = "支付成功\n16.00元\n交易单号 4500000432202610038589325\n商户名称 精品沙县小吃"
        val fromOcr = "支付成功\n￥16.00\n交易单号：4500000432202610038589325"
        assertEquals(
            PaymentCaptureGuard.semanticIdentity("com.tencent.mm", withOrder),
            PaymentCaptureGuard.semanticIdentity("com.tencent.mm", fromOcr),
        )
        assertEquals(
            "com.tencent.mm|scene:expense|amount:16.00|peer:精品沙县小吃",
            PaymentCaptureGuard.semanticIdentity("com.tencent.mm", "支付成功\n16.00元\n商户名称 精品沙县小吃"),
        )
        assertEquals(
            PaymentCaptureGuard.semanticIdentity("com.tencent.mm", "支付成功\n-16.00\n商户名称 精品沙县小吃"),
            PaymentCaptureGuard.semanticIdentity("com.tencent.mm", "你向精品沙县小吃付款16元"),
        )
        assertEquals("", PaymentCaptureGuard.semanticIdentity("com.tencent.mm", "支付成功"))
    }
    @Test fun semanticIdentityUsesPaymentTimeToSeparateSameAmountAtSameMerchant() {
        val first = PaymentCaptureGuard.semanticIdentity(
            "com.tencent.mm",
            "支付成功\n16.00元\n商户名称 精品沙县小吃\n支付时间\n2026年10月13日 12:05:15",
        )
        val second = PaymentCaptureGuard.semanticIdentity(
            "com.tencent.mm",
            "支付成功\n16.00元\n商户名称 精品沙县小吃\n支付时间\n2026年10月13日 12:08:09",
        )
        assertTrue(first.contains("|time:2026年10月13日 12:05:15"))
        assertNotEquals(first, second)
    }
    @Test fun occurrenceIdentityKeepsOrderStableButSeparatesIdenticalTransfers() {
        val order = "com.tencent.mm|id:420000123456"
        assertEquals(order, PaymentCaptureGuard.occurrenceIdentity(order, "page-1"))
        val fallback = "com.tencent.mm|scene:transfer|amount:0.01|peer:张三"
        assertNotEquals(
            PaymentCaptureGuard.occurrenceIdentity(fallback, "page-1"),
            PaymentCaptureGuard.occurrenceIdentity(fallback, "page-2"),
        )
        assertNotEquals(
            PaymentCaptureGuard.wechatCardOccurrence("09:01\n你发起了一笔转账"),
            PaymentCaptureGuard.wechatCardOccurrence("09:01\n你发起了一笔转账\n09:02\n你发起了一笔转账"),
        )
    }
    @Test fun semanticIdentityUsesRankedTransactionAmountInsteadOfOriginalPriceOrDiscount() {
        val text = "支付成功\n商品原价\n200.00元\n优惠金额\n20.00元\n实付金额\n180.00元\n商户名称 某便利店"
        assertEquals("180.00", PaymentCaptureGuard.transactionAmount(text))
        assertTrue(PaymentCaptureGuard.semanticIdentity("com.eg.android.AlipayGphone", text)
            .contains("|scene:expense|amount:180.00|"))
        assertNull(PaymentCaptureGuard.transactionAmount(
            "支付成功\n实付金额 16.00元\n实付金额 18.00元\n商户名称 某便利店",
        ))
    }
    @Test fun completedRefundPagesAreCapturedForReviewAndUseRefundAmount() {
        val refund = "金冠智充\n-20.00\n退款记录\n已退款¥12.93\n2026年10月11日 12:54:05\n" +
            "当前状态 已退款(¥12.93)\n支付时间 2026年10月11日 12:07:39\n商户全称 南阳金冠智能开关有限公司"
        assertTrue(PaymentCaptureGuard.completedRefund(refund))
        assertEquals("matched", PaymentCaptureGuard.pageReason("com.tencent.mm", refund))
        assertEquals("12.93", PaymentCaptureGuard.transactionAmount(refund))
        assertTrue(PaymentCaptureGuard.semanticIdentity("com.tencent.mm", refund)
            .contains("|scene:refund|amount:12.93|"))
        assertEquals(
            "state_unsupported",
            PaymentCaptureGuard.pageReason("com.tencent.mm", "退款中\n12.93元\n退款记录"),
        )
    }
    @Test fun refundReplayIdentityIgnoresUnstableMerchantText() {
        val detailed = "已退款¥12.93\n退款金额 12.93元\n商户全称 南阳金冠智能开关有限公司"
        val sparse = "退款成功\n退款金额 12.93元"

        assertEquals(
            PaymentCaptureGuard.replayIdentity("com.tencent.mm", detailed),
            PaymentCaptureGuard.replayIdentity("com.tencent.mm", sparse),
        )
    }
    @Test fun replayWindowKeepsAnUnchangedPaymentPageSuppressedLongEnough() {
        assertEquals(48 * 60 * 60 * 1000L, PaymentCaptureGuard.replayWindow("com.tencent.mm|id:420000123456"))
        assertEquals(10 * 60 * 1000L, PaymentCaptureGuard.replayWindow("com.tencent.mm|scene:expense|amount:3.00|peer:三津实业"))
        assertEquals(10 * 60 * 1000L, PaymentCaptureGuard.replayWindow("com.tencent.mm|scene:expense|amount:3.00|peer:三津实业|time:08:22:06"))
    }
    @Test fun screenshotFallbackRequiresRecentChatTimestampAndStrongCardFields() {
        val now=SimpleDateFormat("yyyy-MM-dd HH:mm",Locale.US).parse("2026-10-06 09:01")!!.time
        fun line(text:String,top:Int)=OcrLine(text,20,top,500,top+30)
        val card=listOf(line("09:01",500),line("¥0.01",620),line("你发起了一笔转账",660),line("微信转账",700))
        val matched=WechatScreenshotFallback.extract(card,1200,now)
        assertNotNull(matched);assertTrue(matched!!.text.contains("¥0.01"));assertFalse(matched.text.contains("聊天"))
        assertNull(WechatScreenshotFallback.extract(card.map { if(it.text=="09:01") it.copy(text="08:00") else it },1200,now))
        assertNull(WechatScreenshotFallback.extract(card.filterNot { it.text=="微信转账" },1200,now))
        // The status-bar clock is excluded by geometry and cannot make an old card look current.
        assertNull(WechatScreenshotFallback.extract(listOf(line("09:01",10),line("08:00",500))+card.drop(1),1200,now))
    }
}
