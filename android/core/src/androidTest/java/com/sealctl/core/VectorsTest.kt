package com.sealctl.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sealctl.core.app.cardChoices
import com.sealctl.core.app.decodeState
import com.sealctl.core.app.encodeState
import com.sealctl.core.app.State
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

/** The protocol's test vectors through the generated Kotlin bindings (SPEC.md 16.1). */
@RunWith(AndroidJUnit4::class)
class VectorsTest {
    private fun asset(name: String): JSONObject {
        val ctx = InstrumentationRegistry.getInstrumentation().context
        return JSONObject(ctx.assets.open(name).bufferedReader().readText())
    }

    private val v = asset("vectors-v1.json")

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test
    fun wordsRootFingerprintPhoneKeys() {
        for (set in listOf("A", "B")) {
            val words = Words.parse(v.getString("$set.mnemonic").split(" "))
            val root = Root.fromWords(words)
            assertEquals(v.getString("$set.root"), hex(root.toBytes()))
            assertEquals(v.getString("$set.fingerprint"), fingerprint(root))
            val keys = PhoneKeys.fromRoot(root)
            assertEquals(v.getString("$set.phone_identity_public_b64u"), keys.publicId())
            assertEquals(v.getString("$set.phone_box_public_b64u"), keys.boxPublicKey())
            val again = PhoneKeys.fromBytes(keys.toBytes())
            assertEquals(keys.publicId(), again.publicId())
            assertEquals(words.list(), Words.fromEntropy(words.entropy()).list())
        }
        assertEquals(v.getString("B.entropy"), hex(Words.parse(v.getString("B.mnemonic").split(" ")).entropy()))
    }

    @Test
    fun typedWordsByFourLetters() {
        val list = v.getString("B.mnemonic").split(" ").map { it.take(4) }
        val words = Words.parse(list)
        assertEquals(v.getString("B.fingerprint"), fingerprint(Root.fromWords(words)))
        try {
            Words.parse(list.toMutableList().also { it[3] = "zzzz" })
            fail()
        } catch (e: CoreException.UnknownWord) {
            assertEquals(3u, e.index)
        }
        try {
            Words.parse(list.toMutableList().also { it[0] = "able"; it[1] = "able" })
            fail()
        } catch (e: CoreException.Checksum) {
        }
        assertTrue(completeWord("ocea").contains("ocean"))
    }

    @Test
    fun stateBlobOpens() {
        val root = Root.fromBytes(v.getString("B.root").chunked(2).map { it.toInt(16).toByte() }.toByteArray())
        stateOpen(root, v.getString("B.state_blob_b64u"))
        val sealed = stateSeal(root, encodeState(State(emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), null, com.sealctl.core.app.Settings(true, true, 0uL), emptyList())))
        assertEquals(0, decodeState(stateOpen(root, sealed)).machines.size)
    }

    @Test
    fun machineTagAndBackupItem() {
        assertEquals(v.getString("machine.tag"), machineTag(v.getString("machine.public_b64u")))
        val words = Words.parse(v.getString("B.mnemonic").split(" "))
        val item = backupItemEncode(words, "qHWf", 1795251600000uL)
        assertEquals(45, item.size)
        val back = backupItemDecode(item)
        assertEquals("qHWf", back.fingerprint)
        assertEquals(words.list(), back.words.list())
        assertEquals(4, cardChoices(words, 7u).size)
    }

    @Test
    fun relaySigningVectors() {
        val r = asset("relay-signing.json")
        val words = Words.parse(v.getString("B.mnemonic").split(" "))
        val keys = PhoneKeys.fromRoot(Root.fromWords(words))
        val vectors = r.getJSONArray("vectors")
        var checked = 0
        for (i in 0 until vectors.length()) {
            val x = vectors.getJSONObject(i)
            if (x.getString("signer") != "phone") continue
            val h = relayHeaders(keys, x.getString("method"), x.getString("path"), x.getString("time").toULong(), x.getString("body").toByteArray())
            assertEquals(x.getString("key"), h.key)
            assertEquals(x.getString("signature"), h.signature)
            checked++
        }
        assertTrue(checked > 0)
    }

    @Test
    fun expiredPairingCodeAndVersions() {
        try {
            PairingOffer.parse(v.getString("pair.link"))
            fail()
        } catch (e: CoreException.Expired) {
        }
        try {
            PairingOffer.parse("https://example.com/p#v=1")
            fail()
        } catch (e: CoreException.BadLink) {
        }
        assertEquals("1", protocolVersion())
        assertTrue(coreVersion().startsWith("0.7"))
    }
}
