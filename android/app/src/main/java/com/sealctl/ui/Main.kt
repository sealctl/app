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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.sealctl.app.Graph
import com.sealctl.app.MachineView
import com.sealctl.app.MainActivity
import com.sealctl.app.Route
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.core.app.Asking
import com.sealctl.designsystem.Banner
import com.sealctl.designsystem.MachineState
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.StateLabel
import com.sealctl.designsystem.SurfaceCard
import com.sealctl.notify.Notify
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun MainScreen(activity: MainActivity) {
    val top = Ui.stack.lastOrNull()
    val engine = Graph.engine
    val waiting by engine.waiting.collectAsState()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { engine.toasts.collect { snackbar.showSnackbar(it.text) } }
    // Sensitive requests open full screen as soon as they arrive in the foreground.
    LaunchedEffect(waiting) {
        val inApp = waiting.firstOrNull { it.verdict.asking == Asking.IN_APP && !it.expired }
        if (inApp != null && Ui.stack.none { it is Route.Sensitive }) Ui.push(Route.Sensitive(inApp.relay.id))
    }
    Box(Modifier.fillMaxSize()) {
        when (top) {
            null -> Tabs()
            is Route.MachineDetail -> MachineDetailScreen(activity, top.key)
            is Route.LostMachine -> LostMachineScreen(top.key)
            is Route.Pair -> PairingScreen(activity, top)
            Route.Answers -> AnswersScreen()
            Route.Places -> PlacesScreen()
            Route.Devices -> DevicesScreen()
            Route.About -> AboutScreen()
            Route.ShowWords -> ShowWordsScreen(activity)
            Route.DeleteRelay -> DeleteRelayScreen(activity)
            Route.Erase -> EraseScreen(activity)
            Route.Leave -> LeaveScreen(activity)
            is Route.Report -> ReportScreen(top.id)
            is Route.Delayed -> DelayedScreen(top.id)
            is Route.Sensitive -> SensitiveScreen(activity, top.requestId)
            is Route.Activity -> Page("Activity") { ActivityList(top.machine) }
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
                1 -> Page("Activity", onBack = null) { ActivityList(null) }
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
    val context = ctx()
    val scope = rememberCoroutineScope()
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    val views = remember(state, waiting, now, local) { MachineView.sorted(state.machines.filter { !it.deleted }.map { MachineView.of(it, engine, now) }) }
    Page("Machines", onBack = null) {
        if (banners.offline) Banner(Texts.OFFLINE)
        else if (banners.relayDown) Banner(Texts.RELAY_DOWN)
        if (banners.rateLimitedUntil > now) Banner(Texts.rateLimited(banners.rateLimitedUntil))
        if (banners.clockSkew) Banner(Texts.CLOCK) { TextButton({ context.startActivity(android.content.Intent(android.provider.Settings.ACTION_DATE_SETTINGS).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)) }) { Text("Open settings") } }
        if (banners.signatureRefused) Banner(Texts.SIGNATURE)
        if (!Notify.allowed(context)) Banner(Texts.NOTIFICATIONS_OFF) { TextButton({ openAppSettings(context) }) { Text("Open settings") } }
        val am = context.getSystemService(android.app.ActivityManager::class.java)
        if (am?.isBackgroundRestricted == true) Banner(Texts.BACKGROUND_RESTRICTED) { TextButton({ openAppSettings(context) }) { Text("Open settings") } }
        for (d in local.delayed.filter { it.state == "waiting" && it.releaseAt.toLong() > now }) {
            val name = d.machine?.let { k -> engine.machine(k)?.let { engine.displayName(it) } } ?: "This phone"
            Banner(Texts.handsBackAt(name, d.releaseAt.toLong()), tone = Sealctl.colors.accentSoft) {
                Row {
                    TextButton({ Ui.push(Route.Delayed(d.id)) }) { Text("Show") }
                    TextButton({ scope.launch { engine.cancelDelayed(d.id) } }) { Text("Cancel") }
                }
            }
        }
        val waitingCount = waiting.count { !it.expired }
        if (waitingCount > 0) Banner("$waitingCount waiting on this phone", tone = Sealctl.colors.accentSoft)
        if (views.isEmpty()) {
            Gap(24)
            Muted("No machines yet. On your computer, run `sealctl pair` and scan the code.")
            PrimaryButton("Scan code", { Ui.push(Route.Pair()) })
        } else {
            for (v in views) MachineRow(v)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                com.sealctl.designsystem.SecondaryButton("Pair a machine", { Ui.push(Route.Pair()) }, Modifier.weight(1f))
                com.sealctl.designsystem.SecondaryButton("Lock all", {
                    scope.launch { val n = engine.lockAll(); Ui.toast("Locked $n machines.") }
                }, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun MachineRow(v: MachineView) {
    SurfaceCard(Modifier.clickable { Ui.push(Route.MachineDetail(v.machine.key)) }.semantics { contentDescription = "${v.name}, ${v.row}" }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                if (v.machine.nickname != null) Text(v.name, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink)
                else Mono(v.name, weight = FontWeight.SemiBold)
            }
            StateLabel(v.state, v.row)
        }
        val sub = listOfNotNull(
            if (v.machine.nickname != null) v.machine.name else null,
            v.machine.model,
            "seen ${Texts.ago(v.machine.lastSeen?.toLong())}",
        ).joinToString(" · ")
        Muted(sub)
        if (v.machine.flagged) Text("Not seen for ${(System.currentTimeMillis() - (v.machine.lastSeen?.toLong() ?: 0)) / 86_400_000} days", color = Sealctl.colors.waiting, fontSize = 14.sp)
    }
}

@Composable
fun ActivityList(machine: String?) {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val entries = remember(state, machine) { com.sealctl.app.safe { engine.store.usage(machine, null, 500u) } ?: emptyList() }
    val month = Texts.isoDate(System.currentTimeMillis()).take(7)
    val summary = state.summaries.firstOrNull { it.month == month }
    SurfaceCard {
        Text(java.time.YearMonth.parse(month).month.getDisplayName(java.time.format.TextStyle.FULL, androidx.compose.ui.platform.LocalConfiguration.current.locales[0]),
            fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink, fontSize = 18.sp)
        Text("${summary?.keysUsed ?: 0} keys used on ${summary?.machines?.size ?: 0} machines", color = Sealctl.colors.ink2)
        Text("${summary?.requestsDeclined ?: 0} requests declined", color = Sealctl.colors.ink2)
        Muted("No key was written to disk.")
    }
    for (r in state.reports.sortedByDescending { it.time }.take(5)) {
        SurfaceCard(Modifier.clickable { Ui.push(Route.Report(r.id)) }) {
            Text("${r.machineName} handed everything back", fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink)
            Muted("${r.items.count { it.state == "done" }} of ${r.items.size} done · ${Texts.mediumDate(r.time.toLong())}")
        }
    }
    if (entries.isEmpty()) {
        Muted("Nothing yet. Every use of your keys shows here.")
        return
    }
    var day = ""
    for (e in entries) {
        val d = Texts.mediumDate(e.time.toLong())
        if (d != day) { day = d; SectionLabel(d) }
        val name = engine.machine(e.machine)?.let { engine.displayName(it) } ?: e.machine.take(8)
        val outcome = when (e.outcome) {
            "one_tap" -> "One tap"; "automatic" -> "Answered by itself"; "in_session" -> "In session"
            "once" -> "Allowed once"; "denied" -> "Denied"; "expired" -> "Expired"; "confirmed" -> "Confirmed"; else -> e.outcome
        }
        val parts = listOfNotNull(Texts.time(e.time.toLong()), e.key.ifEmpty { null }, e.agent, e.repo, e.command, name, outcome)
        Mono(parts.joinToString(" · "), size = 13, color = Sealctl.colors.ink2)
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
                Row { Text(purpose, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink); Text(" "); Mono("${i.id.take(4)}…${i.id.takeLast(2)}", size = 14); Text(" · words "); Mono(i.words, size = 14) }
                if (i.path.isNotEmpty()) Mono(listOfNotNull(i.path, if (i.size > 0u) "${i.size.toLong() / 1000} KB" else null).joinToString(" · "), size = 13, color = Sealctl.colors.ink2)
                Muted("First used ${Texts.isoDate(i.firstUse.toLong())} · last used ${Texts.ago(i.lastUse.toLong())}")
                if (i.stale) Text("Not seen since ${Texts.isoDate(i.lastUse.toLong())}", color = Sealctl.colors.waiting)
                if (current != null && i.words != current) Text("Words ${i.words} (retired)", color = Sealctl.colors.muted)
            }
        }
    }
}

