package com.smartledger.smart_ledger

import org.junit.Assert.*
import org.junit.Test

class PaymentPageSessionTest {
    @Test fun fragmentsFromSeveralEventsAreCombinedBeforeMatching() {
        val session = PaymentPageSession()
        val pkg = "com.tencent.mm"
        val cls = "com.tencent.mm.plugin.remittance.ui.RemittanceDetailUI"
        assertTrue(session.observe(pkg, cls, listOf("支付成功"), 1_000L))
        assertTrue(session.observe(pkg, cls, listOf("收款方", "张三"), 1_050L))
        val result = session.assess(listOf("-16.00", "转账时间", "2026年10月06日"), 1_160L)
        assertTrue(result.matched)
        assertEquals("transfer", result.route)
        assertTrue(result.text.contains("支付成功"))
        assertTrue(result.text.contains("-16.00"))
    }

    @Test fun completedReceiptDoesNotDelayNextReceiptInTheSameWechatActivity() {
        val session = PaymentPageSession()
        val pkg = "com.tencent.mm"
        val cls = "com.tencent.mm.plugin.remittance.ui.RemittanceDetailUI"
        session.observe(pkg, cls, listOf("支付成功", "实付金额", "16.00元"), 1_000L)
        assertTrue(session.assess(listOf("商户名称", "第一家商户"), 1_100L).matched)
        session.complete()

        assertTrue(session.observe(
            pkg,
            cls,
            listOf("支付成功", "实付金额", "8.50元", "商户名称", "第二家商户"),
            1_180L,
        ))
        val next = session.assess(emptyList(), 1_260L)
        assertTrue(next.matched)
        assertTrue(next.text.contains("8.50元"))
        assertFalse(next.text.contains("16.00元"))
    }

    @Test fun incompletePaymentPageRetriesBeforeRequestingOcr() {
        val session = PaymentPageSession()
        val pkg = "com.eg.android.AlipayGphone"
        assertTrue(session.observe(pkg, "com.alipay.mobile.payee.ui.PayResultActivity", emptyList(), 10_000L))
        val first = session.assess(emptyList(), 10_100L)
        assertTrue(first.shouldRetry)
        assertFalse(first.shouldOcr)
        val expired = session.assess(emptyList(), 12_301L)
        assertFalse(expired.shouldRetry)
        assertTrue(expired.shouldOcr)
    }

    @Test fun ordinaryWechatChatNeedsRepeatedEventsBeforeOcrFallback() {
        val session = PaymentPageSession()
        val pkg = "com.tencent.mm"
        val cls = "com.tencent.mm.ui.chatting.ChattingUI"
        session.observe(pkg, cls, emptyList(), 20_000L)
        assertFalse(session.assess(emptyList(), 20_100L).shouldOcr)
        session.observe(pkg, cls, emptyList(), 20_150L)
        assertTrue(session.assess(emptyList(), 20_200L).shouldOcr)
    }

    @Test fun switchingPackageExpiresOldFinancialFragments() {
        val session = PaymentPageSession()
        session.observe("com.tencent.mm", "RemittanceUI", listOf("支付成功", "16.00元"), 1_000L)
        session.observe("com.eg.android.AlipayGphone", "PayResultActivity", listOf("商户名称 瑞幸"), 1_100L)
        val result = session.assess(emptyList(), 1_200L)
        assertFalse(result.text.contains("16.00元"))
        assertEquals("money_missing", result.reason)
    }

    @Test fun routerRecognizesWechatPaymentFamiliesWithoutReadingUnrelatedChats() {
        assertEquals("transfer", PaymentPageRouter.route("com.tencent.mm", "RemittanceBusiUI", ""))
        assertEquals("red_packet", PaymentPageRouter.route("com.tencent.mm", "LuckyMoneyDetailUI", ""))
        assertEquals("chat", PaymentPageRouter.route("com.tencent.mm", "ChattingUI", "普通聊天"))
        assertEquals("chat", PaymentPageRouter.route("com.tencent.mm", "LauncherUI", "普通聊天"))
    }

    @Test fun routerUsesPerApplicationPaymentFamiliesAndKeepsThemIsolated() {
        assertEquals("alipay", PaymentPageRouter.route(
            "com.eg.android.AlipayGphone", "com.alipay.android.msp.ui.views.MspContainerActivity", ""))
        assertEquals("jd", PaymentPageRouter.route(
            "com.jingdong.app.mall", "com.jd.lib.cashier.complete.view.CashierCompleteActivity", ""))
        assertEquals("meituan", PaymentPageRouter.route(
            "com.sankuai.meituan", "com.meituan.android.mrn.container.MRNBaseActivity", ""))
        assertEquals("douyin", PaymentPageRouter.route(
            "com.ss.android.ugc.aweme", "com.android.ttcjpaysdk.thirdparty.front.counter.dypay.activity.DyPayStandardActivity", ""))
        assertEquals("unionpay", PaymentPageRouter.route(
            "com.unionpay", "com.unionpay.activity.payment.UPActivityScan", ""))
        assertEquals("unknown", PaymentPageRouter.route(
            "com.eg.android.AlipayGphone", "com.tencent.mm.plugin.luckymoney.ui.LuckyMoneyDetailUI", "红包已发出"))
    }

    @Test fun applicationSpecificCompletionWordsDoNotLeakAcrossPackages() {
        assertTrue(PaymentPageRouter.appCompletedStatus("com.smile.gifmaker", "购买成功"))
        assertFalse(PaymentPageRouter.appCompletedStatus("com.eg.android.AlipayGphone", "购买成功"))
        assertTrue(PaymentPageRouter.appCompletedStatus("com.xunmeng.pinduoduo", "拼单成功"))
        assertFalse(PaymentPageRouter.appCompletedStatus("com.taobao.taobao", "拼单成功"))
    }

    @Test fun everyReferenceAdapterExposesItsOwnFieldVocabulary() {
        val expected = mapOf(
            "com.eg.android.AlipayGphone" to "到账银行卡",
            "com.jingdong.app.mall" to "交易说明",
            "com.jd.jrapp" to "退款至",
            "com.sankuai.meituan" to "下单时间",
            "com.sankuai.meituan.takeoutnew" to "交易成功 ¥",
            "com.dianping.v1" to "创建时间",
            "com.taobao.taobao" to "实付价",
            "com.taobao.idlefish" to "现价",
            "com.alibaba.wireless" to "有限公司",
            "com.xunmeng.pinduoduo" to "已选择",
            "me.ele" to "提交订单",
            "com.wudaokou.hippo" to "优先使用此付款方式",
            "com.huawei.wallet" to "二维码付款码",
            "com.ccb.longjiLife" to "优先选择此方式支付",
            "com.unionpay" to "实收金额（元）",
            "com.smile.gifmaker" to "门店通用",
            "com.kuaishou.nebula" to "立即支付",
            "com.ss.android.ugc.aweme" to "还款方式",
            "com.ss.android.ugc.aweme.lite" to "到账方式",
            "com.ss.android.ugc.livelite" to "充值方式",
            "com.ss.android.yumme.video" to "实付价",
        )
        assertEquals(21, expected.size)
        for ((pkg, role) in expected) {
            assertTrue("$pkg should own $role", PaymentPageRouter.appFieldRoles(pkg).contains(role))
        }
    }

    @Test fun resetAndBrowsePagesAreNotMistakenForPaymentPages() {
        assertFalse(PaymentPageRouter.isFinancialClass(
            "com.sankuai.meituan", "com.meituan.android.pt.homepage.activity.MainActivity"))
        assertFalse(PaymentPageRouter.isFinancialClass(
            "com.unionpay", "com.unionpay.activity.UPActivityMain"))
        assertFalse(PaymentPageRouter.isFinancialClass(
            "com.ccb.longjiLife", "com.ccb.cloudmerchant.wallet.newOne.WalletActivity"))
        assertTrue(PaymentPageRouter.isFinancialClass(
            "com.ccb.longjiLife", "com.ccb.cloudmerchant.wallet.newOne.view.CodeResultActivity"))
    }

    @Test fun ordinaryApplicationEventsDoNotStartAReceiptSession() {
        val session = PaymentPageSession()
        assertFalse(session.observe(
            "com.eg.android.AlipayGphone",
            "com.eg.android.AlipayGphone.AlipayLogin",
            listOf("首页", "扫一扫", "生活缴费"),
            1_000L,
        ))
        assertFalse(session.observe(
            "com.sankuai.meituan",
            "com.meituan.android.pt.homepage.MainActivity",
            listOf("外卖", "酒店", "推荐"),
            1_100L,
        ))
    }

    @Test fun returningHomeClearsIncompletePaymentFragments() {
        val session = PaymentPageSession()
        val pkg = "com.eg.android.AlipayGphone"
        assertTrue(session.observe(pkg, "MspContainerActivity", listOf("支付成功"), 1_000L))
        assertFalse(session.observe(pkg, "com.eg.android.AlipayGphone.AlipayLogin", listOf("首页"), 1_100L))
        val result = session.assess(listOf("余额 16.00元"), 1_200L)
        assertFalse(result.matched)
        assertFalse(result.text.contains("支付成功"))
    }
}
