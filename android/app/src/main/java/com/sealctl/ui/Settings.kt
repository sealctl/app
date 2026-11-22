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
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
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
import com.sealctl.core.app.answerDaysLeft
import com.sealctl.core.app.appRulesVersion
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
import com.sealctl.relay.RelayException
import com.sealctl.relay.contentOrNull
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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
    val words = state.words
    Page("Settings", onBack = null) {
        SectionLabel("Words")
        if (words != null) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Body("Words "); Mono(words.fingerprint, weight = FontWeight.SemiBold)
                Body(" · written on ${words.writtenOn} · next check ${com.sealctl.core.app.addDays(words.lastCheck ?: words.writtenOn, 365)}")
            }
        }
        SecondaryButton("Show words", { Ui.push(Route.ShowWords) })
        SectionLabel("Backups")
        ToggleRow("Google backup", state.settings.keychainBackup) {
            if (!it) {
                engine.apply(Event.SetSettings(state.settings.copy(keychainBackup = false)))
                scope.launch { Graph.blockStore.delete() }
            } else engine.apply(Event.SetSettings(state.settings.copy(keychainBackup = true)))
        }
        ToggleRow("Encrypted backup on the relay", state.settings.relayBackup) {
            engine.apply(Event.SetSettings(state.settings.copy(relayBackup = it)), upload = it)
            if (!it) scope.launch { runCatching { engine.relay.putState(local.stateRev.toLong(), null) } }
        }
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
        Row { Mono(engine.relay.host, size = 14); Muted(if (engine.banners.collectAsState().value.relayDown) " · Not answering" else " · Connected") }
        SecondaryButton("Delete my relay data", { Ui.push(Route.DeleteRelay) })
        SectionLabel("This phone")
        SecondaryButton("Erase sealctl from this phone", { Ui.push(Route.Erase) })
        SecondaryButton("Leave sealctl", { Ui.push(Route.Leave) })
        SectionLabel("About")
        NavRow("Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) · core ${coreVersion()} · protocol ${protocolVersion()}", "") { Ui.push(Route.About) }
    }
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
        NavRow("Licences", "") {}
        Muted("sealctl app: AGPL-3.0. sealctl-core: MIT. Libraries: AndroidX and Jetpack Compose, OkHttp, kotlinx.serialization, JNA, CameraX, zxing-cpp (Apache-2.0); Firebase Messaging and Google Play services (Android SDK terms); Rust crates of sealctl-core (MIT/Apache-2.0); SQLite (public domain).")
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
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(Texts.agentName(a.agent)) }
                append(" may use ")
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace)) { append(a.keyName) }
                append(" in ")
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(a.repoName.ifEmpty { a.repoId }) }
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
fun PlacesScreen() {
    val engine = Graph.engine
    val state by engine.state.collectAsState()
    val current by engine.currentPlace.collectAsState()
    val offer by engine.placeOffer.collectAsState()
    var name by remember { mutableStateOf("Place ${state.places.count { !it.deleted } + 1}") }
    var removing by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val context = ctx()
    Page("Places") {
        val o = offer
        if (o != null) SurfaceCard {
            Title("Trust this place?")
            Body("You opened your machines here on ${o.days.size} mornings: ${o.days.joinToString(", ")}.")
            Body("At a trusted place, reopening needs no tap while your phone is unlocked and near the machine, sessions can stay open up to 4 hours, and leaving locks the machines you opened here. The location stays on this phone.")
            OutlinedTextField(name, { name = it.take(40) }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
            PrimaryButton("Trust", {
                engine.apply(Event.AddPlace(com.sealctl.core.app.TrustedPlace(o.id, name, o.lat, o.lon, 150.0, 0u, 0u, false)), upload = true)
                engine.placeOffer.value = null
                scope.launch { engine.monitorPlaces() }
            })
            PlainButton("Not this place", { engine.applyLocal(com.sealctl.core.app.LocalEvent.SuppressCandidate(o.id)); engine.placeOffer.value = null })
        }
        if (!engine.places.hasForeground()) {
            Body("Places need location access. Without it, a session stays open up to 1 hour and reopening always takes a tap.")
            PrimaryButton("Allow location", { openAppSettings(context) })
        } else if (state.places.none { !it.deleted }) {
            Muted("No places yet. After three mornings of approving at the same spot, sealctl asks whether to trust it.")
        }
        for (p in state.places.filter { !it.deleted }) SurfaceCard {
            Text(p.name, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink)
            Muted("trusted since ${Texts.isoDate(p.created.toLong())}" + if (current == p.id) " · You're here" else "")
            if (removing == p.id) {
                Body("Remove ${p.name}? Machines opened here stay Open until their allowance ends.")
                Row { TextButton({ engine.apply(Event.RemovePlace(p.id), upload = true); removing = null; scope.launch { engine.monitorPlaces() } }) { Text("Remove") }; TextButton({ removing = null }) { Text("Cancel") } }
            } else TextButton({ removing = p.id }) { Text("Remove") }
        }
        Muted("Places are learned: after three mornings of approving at the same spot, sealctl asks whether to trust it.")
    }
}

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
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    var confirmUnpair by remember { mutableStateOf(false) }
    var nickname by remember(m?.nickname) { mutableStateOf(m?.nickname ?: "") }
    if (m == null) { Page(null) { Muted("This machine is no longer paired.") }; return }
    val v = MachineView.of(m, engine, now)
    val tag = remember(key) { runCatching { com.sealctl.core.machineTag(key) }.getOrDefault("") }
    Page(null) {
        Row(verticalAlignment = Alignment.CenterVertically) { Mono(m.name, size = 18, weight = FontWeight.SemiBold); Text("  "); Mono("#$tag", color = Sealctl.colors.muted) }
        StateLabel(v.state, v.row)
        if (v.detail.isNotEmpty()) Body(v.detail)
        val hold = local.holds.firstOrNull { it.machine == key && it.until.toLong() > now }
        if (hold != null) {
            Text(Texts.held(engine.displayName(m), hold.until.toLong()), color = Sealctl.colors.waiting)
            TextButton({
                scope.launch {
                    if (biometricGate(activity, "Confirm releasing ${engine.displayName(m)}.") == GateResult.Passed) engine.releaseHold(key)
                }
            }) { Text("Release now") }
        }
        if (v.state == com.sealctl.designsystem.MachineState.Open) PrimaryButton("Lock now", { scope.launch { if (engine.lock(m)) Ui.toast("Locked ${engine.displayName(m)}.") } })
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
    val since = System.currentTimeMillis() - 90L * 86_400_000
    val used = remember(key) { com.sealctl.app.safe { engine.store.usage(key, null, 1000u) } ?: emptyList() }
        .filter { it.time.toLong() > since && it.key.isNotEmpty() }.groupBy { it.key }.map { (k, l) -> k to l.maxOf { it.time.toLong() } }
    val held = state.inventory.filter { it.machine == key && !it.deleted && it.purpose in setOf("volume", "backup") }
    Page(null, bottom = { PrimaryButton("Done", { Ui.pop() }) }) {
        Title("${m?.name ?: "This machine"} was lost or stolen")
        Row(verticalAlignment = Alignment.CenterVertically) {
            Body("1. Unpair it now. ", Modifier.weight(1f))
            if (m != null && !m.deleted) TextButton({ scope.launch { engine.unpair(m) } }) { Text("Unpair") } else Muted("Unpaired")
        }
        Body("2. Change these secrets at their providers. It used them in the last 90 days:")
        for ((k, t) in used) Row { Mono(k, size = 14); Muted(" · last used ${Texts.isoDate(t)}") }
        Body("3. Re-encrypt what it had open. On another machine that has them, run `sealctl migrate`:")
        for (i in held) Mono("${if (i.purpose == "volume") "Volume" else "Backup"} ${i.path.ifEmpty { i.id }}", size = 14)
        Body("Your words were never on that machine, so they don't need to change.")
    }
}

// ---------- level 3 actions on the phone (11.18, 11.19) ----------

/** A level 3 action: biometrics, then at once at a trusted place or after the hour. */
@Composable
private fun PhoneAction(activity: MainActivity, what: String, reason: String, intro: @Composable () -> Unit, button: String, onRun: suspend () -> String?) {
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    val local by engine.local.collectAsState()
    var error by remember { mutableStateOf<String?>(null) }
    var done by remember { mutableStateOf<String?>(null) }
    val pending = local.delayed.lastOrNull { it.what == what && it.state in setOf("waiting", "released") }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(1000); now = System.currentTimeMillis() } }
    suspend fun run() {
        error = null
        done = onRun()
    }
    if (done != null) {
        Page(null, bottom = { PrimaryButton("Done", { Ui.pop() }) }) { Gap(24); Body(done!!) }
        return
    }
    if (pending != null && pending.releaseAt.toLong() > now) {
        DelayView(pending.id, when (what) { "words" -> "Showing your words"; "delete" -> "Deleting your relay data"; else -> "Leaving sealctl" })
        return
    }
    Page(null, bottom = {
        ErrorText(error)
        PrimaryButton(if (pending != null) "Finish" else button, {
            scope.launch {
                when (val g = biometricGate(activity, reason)) {
                    GateResult.Passed -> {}
                    GateResult.Cancelled -> return@launch
                    GateResult.LockedOut -> { error = Texts.LOCKED_OUT; return@launch }
                    GateResult.Changed -> { error = "A fingerprint or face was added or removed. Check two words from your card first."; engine.vault.resetGate(); return@launch }
                    is GateResult.Failed -> { error = g.message; return@launch }
                }
                if (pending != null) {
                    when (val r = engine.finishPhoneAction(pending.id)) {
                        null -> run()
                        "too_early" -> error = "Not yet."
                        "gone" -> error = "This waited too long. Start again."
                        "relay" -> error = "The relay isn't answering, and sealctl can't finish until it confirms nothing was cancelled."
                        else -> error = "Cancelled from ${r.removePrefix("cancelled:").let { by -> engine.machine(by)?.let { engine.displayName(it) } ?: "another device" }}. Nothing happened."
                    }
                    return@launch
                }
                val delayed = try { engine.startPhoneAction(what) } catch (e: Exception) { error = Texts.RELAY_DOWN; return@launch }
                if (delayed == null) run()
            }
        })
        PlainButton("Cancel", { Ui.pop() })
    }) {
        Gap(16)
        intro()
        if (pending == null) Body(if (engine.placeKind() == PlaceKind.TRUSTED) "At your trusted place: this happens as soon as you confirm." else "This starts one hour after you confirm. Your phone and your computers can cancel it until then.")
        else Body("The hour is over. Confirm again to finish.")
    }
}

@Composable
fun ShowWordsScreen(activity: MainActivity) {
    val shown by Graph.words.shown.collectAsState()
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    if (shown != null) {
        SecureScreen()
        val list = shown!!
        androidx.compose.runtime.DisposableEffect(Unit) { onDispose { Graph.words.release() } }
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
    PhoneAction(activity, "words", "Confirm showing your words.", {
        Title("Show your words")
        Body("Showing the words is a sensitive action. Every paired computer is told.")
        ErrorText(error)
    }, "Confirm with fingerprint or face") {
        when (Graph.words.show(activity)) {
            is com.sealctl.vault.AuthResult.Success -> {
                scope.launch { Graph.engine.sendNotice("words", "done", null, null, null) }
                null
            }
            else -> { error = "The words weren't opened."; null }
        }.let { null }
    }
}

@Composable
fun DeleteRelayScreen(activity: MainActivity) {
    val engine = Graph.engine
    val n = engine.liveMachines().size
    PhoneAction(activity, "delete", "Confirm deleting your relay data.", {
        Title("Delete your data on the relay?")
        Body("This unpairs your $n machines and deletes what the relay keeps for these words: your encrypted phone backup, your machines' records and every phone's notification address. It can't be undone. The privacy policy lists what stays.")
        Body("Your words, what this phone keeps, and your sealed files are not touched. To use a machine again, run `sealctl pair` on it.")
    }, "Delete") {
        deleteRelayData(lockFirst = true)
    }
}

/** Notices, locks, then `DELETE /v1/phones/{phone}` (SPEC.md 11.19). */
suspend fun deleteRelayData(lockFirst: Boolean): String {
    val engine = Graph.engine
    engine.sendNotice("delete", "done", null, null, null)
    if (lockFirst) for (m in engine.liveMachines()) {
        if (MachineView.of(m, engine).state == com.sealctl.designsystem.MachineState.Open) engine.lock(m)
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
    Page(null, bottom = {
        SecondaryButton("Delete my relay data first", { Ui.pop(); Ui.push(Route.DeleteRelay) })
        PrimaryButton("Erase", {
            scope.launch {
                when (com.sealctl.vault.Biometric.words(activity, "Erase sealctl from this phone", "Use your fingerprint, face or screen lock", "Cancel",
                    runCatching { Graph.engine.vault.wordsDecryptCipher() }.getOrElse { Graph.engine.vault.wordsEncryptCipher() })) {
                    is com.sealctl.vault.AuthResult.Success -> erase(alsoBackup)
                    else -> {}
                }
            }
        })
        PlainButton("Cancel", { Ui.pop() })
    }) {
        Gap(24)
        Title("Erase sealctl from this phone?")
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
    engine.onBackground()
    engine.vault.erase()
    engine.forgetPhoneKeys()
    com.sealctl.app.safe { engine.store.erase() }
    engine.refreshState()
    engine.waiting.value = emptyList()
    engine.computePhase()
    Ui.reset()
}

@Suppress("unused")
private val keep: @Composable () -> Unit = { Column {}; Text("", fontSize = 1.sp) }
