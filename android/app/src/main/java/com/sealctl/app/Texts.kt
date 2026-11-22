package com.sealctl.app

import com.sealctl.core.RequestKind
import com.sealctl.core.app.ReplyOption
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The app's wording, exactly as SPEC.md 11 gives it. Kept in one place so it can move to
 * string resources for translation (SPEC.md 13) without touching the screens.
 */
object Texts {
    // ---------- approval card and notifications (11.7) ----------

    /** Facts of a request that the card and the notification show. */
    data class Facts(
        val kind: RequestKind,
        val level: Int,
        val subjectKind: String?,
        val subjectName: String?,
        val names: List<String>,
        val agent: String?,
        val command: String?,
        val cwd: String?,
        val repoName: String?,
        val machineName: String,
        val firstItem: String?,
        val all: Boolean,
    )

    fun facts(w: Waiting, machineName: String): Facts {
        val ctx = w.request.ctx()
        val plan = w.plan
        return Facts(
            kind = w.verdict.kind,
            level = w.verdict.level.toInt(),
            subjectKind = ctx?.subject?.kind,
            subjectName = ctx?.subject?.name?.takeIf { it.isNotEmpty() },
            names = ctx?.names ?: emptyList(),
            agent = ctx?.agent,
            command = ctx?.command?.takeIf { it.isNotEmpty() },
            cwd = ctx?.cwd?.takeIf { it.isNotEmpty() },
            repoName = ctx?.repo?.name?.takeIf { it.isNotEmpty() },
            machineName = machineName,
            firstItem = w.request.items().firstOrNull()?.let { it.`object`?.path?.takeIf { p -> p.isNotEmpty() } ?: it.id },
            all = plan?.all ?: false,
        )
    }

    private fun subject(f: Facts) = f.subjectName ?: f.names.firstOrNull()

    /** The card's title by subject (11.7 "Titles by subject"). */
    fun title(f: Facts): String {
        val s = subject(f)
        return when (f.kind) {
            RequestKind.AGENT -> "Let ${f.agent ?: "an agent"} use ${s ?: "this key"}?"
            RequestKind.OWN -> "Allow ${s ?: "this key"} once?"
            RequestKind.KEYS -> if (f.level >= 2) "Let sealctl seal take over ${subjectPhrase(f)} on ${f.machineName}?"
                else "Allow ${subjectPhrase(f)}?"
            RequestKind.UNSEAL -> if (f.all || f.level >= 3) "Hand back everything on ${f.machineName}?"
                else "Hand back ${subjectPhrase(f)} from ${f.machineName}?"
            RequestKind.REWRAP -> "Move ${f.machineName} to new words?"
            RequestKind.OLD_WORDS -> "Move an object sealed with old words?"
            RequestKind.UNKNOWN -> "${f.machineName} sent a request this app doesn't understand. Update the app."
            else -> when (f.subjectKind) {
                "volume" -> "Mount volume $s?"
                "backup" -> "Back up to $s?"
                "ssh" -> "Use SSH key $s?"
                "secret" -> "Allow $s?"
                null, "", "machine" -> if (s != null && f.subjectKind == null) "Allow $s?" else "Open ${f.machineName}?"
                else -> "Allow $s?"
            }
        }
    }

    private fun subjectPhrase(f: Facts): String {
        val s = subject(f) ?: f.firstItem ?: "this object"
        return when (f.subjectKind) {
            "volume" -> "volume $s"
            "backup" -> "backup $s"
            "ssh" -> "SSH key $s"
            else -> s
        }
    }

    /** The part of the title shown in monospace and the accent colour. */
    fun titleSubject(f: Facts): String? = subject(f)

    /** Notification title and body (11.7 "Notification text"). */
    fun notification(w: Waiting, machineName: String): Pair<String, String> {
        val f = facts(w, machineName)
        val cmdIn = listOfNotNull(f.command?.let(::cut), f.cwd?.let { "in $it" }).joinToString(" ")
        return when {
            f.kind == RequestKind.REWRAP -> "Move $machineName to new words?" to "Open sealctl to confirm with your fingerprint."
            f.kind == RequestKind.KEYS && f.level >= 2 -> "sealctl seal on $machineName" to "Open sealctl to see what it takes over."
            f.kind == RequestKind.UNSEAL && f.level >= 3 -> "Leave sealctl on $machineName?" to "Open sealctl to confirm. You'll need the number on its screen."
            f.kind == RequestKind.UNSEAL -> "Hand back from $machineName?" to "Open sealctl to see what."
            f.kind == RequestKind.OLD_WORDS -> "$machineName has an object sealed with old words." to "Open sealctl to move it."
            f.kind == RequestKind.UNKNOWN -> title(f) to ""
            f.kind == RequestKind.AGENT -> title(f) to listOfNotNull(f.repoName?.let { "First use in $it" }, f.command?.let(::cut), machineName).joinToString(" · ")
            f.kind == RequestKind.OWN -> title(f) to listOfNotNull(cmdIn.ifEmpty { null }, machineName).joinToString(" · ")
            f.kind == RequestKind.KEYS -> title(f) to machineName
            else -> title(f) to listOfNotNull(cmdIn.ifEmpty { null }, machineName, f.agent).joinToString(" · ")
        }
    }

    /** "For" is cut in the middle after 80 characters. */
    fun cut(command: String): String =
        if (command.length <= 80) command else command.take(39) + "…" + command.takeLast(40)

    /** The note under the facts (11.7 "By kind"). */
    fun note(w: Waiting): String? {
        val ctx = w.request.ctx()
        val agent = ctx?.agent ?: w.request.uses().firstOrNull()?.agent
        val repo = ctx?.repo?.name ?: w.request.uses().firstOrNull()?.repository?.substringAfterLast('/')
        return when (w.verdict.kind) {
            RequestKind.OPEN -> if (w.verdict.agentFirstUse && agent != null) "First use of this key by $agent in $repo. Allow is remembered." else null
            RequestKind.AGENT -> "First use of this key by $agent in $repo. Allow is remembered; remove it in Answers."
            RequestKind.OWN -> "This key asks every time. It stays in memory only until the command exits."
            RequestKind.KEYS -> if (ctx?.command?.startsWith("sealctl seal") == true) "sealctl seal of a new object on this machine." else null
            else -> null
        }
    }

    const val AGENT_NOTE = "Agents ask once for each key in each repository. Your answer is kept on this phone, not in the repository."

    fun button(o: ReplyOption, kind: RequestKind): String = when (o) {
        ReplyOption.ALLOW_SESSION -> "Allow for this session"
        ReplyOption.ALLOW -> "Allow"
        ReplyOption.ALLOW_ONCE -> "Allow once"
        ReplyOption.DENY -> "Deny"
        ReplyOption.CONFIRM -> "Confirm with fingerprint or face"
    }

    fun afterAnswer(o: ReplyOption, w: Waiting): String = when (o) {
        ReplyOption.ALLOW_SESSION -> if (w.verdict.agentFirstUse) remembered(w) else "Allowed for this session"
        ReplyOption.ALLOW -> if (w.verdict.kind == RequestKind.AGENT) remembered(w) else "Allowed for this session"
        ReplyOption.ALLOW_ONCE -> "Allowed once"
        ReplyOption.DENY -> "Denied"
        ReplyOption.CONFIRM -> "Confirmed"
    }

    private fun remembered(w: Waiting): String {
        val u = w.request.uses().firstOrNull()
        val repo = w.request.ctx()?.repo?.name ?: u?.repository?.substringAfterLast('/') ?: ""
        return "Remembered for ${u?.agent ?: "the agent"} in $repo"
    }

    fun waitingFor(seconds: Long) = "WAITING · %d:%02d".format(seconds / 60, seconds % 60)
    fun moreWaiting(n: Int) = "$n more waiting"
    fun stoppedWaiting(name: String) = "$name stopped waiting."
    fun answersHere(place: String) = "At $place, this answers by itself."
    fun answeredByItself(name: String, place: String?) = if (place != null) "Opened $name at $place." else "Opened $name."
    fun unlockToAnswer(name: String) = "Unlock your phone to answer $name."
    const val UNLOCK_TO_ANSWER = "Unlock your phone to answer."

    fun agentName(a: String?): String = when (a) {
        "claude" -> "Claude Code"
        "codex" -> "Codex"
        "gemini" -> "Gemini CLI"
        "qwen" -> "Qwen Code"
        "copilot" -> "Copilot"
        "cursor" -> "Cursor"
        null -> "you"
        else -> a
    }

    // ---------- levels 2 and 3 (9.6, 11.23) ----------

    fun notNear(name: String) = "$name isn't near this phone. Run the command at its terminal; this phone then asks for the number on its screen."
    const val NO_BIOMETRICS = "This needs a fingerprint or face unlock of the strong class, and this phone has none set up."
    const val LOCKED_OUT = "Fingerprint is locked after too many tries. Lock and unlock your phone with its screen lock, then try again."
    fun whichNumber(name: String) = "Which number does $name show?"
    const val LOOK_AT_TERMINAL = "Look at the terminal where you ran the command."
    const val NO_NUMBER = "I don't see a number"
    fun wrongNumber(name: String) = "That's not the number on $name"
    const val WRONG_NUMBER_BODY = "The request was refused. For the next hour this phone ignores sensitive requests from that computer."
    const val WRONG_NUMBER_WHAT = "Didn't run anything there? Someone else may be using it."
    fun held(name: String, until: Long) = "Sensitive requests from $name are held until ${time(until)} after a wrong number."
    fun handBackAll(name: String) = "Hand back everything on $name?"
    const val HAND_BACK_ALL_BODY = "sealctl unseal --all moves these to passwords of your own. Your files stay encrypted. Then the computer is unpaired."
    const val AT_TRUSTED = "this starts as soon as you confirm."
    const val AWAY = "Away from your trusted places: this starts one hour after you confirm. Your phone and your computers can cancel it until then."
    const val AWAY_NO_LOCATION = "This starts one hour after you confirm. Your phone and your computers can cancel it until then."
    const val CONFIRM = "Confirm with fingerprint or face"
    fun leaving(name: String) = "Leaving sealctl on $name"
    fun startsAt(at: Long, now: Long): String {
        val mins = ((at - now).coerceAtLeast(0) + 59_999) / 60_000
        return "Starts at ${time(at)} · $mins min left"
    }
    const val DELAY_BODY = "You approved this away from your trusted places, so it waits an hour. Every paired computer has been told. If this wasn't you, cancel it."
    const val CANCELLED_HERE = "Cancelled. Nothing was handed back."
    fun cancelledFrom(name: String) = "Cancelled from $name."
    fun handsBackAt(name: String, at: Long) = "$name hands everything back at ${time(at)}."
    fun handedBack(name: String, done: Int, failed: Int) = "$name handed back $done objects. $failed failed."

    // ---------- pairing and errors (11.5, 11.20) ----------

    const val NOT_A_CODE = "This isn't a sealctl pairing code."
    const val CODE_EXPIRED = "This code has expired. Run `sealctl pair` again."
    const val NEWER_VERSION = "This machine runs a newer sealctl. Update the app."
    fun otherRelay(theirs: String, ours: String) = "This machine uses another relay (${theirs.removePrefix("https://").removePrefix("http://")}). This phone uses $ours."
    const val TOO_MANY = "This phone has 100 machines paired, the most it can have. Unpair one first."
    const val LICENCE_REQUIRED = "The relay didn't accept this machine. Run `sealctl status` on it to see why."
    const val RELAY_DOWN = "The relay isn't answering. Trying again."
    fun relayError(code: String) = "The relay refused this ($code)."
    fun paired(name: String) = "Paired. $name can now ask this phone for keys."
    const val OFFLINE = "Offline. Requests reach this phone when it is back online."
    const val NOTIFICATIONS_OFF = "Notifications are off. Requests can't reach you while sealctl is closed."
    fun rateLimited(until: Long) = "This phone has used its relay limit for today. It resets at ${time(until)}."
    const val CLOCK = "This phone's clock is more than 5 minutes off. Turn on automatic date and time."
    const val SIGNATURE = "The relay refused this phone's signature. Update the app."
    const val BACKGROUND_RESTRICTED = "Android is limiting sealctl in the background. Requests may arrive late."

    // ---------- pushes and notices (10.1, 10.4) ----------

    const val TEST_PUSH = "Test from the relay. Requests reach this phone."
    const val DELAYED_TITLE = "Approved on your phone"
    const val DELAYED_BODY = "Something sensitive was approved on your phone and starts in an hour. Open sealctl to see it or cancel it."
    const val CANCELLED_TITLE = "Cancelled"
    const val CANCELLED_BODY = "A pending sensitive action was cancelled."
    const val PLACE_LEARNED = "Trust this place? You opened your machines here on 3 mornings."
    fun leftPlace(place: String, names: String) = "You left $place. Locked $names."
    fun ready(what: String) = "Ready: open sealctl to finish " + when (what) {
        "words" -> "showing your words."
        "delete" -> "deleting your relay data."
        else -> "leaving."
    }

    // ---------- formatting ----------

    fun time(ms: Long): String =
        DateTimeFormatter.ofPattern("HH:mm").format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))

    fun isoDate(ms: Long): String = Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()).toLocalDate().toString()

    fun mediumDate(ms: Long): String =
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).format(Instant.ofEpochMilli(ms).atZone(ZoneId.systemDefault()))

    /** "2 h 10 min" */
    fun duration(seconds: Long): String {
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        return when {
            h > 0 && m > 0 -> "$h h $m min"
            h > 0 -> "$h h"
            else -> "${m.coerceAtLeast(1)} min"
        }
    }

    /** "seen 2 min ago", "seen yesterday". */
    fun ago(ms: Long?, now: Long = System.currentTimeMillis()): String {
        if (ms == null || ms == 0L) return "never seen"
        val s = (now - ms) / 1000
        return when {
            s < 60 -> "just now"
            s < 3600 -> "${s / 60} min ago"
            s < 86_400 -> "${s / 3600} h ago"
            s < 2 * 86_400 -> "yesterday"
            else -> "${s / 86_400} days ago"
        }
    }
}
