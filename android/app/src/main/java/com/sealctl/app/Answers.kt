package com.sealctl.app

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

/**
 * Requests whose answer is on its way: one answer per request at a time, and the card's
 * timer leaves the card to it. Claiming a card and expiring it are each one step under the
 * same lock, so of an answer and the timer on two threads only one gets the card.
 */
internal class InFlight {
    private val ids = HashSet<String>()

    /** Claims [id] for an answer when [ready] gives the card; null when it gives none or an answer is on its way. */
    fun <T : Any> claim(id: String, ready: () -> T?): T? = synchronized(this) {
        if (id in ids) null else ready()?.also { ids.add(id) }
    }

    /** Runs [block] (the card's expiry) unless an answer to [id] is on its way. */
    fun <T : Any> unlessAnswering(id: String, block: () -> T?): T? = synchronized(this) {
        if (id in ids) null else block()
    }

    /** Runs [block] with the requests answered now, no claim coming in meanwhile. */
    fun <T> withAnswering(block: (Set<String>) -> T): T = synchronized(this) { block(ids) }

    fun done(id: String) {
        synchronized(this) { ids.remove(id) }
    }

    operator fun contains(id: String): Boolean = synchronized(this) { id in ids }
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

/**
 * The relay socket of the foreground (SPEC.md 8.3): open only for the current turn. The app
 * leaving the foreground ends the turn; Erase only closes the socket, as the app is still on
 * screen and onboarding again opens it in the same turn.
 */
internal class ForegroundSocket<S : Any>(
    private val create: () -> S,
    private val start: (S) -> Unit,
    private val stop: (S) -> Unit,
) {
    private val lifecycle = Lifecycle()
    private var socket: S? = null

    /** The app came to the foreground: the turn for [open]. */
    fun started(): Long = lifecycle.started()

    fun now(): Long = lifecycle.now()

    /**
     * Opens the socket for [turn], with [whileOpen] under the same lock; false when the app
     * left the foreground since that turn began.
     */
    fun open(turn: Long, whileOpen: () -> Unit = {}): Boolean = synchronized(this) {
        if (!lifecycle.current(turn)) return false
        whileOpen()
        start(socket ?: create().also { socket = it })
        true
    }

    /** The app left the foreground: [whileClosing] and the socket's close under one lock. */
    fun stopped(whileClosing: () -> Unit = {}) {
        lifecycle.stopped()
        synchronized(this) {
            whileClosing()
            closeLocked()
        }
    }

    /** Closes the socket and keeps the turn (Erase, with the app on screen). */
    fun close() {
        synchronized(this) { closeLocked() }
    }

    val isOpen: Boolean get() = synchronized(this) { socket != null }

    private fun closeLocked() {
        socket?.let(stop)
        socket = null
    }
}
