package com.sealctl.vault

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.UserNotAuthenticatedException
import com.sealctl.core.PhoneKeys
import com.sealctl.core.Root
import com.sealctl.core.Words
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The words or a key were invalidated (screen lock changed): the app moves to WordsLost. */
class KeysInvalidatedException : Exception("keys invalidated")

/** The root can't be read now: the device is locked. */
class DeviceLockedException : Exception("device locked")

/**
 * Key storage (SPEC.md 7.3): secrets are AES-256-GCM encrypted with Android Keystore keys
 * and kept as files in `noBackupFilesDir`. Raw bytes exist in Kotlin only between the file
 * and the core object they become, and are wiped at once.
 */
class Vault(private val context: Context) {
    private val dir: File = context.noBackupFilesDir
    private val keyStore: KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    fun isDeviceSecure(): Boolean =
        (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceSecure

    fun isDeviceLocked(): Boolean =
        (context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager).isDeviceLocked

    fun hasRoot(): Boolean = file(ROOT).exists()
    fun hasWords(): Boolean = file(WORDS).exists()
    fun hasPhoneKeys(): Boolean = file(PHONE).exists()

    // ---------- root ----------

    /** Stores the root under `sealctl.root` (`setUnlockedDeviceRequired`). */
    fun saveRoot(root: Root) {
        val key = key(ROOT_KEY) { setUnlockedDeviceRequired(true) }
        val bytes = root.toBytes()
        try { writeSealed(ROOT, key, bytes) } finally { bytes.fill(0) }
    }

    /** The root, readable only while the device is unlocked. Destroy it after use. */
    fun readRoot(): Root {
        val key = existingKey(ROOT_KEY) ?: throw KeysInvalidatedException()
        val bytes = readSealed(ROOT, key)
        try { return Root.fromBytes(bytes) } finally { bytes.fill(0) }
    }

    /** Whether the root can be read now (the phone is unlocked). */
    fun canReadRoot(): Boolean = try {
        readRoot().destroy(); true
    } catch (e: Exception) {
        false
    }

    // ---------- phone keys ----------

    fun savePhoneKeys(keys: PhoneKeys) {
        val key = key(DEVICE_KEY) {}
        val bytes = keys.toBytes()
        try { writeSealed(PHONE, key, bytes) } finally { bytes.fill(0) }
    }

    /** The phone keys; readable after the first unlock since boot. */
    fun readPhoneKeys(): PhoneKeys? {
        if (!file(PHONE).exists()) return null
        val key = existingKey(DEVICE_KEY) ?: throw KeysInvalidatedException()
        val bytes = readSealed(PHONE, key)
        try { return PhoneKeys.fromBytes(bytes) } finally { bytes.fill(0) }
    }

    // ---------- words (behind biometrics or the screen lock) ----------

    /** A cipher to encrypt new words; authenticate it with BiometricPrompt first. */
    fun wordsEncryptCipher(): Cipher {
        val key = key(WORDS_KEY) { wordsAuth() }
        return try {
            Cipher.getInstance(GCM).apply { init(Cipher.ENCRYPT_MODE, key) }
        } catch (e: KeyPermanentlyInvalidatedException) {
            deleteKey(WORDS_KEY)
            Cipher.getInstance(GCM).apply { init(Cipher.ENCRYPT_MODE, key(WORDS_KEY) { wordsAuth() }) }
        }
    }

    /** A cipher to decrypt the words; authenticate it with BiometricPrompt first. */
    fun wordsDecryptCipher(): Cipher {
        val key = existingKey(WORDS_KEY) ?: throw KeysInvalidatedException()
        val raw = file(WORDS).readBytes()
        return try {
            Cipher.getInstance(GCM).apply { init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, raw, 0, IV)) }
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw KeysInvalidatedException()
        }
    }

    fun saveWords(authenticated: Cipher, words: Words) {
        val entropy = words.entropy()
        try {
            val ct = authenticated.doFinal(entropy)
            atomicWrite(WORDS, authenticated.iv + ct)
        } finally {
            entropy.fill(0)
        }
    }

    fun readWords(authenticated: Cipher): Words {
        val raw = file(WORDS).readBytes()
        val entropy = authenticated.doFinal(raw, IV, raw.size - IV)
        try { return Words.fromEntropy(entropy) } finally { entropy.fill(0) }
    }

    private fun KeyGenParameterSpec.Builder.wordsAuth() {
        setUserAuthenticationRequired(true)
        setInvalidatedByBiometricEnrollment(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            setUserAuthenticationParameters(
                0, KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
            )
        } else {
            @Suppress("DEPRECATION")
            setUserAuthenticationValidityDurationSeconds(-1)
        }
    }

    // ---------- the biometric gate (levels 2 and 3, SPEC.md 9.6) ----------

    /** A gate cipher and whether it makes a new gate (first use) or checks the existing one. */
    class Gate(val cipher: Cipher, val creating: Boolean)

    /**
     * A cipher on `sealctl.gate` for a strong-biometric-only prompt. The gate file holds 32
     * random bytes; decrypting it is the proof of a fresh match. When there is no gate yet the
     * cipher encrypts a new one. Throws [KeysInvalidatedException] after an enrolment change.
     */
    fun gate(): Gate {
        val existing = existingKey(GATE_KEY)
        val gate = file(GATE)
        return try {
            if (existing != null && gate.exists()) {
                val raw = gate.readBytes()
                Gate(Cipher.getInstance(GCM).apply { init(Cipher.DECRYPT_MODE, existing, GCMParameterSpec(128, raw, 0, IV)) }, false)
            } else {
                val key = existing ?: key(GATE_KEY) { gateAuth() }
                Gate(Cipher.getInstance(GCM).apply { init(Cipher.ENCRYPT_MODE, key) }, true)
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw KeysInvalidatedException()
        }
    }

    /** Completes the gate with the cipher BiometricPrompt authenticated. */
    fun passGate(gate: Gate): Boolean = try {
        if (gate.creating) {
            val secret = ByteArray(32).also { SecureRandom().nextBytes(it) }
            atomicWrite(GATE, gate.cipher.iv + gate.cipher.doFinal(secret))
            true
        } else {
            val raw = file(GATE).readBytes()
            gate.cipher.doFinal(raw, IV, raw.size - IV).size == 32
        }
    } catch (e: Exception) {
        false
    }

    /** After an enrolment change and the card words: a new gate key. */
    fun resetGate() {
        deleteKey(GATE_KEY)
        file(GATE).delete()
    }

    private fun KeyGenParameterSpec.Builder.gateAuth() {
        setUserAuthenticationRequired(true)
        setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            @Suppress("DEPRECATION")
            setUserAuthenticationValidityDurationSeconds(-1)
        }
    }

    // ---------- erase ----------

    /** Deletes every key and file (Erase sealctl from this phone). */
    fun erase() {
        for (alias in listOf(ROOT_KEY, WORDS_KEY, DEVICE_KEY, GATE_KEY)) deleteKey(alias)
        for (f in listOf(ROOT, WORDS, PHONE, GATE, "root.old.bin", "words.old.bin")) file(f).delete()
    }

    // ---------- plumbing ----------

    private fun file(name: String) = File(dir, name)

    private fun existingKey(alias: String): SecretKey? =
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey

    private fun deleteKey(alias: String) {
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
    }

    /** The key, created on first use: StrongBox first, the TEE when there is none. */
    private fun key(alias: String, params: KeyGenParameterSpec.Builder.() -> Unit): SecretKey {
        existingKey(alias)?.let { return it }
        fun build(strongBox: Boolean): SecretKey {
            val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .apply { if (strongBox) setIsStrongBoxBacked(true) }
                .apply(params)
                .build()
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
                .apply { init(spec) }
                .generateKey()
        }
        return try {
            build(strongBox = true)
        } catch (e: StrongBoxUnavailableException) {
            build(strongBox = false)
        } catch (e: java.security.ProviderException) {
            build(strongBox = false)
        }
    }

    private fun writeSealed(name: String, key: SecretKey, plain: ByteArray) {
        val c = Cipher.getInstance(GCM).apply { init(Cipher.ENCRYPT_MODE, key) }
        atomicWrite(name, c.iv + c.doFinal(plain))
    }

    private fun readSealed(name: String, key: SecretKey): ByteArray {
        val raw = file(name).readBytes()
        val c = Cipher.getInstance(GCM)
        try {
            c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, raw, 0, IV))
            return c.doFinal(raw, IV, raw.size - IV)
        } catch (e: KeyPermanentlyInvalidatedException) {
            throw KeysInvalidatedException()
        } catch (e: UserNotAuthenticatedException) {
            throw DeviceLockedException()
        } catch (e: javax.crypto.IllegalBlockSizeException) {
            // Keystore reports a use while the device is locked this way on some versions.
            throw DeviceLockedException()
        } catch (e: java.security.InvalidKeyException) {
            if (isDeviceLocked()) throw DeviceLockedException()
            throw KeysInvalidatedException()
        }
    }

    private fun atomicWrite(name: String, bytes: ByteArray) {
        val tmp = file("$name.tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file(name))) {
            file(name).delete()
            tmp.renameTo(file(name))
        }
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val GCM = "AES/GCM/NoPadding"
        private const val IV = 12
        const val ROOT = "root.bin"
        const val WORDS = "words.bin"
        const val PHONE = "phone.bin"
        const val GATE = "gate.bin"
        const val ROOT_KEY = "sealctl.root"
        const val WORDS_KEY = "sealctl.words"
        const val DEVICE_KEY = "sealctl.device"
        const val GATE_KEY = "sealctl.gate"
    }
}
