package com.sealctl.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import androidx.work.WorkManager
import com.sealctl.core.Decision
import com.sealctl.core.MachineMessage
import com.sealctl.core.MessageKind
import com.sealctl.core.Notice
import com.sealctl.core.PairingOffer
import com.sealctl.core.PhoneKeys
import com.sealctl.core.Place as PlaceKind
import com.sealctl.core.PlanApproval
import com.sealctl.core.PlanAssembler
import com.sealctl.core.RefuseReason
import com.sealctl.core.Request
import com.sealctl.core.RequestKind
import com.sealctl.core.Root
import com.sealctl.core.app.Asking
import com.sealctl.core.app.DecideContext
import com.sealctl.core.app.DelayedAction
import com.sealctl.core.app.DeviceInfo
import com.sealctl.core.app.Event
import com.sealctl.core.app.Hold
import com.sealctl.core.app.HandbackReport
import com.sealctl.core.app.KeyRefRecord
import com.sealctl.core.app.LocalEvent
import com.sealctl.core.app.LocalState
import com.sealctl.core.app.LocationSample
import com.sealctl.core.app.Machine
import com.sealctl.core.app.MachineSeen
import com.sealctl.core.app.PlaceCandidate
import com.sealctl.core.app.PlanApprovalRecord
import com.sealctl.core.app.PlanItemRecord
import com.sealctl.core.app.ReplyOption
import com.sealctl.core.app.State
import com.sealctl.core.app.Store
import com.sealctl.core.app.Verdict
import com.sealctl.core.app.decide
import com.sealctl.core.app.decodeState
import com.sealctl.core.app.machineDisplayName
import com.sealctl.core.app.randomId
import com.sealctl.core.openMachineStatus
import com.sealctl.core.openRequest
import com.sealctl.core.pairingProof
import com.sealctl.core.sealMachineMessage
import com.sealctl.core.sealPlanKeysReply
import com.sealctl.core.sealPlanPartReply
import com.sealctl.core.sealReply
import com.sealctl.core.sealReportReply
import com.sealctl.core.stateOpen
import com.sealctl.core.stateSeal
import com.sealctl.notify.NoteAction
import com.sealctl.notify.Notify
import com.sealctl.notify.RequestNote
import com.sealctl.places.Fence
import com.sealctl.places.Places
import com.sealctl.relay.ClockSkewException
import com.sealctl.relay.ConflictException
import com.sealctl.relay.PhoneSocket
import com.sealctl.relay.RateLimitedException
import com.sealctl.relay.RelayClient
import com.sealctl.relay.RelayException
import com.sealctl.relay.RelayRequest
import com.sealctl.relay.str
import com.sealctl.relay.strOrNull
import com.sealctl.relay.long
import com.sealctl.vault.Biometric
import com.sealctl.vault.KeysInvalidatedException
import com.sealctl.vault.Vault
import java.io.IOException
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/** A request on this phone waiting for an answer from the person. */
data class Waiting(
    val relay: RelayRequest,
    val request: Request,
    val verdict: Verdict,
    val machine: Machine,
    val seenAt: Long,
    val expired: Boolean = false,
    val plan: com.sealctl.core.RequestPlan? = null,
) {
    /** When this phone stops offering the request, on its own clock (SPEC.md 8.5). */
    val deadline: Long get() = Answers.deadline(seenAt, relay.created, relay.expires)
}

/** Banners on the Machines tab (SPEC.md 11.20). */
data class Banners(
    val offline: Boolean = false,
    val relayDown: Boolean = false,
    val rateLimitedUntil: Long = 0,
    val clockSkew: Boolean = false,
    val signatureRefused: Boolean = false,
)

/** The app's phases (SPEC.md 6.1). */
sealed class Phase {
    data object Loading : Phase()
    data object NeedsScreenLock : Phase()
    data object NoWords : Phase()
    data class BackupFound(val fingerprint: String, val created: Long) : Phase()
    data object CardUnchecked : Phase()
    data class Onboarding(val step: Int) : Phase()
    data object Ready : Phase()
    data class WordsLost(val invalidated: Boolean) : Phase()
}

/** A short confirmation after an answer (SPEC.md 11.7 "After an answer"). */
data class Toast(val text: String)

/**
 * The approval path, sync and everything that talks to the relay. One per process (SPEC.md
 * 6.3): Rust calls on Dispatchers.Default, network on Dispatchers.IO.
 */
class Engine(
    private val context: Context,
    val vault: Vault,
    val store: Store,
    relayUrl: String,
    val places: Places,
) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Volatile private var phoneKeysCache: PhoneKeys? = null
    val relay = RelayClient(relayUrl, { phoneKeys() })

    val phase = MutableStateFlow<Phase>(Phase.Loading)
    val state = MutableStateFlow(safe { store.snapshot() } ?: emptyState())
    val local = MutableStateFlow(safe { store.local() } ?: emptyLocal())
    val waiting = MutableStateFlow<List<Waiting>>(emptyList())
    val banners = MutableStateFlow(Banners())
    private val _toasts = MutableSharedFlow<Toast>(extraBufferCapacity = 8)
    val toasts: SharedFlow<Toast> = _toasts

    fun toast(text: String) { _toasts.tryEmit(Toast(text)) }
    val foreground = MutableStateFlow(false)
    /** The trusted place the phone is inside, from geofence transitions. */
    val currentPlace = MutableStateFlow<String?>(null)
    /** A place candidate to offer ("Trust this place?"). */
    val placeOffer = MutableStateFlow<PlaceCandidate?>(null)
    /** The relay answered or failed for a level 3 delayed record: refresh the screens. */
    val delayedTick = MutableStateFlow(0L)

    private val assemblers = HashMap<String, PlanAssembler>()
    private val approvalLock = Mutex()
    private var socket: PhoneSocket? = null
    private val socketLock = Any()
    private val lifecycle = Lifecycle()
    /** Requests whose answer is on its way (SPEC.md 8.5). */
    private val inFlight = InFlight()
    /** Exits from trusted places so far, to tell whether one came while an answer was on its way. */
    private val placeExits = AtomicInteger(0)
    private var uploadJob: Job? = null
    private var onWifi = false

    init {
        watchNetwork()
    }

    // ---------- keys ----------

    fun phoneKeys(): PhoneKeys? {
        phoneKeysCache?.let { return it }
        return try {
            vault.readPhoneKeys()?.also { phoneKeysCache = it }
        } catch (e: KeysInvalidatedException) {
            phase.value = Phase.WordsLost(invalidated = true)
            null
        } catch (e: Exception) {
            null
        }
    }

    fun forgetPhoneKeys() {
        phoneKeysCache?.destroy()
        phoneKeysCache = null
    }

    /** Runs [block] with the root, then destroys it. Null when the phone is locked. */
    fun <T> withRoot(block: (Root) -> T): T? {
        val root = try {
            vault.readRoot()
        } catch (e: KeysInvalidatedException) {
            phase.value = Phase.WordsLost(invalidated = true)
            return null
        } catch (e: Exception) {
            return null
        }
        return try { block(root) } finally { root.destroy() }
    }

    // ---------- state ----------

    fun refreshState() {
        safe { store.snapshot() }?.let { state.value = it }
        safe { store.local() }?.let { local.value = it }
    }

    fun apply(event: Event, upload: Boolean = false) {
        safe { store.apply(event) }?.let { state.value = it }
        safe { store.local() }?.let { local.value = it }
        scheduleUpload(if (upload) 0 else 10_000)
    }

    fun applyLocal(event: LocalEvent) {
        safe { store.applyLocal(event) }?.let { local.value = it }
    }

    fun liveMachines(): List<Machine> = state.value.machines.filter { !it.deleted }

    fun machine(key: String): Machine? = liveMachines().firstOrNull { it.key == key }

    fun displayName(m: Machine): String = machineDisplayName(m)

    fun offset(): Int = TimeZone.getDefault().getOffset(System.currentTimeMillis()) / 1000

    // ---------- phase ----------

    suspend fun computePhase() {
        refreshState()
        phase.value = when {
            !vault.isDeviceSecure() -> Phase.NeedsScreenLock
            vault.hasRoot() && vault.hasPhoneKeys() -> {
                if (phoneKeys() == null && phase.value is Phase.WordsLost) return
                val words = state.value.words
                val step = local.value.onboardingStep.toInt()
                when {
                    words == null || words.writtenOn.isEmpty() -> Phase.CardUnchecked
                    step in 7..10 -> Phase.Onboarding(step)
                    else -> Phase.Ready
                }
            }
            else -> {
                val item = withContext(Dispatchers.IO) { Graph.blockStore.read() }
                val decoded = item?.let { runCatching { com.sealctl.core.backupItemDecode(it) }.getOrNull() }
                if (decoded != null) {
                    decoded.words.destroy()
                    Phase.BackupFound(decoded.fingerprint, decoded.created.toLong())
                } else Phase.NoWords
            }
        }
    }

    // ---------- foreground: socket and catch-up ----------

    /** The app came to the foreground: the number to hand to [onForeground] (SPEC.md 8.3). */
    fun started(): Long {
        val t = lifecycle.started()
        foreground.value = true
        return t
    }

    /**
     * Opens the socket and catches up, unless the app left the foreground since [turn] began:
     * a stop that came first leaves no socket open in the background.
     */
    fun onForeground(turn: Long = lifecycle.now()) {
        if (phase.value != Phase.Ready || phoneKeys() == null) return
        synchronized(socketLock) {
            if (!lifecycle.current(turn)) return
            foreground.value = true
            if (socket == null) {
                socket = PhoneSocket(relay, scope, onMessage = ::onSocketMessage, onConnected = {
                    scope.launch { catchUp() }
                }, onState = { ok -> banners.value = banners.value.copy(relayDown = !ok && !banners.value.offline) })
            }
            socket?.start()
        }
        scope.launch {
            // Cancels first: a plan whose delay was cancelled while away hands out no keys.
            refreshDelayed()
            catchUp()
            refreshStatus()
            refreshMachines()
            if (System.currentTimeMillis() - local.value.lastDownload.toLong() > 3_600_000) download()
            if (local.value.dirty) scheduleUpload(0)
            registerPush()
        }
    }

    fun onBackground() {
        lifecycle.stopped()
        synchronized(socketLock) {
            // Under the lock: an onForeground already past its check sets it back otherwise.
            foreground.value = false
            socket?.stop()
            socket = null
        }
    }

    private fun onSocketMessage(o: JsonObject) {
        when (o.str("type")) {
            "request" -> scope.launch { handle(RelayClient.parseRequest(o), fromPush = false) }
            "status" -> scope.launch { refreshStatus() }
            "delayed" -> scope.launch { refreshDelayed() }
            "cancelled" -> scope.launch {
                delayedCancelled(o.str("id"), o.strOrNull("by"))
                refreshDelayed()
            }
        }
    }

    /**
     * Lists pending requests and handles each (after a push, on foreground, on reconnect).
     * False when the relay could not be asked.
     */
    suspend fun catchUp(fromPush: Boolean = false): Boolean {
        if (phoneKeys() == null) return false
        // A request seen after this was asked for may be newer than the list.
        val asked = System.currentTimeMillis()
        val list = try {
            relay.requests().also { relayOk() }
        } catch (e: Exception) {
            relayFailed(e); return false
        }
        for (r in list) handle(r, fromPush)
        // Requests that left the relay list expired or were answered elsewhere.
        val ids = list.map { it.id }.toSet()
        val now = System.currentTimeMillis()
        val gone = mutableSetOf<String>()
        waiting.update { current ->
            current.map {
                if (it.relay.id !in ids && !it.expired && it.relay.id !in inFlight && (it.deadline < now || it.seenAt < asked)) {
                    gone += it.relay.id
                    it.copy(expired = true)
                } else it
            }
        }
        for (id in gone) Notify.cancel(context, id)
        return true
    }

    private fun relayOk() {
        banners.value = banners.value.copy(relayDown = false, offline = false, clockSkew = false)
    }

    private fun relayFailed(e: Exception) {
        banners.value = when (e) {
            is ClockSkewException -> banners.value.copy(clockSkew = true)
            is RateLimitedException -> banners.value.copy(rateLimitedUntil = e.until)
            is RelayException -> if (e.status == 401) banners.value.copy(signatureRefused = true)
                else if (e.status >= 500 || e.status == 0) banners.value.copy(relayDown = true) else banners.value
            is IOException -> banners.value.copy(relayDown = !banners.value.offline)
            else -> banners.value
        }
        dlog("relay call failed: ${e.javaClass.simpleName}")
    }

    // ---------- the approval path (SPEC.md 9.1) ----------

    suspend fun handle(r: RelayRequest, fromPush: Boolean) = approvalLock.withLock {
        if (waiting.value.any { it.relay.id == r.id && !it.expired }) return@withLock
        if (!safeBool { store.seeRequest(r.id, r.machine, r.expires.toULong()) }) return@withLock
        val machine = machine(r.machine)
        if (machine == null) {
            safe { store.closeRequest(r.id, "ignored") }
            return@withLock
        }
        val keys = phoneKeys() ?: return@withLock
        val req = try {
            openRequest(keys, r.machine, r.id, r.sealed)
        } catch (e: Exception) {
            dlog("request refused by the core: ${e.javaClass.simpleName}")
            safe { store.closeRequest(r.id, "ignored") }
            return@withLock
        }
        var plan: com.sealctl.core.RequestPlan? = null
        if (req.kind() == RequestKind.UNSEAL) {
            plan = try {
                assemblers.getOrPut(r.machine) { PlanAssembler() }.add(req)
            } catch (e: Exception) {
                reply(req, r, Decision.Refuse(RefuseReason.BAD_LABEL), "ignored", allowed = false)
                return@withLock
            }
        }
        val mark = placeMark()
        val hash = req.plan()?.hash
        val found = Plans.forRequest(local.value.plans, local.value.delayed, r.machine, hash)
        var verdict = decide(req, context(r, machine, found))
        if (verdict.asking == Asking.PLAN_KEYS && Plans.needsRelayCheck(found)) {
            // A cancel made on a computer reaches this phone only by the socket, a push or a refresh:
            // ask the relay before a delayed plan hands out keys. Without an answer, ask the person.
            val fetched = refreshDelayed()
            verdict = decide(req, context(r, machine, Plans.afterRelayCheck(fetched, local.value.plans, local.value.delayed, r.machine, hash)))
        }
        when (verdict.asking) {
            Asking.SILENT -> silent(req, r)
            Asking.AUTOMATIC -> {
                val d = verdict.automatic ?: return@withLock
                when (send(req, r, d, "automatic", allowed = true, remember = false, decidedAt = mark)) {
                    Sent.POSTED -> Notify.show(
                        context, Notify.ANSWERED, "auto-${r.id}",
                        Texts.answeredByItself(displayName(machine), placeName()), null, timeoutMs = 60_000,
                    )
                    Sent.FAILED, Sent.LOCKED -> {
                        // Fail closed: the person answers instead of the request waiting unseen (SPEC.md 9.1).
                        val again = runCatching { openRequest(keys, r.machine, r.id, r.sealed) }.getOrNull() ?: return@withLock
                        ask(again, r, verdict.copy(asking = Asking.ONE_TAP, automatic = null), machine, plan, fromPush)
                    }
                    Sent.GONE -> {}
                }
            }
            Asking.PLAN_KEYS -> planKeys(req, r)
            Asking.REFUSED -> {
                val err = verdict.refuse ?: RefuseReason.UNSUPPORTED
                reply(req, r, Decision.Refuse(err), "denied", allowed = false)
                if (err == RefuseReason.NOT_NEAR || err == RefuseReason.NO_BIOMETRICS) {
                    val text = if (err == RefuseReason.NOT_NEAR) Texts.notNear(displayName(machine)) else Texts.NO_BIOMETRICS
                    Notify.show(context, Notify.SENSITIVE, "refused-${r.id}", text, null)
                }
            }
            Asking.ONE_TAP, Asking.IN_APP -> ask(req, r, verdict, machine, plan, fromPush)
        }
    }

    /** Puts a request on the card, with a notification when the app is not on screen. */
    private fun ask(req: Request, r: RelayRequest, verdict: Verdict, machine: Machine, plan: com.sealctl.core.RequestPlan?, fromPush: Boolean) {
        val w = Waiting(r, req, verdict, machine, System.currentTimeMillis(), plan = plan ?: req.plan())
        waiting.update { list -> list.filter { it.relay.id != r.id } + w }
        // The agent's one-time note shows on the card (SPEC.md 11.11).
        if (!foreground.value || fromPush) showNotification(w)
        scheduleExpiry(w)
    }

    private fun context(r: RelayRequest, machine: Machine, plan: PlanApprovalRecord?): DecideContext {
        val l = local.value
        val s = state.value
        val unlocked = !vault.isDeviceLocked() && vault.canReadRoot()
        val status = machine.lastStatus
        val open = status?.session == "open" && status.left?.let { left ->
            (System.currentTimeMillis() - status.reportedAt.toLong()) / 1000 < left.toLong()
        } ?: false
        return DecideContext(
            now = System.currentTimeMillis().toULong(),
            utcOffsetSecs = offset(),
            phoneUnlocked = unlocked,
            near = r.near,
            onWifi = onWifi,
            placesOn = places.hasForeground(),
            currentPlace = currentPlace.value,
            currentPlaceSettled = placeSettled(),
            day = l.days.firstOrNull { it.machine == r.machine },
            answers = s.answers.filter { !it.deleted },
            sessionOpen = open,
            hold = l.holds.firstOrNull { it.machine == r.machine },
            biometrics = Biometric.availability(context),
            plan = plan,
        )
    }

    private fun placeName(): String? =
        currentPlace.value?.let { id -> state.value.places.firstOrNull { it.id == id && !it.deleted }?.name }

    fun placeKind(): PlaceKind = com.sealctl.core.app.placeKind(places.hasForeground(), currentPlace.value)

    /** The place the phone is inside also lifts the level 3 delay (a place added by hand: after 24 hours). */
    fun placeSettled(): Boolean = currentPlace.value
        ?.let { id -> state.value.places.firstOrNull { it.id == id && !it.deleted } }
        ?.let { com.sealctl.core.app.placeSettled(it, System.currentTimeMillis().toULong()) } ?: false

    /** A level 3 action happens at once here (SPEC.md 9.6). */
    fun delayLifted(): Boolean = placeKind() == PlaceKind.TRUSTED && placeSettled()

    private suspend fun silent(req: Request, r: RelayRequest) {
        val keys = phoneKeys() ?: return
        if (req.kind() == RequestKind.UNSEAL) {
            val sealed = runCatching { sealPlanPartReply(keys, req) }.getOrNull() ?: return
            post(r, sealed, null, userTapped = false)
            safe { store.closeRequest(r.id, "answered") }
            return
        }
        val result = safe { store.applyReport(req, offset()) }
        refreshState()
        val sealed = runCatching { sealReportReply(keys, req, result?.ack, emptyList()) }.getOrNull() ?: return
        post(r, sealed, null, userTapped = false)
        safe { store.closeRequest(r.id, "answered") }
        result?.handback?.let { reportArrived(it) }
    }

    private fun reportArrived(report: HandbackReport) {
        val failed = report.items.count { it.state == "failed" }
        val done = report.items.count { it.state == "done" }
        Notify.show(
            context, Notify.SENSITIVE, "report-${report.id}",
            Texts.handedBack(report.machineName, done, failed), null, screen = "report:${report.id}",
        )
        // Tell every other machine (SPEC.md 9.6 Report).
        scope.launch {
            sendNotice("unseal_all", "done", report.machine, null, null, done, failed, report.items.count { it.state == "skipped" })
        }
    }

    private suspend fun planKeys(req: Request, r: RelayRequest) {
        val keys = phoneKeys() ?: return
        // The same plan decide() matched: live, with this request's hash.
        val hash = req.plan()?.hash ?: return
        val plan = Plans.forRequest(local.value.plans, local.value.delayed, r.machine, hash)?.takeIf { it.planHash == hash } ?: return
        val approval = PlanApproval(plan.machine, plan.planHash, plan.notBefore, plan.keys.map { com.sealctl.core.KeyRef(it.purpose, it.id) })
        val sealed = withRoot { root -> runCatching { sealPlanKeysReply(root, keys, req, approval) }.getOrNull() } ?: return
        if (post(r, sealed, null, userTapped = false) == Sent.POSTED) {
            safe { store.answered(req, "in_session", true, false, currentPlace.value, offset()) }
            refreshState()
        }
    }

    private fun scheduleExpiry(w: Waiting) {
        scope.launch {
            val left = w.deadline - System.currentTimeMillis()
            if (left > 0) delay(left)
            expire(w.relay.id)
        }
    }

    /**
     * The card's time is up. While an answer is on its way the answer decides: the relay takes
     * it, or the answer closes the card when it fails after the deadline.
     */
    private fun expire(id: String) {
        if (id in inFlight) return
        val w = waiting.value.firstOrNull { it.relay.id == id && !it.expired } ?: return
        waiting.update { list -> list.map { if (it.relay.id == id) it.copy(expired = true) else it } }
        Notify.cancel(context, id)
        safe { store.closeRequest(id, "expired") }
        safe { store.answered(w.request, "expired", false, false, null, offset()) }
        refreshState()
    }

    /** Removes an expired card from the list ("Close"). */
    fun dismiss(id: String) {
        waiting.update { list -> list.filter { it.relay.id != id } }
    }

    /** [body] replaces the request's text, for "Couldn't send your answer — try again." */
    private fun showNotification(w: Waiting, body: String? = null) {
        val name = displayName(w.machine)
        val t = Texts.notification(w, name).let { if (body != null) it.first to body else it }
        val actions = if (w.verdict.asking == Asking.ONE_TAP) w.verdict.options.map {
            NoteAction(it.name, Texts.button(it, w.verdict.kind), authRequired = it != ReplyOption.DENY)
        } else emptyList()
        Notify.showRequest(
            context,
            RequestNote(w.relay.id, w.machine.key, t.first, t.second, w.deadline, actions, sensitive = w.verdict.asking != Asking.ONE_TAP),
        )
    }

    /** The decision a button stands for. */
    fun decisionFor(w: Waiting, option: ReplyOption): Pair<Decision, String> {
        val place = placeKind()
        return when (option) {
            ReplyOption.ALLOW_SESSION ->
                (if (w.verdict.agentFirstUse) Decision.Remember(place) else Decision.Session(place)) to "one_tap"
            ReplyOption.ALLOW -> (if (w.verdict.kind == RequestKind.AGENT) Decision.Remember(place) else Decision.Session(place)) to "one_tap"
            ReplyOption.ALLOW_ONCE -> Decision.Once(place) to "once"
            ReplyOption.DENY -> Decision.Deny to "denied"
            ReplyOption.CONFIRM -> Decision.Once(place) to "confirmed"
        }
    }

    /**
     * Answers a waiting one-tap request (card button or notification action). A tap after the
     * card's time, or an answer already on its way (a notification action and the card at
     * once), sends nothing. A reply the relay did not take keeps the card and says so (SPEC.md
     * 8.5, 11.7).
     */
    suspend fun answer(id: String, option: ReplyOption): Boolean = answerOutcome(id, option) == Sent.POSTED

    private suspend fun answerOutcome(id: String, option: ReplyOption): Sent? {
        val w = waiting.value.firstOrNull { it.relay.id == id && !it.expired } ?: return null
        if (w.verdict.asking != Asking.ONE_TAP || option !in w.verdict.options) return null
        if (System.currentTimeMillis() >= w.deadline) {
            // The timer ran late (it stops while the phone sleeps): the card stops waiting.
            expire(id)
            return Sent.GONE
        }
        if (!inFlight.start(id)) return null
        // In the engine's scope: a screen that goes away does not stop the answer halfway.
        return scope.async {
            try {
                val mark = placeMark()
                val (decision, outcome) = decisionFor(w, option)
                val sent = send(w.request, w.relay, decision, outcome, allowed = option != ReplyOption.DENY,
                    remember = decision is Decision.Remember, decidedAt = mark)
                inFlight.done(id)
                when (sent) {
                    Sent.POSTED -> {
                        waiting.update { list -> list.filter { it.relay.id != id } }
                        Notify.cancel(context, id)
                        if (w.verdict.agentFirstUse) applyLocal(LocalEvent.AgentNoteShown)
                        _toasts.tryEmit(Toast(Texts.afterAnswer(option, w)))
                    }
                    Sent.FAILED -> if (System.currentTimeMillis() >= w.deadline) expire(id) else {
                        _toasts.tryEmit(Toast(Texts.ANSWER_NOT_SENT))
                        // The timer may have fired while the answer was on its way, and left the card to it.
                        scheduleExpiry(w)
                    }
                    // `404 gone` closed the card already; a reply still retrying at the deadline did not.
                    Sent.GONE -> expire(id)
                    // reply() said "Unlock your phone to answer."
                    Sent.LOCKED -> scheduleExpiry(w)
                }
                sent
            } finally {
                inFlight.done(id)
            }
        }.await()
    }

    /**
     * A notification action: fetch the request again if this process did not see it. When the
     * answer can't be sent, the request's notification comes back saying so (SPEC.md 10.2).
     */
    suspend fun answerFromNotification(id: String, action: String) {
        val option = runCatching { ReplyOption.valueOf(action) }.getOrNull() ?: return
        if (waiting.value.none { it.relay.id == id } && !catchUp(fromPush = false)) {
            Notify.show(context, Notify.REQUESTS, id, Texts.REQUEST_TITLE, Texts.ANSWER_NOT_SENT)
            return
        }
        if (option != ReplyOption.DENY && !vault.canReadRoot()) {
            val w = waiting.value.firstOrNull { it.relay.id == id }
            Notify.show(context, Notify.REQUESTS, "unlock-$id", Texts.unlockToAnswer(w?.let { displayName(it.machine) } ?: ""), null)
            return
        }
        if (answerOutcome(id, option) == Sent.FAILED) {
            waiting.value.firstOrNull { it.relay.id == id && !it.expired }?.let { showNotification(it, Texts.ANSWER_NOT_SENT) }
        }
    }

    /** Where the phone was when a decision was made, and how many place exits it had seen. */
    data class PlaceMark(val place: String?, val exits: Int)

    private fun placeMark() = PlaceMark(currentPlace.value, placeExits.get())

    /** Opens a request on the card again from the relay's text: the core seals a request once. */
    private fun reopen(r: RelayRequest, keys: PhoneKeys) {
        if (waiting.value.none { it.relay.id == r.id }) return
        val again = runCatching { openRequest(keys, r.machine, r.id, r.sealed) }.getOrNull() ?: return
        waiting.update { list -> list.map { if (it.relay.id == r.id) it.copy(request = again) else it } }
    }

    /**
     * Seals and posts one reply, then records it. Returns false when the reply could not be
     * sealed or the machine stopped waiting.
     */
    suspend fun reply(
        req: Request,
        r: RelayRequest,
        decision: Decision,
        outcome: String,
        allowed: Boolean,
        remember: Boolean = false,
        delaySecs: Int? = null,
        decidedAt: PlaceMark? = null,
    ): Boolean = send(req, r, decision, outcome, allowed, remember, delaySecs, decidedAt) == Sent.POSTED

    /**
     * [reply], telling why a reply did not go. A request on the card whose reply did not go is
     * opened again from the relay's text, as the core seals a request once.
     */
    private suspend fun send(
        req: Request,
        r: RelayRequest,
        decision: Decision,
        outcome: String,
        allowed: Boolean,
        remember: Boolean = false,
        delaySecs: Int? = null,
        decidedAt: PlaceMark? = null,
    ): Sent {
        val mark = decidedAt ?: placeMark()
        val keys = phoneKeys() ?: return Sent.FAILED
        val needsRoot = allowed && req.items().isNotEmpty()
        val sealed = try {
            if (needsRoot) withRoot { root -> sealReply(root, keys, req, decision) } ?: run {
                _toasts.tryEmit(Toast(Texts.UNLOCK_TO_ANSWER)); return Sent.LOCKED
            } else sealReply(null, keys, req, decision)
        } catch (e: Exception) {
            dlog("seal failed: ${e.javaClass.simpleName}")
            reopen(r, keys)
            return Sent.FAILED
        }
        val sent = post(r, sealed, delaySecs, userTapped = true)
        if (sent != Sent.POSTED) {
            if (sent == Sent.FAILED) reopen(r, keys)
            return sent
        }
        // A place left while this was on its way: the day did not begin there after all.
        val left = mark.place != null && placeExits.get() != mark.exits
        val place = if (left) currentPlace.value else mark.place
        safe { store.answered(req, outcome, allowed, remember, place, offset()) }?.let { result ->
            if (result.firstOfDay) scope.launch { firstApprovalOfDay() }
        }
        refreshState()
        scheduleUpload(10_000)
        // The lock that leaving sent may have reached the machine before this answer did.
        if (left && allowed) machine(r.machine)?.let { lock(it, "place") }
        return Sent.POSTED
    }

    /** The time a reply may still go, on this phone's clock. */
    private fun deadline(r: RelayRequest): Long = waiting.value.firstOrNull { it.relay.id == r.id }?.deadline
        ?: Answers.deadline(System.currentTimeMillis(), r.created, r.expires)

    /** Posts a reply with the retries of SPEC.md 8.5, until the request's deadline. */
    private suspend fun post(r: RelayRequest, sealed: String, delaySecs: Int?, userTapped: Boolean): Sent {
        val backoff = listOf(1_000L, 2_000L, 4_000L)
        var attempt = 0
        val until = deadline(r)
        while (System.currentTimeMillis() < until) {
            try {
                relay.reply(r.id, sealed, delaySecs, userTapped)
                relayOk()
                return Sent.POSTED
            } catch (e: RelayException) {
                if (e.code == "gone") {
                    safe { store.closeRequest(r.id, "expired") }
                    waiting.update { list -> list.map { if (it.relay.id == r.id) it.copy(expired = true) else it } }
                    Notify.cancel(context, r.id)
                    return Sent.GONE
                }
                if (e is RateLimitedException || e.status in 400..499) { relayFailed(e); return Sent.FAILED }
                relayFailed(e)
            } catch (e: IOException) {
                relayFailed(e)
            }
            delay(backoff.getOrElse(attempt) { 10_000L })
            attempt++
        }
        return Sent.GONE
    }

    // ---------- levels 2 and 3 ----------

    /** A wrong number: refuse with `no_match` and hold the machine for an hour. */
    suspend fun wrongNumber(w: Waiting) {
        reply(w.request, w.relay, Decision.Refuse(RefuseReason.NO_MATCH), "denied", allowed = false)
        applyLocal(LocalEvent.SetHold(Hold(w.machine.key, (System.currentTimeMillis() + 3_600_000).toULong())))
        waiting.update { list -> list.filter { it.relay.id != w.relay.id } }
    }

    fun releaseHold(machine: String) = applyLocal(LocalEvent.ClearHold(machine))

    /** Denies a sensitive request (Deny, "I don't see a number"). */
    suspend fun deny(w: Waiting) {
        reply(w.request, w.relay, Decision.Deny, "denied", allowed = false)
        waiting.update { list -> list.filter { it.relay.id != w.relay.id } }
        Notify.cancel(context, w.relay.id)
    }

    /** Refuses a sensitive request for a reason (no biometrics, unsupported). */
    suspend fun refuse(w: Waiting, err: RefuseReason) {
        reply(w.request, w.relay, Decision.Refuse(err), "denied", allowed = false)
        waiting.update { list -> list.filter { it.relay.id != w.relay.id } }
        Notify.cancel(context, w.relay.id)
    }

    /** The level 3 delay in seconds (shortened only in debug builds that ask for it). */
    fun delaySecs(verdictDelay: Int): Int =
        if (verdictDelay > 0 && BuildConfig.DEBUG && BuildConfig.TEST_DELAY_SECS > 0) BuildConfig.TEST_DELAY_SECS else verdictDelay

    /**
     * After biometrics: answer a level 2 or 3 request. `unseal` signs the plan, with the
     * not-before time two hours on away from a trusted place.
     */
    suspend fun confirmSensitive(w: Waiting): Boolean {
        val place = placeKind()
        return when (w.verdict.kind) {
            RequestKind.UNSEAL -> {
                val delay = delaySecs(w.verdict.delaySecs.toInt())
                val notBefore = System.currentTimeMillis() + delay * 1000L
                val ok = reply(w.request, w.relay, Decision.Plan(place, notBefore.toULong()), "confirmed", allowed = true,
                    delaySecs = if (delay > 0) delay else null)
                if (ok) {
                    val plan = w.plan ?: w.request.plan()
                    applyLocal(LocalEvent.PutPlan(PlanApprovalRecord(
                        machine = w.machine.key, requestId = w.relay.id, planHash = plan?.hash ?: "",
                        items = plan?.items?.map { PlanItemRecord(it.kind, it.name, it.purpose, it.id) } ?: emptyList(),
                        keys = plan?.items?.mapNotNull { i -> if (i.purpose != null && i.id != null) KeyRefRecord(i.purpose!!, i.id!!) else null }?.distinct() ?: emptyList(),
                        notBefore = notBefore.toULong(), state = if (delay > 0) "delayed" else "approved",
                        delayId = if (delay > 0) w.relay.id else null, all = plan?.all ?: false,
                    )))
                    if (delay > 0) {
                        applyLocal(LocalEvent.PutDelayed(DelayedAction(
                            id = w.relay.id, what = "unseal_all", machine = w.machine.key,
                            releaseAt = notBefore.toULong(), expires = (notBefore + 900_000).toULong(),
                            state = "waiting", cancelledBy = null,
                        )))
                        scope.launch { sendNotice("unseal_all", "pending", w.machine.key, w.relay.id, notBefore) }
                    }
                    waiting.update { list -> list.filter { it.relay.id != w.relay.id } }
                    Notify.cancel(context, w.relay.id)
                }
                ok
            }
            RequestKind.KEYS -> {
                val ok = reply(w.request, w.relay, Decision.Once(place), "confirmed", allowed = true)
                if (ok) { waiting.update { list -> list.filter { it.relay.id != w.relay.id } }; Notify.cancel(context, w.relay.id) }
                ok
            }
            else -> {
                // rewrap and old_words need a change of words in progress (not built yet).
                refuse(w, RefuseReason.UNSUPPORTED); false
            }
        }
    }

    // ---------- delayed approvals (SPEC.md 11.23) ----------

    /** Returns whether the relay's list was fetched. */
    suspend fun refreshDelayed(): Boolean {
        if (phoneKeys() == null) return false
        val list = runCatching { relay.listDelayed() }.getOrNull() ?: return false
        for (d in list) {
            val mine = local.value.delayed.firstOrNull { it.id == d.id }
            if (mine == null) {
                applyLocal(LocalEvent.PutDelayed(DelayedAction(d.id, if (d.machine != null) "unseal_all" else "unknown", d.machine,
                    d.releaseAt.toULong(), d.expires.toULong(), d.state, d.by)))
            } else if (mine.state != d.state && mine.state != "cancelled") {
                if (d.state == "cancelled") delayedCancelled(d.id, d.by)
                else applyLocal(LocalEvent.PutDelayed(mine.copy(state = d.state)))
            }
        }
        // However the cancel arrived (socket, push, this list), its plan hands out no keys.
        for (p in Plans.toCancel(local.value.plans, local.value.delayed)) applyLocal(LocalEvent.PutPlan(p.copy(state = "cancelled")))
        // Records the relay no longer has: fetched by the machine, finished or expired.
        val ids = list.map { it.id }.toSet()
        for (d in local.value.delayed) {
            if (d.id !in ids && d.state == "waiting" && System.currentTimeMillis() > d.releaseAt.toLong()) {
                // A machine's record leaves when the machine fetches it; a phone-only one leaves
                // only when this phone finishes it or it expires, so a missing one is gone.
                applyLocal(LocalEvent.PutDelayed(d.copy(state = if (d.machine == null) "gone" else "released")))
            }
        }
        delayedTick.value = System.currentTimeMillis()
        return true
    }

    /**
     * A delayed approval was cancelled elsewhere: record it, close its plan, and when a
     * computer cancelled it, tell every machine (SPEC.md 11.23).
     */
    private suspend fun delayedCancelled(id: String, by: String?) {
        val d = local.value.delayed.firstOrNull { it.id == id }
        if (d != null && d.state != "cancelled") {
            applyLocal(LocalEvent.PutDelayed(d.copy(state = "cancelled", cancelledBy = by)))
            if (by != null && by != "phone") scope.launch { sendNotice(d.what, "cancelled", d.machine, id, d.releaseAt.toLong()) }
        }
        takeBackReady(id)
        for (p in local.value.plans.filter { it.delayId == id && it.state != "cancelled" }) {
            applyLocal(LocalEvent.PutPlan(p.copy(state = "cancelled")))
        }
        delayedTick.value = System.currentTimeMillis()
    }

    /** Cancel needs no biometrics: stopping is always allowed. */
    suspend fun cancelDelayed(id: String): Boolean {
        val d = local.value.delayed.firstOrNull { it.id == id }
        return try {
            relay.cancelDelayed(id)
            d?.let { applyLocal(LocalEvent.PutDelayed(it.copy(state = "cancelled", cancelledBy = "phone"))) }
            local.value.plans.firstOrNull { it.delayId == id }?.let { applyLocal(LocalEvent.PutPlan(it.copy(state = "cancelled"))) }
            scope.launch { sendNotice(d?.what ?: "unseal_all", "cancelled", d?.machine, id, d?.releaseAt?.toLong()) }
            takeBackReady(id)
            delayedTick.value = System.currentTimeMillis()
            true
        } catch (e: Exception) {
            relayFailed(e as? Exception ?: Exception()); false
        }
    }

    /** A cancelled action on the phone: no "Ready" note at its end (SPEC.md 11.23). */
    private fun takeBackReady(id: String) {
        Notify.cancel(context, "ready-$id")
        runCatching { WorkManager.getInstance(context).cancelUniqueWork("release-$id") }
    }

    /** Starts a level 3 action on the phone: at once at a trusted place, else after the hour. */
    suspend fun startPhoneAction(what: String): DelayedAction? {
        if (delayLifted()) return null
        val delay = delaySecs(7200)
        val id = randomId()
        val d = relay.addDelayed(id, delay)
        val action = DelayedAction(id, what, null, d.releaseAt.toULong(), d.expires.toULong(), "waiting", null)
        applyLocal(LocalEvent.PutDelayed(action))
        ReleaseWorker.schedule(context, id, what, d.releaseAt)
        scope.launch { sendNotice(what, "pending", null, id, d.releaseAt) }
        return action
    }

    /** After the hour and biometrics again: the relay must answer `finish` with 200. */
    suspend fun finishPhoneAction(id: String): String? = try {
        relay.finishDelayed(id)
        local.value.delayed.firstOrNull { it.id == id }?.let { applyLocal(LocalEvent.PutDelayed(it.copy(state = "finished"))) }
        null
    } catch (e: RelayException) {
        when (e.code) {
            "cancelled" -> {
                local.value.delayed.firstOrNull { it.id == id }?.let {
                    applyLocal(LocalEvent.PutDelayed(it.copy(state = "cancelled", cancelledBy = e.body.strOrNull("by"))))
                }
                takeBackReady(id)
                "cancelled:" + (e.body.strOrNull("by") ?: "")
            }
            "too_early" -> "too_early"
            "gone" -> {
                // Terminal: the relay no longer has it (it expired). Record that, so the screen
                // offers a new start instead of a Finish that can only get `gone` again.
                local.value.delayed.firstOrNull { it.id == id }?.let { applyLocal(LocalEvent.PutDelayed(it.copy(state = "gone"))) }
                "gone"
            }
            else -> "relay"
        }
    } catch (e: IOException) {
        "relay"
    }

    /** A sealed `notice` to every paired machine (SPEC.md 9.6). */
    suspend fun sendNotice(what: String, st: String, machine: String?, delayId: String?, at: Long?, done: Int = 0, failed: Int = 0, skipped: Int = 0) {
        val keys = phoneKeys() ?: return
        val report = if (st == "done") com.sealctl.core.NoticeReport(done.toULong(), failed.toULong(), skipped.toULong(), emptyList()) else null
        val name = machine?.let { machine(it)?.name }
        for (m in liveMachines()) {
            if (m.boxKey.isEmpty()) continue
            val msg = MachineMessage(1u, System.currentTimeMillis().toULong(), nextSeq(m.key),
                MessageKind.Notice(Notice(what, st, name, delayId, at?.toULong(), report)))
            runCatching { relay.postMessage(m.key, sealMachineMessage(keys, m.key, m.boxKey, msg)) }
        }
    }

    private fun nextSeq(machine: String): ULong = safe { store.nextMessageSeq(machine) } ?: System.currentTimeMillis().toULong()

    // ---------- machines ----------

    /** Sends a lock to a machine; the relay holds it up to 24 hours. */
    suspend fun lock(machine: Machine, reason: String = "phone"): Boolean {
        val keys = phoneKeys() ?: return false
        if (machine.boxKey.isEmpty()) return false
        val msg = MachineMessage(1u, System.currentTimeMillis().toULong(), nextSeq(machine.key), MessageKind.Lock(reason))
        return runCatching {
            relay.postMessage(machine.key, sealMachineMessage(keys, machine.key, machine.boxKey, msg)); true
        }.getOrElse { relayFailed(it as? Exception ?: Exception()); false }
    }

    suspend fun lockAll(): Int {
        var n = 0
        for (m in liveMachines()) if (MachineView.of(m, this).state == com.sealctl.designsystem.MachineState.Open && lock(m)) n++
        return n
    }

    suspend fun unpair(machine: Machine): Boolean {
        lock(machine)
        return try {
            relay.removeMachine(machine.key)
            apply(Event.UnpairMachine(machine.key), upload = true)
            true
        } catch (e: Exception) {
            relayFailed(e); false
        }
    }

    suspend fun refreshMachines() {
        val list = runCatching { relay.machines() }.getOrNull() ?: return
        apply(Event.MachinesListed(list.map { MachineSeen(it.machine, it.lastSeen?.toULong()) }))
        val keys = list.map { it.machine }.toSet()
        relayMachines.value = keys
        // A machine that unpaired itself (`sealctl unseal --all`, `sealctl unpair`) leaves the
        // list; while leaving, the rows stay to show "Handed back".
        if (local.value.leaveStep == 0u) {
            for (m in liveMachines().filter { it.key !in keys }) apply(Event.UnpairMachine(m.key))
        }
    }

    /** Machines the relay lists as paired, for Leave sealctl (SPEC.md 11.22 step 2). */
    val relayMachines = MutableStateFlow<Set<String>?>(null)

    suspend fun refreshStatus() {
        val keys = phoneKeys() ?: return
        val list = runCatching { relay.status() }.getOrNull() ?: return
        for (s in list) {
            if (machine(s.machine) == null) continue
            val st = runCatching { openMachineStatus(keys, s.machine, s.sealed) }.getOrNull() ?: continue
            safe { store.applyStatus(s.machine, st, offset()) }
        }
        refreshState()
    }

    // ---------- pairing (SPEC.md 11.5) ----------

    sealed class PairError(val text: String) {
        class Message(text: String) : PairError(text)
    }

    /** Parses a scanned or typed code; returns the offer or the error text of 11.20. */
    fun parseOffer(text: String): Result<PairingOffer> = runCatching { PairingOffer.parse(text.trim()) }.fold(
        onSuccess = { offer ->
            if (offer.relayOrigin().trimEnd('/') != relay.baseUrl.trimEnd('/')) {
                Result.failure(Exception(Texts.otherRelay(offer.relayOrigin(), relay.host)))
            } else Result.success(offer)
        },
        onFailure = { e ->
            Result.failure(Exception(when (e) {
                is com.sealctl.core.CoreException.Expired -> Texts.CODE_EXPIRED
                is com.sealctl.core.CoreException.NewerVersion -> Texts.NEWER_VERSION
                else -> Texts.NOT_A_CODE
            }))
        },
    )

    /** Registers the machine with the relay after biometrics. */
    suspend fun pair(offer: PairingOffer, replaces: String?): Result<Machine> {
        val keys = phoneKeys() ?: return Result.failure(Exception(Texts.UNLOCK_TO_ANSWER))
        val proof = pairingProof(keys, offer)
        return try {
            relay.addMachine(offer.machineKey(), offer.name(), offer.os(), offer.model(), proof)
            val m = Machine(
                key = offer.machineKey(), boxKey = offer.machineBoxKey(), name = offer.name(), os = offer.os(),
                model = offer.model(), hint = offer.hint(), pairedAt = System.currentTimeMillis().toULong(),
                nickname = null, lastSeen = System.currentTimeMillis().toULong(), lastStatus = null, tagShown = false,
                flagged = false, relay = offer.relayOrigin(), updated = 0u, deleted = false,
            )
            apply(Event.PairMachine(m, replaces), upload = true)
            if (replaces != null) runCatching { relay.removeMachine(replaces) }
            Result.success(m)
        } catch (e: RelayException) {
            Result.failure(Exception(when {
                e.code == "too_many_machines" -> Texts.TOO_MANY
                e.status == 402 -> Texts.LICENCE_REQUIRED
                else -> Texts.relayError(e.code)
            }))
        } catch (e: IOException) {
            Result.failure(Exception(Texts.RELAY_DOWN))
        }
    }

    // ---------- sync (SPEC.md 6.5) ----------

    fun scheduleUpload(delayMs: Long) {
        uploadJob?.cancel()
        uploadJob = scope.launch {
            if (delayMs > 0) delay(delayMs)
            upload()
        }
    }

    suspend fun upload(): Boolean {
        if (!state.value.settings.relayBackup || phase.value !is Phase.Ready && phase.value !is Phase.Onboarding) return false
        repeat(3) {
            val blob = withRoot { root -> stateSeal(root, store.stateForUpload()) } ?: return false
            try {
                val rev = relay.putState(local.value.stateRev.toLong(), blob)
                applyLocal(LocalEvent.Synced(rev.toULong(), uploaded = true))
                return true
            } catch (e: ConflictException) {
                if (!download()) return false
            } catch (e: Exception) {
                relayFailed(e); return false
            }
        }
        return false
    }

    /** Downloads and merges the relay state. */
    suspend fun download(): Boolean {
        if (phoneKeys() == null) return false
        return try {
            val (rev, blob) = relay.getState()
            if (blob != null) {
                val remote = withRoot { root -> decodeState(stateOpen(root, blob)) } ?: return false
                apply(Event.MergeRemote(remote))
            }
            applyLocal(LocalEvent.Synced(rev.toULong(), uploaded = false))
            true
        } catch (e: Exception) {
            relayFailed(e); false
        }
    }

    // ---------- push (SPEC.md 8.2, 10.2) ----------

    fun deviceId(): String {
        val d = local.value.device
        if (d.deviceId.isNotEmpty()) return d.deviceId
        val id = randomId()
        applyLocal(LocalEvent.SetDevice(DeviceInfo(id, null, "fcm", false, 0u)))
        return id
    }

    /**
     * Registers this install's FCM token. Not once Leave sealctl has reached its deletion step:
     * that would put this phone back on the relay (SPEC.md 11.22).
     */
    suspend fun registerPush(token: String? = null) {
        if (!BuildConfig.HAS_FIREBASE || local.value.leaveStep >= 5u || phoneKeys() == null) return
        val t = token ?: runCatching { Push.token() }.getOrNull() ?: return
        val id = deviceId()
        try {
            relay.putPush(id, t)
            applyLocal(LocalEvent.SetDevice(DeviceInfo(id, t, "fcm", false, System.currentTimeMillis().toULong())))
        } catch (e: Exception) {
            relayFailed(e)
        }
    }

    fun onPush(type: String, id: String?, expires: Long) {
        scope.launch {
            when (type) {
                "request" -> catchUp(fromPush = true)
                "test" -> Notify.show(context, Notify.REQUESTS, "test", Texts.TEST_PUSH, null, timeoutMs = 60_000)
                "delayed" -> {
                    refreshDelayed()
                    Notify.show(context, Notify.SENSITIVE, "delayed-$id", Texts.DELAYED_TITLE, Texts.DELAYED_BODY, screen = "delayed:$id")
                }
                "cancelled" -> {
                    refreshDelayed()
                    Notify.show(context, Notify.SENSITIVE, "cancelled-$id", Texts.CANCELLED_TITLE, Texts.CANCELLED_BODY)
                }
            }
        }
    }

    // ---------- places (SPEC.md 11.9) ----------

    private suspend fun firstApprovalOfDay() {
        val fix = places.sample() ?: return
        val c = safe {
            store.placeSample(LocationSample(fix.lat, fix.lon, fix.accuracy, fix.time.toULong()), offset())
        }
        refreshState()
        if (c != null) {
            placeOffer.value = c
            Notify.show(context, Notify.PLACES, "place-${c.id}", Texts.PLACE_LEARNED, null, screen = "place")
        }
    }

    suspend fun monitorPlaces() {
        places.monitor(state.value.places.filter { !it.deleted }.map { Fence(it.id, it.lat, it.lon, it.radius.toFloat()) })
    }

    /** The phone left a place: lock every machine whose day began there. */
    fun onPlaceTransition(ids: List<String>, entered: Boolean) {
        scope.launch {
            if (entered) {
                currentPlace.value = ids.firstOrNull()
                return@launch
            }
            if (currentPlace.value in ids) currentPlace.value = null
            // An answer made at the place and still on its way locks its machine once posted.
            placeExits.incrementAndGet()
            for (id in ids) {
                val place = state.value.places.firstOrNull { it.id == id } ?: continue
                val days = local.value.days.filter { it.placeId == id }
                val locked = days.mapNotNull { d -> machine(d.machine) }.filter { lock(it, "place") }
                if (locked.isNotEmpty()) {
                    Notify.show(context, Notify.PLACES, "left-$id", Texts.leftPlace(place.name, locked.joinToString { displayName(it) }), null)
                }
            }
        }
    }

    // ---------- network ----------

    private fun watchNetwork() {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                banners.value = banners.value.copy(offline = false)
                if (foreground.value) scope.launch { catchUp() }
            }

            override fun onLost(network: Network) {
                banners.value = banners.value.copy(offline = true)
                onWifi = false
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                onWifi = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            }
        })
    }

    companion object {
        private const val TAG = "sealctl"

        fun emptyState() = State(emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), null,
            com.sealctl.core.app.Settings(true, true, 0u), emptyList())

        fun emptyLocal() = LocalState(emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), emptyList(),
            DeviceInfo("", null, "fcm", false, 0u), 0u, 0u, 0u, 0u, false, false, emptyList(), false, 0u, emptyList())
    }
}

inline fun <T> safe(block: () -> T): T? = try {
    block()
} catch (e: Exception) {
    dlog("store: ${e.javaClass.simpleName}")
    null
}

/** Debug builds only: release builds make no Log calls (SPEC.md 2 rule 7). Never logs names or values. */
fun dlog(msg: String) {
    if (BuildConfig.DEBUG) Log.w("sealctl", msg)
}

inline fun safeBool(block: () -> Boolean): Boolean = safe(block) ?: false

@Suppress("unused")
private fun JsonObject.longValue(k: String) = this[k]?.jsonPrimitive?.longOrNull
