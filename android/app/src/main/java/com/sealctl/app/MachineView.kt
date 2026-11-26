package com.sealctl.app

import com.sealctl.core.app.Machine
import com.sealctl.core.app.MachineSession
import com.sealctl.core.app.machineModelName
import com.sealctl.core.app.machineSession
import com.sealctl.core.app.machineShortName
import com.sealctl.designsystem.MachineState

/**
 * A machine's row: its state and the texts of SPEC.md 11.8. [name] is the short name the list
 * shows (SPEC.md 11.17), the same as the Activity rows: the nickname, else the host.
 */
data class MachineView(
    val machine: Machine,
    val name: String,
    val state: MachineState,
    val row: String,
    val detail: String,
    val leftSecs: Long?,
    /** The model as the list names it ("Mac mini" for `Mac16,10`), or null when none was reported. */
    val model: String? = modelOf(machine),
) {

    /** "seen 1 h ago" */
    fun seen(now: Long = System.currentTimeMillis()): String = "seen ${Texts.ago(machine.lastSeen?.toLong(), now)}"

    /** The card's muted line (SPEC.md 11.17): "Mac mini · seen 1 h ago". */
    fun sub(now: Long = System.currentTimeMillis()): String = listOfNotNull(model, seen(now)).joinToString(" · ")

    /** "Not seen for 94 days" for a machine unseen for 90 days, else null. */
    fun unseen(now: Long = System.currentTimeMillis()): String? =
        if (machine.flagged) "Not seen for ${(now - (machine.lastSeen?.toLong() ?: 0)) / 86_400_000} days" else null

    /** The card's one label: "Devs-Mac-mini, Locked · last report 1 h ago, Mac mini, seen 1 h ago". */
    fun label(now: Long = System.currentTimeMillis()): String =
        listOfNotNull(name, row, model, seen(now), unseen(now)).joinToString(", ")

    companion object {
        /** [modelOf] reads it from the shared core: the list reads it once per change, not every second. */
        fun modelOf(m: Machine): String? = m.model?.let { machineModelName(it) }?.ifEmpty { null }

        /** The session of [m]'s last status from the shared core, also read once per change. */
        fun sessionOf(m: Machine): MachineSession? = m.lastStatus?.let { machineSession(it) }

        /** Whether [s] shows the machine as active at [now]: it works, so there is no countdown. */
        fun isActive(s: MachineSession, now: Long): Boolean = s.activeUntil?.let { now < it.toLong() } == true

        /**
         * The Open row at [now] (SPEC.md 11.8): "Open · active" while the machine works, "Open ·
         * idle 12 min · locks at 15:42" once it is idle, "Open · 2 h 10 min left" from a CLI that
         * sends no idle time; null once the time it locks has passed.
         */
        fun openRow(s: MachineSession, now: Long): String? {
            val locksAt = s.locksAt.toLong()
            if (!s.open || now >= locksAt) return null
            val lastWork = s.lastWork?.toLong()
            return when {
                isActive(s, now) -> "Open · active"
                lastWork != null -> "Open · idle ${Texts.duration((now - lastWork).coerceAtLeast(0) / 1000)} · locks at ${Texts.time(locksAt)}"
                else -> "Open · ${Texts.duration((locksAt - now + 999) / 1000)} left"
            }
        }

        /**
         * [name] is [machineShortName] of [m], [model] its [modelOf] and [session] its
         * [sessionOf]; the list passes the ones it keeps, read from the shared core once per
         * change of the machines.
         */
        fun of(
            m: Machine,
            engine: Engine,
            now: Long = System.currentTimeMillis(),
            name: String = machineShortName(m),
            model: String? = modelOf(m),
            session: MachineSession? = sessionOf(m),
        ): MachineView {
            val waiting = engine.waiting.value.firstOrNull { it.machine.key == m.key && !it.expired }
            if (waiting != null) {
                val secs = (now - waiting.relay.created.coerceAtMost(now)) / 1000
                return MachineView(m, name, MachineState.Waiting, "Waiting · %d:%02d".format(secs / 60, secs % 60),
                    "A request is on this phone.", null, model)
            }
            val st = m.lastStatus
            if (st == null) {
                return MachineView(m, name, MachineState.Unknown, "Seen ${Texts.ago(m.lastSeen?.toLong(), now)}",
                    "This machine hasn't reported its state yet.", null, model)
            }
            val reported = st.reportedAt.toLong()
            if (st.session == "open") {
                val s = session ?: machineSession(st)
                val row = openRow(s, now)
                if (row != null) {
                    val place = engine.state.value.places.firstOrNull { it.id == st.place }?.name
                    val opened = engine.local.value.days.firstOrNull { it.machine == m.key }?.firstApproval?.toLong()
                    val detail = buildString {
                        if (opened != null) append("Opened at ${Texts.time(opened)}")
                        if (place != null) append(" at $place")
                        if (opened != null) append(". ")
                        if (isActive(s, now)) s.allowanceSecs?.let { append("Locks after ${Texts.duration(it.toLong())} idle. ") }
                        st.stop?.let { append("Hard stop at ${Texts.time(it.toLong())}.") }
                    }.trim()
                    val left = (s.locksAt.toLong() - now + 999) / 1000
                    return MachineView(m, name, MachineState.Open, row, detail, left, model)
                }
                return MachineView(m, name, MachineState.Locked, "Locked · last report ${Texts.ago(reported, now)}",
                    "No keys in memory. Volumes unmounted.", null, model)
            }
            return MachineView(m, name, MachineState.Locked, "Locked", "No keys in memory. Volumes unmounted.", null, model)
        }

        /** Waiting, then Open, then Locked, then by last seen (SPEC.md 11.17). */
        fun sorted(list: List<MachineView>): List<MachineView> = list.sortedWith(
            compareBy<MachineView> {
                when (it.state) { MachineState.Waiting -> 0; MachineState.Open -> 1; MachineState.Locked -> 2; else -> 3 }
            }.thenByDescending { it.machine.lastSeen?.toLong() ?: 0 },
        )
    }
}
