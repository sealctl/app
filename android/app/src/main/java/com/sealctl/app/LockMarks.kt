package com.sealctl.app

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * A lock this phone sent to a machine whose status has not answered it yet (SPEC.md 11.8):
 * [at] is the lock's `t` (corrected clock), [accepted] when the relay took it (0 while it waits
 * in the outbox).
 */
data class LockMark(val at: Long, val accepted: Long = 0)

/**
 * The locks sent and not yet answered by a status, by machine (SPEC.md 11.8). The machine's card
 * shows "Locking…" from the lock until a status confirms it, and "Locked" once the relay has
 * held the lock for [SETTLE_MS] with no status. A status that says Locked ends the mark; one that
 * says Open ends it only when made after the lock (a session opened since): one the machine made
 * before it received the lock must not show the session as open again.
 */
object LockMarks {
    /** How long after the relay took a lock with no status the card shows Locked. */
    const val SETTLE_MS = 60_000L

    /** A mark this old is dropped: the relay holds a message a day. */
    const val MAX_AGE_MS = 24 * 3_600_000L

    /** [marks] after a lock made at [at] was sent to [machine] (queued or taken). */
    fun sent(marks: Map<String, LockMark>, machine: String, at: Long, accepted: Long): Map<String, LockMark> =
        marks + (machine to LockMark(at, accepted))

    /** [marks] after the relay took a queued lock for [machine] at [now]. */
    fun accepted(marks: Map<String, LockMark>, machine: String, now: Long): Map<String, LockMark> =
        marks[machine]?.takeIf { it.accepted == 0L }?.let { marks + (machine to it.copy(accepted = now)) } ?: marks

    /**
     * [marks] after a status [machine] made at [statusTime] (its `t`): one that says it is not
     * [open] confirms the lock; one that says Open counts only when made after the lock.
     */
    fun status(marks: Map<String, LockMark>, machine: String, statusTime: Long, open: Boolean): Map<String, LockMark> =
        marks[machine]?.takeIf { !open || statusTime >= it.at }?.let { marks - machine } ?: marks

    /** [marks] without those too old to matter at [now], or for machines no longer paired. */
    fun pruned(marks: Map<String, LockMark>, now: Long, live: (String) -> Boolean): Map<String, LockMark> =
        marks.filter { (k, m) -> live(k) && now - m.at < MAX_AGE_MS }

    /** Whether the card shows Locked rather than Locking… at [now]. */
    fun settled(mark: LockMark, now: Long): Boolean = mark.accepted != 0L && now - mark.accepted >= SETTLE_MS

    fun encode(marks: Map<String, LockMark>): String = buildJsonObject {
        for ((k, m) in marks) put(k, buildJsonObject { put("at", m.at); put("accepted", m.accepted) })
    }.toString()

    fun decode(text: String?): Map<String, LockMark> = runCatching {
        Json.parseToJsonElement(text ?: return emptyMap()).jsonObject.mapNotNull { (k, v) ->
            val o = v as? JsonObject ?: return@mapNotNull null
            val at = o["at"]?.jsonPrimitive?.longOrNull ?: return@mapNotNull null
            k to LockMark(at, o["accepted"]?.jsonPrimitive?.longOrNull ?: 0)
        }.toMap()
    }.getOrDefault(emptyMap())
}
