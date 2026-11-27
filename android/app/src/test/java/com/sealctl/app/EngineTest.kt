package com.sealctl.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.sealctl.core.app.Event
import com.sealctl.core.app.ReplyOption
import com.sealctl.core.app.TrustedPlace
import com.sealctl.designsystem.MachineState
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Engine.kt on the JVM (Robolectric) with the real shared core (host build), against a fake
 * relay and a fake machine of the test's own (SPEC.md 16): locks and notices during the
 * relay's maintenance, the corrected clock on a phone whose clock is behind, leaving a place,
 * the card after a lock, and the delayed records.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36], application = Application::class)
class EngineTest {
    private val context: Application = ApplicationProvider.getApplicationContext()
    private lateinit var relay: LocalRelay

    @Before
    fun setUp() {
        relay = LocalRelay.start()
    }

    @After
    fun tearDown() = relay.close()

    /** `503 maintenance` with `Retry-After: 1` on the next message, once. */
    private fun maintenanceOnce() {
        relay.control("/test/fail", """{"status":503,"error":"maintenance","retryAfter":1,"path":"/messages"}""")
    }

    /** The machine socket, listening for one message ([openedAt]: the session's open, for the lock check). */
    private fun listen(m: FakeMachine, vararg extra: String): FakeMachine.Run =
        m.start("listen", "--secs", "20", "--count", "1", *extra).also { it.find("LISTENING") }

    @Test
    fun aLockDuringMaintenanceIsSentAfterRetryAfter() = runBlocking {
        val (engine, m, machine) = pairedEngine(context, relay)
        maintenanceOnce()
        val listen = listen(m)
        // Not taken now: kept, not dropped.
        assertFalse(engine.lock(machine, "phone"))
        assertEquals(1, engine.outboxPending().size)
        assertEquals("Locking…", MachineView.of(machine, engine).row)
        // Sent again once the relay's Retry-After is over.
        val (_, heard) = listen.finish()
        assertTrue(heard, heard.contains("type=lock"))
        assertTrue(eventually { engine.outboxPending().isEmpty() })
    }

    @Test
    fun aNoticeDuringMaintenanceIsSentAfterRetryAfter() = runBlocking {
        val (engine, m, _) = pairedEngine(context, relay)
        maintenanceOnce()
        val listen = listen(m)
        engine.sendNotice("unseal_all", "pending", null, "d1", engine.clockNow() + 7_200_000)
        assertEquals(1, engine.outboxPending().size)
        val (_, heard) = listen.finish()
        assertTrue(heard, heard.contains("type=notice"))
        assertTrue(eventually { engine.outboxPending().isEmpty() })
    }

    /**
     * The phone's clock 3 minutes behind (the relay's and the machine's are right). The machine
     * ignores a lock made over a minute before its session opened: stamped on the phone's own
     * clock, a lock sent now would look made before the session; on the corrected clock it applies.
     */
    @Test
    fun aLockIsStampedOnTheCorrectedClock() = runBlocking {
        val (engine, m, machine) = pairedEngine(context, relay)
        val relayNow = Json.parseToJsonElement(relay.control("/test/clock", """{"offset":180}""")).jsonObject["time"]!!.jsonPrimitive.long * 1000
        assertTrue(engine.refreshClock())
        // The machine's session opened just now, by its own (right) clock.
        val openedAt = relayNow
        assertFalse("the phone's own clock would make the lock look old", System.currentTimeMillis() + 60_000 >= openedAt)
        val listen = listen(m, "--opened-at", openedAt.toString())
        assertTrue(engine.lock(machine, "phone", userTapped = true))
        val (_, heard) = listen.finish()
        assertTrue(heard, heard.contains("type=lock") && heard.contains("applies=true"))
    }

    /** Inside the trusted place "Desk" (p1), trusted three days ago. */
    private fun atDesk(engine: Engine) {
        engine.apply(Event.AddPlace(TrustedPlace("p1", "Desk", 0.0, 0.0, 150.0,
            (System.currentTimeMillis() - 3 * 86_400_000L).toULong(), 0u, false, false)))
        engine.currentPlace.value = "p1"
        assertEquals("p1", engine.here())
    }

    /** The machine's `open`, allowed for the session from the card. */
    private suspend fun allowOpen(engine: Engine, m: FakeMachine) {
        val r = m.start("request", "--kind", "open", "--subject", "secret:OPENAI_API_KEY", "--new-key", "secrets:store-1",
            "--cmd", "npm test", "--ttl", "60")
        var w: Waiting? = null
        val end = System.currentTimeMillis() + 30_000
        while (w == null && System.currentTimeMillis() < end) {
            engine.catchUp()
            w = engine.waiting.value.firstOrNull { !it.expired }
            if (w == null) Thread.sleep(100)
        }
        checkNotNull(w) { "no request: ${r.output}" }
        assertTrue(engine.answer(w.relay.id, ReplyOption.ALLOW_SESSION))
        val (code, out) = r.finish()
        assertEquals(out, 0, code)
    }

    /**
     * Leaving the place while the relay is in maintenance: the lock for the machine allowed there
     * is kept and sent after Retry-After, and its allowance is recorded as locked once it went.
     */
    @Test
    fun leavingThePlaceDuringMaintenanceLocksAfterRetryAfter() = runBlocking {
        val (engine, m, _) = pairedEngine(context, relay)
        atDesk(engine)
        allowOpen(engine, m)
        assertEquals("p1", engine.local.value.grants.single().placeId)
        maintenanceOnce()
        val listen = listen(m)
        engine.onPlaceTransition(listOf("p1"), entered = false)
        val (_, heard) = listen.finish()
        assertTrue(heard, heard.contains("type=lock"))
        assertTrue(eventually { engine.local.value.grants.single().locked })
        assertTrue(engine.outboxPending().isEmpty())
    }

    /**
     * After a lock the card says "Locking…": a status the machine made before the lock arrived,
     * still Open, does not show the session as open again; a status saying Locked does.
     */
    @Test
    fun theCardShowsLockingUntilAStatusAnswersTheLock() = runBlocking {
        val (engine, m, machine) = pairedEngine(context, relay)
        assertEquals(0, m.run("status", "--state", "open", "--left", "3000").first)
        engine.refreshStatus()
        assertEquals(MachineState.Open, MachineView.of(engine.machine(machine.key)!!, engine).state)
        assertTrue(engine.lock(machine, "phone", userTapped = true))
        assertEquals("Locking…", MachineView.of(engine.machine(machine.key)!!, engine).row)
        // Made 30 s ago, before the lock: the session still shows as locking.
        assertEquals(0, m.run("status", "--state", "open", "--left", "3000", "--made-ago", "30").first)
        engine.refreshStatus()
        assertEquals("Locking…", MachineView.of(engine.machine(machine.key)!!, engine).row)
        assertEquals(0, m.run("status", "--state", "locked").first)
        engine.refreshStatus()
        val v = MachineView.of(engine.machine(machine.key)!!, engine)
        assertEquals(MachineState.Locked, v.state)
        assertTrue(engine.lockMarks.value.isEmpty())
    }

    /**
     * An existing behaviour (SPEC.md 11.23): a delayed record another install started reaches this
     * phone from the relay's list, and a cancel made on the computer reaches it the same way.
     * While the relay is in maintenance the list is not fetched and nothing changes.
     */
    @Test
    fun refreshDelayedTakesRecordsAndCancelsFromTheRelay() = runBlocking {
        val (engine, m, machine) = pairedEngine(context, relay)
        // Another install of this phone starts a level 3 action.
        val id = com.sealctl.core.app.randomId()
        engine.relay.addDelayed(id, 7_200)
        assertTrue(engine.refreshDelayed())
        val d = engine.local.value.delayed.single { it.id == id }
        assertEquals("waiting", d.state)
        val (code, out) = m.run("delayed", "cancel", id)
        assertEquals(out, 0, code)
        relay.control("/test/fail", """{"status":503,"error":"maintenance","retryAfter":1,"path":"/delayed"}""")
        assertFalse(engine.refreshDelayed())
        assertEquals("waiting", engine.local.value.delayed.single { it.id == id }.state)
        assertTrue(eventually { engine.relay.waitMs() == 0L })
        assertTrue(engine.refreshDelayed())
        val cancelled = engine.local.value.delayed.single { it.id == id }
        assertEquals("cancelled", cancelled.state)
        assertEquals(machine.key, cancelled.cancelledBy)
    }
}
