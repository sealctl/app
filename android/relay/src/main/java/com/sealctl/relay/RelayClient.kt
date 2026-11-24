package com.sealctl.relay

import com.sealctl.core.PhoneKeys
import com.sealctl.core.relayHeaders
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/** A relay error body `{"error": code, ...}` with its HTTP status. */
open class RelayException(val status: Int, val code: String, val body: JsonObject = JsonObject(emptyMap())) :
    IOException("relay $status $code")

/** `401 clock_skew` after the retry (SPEC.md 11.20). */
class ClockSkewException(body: JsonObject) : RelayException(401, "clock_skew", body)

/** `429 rate_limited`: no calls until [until] except replies the user taps (SPEC.md 8.1). */
class RateLimitedException(val until: Long, val scope: String?, body: JsonObject) : RelayException(429, "rate_limited", body)

/** `409 conflict` on the state, with the stored revision. */
class ConflictException(val rev: Long, body: JsonObject) : RelayException(409, "conflict", body)

data class RelayRequest(
    val id: String,
    val machine: String,
    val sealed: String,
    val created: Long,
    val expires: Long,
    val near: Boolean,
)

data class RelayMachine(val machine: String, val name: String, val os: String?, val model: String?, val pairedAt: Long, val lastSeen: Long?)

data class RelayStatus(val machine: String, val sealed: String, val updated: Long)

/** [by] is who cancelled it ("phone" or a machine key), for a cancelled record. */
data class RelayDelayed(val id: String, val machine: String?, val created: Long, val releaseAt: Long, val expires: Long, val state: String, val by: String? = null)

data class RelayDevice(val device: String, val platform: String, val sandbox: Boolean, val updated: Long)

/**
 * The Relay API client (SPEC.md 8): every call signed by the phone key with the core's
 * `relay_headers`, a clock offset corrected from `401 clock_skew`, the rate-limit window, and
 * HTTP/2 over TLS with no cache.
 */
class RelayClient(
    val baseUrl: String,
    private val keys: () -> PhoneKeys?,
    private val http: OkHttpClient = defaultClient(),
    private val now: () -> Long = System::currentTimeMillis,
    /** The relay's time, Unix ms, from `/v1/health` or a `401 clock_skew` (SPEC.md 8.1). */
    private val onRelayTime: (Long) -> Unit = {},
    /** A signed call the relay accepted, with the `Sealctl-Time` it carried, in ms (SPEC.md 8.1). */
    private val onAccepted: (Long) -> Unit = {},
) {
    @Volatile var clockOffsetSecs: Long = 0
    @Volatile var rateLimitedUntil: Long = 0
        private set

    val host: String get() = baseUrl.removePrefix("https://").removePrefix("http://")

    private fun phoneKeys(): PhoneKeys = keys() ?: throw RelayException(0, "no_keys")

    fun phoneId(): String = phoneKeys().publicId()

    /** Milliseconds left in the rate-limit window (0 when calls may go out). */
    fun rateLimitedForMs(): Long = (rateLimitedUntil - now()).coerceAtLeast(0)

    /** A `429 rate_limited` answer (a call or the socket upgrade): no calls for `retryAfter` seconds (60 when absent). */
    fun noteRateLimited(retryAfterSecs: Long?): Long {
        rateLimitedUntil = now() + (retryAfterSecs ?: 60) * 1000
        return rateLimitedUntil
    }

    private fun unixTime(): Long = now() / 1000 + clockOffsetSecs

    /** One signed call. Throws [RelayException] on an error answer and [IOException] offline. */
    suspend fun call(method: String, path: String, body: JsonObject? = null, userTapped: Boolean = false): JsonObject =
        withContext(Dispatchers.IO) {
            if (!userTapped && now() < rateLimitedUntil) {
                throw RateLimitedException(rateLimitedUntil, null, JsonObject(emptyMap()))
            }
            val first = execute(method, path, body)
            val result = if (first.first == 401 && first.second.code() == "clock_skew") {
                first.second["time"]?.jsonPrimitive?.longOrNull?.let {
                    clockOffsetSecs = it - now() / 1000
                    onRelayTime(it * 1000)
                }
                val again = execute(method, path, body)
                if (again.first == 401 && again.second.code() == "clock_skew") throw ClockSkewException(again.second)
                again
            } else first
            val (status, json, signedAt) = result
            if (status in 200..299) {
                onAccepted(signedAt * 1000)
                return@withContext json
            }
            when {
                // Only `rate_limited` (or a 429 without a relay body) opens the window; a cap such
                // as `too_many_delayed` is an ordinary error with its own code.
                status == 429 && (json.code() == "rate_limited" || json.code().startsWith("http_")) -> {
                    val until = noteRateLimited(json["retryAfter"]?.jsonPrimitive?.longOrNull)
                    throw RateLimitedException(until, json["scope"]?.jsonPrimitive?.contentOrNull(), json)
                }
                status == 409 && json.code() == "conflict" ->
                    throw ConflictException(json["rev"]?.jsonPrimitive?.longOrNull ?: 0, json)
                else -> throw RelayException(status, json.code(), json)
            }
        }

    /** One try: the status, the body and the signed time (Unix seconds). */
    private fun execute(method: String, path: String, body: JsonObject?): Triple<Int, JsonObject, Long> {
        val bytes = body?.toString()?.toByteArray() ?: ByteArray(0)
        val t = unixTime()
        val h = relayHeaders(phoneKeys(), method, path, t.toULong(), bytes)
        val rb = if (body != null) bytes.toRequestBody(JSON) else if (method == "GET" || method == "DELETE") null else ByteArray(0).toRequestBody(JSON)
        val req = Request.Builder()
            .url(baseUrl.trimEnd('/') + path)
            .method(method, rb)
            .header("Sealctl-Key", h.key)
            .header("Sealctl-Time", h.time)
            .header("Sealctl-Signature", h.signature)
            .build()
        http.newCall(req).execute().use { res ->
            val text = res.body.string()
            val json = runCatching { Json.parseToJsonElement(text).jsonObject }.getOrElse {
                buildJsonObject { put("error", if (res.isSuccessful) "" else "http_${res.code}") }
            }
            return Triple(res.code, json, t)
        }
    }

    private fun phone() = "/v1/phones/${phoneId()}"

    // ---------- typed calls (SPEC.md 8.2) ----------

    suspend fun health(): JsonObject = withContext(Dispatchers.IO) {
        http.newCall(Request.Builder().url(baseUrl.trimEnd('/') + "/v1/health").build()).execute().use {
            Json.parseToJsonElement(it.body.string()).jsonObject
        }
    }

    /**
     * The relay's time from `/v1/health` (Unix ms), also handed to `onRelayTime`; null when the
     * relay can't be reached or gives none (SPEC.md 8.1). Unsigned.
     */
    suspend fun relayTime(): Long? = runCatching { health()["time"]?.jsonPrimitive?.longOrNull }
        .getOrNull()?.takeIf { it > 0 }?.let { it * 1000 }?.also(onRelayTime)

    suspend fun addMachine(machine: String, name: String, os: String, model: String?, proof: String): JsonObject =
        call("POST", "${phone()}/machines", buildJsonObject {
            put("machine", machine); put("name", name); put("os", os)
            if (model != null) put("model", model)
            put("proof", proof)
        }, userTapped = true)

    suspend fun machines(): List<RelayMachine> =
        call("GET", "${phone()}/machines")["machines"]?.jsonArray.orEmpty().map {
            val o = it.jsonObject
            RelayMachine(
                o.str("machine"), o.str("name"), o.strOrNull("os"), o.strOrNull("model"),
                o.long("pairedAt"), o["lastSeen"]?.jsonPrimitive?.longOrNull,
            )
        }

    suspend fun removeMachine(machine: String) {
        try {
            call("DELETE", "${phone()}/machines/$machine", userTapped = true)
        } catch (e: RelayException) {
            if (e.code != "not_paired") throw e
        }
    }

    suspend fun requests(): List<RelayRequest> =
        call("GET", "${phone()}/requests")["requests"]?.jsonArray.orEmpty().map { parseRequest(it.jsonObject) }

    /** Posts a reply; `delay` for a level 3 approval away from a trusted place. */
    suspend fun reply(id: String, sealed: String, delay: Int? = null, userTapped: Boolean = true): JsonObject =
        call("POST", "${phone()}/requests/$id/reply", buildJsonObject {
            put("sealed", sealed)
            if (delay != null) put("delay", delay)
        }, userTapped)

    /** `(rev, blob)`; blob is null before the first upload. */
    suspend fun getState(): Pair<Long, String?> {
        val o = call("GET", "${phone()}/state")
        return o.long("rev") to o.strOrNull("blob")
    }

    suspend fun putState(rev: Long, blob: String?): Long =
        call("PUT", "${phone()}/state", buildJsonObject {
            put("rev", rev)
            if (blob == null) put("blob", JsonNull) else put("blob", blob)
        }).long("rev")

    suspend fun putPush(device: String, token: String): Int =
        call("PUT", "${phone()}/push/$device", buildJsonObject { put("platform", "fcm"); put("token", token) }).let { it["devices"] }
            ?.jsonPrimitive?.longOrNull?.toInt() ?: 0

    suspend fun listPush(): List<RelayDevice> =
        call("GET", "${phone()}/push")["devices"]?.jsonArray.orEmpty().map {
            val o = it.jsonObject
            RelayDevice(o.str("device"), o.str("platform"), o["sandbox"]?.jsonPrimitive?.booleanOrNull ?: false, o.long("updated"))
        }

    suspend fun deletePush(device: String) {
        try {
            call("DELETE", "${phone()}/push/$device", userTapped = true)
        } catch (e: RelayException) {
            if (e.code != "unknown_device") throw e
        }
    }

    suspend fun testPush(device: String): JsonObject = call("POST", "${phone()}/push/$device/test", userTapped = true)

    suspend fun deletePhone(): JsonObject = call("DELETE", phone(), userTapped = true)

    suspend fun status(): List<RelayStatus> =
        call("GET", "${phone()}/status")["status"]?.jsonArray.orEmpty().map {
            val o = it.jsonObject
            RelayStatus(o.str("machine"), o.str("sealed"), o.long("updated"))
        }

    suspend fun postMessage(machine: String, sealed: String): Boolean =
        call("POST", "${phone()}/machines/$machine/messages", buildJsonObject { put("sealed", sealed) }, userTapped = true).let { it["delivered"] }
            ?.jsonPrimitive?.booleanOrNull ?: false

    suspend fun addDelayed(id: String, delay: Int): RelayDelayed {
        val o = call("POST", "${phone()}/delayed", buildJsonObject { put("id", id); put("delay", delay) }, userTapped = true)
        return RelayDelayed(o.str("id"), null, now(), o.long("releaseAt"), o.long("expires"), "waiting")
    }

    suspend fun listDelayed(): List<RelayDelayed> =
        call("GET", "${phone()}/delayed")["delayed"]?.jsonArray.orEmpty().map {
            val o = it.jsonObject
            RelayDelayed(o.str("id"), o.strOrNull("machine"), o.long("created"), o.long("releaseAt"), o.long("expires"), o.str("state"), o.strOrNull("by"))
        }

    /** One record; `by` says who cancelled. Null when the relay has no such record. */
    suspend fun cancelledBy(id: String): String? = try {
        call("GET", "${phone()}/delayed/$id").strOrNull("by")
    } catch (e: RelayException) {
        null
    }

    /** [userTapped]: the person tapped Cancel; false for a cancel sent again by the app. */
    suspend fun cancelDelayed(id: String, userTapped: Boolean = true) {
        call("POST", "${phone()}/delayed/$id/cancel", userTapped = userTapped)
    }

    suspend fun finishDelayed(id: String): JsonObject = call("POST", "${phone()}/delayed/$id/finish", userTapped = true)

    /** Opens the phone socket (foreground only, SPEC.md 8.3). */
    fun openSocket(listener: WebSocketListener): WebSocket {
        val path = "${phone()}/socket"
        val h = relayHeaders(phoneKeys(), "GET", path, unixTime().toULong(), ByteArray(0))
        val url = baseUrl.trimEnd('/').replaceFirst("http", "ws") + path
        val req = Request.Builder().url(url)
            .header("Sealctl-Key", h.key).header("Sealctl-Time", h.time).header("Sealctl-Signature", h.signature)
            .build()
        return http.newWebSocket(req, listener)
    }

    companion object {
        private val JSON = "application/json".toMediaType()

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .cache(null)
            .callTimeout(10, TimeUnit.SECONDS)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .pingInterval(0, TimeUnit.SECONDS)
            .build()

        fun parseRequest(o: JsonObject) = RelayRequest(
            o.str("id"), o.str("machine"), o.str("sealed"), o.long("created"), o.long("expires"),
            o["near"]?.jsonPrimitive?.booleanOrNull ?: false,
        )
    }
}

internal fun JsonObject.code(): String = this["error"]?.jsonPrimitive?.contentOrNull() ?: ""
fun JsonObject.str(k: String): String = this[k]?.jsonPrimitive?.contentOrNull() ?: ""
fun JsonObject.strOrNull(k: String): String? = this[k]?.jsonPrimitive?.contentOrNull()
fun JsonObject.long(k: String): Long = this[k]?.jsonPrimitive?.longOrNull ?: 0
fun JsonPrimitive.contentOrNull(): String? = if (this is JsonNull) null else content
private fun JsonArray?.orEmpty(): List<JsonElement> = this ?: emptyList()
