package com.sealctl.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sealctl.app.Graph
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.app.Waiting
import com.sealctl.core.app.ReplyOption
import com.sealctl.designsystem.Fact
import com.sealctl.designsystem.MachineState
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.SecondaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.StateDot
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The approval card as a sheet (SPEC.md 11.7): the oldest waiting request first. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ApprovalSheet(list: List<Waiting>) {
    val focus by Ui.focusRequest.collectAsState()
    val w = list.firstOrNull { it.relay.id == focus } ?: list.minBy { it.seenAt }
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(onDismissRequest = { /* stays until answered or closed */ }, sheetState = sheet, containerColor = Sealctl.colors.surface) {
        ApprovalCard(w, more = list.size - 1)
    }
}

@Composable
fun ApprovalCard(w: Waiting, more: Int) {
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    var busy by remember(w.relay.id) { mutableStateOf(false) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(w.relay.id) { while (true) { now = System.currentTimeMillis(); delay(1000) } }
    val name = engine.displayName(w.machine)
    // Machine-controlled values are sanitised and cut; a tap on the title or facts shows them whole.
    var whole by remember(w.relay.id) { mutableStateOf(false) }
    val short = Texts.facts(w, name)
    val full = Texts.facts(w, name, short = false)
    val f = if (whole) full else short
    val local by engine.local.collectAsState()
    Column(
        Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StateDot(if (w.expired) MachineState.Locked else MachineState.Waiting)
            val secs = ((now - w.relay.created.coerceAtMost(now)) / 1000)
            Text(Texts.waitingFor(secs), color = if (w.expired) Sealctl.colors.muted else Sealctl.colors.waiting, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
        }
        val title = Texts.title(f)
        val subject = Texts.titleSubject(f)
        Text(
            buildAnnotatedString {
                if (subject != null && title.contains(subject)) {
                    val i = title.indexOf(subject)
                    append(title.substring(0, i))
                    withStyle(SpanStyle(fontFamily = FontFamily.Monospace, color = Sealctl.colors.accent)) { append(subject) }
                    append(title.substring(i + subject.length))
                } else append(title)
            },
            fontSize = 24.sp, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink,
            modifier = Modifier.clickable(enabled = short != full) { whole = !whole }.semantics { contentDescription = title },
        )
        Column(Modifier.clickable(enabled = short != full) { whole = !whole }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            f.command?.let { Fact("For", it) }
            f.cwd?.let { Fact("In", it) }
            Fact("From", listOfNotNull(name, f.agent).joinToString(" · "))
            if (short != full) Muted(if (whole) "Tap to shorten." else "Cut to fit. Tap to show in full.")
        }
        Texts.note(w)?.let { Muted(it) }
        if (w.verdict.agentFirstUse && !local.agentNoteShown) Muted(Texts.AGENT_NOTE)
        if (w.expired) {
            Text(Texts.stoppedWaiting(name), color = Sealctl.colors.ink2)
            SecondaryButton("Close", { engine.dismiss(w.relay.id) })
        } else {
            w.verdict.options.forEachIndexed { i, o ->
                val label = Texts.button(o, w.verdict.kind)
                val onClick: () -> Unit = {
                    if (!busy) {
                        busy = true
                        scope.launch {
                            if (o != ReplyOption.DENY) haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                            if (!engine.answer(w.relay.id, o)) busy = false
                            Ui.focusRequest.value = null
                        }
                    }
                }
                when {
                    o == ReplyOption.DENY -> PlainButton(label, onClick)
                    i == 0 -> PrimaryButton(label, onClick, enabled = !busy)
                    else -> SecondaryButton(label, onClick, enabled = !busy)
                }
            }
            if (more > 0) Muted(Texts.moreWaiting(more))
            val st by engine.state.collectAsState()
            val here by engine.currentPlace.collectAsState()
            if (w.verdict.answersByItselfHere) {
                val place = st.places.firstOrNull { it.id == here }?.name
                if (place != null) Muted(Texts.answersHere(place))
            }
        }
        Gap(8)
    }
}
