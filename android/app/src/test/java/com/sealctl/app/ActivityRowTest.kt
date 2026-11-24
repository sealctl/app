package com.sealctl.app

import com.sealctl.core.app.ActivityRow
import com.sealctl.core.app.ActivityTone
import com.sealctl.core.app.Machine
import com.sealctl.core.app.UsageEntry
import com.sealctl.core.app.activityRow
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Activity rows of SPEC.md 11.12, through the shared crate as the screen gets them. */
class ActivityRowTest {
    private val macMini = Machine(
        key = "A".repeat(43), boxKey = "", name = "dev@Devs-Mac-mini.local", os = "macOS 26.1", model = null, hint = null,
        pairedAt = 0u, nickname = null, lastSeen = null, lastStatus = null, tagShown = false, flagged = false,
        relay = "", updated = 0u, deleted = false,
    )

    private fun entry(key: String, outcome: String, kind: String? = null, agent: String? = null, repo: String? = null, command: String? = null, machine: String = macMini.key) =
        UsageEntry(time = 0u, machine = machine, key = key, agent = agent, repo = repo, command = command, outcome = outcome, kind = kind)

    @Test
    fun exampleRows() {
        // web-relay/web-relay-token · dev · scan · dev@Devs-Mac-mini.local · In session
        assertEquals(
            ActivityRow("web-relay-token", "In session", ActivityTone.NORMAL, listOf("web-relay", "sealctl scan", "Devs-Mac-mini")),
            activityRow(entry("web-relay/web-relay-token", "in_session", repo = "dev", command = "scan"), macMini),
        )
        assertEquals(
            ActivityRow("ubuntu-packages", "One tap", ActivityTone.NORMAL, listOf("agent-lib-1.4.0", "Devs-Mac-mini")),
            activityRow(entry("agent-lib-1.4.0/ubuntu-packages", "one_tap", kind = "secret"), macMini),
        )
        assertEquals(
            ActivityRow("Volume safe", "Allowed once", ActivityTone.NORMAL, listOf("Devs-Mac-mini")),
            activityRow(entry("safe", "once", kind = "volume"), macMini),
        )
        assertEquals(
            ActivityRow("Seal volume safe", "Confirmed", ActivityTone.NORMAL, listOf("Devs-Mac-mini")),
            activityRow(entry("seal", "confirmed", kind = "machine", command = "seal volume safe 5D1E7B2A-94C3-4F60-8A1B-3C2D4E5F6071"), macMini),
        )
        assertEquals(
            ActivityRow("Secret store a7c3…42", "Confirmed", ActivityTone.NORMAL, listOf("sealctl unseal", "unpaired (Zq7Lr2Xa)")),
            activityRow(
                entry("secrets a7c3e9f1-2b4d-4e6f-8a0c-1d3e5f7a9b42", "confirmed", command = "sealctl unseal", machine = "Zq7Lr2Xaq0r1s2t3u4v5w6x7y8z9A0B1C2D3E4F5G6H"),
                null,
            ),
        )
    }

    @Test
    fun outcomesAndNickname() {
        val denied = activityRow(entry("r2:acme-backups", "denied", kind = "backup"), macMini.copy(nickname = "Work laptop"))
        assertEquals("Backup r2:acme-backups", denied.subject)
        assertEquals(ActivityTone.DECLINED, denied.tone)
        assertEquals(listOf("Work laptop"), denied.details)
        assertEquals(ActivityTone.MUTED, activityRow(entry("github", "expired", kind = "ssh"), macMini).tone)
    }

    @Test
    fun oneLabelPerRow() {
        val row = ActivityRow("web-relay-token", "In session", ActivityTone.NORMAL, listOf("web-relay", "sealctl scan", "Devs-Mac-mini"))
        assertEquals("web-relay · sealctl scan · Devs-Mac-mini", Texts.activityDetails(row))
        assertEquals("09:18, web-relay-token, In session, web-relay, sealctl scan, Devs-Mac-mini", Texts.activityLabel("09:18", row))
        assertEquals("08:54, Volume safe, Allowed once", Texts.activityLabel("08:54", ActivityRow("Volume safe", "Allowed once", ActivityTone.NORMAL, emptyList())))
    }
}
