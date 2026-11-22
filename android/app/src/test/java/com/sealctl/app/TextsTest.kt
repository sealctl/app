package com.sealctl.app

import com.sealctl.core.RequestKind
import com.sealctl.core.app.ReplyOption
import org.junit.Assert.assertEquals
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
    fun commandsAreCutInTheMiddle() {
        val long = "x".repeat(50) + "y".repeat(50)
        val c = Texts.cut(long)
        assertEquals(80, c.length)
        assertTrue(c.startsWith("xxx") && c.endsWith("yyy") && c.contains("…"))
        assertEquals("npm test", Texts.cut("npm test"))
    }

    @Test
    fun durationsAndErrors() {
        assertEquals("2 h 10 min", Texts.duration(7800))
        assertEquals("2 h", Texts.duration(7200))
        assertEquals("1 min", Texts.duration(5))
        assertEquals("This machine uses another relay (relay.example.org). This phone uses relay.sealctl.com.",
            Texts.otherRelay("https://relay.example.org", "relay.sealctl.com"))
        assertEquals("dev@mbp.example.com stopped waiting.", Texts.stoppedWaiting("dev@mbp.example.com"))
        assertEquals("Claude Code", Texts.agentName("claude"))
        assertEquals("aider", Texts.agentName("aider"))
        assertEquals("Ready: open sealctl to finish showing your words.", Texts.ready("words"))
    }
}
