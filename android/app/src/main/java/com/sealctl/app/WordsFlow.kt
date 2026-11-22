package com.sealctl.app

import android.content.Context
import androidx.fragment.app.FragmentActivity
import com.sealctl.core.PhoneKeys
import com.sealctl.core.Root
import com.sealctl.core.Words
import com.sealctl.core.app.Event
import com.sealctl.core.app.LocalEvent
import com.sealctl.core.app.WordsInfo
import com.sealctl.core.app.cardChoices
import com.sealctl.core.app.cardPositions
import com.sealctl.core.app.cardWordMatches
import com.sealctl.core.backupItemEncode
import com.sealctl.core.fingerprint
import com.sealctl.vault.AuthResult
import com.sealctl.vault.Biometric
import com.sealctl.vault.KeysInvalidatedException
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The words on this phone: making them, showing them in the protected view, the card checks
 * and restoring. The `Words` object lives only while one of these screens is open.
 */
class WordsFlow(private val context: Context, private val engine: Engine) {
    private var session: Words? = null

    /** The 24 words for the protected view (FLAG_SECURE), or null when closed. */
    val shown = MutableStateFlow<List<String>?>(null)
    val fingerprint = MutableStateFlow<String?>(null)

    fun hasSession() = session != null

    /** Step 4 [Show my words]: makes the words behind the prompt, then stores root and keys. */
    suspend fun create(activity: FragmentActivity): AuthResult {
        if (engine.vault.hasWords() && engine.vault.hasRoot()) return show(activity)
        val cipher = engine.vault.wordsEncryptCipher()
        val r = Biometric.words(activity, "Show your words", "Use your fingerprint, face or screen lock", "Cancel", cipher)
        if (r !is AuthResult.Success || r.cipher == null) return r
        val words = Words.generate()
        saveAll(r.cipher!!, words)
        open(words)
        return r
    }

    private fun saveAll(cipher: javax.crypto.Cipher, words: Words) {
        engine.vault.saveWords(cipher, words)
        val root = Root.fromWords(words)
        try {
            engine.vault.saveRoot(root)
            val keys = PhoneKeys.fromRoot(root)
            engine.vault.savePhoneKeys(keys)
            keys.destroy()
            fingerprint.value = fingerprint(root)
        } finally {
            root.destroy()
        }
        engine.forgetPhoneKeys()
    }

    /** Shows the stored words after the words prompt (strong biometrics or the screen lock). */
    suspend fun show(activity: FragmentActivity): AuthResult {
        val cipher = try {
            engine.vault.wordsDecryptCipher()
        } catch (e: KeysInvalidatedException) {
            return AuthResult.Failed(-1, "invalidated")
        }
        val r = Biometric.words(activity, "Show your words", "Use your fingerprint, face or screen lock", "Cancel", cipher)
        if (r is AuthResult.Success && r.cipher != null) {
            open(engine.vault.readWords(r.cipher!!))
        }
        return r
    }

    /** Opens the words for a card check without showing them. */
    suspend fun unlockForCheck(activity: FragmentActivity): AuthResult {
        val cipher = try {
            engine.vault.wordsDecryptCipher()
        } catch (e: KeysInvalidatedException) {
            return AuthResult.Failed(-1, "invalidated")
        }
        val r = Biometric.words(activity, "Check your card", "Use your fingerprint, face or screen lock", "Cancel", cipher)
        if (r is AuthResult.Success && r.cipher != null) {
            open(engine.vault.readWords(r.cipher!!))
            shown.value = null
        }
        return r
    }

    private fun open(words: Words) {
        session?.destroy()
        session = words
        shown.value = words.list()
        val root = Root.fromWords(words)
        fingerprint.value = fingerprint(root)
        root.destroy()
    }

    /** Hides the words; the session stays for the check that follows. */
    fun hide() {
        shown.value = null
    }

    /** Forgets the words (screen closed, check done). */
    fun release() {
        shown.value = null
        session?.destroy()
        session = null
    }

    fun positions(count: Int, groups: Int): List<Int> = cardPositions(count.toUInt(), groups.toUInt()).map { it.toInt() }

    fun choices(position: Int): List<String> = session?.let { cardChoices(it, position.toUInt()) } ?: emptyList()

    fun matches(position: Int, typed: String): Boolean =
        session?.let { cardWordMatches(it, position.toUInt(), typed) } ?: false

    /** Step 6 passed: the card is written; the words backup goes to Block Store. */
    suspend fun cardChecked() {
        val fp = fingerprint.value ?: return
        val today = Texts.isoDate(System.currentTimeMillis())
        engine.apply(Event.SetWords(WordsInfo(fp, today, null, emptyList(), 0u)))
        engine.applyLocal(LocalEvent.SetOnboardingStep(7u))
        saveBackup()
        release()
        engine.computePhase()
    }

    /** Writes the Block Store item while the words are open. Returns whether it goes to the cloud. */
    suspend fun saveBackup(): Boolean? {
        val words = session ?: return null
        val fp = fingerprint.value ?: return null
        if (!engine.state.value.settings.keychainBackup) return null
        val item = backupItemEncode(words, fp, System.currentTimeMillis().toULong())
        return try { Graph.blockStore.save(item) } catch (e: Exception) { null } finally { item.fill(0) }
    }

    /** Restore: stores typed or backed-up words behind the words prompt. */
    suspend fun restore(activity: FragmentActivity, words: Words): AuthResult {
        val cipher = engine.vault.wordsEncryptCipher()
        val r = Biometric.words(activity, "Restore your words", "Use your fingerprint, face or screen lock", "Cancel", cipher)
        if (r !is AuthResult.Success || r.cipher == null) return r
        saveAll(r.cipher!!, words)
        open(words)
        shown.value = null
        return r
    }

    /** After a restore: the words facts from the relay, or written today. */
    fun restored(fp: String) {
        val w = engine.state.value.words
        if (w == null || w.fingerprint != fp) {
            engine.apply(Event.SetWords(WordsInfo(fp, Texts.isoDate(System.currentTimeMillis()), null, emptyList(), 0u)))
        }
        engine.applyLocal(LocalEvent.SetOnboardingStep(7u))
    }
}
