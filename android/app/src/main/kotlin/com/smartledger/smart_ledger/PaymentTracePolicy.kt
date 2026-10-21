package com.smartledger.smart_ledger

/** Fixed metadata vocabulary: recognized fields are allowlisted and masked. */
object PaymentTracePolicy {
    const val maxEntries = 400
    const val maxAge = 48L * 60 * 60 * 1000
    val codes = setOf(
        "notification_connected",
        "notification_disconnected",
        "accessibility_connected",
        "accessibility_interrupted",
        "accessibility_disconnected",
        "event_received",
        "event_text_read",
        "page_session_started",
        "page_session_waiting",
        "page_session_matched",
        "page_session_resumed",
        "ocr_fallback",
        "ocr_event_coalesced",
        "screenshot_requested",
        "screenshot_capability_missing",
        "screenshot_unavailable",
        "ocr_model_missing",
        "ocr_started",
        "quick_capture_started",
        "quick_capture_ready",
        "quick_capture_cancelled",
        "quick_capture_failed",
        "quick_ocr_text_read",
        "quick_ocr_matched",
        "quick_ocr_failed",
        "ocr_no_match",
        "ocr_matched",
        "ocr_failed",
        "master_disabled",
        "enhanced_disabled",
        "app_disabled",
        "chat_filtered",
        "empty_content",
        "window_changed",
        "node_read",
        "no_payment_match",
        "matched",
        "too_long",
        "group_summary",
        "untrusted_title",
        "state_unsupported",
        "success_missing",
        "money_missing",
        "fields_missing",
        "read_failed",
        "queued",
        "replay_skipped",
        "queue_dropped",
        "config_saved",
        "queue_reset",
        "reconnect_requested",
        "retry_requested",
        "worker_start",
        "worker_ready",
        "worker_take",
        "confidence_high",
        "confidence_review",
        "confidence_low",
        "worker_revoked",
        "worker_posted",
        "worker_pending",
        "worker_duplicate_order",
        "worker_duplicate_semantic",
        "worker_duplicate_same_day",
        "worker_duplicate_time",
        "worker_repeated",
        "worker_discarded",
        "worker_quality",
        "worker_finish",
        "worker_start_failed",
        "worker_timeout",
        "plugin_unavailable",
        "invalid_capture",
        "database_error",
        "processing_error",
        "amount_missing",
        "account_missing",
        "category_missing",
        "peer_review",
        "warning_review",
        "overlay_denied",
        "overlay_queued",
        "overlay_overflow",
        "overlay_expanded",
        "overlay_collapsed",
        "overlay_failed",
        "form_submitted",
        "form_saved",
        "form_rejected",
        "form_duplicate")
    fun source(value: String) = value.takeIf { it == "notification" || it == "accessibility" || it == "screenshot" } ?: ""
    fun reference(value: String): String {
        val id = value.removePrefix("auto-")
        return if (Regex("^[a-f0-9]{64}$").matches(id)) id.take(12) else ""
    }
    fun fields(value: Map<*, *>?, reveal: Boolean = false): Map<String, String> {
        if (value == null) return emptyMap()
        val result = linkedMapOf<String, String>()
        if (reveal) (value["amount"] as? String)?.trim()?.takeIf { Regex("^\\d{1,12}\\.\\d{2}$").matches(it) }
            ?.let { result["amount"] = it }
        for (key in listOf("merchant", "account", "category")) {
            val raw = (value[key] as? String)?.trim()?.takeIf { it.isNotEmpty() && it.length <= 100 } ?: continue
            if (reveal) result[key] = raw else {
                val tail = if (key == "account") Regex("\\d{4}(?=\\D*$)").find(raw)?.value ?: raw.takeLast(1) else raw.takeLast(1)
                result[key] = if (raw.length == 1) "*" else raw.take(1) + "*".repeat((raw.length - tail.length - 1).coerceAtLeast(1)) + tail
            }
        }
        (value["qualityScore"] as? String)?.takeIf { Regex("^\\d{1,3}$").matches(it) }
            ?.let { if (it.toInt() <= 100) result["qualityScore"] = it }
        for (key in listOf("amountMatch", "categoryMatch", "accountMatch")) {
            (value[key] as? String)?.takeIf { it == "0" || it == "1" }?.let { result[key] = it }
        }
        (value["remarkScore"] as? String)?.takeIf { Regex("^\\d{1,3}$").matches(it) }
            ?.let { if (it.toInt() <= 100) result["remarkScore"] = it }
        return result
    }
    fun retained(time: Long, now: Long) = time > 0 && time <= now && now - time <= maxAge
}
