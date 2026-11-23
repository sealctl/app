package com.sealctl.app

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/** Timing rules of an answer (SPEC.md 8.3, 8.5), apart from the engine so they can be tested. */
internal object Answers {
    /** The relay's signature time window (Relay API, Signing). */
    const val CLOCK_WINDOW_MS = 300_000L

    /**
     * When this phone stops offering a request, on its own clock. The relay's `expires` is on
     * the relay's clock; a phone clock ahead of it by less than the window raises no clock
     * error, yet would close every request at once. The time between `created` and seeing the
     * request is added, up to the window. A late answer gets `404 gone`: the relay decides.
     */
    fun deadline(seenAt: Long, created: Long, expires: Long): Long =
        expires + (seenAt - created).coerceIn(0L, CLOCK_WINDOW_MS)
}

/** What became of one reply. */
enum class Sent {
    /** The relay took it. */
    POSTED,

    /** The machine stopped waiting (`404 gone`, or the request's time ran out). */
    GONE,

    /** The root could not be read: "Unlock your phone to answer." */
    LOCKED,

    /** Not sealed, or the relay did not take it; the request can be answered again. */
    FAILED,
}

/** Requests whose answer is on its way: one answer per request at a time. */
internal class InFlight {
    private val ids: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** False when an answer to [id] is already on its way. */
    fun start(id: String): Boolean = ids.add(id)

    fun done(id: String) {
        ids.remove(id)
    }

    operator fun contains(id: String): Boolean = id in ids
}

/**
 * The app's turns in the foreground. A start hands out a number; foreground work started for
 * it runs only while no stop (or later start) came since, so a stop that wins the race against
 * that work leaves no socket open and the app not counted as in the foreground.
 */
internal class Lifecycle {
    private val turn = AtomicLong(0)

    @Volatile
    var foreground = false
        private set

    fun started(): Long {
        foreground = true
        return turn.incrementAndGet()
    }

    fun stopped() {
        foreground = false
        turn.incrementAndGet()
    }

    fun now(): Long = turn.get()

    fun current(t: Long): Boolean = foreground && t == turn.get()
}
