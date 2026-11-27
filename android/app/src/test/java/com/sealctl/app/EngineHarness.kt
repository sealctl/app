package com.sealctl.app

import android.content.Context
import com.sealctl.core.PhoneKeys
import com.sealctl.core.Root
import com.sealctl.core.Words
import com.sealctl.core.app.Machine
import com.sealctl.core.app.Store
import com.sealctl.places.LocationPermissions
import com.sealctl.places.Places
import com.sealctl.vault.Vault
import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** The root and the phone keys in memory: the JVM has no Android Keystore. Made fresh per test. */
class MemoryVault(context: Context) : Vault(context) {
    private val words = Words.generate()
    private val root = Root.fromWords(words)
    private val keys = PhoneKeys.fromRoot(root)

    override fun isDeviceLocked(): Boolean = false
    override fun readRoot(): Root = Root.fromBytes(root.toBytes())
    override fun readPhoneKeys(): PhoneKeys = keys
    override fun erase() {}
}

/** Location allowed all the time, so a trusted place counts. */
object AlwaysAllowed : LocationPermissions {
    override fun hasForeground() = true
    override fun hasBackground() = true
}

private val http = OkHttpClient.Builder().callTimeout(5, TimeUnit.SECONDS).build()

/**
 * A `tools/fake-relay` of one test's own, on a free loopback port: never a shared or remote
 * relay. Its `/test/` routes set its clock and make calls fail.
 */
class LocalRelay private constructor(val url: String, private val process: Process) : AutoCloseable {
    /** A `/test/` control call; its body. */
    fun control(path: String, body: String): String =
        http.newCall(Request.Builder().url(url + path).post(body.toRequestBody("application/json".toMediaType())).build())
            .execute().use { it.body.string() }

    override fun close() {
        process.destroy()
        process.waitFor(5, TimeUnit.SECONDS)
    }

    companion object {
        /** Started and answering `/v1/health` within 5 seconds. */
        fun start(): LocalRelay {
            val bin = System.getProperty("sealctl.fakeRelay") ?: error("no fake relay")
            repeat(5) {
                val port = (20_000..40_000).random()
                val p = ProcessBuilder(bin, "--bind", "127.0.0.1:$port")
                    .redirectErrorStream(true).redirectOutput(File("/dev/null")).start()
                val r = LocalRelay("http://127.0.0.1:$port", p)
                val end = System.currentTimeMillis() + 5_000
                while (System.currentTimeMillis() < end && p.isAlive) {
                    val up = runCatching {
                        http.newCall(Request.Builder().url(r.url + "/v1/health").build()).execute().use { it.code == 200 }
                    }.getOrDefault(false)
                    if (up) return r
                    Thread.sleep(50)
                }
                r.close()
            }
            error("the fake relay did not start")
        }
    }
}

/** A `tools/fake-machine` with a home of its own. */
class FakeMachine(private val relay: String) {
    val home: File = Files.createTempDirectory("fake-machine").toFile()

    /** A started process: its output so far, and its end. */
    class Run(val process: Process) {
        private val out = StringBuffer()
        private val reader = Thread {
            process.inputStream.bufferedReader().forEachLine { synchronized(out) { out.appendLine(it); (out as Object).notifyAll() } }
        }.apply { isDaemon = true; start() }

        val output: String get() = synchronized(out) { out.toString() }

        /** Waits until the output has a line containing [text], within [timeoutMs]. */
        fun find(text: String, timeoutMs: Long = 30_000): String {
            val end = System.currentTimeMillis() + timeoutMs
            synchronized(out) {
                while (!out.contains(text)) {
                    val left = end - System.currentTimeMillis()
                    if (left <= 0 || (!process.isAlive && !reader.isAlive)) error("no \"$text\" in: $out")
                    (out as Object).wait(minOf(left, 200))
                }
                return out.lines().first { it.contains(text) }
            }
        }

        /** The exit status and the whole output. */
        fun finish(timeoutMs: Long = 60_000): Pair<Int, String> {
            if (!process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) process.destroy()
            reader.join(5_000)
            return process.exitValue() to output
        }
    }

    fun start(vararg args: String): Run {
        val bin = System.getProperty("sealctl.fakeMachine") ?: error("no fake machine")
        val pb = ProcessBuilder(listOf(bin) + args).redirectErrorStream(true)
        pb.environment()["FAKE_MACHINE_HOME"] = home.absolutePath
        pb.environment()["SEALCTL_RELAY"] = relay
        return Run(pb.start())
    }

    fun run(vararg args: String): Pair<Int, String> = start(*args).finish()
}

/**
 * An engine on a fresh database, a memory vault and [relay], paired with a fake machine. Its
 * outbox job is the in-process timer only (no WorkManager in these tests).
 */
suspend fun pairedEngine(context: Context, relay: LocalRelay): Triple<Engine, FakeMachine, Machine> {
    val dir = Files.createTempDirectory("engine").toFile()
    val engine = Engine(context, MemoryVault(context), Store.open(File(dir, "sealctl.db").absolutePath), relay.url, Places(context))
    engine.scheduleOutboxWork = {}
    engine.permissions = AlwaysAllowed
    val m = FakeMachine(relay.url)
    val link = File(m.home, "link")
    val (code, out) = m.run("pair", "--name", "dev@mbp.example.com", "--no-wait", "--link-file", link.absolutePath)
    check(code == 0) { out }
    val offer = engine.parseOffer(link.readText()).getOrThrow()
    val machine = engine.pair(offer, null).getOrThrow()
    val (waited, waitOut) = m.run("pair-wait", "--wait-secs", "20")
    check(waited == 0) { waitOut }
    return Triple(engine, m, machine)
}

/** Waits until [done] holds, within [timeoutMs]; whether it did. */
fun eventually(timeoutMs: Long = 10_000, done: () -> Boolean): Boolean {
    val end = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < end) {
        if (done()) return true
        Thread.sleep(50)
    }
    return done()
}
