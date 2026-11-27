package com.sealctl.relay

import com.sealctl.core.PhoneKeys
import com.sealctl.core.Root
import com.sealctl.core.Words
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.IOException
import java.util.concurrent.TimeUnit
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** The relay client against a mock server, signing with the real core (host build). */
class RelayClientTest {
    private val server = MockWebServer()
    private lateinit var keys: PhoneKeys
    private lateinit var client: RelayClient
    private var clock = 1_795_251_600_000L

    @Before
    fun setUp() {
        server.start()
        val words = Words.parse(
            "bulk search gospel radio edit key flip afford jaguar rapid mechanic power family category snap boss iron web various grow smoke next example lounge".split(" "),
        )
        keys = PhoneKeys.fromRoot(Root.fromWords(words))
        client = RelayClient(server.url("/").toString().trimEnd('/'), { keys }, now = { clock })
    }

    @After
    fun tearDown() = server.shutdown()

    private fun json(code: Int, body: String) = MockResponse().setResponseCode(code).setBody(body).addHeader("content-type", "application/json")

    @Test
    fun signsEveryCallWithThePhoneKey() = runTest {
        server.enqueue(json(200, """{"requests":[{"id":"abc","machine":"m","sealed":"s","created":1,"expires":2,"near":true}]}"""))
        val list = client.requests()
        assertEquals(1, list.size)
        assertTrue(list[0].near)
        val r = server.takeRequest()
        assertEquals("/v1/phones/6jOhto9rTH8m9Up6iegjDiB66iuP5cbQcp5Jsw0S-Vk/requests", r.path)
        assertEquals("6jOhto9rTH8m9Up6iegjDiB66iuP5cbQcp5Jsw0S-Vk", r.getHeader("Sealctl-Key"))
        assertEquals("1795251600", r.getHeader("Sealctl-Time"))
        assertEquals(86, r.getHeader("Sealctl-Signature")!!.length)
    }

    @Test
    fun clockSkewCorrectsTheOffsetAndRetriesOnce() = runTest {
        server.enqueue(json(401, """{"error":"clock_skew","time":1795252000}"""))
        server.enqueue(json(200, """{"machines":[]}"""))
        client.machines()
        server.takeRequest()
        assertEquals("1795252000", server.takeRequest().getHeader("Sealctl-Time"))
        assertEquals(400L, client.clockOffsetSecs)

        server.enqueue(json(401, """{"error":"clock_skew","time":1}"""))
        server.enqueue(json(401, """{"error":"clock_skew","time":1}"""))
        try {
            client.machines(); fail()
        } catch (e: ClockSkewException) {
        }
    }

    /** SPEC.md 8.1: the relay's time and the accepted signed times go to the corrected clock. */
    @Test
    fun relayTimesReachTheClock() = runTest {
        val times = mutableListOf<Long>()
        val accepted = mutableListOf<Long>()
        val c = RelayClient(server.url("/").toString().trimEnd('/'), { keys }, now = { clock },
            onRelayTime = { times += it }, onAccepted = { accepted += it })
        server.enqueue(json(200, """{"ok":true,"env":"fake","version":"x","time":1795252000}"""))
        assertEquals(1_795_252_000_000L, c.relayTime())
        assertEquals("/v1/health", server.takeRequest().path)
        server.enqueue(json(401, """{"error":"clock_skew","time":1795252400}"""))
        server.enqueue(json(200, """{"machines":[]}"""))
        c.machines()
        assertEquals(listOf(1_795_252_000_000L, 1_795_252_400_000L), times)
        // The retry was signed with the corrected offset and accepted.
        assertEquals(listOf(1_795_252_400_000L), accepted)
        // No time in the answer, or no answer: nothing learned.
        server.enqueue(json(200, """{"ok":true}"""))
        assertNull(c.relayTime())
        assertEquals(2, times.size)
    }

    @Test
    fun rateLimitStopsCallsButNotTappedReplies() = runTest {
        server.enqueue(json(429, """{"error":"rate_limited","retryAfter":3600,"scope":"phone"}"""))
        try {
            client.requests(); fail()
        } catch (e: RateLimitedException) {
            assertEquals("phone", e.scope)
            assertEquals(clock + 3_600_000, e.until)
        }
        try {
            client.requests(); fail()
        } catch (e: RateLimitedException) {
        }
        assertEquals(1, server.requestCount)
        server.enqueue(json(200, """{"delivered":true}"""))
        client.reply("id", "sealed", userTapped = true)
        server.takeRequest(); val r = server.takeRequest()
        assertEquals("""{"sealed":"sealed"}""", r.body.readUtf8())
    }

    /** SPEC.md 8.1: a message the app sends by itself (a lock on leaving a place, a notice) waits out the window; one the person taps goes. */
    @Test
    fun messagesTheAppSendsByItselfWaitOutTheWindow() = runTest {
        server.enqueue(json(429, """{"error":"rate_limited","retryAfter":600,"scope":"phone"}"""))
        try {
            client.machines(); fail()
        } catch (e: RateLimitedException) {
        }
        try {
            client.postMessage("m", "sealed"); fail()
        } catch (e: RateLimitedException) {
            assertEquals(clock + 600_000, e.until)
        }
        assertEquals(1, server.requestCount)
        server.enqueue(json(200, """{"delivered":true}"""))
        assertTrue(client.postMessage("m", "sealed", userTapped = true))
        assertEquals(2, server.requestCount)
    }

    /**
     * SPEC.md 8.1: `503 maintenance` with `Retry-After` (relay SPEC 3.18): what the app sends by
     * itself waits until then without calling; a tapped call still goes; after it, calls go again.
     */
    @Test
    fun maintenanceRetryAfterHoldsBackWhatTheAppSendsByItself() = runTest {
        server.enqueue(json(503, """{"error":"maintenance","retryAfter":120}""").addHeader("Retry-After", "120"))
        try {
            client.postMessage("m", "sealed"); fail()
        } catch (e: UnavailableException) {
            assertEquals(503, e.status)
            assertEquals("maintenance", e.code)
            assertEquals(clock + 120_000, e.until)
        }
        assertEquals(120_000L, client.waitMs())
        assertEquals(0L, client.rateLimitedForMs())
        try {
            client.machines(); fail()
        } catch (e: UnavailableException) {
            assertEquals(clock + 120_000, e.until)
        }
        assertEquals(1, server.requestCount)
        server.enqueue(json(200, """{"delivered":true}"""))
        assertTrue(client.postMessage("m", "sealed", userTapped = true))
        assertEquals(2, server.requestCount)
        clock += 120_000
        assertEquals(0L, client.waitMs())
        server.enqueue(json(200, """{"delivered":true}"""))
        assertTrue(client.postMessage("m", "sealed"))
        assertEquals(3, server.requestCount)
    }

    /** The body's `retryAfter` counts when the header is missing; at most an hour; a 5xx without either is an ordinary error. */
    @Test
    fun retryAfterFromTheBodyCappedAndOnlyWhenGiven() = runTest {
        server.enqueue(json(503, """{"error":"maintenance","retryAfter":86400}"""))
        try {
            client.requests(); fail()
        } catch (e: UnavailableException) {
            assertEquals(clock + 3_600_000, e.until)
        }
        clock += 3_600_000
        server.enqueue(json(500, """{"error":"internal"}"""))
        try {
            client.requests(); fail()
        } catch (e: UnavailableException) {
            fail("no Retry-After: not a wait")
        } catch (e: RelayException) {
            assertEquals(500, e.status)
        }
        assertEquals(0L, client.waitMs())
        assertNull(RelayClient.retryAfterSecs("Wed, 21 Oct 2026 07:28:00 GMT"))
        assertEquals(7L, RelayClient.retryAfterSecs(" 7 "))
    }

    /** A socket upgrade refused with `503` and `Retry-After` holds back the next upgrade too. */
    @Test
    fun aRefusedSocketUpgradeWaitsOutRetryAfter() {
        server.enqueue(json(503, """{"error":"maintenance","retryAfter":90}""").addHeader("Retry-After", "90"))
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        val socket = PhoneSocket(client, scope, onMessage = {}, onConnected = {})
        socket.start()
        val deadline = System.currentTimeMillis() + 5_000
        while (client.waitMs() == 0L && System.currentTimeMillis() < deadline) Thread.sleep(50)
        // past the first reconnect's backoff (1 s ± 20 %)
        Thread.sleep(1_500)
        socket.stop()
        assertEquals(90_000L, client.waitMs())
        assertEquals("no second upgrade before Retry-After", 1, server.requestCount)
    }

    /** SPEC.md 8.1: the window outlives the process: a client made later starts inside it. */
    @Test
    fun theWindowIsKeptForTheNextClient() = runTest {
        val kept = mutableListOf<Long>()
        val first = RelayClient(server.url("/").toString().trimEnd('/'), { keys }, now = { clock }, onRateLimited = { kept += it })
        server.enqueue(json(429, """{"error":"rate_limited","retryAfter":120}"""))
        try {
            first.requests(); fail()
        } catch (e: RateLimitedException) {
        }
        assertEquals(listOf(clock + 120_000), kept)
        val next = RelayClient(server.url("/").toString().trimEnd('/'), { keys }, now = { clock + 1_000 }, rateLimitedUntil = kept.last())
        assertEquals(119_000L, next.rateLimitedForMs())
        try {
            next.requests(); fail()
        } catch (e: RateLimitedException) {
        }
        assertEquals(1, server.requestCount)
    }

    @Test
    fun theSocketWaitsOutTheRateLimitWindow() {
        // Staging incident 2026-11-22: a client that kept calling after 429 sent ~86,000 calls.
        server.enqueue(json(429, """{"error":"rate_limited","retryAfter":3600,"scope":"key"}"""))
        try {
            kotlinx.coroutines.runBlocking { client.machines() }
            fail("expected 429")
        } catch (e: RateLimitedException) {
            assertEquals("key", e.scope)
        }
        assertEquals(3_600_000L, client.rateLimitedForMs())
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        val socket = PhoneSocket(client, scope, onMessage = {}, onConnected = {})
        socket.start()
        Thread.sleep(1_000)
        socket.stop()
        assertEquals("no upgrade during the window", 1, server.requestCount)
    }

    @Test
    fun aRefusedSocketUpgradeOpensTheRateLimitWindow() {
        server.enqueue(json(429, """{"error":"rate_limited","retryAfter":1800,"scope":"phone"}""").addHeader("Retry-After", "1800"))
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        val socket = PhoneSocket(client, scope, onMessage = {}, onConnected = {})
        socket.start()
        val deadline = System.currentTimeMillis() + 5_000
        while (client.rateLimitedForMs() == 0L && System.currentTimeMillis() < deadline) Thread.sleep(50)
        Thread.sleep(1_500)
        socket.stop()
        assertEquals(1_800_000L, client.rateLimitedForMs())
        assertEquals("no second upgrade during the window", 1, server.requestCount)
    }

    @Test
    fun anOther429IsAnErrorWithItsCodeNotAWindow() = runTest {
        server.enqueue(json(429, """{"error":"too_many_delayed"}"""))
        try {
            client.reply("id", "sealed", delay = 7200); fail()
        } catch (e: RateLimitedException) {
            fail("too_many_delayed is not a rate limit")
        } catch (e: RelayException) {
            assertEquals(429, e.status)
            assertEquals("too_many_delayed", e.code)
        }
        assertEquals(0L, client.rateLimitedForMs())
        server.enqueue(json(200, """{"requests":[]}"""))
        client.requests()
        assertEquals(2, server.requestCount)
    }

    @Test
    fun stateConflictCarriesTheRevision() = runTest {
        server.enqueue(json(409, """{"error":"conflict","rev":7}"""))
        try {
            client.putState(3, "blob"); fail()
        } catch (e: ConflictException) {
            assertEquals(7L, e.rev)
        }
        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("3", body["rev"]!!.jsonPrimitive.content)
    }

    @Test
    fun goneAndUnknownDevice() = runTest {
        server.enqueue(json(404, """{"error":"gone"}"""))
        try {
            client.reply("x", "s"); fail()
        } catch (e: RelayException) {
            assertEquals("gone", e.code)
        }
        server.enqueue(json(404, """{"error":"unknown_device"}"""))
        client.deletePush("dev") // treated as done
        server.enqueue(json(404, """{"error":"not_paired"}"""))
        client.removeMachine("m") // treated as done
    }

    @Test
    fun delayedRecordsSayWhoCancelled() = runTest {
        // The relay puts `by` at the top level of a cancelled record (list and single record).
        server.enqueue(json(200, """{"delayed":[
            {"id":"d1","machine":"m","created":1,"releaseAt":2,"expires":3,"state":"cancelled","by":"mkey"},
            {"id":"d2","machine":null,"created":1,"releaseAt":2,"expires":3,"state":"waiting"}]}"""))
        val list = client.listDelayed()
        assertEquals("mkey", list[0].by)
        assertNull(list[1].by)
        server.enqueue(json(200, """{"id":"d1","machine":"m","created":1,"releaseAt":2,"expires":3,"state":"cancelled","by":"phone"}"""))
        assertEquals("phone", client.cancelledBy("d1"))
    }

    /**
     * A relay that takes a call and never answers holds no start of an action on the phone
     * forever (SPEC.md 11.23): every call ends at the client's timeout, 10 s by default.
     */
    @Test
    fun aCallTheRelayNeverAnswersEndsAtTheTimeout() = runTest {
        assertEquals(10_000, RelayClient.defaultClient().callTimeoutMillis)
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val c = RelayClient(server.url("/").toString().trimEnd('/'), { keys },
            http = OkHttpClient.Builder().callTimeout(300, TimeUnit.MILLISECONDS).build(), now = { clock })
        try {
            c.addDelayed("d1", 7200); fail()
        } catch (e: IOException) {
        }
    }
}
