package com.sealctl.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.sealctl.app.Graph
import com.sealctl.app.MainActivity
import com.sealctl.app.Route
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.app.Waiting
import com.sealctl.core.Place as PlaceKind
import com.sealctl.core.RefuseReason
import com.sealctl.core.RequestKind
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.SecondaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.Title
import com.sealctl.designsystem.monoStyle
import com.sealctl.vault.AuthResult
import com.sealctl.vault.Biometric
import com.sealctl.vault.KeysInvalidatedException
import com.sealctl.vault.Vault
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The biometric gate of levels 2 and 3 (SPEC.md 9.6). */
sealed class GateResult {
    data object Passed : GateResult()
    data object Cancelled : GateResult()
    data object LockedOut : GateResult()
    data object Changed : GateResult()
    data class Failed(val message: String) : GateResult()
}

suspend fun biometricGate(activity: FragmentActivity, reason: String): GateResult {
    val vault = Graph.engine.vault
    val gate = try { vault.gate() } catch (e: KeysInvalidatedException) { return GateResult.Changed }
    return when (val r = Biometric.strong(activity, reason, "Cancel", gate.cipher)) {
        is AuthResult.Success -> {
            val c = r.cipher ?: return GateResult.Failed("no cipher")
            if (vault.passGate(Vault.Gate(c, gate.creating))) GateResult.Passed else GateResult.Failed("gate")
        }
        AuthResult.Cancelled -> GateResult.Cancelled
        AuthResult.LockedOut -> GateResult.LockedOut
        is AuthResult.Failed -> GateResult.Failed(r.message)
    }
}

private enum class SStep { Number, WrongNumber, Plan, CardWords, Done, Delay, NotNear, Held, NoBiometrics }

/** Levels 2 and 3 (SPEC.md 11.23): full screen, never a sheet, never from a notification button. */
@Composable
fun SensitiveScreen(activity: MainActivity, requestId: String) {
    val engine = Graph.engine
    val waiting by engine.waiting.collectAsState()
    val w = waiting.firstOrNull { it.relay.id == requestId }
    val scope = rememberCoroutineScope()
    var step by remember(requestId) { mutableStateOf(if (w?.verdict?.needsNumber == true) SStep.Number else SStep.Plan) }
    var error by remember { mutableStateOf<String?>(null) }
    var cardChecked by remember { mutableStateOf(false) }
    if (w == null && step != SStep.Delay && step != SStep.Done && step != SStep.WrongNumber) {
        Page(null) { Title(Texts.stoppedWaiting("The machine")); SecondaryButton("Close", { Ui.pop() }) }
        return
    }
    // The name stays after the request leaves the waiting list (answered, refused).
    val name = remember(requestId) { w?.let { engine.displayName(it.machine) } ?: "" }
    val level3 = (w?.verdict?.level?.toInt() ?: 3) >= 3
    fun deny() = scope.launch { w?.let { engine.deny(it) }; Ui.pop() }
    when (step) {
        SStep.Number -> NumberMatch(w!!, name, onPick = { ok ->
            if (ok) step = SStep.Plan else scope.launch { engine.wrongNumber(w); step = SStep.WrongNumber }
        }, onNone = { deny() })
        SStep.WrongNumber -> Page(null, onBack = { Ui.pop() }, bottom = {
            SecondaryButton("What to do", { Ui.pop(); w?.let { Ui.push(Route.LostMachine(it.machine.key)) } })
            PrimaryButton("Close", { Ui.pop() })
        }) {
            Gap(24)
            Title(Texts.wrongNumber(name))
            Body(Texts.WRONG_NUMBER_BODY)
            Muted(Texts.WRONG_NUMBER_WHAT)
        }
        SStep.Plan -> PlanView(w!!, name, level3, error, onConfirm = {
            scope.launch {
                if (w.verdict.needsCardWords && !cardChecked) { step = SStep.CardWords; return@launch }
                if (w.verdict.needsBiometrics) {
                    when (val g = biometricGate(activity, "Confirm handing back $name.")) {
                        GateResult.Passed -> {}
                        GateResult.Cancelled -> return@launch
                        GateResult.LockedOut -> {
                            if (level3) { engine.refuse(w, RefuseReason.NO_BIOMETRICS); error = Texts.LOCKED_OUT; return@launch }
                            step = SStep.CardWords; return@launch
                        }
                        GateResult.Changed -> { step = SStep.CardWords; return@launch }
                        is GateResult.Failed -> { error = g.message; return@launch }
                    }
                }
                val ok = engine.confirmSensitive(w)
                step = if (!ok) { error = Texts.stoppedWaiting(name); SStep.Plan } else if (engine.delaySecs(w.verdict.delaySecs.toInt()) > 0) SStep.Delay else SStep.Done
            }
        }, onDeny = { deny() })
        SStep.CardWords -> CardWords(activity, positions = 2, groups = 2, title = "Use your card", onPassed = {
            cardChecked = true
            if (w?.verdict?.needsBiometrics == true) engine.vault.resetGate()
            step = SStep.Plan
        }, onCancel = { step = SStep.Plan })
        SStep.Delay -> {
            val d = engine.local.collectAsState().value.delayed.firstOrNull { it.id == requestId }
            if (d != null) DelayView(d.id, Texts.leaving(name)) else { Ui.pop() }
        }
        SStep.Done -> Page(null, onBack = { Ui.pop() }, bottom = { PrimaryButton("Done", { Ui.pop() }) }) {
            Gap(24)
            Title("Confirmed")
            Body("$name goes ahead now. Its report shows here when it is done.")
        }
        else -> Ui.pop()
    }
}

@Composable
private fun NumberMatch(w: Waiting, name: String, onPick: (Boolean) -> Unit, onNone: () -> Unit) {
    val choices = remember(w.relay.id) { w.request.matchChoices() }
    Page(null, onBack = null, bottom = { PlainButton(Texts.NO_NUMBER, onNone) }) {
        Gap(24)
        Title(Texts.whichNumber(name))
        Body(Texts.LOOK_AT_TERMINAL)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            for (n in choices) {
                OutlinedButton(
                    onClick = { onPick(w.request.checkMatch(n)) },
                    modifier = Modifier.weight(1f).heightIn(min = 72.dp).semantics { contentDescription = "Number $n" },
                    shape = RoundedCornerShape(12.dp),
                ) { Text("$n", style = monoStyle(30, FontWeight.SemiBold), color = Sealctl.colors.ink) }
            }
        }
    }
}

@Composable
private fun PlanView(w: Waiting, name: String, level3: Boolean, error: String?, onConfirm: () -> Unit, onDeny: () -> Unit) {
    val engine = Graph.engine
    val plan = w.plan
    val kind = engine.placeKind()
    val st by engine.state.collectAsState()
    val here by engine.currentPlace.collectAsState()
    val place = st.places.firstOrNull { it.id == here }?.name
    Page(null, onBack = null, bottom = {
        ErrorText(error)
        PrimaryButton(Texts.CONFIRM, onConfirm)
        PlainButton("Deny", onDeny)
    }) {
        Gap(12)
        when (w.verdict.kind) {
            RequestKind.UNSEAL -> {
                val all = plan?.all == true || level3
                val first = plan?.items?.firstOrNull { it.kind != "pairing" }
                Title(if (all) Texts.handBackAll(name) else "Hand back ${first?.kind ?: ""} ${first?.name ?: ""} from $name?")
                if (all) Body(Texts.HAND_BACK_ALL_BODY)
                plan?.items?.forEachIndexed { i, it ->
                    Row { Text("${i + 1}", style = monoStyle(15), color = Sealctl.colors.muted, modifier = Modifier.width(28.dp)); Mono("${label(it.kind)} · ${it.name}") }
                }
            }
            RequestKind.KEYS -> {
                val s = w.request.ctx()?.subject
                Title("Let sealctl seal take over ${s?.kind ?: ""} ${s?.name ?: ""} on $name?")
                for (i in w.request.items()) Mono("${i.purpose} · ${i.`object`?.path ?: i.id}")
            }
            RequestKind.REWRAP -> {
                Title("Move $name to new words?")
                Body("${w.request.items().size} objects. Each takes seconds.")
            }
            else -> Title(Texts.title(Texts.facts(w, name)))
        }
        if (level3) {
            Gap(4)
            when {
                kind == PlaceKind.TRUSTED -> Body("At ${place ?: "your trusted place"}: ${Texts.AT_TRUSTED}")
                kind == PlaceKind.NO_LOCATION -> Body(Texts.AWAY_NO_LOCATION)
                else -> Body(Texts.AWAY)
            }
        }
        if (w.verdict.needsCardWords) Muted("This phone has no strong fingerprint or face unlock: two words from your card confirm it instead.")
    }
}

fun label(kind: String) = when (kind) { "ai" -> "AI tools"; "local" -> "local files"; else -> kind }

/** The countdown of a delayed approval, with Cancel (SPEC.md 11.23 Delay). */
@Composable
fun DelayView(id: String, title: String) {
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    val local by engine.local.collectAsState()
    val d = local.delayed.firstOrNull { it.id == id }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(id) { while (true) { now = System.currentTimeMillis(); delay(1000) } }
    LaunchedEffect(id) { while (true) { engine.refreshDelayed(); delay(15_000) } }
    Page(null, bottom = {
        if (d?.state == "waiting") PrimaryButton("Cancel", { scope.launch { engine.cancelDelayed(id) } })
        else PrimaryButton("Close", { Ui.pop() })
    }) {
        Gap(24)
        Title(title)
        when (d?.state) {
            "waiting" -> {
                Text(Texts.startsAt(d.releaseAt.toLong(), now), fontSize = 20.sp, color = Sealctl.colors.waiting, fontWeight = FontWeight.SemiBold)
                Body(Texts.DELAY_BODY)
            }
            "cancelled" -> Body(if (d.cancelledBy == null || d.cancelledBy == "phone") Texts.CANCELLED_HERE
                else Texts.cancelledFrom(engine.machine(d.cancelledBy!!)?.let { engine.displayName(it) } ?: "a computer"))
            "released", "finished" -> Body("The hour is over. The computer goes ahead.")
            else -> Body("This waited too long. Start again.")
        }
    }
}

@Composable
fun DelayedScreen(id: String) {
    val engine = Graph.engine
    val d = engine.local.collectAsState().value.delayed.firstOrNull { it.id == id }
    val title = when (d?.what) {
        "words" -> "Showing your words"
        "delete" -> "Deleting your relay data"
        "leave" -> "Leaving sealctl"
        else -> Texts.leaving(d?.machine?.let { k -> engine.machine(k)?.let { engine.displayName(it) } } ?: "this computer")
    }
    DelayView(id, title)
}

/** The hand-back report (SPEC.md 11.23 Report). */
@Composable
fun ReportScreen(id: String) {
    val engine = Graph.engine
    val r = engine.state.collectAsState().value.reports.firstOrNull { it.id == id }
    Page(null, bottom = { PrimaryButton("Done", { Ui.pop() }) }) {
        if (r == null) { Title("Report"); Muted("This report is not on this phone."); return@Page }
        Title("${r.machineName} handed everything back")
        val done = r.items.count { it.state == "done" }
        Muted("$done of ${r.items.size} done · ${Texts.time(r.time.toLong())}")
        for (i in r.items) {
            val color = when (i.state) { "failed" -> Sealctl.colors.waiting; "skipped" -> Sealctl.colors.muted; else -> Sealctl.colors.ink }
            Mono("${label(i.kind)} · ${i.name} → ${i.to}", color = color, size = 14)
            if (i.state == "failed") Text("Run `sealctl unseal --resume` on that computer.", color = Sealctl.colors.waiting, fontSize = 13.sp)
        }
        if (r.run.isNotEmpty()) { Body("Run folder on that computer:"); Mono(r.run, size = 13) }
        Body("Your other computers were told.")
    }
}

/**
 * Typed words from the card (level 2 fallback, yearly check, Leave sealctl). The words are
 * opened behind the words prompt and checked inside the core; nothing typed is kept.
 */
@Composable
fun CardWords(activity: FragmentActivity, positions: Int, groups: Int, title: String, body: String? = null, onPassed: () -> Unit, onCancel: () -> Unit) {
    val scope = rememberCoroutineScope()
    var opened by remember { mutableStateOf(Graph.words.hasSession()) }
    val pos = remember { Graph.words.positions(positions, groups) }
    val typed = remember { mutableListOf<String>().apply { repeat(positions) { add("") } } }
    var focus by remember { mutableIntStateOf(0) }
    var prefix by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var tick by remember { mutableIntStateOf(0) }
    SecureScreen()
    if (!opened) {
        Page(null, onBack = onCancel, bottom = {
            ErrorText(message)
            PrimaryButton("Use my card", {
                scope.launch {
                    when (val r = Graph.words.unlockForCheck(activity)) {
                        is AuthResult.Success -> opened = true
                        AuthResult.Cancelled -> {}
                        else -> message = (r as? AuthResult.Failed)?.message ?: Texts.LOCKED_OUT
                    }
                }
            })
        }) { Gap(24); Title(title); Body(body ?: "Have your card ready. Type ${if (positions == 2) "two" else "three"} words from it.") }
        return
    }
    Page(null, onBack = { Graph.words.release(); onCancel() }, bottom = {
        ErrorText(message)
        WordKeypad(prefix, onChange = { prefix = it; typed[focus] = it; tick++ }, onWord = { word ->
            typed[focus] = word; prefix = ""; tick++
            if (focus < positions - 1) focus++
        })
        PrimaryButton("Check", {
            val wrong = pos.indices.firstOrNull { !Graph.words.matches(pos[it], typed[it]) }
            if (wrong == null) { Graph.words.release(); onPassed() } else message = "That's not word ${pos[wrong]} on these words."
        }, enabled = typed.all { it.isNotEmpty() })
    }) {
        Title(title)
        Body(body ?: "Have your card ready. Type ${if (positions == 2) "two" else "three"} words from it.")
        androidx.compose.runtime.key(tick) {
            pos.forEachIndexed { i, p -> WordField(p, typed[i], focus == i, false) { focus = i; prefix = typed[i].take(4) } }
        }
        Spacer(Modifier.height(4.dp))
    }
}

