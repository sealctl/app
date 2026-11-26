package com.sealctl.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.sealctl.app.Graph
import com.sealctl.app.MainActivity
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.core.Place as PlaceKind
import com.sealctl.core.app.Event
import com.sealctl.core.app.HandbackReport
import com.sealctl.core.app.LocalEvent
import com.sealctl.core.app.ReportItem
import com.sealctl.core.app.runningPhoneAction
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.SecondaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.Title
import kotlinx.coroutines.launch

/**
 * Leave sealctl (SPEC.md 11.22). Each step is saved, so a closed app resumes where it left.
 * Steps: 1 what happens, 2 each computer, 3 confirm (+ delay), 4 card check, 5 relay data and
 * words backup, 6 what happened, 7 the card.
 */
@Composable
fun LeaveScreen(activity: MainActivity) {
    val engine = Graph.engine
    val local by engine.local.collectAsState()
    val step = local.leaveStep.toInt().coerceAtLeast(1)
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    // Two card words before a new gate (9.6) at step 1 or 3; then the step goes on.
    var gateCard by remember { mutableStateOf<GateResult?>(null) }
    // At step 3: one start or finish at a time, and the delay on screen until closed.
    var busy by remember { mutableStateOf(false) }
    var shown by remember { mutableStateOf<String?>(null) }
    var finishing by remember { mutableStateOf(false) }
    fun once(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch { try { block() } finally { busy = false } }
    }
    fun go(n: Int, skipped: List<String> = local.leaveSkipped) = engine.applyLocal(LocalEvent.SetLeave(n.toUInt(), skipped))
    fun cancel() { go(0, emptyList()); Ui.pop() }
    // Skipped computers keep their names after step 5 forgets every machine.
    fun skippedName(key: String) = engine.state.value.machines.firstOrNull { it.key == key }?.name
        ?.let { Texts.shown(it, Texts.MAX_NAME) } ?: key.take(8)

    suspend fun start() {
        when (val g = biometricGate(activity, "Confirm leaving sealctl.")) {
            GateResult.Passed -> go(2)
            GateResult.Cancelled -> {}
            GateResult.LockedOut -> error = Texts.LOCKED_OUT
            GateResult.Changed, GateResult.NoGate -> { error = null; gateCard = g }
            else -> error = Texts.NO_BIOMETRICS
        }
    }
    /** Step 3: biometrics, then the delayed record [id] finished, or a new start (11.22, 11.23). */
    suspend fun confirm(id: String?) {
        error = null
        when (val g = biometricGate(activity, "Confirm leaving sealctl.")) {
            GateResult.Passed -> {}
            GateResult.Cancelled -> return
            GateResult.LockedOut -> { error = Texts.LOCKED_OUT; return }
            GateResult.Changed, GateResult.NoGate -> { error = null; finishing = id != null; gateCard = g; return }
            else -> { error = Texts.NO_BIOMETRICS; return }
        }
        if (id != null) {
            when (engine.finishPhoneAction(id)) {
                null -> go(4)
                "relay" -> error = "The relay isn't answering, and sealctl can't finish until it confirms nothing was cancelled."
                "too_early" -> error = "Not yet."
                // Expired or cancelled: the delay screen says so itself.
                else -> {}
            }
            return
        }
        val delayed = try {
            engine.startPhoneAction("leave")
        } catch (e: com.sealctl.relay.RelayException) {
            error = if (e.code == "too_many_delayed") Texts.TOO_MANY_DELAYED else Texts.RELAY_DOWN
            return
        } catch (e: Exception) {
            error = Texts.RELAY_DOWN
            return
        }
        if (delayed == null) go(4) else shown = delayed.id
    }

    gateCard?.let { why ->
        if (step == 1 || step == 3) {
            GateCardWords(activity, why, onPassed = {
                gateCard = null
                if (step == 1) scope.launch { start() }
                else once { confirm(if (finishing) engine.runningAction("leave")?.id else null) }
            }, onCancel = { gateCard = null })
            return
        }
    }
    when (step) {
        1 -> Page(null, onBack = { cancel() }, bottom = {
            PrimaryButton("Start", { scope.launch { start() } })
            PlainButton("Cancel", { cancel() })
        }) {
            Gap(24)
            Title("Unseal all machines and leave")
            Body("sealctl hands everything back to you before you go. On each computer, `sealctl unseal --all` moves your volumes, backups, SSH keys and secrets to passwords of your own. Your files stay encrypted.")
            Body("Then this phone deletes your data on the relay and the copy of your words in your Google backup.")
            ErrorText(error)
        }
        2 -> EachComputer(onContinue = { go(3) }, onSkip = { key -> go(2, local.leaveSkipped + key) }, onBack = { cancel() })
        3 -> {
            // A leave still waiting or ready is shown, never started again (11.23).
            val now by rememberNow()
            val running = runningPhoneAction(local.delayed, "leave", now.toULong())
            LaunchedEffect(running?.id) { if (running != null) shown = running.id }
            val d = (running?.id ?: shown)?.let { id -> local.delayed.firstOrNull { it.id == id } }
            if (d != null) {
                DelayView(d.id, "Leaving sealctl", PhoneActionButtons("leave", busy, error,
                    onReady = { once { confirm(d.id) } },
                    onStartAgain = { shown = null; once { confirm(null) } }))
                return
            }
            Page(null, onBack = { cancel() }, bottom = {
                ErrorText(error)
                PrimaryButton(Texts.CONFIRM, { once { confirm(null) } }, enabled = !busy)
                PlainButton("Cancel", { cancel() })
            }) {
                Gap(24)
                Title("Delete your data and the last copy of your words?")
                Body("Next, this phone deletes your data on the relay and removes your words from your Google backup.")
                Body(
                    if (engine.delayLifted()) "At your trusted place: this happens as soon as you confirm."
                    else "This starts two hours after you confirm. Your phone and your computers can cancel it until then.",
                )
            }
        }
        4 -> {
            var lost by remember { mutableStateOf(false) }
            if (lost) {
                Page(null, bottom = { PrimaryButton("Close", { cancel() }) }) {
                    Gap(24)
                    Body("Keep the copy in your Google backup until you find it, or write a new card first (Show words).")
                }
            } else {
                CardWords(activity, positions = 3, groups = 3, title = "Check your card first",
                    body = "After this, your paper card is the only copy of your words. Type three words from it.",
                    onPassed = { go(5) }, onCancel = { lost = true })
            }
        }
        5 -> {
            var running by remember { mutableStateOf(false) }
            Page(null, bottom = {
                ErrorText(error)
                PrimaryButton(if (error != null) "Try again" else "Continue", {
                    if (running) return@PrimaryButton
                    running = true
                    scope.launch {
                        for (k in local.leaveSkipped) runCatching { engine.relay.removeMachine(k) }
                        val r = deleteRelayData(lockFirst = false)
                        if (r.startsWith("Deleted")) {
                            val removed = Graph.blockStore.delete()
                            engine.apply(Event.AddReport(HandbackReport(
                                id = "leave-${System.currentTimeMillis()}", machine = "", machineName = "This phone", what = "leave", planHash = "",
                                items = listOf(
                                    ReportItem("relay", "Relay data", "deleted", "done"),
                                    if (removed) ReportItem("backup", "Words backup", "removed", "done")
                                    else ReportItem("backup", "Words backup", "not removed", "failed"),
                                ) + local.leaveSkipped.map { ReportItem("computer", skippedName(it), "skipped", "skipped") },
                                run = "", time = System.currentTimeMillis().toULong(), updated = 0u,
                            )))
                            error = null
                            go(6)
                        } else error = "The relay isn't answering. Try again."
                        running = false
                    }
                })
            }) {
                Gap(24)
                Title("Deleting your relay data")
                Body("This removes your words from your Google backup. Your other Android phones lose this copy too.")
            }
        }
        6 -> {
            val all = engine.state.collectAsState().value.reports
            val leave = all.filter { it.what == "leave" }.maxByOrNull { it.time }
            val backupLeft = leave?.items?.any { it.kind == "backup" && it.state == "failed" } == true
            var retrying by remember { mutableStateOf(false) }
            Page(null, bottom = {
                ErrorText(error)
                if (backupLeft && leave != null) SecondaryButton("Remove the words backup again", {
                    if (retrying) return@SecondaryButton
                    retrying = true
                    scope.launch {
                        if (Graph.blockStore.delete()) {
                            error = null
                            engine.apply(Event.AddReport(leave.copy(items = leave.items.map {
                                if (it.kind == "backup") it.copy(to = "removed", state = "done") else it
                            })))
                        } else error = "The words backup couldn't be removed. Try again."
                        retrying = false
                    }
                })
                PrimaryButton("Next", { go(7) })
            }) {
                Gap(24)
                Title("What happened")
                for (r in all.filter { it.what == "unseal" }) Body("${r.machineName}: handed back · ${r.items.count { it.state == "done" }} objects")
                for (k in local.leaveSkipped) Body("${skippedName(k)}: skipped")
                Body("Relay data deleted.")
                Body(if (backupLeft) "Words backup not removed." else "Words backup removed.")
            }
        }
        else -> Page(null, onBack = null, bottom = {
            PrimaryButton("Done", {
                Ui.goodbye.value = true
                Graph.engine.scope.launch {
                    // Erase removes the saved step with the database: an app closed before it
                    // ends opens at this step again, not as if nothing happened.
                    erase(alsoBackup = true)
                }
            })
        }) {
            Gap(24)
            Title("Keep your card for now")
            Body("Keep your paper card until no old copies of your backups or volumes remain: older disk images, old backup snapshots in another place, or copies of the store. Those still open only with these words. Then destroy it.")
        }
    }
}

@Composable
private fun EachComputer(onContinue: () -> Unit, onSkip: (String) -> Unit, onBack: () -> Unit) {
    val engine = Graph.engine
    val local by engine.local.collectAsState()
    val paired by engine.relayMachines.collectAsState()
    val state by engine.state.collectAsState()
    val delayed = local.delayed
    var skipping by remember { mutableStateOf<String?>(null) }
    // Asks the relay every 5 s while this screen is on show, not in the background.
    WhileStarted(5_000) { engine.refreshMachines(); engine.refreshDelayed() }
    // Every machine paired when leaving began; one that unpaired itself shows as handed back.
    val machines = state.machines.filter { !it.deleted }
    val rows = machines.map { m ->
        val handed = paired != null && !paired!!.contains(m.key)
        val skipped = m.key in local.leaveSkipped
        val d = delayed.lastOrNull { it.machine == m.key && it.state == "waiting" }
        val report = state.reports.lastOrNull { it.machine == m.key }
        val status = when {
            skipped -> "Skipped"
            handed && report != null -> "Handed back · ${report.items.count { it.state == "done" }} objects"
            handed -> "Handed back"
            d != null -> "Starts at ${Texts.time(d.releaseAt.toLong())}"
            else -> "Waiting for `sealctl unseal --all`"
        }
        Triple(m, status, handed || skipped)
    }
    Page(null, onBack = onBack, bottom = {
        if (rows.any { !it.third }) SecondaryButton("Skip a computer", { skipping = rows.first { !it.third }.first.key })
        PrimaryButton("Continue", onContinue, enabled = rows.all { it.third })
    }) {
        Title("Hand back each computer")
        Body("On each computer, run:")
        Mono("sealctl unseal --all", size = 18)
        Body("It shows a plan and asks before it changes anything. When it asks this phone, tap Allow.")
        for ((m, status, _) in rows) Row(verticalAlignment = Alignment.CenterVertically) {
            Mono(Texts.shown(m.name, Texts.MAX_NAME), size = 14); Text(" · $status", color = Sealctl.colors.ink2)
        }
        if (rows.isEmpty()) Muted("No computers are paired.")
        val s = skipping
        if (s != null) {
            Body("Skip ${engine.machine(s)?.name?.let { Texts.shown(it, Texts.MAX_NAME) } ?: ""}? Use it when the computer is lost or already wiped. Anything it holds then opens only with your card.")
            Row { TextButton({ onSkip(s); skipping = null }) { Text("Skip") }; TextButton({ skipping = null }) { Text("Cancel") } }
        }
    }
}

