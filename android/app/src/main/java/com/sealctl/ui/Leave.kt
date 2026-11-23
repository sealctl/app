package com.sealctl.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
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
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.SecondaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.Title
import kotlinx.coroutines.delay
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
    fun go(n: Int, skipped: List<String> = local.leaveSkipped) = engine.applyLocal(LocalEvent.SetLeave(n.toUInt(), skipped))
    fun cancel() { go(0, emptyList()); Ui.pop() }
    // Skipped computers keep their names after step 5 forgets every machine.
    fun skippedName(key: String) = engine.state.value.machines.firstOrNull { it.key == key }?.name
        ?.let { Texts.shown(it, Texts.MAX_NAME) } ?: key.take(8)

    when (step) {
        1 -> Page(null, onBack = { cancel() }, bottom = {
            PrimaryButton("Start", {
                scope.launch {
                    when (biometricGate(activity, "Confirm leaving sealctl.")) {
                        GateResult.Passed -> go(2)
                        GateResult.Cancelled -> {}
                        GateResult.LockedOut -> error = Texts.LOCKED_OUT
                        else -> error = Texts.NO_BIOMETRICS
                    }
                }
            })
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
            val pending = local.delayed.lastOrNull { it.what == "leave" && it.state in setOf("waiting", "released") }
            var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
            LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
            if (pending != null && pending.releaseAt.toLong() > now) {
                DelayView(pending.id, "Leaving sealctl")
                return
            }
            Page(null, onBack = { cancel() }, bottom = {
                ErrorText(error)
                PrimaryButton(Texts.CONFIRM, {
                    scope.launch {
                        when (biometricGate(activity, "Confirm leaving sealctl.")) {
                            GateResult.Passed -> {}
                            GateResult.Cancelled -> return@launch
                            GateResult.LockedOut -> { error = Texts.LOCKED_OUT; return@launch }
                            else -> { error = Texts.NO_BIOMETRICS; return@launch }
                        }
                        if (pending != null) {
                            when (engine.finishPhoneAction(pending.id)) {
                                null -> go(4)
                                "relay" -> error = "The relay isn't answering, and sealctl can't finish until it confirms nothing was cancelled."
                                "too_early" -> error = "Not yet."
                                "gone" -> error = "This waited too long. Start again."
                                else -> error = "Cancelled from another device. Nothing happened."
                            }
                            return@launch
                        }
                        val delayed = try { engine.startPhoneAction("leave") } catch (e: Exception) { error = Texts.RELAY_DOWN; return@launch }
                        if (delayed == null) go(4)
                    }
                })
                PlainButton("Cancel", { cancel() })
            }) {
                Gap(24)
                Title("Delete your data and the last copy of your words?")
                Body("Next, this phone deletes your data on the relay and removes your words from your Google backup.")
                Body(
                    if (pending != null) "The hour is over. Confirm again to finish."
                    else if (engine.delayLifted()) "At your trusted place: this happens as soon as you confirm."
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
    LaunchedEffect(Unit) { while (true) { engine.refreshMachines(); engine.refreshDelayed(); delay(5_000) } }
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

