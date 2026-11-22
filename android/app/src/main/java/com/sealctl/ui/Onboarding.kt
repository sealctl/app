package com.sealctl.ui

import android.Manifest
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.sealctl.app.CardPdf
import com.sealctl.app.Graph
import com.sealctl.app.MainActivity
import com.sealctl.app.Phase
import com.sealctl.app.Route
import com.sealctl.app.Texts
import com.sealctl.app.Ui
import com.sealctl.core.CoreException
import com.sealctl.core.Root
import com.sealctl.core.Words
import com.sealctl.core.app.Event
import com.sealctl.core.app.LocalEvent
import com.sealctl.core.backupItemDecode
import com.sealctl.core.fingerprint
import com.sealctl.designsystem.Body
import com.sealctl.designsystem.Mono
import com.sealctl.designsystem.Muted
import com.sealctl.designsystem.PlainButton
import com.sealctl.designsystem.PrimaryButton
import com.sealctl.designsystem.SecondaryButton
import com.sealctl.designsystem.Sealctl
import com.sealctl.designsystem.Title
import com.sealctl.designsystem.Wordmark
import com.sealctl.designsystem.monoStyle
import com.sealctl.vault.AuthResult
import com.sealctl.vault.NoBiometricsException
import java.util.Locale
import kotlinx.coroutines.launch

/** Android 9 and 10 keep the words behind a fingerprint only (SPEC.md 7.3). */
private const val NEEDS_FINGERPRINT = "On this version of Android, sealctl keeps your words behind a fingerprint. Add a fingerprint in your phone's settings, then try again."

private enum class Step { Welcome, About, Card, Ready, Words, Check, Backups, Notifications, Places, PlacesAlways, Pair, Restore, RestoreConfirm, Restoring, OldPhone, ChangeNow, BackupFound }

@Composable
fun OnboardingFlow(activity: MainActivity, phase: Phase) {
    val start = when (phase) {
        is Phase.BackupFound -> Step.BackupFound
        Phase.CardUnchecked -> Step.Ready
        is Phase.Onboarding -> when (phase.step) { 7 -> Step.Backups; 8 -> Step.Notifications; 9 -> Step.Places; else -> Step.Pair }
        else -> Step.Welcome
    }
    // A restore persists step 7 before its last screens; the phase that follows must not
    // skip them (Restoring, the old phone, changing the words).
    var restoreStep by rememberSaveable { mutableStateOf<Step?>(null) }
    var step by rememberSaveable(phase) { mutableStateOf(if (phase is Phase.Onboarding) restoreStep ?: start else start) }
    SideEffect { restoreStep = step.takeIf { it == Step.Restoring || it == Step.OldPhone || it == Step.ChangeNow } }
    var restoring by rememberSaveable { mutableStateOf(false) }
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    fun setStep(s: Step) {
        step = s
        val persisted = when (s) { Step.Backups -> 7; Step.Notifications -> 8; Step.Places, Step.PlacesAlways -> 9; Step.Pair -> 10; else -> null }
        if (persisted != null) engine.applyLocal(LocalEvent.SetOnboardingStep(persisted.toUInt()))
    }
    fun finish() {
        engine.applyLocal(LocalEvent.SetOnboardingStep(0u))
        scope.launch { engine.computePhase(); engine.onForeground() }
    }
    when (step) {
        Step.Welcome -> Welcome(onCreate = { step = Step.About }, onRestore = { step = Step.Restore })
        Step.BackupFound -> BackupFoundScreen(phase as? Phase.BackupFound, activity,
            onRestored = { restoring = true; step = Step.Restoring },
            onPaper = { step = Step.Restore }, onCreate = { step = Step.About })
        Step.About -> AboutWords { step = Step.Card }
        Step.Card -> BlankCard { step = Step.Ready }
        Step.Ready -> GetReady(activity) { step = Step.Words }
        Step.Words -> WordsPages(onDone = { Graph.words.hide(); step = Step.Check })
        Step.Check -> CardCheck(onAgain = { step = Step.Ready }, onPassed = {
            scope.launch {
                Graph.words.cardChecked()
                setStep(Step.Backups)
            }
        })
        Step.Backups -> Backups(activity) { setStep(Step.Notifications) }
        Step.Notifications -> NotificationsStep { if (restoring) finish() else setStep(Step.Places) }
        Step.Places -> PlacesStep(onAlways = { step = Step.PlacesAlways }, onDone = { setStep(Step.Pair) })
        Step.PlacesAlways -> PlacesAlways { setStep(Step.Pair) }
        Step.Pair -> PairFirst(onScan = { finish(); Ui.push(Route.Pair()) }, onLater = { finish() })
        Step.Restore -> RestoreWords(onBack = { step = Step.Welcome }) { step = Step.RestoreConfirm }
        Step.RestoreConfirm -> RestoreConfirm(activity, onNo = { step = Step.Restore }, onYes = { restoring = true; step = Step.Restoring })
        Step.Restoring -> Restoring { step = Step.OldPhone }
        Step.OldPhone -> OldPhone(onKept = { setStep(Step.Backups) }, onLost = { step = Step.ChangeNow })
        Step.ChangeNow -> ChangeNow { setStep(Step.Backups) }
    }
}

@Composable
private fun Welcome(onCreate: () -> Unit, onRestore: () -> Unit) {
    val context = ctx()
    val goodbye by Ui.goodbye.collectAsState()
    Page(null, onBack = null, bottom = {
        PrimaryButton("Create new words", onCreate)
        SecondaryButton("Restore", onRestore)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
            Muted("No account. ")
            Text("Privacy", color = Sealctl.colors.accent, modifier = Modifier.padding(horizontal = 4.dp)
                .clickableNoRipple { openUrl(context, "https://sealctl.com/privacy") })
            Muted("·")
            Text("Terms", color = Sealctl.colors.accent, modifier = Modifier.padding(horizontal = 4.dp)
                .clickableNoRipple { openUrl(context, "https://sealctl.com/terms") })
        }
    }) {
        Spacer(Modifier.height(48.dp))
        if (goodbye) Muted("sealctl is gone from this phone. You can delete the app.")
        Wordmark(size = 34)
        Title("Your phone holds the keys.")
        Body("When an agent on your computer needs a key, your computer asks this phone. You tap Allow, and the key goes into that one command.")
    }
}

fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier = this.clickable(onClick = onClick)

@Composable
private fun AboutWords(onNext: () -> Unit) {
    Page(null, onBack = null, bottom = { PrimaryButton("Next", onNext) }) {
        Spacer(Modifier.height(32.dp))
        Title("24 words open everything")
        Body("Every key sealctl hands out comes from 24 words. You write them by hand on a paper card. With the card, you can get everything back on a new phone or open your files with no phone at all.")
        Body("The app never shows the words for printing, copying or photos.")
    }
}

@Composable
private fun BlankCard(onDone: () -> Unit) {
    val context = ctx()
    val locale = androidx.compose.ui.platform.LocalConfiguration.current.locales[0]
    val letterRegions = setOf("US", "CA", "MX", "PH", "CL", "CO", "VE")
    var letter by rememberSaveable { mutableStateOf(locale.country in letterRegions) }
    Page(null, onBack = null, bottom = {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SecondaryButton("Print", { CardPdf.print(context, letter) }, Modifier.weight(1f))
            SecondaryButton("Share PDF", { CardPdf.share(context, letter) }, Modifier.weight(1f))
        }
        PrimaryButton("I have a blank card", onDone)
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Print a blank card")
        Body("The card has 24 numbered lines with four boxes each: the first four letters are enough to know each word. It folds to wallet size.")
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Muted("Paper size:")
            Text("A4", color = if (!letter) Sealctl.colors.accent else Sealctl.colors.ink2, fontWeight = if (!letter) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier.clickableNoRipple { letter = false }.padding(8.dp))
            Muted("·")
            Text("Letter", color = if (letter) Sealctl.colors.accent else Sealctl.colors.ink2, fontWeight = if (letter) FontWeight.SemiBold else FontWeight.Normal,
                modifier = Modifier.clickableNoRipple { letter = true }.padding(8.dp))
        }
        Muted("No printer? Any paper works. Number 24 lines.")
    }
}

@Composable
private fun GetReady(activity: MainActivity, onShown: () -> Unit) {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    Page(null, onBack = null, bottom = {
        ErrorText(error)
        PrimaryButton("Show my words", {
            scope.launch {
                val r = try { Graph.words.create(activity) } catch (e: NoBiometricsException) { error = NEEDS_FINGERPRINT; return@launch }
                when (r) {
                    is AuthResult.Success -> onShown()
                    AuthResult.Cancelled -> {}
                    AuthResult.LockedOut -> error = Texts.LOCKED_OUT
                    is AuthResult.Failed -> error = "Couldn't open the words (${r.message})."
                }
            }
        })
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Write where no camera can see")
        Body("Screenshots and screen recordings hide the words. Write each word in full, in the boxes and on the line.")
    }
}

@Composable
private fun WordsPages(onDone: () -> Unit) {
    SecureScreen()
    val words by Graph.words.shown.collectAsState()
    val fp by Graph.words.fingerprint.collectAsState()
    var page by rememberSaveable { mutableIntStateOf(0) }
    val list = words ?: return
    Page(null, onBack = if (page > 0) ({ page-- }) else null, bottom = {
        if (page < 3) PrimaryButton("Next", { page++ }) else PrimaryButton("I've written all 24", onDone)
    }) {
        Title("Words ${page * 6 + 1} to ${page * 6 + 6}")
        for (i in page * 6 until page * 6 + 6) {
            val w = list[i]
            Row(Modifier.fillMaxWidth().padding(vertical = 6.dp).semantics { contentDescription = "Word ${i + 1}: $w" }, verticalAlignment = Alignment.CenterVertically) {
                Text("${i + 1}", style = monoStyle(18), color = Sealctl.colors.muted, modifier = Modifier.width(44.dp))
                Text(buildAnnotatedString {
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(w.take(4)) }
                    append(w.drop(4))
                }, style = monoStyle(26), color = Sealctl.colors.ink)
            }
        }
        if (page == 3) {
            Gap(16)
            Title("Now fill in the card")
            com.sealctl.designsystem.Line(com.sealctl.designsystem.plain("Words fingerprint: "), com.sealctl.designsystem.code(fp ?: "", size = 18, weight = FontWeight.SemiBold, color = Sealctl.colors.ink))
            com.sealctl.designsystem.Line(com.sealctl.designsystem.plain("Written on: "), com.sealctl.designsystem.code(Texts.isoDate(System.currentTimeMillis()), size = 18, color = Sealctl.colors.ink))
        }
    }
}

@Composable
private fun CardCheck(onAgain: () -> Unit, onPassed: () -> Unit) {
    val positions = remember { Graph.words.positions(3, 2) }
    var index by rememberSaveable { mutableIntStateOf(0) }
    var wrong by rememberSaveable { mutableIntStateOf(0) }
    var message by remember { mutableStateOf<String?>(null) }
    var round by remember { mutableIntStateOf(0) }
    if (!Graph.words.hasSession()) {
        LaunchedEffect(Unit) { onAgain() }
        return
    }
    val pos = positions[index]
    val choices = remember(pos, round) { Graph.words.choices(pos) }
    Page(null, onBack = null, bottom = {
        if (wrong >= 2) SecondaryButton("Show the words again", onAgain)
    }) {
        Muted("Check your card · ${index + 1} of 3")
        Title("Which is word $pos?")
        for (c in choices) ChoiceButton(c) {
            if (Graph.words.matches(pos, c)) {
                message = null; wrong = 0
                if (index == 2) onPassed() else index++
            } else {
                wrong++; round++
                message = "That's not word $pos. Look at your card again."
            }
        }
        ErrorText(message)
    }
}

@Composable
private fun Backups(activity: MainActivity, onContinue: () -> Unit) {
    val engine = Graph.engine
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    val state by engine.state.collectAsState()
    var e2ee by remember { mutableStateOf<Boolean?>(null) }
    LaunchedEffect(Unit) { e2ee = Graph.blockStore.e2eeAvailable() }
    Page(null, onBack = null, bottom = { PrimaryButton("Continue", onContinue) }) {
        Spacer(Modifier.height(24.dp))
        Title("Backups")
        Row { Text("Paper card", fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink); Muted(" · Written and checked") }
        ToggleRow("Google backup", state.settings.keychainBackup && e2ee != false, enabled = e2ee == true) {
            message = null
            if (!it) {
                engine.apply(Event.SetSettings(state.settings.copy(keychainBackup = false)))
                engine.scope.launch { Graph.blockStore.delete() }
            } else scope.launch { message = enableGoogleBackup(activity) }
        }
        ErrorText(message)
        if (e2ee == false) Muted("Off: Google can't end-to-end encrypt it on this phone.")
        else Muted("A new Android phone on the same Google account restores without the words. End-to-end encrypted because this phone has a screen lock.")
        ToggleRow("Encrypted backup on the relay", state.settings.relayBackup) {
            engine.apply(Event.SetSettings(state.settings.copy(relayBackup = it)))
        }
        Muted("Your machines, places, answers and inventory, encrypted with a key only your words can make. It does not hold your words.")
    }
}

@Composable
fun ToggleRow(label: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontWeight = FontWeight.SemiBold, color = Sealctl.colors.ink, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled, modifier = Modifier.semantics { contentDescription = label })
    }
}

@Composable
private fun NotificationsStep(onDone: () -> Unit) {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { onDone() }
    Page(null, onBack = null, bottom = {
        PrimaryButton("Allow notifications", {
            if (Build.VERSION.SDK_INT >= 33) launcher.launch(Manifest.permission.POST_NOTIFICATIONS) else onDone()
        })
        PlainButton("Not now", onDone)
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Requests arrive as notifications")
        Body("When a machine needs a key, this phone shows a notification. You answer with one tap. A locked phone asks for its unlock first.")
    }
}

@Composable
private fun PlacesStep(onAlways: () -> Unit, onDone: () -> Unit) {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
        if (r[Manifest.permission.ACCESS_FINE_LOCATION] == true && Build.VERSION.SDK_INT >= 29) onAlways() else onDone()
    }
    Page(null, onBack = null, bottom = {
        PrimaryButton("Allow location", {
            launcher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        })
        PlainButton("Not now", onDone)
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Learn your places?")
        Body("sealctl can learn where you work. At a trusted place, reopening your machine needs no tap while your phone is unlocked and near it, and leaving locks the machines you opened there. Locations stay on this phone.")
        Muted("Without places, a session stays open up to 1 hour and reopening always takes a tap.")
    }
}

@Composable
private fun PlacesAlways(onDone: () -> Unit) {
    val context = ctx()
    Page(null, onBack = null, bottom = {
        PrimaryButton("Open settings", { openAppSettings(context); onDone() })
        PlainButton("Not now", onDone)
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Allow location all the time")
        Body("sealctl needs it to notice when you leave a trusted place and lock your machines. It checks only when you cross the edge of a place. Locations stay on this phone.")
    }
}

@Composable
private fun PairFirst(onScan: () -> Unit, onLater: () -> Unit) {
    Page(null, onBack = null, bottom = {
        PrimaryButton("Scan code", onScan)
        PlainButton("Later", onLater)
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Pair a machine")
        Body("On your computer, run:")
        Mono("sealctl pair", size = 18)
        Body("Then scan the code it shows.")
    }
}

// ---------- restore (11.4) ----------

@Composable
private fun BackupFoundScreen(found: Phase.BackupFound?, activity: MainActivity, onRestored: () -> Unit, onPaper: () -> Unit, onCreate: () -> Unit) {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    val fp = found?.fingerprint ?: ""
    Page(null, onBack = null, bottom = {
        ErrorText(error)
        PrimaryButton("Restore $fp", {
            scope.launch {
                val bytes = Graph.blockStore.read() ?: run { error = "The backup is gone."; return@launch }
                val item = runCatching { backupItemDecode(bytes) }.getOrNull() ?: run { error = "The backup can't be read."; return@launch }
                bytes.fill(0)
                val r = try { Graph.words.restore(activity, item.words) } catch (e: NoBiometricsException) { error = NEEDS_FINGERPRINT; return@launch }
                if (r is AuthResult.Success) {
                    Graph.words.restored(item.fingerprint)
                    Graph.words.release()
                    onRestored()
                }
            }
        })
        SecondaryButton("Restore from paper", onPaper)
        PlainButton("Create new words", onCreate)
    }) {
        Spacer(Modifier.height(48.dp))
        Wordmark()
        Title("Your words are in your Google backup")
        com.sealctl.designsystem.Line(com.sealctl.designsystem.plain("Words "), com.sealctl.designsystem.code(fp, size = 15, color = Sealctl.colors.ink), com.sealctl.designsystem.plain(", saved on ${found?.created?.let { Texts.isoDate(it) } ?: ""}."))
    }
}

/** Typed words, kept only in this screen's memory (SPEC.md 11.4). */
private object Typed {
    val words = mutableStateListOf<String>().apply { repeat(24) { add("") } }
    var parsed: Words? = null
    fun clear() {
        for (i in 0 until 24) words[i] = ""
        parsed?.destroy(); parsed = null
    }
}

@Composable
private fun RestoreWords(onBack: () -> Unit, onParsed: () -> Unit) {
    SecureScreen()
    var focus by remember { mutableIntStateOf(Typed.words.indexOfFirst { it.isEmpty() }.coerceAtLeast(0)) }
    var prefix by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var bad by remember { mutableIntStateOf(-1) }
    Page(null, onBack = { Typed.clear(); onBack() }, bottom = {
        ErrorText(error)
        WordKeypad(prefix, onChange = { prefix = it; Typed.words[focus] = it }, onWord = { w ->
            Typed.words[focus] = w; prefix = ""
            if (focus < 23) focus++ else {
                try {
                    Typed.parsed?.destroy()
                    Typed.parsed = Words.parse(Typed.words.toList())
                    error = null; onParsed()
                } catch (e: CoreException.UnknownWord) {
                    bad = e.index.toInt(); error = "No word starts with '${Typed.words[bad].take(4)}'."
                } catch (e: CoreException) {
                    error = "These words don't fit together. Check the order and spelling against your card."
                }
            }
        })
        if (Typed.words.all { it.isNotEmpty() }) PrimaryButton("Check", {
            try {
                Typed.parsed?.destroy()
                Typed.parsed = Words.parse(Typed.words.toList()); onParsed()
            } catch (e: CoreException.UnknownWord) {
                bad = e.index.toInt(); error = "No word starts with '${Typed.words[bad].take(4)}'."
            } catch (e: CoreException) {
                error = "These words don't fit together. Check the order and spelling against your card."
            }
        })
    }) {
        Title("Type your 24 words")
        Muted("Four letters are enough. Each word completes itself.")
        for (i in 0 until 24) WordField(i + 1, Typed.words[i], focus == i, bad == i) { focus = i; prefix = Typed.words[i].take(4) }
    }
}

@Composable
private fun RestoreConfirm(activity: MainActivity, onNo: () -> Unit, onYes: () -> Unit) {
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    val words = Typed.parsed ?: run { LaunchedEffect(Unit) { onNo() }; return }
    val fp = remember(words) { Root.fromWords(words).let { r -> fingerprint(r).also { r.destroy() } } }
    Page(null, onBack = onNo, bottom = {
        ErrorText(error)
        PrimaryButton("Yes", {
            scope.launch {
                val r = try { Graph.words.restore(activity, words) } catch (e: NoBiometricsException) { error = NEEDS_FINGERPRINT; return@launch }
                if (r is AuthResult.Success) {
                    Graph.words.restored(fp)
                    Graph.words.release()
                    Typed.clear()
                    onYes()
                }
            }
        })
        SecondaryButton("No, check again", onNo)
    }) {
        Spacer(Modifier.height(32.dp))
        Row(verticalAlignment = Alignment.CenterVertically) { Title("These are words "); Mono(fp, size = 22, weight = FontWeight.SemiBold) }
        Body("Does your card say $fp?")
    }
}

@Composable
private fun Restoring(onContinue: () -> Unit) {
    val engine = Graph.engine
    var loaded by remember { mutableStateOf(false) }
    var empty by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        engine.download()
        engine.refreshMachines()
        val s = engine.state.value
        empty = s.machines.none { !it.deleted } && s.places.isEmpty() && s.answers.isEmpty()
        loaded = true
        engine.registerPush()
    }
    val s by engine.state.collectAsState()
    Page(null, onBack = null, bottom = { if (loaded) PrimaryButton("Continue", onContinue) }) {
        Spacer(Modifier.height(32.dp))
        if (!loaded) Title("Restoring your data") else if (empty) {
            Title("Found your backup")
            Body("No relay backup for these words. Your machines will need sealctl pair again, unless they are still paired: they reconnect by themselves.")
        } else {
            Title("Found your backup")
            Body("${s.machines.count { !it.deleted }} machines · ${s.places.count { !it.deleted }} places · ${s.answers.count { !it.deleted }} answers · ${s.inventory.count { !it.deleted }} inventory items")
        }
    }
}

@Composable
private fun OldPhone(onKept: () -> Unit, onLost: () -> Unit) {
    Page(null, onBack = null, bottom = {
        SecondaryButton("I still have it, or it was reset", onKept)
        SecondaryButton("It was lost or stolen", onLost)
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Where is your old phone?")
    }
}

@Composable
private fun ChangeNow(onLater: () -> Unit) {
    var note by remember { mutableStateOf<String?>(null) }
    Page(null, onBack = null, bottom = {
        ErrorText(note)
        PrimaryButton("Change words now", { note = "Changing words isn't in this version of the app yet." })
        PlainButton("Remind me tomorrow", onLater)
    }) {
        Spacer(Modifier.height(32.dp))
        Title("Change your words now")
        Body("Your old phone holds these words behind its passcode. Changing them makes sure it can't open anything new. It takes about 10 minutes and a new blank card.")
    }
}

// ---------- blocking states (11.20) ----------

@Composable
fun NeedsScreenLockScreen() {
    val context = ctx()
    Page(null, onBack = null, bottom = {
        PrimaryButton("Open settings", { context.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) })
    }) {
        Spacer(Modifier.height(48.dp))
        Wordmark()
        Title("Set a screen lock first")
        Body("Set a screen lock first. sealctl keeps your words behind this phone's screen lock.")
    }
}

@Composable
fun WordsLostScreen(activity: MainActivity, invalidated: Boolean) {
    val scope = rememberCoroutineScope()
    Page(null, onBack = null, bottom = {
        PrimaryButton("Restore", {
            Graph.engine.vault.erase()
            Graph.engine.forgetPhoneKeys()
            scope.launch { Graph.engine.computePhase() }
        })
    }) {
        Spacer(Modifier.height(48.dp))
        Wordmark()
        Body("This phone's screen lock changed and Android removed sealctl's keys. Restore your words from your Google backup or your card.")
    }
}

@Suppress("unused")
private val keepColumn: @Composable () -> Unit = { Column {} }
