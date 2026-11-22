package com.sealctl.relay

import com.sealctl.core.PhoneKeys
import com.sealctl.core.Root
import com.sealctl.core.Words
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
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
}
