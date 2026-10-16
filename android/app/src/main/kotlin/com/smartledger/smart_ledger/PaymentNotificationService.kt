package com.smartledger.smart_ledger

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

class PaymentNotificationService : NotificationListenerService() {
    override fun onListenerConnected() { PaymentAutomation.notificationConnected = true; PaymentAutomation.lastNotificationConnectedAt = System.currentTimeMillis(); PaymentTrace.event(this,"notification_connected"); PaymentAutomation.resume(this) }
    override fun onListenerDisconnected() { PaymentAutomation.notificationConnected = false; PaymentTrace.event(this,"notification_disconnected"); PaymentAutomation.reconnect(this) }
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!PaymentAutomation.sourceGate(this, sbn.packageName, "notification")) return
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val official = PaymentCaptureGuard.trustedTitle(sbn.packageName, title)
        if ((sbn.notification.category == Notification.CATEGORY_MESSAGE || sbn.notification.actions?.any { !it.remoteInputs.isNullOrEmpty() } == true) && !official) {
            PaymentAutomation.record(this, sbn.packageName, "notification", "chat_filtered"); return
        }
        val parts = listOfNotNull(extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()).filter { it.isNotBlank() }.distinct()
        // Big text normally contains the entire short text; don't duplicate amounts/statuses.
        val text = parts.maxByOrNull { it.length } ?: run { PaymentAutomation.record(this, sbn.packageName, "notification", "empty_content"); return }
        val reason=PaymentCaptureGuard.notificationReason(sbn.packageName,title,text,sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0)
        if(reason!="matched") { PaymentAutomation.record(this,sbn.packageName,"notification",reason);return }
        val content = if (title.isBlank() || text.contains(title)) text else "$title\n$text"
        if (content.length > 4000) { PaymentAutomation.record(this, sbn.packageName, "notification", "too_long"); return }
        PaymentAutomation.record(this, sbn.packageName, "notification", "matched")
        PaymentAutomation.enqueue(this, sbn.packageName, "notification", content, sbn.postTime,
            "${sbn.key}|${sbn.postTime}|$title|$text")
    }
    override fun onDestroy() { PaymentAutomation.notificationConnected = false; PaymentTrace.event(this,"notification_disconnected"); super.onDestroy() }
}
