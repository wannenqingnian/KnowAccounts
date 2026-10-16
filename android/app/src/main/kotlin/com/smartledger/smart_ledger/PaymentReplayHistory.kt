package com.smartledger.smart_ledger

object PaymentReplayHistory {
    fun contains(value: String, fingerprint: String, now: Long, window: Long): Boolean =
        value.lineSequence().any {
            val parts = it.split(':', limit = 2)
            parts.size == 2 && parts[0] == fingerprint &&
                now - (parts[1].toLongOrNull() ?: Long.MIN_VALUE) in 0..window
        }

    fun record(value: String, fingerprint: String, now: Long): String =
        (sequenceOf("$fingerprint:$now") + value.lineSequence().filter { it.substringBefore(':') != fingerprint })
            .take(12).joinToString("\n")
}
