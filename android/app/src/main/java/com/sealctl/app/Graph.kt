package com.sealctl.app

import android.content.Context
import com.sealctl.core.app.Store
import com.sealctl.places.Places
import com.sealctl.vault.BlockStore
import com.sealctl.vault.Vault
import java.io.File

/** The singletons, built by hand (SPEC.md 6.3: no DI framework). */
object Graph {
    lateinit var engine: Engine
        private set
    lateinit var blockStore: BlockStore
        private set
    lateinit var words: WordsFlow
        private set

    fun init(context: Context) {
        val app = context.applicationContext
        val vault = Vault(app)
        val store = Store.open(File(app.noBackupFilesDir, "sealctl.db").absolutePath)
        blockStore = BlockStore(app)
        engine = Engine(app, vault, store, relayUrl(app), Places(app))
        words = WordsFlow(app, engine)
    }

    /**
     * The relay origin: the build setting, or in debug builds only a test override written
     * to `no_backup/relay-override.txt` (used by the instrumented tests and the emulator runs
     * against the fake relay).
     */
    fun relayUrl(context: Context): String {
        if (BuildConfig.DEBUG) {
            val f = File(context.noBackupFilesDir, "relay-override.txt")
            if (f.exists()) f.readText().trim().takeIf { it.startsWith("http") }?.let { return it }
        }
        return BuildConfig.RELAY_URL
    }
}
