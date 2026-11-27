package com.sealctl.app

import com.sealctl.core.app.GrantRecord
import com.sealctl.relay.RateLimitedException
import com.sealctl.relay.RelayException
import com.sealctl.relay.UnavailableException
import java.io.File
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** A sealed `lock` or `notice` for one machine (SPEC.md 9.6, 11.9). */
data class Outgoing(
    val id: String,
    val machine: String,
    val sealed: String,
    val lock: Boolean,
    /** Its `t`: when it was made, Unix ms on the corrected clock. */
    val made: Long,
    /** A lock for leaving a place: the allowance it locks, recorded as locked once the relay takes it. */
    val grant: GrantRecord? = null,
)

/**
 * Locks and notices the relay did not take (no answer, a `5xx` such as `503 maintenance`, a
 * `Retry-After`, the rate-limit window), kept in [file] and sent again until the relay takes
 * them or they no longer matter (SPEC.md 8.1, 9.6, 11.9): their machine is unpaired, the relay
 * gave a final answer (a `4xx` but `401`, `408` and `429`), or they are a day old (the relay
 * holds a message for a day, and no session outlasts one). A lock never waits behind anything:
 * the machine applies it whatever its order. A notice for a machine goes after those queued
 * before it, so the machine never sees a newer one first and drops the older as old.
 *
 * [post] sends one message, the app's own (not tapped) unless said otherwise; [delivered] hears
 * of each the relay took after it was queued; [wake] asks for [flush] again after that many ms
 * (a timer, and a job that outlives the process). [now] is the corrected clock; [clock] the
 * system clock the waits are counted on.
 */
internal class Outbox(
    private val file: File?,
    private val now: () -> Long,
    private val post: suspend (Outgoing, userTapped: Boolean) -> Unit,
    private val live: (String) -> Boolean,
    private val delivered: (Outgoing) -> Unit,
    private val wake: (Long) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: () -> Double = { Math.random() },
) {
    enum class Result {
        /** The relay took it. */
        SENT,
        /** Kept, and sent again later. */
        QUEUED,
        /** A final answer: not sent again. */
        REFUSED,
    }

    private val items = ArrayList<Outgoing>()
    /** One flush at a time. */
    private val flushing = Mutex()
    /** No try before this (system ms): a `Retry-After`, the rate-limit window, or the backoff. */
    @Volatile private var notBefore = 0L
    private var failures = 0

    init {
        file?.let { load(it) }
    }

    /** What is waiting, oldest first. */
    @Synchronized
    fun pending(): List<Outgoing> = items.toList()

    /**
     * Sends [o] now, or queues it when the relay can't take it now. One the person tapped
     * ([userTapped], Lock now) is tried at once, whatever the wait; the app's own waits out a
     * `Retry-After` or the rate-limit window in the queue.
     */
    suspend fun send(o: Outgoing, userTapped: Boolean): Result {
        val behind = synchronized(this) { !o.lock && items.any { it.machine == o.machine } }
        if (behind || (!userTapped && clock() < notBefore)) {
            enqueue(o)
            if (behind) wake(maxOf(0, notBefore - clock()))
            return Result.QUEUED
        }
        return try {
            post(o, userTapped)
            // A lock made later covers every session one queued earlier would lock.
            if (o.lock) for (old in removeLocks(o.machine)) delivered(old)
            // The relay is back: what waits goes now.
            val more = synchronized(this) { failures = 0; notBefore = 0; items.isNotEmpty() }
            if (more) wake(0)
            Result.SENT
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (isFinal(e)) return Result.REFUSED
            enqueue(o)
            failed(e)
            Result.QUEUED
        }
    }

    /**
     * Sends what is waiting, oldest first, unless the last failure's wait is not over. Drops what
     * no longer matters. Stops at the first failure and asks to be woken when its wait is over.
     */
    suspend fun flush() {
        if (!flushing.tryLock()) return
        try {
            dropObsolete()
            val wait = notBefore - clock()
            if (wait > 0) {
                if (pending().isNotEmpty()) wake(wait)
                return
            }
            for (o in pending()) {
                try {
                    post(o, false)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (isFinal(e)) { remove(o.id); continue }
                    failed(e)
                    return
                }
                remove(o.id)
                delivered(o)
            }
            synchronized(this) { failures = 0; notBefore = 0 }
        } finally {
            flushing.unlock()
        }
    }

    /** Forgets everything (erase, Leave sealctl). */
    @Synchronized
    fun clear() {
        items.clear()
        notBefore = 0
        failures = 0
        save()
    }

    private fun failed(e: Exception) {
        val wait = synchronized(this) {
            failures++
            val until = when (e) {
                is UnavailableException -> e.until
                is RateLimitedException -> e.until
                else -> 0L
            }
            // The relay said when: then, not before and not later. Otherwise back off.
            notBefore = if (until > 0) until else clock() + backoffMs(failures, random)
            notBefore - clock()
        }
        wake(wait)
    }

    @Synchronized
    private fun enqueue(o: Outgoing) {
        var item = o
        if (o.lock) {
            // One lock per machine: the newer one covers the older, and keeps its allowance.
            val old = items.filter { it.lock && it.machine == o.machine }
            if (o.grant == null) old.lastOrNull { it.grant != null }?.let { item = o.copy(grant = it.grant) }
            items.removeAll(old.toSet())
        }
        items += item
        save()
    }

    @Synchronized
    private fun removeLocks(machine: String): List<Outgoing> {
        val old = items.filter { it.lock && it.machine == machine }
        if (old.isNotEmpty()) { items.removeAll(old.toSet()); save() }
        return old
    }

    @Synchronized
    private fun remove(id: String) {
        if (items.removeAll { it.id == id }) save()
    }

    @Synchronized
    private fun dropObsolete() {
        val t = now()
        if (items.removeAll { !live(it.machine) || t - it.made > MAX_AGE_MS }) save()
    }

    private fun save() {
        val f = file ?: return
        runCatching {
            val text = buildJsonArray {
                for (o in items) add(buildJsonObject {
                    put("id", o.id); put("machine", o.machine); put("sealed", o.sealed)
                    put("lock", o.lock); put("made", o.made)
                    o.grant?.let { g ->
                        put("grant", buildJsonObject {
                            put("machine", g.machine); put("place", g.placeId); put("at", g.at.toLong()); put("ends", g.ends.toLong())
                        })
                    }
                })
            }.toString()
            val tmp = File(f.parentFile, f.name + ".tmp")
            tmp.writeText(text)
            if (!tmp.renameTo(f)) throw IOException("rename")
        }.onFailure { dlog("outbox not saved: ${it.javaClass.simpleName}") }
    }

    private fun load(f: File) {
        val list = runCatching { Json.parseToJsonElement(f.readText()).jsonArray }.getOrNull() ?: return
        for (e in list) {
            val o = e as? JsonObject ?: continue
            fun str(k: String) = o[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
            val grant = (o["grant"] as? JsonObject)?.let { g ->
                GrantRecord(
                    machine = g["machine"]?.jsonPrimitive?.content ?: return@let null,
                    placeId = g["place"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content,
                    at = (g["at"]?.jsonPrimitive?.longOrNull ?: 0).toULong(),
                    ends = (g["ends"]?.jsonPrimitive?.longOrNull ?: 0).toULong(),
                    locked = false,
                )
            }
            items += Outgoing(
                id = str("id") ?: continue,
                machine = str("machine") ?: continue,
                sealed = str("sealed") ?: continue,
                lock = o["lock"]?.jsonPrimitive?.booleanOrNull ?: false,
                made = o["made"]?.jsonPrimitive?.longOrNull ?: continue,
                grant = grant,
            )
        }
    }

    companion object {
        /** A message this old no longer matters: the relay holds one a day, and no session lasts longer. */
        const val MAX_AGE_MS = 24 * 3_600_000L

        /**
         * An answer the same message would get again: a `4xx` but `401` (a clock the relay
         * refused may be set right), `408` and `429`; or no keys at all after an erase.
         */
        fun isFinal(e: Exception): Boolean = e is RelayException && e.status in 400..499 && e.status != 401 && e.status != 408 && e.status != 429

        /** The wait after [failures] failures that gave no `Retry-After`: 10 s doubling, at most 10 minutes, ±20 %. */
        fun backoffMs(failures: Int, random: () -> Double = { Math.random() }): Long {
            val base = minOf(10_000L shl (failures - 1).coerceIn(0, 6), 10 * 60_000L)
            return (base * (0.8 + 0.4 * random())).toLong()
        }
    }
}
