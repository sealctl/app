package com.sealctl.relay

import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * The phone socket while the app is in the foreground (SPEC.md 8.3): `ping` every 30 s, a
 * dead socket after 10 s without `pong`, reconnect with backoff 1, 2, 4, 8, 16 then 30 s
 * (±20% jitter, reset by a `pong`), at most 60 upgrades an hour, none during a `429` window.
 */
class PhoneSocket(
    private val client: RelayClient,
    private val scope: CoroutineScope,
    private val onMessage: (JsonObject) -> Unit,
    private val onConnected: () -> Unit,
    private val onState: (Boolean) -> Unit = {},
) {
    private var socket: WebSocket? = null
    private var loop: Job? = null
    @Volatile private var lastPong = 0L
    @Volatile private var open = false
    private val upgrades = ArrayDeque<Long>()

    fun start() {
        if (loop?.isActive == true) return
        loop = scope.launch {
            var attempt = 0
            while (isActive) {
                val now = System.currentTimeMillis()
                while (upgrades.isNotEmpty() && now - upgrades.first() > 3_600_000) upgrades.removeFirst()
                if (upgrades.size >= 60) {
                    delay(60_000); continue
                }
                // The relay said to slow down: no upgrade (and no catch-up after it) until then.
                val limited = client.rateLimitedForMs()
                if (limited > 0) {
                    delay(limited); continue
                }
                upgrades.addLast(now)
                val closed = kotlinx.coroutines.CompletableDeferred<Unit>()
                runCatching {
                    socket = client.openSocket(object : WebSocketListener() {
                        override fun onOpen(webSocket: WebSocket, response: Response) {
                            // `attempt` resets on the first pong, not here: a relay that accepts and
                            // then closes at once must not get a reconnect (and a catch-up) every second.
                            open = true; lastPong = System.currentTimeMillis()
                            onState(true); onConnected()
                        }

                        override fun onMessage(webSocket: WebSocket, text: String) {
                            if (text == "pong") { lastPong = System.currentTimeMillis(); attempt = 0; return }
                            runCatching { Json.parseToJsonElement(text).jsonObject }.getOrNull()?.let(onMessage)
                        }

                        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { finish() }
                        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
                        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                            // The upgrade itself was refused with 429: the same window as a call's.
                            if (response?.code == 429) client.noteRateLimited(response.header("Retry-After")?.trim()?.toLongOrNull())
                            finish()
                        }

                        private fun finish() {
                            open = false; onState(false); closed.complete(Unit)
                        }
                    })
                }.onFailure { closed.complete(Unit) }
                // Keep-alive until the socket closes.
                val pinger = launch {
                    while (isActive) {
                        delay(30_000)
                        if (!open) continue
                        val sent = System.currentTimeMillis()
                        socket?.send("ping")
                        delay(10_000)
                        if (lastPong < sent) { socket?.cancel(); break }
                    }
                }
                closed.await()
                pinger.cancel()
                if (!isActive) break
                val base = listOf(1, 2, 4, 8, 16, 30)[attempt.coerceAtMost(5)] * 1000L
                attempt++
                delay((base * (0.8 + Random.nextDouble() * 0.4)).toLong())
            }
        }
    }

    fun stop() {
        loop?.cancel(); loop = null
        socket?.close(1000, null); socket = null
        open = false
    }

    val isOpen: Boolean get() = open
}
