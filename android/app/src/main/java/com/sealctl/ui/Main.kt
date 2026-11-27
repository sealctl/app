package com.sealctl.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.sealctl.app.Graph
import com.sealctl.app.MachineView
import com.sealctl.app.MainActivity
import com.sealctl.app.Ready
import com.sealctl.app.Route
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.app.Waiting
import com.sealctl.core.app.Asking
import com.sealctl.core.app.DelayPhase
import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.delayPhase
import com.sealctl.core.app.LocalState
import com.sealctl.core.app.Machine
import com.sealctl.core.app.MachineSession
import com.sealctl.core.app.machineShortName
import com.sealctl.designsystem.Banner
import com.sealctl.designsystem.MachineState
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.StateLabel
import com.sealctl.designsystem.SurfaceCard
import com.sealctl.notify.Notify
import kotlinx.coroutines.launch

@Composable
fun MainScreen(activity: MainActivity) {
    val top = Ui.stack.lastOrNull()
    val engine = Graph.engine
    val waiting by engine.waiting.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { engine.toasts.collect { snackbar.showSnackbar(it.text) } }
    // Sensitive requests open full screen as soon as they arrive in the foreground.
    LaunchedEffect(waiting, Ui.stack.size) {
        val inApp = waiting.firstOrNull { it.verdict.asking == Asking.IN_APP && !it.expired }
        if (inApp != null && Ui.stack.none { it is Route.Sensitive && it.requestId == inApp.relay.id }) {
            Ui.stack.removeAll { it is Route.Sensitive }
            Ui.push(Route.Sensitive(inApp.relay.id))
        }
    }
    Box(Modifier.fillMaxSize()) {
        when (top) {
            null -> Tabs()
            is Route.MachineDetail -> MachineDetailScreen(activity, top.key)
            is Route.LostMachine -> LostMachineScreen(top.key)
            is Route.Pair -> PairingScreen(activity, top)
            Route.Answers -> AnswersScreen()
            Route.Places -> PlacesScreen(activity)
            Route.PlacesAlways -> PlacesAlwaysScreen(onDone = { Ui.pop() })
            Route.Devices -> DevicesScreen()
            Route.About -> AboutScreen()
            Route.Licences -> LicencesScreen()
            Route.ShowWords -> ShowWordsScreen(activity)
            Route.DeleteRelay -> DeleteRelayScreen(activity)
            Route.Erase -> EraseScreen(activity)
            Route.Leave -> LeaveScreen(activity)
            is Route.Report -> ReportScreen(top.id)
            is Route.Delayed -> DelayedScreen(activity, top.id)
            is Route.Sensitive -> SensitiveScreen(activity, top.requestId)
            is Route.Activity -> ActivityScreen("Activity", onBack = { Ui.pop() }, top.machine)
            is Route.Inventory -> Page("Inventory") { InventoryList(top.machine) }
        }
        // The approval card: a sheet over any screen (SPEC.md 11.7).
        val oneTap = waiting.filter { it.verdict.asking == Asking.ONE_TAP }
        if (oneTap.isNotEmpty() && top !is Route.Sensitive) ApprovalSheet(oneTap)
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = 96.dp))
    }
}

@Composable
private fun Tabs() {
    // The tab survives pushed screens: going back returns to it.
    var tab by Ui.tab
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Box(Modifier.weight(1f)) {
            when (tab) {
                0 -> MachinesTab()
                1 -> ActivityScreen("Activity", onBack = null, machine = null)
                2 -> Page("Inventory", onBack = null) { InventoryList(null) }
                else -> SettingsTab()
            }
        }
        NavigationBar(containerColor = Sealctl.colors.surface) {
            val items = listOf("Machines" to Icons.Filled.Home, "Activity" to Icons.Filled.List, "Inventory" to Icons.Filled.Lock, "Settings" to Icons.Filled.Settings)
            items.forEachIndexed { i, (label, icon) ->
                NavigationBarItem(
                    selected = tab == i, onClick = { tab = i },
                    icon = { Icon(icon, contentDescription = null) }, label = { Text(label) },
                    colors = NavigationBarItemDefaults.colors(selectedIconColor = Sealctl.colors.accent, selectedTextColor = Sealctl.colors.accent, indicatorColor = Sealctl.colors.accentSoft),
                )
            }
        }
    }
}

@Composable
private fun MachinesTab() {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val waiting by engine.waiting.collectAsState()
    val banners by engine.banners.collectAsState()
    val local by engine.local.collectAsState()
    // A lock sent shows "Locking…" at once (SPEC.md 11.8): a change redraws the list.
    val locks by engine.lockMarks.collectAsState()
    val context = ctx()
    val scope = rememberCoroutineScope()
    // Read by the parts that count time, not here: the tab itself recomposes only on a change.
    val clock = rememberNow()
    // System settings the person may change and come back from: read on each return, not on
    // every recomposition (each is a call into the system).
    fun restricted() = context.getSystemService(android.app.ActivityManager::class.java)?.isBackgroundRestricted == true
    var notificationsOff by remember { mutableStateOf(!Notify.allowed(context)) }
    var backgroundRestricted by remember { mutableStateOf(restricted()) }
    LifecycleResumeEffect(Unit) {
        notificationsOff = !Notify.allowed(context)
        backgroundRestricted = restricted()
        onPauseOrDispose {}
    }
    // The short names, models and sessions come from the shared core: once per change of the machines, not every second.
    val machines = remember(state.machines) {
        state.machines.filter { !it.deleted }.map { Named(it, machineShortName(it), MachineView.modelOf(it), MachineView.sessionOf(it)) }
    }
    Page("Machines", onBack = null) {
        if (banners.offline) Banner(Texts.OFFLINE)
        else if (banners.relayDown) Banner(Texts.RELAY_DOWN)
        RateLimitedBanner(banners.rateLimitedUntil, clock)
        if (banners.clockSkew) Banner(Texts.CLOCK) { TextButton({ context.startActivity(android.content.Intent(android.provider.Settings.ACTION_DATE_SETTINGS).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }) { Text("Open settings") } }
        if (banners.signatureRefused) Banner(Texts.SIGNATURE)
        if (notificationsOff) Banner(Texts.NOTIFICATIONS_OFF) { TextButton({ openAppSettings(context) }) { Text("Open settings") } }
        if (backgroundRestricted) Banner(Texts.BACKGROUND_RESTRICTED) { TextButton({ openAppSettings(context) }) { Text("Open settings") } }
        PlacesAlwaysBanner()
        DelayedBanners(local.delayed, clock) { id -> scope.launch { engine.cancelDelayed(id) } }
        val waitingCount = waiting.count { !it.expired }
        if (waitingCount > 0) Banner("$waitingCount waiting on this phone", tone = Sealctl.colors.accentSoft) {
            TextButton({
                val w = waiting.first { !it.expired }
                if (w.verdict.asking == Asking.IN_APP) Ui.push(Route.Sensitive(w.relay.id)) else Ui.focusRequest.value = w.relay.id
            }) { Text("Show") }
        }
        if (machines.isEmpty()) {
            Gap(24)
            Muted("No machines yet. On your computer, run `sealctl pair` and scan the code.")
            PrimaryButton("Scan code", { Ui.push(Route.Pair()) })
        } else {
            MachineList(machines, waiting, local, locks, clock)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                com.sealctl.designsystem.SecondaryButton("Pair a machine", { Ui.push(Route.Pair()) }, Modifier.weight(1f))
                com.sealctl.designsystem.SecondaryButton("Lock all", {
                    scope.launch { val n = engine.lockAll(); Ui.toast("Locked $n machines.") }
                }, Modifier.weight(1f))
            }
        }
    }
}

/** A machine with its short name, model and session, as the shared core gives them. */
private data class Named(val machine: Machine, val name: String, val model: String?, val session: MachineSession?)

@Composable
private fun RateLimitedBanner(until: Long, clock: State<Long>) {
    if (until > clock.value) Banner(Texts.rateLimited(until))
}

/**
 * "Unseal all starts at 14:05 on …" for each delayed approval still counting down, and for an
 * action this install started on the phone, "… ready until 12:37" once its wait is over, until
 * it expires (11.23).
 */
@Composable
private fun DelayedBanners(delayed: List<DelayedAction>, clock: State<Long>, onCancel: (String) -> Unit) {
    val engine = Graph.engine
    val now = clock.value
    for (d in delayed) {
        val ready = when (delayPhase(d, now.toULong())) {
            DelayPhase.WAITING -> false
            DelayPhase.READY -> if (Ready.isOwn(d)) true else continue
            else -> continue
        }
        val name = if (d.what == Texts.PLACE) d.reasonPlace ?: "This place"
            else d.machine?.let { k -> engine.machine(k)?.let { engine.displayName(it) } } ?: "This phone"
        val text = if (ready) Texts.readyBanner(d.what, d.expires.toLong()) else Texts.delayedAt(d.what, name, d.releaseAt.toLong())
        Banner(text, tone = Sealctl.colors.accentSoft) {
            Row {
                if (ready) TextButton({ Ui.push(Route.Delayed(d.id)) }) { Text(Texts.readyButton(d.what), fontWeight = FontWeight.SemiBold) }
                else TextButton({ Ui.push(Route.Delayed(d.id)) }) { Text("Show") }
                TextButton({ onCancel(d.id) }) { Text("Cancel") }
            }
        }
    }
}

/**
 * The machines in their order (11.17), from the machines and names read once per change. Only
 * this part follows the clock: the waiting time, the idle time or time left and "seen … ago" each second
 * (an active machine's row stays the same).
 * [waiting], [local] and [locks] are what [MachineView.of] reads besides: a change to them redraws it.
 */
@Composable
private fun MachineList(
    machines: List<Named>,
    @Suppress("UNUSED_PARAMETER") waiting: List<Waiting>,
    @Suppress("UNUSED_PARAMETER") local: LocalState,
    @Suppress("UNUSED_PARAMETER") locks: Map<String, com.sealctl.app.LockMark>,
    clock: State<Long>,
) {
    val engine = Graph.engine
    val now = clock.value
    val views = MachineView.sorted(machines.map { MachineView.of(it.machine, engine, now, it.name, it.model, it.session) })
    for (v in views) MachineRow(v, now)
}

/** A machine on the list (11.17): its short name, its state, then the model and when it was seen. */
@Composable
private fun MachineRow(v: MachineView, now: Long) {
    SurfaceCard(Modifier.clickable { Ui.push(Route.MachineDetail(v.machine.key)) }.clearAndSetSemantics { contentDescription = v.label(now) }) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(v.name, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            StateLabel(v.state, v.row)
            Muted(v.sub(now))
            v.unseen(now)?.let { Text(it, color = Sealctl.colors.waiting, fontSize = 14.sp) }
        }
    }
}

@Composable
fun InventoryList(machine: String?) {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val items = state.inventory.filter { !it.deleted && (machine == null || it.machine == machine) }
    if (items.isEmpty()) {
        Muted("No keys handed out yet.")
        return
    }
    val current = state.words?.fingerprint
    for ((m, list) in items.groupBy { it.machine }) {
        SectionLabel(engine.machine(m)?.let { engine.displayName(it) } ?: m.take(8))
        for (i in list) {
            SurfaceCard {
                val purpose = when (i.purpose) { "secrets" -> "Secret store"; "secret" -> "Own-approval secret"; "volume" -> "Volume"; "backup" -> "Backup"; else -> i.purpose }
                com.sealctl.designsystem.Line(com.sealctl.designsystem.plain(purpose, FontWeight.SemiBold), com.sealctl.designsystem.plain(" "), com.sealctl.designsystem.code("${i.id.take(4)}…${i.id.takeLast(2)}", size = 14), com.sealctl.designsystem.plain(" · seed "), com.sealctl.designsystem.code(i.words, size = 14), color = Sealctl.colors.ink)
                if (i.path.isNotEmpty()) Mono(listOfNotNull(i.path, if (i.size > 0u) "${i.size.toLong() / 1000} KB" else null).joinToString(" · "), size = 13, color = Sealctl.colors.ink2)
                Muted("First used ${Texts.isoDate(i.firstUse.toLong())} · last used ${Texts.ago(i.lastUse.toLong())}")
                if (i.stale) Text("Not seen since ${Texts.isoDate(i.lastUse.toLong())}", color = Sealctl.colors.waiting)
                if (current != null && i.words != current) Text("Seed ${i.words} (retired)", color = Sealctl.colors.muted)
            }
        }
    }
}

