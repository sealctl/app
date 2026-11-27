package com.sealctl.app

import com.sealctl.core.RequestKind
import com.sealctl.core.app.ReplyOption
import com.sealctl.vault.AuthResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The wording of SPEC.md 11.7 and 11.20. */
class TextsTest {
    private fun f(kind: RequestKind, subjectKind: String? = null, subject: String? = null, level: Int = 1, agent: String? = null, all: Boolean = false) =
        Texts.Facts(kind, level, subjectKind, subject, emptyList(), agent, "npm test", "~/dev/shop", "shop", "dev@mbp.example.com", null, all)

    @Test
    fun titlesBySubject() {
        assertEquals("Allow OPENAI_API_KEY?", Texts.title(f(RequestKind.OPEN, "secret", "OPENAI_API_KEY")))
        assertEquals("Mount volume clients?", Texts.title(f(RequestKind.OPEN, "volume", "clients")))
        assertEquals("Back up to r2:acme-backups?", Texts.title(f(RequestKind.OPEN, "backup", "r2:acme-backups")))
        assertEquals("Use SSH key github?", Texts.title(f(RequestKind.OPEN, "ssh", "github")))
        assertEquals("Open dev@mbp.example.com?", Texts.title(f(RequestKind.OPEN)))
        assertEquals("Allow volume clients?", Texts.title(f(RequestKind.KEYS, "volume", "clients")))
        assertEquals("Let claude use OPENAI_API_KEY?", Texts.title(f(RequestKind.AGENT, "secret", "OPENAI_API_KEY", agent = "claude")))
        assertEquals("Allow DEPLOY_TOKEN once?", Texts.title(f(RequestKind.OWN, "secret", "DEPLOY_TOKEN")))
        assertEquals("Hand back everything on dev@mbp.example.com?", Texts.title(f(RequestKind.UNSEAL, level = 3, all = true)))
        assertEquals("Hand back volume safe from dev@mbp.example.com?", Texts.title(f(RequestKind.UNSEAL, "volume", "safe", level = 2)))
        assertEquals("Let sealctl seal take over volume safe on dev@mbp.example.com?", Texts.title(f(RequestKind.KEYS, "volume", "safe", level = 2)))
        assertTrue(Texts.title(f(RequestKind.UNKNOWN)).endsWith("doesn't understand. Update the app."))
    }

    @Test
    fun buttonsAndConfirmations() {
        assertEquals("Allow for this session", Texts.button(ReplyOption.ALLOW_SESSION, RequestKind.OPEN))
        assertEquals("Allow once", Texts.button(ReplyOption.ALLOW_ONCE, RequestKind.OPEN))
        assertEquals("Deny", Texts.button(ReplyOption.DENY, RequestKind.OPEN))
        assertEquals("Confirm with fingerprint or face", Texts.button(ReplyOption.CONFIRM, RequestKind.UNSEAL))
    }

    @Test
    fun durationsAndErrors() {
        assertEquals("2 h 10 min", Texts.duration(7800))
        assertEquals("2 h", Texts.duration(7200))
        assertEquals("1 min", Texts.duration(5))
        assertEquals("This machine uses another relay (relay.example.org). This phone uses relay.sealctl.com.",
            Texts.otherRelay("https://relay.example.org", "relay.sealctl.com"))
        assertEquals("dev@mbp.example.com stopped waiting.", Texts.stoppedWaiting("dev@mbp.example.com"))
        assertEquals("Couldn't send your answer — try again.", Texts.ANSWER_NOT_SENT)
        assertEquals("Claude Code", Texts.agentName("claude"))
        assertEquals("aider", Texts.agentName("aider"))
        assertEquals("Ready: open sealctl to finish showing your words.", Texts.ready("words"))
    }

    @Test
    fun delayedActionsByKind() {
        val at = 7_201_000L
        assertEquals("Showing your words", Texts.delayScreenTitle("words", null))
        assertEquals("Deleting your relay data", Texts.delayScreenTitle("delete", null))
        assertEquals("Leaving sealctl", Texts.delayScreenTitle("leave", null))
        assertEquals("Leaving sealctl on dev@mbp.example.com", Texts.delayScreenTitle("unseal_all", "dev@mbp.example.com"))
        assertEquals("Started on another of your devices", Texts.delayScreenTitle("unknown", null))
        assertEquals(
            "Showing your words, deleting your relay data or leaving sealctl was started on another phone or tablet " +
                "with your words. It goes ahead at ${Texts.time(at)}. Not you? Cancel it.",
            Texts.delayWaiting("unknown", at),
        )
        assertEquals(Texts.DELAY_BODY, Texts.delayWaiting("words", at))
        assertEquals("A protected action started on another of your devices goes ahead at ${Texts.time(at)}.", Texts.delayedAt("unknown", "This phone", at))
        assertEquals(
            "A protected action started on another of your devices" to "It goes ahead at ${Texts.time(at)}. Open sealctl to see it or cancel it.",
            Texts.delayedNote("unknown", at),
        )
        assertEquals(Texts.DELAYED_TITLE to Texts.DELAYED_BODY, Texts.delayedNote("words", at))
        assertEquals(Texts.DELAYED_TITLE to Texts.DELAYED_BODY, Texts.delayedNote(null, at))
        assertEquals("Cancelled. Nothing was handed back.", Texts.delayCancelledHere("unseal_all"))
        assertEquals("Cancelled. Nothing happened.", Texts.delayCancelledHere("unknown"))
        assertEquals("The hour is over. The computer goes ahead.", Texts.delayOver("unseal_all"))
        assertEquals("The wait is over. The phone or tablet that started it can go ahead.", Texts.delayOver("unknown"))
        assertEquals("This waited too long. Start again.", Texts.delayGone("words"))
        assertTrue(Texts.delayGone("unknown").startsWith("This is no longer waiting"))
    }

    /** An action on the phone, by where its delay stands (SPEC.md 11.23). */
    @Test
    fun phoneActionPhases() {
        val started = 1_000_000L
        val at = started + 7_200_000
        val until = at + 3_600_000
        assertEquals("Started at ${Texts.time(started)} · goes ahead at ${Texts.time(at)}", Texts.goesAheadAt(started, at))
        assertEquals("Goes ahead at ${Texts.time(at)}", Texts.goesAheadAt(0, at))
        assertEquals("59 min left", Texts.minutesLeft(at, at - 59 * 60_000))
        assertEquals("Ready until ${Texts.time(until)}", Texts.readyUntil(until))
        assertEquals("Show my words", Texts.readyButton("words"))
        assertEquals("Finish", Texts.readyButton("delete"))
        assertEquals("Finish", Texts.readyButton("leave"))
        assertEquals("Showing your words: ready until ${Texts.time(until)}.", Texts.readyBanner("words", until))
        assertEquals("Open it by ${Texts.time(until)}, or it has to start again.", Texts.readyNote(until))
        assertEquals("This phone leaves sealctl at ${Texts.time(at)}.", Texts.delayedAt("leave", "This phone", at))
    }

    /** The delay screen gives the real reason, what happens next and what Cancel does (11.23). */
    @Test
    fun whyItWaitsAndWhatComesNext() {
        val at = 7_200_000L
        val until = at + 3_600_000
        assertEquals("You started this away from your trusted places, so it waits two hours.", Texts.waitReason("away", null, 0))
        assertEquals("You're away from your trusted places, so this waits two hours.", Texts.waitReason("away", null, 0, started = false))
        assertEquals(
            "You're at Home, which was trusted less than two hours ago, so this still waits two hours. Home skips the wait from ${Texts.time(at)}.",
            Texts.waitReason("unsettled", "Home", at),
        )
        assertEquals("Location isn't set to \"Allow all the time\" for sealctl, so it can't tell when you're at a trusted place. This waits two hours.",
            Texts.waitReason("no_always", null, 0))
        assertEquals("You have no trusted places, so this waits two hours.", Texts.waitReason("places_off", null, 0))
        // A record started before reasons were kept.
        assertEquals("You approved this away from your trusted places, so it waits two hours.", Texts.waitReason("", null, 0))
        assertEquals(
            "At ${Texts.time(at)} sealctl will notify you. Open it then and confirm with your fingerprint or face to see your words. You'll have until ${Texts.time(until)}.",
            Texts.waitNext("words", at, until),
        )
        assertEquals("Cancel stops it: nothing happens, and your computers are told.", Texts.WAIT_CANCEL)
        assertTrue(Texts.beforeStart("delete", "away", null, 0, at).endsWith(
            "If you confirm now, sealctl will notify you at ${Texts.time(at)}. Open it then and confirm with your fingerprint or face to delete your relay data. Every paired computer is told, and can cancel it until then."))
    }

    /** Trusting a place: its row and its banner (11.9). */
    @Test
    fun trustingAPlace() {
        val at = 7_200_000L
        assertEquals("Skips the two-hour wait from ${Texts.time(at)}, unless one of your computers cancels it.", Texts.placeSettles(at))
        assertEquals("Home skips the two-hour wait from ${Texts.time(at)}, unless one of your computers cancels it.", Texts.delayedAt(Texts.PLACE, "Home", at))
        assertEquals("Trusting Home", Texts.delayScreenTitle(Texts.PLACE, "Home"))
    }

    /** 11.4: a cancelled or failed restore prompt says so; the screen stays and Yes asks again. */
    @Test
    fun restoreLineAfterThePrompt() {
        assertNull(Texts.restoreLine(AuthResult.Success(null)))
        assertEquals("Couldn't confirm it's you, so nothing was restored. Try again.", Texts.restoreLine(AuthResult.Cancelled))
        assertEquals(Texts.RESTORE_NOT_CONFIRMED, Texts.restoreLine(AuthResult.Failed(BiometricErrorTimeout, "Timeout")))
        assertEquals(Texts.LOCKED_OUT, Texts.restoreLine(AuthResult.LockedOut))
    }

    private companion object {
        /** `BiometricPrompt.ERROR_TIMEOUT`. */
        const val BiometricErrorTimeout = 3
    }
}
