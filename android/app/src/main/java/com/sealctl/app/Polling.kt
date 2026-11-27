package com.sealctl.app

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.sealctl.relay.ClockSkewException
import com.sealctl.relay.RateLimitedException
import com.sealctl.relay.RelayException
import kotlinx.coroutines.delay

/** How a screen's relay checks are paced (SPEC.md 8.1), apart from the engine so they can be tested. */
internal object Polling {
    /** The longest pause between two checks after errors. */
    const val CAP_MS = 60_000L

    /** The longest rate-limit window kept from an earlier process: a day, the relay's longest limit. */
    const val KEPT_WINDOW_MS = 86_400_000L

    /**
     * The rate-limit window an earlier process kept, as a new client starts it: none once it
     * has passed, and at most [KEPT_WINDOW_MS] on (a clock that was set back).
     */
    fun keptWindow(until: Long, now: Long): Long = if (until <= now) 0 else minOf(until, now + KEPT_WINDOW_MS)

    /**
     * A final answer: asking again gets the same (any `4xx` but `408` and `429`, a clock the
     * relay refuses, no keys). Polling stops.
     */
    fun isFinal(e: Throwable): Boolean = when (e) {
        is RateLimitedException -> false
        is ClockSkewException -> true
        is RelayException -> (e.status in 400..499 && e.status != 408) || e.code == "no_keys"
        else -> false
    }
}

/**
 * The pause before a screen's next relay check: [baseMs] after one that went; after errors,
 * doubling up to [capMs], with ±20 % jitter, and never inside the rate-limit window. A final
 * answer stops the checks for good, also when the screen comes back.
 */
internal class PollBackoff(
    private val baseMs: Long,
    private val capMs: Long = Polling.CAP_MS,
    private val random: () -> Double = { Math.random() },
) {
    private var failures = 0

    @Volatile var stopped = false
        private set

    /** The pause after a check that ended with [error] (null: it went); null to stop checking. */
    fun after(error: Throwable?, windowMs: Long): Long? {
        if (error == null) {
            failures = 0
        } else if (Polling.isFinal(error)) {
            stopped = true
            return null
        } else {
            failures++
        }
        val pause = if (failures == 0) baseMs else minOf(capMs, baseMs shl minOf(failures, 16))
        val jittered = (pause * (0.8 + 0.4 * random())).toLong()
        return maxOf(jittered, windowMs)
    }
}

/**
 * Runs [check] at once and then after each of [backoff]'s pauses, only while this lifecycle is
 * at least started (as [everyWhileStarted]); [windowMs] is the relay client's rate-limit window.
 */
internal suspend fun Lifecycle.pollWhileStarted(backoff: PollBackoff, windowMs: () -> Long, check: suspend () -> Throwable?) {
    repeatOnLifecycle(Lifecycle.State.STARTED) {
        while (!backoff.stopped) {
            val pause = backoff.after(check(), windowMs()) ?: break
            delay(pause)
        }
    }
}
