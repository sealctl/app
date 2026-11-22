package com.sealctl.app

import com.sealctl.core.app.Machine
import com.sealctl.designsystem.MachineState

/** A machine's row: its state and the texts of SPEC.md 11.8. */
data class MachineView(
    val machine: Machine,
    val name: String,
    val state: MachineState,
    val row: String,
    val detail: String,
    val leftSecs: Long?,
) {
    companion object {
        fun of(m: Machine, engine: Engine, now: Long = System.currentTimeMillis()): MachineView {
            val name = engine.displayName(m)
            val waiting = engine.waiting.value.firstOrNull { it.machine.key == m.key && !it.expired }
            if (waiting != null) {
                val secs = (now - waiting.relay.created.coerceAtMost(now)) / 1000
                return MachineView(m, name, MachineState.Waiting, "Waiting · %d:%02d".format(secs / 60, secs % 60),
                    "A request is on this phone.", null)
            }
            val st = m.lastStatus
            if (st == null) {
                return MachineView(m, name, MachineState.Unknown, "Seen ${Texts.ago(m.lastSeen?.toLong(), now)}",
                    "This machine hasn't reported its state yet.", null)
            }
            val reported = st.reportedAt.toLong()
            if (st.session == "open") {
                val left = (st.left?.toLong() ?: 0) - (now - reported) / 1000
                if (left > 0) {
                    val place = engine.state.value.places.firstOrNull { it.id == st.place }?.name
                    val opened = engine.local.value.days.firstOrNull { it.machine == m.key }?.firstApproval?.toLong()
                    val detail = buildString {
                        if (opened != null) append("Opened at ${Texts.time(opened)}")
                        if (place != null) append(" at $place")
                        if (opened != null) append(". ")
                        st.stop?.let { append("Hard stop at ${Texts.time(it.toLong())}.") }
                    }.trim()
                    return MachineView(m, name, MachineState.Open, "Open · ${Texts.duration(left)} left", detail, left)
                }
                return MachineView(m, name, MachineState.Locked, "Locked (last report ${Texts.ago(reported, now)})",
                    "No keys in memory. Volumes unmounted.", null)
            }
            return MachineView(m, name, MachineState.Locked, "Locked", "No keys in memory. Volumes unmounted.", null)
        }

        /** Waiting, then Open, then Locked, then by last seen (SPEC.md 11.17). */
        fun sorted(list: List<MachineView>): List<MachineView> = list.sortedWith(
            compareBy<MachineView> {
                when (it.state) { MachineState.Waiting -> 0; MachineState.Open -> 1; MachineState.Locked -> 2; else -> 3 }
            }.thenByDescending { it.machine.lastSeen?.toLong() ?: 0 },
        )
    }
}
