package com.sealctl.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.fragment.app.FragmentActivity
import com.sealctl.app.BuildConfig
import com.sealctl.app.Graph
import com.sealctl.app.MachineView
import com.sealctl.app.MainActivity
import com.sealctl.app.Push
import com.sealctl.app.Route
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.core.Place as PlaceKind
import com.sealctl.core.app.Event
import com.sealctl.core.app.LocalEvent
import com.sealctl.core.app.LocationAccess
import com.sealctl.core.app.answerDaysLeft
import com.sealctl.core.app.appRulesVersion
import com.sealctl.core.app.runningPhoneAction
import com.sealctl.core.coreVersion
import com.sealctl.core.protocolVersion
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.SecondaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.StateLabel
import com.sealctl.designsystem.SurfaceCard
import com.sealctl.designsystem.Title
import com.sealctl.designsystem.Wordmark
import com.sealctl.vault.AuthResult
import com.sealctl.relay.ConflictException
import com.sealctl.relay.RelayException
import com.sealctl.relay.contentOrNull
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonPrimitive

@Composable
fun SettingsTab() {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val local by engine.local.collectAsState()
    val context = ctx()
    val scope = rememberCoroutineScope()
    var testMessage by remember { mutableStateOf<String?>(null) }
    var backupMessage by remember { mutableStateOf<String?>(null) }
    val words = state.words
    Page("Settings", onBack = null) {
        PlacesAlwaysBanner()
        SectionLabel("Words")
        if (words != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Body("Seed "); Mono(words.fingerprint, weight = FontWeight.SemiBold)
                Body(" · written on ${words.writtenOn} · next check ${com.sealctl.core.app.addDays(words.lastCheck ?: words.writtenOn, 365)}")
            }
        }
        SecondaryButton("Show words", { Ui.push(Route.ShowWords) })
        SectionLabel("Backups")
        ToggleRow("Google backup", state.settings.keychainBackup) {
            backupMessage = null
            if (!it) {
                engine.apply(Event.SetSettings(state.settings.copy(keychainBackup = false)))
                scope.launch { Graph.blockStore.delete() }
            } else (context as? FragmentActivity)?.let { activity -> scope.launch { backupMessage = enableGoogleBackup(activity) } }
        }
        ToggleRow("Encrypted backup on the relay", state.settings.relayBackup) {
            backupMessage = null
            engine.apply(Event.SetSettings(state.settings.copy(relayBackup = it)), upload = it)
            if (!it) scope.launch {
                if (!clearRelayBackup()) backupMessage = "The copy on the relay couldn't be removed yet. Turn the backup on and off again to retry."
            }
        }
        ErrorText(backupMessage)
        if (local.lastUpload > 0u) Muted("Saved ${Texts.ago(local.lastUpload.toLong())}")
        if (local.backupShortened) Muted("The relay backup is full. Old inventory entries were shortened.")
        NavRow("Places", "${state.places.count { !it.deleted }}") { Ui.push(Route.Places) }
        NavRow("Answers", "${state.answers.count { !it.deleted }}") { Ui.push(Route.Answers) }
        SectionLabel("Notifications")
        Body(if (com.sealctl.notify.Notify.allowed(context)) "On" else "Off")
        SecondaryButton("Send a test request", {
            scope.launch {
                testMessage = null
                val id = engine.deviceId()
                testMessage = try {
                    engine.relay.testPush(id); null
                } catch (e: RelayException) {
                    when {
                        e.code == "push_failed" && e.body["removed"]?.jsonPrimitive?.booleanOrNull == true -> {
                            engine.registerPush(Push.renew())
                            "This phone's notification address was out of date. It has been renewed. Try again."
                        }
                        e.code == "push_failed" -> "The push service refused the test (${e.body["reason"]?.jsonPrimitive?.contentOrNull() ?: ""})."
                        e.code == "push_not_configured" -> "The relay can't send notifications right now."
                        e.code == "unknown_device" -> { engine.registerPush(); "This phone was registered again. Try again." }
                        else -> Texts.relayError(e.code)
                    }
                } catch (e: Exception) { Texts.RELAY_DOWN }
                if (testMessage == null) {
                    delay(30_000)
                    // The notification itself is the success; nothing to say unless it never came.
                }
            }
        })
        ErrorText(testMessage)
        NavRow("Phones getting requests", "") { Ui.push(Route.Devices) }
        SectionLabel("Relay")
        com.sealctl.designsystem.Line(com.sealctl.designsystem.code(engine.relay.host, size = 14, color = Sealctl.colors.ink), com.sealctl.designsystem.plain(if (engine.banners.collectAsState().value.relayDown) " · Not answering" else " · Connected"), style = androidx.compose.material3.MaterialTheme.typography.bodyMedium, color = Sealctl.colors.muted)
        SecondaryButton("Delete relay data and unpair", { Ui.push(Route.DeleteRelay) })
        Muted("Your machines are unpaired and the relay forgets them. Your words stay on this phone.")
        SectionLabel("This phone")
        SecondaryButton("Remove from this phone", { Ui.push(Route.Erase) })
        Muted("Your words, machines and history leave this phone. Your computers stay sealed; your card restores everything.")
        SecondaryButton("Unseal all machines and leave", { Ui.push(Route.Leave) })
        Muted("Every computer gets its passwords back, then sealctl forgets you.")
        SectionLabel("About")
        NavRow("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) · core ${coreVersion()} · protocol ${protocolVersion()}", "") { Ui.push(Route.About) }
    }
}

/**
 * Turning Google backup on writes the Block Store item, which needs the words open: the words
 * prompt comes first, and the setting stays on only once the item is saved. Returns the error
 * to show, or null.
 */
internal suspend fun enableGoogleBackup(activity: FragmentActivity): String? {
    val engine = Graph.engine
    engine.apply(Event.SetSettings(engine.state.value.settings.copy(keychainBackup = true)))
    val r = Graph.words.unlockForCheck(activity)
    val saved = if (r is AuthResult.Success) {
        try { Graph.words.saveBackup() } finally { Graph.words.release() }
    } else null
    if (saved != null) return null
    engine.apply(Event.SetSettings(engine.state.value.settings.copy(keychainBackup = false)))
    return when (r) {
        AuthResult.Cancelled -> null
        is AuthResult.Success -> "The copy couldn't be saved to your Google backup. Try again later."
        else -> "Your words weren't opened, so nothing was saved to your Google backup."
    }
}

/**
 * Turning the relay backup off (SPEC.md 6.5): the stored blob is replaced by a sealed empty
 * state, at the relay's current revision. Returns whether the relay confirmed it.
 */
private suspend fun clearRelayBackup(): Boolean {
    val engine = Graph.engine
    var rev = engine.local.value.stateRev.toLong()
    repeat(3) {
        val blob = engine.withRoot { root -> runCatching { com.sealctl.core.stateSeal(root, ByteArray(0)) }.getOrNull() } ?: return false
        try {
            val stored = engine.relay.putState(rev, blob)
            engine.applyLocal(LocalEvent.Synced(stored.toULong(), uploaded = false))
            return true
        } catch (e: ConflictException) {
            rev = e.rev
        } catch (e: Exception) {
            return false
        }
    }
    return false
}

@Composable
fun NavRow(label: String, value: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 12.dp).semantics { contentDescription = label }, verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Sealctl.colors.ink, modifier = Modifier.weight(1f))
        Text("$value  ›", color = Sealctl.colors.muted)
    }
}

@Composable
fun AboutScreen() {
    val context = ctx()
    Page("About") {
        Wordmark()
        Body("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) · core ${coreVersion()} · protocol ${protocolVersion()} · rules ${appRulesVersion()}")
        Muted("Relay ${Graph.engine.relay.host}")
        NavRow("Source code", "") { openUrl(context, "https://github.com/sealctl/app") }
        NavRow("Licences", "") { Ui.push(Route.Licences) }
        NavRow("Privacy policy", "") { openUrl(context, "https://sealctl.com/privacy") }
        NavRow("Terms", "") { openUrl(context, "https://sealctl.com/terms") }
        NavRow("Report a security issue", "") {
            runCatching { context.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:security@sealctl.com")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }
}

@Composable
fun AnswersScreen() {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val answers = state.answers.filter { !it.deleted }
    Page("Answers") {
        if (answers.isEmpty()) Muted("No answers yet. When you tap Allow on an agent's first use of a key, it's remembered here.")
        for (a in answers) SurfaceCard {
            Text(buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(Texts.shown(Texts.agentName(a.agent), Texts.MAX_AGENT)) }
                append(" may use ")
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(Texts.shown(a.keyName, Texts.MAX_NAME)) }
                append(" in ")
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(Texts.shown(a.repoName.ifEmpty { a.repoId }, Texts.MAX_NAME)) }
            }, color = Sealctl.colors.ink)
            val left = answerDaysLeft(a.lastUsed, System.currentTimeMillis().toULong())
            if (left <= 10) Text("Unused for ${90 - left} days. Removed in $left days.", color = Sealctl.colors.waiting)
            else Muted("Last used ${Texts.ago(a.lastUsed.toLong())}")
            TextButton({ engine.apply(Event.RemoveAnswer(a.agent, a.keyName, a.repoId), upload = true) }) { Text("Remove") }
        }
        Muted("Agents ask once per key and repository. You at the keyboard are never asked inside an Open session. A file in a repository never grants anything.")
    }
}

@Composable
fun PlacesScreen(activity: MainActivity) {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val local by engine.local.collectAsState()
    val current by engine.currentPlace.collectAsState()
    val offer by engine.placeOffer.collectAsState()
    var name by remember { mutableStateOf("Place ${state.places.count { !it.deleted } + 1}") }
    var removing by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val context = ctx()
    // Two card words before a new gate (9.6), asked by "Trust where I am now"; then it goes on.
    var gateCard by remember { mutableStateOf<Pair<GateResult, suspend () -> Unit>?>(null) }
    gateCard?.let { (why, then) ->
        GateCardWords(activity, why, onPassed = { gateCard = null; scope.launch { then() } }, onCancel = { gateCard = null })
        return
    }
    Page("Places") {
        if (engine.places.hasForeground()) PlacesAlwaysBanner()
        val o = offer
        if (o != null) SurfaceCard {
            Title("Trust this place?")
            Body("You opened your machines here on ${o.days.size} mornings: ${o.days.joinToString(", ")}.")
            Body("At a trusted place, reopening needs no tap while your phone is unlocked and near the machine, sessions can stay open up to 4 hours, and leaving locks the machines you opened here. The location stays on this phone.")
            OutlinedTextField(name, { name = it.take(40) }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
            PrimaryButton("Trust", {
                engine.placeOffer.value = null
                // Announced to every paired computer; it skips the wait in two hours (11.9).
                scope.launch {
                    if (!engine.trustPlace(com.sealctl.core.app.TrustedPlace(o.id, name, o.lat, o.lon, 150.0, 0u, 0u, false, false))) Ui.toast(Texts.RELAY_DOWN)
                    engine.monitorPlaces()
                }
                // Leaving the place is noticed only with location all the time: explain, then ask.
                if (engine.location() != LocationAccess.ALWAYS) Ui.push(Route.PlacesAlways)
            })
            PlainButton("Not this place", { engine.applyLocal(com.sealctl.core.app.LocalEvent.SuppressCandidate(o.id)); engine.placeOffer.value = null })
        }
        if (engine.places.hasForeground() && current == null && o == null) TrustHere(activity) { why, then -> gateCard = why to then }
        if (!engine.places.hasForeground()) {
            Body("Places need location access. Without it, a session stays open up to 1 hour and reopening always takes a tap.")
            PrimaryButton("Allow location", { openAppSettings(context) })
        } else if (state.places.none { !it.deleted }) {
            Muted("No places yet. After three mornings of approving at the same spot, sealctl asks whether to trust it.")
        }
        for (p in state.places.filter { !it.deleted }) SurfaceCard {
            Text(p.name, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink)
            // created 0: added by hand while the clock could not be checked (SPEC.md 8.1)
            val since = if (p.created == 0uL) "trusted just now" else "trusted since ${Texts.isoDate(p.created.toLong())}"
            Muted(since + if (current == p.id) " · You're here" else "")
            PlaceSettles(p, local.delayed)
            if (removing == p.id) {
                Body("Remove ${p.name}? Machines opened here stay Open until their allowance ends.")
                Row { TextButton({ removing = null; scope.launch { engine.removePlace(p) } }) { Text("Remove") }; TextButton({ removing = null }) { Text("Cancel") } }
            } else TextButton({ removing = p.id }) { Text("Remove") }
        }
        Muted("Places are learned: after three mornings of approving at the same spot, sealctl asks whether to trust it. You can also trust where you are now.")
    }
}

/**
 * A trusted place's row (SPEC.md 11.9): when it starts to skip the two-hour wait, or that its
 * trusting was not confirmed with the relay, with [Confirm again].
 */
@Composable
private fun PlaceSettles(p: com.sealctl.core.app.TrustedPlace, delayed: List<com.sealctl.core.app.DelayedAction>) {
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    val now = System.currentTimeMillis()
    val record = p.trustId?.let { id -> delayed.firstOrNull { it.id == id } }
    when {
        p.trustId != null && p.trustedAt == 0uL -> {
            val waiting = record != null && (record.state == "waiting" || record.state == "released") && now < record.expires.toLong()
            if (waiting) Muted(Texts.placeSettles(record!!.releaseAt.toLong()))
            else {
                Muted(Texts.PLACE_UNCONFIRMED)
                TextButton({ scope.launch { if (!engine.announceTrust(p.id)) Ui.toast(Texts.RELAY_DOWN) } }) { Text(Texts.PLACE_CONFIRM_AGAIN) }
            }
        }
        p.trustId == null && p.manual && p.created == 0uL -> Muted(Texts.PLACE_STALE_CLOCK)
        p.trustId == null && com.sealctl.core.app.placeSettlesAt(p).toLong() > now -> Muted(Texts.placeSettles(com.sealctl.core.app.placeSettlesAt(p).toLong()))
    }
}

/** "Trust where I am now": a place added by hand (SPEC.md 11.9). Its comforts start at once; it lifts the level 3 delay two hours after it is announced. */
@Composable
private fun TrustHere(activity: MainActivity, onCard: (GateResult, suspend () -> Unit) -> Unit) {
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    var fix by remember { mutableStateOf<com.sealctl.places.Fix?>(null) }
    var locating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("Home") }
    var error by remember { mutableStateOf<String?>(null) }
    val f = fix
    suspend fun trust(f: com.sealctl.places.Fix, name: String) {
        when (val g = biometricGate(activity, "Trust this place")) {
            GateResult.Passed -> {
                // `created` 0: the store stamps it on the corrected clock (SPEC.md 8.1).
                val place = com.sealctl.core.app.TrustedPlace(randomPlaceId(), name.ifBlank { "Place" }, f.lat, f.lon, 150.0,
                    0u, 0u, false, true)
                // Announced to every paired computer, which can cancel it for two hours (11.9).
                val announced = engine.trustPlace(place)
                engine.monitorPlaces()
                fix = null
                Ui.toast(if (announced) "Trusted ${place.name}." else "Trusted ${place.name}. ${Texts.PLACE_UNCONFIRMED}")
                if (engine.location() != LocationAccess.ALWAYS) Ui.push(Route.PlacesAlways)
            }
            GateResult.Cancelled -> {}
            GateResult.NoBiometrics -> error = Texts.NO_BIOMETRICS
            // Two card words first (9.6), then the prompt again, which makes the new gate.
            GateResult.Changed, GateResult.NoGate -> { error = null; onCard(g) { trust(f, name) } }
            else -> error = "Couldn't confirm it's you."
        }
    }
    if (f == null) {
        SecondaryButton(if (locating) "Finding where you are…" else "Trust where I am now", {
            if (!locating) {
                locating = true
                error = null
                scope.launch {
                    val got = engine.places.sample()
                    locating = false
                    when {
                        got == null -> error = "Couldn't get your location. Try again in a moment."
                        got.accuracy > 100 -> error = "Your location is only accurate to ${got.accuracy.toInt()} m. Try again in a moment, near a window."
                        else -> fix = got
                    }
                }
            }
        }, enabled = !locating)
    } else SurfaceCard {
        Title("Trust this place?")
        Body("From now on here: reopening your machines needs no tap while your phone is unlocked and near them, sessions can stay open up to 4 hours, and leaving locks the machines you opened here.")
        Body(Texts.trustHere(System.currentTimeMillis() + engine.delaySecs(com.sealctl.app.Delays.LEVEL3_SECS) * 1000L))
        Muted("Accurate to ${f.accuracy.toInt()} m. The location stays on this phone.")
        OutlinedTextField(name, { name = it.take(40) }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
        PrimaryButton("Trust", { scope.launch { trust(f, name) } })
        PlainButton("Cancel", { fix = null })
    }
    ErrorText(error)
}

private fun randomPlaceId(): String = java.util.UUID.randomUUID().toString()

@Composable
fun DevicesScreen() {
    val engine = Graph.engine
    var list by remember { mutableStateOf<List<com.sealctl.relay.RelayDevice>?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { list = runCatching { engine.relay.listPush() }.getOrNull() }
    val mine = engine.local.collectAsState().value.device.deviceId
    Page("Phones getting requests") {
        val l = list
        if (l == null) Muted(Texts.RELAY_DOWN)
        else for (d in l) Row(verticalAlignment = Alignment.CenterVertically) {
            val label = if (d.device == mine) "This phone" else {
                val stale = System.currentTimeMillis() - d.updated > 30L * 86_400_000
                "${if (d.platform == "apns") "iPhone" else "Android"} · " + if (stale) "Not updated since ${Texts.isoDate(d.updated)}" else "updated ${Texts.ago(d.updated)}"
            }
            Text(label, color = Sealctl.colors.ink, modifier = Modifier.weight(1f))
            if (d.device != mine) TextButton({ scope.launch { runCatching { engine.relay.deletePush(d.device) }; list = runCatching { engine.relay.listPush() }.getOrNull() } }) { Text("Remove") }
        }
    }
}

// ---------- machine detail (11.17) ----------

@Composable
fun MachineDetailScreen(activity: MainActivity, key: String) {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val local by engine.local.collectAsState()
    val m = state.machines.firstOrNull { it.key == key && !it.deleted }
    val scope = rememberCoroutineScope()
    val now by rememberNow()
    var confirmUnpair by remember { mutableStateOf(false) }
    var releaseError by remember { mutableStateOf<String?>(null) }
    var gateCard by remember { mutableStateOf<GateResult?>(null) }
    var nickname by remember(m?.nickname) { mutableStateOf(m?.nickname ?: "") }
    if (m == null) { Page(null) { Muted("This machine is no longer paired.") }; return }
    suspend fun release() {
        releaseError = when (val g = biometricGate(activity, "Confirm releasing ${engine.displayName(m)}.")) {
            GateResult.Passed -> { engine.releaseHold(key); null }
            GateResult.Cancelled -> null
            GateResult.NoBiometrics -> Texts.NO_BIOMETRICS
            GateResult.LockedOut -> Texts.LOCKED_OUT
            // Two card words before a new gate (9.6), then the prompt again.
            GateResult.Changed, GateResult.NoGate -> { gateCard = g; null }
            else -> "Couldn't confirm it's you."
        }
    }
    gateCard?.let { why ->
        GateCardWords(activity, why, onPassed = { gateCard = null; scope.launch { release() } }, onCancel = { gateCard = null })
        return
    }
    val name = remember(m) { com.sealctl.core.app.machineShortName(m) }
    val model = remember(m) { MachineView.modelOf(m) }
    val session = remember(m) { MachineView.sessionOf(m) }
    val v = MachineView.of(m, engine, now, name, model, session)
    val tag = remember(key) { runCatching { com.sealctl.core.machineTag(key) }.getOrDefault("") }
    Page(null) {
        Row(verticalAlignment = Alignment.CenterVertically) { Mono(Texts.shown(m.name, 0), size = 18, weight = FontWeight.SemiBold); Text("  "); Mono("#$tag", color = Sealctl.colors.muted) }
        StateLabel(v.state, v.row, v.spoken)
        if (v.detail.isNotEmpty()) Body(v.detail)
        val hold = local.holds.firstOrNull { it.machine == key && it.until.toLong() > now }
        if (hold != null) {
            Text(Texts.held(engine.displayName(m), hold.until.toLong()), color = Sealctl.colors.waiting)
            TextButton({ scope.launch { release() } }) { Text("Release now") }
            ErrorText(releaseError)
        }
        if (v.state == com.sealctl.designsystem.MachineState.Open) PrimaryButton("Lock now", { scope.launch { if (engine.lock(m, userTapped = true)) Ui.toast("Locked ${engine.displayName(m)}.") } })
        OutlinedTextField(nickname, { nickname = it.take(40) }, label = { Text("Nickname") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        if (nickname != (m.nickname ?: "")) SecondaryButton("Save nickname", { engine.apply(Event.SetNickname(key, nickname.ifBlank { null })) })
        Muted(listOfNotNull(m.os.ifEmpty { null }, m.model, "paired ${Texts.isoDate(m.pairedAt.toLong())}", "seen ${Texts.ago(m.lastSeen?.toLong())}").joinToString(" · "))
        NavRow("Keys it used", "") { Ui.push(Route.Activity(key)) }
        NavRow("What it holds", "") { Ui.push(Route.Inventory(key)) }
        if (confirmUnpair) SurfaceCard {
            Title("Unpair ${engine.displayName(m)}?")
            Body("It can no longer ask this phone for keys. If it is Open, it locks the next time it reaches the relay. Its history and inventory stay on this phone.")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PrimaryButton("Unpair", { scope.launch { if (engine.unpair(m)) Ui.pop() } }, Modifier.weight(1f))
                SecondaryButton("Cancel", { confirmUnpair = false }, Modifier.weight(1f))
            }
        } else SecondaryButton("Unpair", { confirmUnpair = true })
        PlainButton("This machine was lost or stolen", { Ui.push(Route.LostMachine(key)) }, color = Sealctl.colors.accent)
    }
}

@Composable
fun LostMachineScreen(key: String) {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val m = state.machines.firstOrNull { it.key == key }
    val scope = rememberCoroutineScope()
    // The machine's keys of the last 90 days, read from the store off the main thread.
    val used by produceState(emptyList<Pair<String, Long>>(), key) {
        value = withContext(Dispatchers.IO) {
            val since = System.currentTimeMillis() - 90L * 86_400_000
            (com.sealctl.app.safe { engine.store.usage(key, null, 1000u) } ?: emptyList())
                .filter { it.time.toLong() > since && it.key.isNotEmpty() }.groupBy { it.key }.map { (k, l) -> k to l.maxOf { it.time.toLong() } }
        }
    }
    val held = state.inventory.filter { it.machine == key && !it.deleted && it.purpose in setOf("volume", "backup") }
    Page(null, bottom = { PrimaryButton("Done", { Ui.pop() }) }) {
        Title("${m?.name?.let { Texts.shown(it, Texts.MAX_NAME) } ?: "This machine"} was lost or stolen")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Body("1. Unpair it now. ", Modifier.weight(1f))
            if (m != null && !m.deleted) TextButton({ scope.launch { engine.unpair(m) } }) { Text("Unpair") } else Muted("Unpaired")
        }
        Body("2. Change these secrets at their providers. It used them in the last 90 days:")
        for ((k, t) in used) com.sealctl.designsystem.Line(com.sealctl.designsystem.code(k, size = 14, color = Sealctl.colors.ink), com.sealctl.designsystem.plain(" · last used ${Texts.isoDate(t)}"), style = androidx.compose.material3.MaterialTheme.typography.bodyMedium, color = Sealctl.colors.muted)
        Body("3. Re-encrypt what it had open. On another machine that has them, run `sealctl migrate`:")
        for (i in held) Mono("${if (i.purpose == "volume") "Volume" else "Backup"} ${i.path.ifEmpty { i.id }}", size = 14)
        Body("Your words were never on that machine, so they don't need to change.")
    }
}

// ---------- level 3 actions on the phone (11.18, 11.19) ----------

/**
 * A level 3 action: biometrics, then at once at a trusted place or after the two hours. After a
 * fingerprint or face was added or removed, two words from the card come first (9.6).
 * `prepare` is the user's own step (a prompt) that must succeed before a delayed record is
 * used up; `abandon` undoes it when the record can't be finished.
 *
 * While an action of this kind waits or is ready, the screen shows its delay instead of a start
 * (SPEC.md 11.23), and the record it shows ([focus], from a notification or a banner, or the
 * one just started) stays on screen until closed, also after it was cancelled or expired. One
 * tap runs at a time: the buttons are off while a start or a finish is on its way.
 */
@Composable
private fun PhoneAction(
    activity: MainActivity,
    what: String,
    reason: String,
    intro: @Composable () -> Unit,
    button: String,
    focus: String? = null,
    prepare: (suspend () -> Boolean)? = null,
    abandon: () -> Unit = {},
    onRun: suspend () -> String?,
) {
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    val local by engine.local.collectAsState()
    var error by remember { mutableStateOf<String?>(null) }
    var done by remember { mutableStateOf<String?>(null) }
    var cardCheck by remember { mutableStateOf<GateResult?>(null) }
    // What a passed card check goes on with: the start or the finish it interrupted.
    var afterCard by remember { mutableStateOf<(suspend () -> Unit)?>(null) }
    var busy by remember { mutableStateOf(false) }
    var shown by remember { mutableStateOf(focus) }
    val now by rememberNow()
    val running = runningPhoneAction(local.delayed, what, now.toULong())
    LaunchedEffect(running?.id) { if (running != null) shown = running.id }
    val d = (running?.id ?: shown)?.let { id -> local.delayed.firstOrNull { it.id == id } }
    val other = if (d == null) runningPhoneAction(local.delayed, Texts.OTHER_DEVICE, now.toULong()) else null

    fun once(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch { try { block() } finally { busy = false } }
    }
    suspend fun gate(then: suspend () -> Unit): Boolean {
        when (val g = biometricGate(activity, reason)) {
            GateResult.Passed -> return true
            GateResult.Cancelled -> {}
            GateResult.LockedOut -> error = Texts.LOCKED_OUT
            GateResult.NoBiometrics -> error = Texts.NO_BIOMETRICS
            // A new gate is made only after the card check.
            GateResult.Changed, GateResult.NoGate -> { error = null; afterCard = then; cardCheck = g }
            is GateResult.Failed -> error = g.message
        }
        return false
    }
    suspend fun run() {
        error = null
        done = onRun()
    }
    suspend fun start() {
        error = null
        if (!gate { start() }) return
        val started = try {
            engine.startPhoneAction(what)
        } catch (e: RelayException) {
            error = if (e.code == "too_many_delayed") Texts.TOO_MANY_DELAYED else Texts.RELAY_DOWN
            return
        } catch (e: Exception) {
            error = Texts.RELAY_DOWN
            return
        }
        if (started == null) run() else shown = started.id
    }
    suspend fun finish(id: String) {
        error = null
        if (!gate { finish(id) }) return
        if (prepare != null && !prepare()) return
        when (val r = engine.finishPhoneAction(id)) {
            null -> { run(); return }
            "too_early" -> error = "Not yet."
            // The record now reads as expired or cancelled: the screen says so itself.
            "gone" -> {}
            "relay" -> error = "The relay isn't answering, and sealctl can't finish until it confirms nothing was cancelled."
            else -> if (!r.startsWith("cancelled:")) error = Texts.relayError(r)
        }
        abandon()
    }
    if (done != null) {
        Page(null, bottom = { PrimaryButton("Done", { Ui.pop() }) }) { Gap(24); Body(done!!) }
        return
    }
    cardCheck?.let { why ->
        GateCardWords(activity, why, onPassed = {
            cardCheck = null
            afterCard?.let { next -> afterCard = null; once { next() } }
        }, onCancel = { cardCheck = null; afterCard = null })
        return
    }
    if (d != null) {
        DelayView(d.id, Texts.delayScreenTitle(what, null), PhoneActionButtons(what, busy, error,
            onReady = { once { finish(d.id) } },
            onStartAgain = { shown = null; once { start() } }))
        return
    }
    Page(null, bottom = {
        ErrorText(error)
        PrimaryButton(button, { once { start() } }, enabled = !busy)
        PlainButton("Cancel", { Ui.pop() })
    }) {
        Gap(16)
        intro()
        WaitBeforeStart(what, now)
        if (other != null) {
            // Not started blindly next to another install's action, whose kind is unknown here.
            Muted(Texts.otherDeviceRunning(other.releaseAt.toLong()))
            TextButton({ Ui.push(Route.Delayed(other.id)) }) { Text("Show it") }
        }
    }
}

/**
 * Before a level 3 action on the phone starts (SPEC.md 11.23): at a trusted place that lifts the
 * wait, that it happens at once; otherwise that it waits two hours, the real reason, and what
 * comes after, before the person confirms.
 */
@Composable
fun WaitBeforeStart(what: String, now: Long) {
    val engine = Graph.engine
    val reason = engine.delayReasonNow()
    val here = engine.herePlace()
    if (reason == com.sealctl.core.app.DelayReason.NONE) {
        Body("At ${here?.name ?: "your trusted place"}: this happens as soon as you confirm.")
        return
    }
    val unsettled = here?.takeIf { reason == com.sealctl.core.app.DelayReason.UNSETTLED }
    Body(Texts.beforeStart(what, com.sealctl.core.app.delayReasonCode(reason), unsettled?.name,
        unsettled?.let { com.sealctl.core.app.placeSettlesAt(it).toLong() } ?: 0L, now + engine.delaySecs(com.sealctl.app.Delays.LEVEL3_SECS) * 1000L))
}

@Composable
fun ShowWordsScreen(activity: MainActivity, focus: String? = null) {
    val shown by Graph.words.shown.collectAsState()
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    // Words opened for a delayed record show only once the relay has confirmed it finished.
    var revealed by remember { mutableStateOf(false) }
    androidx.compose.runtime.DisposableEffect(Unit) { onDispose { Graph.words.release() } }
    if (shown != null && revealed) {
        SecureScreen()
        val list = shown!!
        Page("Your words", onBack = { Graph.words.release(); Ui.pop() }) {
            list.forEachIndexed { i, w ->
                Row(Modifier.semantics { contentDescription = "Word ${i + 1}: $w" }) {
                    Mono("${i + 1}".padStart(2), color = Sealctl.colors.muted, size = 18); Text("  "); Mono(w, size = 22)
                }
            }
            Muted("Correct your card, then check again.")
        }
        return
    }
    suspend fun open(): Boolean = when (Graph.words.show(activity)) {
        is com.sealctl.vault.AuthResult.Success -> true
        else -> { error = "The words weren't opened."; false }
    }
    PhoneAction(activity, "words", "Confirm showing your words.", {
        Title("Show your words")
        Body("Showing the words is a sensitive action. Every paired computer is told.")
        ErrorText(error)
    }, "Confirm with fingerprint or face",
        focus = focus,
        prepare = { error = null; open() },
        abandon = { Graph.words.release() },
    ) {
        if (Graph.words.shown.value != null || open()) {
            revealed = true
            scope.launch { Graph.engine.sendNotice("words", "done", null, null, null) }
        }
        null
    }
}

@Composable
fun DeleteRelayScreen(activity: MainActivity, focus: String? = null) {
    val engine = Graph.engine
    val n = engine.liveMachines().size
    PhoneAction(activity, "delete", "Confirm deleting your relay data.", {
        Title("Delete your data on the relay?")
        Body("This unpairs your $n machines and deletes what the relay keeps for these words: your encrypted phone backup, your machines' records and every phone's notification address. It can't be undone. The privacy policy lists what stays.")
        Body("Your words, what this phone keeps, and your sealed files are not touched. To use a machine again, run `sealctl pair` on it.")
    }, "Delete", focus = focus) {
        deleteRelayData(lockFirst = true)
    }
}

/** Notices, locks, then `DELETE /v1/phones/{phone}` (SPEC.md 11.19). */
suspend fun deleteRelayData(lockFirst: Boolean): String {
    val engine = Graph.engine
    engine.sendNotice("delete", "done", null, null, null)
    if (lockFirst) for (m in engine.liveMachines()) {
        if (MachineView.of(m, engine).state == com.sealctl.designsystem.MachineState.Open) engine.lock(m, userTapped = true)
    }
    return try {
        engine.relay.deletePhone()
        engine.apply(Event.ForgetMachines)
        engine.apply(Event.SetSettings(engine.state.value.settings.copy(relayBackup = false)))
        "Deleted. The relay has nothing for these words."
    } catch (e: Exception) {
        "The relay isn't answering. Try again."
    }
}

@Composable
fun EraseScreen(activity: MainActivity) {
    val scope = rememberCoroutineScope()
    var alsoBackup by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Page(null, bottom = {
        ErrorText(error)
        SecondaryButton("Delete relay data and unpair first", { Ui.pop(); Ui.push(Route.DeleteRelay) })
        PrimaryButton("Remove", {
            scope.launch {
                val vault = Graph.engine.vault
                // On API 28 and 29 the words key needs a fingerprint; with none enrolled it can't be made.
                val cipher = try {
                    runCatching { vault.wordsDecryptCipher() }.getOrElse { vault.wordsEncryptCipher() }
                } catch (e: com.sealctl.vault.NoBiometricsException) {
                    error = NEEDS_FINGERPRINT; return@launch
                } catch (e: Exception) {
                    error = "Couldn't confirm it's you."; return@launch
                }
                error = null
                when (com.sealctl.vault.Biometric.words(activity, "Remove sealctl from this phone", "Use your fingerprint, face or screen lock", "Cancel", cipher)) {
                    is com.sealctl.vault.AuthResult.Success -> erase(alsoBackup)
                    else -> {}
                }
            }
        })
        PlainButton("Cancel", { Ui.pop() })
    }) {
        Gap(24)
        Title("Remove sealctl from this phone?")
        Body("This removes your words, machines, places and history from this phone. Your machines stay paired; your card restores everything on any phone.")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Checkbox(alsoBackup, { alsoBackup = it })
            Body("Also remove the copy in your Google backup")
        }
    }
}

/**
 * Erase (SPEC.md 11.19): push device, keys and files, database; back to Welcome. Runs in the
 * engine's scope: the screen that asked for it leaves the composition half way.
 */
suspend fun erase(alsoBackup: Boolean) {
    Graph.engine.scope.launch { eraseNow(alsoBackup) }.join()
}

private suspend fun eraseNow(alsoBackup: Boolean) {
    val engine = Graph.engine
    runCatching { engine.relay.deletePush(engine.deviceId()) }
    if (alsoBackup) Graph.blockStore.delete()
    engine.eraseLocal()
    engine.computePhase()
    Ui.reset()
}

@Suppress("unused")
private val keep: @Composable () -> Unit = { Column {}; Text("", fontSize = 1.sp) }
